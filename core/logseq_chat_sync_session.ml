module Snapshot = Logseq_chat_lg_core_native
module Store = Logseq_chat_lg_core_native
module LG = Logseq_chat_lg_core_native
module Protocol = Logseq_chat_lg_core_native

type checkpoint = LG.sync_checkpoint =
  { graph_id : string
  ; schema_version : string
  ; applied_server_t : int
  }

type state =
  { graph_id : string
  ; schema_version : string
  ; mutable applied_server_t : int
  }

type sync_error =
  | Unsupported_format
  | Graph_mismatch
  | Schema_mismatch
  | Cursor_mismatch
  | Invalid_cursor
  | Apply_failed of string

type snapshot_metadata =
  { url : string
  ; content_encoding : string option
  ; baseline_t : int
  ; schema_version : string
  ; row_count : int
  }

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let create_checkpoint ~graph_id ~schema_version ~applied_server_t =
  LG.logseq_chat_sync_checkpoint_create graph_id schema_version applied_server_t
;;

let encode_checkpoint = LG.logseq_chat_sync_checkpoint_encode
let decode_checkpoint = LG.logseq_chat_sync_checkpoint_decode

let checkpoint_error_message operation path error =
  Printf.sprintf "%s %s: %s" operation path (Printexc.to_string error)
;;

let load_checkpoint path =
  if not (Sys.file_exists path)
  then Ok None
  else
    try
      let channel = open_in_bin path in
      let source =
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () -> really_input_string channel (in_channel_length channel))
      in
      Result.map Option.some (decode_checkpoint source)
    with
    | error -> Error (checkpoint_error_message "read checkpoint" path error)
;;

let save_checkpoint_atomic path checkpoint =
  let temporary = path ^ ".tmp" in
  try
    let channel = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600 temporary in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () ->
        output_string channel (encode_checkpoint checkpoint);
        flush channel;
        Unix.fsync (Unix.descr_of_out_channel channel));
    Unix.rename temporary path;
    Ok ()
  with
  | error ->
    (try if Sys.file_exists temporary then Sys.remove temporary with
     | _ -> ());
    Error (checkpoint_error_message "write checkpoint" path error)
;;

let create_state ~graph_id ~schema_version ~applied_server_t =
  { graph_id; schema_version; applied_server_t }
;;

let applied_server_t state = state.applied_server_t
let submission_accepted _state ~server_t:_ = ()

let sync_error_of_lg_code = function
  | "unsupported-format" -> Unsupported_format
  | "graph-mismatch" -> Graph_mismatch
  | "schema-mismatch" -> Schema_mismatch
  | "cursor-mismatch" -> Cursor_mismatch
  | "invalid-cursor" -> Invalid_cursor
  | code -> Apply_failed ("Unknown LG sync-state error: " ^ code)
;;

let apply_validated_change_set (state : state) (change : Protocol.sync_change_set) ~apply =
  match
    LG.logseq_chat_sync_state_apply_change_set_error
      state.graph_id
      state.schema_version
      state.applied_server_t
      change.format_version
      change.graph_id
      change.schema_version
      change.t_before
      change.t
  with
  | Some code -> Error (sync_error_of_lg_code code)
  | None ->
    (match apply change with
     | Error message -> Error (Apply_failed message)
     | Ok () ->
       state.applied_server_t <- change.t;
       Ok ())
;;

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when not (String.equal value "") -> Ok value
  | _ -> Error ("snapshot metadata is missing " ^ name)
;;

let non_negative_int_field name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) when value >= 0 -> Ok value
  | _ -> Error ("snapshot metadata is missing " ^ name)
;;

let decode_snapshot_metadata body =
  try
    match Yojson.Basic.from_string body with
    | `Assoc fields ->
      (match List.assoc_opt "ok" fields with
       | Some (`Bool true) ->
         bind (string_field "url" fields) (fun url ->
           bind (non_negative_int_field "t" fields) (fun baseline_t ->
             bind (string_field "schema-version" fields) (fun schema_version ->
               bind (non_negative_int_field "row-count" fields) (fun row_count ->
                 let content_encoding =
                   match List.assoc_opt "content-encoding" fields with
                   | Some (`String value) when not (String.equal value "") -> Some value
                   | Some `Null | None -> None
                   | Some _ -> invalid_arg "snapshot metadata has invalid content-encoding"
                 in
                 Ok { url; content_encoding; baseline_t; schema_version; row_count }))))
       | Some (`Bool false) -> Error "snapshot download is not ready"
       | _ -> Error "snapshot metadata is missing ok")
    | _ -> Error "snapshot metadata must be an object"
  with
  | Yojson.Json_error message -> Error message
  | Invalid_argument message -> Error message
;;

let cleanup_staging active_path =
  let staging_path = Store.logseq_chat_graph_store_staging_path active_path in
  try if Sys.file_exists staging_path then Sys.remove staging_path with
  | _ -> ()
;;

let protected_attr attr =
  String.equal attr "block/title" || String.equal attr "block/name"
;;

let plaintext_snapshot_db decrypt db =
  let rec loop datoms = function
    | [] -> Ok (Datascript.init_db ~schema:db.Datascript.schema (List.rev datoms))
    | datom :: rest when protected_attr datom.Datascript.a ->
      (match datom.v with
       | Datascript.String ciphertext ->
         bind (decrypt ciphertext) (fun plaintext ->
           loop ({ datom with Datascript.v = Datascript.String plaintext } :: datoms) rest)
       | _ -> Error ("protected snapshot attribute " ^ datom.a ^ " must be a string"))
    | datom :: rest -> loop (datom :: datoms) rest
  in
  loop [] (Datascript.datoms db Datascript.Eavt () |> List.of_seq)
;;

let materialize_plaintext_snapshot ~active_path decrypt encrypted_db =
  bind (plaintext_snapshot_db decrypt encrypted_db) (fun plaintext_db ->
    try
      let storage = Store.logseq_chat_graph_store_import_storage active_path in
      Datascript.store ~storage plaintext_db;
      Datascript.collect_garbage storage;
      Ok ()
    with
    | error -> Error ("store local plaintext graph: " ^ Printexc.to_string error))
;;

let import_snapshot_file
      ?decrypt_protected
      ~graph_id
      ~active_path
      ~checkpoint_path
      ~metadata
      ~download_path
      ()
  =
  let parser = Snapshot.logseq_chat_snapshot_create_parser (64 * 1024 * 1024) in
  let import =
    Snapshot.logseq_chat_snapshot_create_import
      graph_id metadata.schema_version metadata.baseline_t metadata.row_count
  in
  let import_rows rows =
    bind (Snapshot.logseq_chat_snapshot_accept_rows import rows) (fun () -> Store.logseq_chat_graph_store_append_rows active_path rows)
  in
  let run () =
    bind (Store.logseq_chat_graph_store_begin_import active_path) (fun () ->
      let channel = open_in_bin download_path in
      let buffer = Bytes.create (256 * 1024) in
      let rec read () =
        match input channel buffer 0 (Bytes.length buffer) with
        | 0 -> Ok ()
        | count ->
          let chunk = Bytes.sub_string buffer 0 count in
          bind (Snapshot.logseq_chat_snapshot_feed parser chunk) (fun rows -> bind (import_rows rows) read)
      in
      let streamed =
        Fun.protect ~finally:(fun () -> close_in_noerr channel) read
      in
      bind streamed (fun () ->
        bind (Snapshot.logseq_chat_snapshot_finish_parser parser) (fun () ->
          bind (Snapshot.logseq_chat_snapshot_finish_import import) (fun completed ->
            bind (Store.logseq_chat_graph_store_restore_db (Store.logseq_chat_graph_store_staging_path active_path)) (fun imported_db ->
              let materialized =
                match decrypt_protected with
                | None -> Ok ()
                | Some decrypt ->
                  materialize_plaintext_snapshot ~active_path decrypt imported_db
              in
              bind materialized (fun () ->
                bind
                  (Store.logseq_chat_graph_store_restore_db (Store.logseq_chat_graph_store_staging_path active_path))
                  (fun _validated_db ->
                    bind (Store.logseq_chat_graph_store_activate active_path) (fun () ->
                  let checkpoint =
                    create_checkpoint
                      ~graph_id
                      ~schema_version:metadata.schema_version
                      ~applied_server_t:metadata.baseline_t
                  in
                  bind (save_checkpoint_atomic checkpoint_path checkpoint) (fun () ->
                    Ok completed)))))))))
  in
  try
    match run () with
    | Ok _ as result -> result
    | Error _ as error ->
      cleanup_staging active_path;
      error
  with
  | error ->
    cleanup_staging active_path;
    Error ("import graph snapshot: " ^ Printexc.to_string error)
;;

let apply_change_set
      ?(decrypt_protected = fun value -> Ok value)
      ~conn
      ~checkpoint_path
      state
      change
  =
  apply_validated_change_set
    state
    change
    ~apply:(fun change ->
      bind
        (Logseq_chat_lg_core_native.logseq_chat_entity_sync_apply_change_set
           decrypt_protected
           conn
           change)
        (fun () ->
        let checkpoint =
          create_checkpoint
            ~graph_id:change.graph_id
            ~schema_version:change.schema_version
            ~applied_server_t:change.t
        in
          save_checkpoint_atomic checkpoint_path checkpoint))
  |> Result.map_error (function
    | Unsupported_format -> "unsupported sync format"
    | Graph_mismatch -> "sync graph mismatch"
    | Schema_mismatch -> "sync schema mismatch"
    | Cursor_mismatch -> "sync cursor mismatch"
    | Invalid_cursor -> "invalid sync cursor"
    | Apply_failed message -> message)
;;
