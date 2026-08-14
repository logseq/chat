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

let import_snapshot_file
      ~graph_id
      ~active_path
      ~checkpoint_path
      ~metadata
      ~download_path
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
                    Ok completed)))))))
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
