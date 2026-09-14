let fail label message = failwith (label ^ ": " ^ message)

let () =
  let path = Filename.temp_file "logseq-chat-sync-checkpoint" ".transit" in
  Sys.remove path;
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path;
      let temporary = path ^ ".tmp" in
      if Sys.file_exists temporary then Sys.remove temporary)
    (fun () ->
      (match Logseq_chat_lg_core_native.logseq_chat_sync_checkpoint_load_checkpoint path with
       | Ok None -> ()
       | Ok (Some _) -> fail "missing checkpoint" "unexpected value"
       | Error message -> fail "missing checkpoint" message);
      let checkpoint =
        Logseq_chat_lg_core_native.logseq_chat_sync_checkpoint_create
          "graph-1" "65.33" 48192
      in
      (match Logseq_chat_lg_core_native.logseq_chat_sync_checkpoint_save_checkpoint_atomic path checkpoint with
       | Ok () -> ()
       | Error message -> fail "save" message);
      if (Unix.stat path).st_perm land 0o077 <> 0 then
        fail "checkpoint permissions" "checkpoint is accessible to other users";
      match Logseq_chat_lg_core_native.logseq_chat_sync_checkpoint_load_checkpoint path with
      | Ok (Some restored) ->
        if not (String.equal restored.graph_id "graph-1")
        then fail "graph id" "changed after persistence";
        if not (String.equal restored.schema_version "65.33")
        then fail "schema version" "changed after persistence";
        if restored.applied_server_t <> 48192
        then fail "cursor" "changed after persistence"
      | Ok None -> fail "load" "checkpoint disappeared"
      | Error message -> fail "load" message)
;;

let () =
  let path = Filename.temp_file "logseq-chat-checkpoint-directory" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () ->
    if Sys.file_exists (path ^ ".tmp") then Sys.remove (path ^ ".tmp");
    Unix.rmdir path)
    (fun () ->
      let checkpoint = Logseq_chat_lg_core_native.logseq_chat_sync_checkpoint_create "graph" "1" 0 in
      (match Logseq_chat_lg_core_native.logseq_chat_sync_checkpoint_save_checkpoint_atomic path checkpoint with
       | Error _ -> ()
       | Ok () -> fail "checkpoint failure" "replaced a directory");
      if Sys.file_exists (path ^ ".tmp") then fail "checkpoint failure" "temporary file leaked")
;;
