let change ~graph_id ~schema_version ~t_before ~t =
  { Logseq_chat_lg_core_native.format_version = 1
  ; graph_id
  ; schema_version
  ; t_before
  ; t
  ; upserts = []
  ; deleted = []
  ; operation_ids = []
  }
;;

let () =
  let state =
    Logseq_chat_lg_core_native.logseq_chat_sync_session_create_state
      "graph-1" "65.33" 10
  in
  Logseq_chat_lg_core_native.logseq_chat_sync_session_submission_accepted state 11;
  if Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state <> 10
  then failwith "HTTP acknowledgement must not advance the applied WebSocket cursor";
  let applied = ref false in
  (match
     Logseq_chat_lg_core_native.logseq_chat_sync_session_apply_validated_change_set
       state
       (change ~graph_id:"graph-1" ~schema_version:"65.33" ~t_before:10 ~t:11)
       (fun _ ->
         applied := true;
         Ok ())
   with
   | Ok () -> ()
   | Error _ -> failwith "valid change set was rejected");
  if not !applied then failwith "change set was not applied";
  if Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state <> 11
  then failwith "successful WebSocket application must advance the cursor"
;;

let () =
  let state =
    Logseq_chat_lg_core_native.logseq_chat_sync_session_create_state
      "graph-1" "65.33" 20
  in
  let never_apply _ = failwith "invalid event reached the database callback" in
  let reject expected change =
    match Logseq_chat_lg_core_native.logseq_chat_sync_session_apply_validated_change_set state change never_apply with
    | Error actual when actual = expected -> ()
    | _ -> failwith "invalid change set produced the wrong result"
  in
  reject
    Logseq_chat_lg_core_native.Cursor_mismatch
    (change ~graph_id:"graph-1" ~schema_version:"65.33" ~t_before:19 ~t:21);
  reject
    Logseq_chat_lg_core_native.Graph_mismatch
    (change ~graph_id:"graph-2" ~schema_version:"65.33" ~t_before:20 ~t:21);
  reject
    Logseq_chat_lg_core_native.Schema_mismatch
    (change ~graph_id:"graph-1" ~schema_version:"66" ~t_before:20 ~t:21)
;;

let () =
  let state = Logseq_chat_lg_core_native.logseq_chat_sync_session_create_state
    "graph-1" "65.33" 20 in
  let event = change ~graph_id:"graph-1" ~schema_version:"65.33" ~t_before:20 ~t:21 in
  (match Logseq_chat_lg_core_native.logseq_chat_sync_session_apply_validated_change_set state event
           (fun _ -> Error "checkpoint unavailable") with
   | Error (Logseq_chat_lg_core_native.Apply_failed "checkpoint unavailable") -> ()
   | _ -> failwith "callback error was not preserved");
  if Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state <> 20 then
    failwith "failed callback advanced sync cursor"
;;
