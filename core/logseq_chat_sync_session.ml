module Snapshot = Logseq_chat_snapshot
module Store = Logseq_chat_graph_store
module Checkpoint = Logseq_chat_sync_checkpoint

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
  let staging_path = Store.staging_path active_path in
  try if Sys.file_exists staging_path then Sys.remove staging_path with
  | _ -> ()
;;

let protected_attr attr =
  String.equal attr "block/title" || String.equal attr "block/name"
;;

let plaintext_snapshot_db decrypt db =
  let built_in_entities = Hashtbl.create 128 in
  Datascript.datoms db Datascript.Aevt ~a:"block/uuid" ()
  |> Seq.iter (fun datom ->
    match datom.Datascript.v with
    | Datascript.Uuid uuid
      when String.starts_with ~prefix:"00000002-" uuid
           || String.starts_with ~prefix:"00000004-" uuid ->
      Hashtbl.replace built_in_entities datom.e ()
    | _ -> ());
  Datascript.datoms db Datascript.Aevt ~a:"logseq.property/built-in?" ()
  |> Seq.iter (fun datom ->
    match datom.Datascript.v with
    | Datascript.Bool true -> Hashtbl.replace built_in_entities datom.e ()
    | _ -> ());
  let rec loop datoms = function
    | [] -> Ok (Datascript.init_db ~schema:db.Datascript.schema (List.rev datoms))
    | datom :: rest
      when protected_attr datom.Datascript.a
           && not (Hashtbl.mem built_in_entities datom.e) ->
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
      let storage = Store.import_storage ~active_path in
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
  let parser = Snapshot.create_parser ~max_frame_bytes:(64 * 1024 * 1024) in
  let import =
    Snapshot.create_import
      ~graph_id
      ~schema_version:metadata.schema_version
      ~baseline_t:metadata.baseline_t
      ~expected_rows:metadata.row_count
  in
  let import_rows rows =
    bind (Snapshot.accept_rows import rows) (fun () -> Store.append_rows ~active_path rows)
  in
  let run () =
    bind (Store.begin_import ~active_path) (fun () ->
      let channel = open_in_bin download_path in
      let buffer = Bytes.create (256 * 1024) in
      let rec read () =
        match input channel buffer 0 (Bytes.length buffer) with
        | 0 -> Ok ()
        | count ->
          let chunk = Bytes.sub_string buffer 0 count in
          bind (Snapshot.feed parser chunk) (fun rows -> bind (import_rows rows) read)
      in
      let streamed =
        Fun.protect ~finally:(fun () -> close_in_noerr channel) read
      in
      bind streamed (fun () ->
        bind (Snapshot.finish_parser parser) (fun () ->
          bind (Snapshot.finish_import import) (fun completed ->
            bind (Store.restore_db ~path:(Store.staging_path active_path)) (fun imported_db ->
              let materialized =
                match decrypt_protected with
                | None -> Ok ()
                | Some decrypt ->
                  materialize_plaintext_snapshot ~active_path decrypt imported_db
              in
              bind materialized (fun () ->
                bind
                  (Store.restore_db ~path:(Store.staging_path active_path))
                  (fun _validated_db ->
                    bind (Store.activate ~active_path) (fun () ->
                  let checkpoint =
                    Checkpoint.create
                      ~graph_id
                      ~schema_version:metadata.schema_version
                      ~applied_server_t:metadata.baseline_t
                  in
                  bind (Checkpoint.save_atomic checkpoint_path checkpoint) (fun () ->
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
  Logseq_chat_sync_state.apply_change_set
    state
    change
    ~apply:(fun change ->
      bind
        (Logseq_chat_entity_sync.apply_change_set ~decrypt_protected conn change)
        (fun () ->
        let checkpoint =
          Checkpoint.create
            ~graph_id:change.Logseq_chat_sync_protocol.graph_id
            ~schema_version:change.schema_version
            ~applied_server_t:change.t
        in
          Checkpoint.save_atomic checkpoint_path checkpoint))
  |> Result.map_error (function
    | Logseq_chat_sync_state.Unsupported_format -> "unsupported sync format"
    | Graph_mismatch -> "sync graph mismatch"
    | Schema_mismatch -> "sync schema mismatch"
    | Cursor_mismatch -> "sync cursor mismatch"
    | Invalid_cursor -> "invalid sync cursor"
    | Apply_failed message -> message)
;;
