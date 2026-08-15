module Sync_session = Logseq_chat_sync_session
module Checkpoint = Logseq_chat_sync_checkpoint
module E2ee_keyring = Logseq_chat_e2ee_keyring

let e2ee_keyring =
  Logseq_chat_e2ee_keyring.create
    ~crypto:Logseq_chat_platform_crypto.crypto
    ~load:Logseq_chat_platform_crypto.load_graph_key
    ~save:Logseq_chat_platform_crypto.save_graph_key
    ~fetch:Logseq_chat_http.send
;;

type graph_runtime =
  { conn : Datascript.conn
  ; state : Logseq_chat_sync_state.t
  ; checkpoint_path : string
  ; graph_id : string
  ; e2ee : bool
  ; mutable recent_blocks : Logseq_chat_model.block list
  }

let graph_runtime : graph_runtime option ref = ref None
let sse_parser = ref (Logseq_chat_sse.create ())

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) when not (String.equal value "") -> Ok value
  | _ -> Error ("graph sync payload requires " ^ name)
;;

let optional_bool fields name =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> Ok value
  | None -> Ok false
  | Some _ -> Error ("graph sync payload requires a boolean " ^ name)
;;

let graph_blocks ~graph_id ~e2ee conn =
  if e2ee
  then
    Logseq_chat_graph_read.blocks
      ~decrypt_title:(E2ee_keyring.decrypt_title e2ee_keyring ~graph_id)
      (Datascript.conn_db conn)
  else Logseq_chat_graph_read.blocks (Datascript.conn_db conn)
;;

let open_graph_paths ~graph_id ~active_path ~checkpoint_path ~e2ee =
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
  let* () =
    if e2ee
    then Result.map (fun _key -> ()) (E2ee_keyring.graph_key e2ee_keyring ~graph_id)
    else Ok ()
  in
  let state =
    Logseq_chat_sync_state.create
      ~graph_id
      ~schema_version:checkpoint.schema_version
      ~applied_server_t:checkpoint.applied_server_t
  in
  let recent_blocks = graph_blocks ~graph_id ~e2ee conn in
  graph_runtime := Some { conn; state; checkpoint_path; graph_id; e2ee; recent_blocks };
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
      let* e2ee = optional_bool fields "isEncrypted" in
      open_graph_paths ~graph_id ~active_path ~checkpoint_path ~e2ee
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
      let* e2ee = optional_bool fields "isEncrypted" in
      let* metadata = Sync_session.decode_snapshot_metadata metadata_body in
      let* _ =
        Sync_session.import_snapshot_file
          ~graph_id
          ~active_path
          ~checkpoint_path
          ~metadata
          ~download_path
      in
      open_graph_paths ~graph_id ~active_path ~checkpoint_path ~e2ee
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
             | Some runtime ->
               bind
                 (Sync_session.apply_change_set
                    ~conn:runtime.conn
                    ~checkpoint_path:runtime.checkpoint_path
                    runtime.state
                    change)
                 (fun () ->
                   runtime.recent_blocks <-
                     graph_blocks ~graph_id:runtime.graph_id ~e2ee:runtime.e2ee runtime.conn;
                   apply_frames rest)))
  in
  apply_frames (Logseq_chat_sse.feed !sse_parser chunk)
;;

let sync_cursor () =
  match !graph_runtime with
  | Some runtime -> Some (Logseq_chat_sync_state.applied_server_t runtime.state)
  | None -> None
;;

let graph_blocks () =
  match !graph_runtime with
  | Some runtime -> Some runtime.recent_blocks
  | None -> None
;;

let journal_page_id ~journal_day =
  match !graph_runtime with
  | Some runtime ->
    Logseq_chat_graph_read.journal_page_uuid
      (Datascript.conn_db runtime.conn)
      ~journal_day
  | None -> None
;;

let read_file path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> Ok (really_input_string channel (in_channel_length channel)))
  with
  | error -> Error ("read asset for encryption: " ^ Printexc.to_string error)
;;

let write_file path contents =
  try
    let channel = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () -> output_string channel contents);
    Ok ()
  with
  | error -> Error ("write encrypted asset: " ^ Printexc.to_string error)
;;

let encrypt_asset_file ~graph_id ~source_path =
  let bind result f = match result with Ok value -> f value | Error _ as error -> error in
  bind (read_file source_path) (fun bytes ->
    bind (E2ee_keyring.encrypt_asset e2ee_keyring ~graph_id bytes) (fun encrypted ->
      let path =
        Filename.temp_file
          ~temp_dir:(Filename.dirname source_path)
          "logseq-chat-e2ee-"
          ".transit"
      in
      match write_file path encrypted with
      | Ok () -> Ok (path, String.length encrypted)
      | Error _ as error ->
        (try Sys.remove path with _ -> ());
        error))
;;

let graph_catalog_address = "logseq-chat/graph-catalog/v1"

let create_session ?storage ?catalog_session () =
  Logseq_chat_rpc.create
    ?storage
    ?load_graph_catalog:
      (Option.map
         (fun session () ->
           Logseq_chat_sqlite.restore_string session ~address:graph_catalog_address)
         catalog_session)
    ?save_graph_catalog:
      (Option.map
         (fun session body ->
           Logseq_chat_sqlite.store_string session ~address:graph_catalog_address body)
         catalog_session)
    ~open_graph
    ~import_snapshot
    ~start_sse
    ~feed_sse
    ~sync_cursor
    ~graph_blocks
    ~load_cached_graph_key:(fun ~graph_id ->
      Result.map
        (fun _key -> ())
        (E2ee_keyring.load_cached e2ee_keyring ~graph_id))
    ~unlock_graph:(fun config ~password ->
      Result.map (fun _key -> ()) (E2ee_keyring.unlock e2ee_keyring config ~password))
    ~graph_unlocked:(fun ~graph_id ->
      Result.is_ok (E2ee_keyring.graph_key e2ee_keyring ~graph_id))
    ~encrypt_title:(E2ee_keyring.encrypt_title e2ee_keyring)
    ~encrypt_asset_file
    ~journal_page_id
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
            create_session
              ~storage:(Logseq_chat_sqlite.storage opened)
              ~catalog_session:opened
              ();
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
