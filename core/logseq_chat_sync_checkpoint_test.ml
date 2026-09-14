module Checkpoint = Logseq_chat_sync_session

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
      (match Checkpoint.load_checkpoint path with
       | Ok None -> ()
       | Ok (Some _) -> fail "missing checkpoint" "unexpected value"
       | Error message -> fail "missing checkpoint" message);
      let checkpoint =
        Checkpoint.create_checkpoint
          ~graph_id:"graph-1"
          ~schema_version:"65.33"
          ~applied_server_t:48192
      in
      (match Checkpoint.save_checkpoint_atomic path checkpoint with
       | Ok () -> ()
       | Error message -> fail "save" message);
      match Checkpoint.load_checkpoint path with
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
