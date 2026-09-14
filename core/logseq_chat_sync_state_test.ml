let change ~graph_id ~schema_version ~t_before ~t =
  { Logseq_chat_sync_protocol.format_version = 1
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
    Logseq_chat_sync_session.create_state
      ~graph_id:"graph-1"
      ~schema_version:"65.33"
      ~applied_server_t:10
  in
  Logseq_chat_sync_session.submission_accepted state ~server_t:11;
  if Logseq_chat_sync_session.applied_server_t state <> 10
  then failwith "HTTP acknowledgement must not advance the applied WebSocket cursor";
  let applied = ref false in
  (match
     Logseq_chat_sync_session.apply_validated_change_set
       state
       (change ~graph_id:"graph-1" ~schema_version:"65.33" ~t_before:10 ~t:11)
       ~apply:(fun _ ->
         applied := true;
         Ok ())
   with
   | Ok () -> ()
   | Error _ -> failwith "valid change set was rejected");
  if not !applied then failwith "change set was not applied";
  if Logseq_chat_sync_session.applied_server_t state <> 11
  then failwith "successful WebSocket application must advance the cursor"
;;

let () =
  let state =
    Logseq_chat_sync_session.create_state
      ~graph_id:"graph-1"
      ~schema_version:"65.33"
      ~applied_server_t:20
  in
  let never_apply _ = failwith "invalid event reached the database callback" in
  let reject expected change =
    match Logseq_chat_sync_session.apply_validated_change_set state change ~apply:never_apply with
    | Error actual when actual = expected -> ()
    | _ -> failwith "invalid change set produced the wrong result"
  in
  reject
    Logseq_chat_sync_session.Cursor_mismatch
    (change ~graph_id:"graph-1" ~schema_version:"65.33" ~t_before:19 ~t:21);
  reject
    Logseq_chat_sync_session.Graph_mismatch
    (change ~graph_id:"graph-2" ~schema_version:"65.33" ~t_before:20 ~t:21);
  reject
    Logseq_chat_sync_session.Schema_mismatch
    (change ~graph_id:"graph-1" ~schema_version:"66" ~t_before:20 ~t:21)
;;
