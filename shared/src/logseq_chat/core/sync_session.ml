module Json = Yojson.Basic
module Json_util = Yojson.Basic.Util
module Checkpoint = Sync_checkpoint
module Sync_state = Sync_state
module Snapshot = Snapshot
module Store = Graph_store
module Entity_sync = Entity_sync
module Ds = Datascript

type sync_session_state =
  { graph_id : string
  ; schema_version : string
  ; applied_server_t : int ref
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

let create_state graph_id schema_version applied_server_t =
  { graph_id; schema_version; applied_server_t = ref applied_server_t }

let applied_server_t state = !(state.applied_server_t)

let submission_accepted _state _server_t = ()

let sync_error_of_code code =
  match code with
  | "unsupported-format" -> Unsupported_format
  | "graph-mismatch" -> Graph_mismatch
  | "schema-mismatch" -> Schema_mismatch
  | "cursor-mismatch" -> Cursor_mismatch
  | "invalid-cursor" -> Invalid_cursor
  | _ -> Apply_failed ("Unknown LG sync-state error: " ^ code)

let apply_validated_change_set state
    (change : Sync_protocol.sync_change_set) apply =
  match
    Sync_state.apply_change_set_error state.graph_id
      state.schema_version (applied_server_t state) change.format_version
      change.graph_id change.schema_version change.t_before change.t
  with
  | Some code -> Error (sync_error_of_code code)
  | None ->
    (match apply change with
     | Error message -> Error (Apply_failed message)
     | Ok () ->
       state.applied_server_t := change.t;
       Ok ())

let string_field name input =
  match Json_util.member name input with
  | `String value when value <> "" -> Ok value
  | _ -> Error ("snapshot metadata is missing " ^ name)

let non_negative_int_field name input =
  match Json_util.member name input with
  | `Int value when value >= 0 -> Ok value
  | _ -> Error ("snapshot metadata is missing " ^ name)

let decode_snapshot_metadata body =
  try
    let input = Json.from_string body in
    match input with
    | `Assoc _ ->
      (match Json_util.member "ok" input with
       | `Bool true ->
         let ( let* ) = Result.bind in
         let* url = string_field "url" input in
         let* baseline_t = non_negative_int_field "t" input in
         let* schema_version = string_field "schema-version" input in
         let* row_count = non_negative_int_field "row-count" input in
         let encoding =
           match Json_util.member "content-encoding" input with
           | `String value ->
             if value = "" then
               invalid_arg
                 "snapshot metadata has invalid content-encoding"
             else Some value
           | `Null -> None
           | _ ->
             invalid_arg
               "snapshot metadata has invalid content-encoding"
         in
         Ok
           {
             url;
             content_encoding = encoding;
             baseline_t;
             schema_version;
             row_count;
           }
       | `Bool false -> Error "snapshot download is not ready"
       | _ -> Error "snapshot metadata is missing ok")
    | _ -> Error "snapshot metadata must be an object"
  with
  | Yojson.Json_error message -> Error message
  | Invalid_argument message -> Error message

let cleanup_staging active_path =
  try
    let path = Store.staging_path active_path in
    if Sys.file_exists path then Sys.remove path
  with _ -> ()

let plaintext_datom decrypt (datom : Ds.datom) =
  let ( let* ) = Result.bind in
  if Entity_sync.protected_attr datom.a then
    match datom.v with
    | Ds.String ciphertext ->
      let* value = decrypt ciphertext in
      Ok { datom with Ds.v = Ds.String value }
    | _ ->
      Error
        ("protected snapshot attribute " ^ datom.a ^ " must be a string")
  else Ok datom

let plaintext_snapshot_db decrypt db =
  let rec loop remaining plaintext =
    let ( let* ) = Result.bind in
    match remaining () with
    | Seq.Cons (datom, rest) ->
      let* datom = plaintext_datom decrypt datom in
      loop rest (datom :: plaintext)
    | Seq.Nil -> Ok (Ds.init_db ~schema:(Ds.schema db) (List.rev plaintext))
  in
  loop (Ds.Db.datoms db Ds.Eavt ()) []

let materialize_plaintext_snapshot active_path decrypt encrypted_db =
  let ( let* ) = Result.bind in
  let* db = plaintext_snapshot_db decrypt encrypted_db in
  try
    let storage = Store.import_storage active_path in
    Ds.store ~storage db;
    Ds.collect_garbage storage;
    Ok ()
  with error ->
    Error ("store local plaintext graph: " ^ Printexc.to_string error)

let stream_snapshot active_path download_path parser import =
  let channel = open_in_bin download_path in
  let buffer = Bytes.create (256 * 1024) in
  let ( let* ) = Result.bind in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let rec loop () =
        let count = input channel buffer 0 (Bytes.length buffer) in
        if count = 0 then Ok ()
        else begin
          let* rows =
            Snapshot.feed parser (Bytes.sub_string buffer 0 count)
          in
          let* () = Snapshot.accept_rows import rows in
          let* () = Store.append_rows active_path rows in
          loop ()
        end
      in
      loop ())

let import_snapshot decrypt graph_id active_path checkpoint_path metadata
    download_path =
  let parser = Snapshot.create_parser (64 * 1024 * 1024) in
  let import =
    Snapshot.create_import graph_id metadata.schema_version
      metadata.baseline_t metadata.row_count
  in
  let ( let* ) = Result.bind in
  let* () = Store.begin_import active_path in
  let* () = stream_snapshot active_path download_path parser import in
  let* () = Snapshot.finish_parser parser in
  let* completed = Snapshot.finish_import import in
  let* db = Store.restore_db (Store.staging_path active_path) in
  let* () =
    match decrypt with
    | Some decrypt ->
      materialize_plaintext_snapshot active_path decrypt db
    | None -> Ok ()
  in
  let* _ = Store.restore_db (Store.staging_path active_path) in
  let* () = Store.activate active_path in
  let* () =
    Checkpoint.save_checkpoint_atomic checkpoint_path
      (Checkpoint.create graph_id metadata.schema_version
         metadata.baseline_t)
  in
  Ok completed

let import_snapshot_file decrypt graph_id active_path checkpoint_path
    metadata download_path =
  try
    match
      import_snapshot decrypt graph_id active_path checkpoint_path
        metadata download_path
    with
    | Ok completed -> Ok completed
    | Error message ->
      cleanup_staging active_path;
      Error message
  with error ->
    cleanup_staging active_path;
    Error ("import graph snapshot: " ^ Printexc.to_string error)

let error_message error =
  match error with
  | Unsupported_format -> "unsupported sync format"
  | Graph_mismatch -> "sync graph mismatch"
  | Schema_mismatch -> "sync schema mismatch"
  | Cursor_mismatch -> "sync cursor mismatch"
  | Invalid_cursor -> "invalid sync cursor"
  | Apply_failed message -> message

let apply_change_set decrypt conn checkpoint_path state change =
  match
    apply_validated_change_set state change (fun change ->
        let ( let* ) = Result.bind in
        let* () = Entity_sync.apply_change_set decrypt conn change in
        Checkpoint.save_checkpoint_atomic checkpoint_path
          (Checkpoint.create change.Sync_protocol.graph_id
             change.schema_version change.t))
  with
  | Ok () -> Ok ()
  | Error error -> Error (error_message error)
