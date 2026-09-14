module Sync_session = Logseq_chat_lg_core_native
module E2ee_keyring = Logseq_chat_lg_core_native

let () =
  if not (Logseq_chat_lui_native.logseq_chat_native_bridge_linked ())
  then failwith "LG/LUI native bridge failed to link"

let () = Logseq_chat_lui_projection.register_callbacks ()

let e2ee_keyring =
  E2ee_keyring.logseq_chat_e2ee_keyring_create
    Logseq_chat_platform_crypto.crypto
    (fun graph_id -> Logseq_chat_platform_crypto.load_graph_key ~graph_id)
    (fun graph_id key -> Logseq_chat_platform_crypto.save_graph_key ~graph_id ~key)
    Logseq_chat_platform_crypto.load_e2ee_password
    (fun password -> Logseq_chat_platform_crypto.save_e2ee_password ~password)
    Logseq_chat_http.send
;;

type graph_runtime =
  { conn : Datascript.conn
  ; state : Sync_session.sync_session_state
  ; checkpoint_path : string
  ; graph_id : string
  ; e2ee : bool
  ; read_runtime : Logseq_chat_graph_runtime.t
  }

let graph_runtime : graph_runtime option ref = ref None
let projection_session : Logseq_chat_sqlite.session option ref = ref None
let sqlite_session : Logseq_chat_sqlite.session option ref = ref None

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

let graph_read_runtime ~graph_id ~active_path ~server_t ~e2ee conn =
  (* The search index lives next to the graph database, matching Logseq's
     per-graph <graph>/search/db.sqlite layout. *)
  let search_index_path =
    Filename.concat (Filename.dirname active_path) (Filename.concat "search" "db.sqlite")
  in
  if e2ee
  then
    Logseq_chat_graph_runtime.create
      ~encrypt_title:(E2ee_keyring.logseq_chat_e2ee_keyring_encrypt_title e2ee_keyring graph_id)
      ~search_index_path
      ~auto_create_today:true
      ~path:active_path
      ~server_t
      conn
  else
    Logseq_chat_graph_runtime.create
      ~search_index_path
      ~auto_create_today:true
      ~path:active_path
      ~server_t
      conn
;;

let open_graph_paths ~graph_id ~active_path ~checkpoint_path ~e2ee =
  let started_at = Unix.gettimeofday () in
  let report stage =
    Printf.eprintf
      "LOGSEQ_GRAPH_OPEN_METRIC stage=%s elapsed_ms=%.3f\n%!"
      stage
      ((Unix.gettimeofday () -. started_at) *. 1000.0)
  in
  let bind result f = match result with Ok value -> f value | Error _ as error -> error in
  let ( let* ) = bind in
  let* checkpoint = Logseq_chat_lg_core_native.logseq_chat_sync_checkpoint_load_checkpoint checkpoint_path in
  report "checkpoint_loaded";
  let* checkpoint =
    match checkpoint with
    | Some checkpoint when String.equal checkpoint.graph_id graph_id -> Ok checkpoint
    | Some _ -> Error "graph checkpoint belongs to another graph"
    | None -> Error "graph checkpoint is missing"
  in
  let* conn = Logseq_chat_lg_core_native.logseq_chat_graph_store_restore_conn active_path in
  report "connection_restored";
  let* () =
    if e2ee
    then Result.map (fun _key -> ()) (E2ee_keyring.logseq_chat_e2ee_keyring_graph_key e2ee_keyring graph_id)
    else Ok ()
  in
  report "encryption_ready";
  let state =
    Logseq_chat_lg_core_native.logseq_chat_sync_session_create_state
      graph_id checkpoint.schema_version checkpoint.applied_server_t
  in
  let read_runtime =
    graph_read_runtime
      ~graph_id
      ~active_path
      ~server_t:checkpoint.applied_server_t
      ~e2ee
      conn
  in
  report "runtime_created";
  graph_runtime := Some { conn; state; checkpoint_path; graph_id; e2ee; read_runtime };
  report "complete";
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
      let* metadata = Logseq_chat_lg_core_native.logseq_chat_sync_session_decode_snapshot_metadata metadata_body in
      let* _ =
        Logseq_chat_lg_core_native.logseq_chat_sync_session_import_snapshot_file
          (if e2ee
           then Some (E2ee_keyring.logseq_chat_e2ee_keyring_decrypt_title e2ee_keyring graph_id)
           else None)
          graph_id active_path checkpoint_path metadata download_path
      in
      open_graph_paths ~graph_id ~active_path ~checkpoint_path ~e2ee
    | _ -> Error "importSnapshot payload must be an object"
  with
  | error -> Error (Printexc.to_string error)
;;

let apply_sync_event payload =
  let bind result f = match result with Ok value -> f value | Error _ as error -> error in
  let ( let* ) = bind in
  try
    match Yojson.Basic.from_string payload with
    | `Assoc fields ->
      let* event_name = required_string fields "type" in
      let* data = required_string fields "data" in
      bind
        (Logseq_chat_lg_core_native.logseq_chat_sync_protocol_decode_event event_name data)
        (function
          | Logseq_chat_lg_core_native.Reset reset ->
            Error ("snapshot required: " ^ reset.reason)
          | Graph_changes change ->
            (match !graph_runtime with
             | None -> Error "graph runtime is not open"
             | Some runtime ->
               bind
                 (Logseq_chat_lg_core_native.logseq_chat_sync_session_apply_change_set
                    (if runtime.e2ee
                     then E2ee_keyring.logseq_chat_e2ee_keyring_decrypt_title e2ee_keyring runtime.graph_id
                     else (fun value -> Ok value))
                    runtime.conn
                    runtime.checkpoint_path
                    runtime.state
                    change)
                 (fun () ->
                   Logseq_chat_graph_runtime.rebase
                     runtime.read_runtime
                     ~server_t:change.t
                     ~operation_ids:change.operation_ids
                     ~changed_uuids:
                       (Logseq_chat_lg_core_native.logseq_chat_sync_protocol_changed_block_uuids change
                        |> Rrbvec.to_list);
                   Ok ())))
    | _ -> Error "WebSocket sync event must be an object"
  with
  | Yojson.Json_error message -> Error message
;;

let sync_cursor () =
  match !graph_runtime with
  | Some runtime -> Some (Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t runtime.state)
  | None -> None
;;

let graph_blocks () =
  match !graph_runtime with
  | Some runtime -> Some (Logseq_chat_graph_runtime.blocks runtime.read_runtime)
  | None -> None
;;

let authoritative_graph_blocks () =
  match !graph_runtime with
  | Some runtime ->
    Some (Logseq_chat_graph_read.blocks
            (Datascript.conn_db runtime.read_runtime.conn))
  | None -> None
;;

let graph_sidebar_pages () =
  match !graph_runtime with
  | Some runtime ->
    Some (Logseq_chat_graph_runtime.sidebar_pages runtime.read_runtime)
  | None -> None
;;

let graph_tag_pages () =
  match !graph_runtime with
  | Some runtime -> Some (Logseq_chat_graph_runtime.tag_pages runtime.read_runtime)
  | None -> None
;;

let graph_node_is_tag uuid =
  match !graph_runtime with
  | Some runtime -> Logseq_chat_graph_runtime.node_is_tag runtime.read_runtime uuid
  | None -> false
;;

let graph_node_is_property uuid =
  match !graph_runtime with
  | Some runtime -> Logseq_chat_graph_runtime.node_is_property runtime.read_runtime uuid
  | None -> false
;;

let graph_page_blocks page_uuid =
  match !graph_runtime with
  | Some runtime ->
    Some (Logseq_chat_graph_runtime.blocks_for_page runtime.read_runtime page_uuid)
  | None -> None
;;

let graph_node_destination uuid =
  match !graph_runtime with
  | Some runtime ->
    Logseq_chat_graph_runtime.node_destination runtime.read_runtime uuid
  | None -> None
;;

let graph_tag_objects uuid =
  match !graph_runtime with
  | Some runtime ->
    Some (Logseq_chat_graph_runtime.objects_for_tag runtime.read_runtime uuid)
  | None -> None
;;

let graph_node_references uuid =
  match !graph_runtime with
  | Some runtime ->
    Some (Logseq_chat_graph_runtime.references_for_node runtime.read_runtime uuid)
  | None -> None
;;

let graph_normalize_titles ~uuid titles =
  match !graph_runtime with
  | Some runtime ->
    Logseq_chat_graph_runtime.normalize_titles runtime.read_runtime ~uuid titles
  | None -> titles, []
;;

let graph_search query =
  match !graph_runtime with
  | Some runtime -> Logseq_chat_graph_runtime.search runtime.read_runtime query
  | None -> []
;;

let graph_due_flashcards ~now =
  match !graph_runtime with
  | Some runtime -> Logseq_chat_graph_runtime.due_flashcards runtime.read_runtime ~now
  | None -> []
;;

let graph_review_flashcard ~uuid ~rating ~now ~operation_id =
  match !graph_runtime with
  | Some runtime ->
    Logseq_chat_graph_runtime.review_flashcard
      runtime.read_runtime
      ~uuid
      ~rating
      ~now
      ~operation_id
  | None -> Error "graph runtime is not open"
;;

let graph_set_page_favorite ~page_uuid ~favorite ~operation_id ~now =
  match !graph_runtime with
  | Some runtime ->
    Logseq_chat_graph_runtime.set_page_favorite
      runtime.read_runtime
      ~page_uuid
      ~favorite
      ~operation_id
      ~now
  | None -> Error "graph runtime is not open"
;;

let graph_delete_page ~page_uuid ~operation_id ~now =
  match !graph_runtime with
  | Some runtime ->
    Logseq_chat_graph_runtime.delete_page
      runtime.read_runtime
      ~page_uuid
      ~operation_id
      ~now
  | None -> Error "graph runtime is not open"
;;

let load_older_journals () =
  Option.iter
    (fun runtime -> Logseq_chat_graph_runtime.load_older_journals runtime.read_runtime)
    !graph_runtime
;;

let has_older_journals () =
  Option.fold
    ~none:false
    ~some:(fun runtime ->
      Logseq_chat_graph_runtime.has_older_journals runtime.read_runtime)
    !graph_runtime
;;

let journal_page_id ~journal_day =
  match !graph_runtime with
  | Some runtime ->
    Logseq_chat_graph_runtime.journal_page_uuid runtime.read_runtime ~journal_day
  | None -> None
;;

let stage_operation operation =
  match !graph_runtime with
  | None -> Error "graph runtime is not open"
  | Some runtime -> Logseq_chat_graph_runtime.stage runtime.read_runtime operation
;;

let prepare_operation operation =
  match !graph_runtime with
  | None -> Error "graph runtime is not open"
  | Some runtime -> Logseq_chat_graph_runtime.prepare_sync runtime.read_runtime operation
;;

let pending_operations () =
  match !graph_runtime with
  | None -> []
  | Some runtime -> Logseq_chat_graph_runtime.pending_operations runtime.read_runtime
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

let resolve_asset_path source_path =
  if Filename.is_relative source_path
  then
    match !graph_runtime with
    | Some runtime ->
      let documents_dir =
        runtime.checkpoint_path |> Filename.dirname |> Filename.dirname |> Filename.dirname
      in
      Filename.concat documents_dir source_path
    | None -> source_path
  else source_path
;;

let encrypt_asset_file ~graph_id ~source_path =
  let bind result f = match result with Ok value -> f value | Error _ as error -> error in
  bind (read_file source_path) (fun bytes ->
    bind (E2ee_keyring.logseq_chat_e2ee_keyring_encrypt_asset e2ee_keyring graph_id bytes) (fun encrypted ->
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

let model_for_graph ~graph_id =
  match !graph_runtime with
  | Some runtime when String.equal runtime.graph_id graph_id ->
    Option.iter Logseq_chat_sqlite.close !projection_session;
    let path =
      Filename.concat (Filename.dirname runtime.checkpoint_path) "projection.sqlite"
    in
    let projection = Logseq_chat_sqlite.open_session path in
    let projection_storage = Logseq_chat_sqlite.storage projection in
    if projection_storage.storage_list_addresses () = []
    then
      Option.iter
        (fun catalog ->
          Logseq_chat_sqlite.migrate_datascript_storage
            ~source:catalog
            ~destination:projection)
        !sqlite_session;
    projection_session := Some projection;
    Logseq_chat_model.create ~storage:projection_storage ()
  | _ -> Logseq_chat_model.create ()
;;

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
    ~model_for_graph
    ~apply_sync_event
    ~sync_cursor
    ~graph_blocks
    ~authoritative_graph_blocks
    ~graph_sidebar_pages
    ~graph_tag_pages
    ~graph_node_is_tag
    ~graph_node_is_property
    ~graph_page_blocks
    ~graph_node_destination
    ~graph_node_references
    ~graph_tag_objects
    ~graph_normalize_titles
    ~graph_search
    ~graph_due_flashcards
    ~graph_review_flashcard
    ~graph_set_page_favorite
    ~graph_delete_page
    ~load_older_journals
    ~has_older_journals
    ~stage_operation
    ~prepare_operation
    ~pending_operations
    ~load_cached_graph_key:(fun config ->
      Result.map
        (fun _key -> ())
        (E2ee_keyring.logseq_chat_e2ee_keyring_load_cached e2ee_keyring config))
    ~unlock_graph:(fun config ~password ->
      Result.map (fun _key -> ()) (E2ee_keyring.logseq_chat_e2ee_keyring_unlock e2ee_keyring config password))
    ~provision_graph_key:(fun config ->
      Result.map (fun _key -> ()) (E2ee_keyring.logseq_chat_e2ee_keyring_provision e2ee_keyring config))
    ~graph_unlocked:(fun ~graph_id ->
      Result.is_ok (E2ee_keyring.logseq_chat_e2ee_keyring_graph_key e2ee_keyring graph_id))
    ~encrypt_title:(fun ~graph_id title ->
      E2ee_keyring.logseq_chat_e2ee_keyring_encrypt_title e2ee_keyring graph_id title)
    ~resolve_asset_path
    ~encrypt_asset_file
    ~journal_page_id
    ()
;;
let session = ref (create_session ())

let assoc name fields = List.assoc_opt name fields

let open_database request =
  match Yojson.Basic.from_string request with
  | `Assoc fields ->
    (match assoc "method" fields, assoc "params" fields with
     | Some (`String "open"), Some (`Assoc params) ->
       (match assoc "path" params with
        | Some (`String path) ->
          Option.iter Logseq_chat_sqlite.close !sqlite_session;
          Option.iter Logseq_chat_sqlite.close !projection_session;
          projection_session := None;
          graph_runtime := None;
          let opened = Logseq_chat_sqlite.open_session path in
          sqlite_session := Some opened;
          session :=
            create_session
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
