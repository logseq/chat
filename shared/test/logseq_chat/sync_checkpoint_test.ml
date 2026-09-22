module Value = Transit_core.Json

let decode_fields fields =
  Sync_checkpoint.decode_map
    (List.map (fun (key, value) -> (Value.Keyword key, value)) fields)

let replace_assoc key value fields =
  (key, value) :: List.remove_assoc key fields

let checkpoint_validates_every_required_field () =
  let fields =
    [ "format-version", Value.Int 1;
      "graph-id", Value.String "graph";
      "schema-version", Value.String "1";
      "applied-server-t", Value.Int 0 ]
  in
  let invalid = Error "invalid graph sync checkpoint" in
  Test_util.check_eq (decode_fields fields)
    (Ok (Sync_checkpoint.create "graph" "1" 0));
  List.iter
    (fun (field, _) ->
       Test_util.check_eq
         (decode_fields (List.remove_assoc field fields))
         invalid;
       Test_util.check_eq
         (decode_fields
            (replace_assoc field (Value.Bool false) fields))
         invalid)
    fields;
  Test_util.check_eq
    (decode_fields
       (replace_assoc "format-version" (Value.Int 2) fields))
    invalid;
  Test_util.check_eq
    (decode_fields
       (replace_assoc "applied-server-t" (Value.Int (-1)) fields))
    invalid

let remove_file path =
  if Sys.file_exists path then Sys.remove path

let checkpoint_persists_privately_and_roundtrips () =
  let path = Filename.temp_file "logseq-chat-sync-checkpoint" ".transit" in
  Sys.remove path;
  Fun.protect
    ~finally:(fun () ->
       remove_file path;
       remove_file (path ^ ".tmp"))
    (fun () ->
       Test_util.check_eq (Sync_checkpoint.load_checkpoint path)
         (Ok None);
       (match
          Sync_checkpoint.save_checkpoint_atomic path
            (Sync_checkpoint.create "graph-1" "65.33" 48192)
        with
        | Ok () -> ()
        | Error message -> Alcotest.fail message);
       Test_util.check
         ~msg:"checkpoint must be private"
         ((Unix.stat path).st_perm land 63 = 0);
       match Sync_checkpoint.load_checkpoint path with
       | Ok (Some restored) ->
         Test_util.check_eq restored.graph_id "graph-1";
         Test_util.check_eq restored.schema_version "65.33";
         Test_util.check_eq restored.applied_server_t 48192
       | _ -> Alcotest.fail "checkpoint disappeared or failed to load")

let failed_save_preserves_directory_and_removes_temporary_file () =
  let path = Filename.temp_file "logseq-chat-checkpoint-directory" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () ->
       remove_file (path ^ ".tmp");
       Unix.rmdir path)
    (fun () ->
       (match
          Sync_checkpoint.save_checkpoint_atomic path
            (Sync_checkpoint.create "graph" "1" 0)
        with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "checkpoint replaced a directory");
       Test_util.check ~msg:"temporary file left behind"
         (not (Sys.file_exists (path ^ ".tmp"))))

let cases =
  [ Test_util.case "checkpoint validates every required field"
      checkpoint_validates_every_required_field;
    Test_util.case "checkpoint persists privately and roundtrips"
      checkpoint_persists_privately_and_roundtrips;
    Test_util.case "failed save preserves directory and removes temporary file"
      failed_save_preserves_directory_and_removes_temporary_file ]
