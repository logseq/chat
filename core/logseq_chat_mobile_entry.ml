module Sync_session = Logseq_chat_sync_session
module Checkpoint = Logseq_chat_sync_checkpoint

type graph_runtime = Datascript.conn * Logseq_chat_sync_state.t * string

let graph_runtime : graph_runtime option ref = ref None
let sse_parser = ref (Logseq_chat_sse.create ())

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) when not (String.equal value "") -> Ok value
  | _ -> Error ("graph sync payload requires " ^ name)
;;

let open_graph_paths ~graph_id ~active_path ~checkpoint_path =
  let bind result f = match result with Ok value -> f value | Error _ as error -> error in
  let ( let* ) = bind in
  let* checkpoint = Checkpoint.load checkpoint_path in
  let* checkpoint =
    match checkpoint with
    | Some checkpoint when String.equal checkpoint.graph_id graph_id -> Ok checkpoint
    | Some _ -> Error "graph checkpoint belongs to another graph"
    | None -> Error "graph checkpoint is missing"
  in
  let* conn = Logseq_chat_graph_store.restore_conn ~path:active_path in
  let state =
    Logseq_chat_sync_state.create
      ~graph_id
      ~schema_version:checkpoint.schema_version
      ~applied_server_t:checkpoint.applied_server_t
  in
  graph_runtime := Some (conn, state, checkpoint_path);
  Ok ()
;;

let open_graph payload =
  try
    match Yojson.Basic.from_string payload with
    | `Assoc fields ->
      let bind result f = match result with Ok value -> f value | Error _ as error -> error in
      let ( let* ) = bind in
      let* graph_id = required_string fields "graphId" in
      let* active_path = required_string fields "activePath" in
      let* checkpoint_path = required_string fields "checkpointPath" in
      open_graph_paths ~graph_id ~active_path ~checkpoint_path
    | _ -> Error "openGraph payload must be an object"
  with
  | error -> Error (Printexc.to_string error)
;;

let import_snapshot payload =
  try
    match Yojson.Basic.from_string payload with
    | `Assoc fields ->
      let bind result f = match result with Ok value -> f value | Error _ as error -> error in
      let ( let* ) = bind in
      let* graph_id = required_string fields "graphId" in
      let* active_path = required_string fields "activePath" in
      let* checkpoint_path = required_string fields "checkpointPath" in
      let* metadata_body = required_string fields "metadataBody" in
      let* download_path = required_string fields "downloadPath" in
      let* metadata = Sync_session.decode_snapshot_metadata metadata_body in
      let* _ =
        Sync_session.import_snapshot_file
          ~graph_id
          ~active_path
          ~checkpoint_path
          ~metadata
          ~download_path
      in
      open_graph_paths ~graph_id ~active_path ~checkpoint_path
    | _ -> Error "importSnapshot payload must be an object"
  with
  | error -> Error (Printexc.to_string error)
;;

let start_sse () = sse_parser := Logseq_chat_sse.create ()

let feed_sse chunk =
  let bind result f = match result with Ok value -> f value | Error _ as error -> error in
  let rec apply_frames = function
    | [] -> Ok ()
    | (frame : Logseq_chat_sse.frame) :: rest ->
      bind
        (Logseq_chat_sync_protocol.decode_event ~event_name:frame.event frame.data)
        (function
          | Logseq_chat_sync_protocol.Reset reset ->
            Error ("snapshot required: " ^ reset.reason)
          | Graph_changes change ->
            (match !graph_runtime with
             | None -> Error "graph runtime is not open"
             | Some (conn, state, checkpoint_path) ->
               bind
                 (Sync_session.apply_change_set ~conn ~checkpoint_path state change)
                 (fun () -> apply_frames rest)))
  in
  apply_frames (Logseq_chat_sse.feed !sse_parser chunk)
;;

let sync_cursor () =
  match !graph_runtime with
  | Some (_conn, state, _checkpoint_path) ->
    Some (Logseq_chat_sync_state.applied_server_t state)
  | None -> None
;;

let graph_blocks () =
  match !graph_runtime with
  | Some (conn, _state, _checkpoint_path) ->
    Some (Logseq_chat_graph_read.blocks (Datascript.conn_db conn))
  | None -> None
;;

let create_session ?storage () =
  Logseq_chat_rpc.create
    ?storage
    ~open_graph
    ~import_snapshot
    ~start_sse
    ~feed_sse
    ~sync_cursor
    ~graph_blocks
    ()
;;
let session = ref (create_session ())
let sqlite_session : Logseq_chat_sqlite.session option ref = ref None

let assoc name fields = List.assoc_opt name fields

let open_database request =
  match Yojson.Basic.from_string request with
  | `Assoc fields ->
    (match assoc "method" fields, assoc "params" fields with
     | Some (`String "open"), Some (`Assoc params) ->
       (match assoc "path" params with
        | Some (`String path) ->
          Option.iter Logseq_chat_sqlite.close !sqlite_session;
          let opened = Logseq_chat_sqlite.open_session path in
          sqlite_session := Some opened;
          session :=
            create_session ~storage:(Logseq_chat_sqlite.storage opened) ();
          Some (Logseq_chat_rpc.call !session {|{"apiVersion":1,"method":"snapshot","params":{}}|})
        | _ -> None)
     | _ -> None)
  | _ -> None
  | exception _ -> None
;;

let call request =
  match open_database request with
  | Some response -> response
  | None -> Logseq_chat_rpc.call !session request
;;

let () = Callback.register "logseq_chat_mobile_call" call
