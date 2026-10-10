let change graph schema t_before t =
  { Sync_protocol.format_version = 1;
    graph_id = graph;
    schema_version = schema;
    t_before;
    t;
    upserts = [];
    deleted = [];
    operation_ids = [] }

let only_successful_websocket_application_advances_cursor () =
  let state = Sync_session.create_state "graph-1" "65.33" 10 in
  let applied = ref false in
  Sync_session.submission_accepted state 11;
  Test_util.check_eq (Sync_session.applied_server_t state) 10;
  Test_util.check_eq
    (Sync_session.apply_validated_change_set state
       (change "graph-1" "65.33" 10 11)
       (fun _ ->
          applied := true;
          Ok ()))
    (Ok ());
  Test_util.check !applied;
  Test_util.check_eq (Sync_session.applied_server_t state) 11

let invalid_events_never_reach_database () =
  let state = Sync_session.create_state "graph-1" "65.33" 20 in
  List.iter
    (fun (expected, event) ->
       Test_util.check_eq
         (Sync_session.apply_validated_change_set state event (fun _ ->
            Alcotest.fail "invalid event reached database"))
         (Error expected);
       Test_util.check_eq (Sync_session.applied_server_t state) 20)
    [
      ( Sync_session.Cursor_mismatch,
        change "graph-1" "65.33" 19 21 );
      ( Sync_session.Graph_mismatch,
        change "graph-2" "65.33" 20 21 );
      ( Sync_session.Schema_mismatch,
        change "graph-1" "66" 20 21 );
      ( Sync_session.Unsupported_format,
        { (change "graph-1" "65.33" 20 21) with format_version = 2 } );
      ( Sync_session.Invalid_cursor,
        change "graph-1" "65.33" 20 19 );
    ]

let failed_application_preserves_error_and_cursor () =
  let state = Sync_session.create_state "graph-1" "65.33" 20 in
  Test_util.check_eq
    (Sync_session.apply_validated_change_set state
       (change "graph-1" "65.33" 20 21)
       (fun _ -> Error "checkpoint unavailable"))
    (Error (Sync_session.Apply_failed "checkpoint unavailable"));
  Test_util.check_eq (Sync_session.applied_server_t state) 20

let cases =
  [ Test_util.case "only successful websocket application advances cursor"
      only_successful_websocket_application_advances_cursor;
    Test_util.case "invalid events never reach database"
      invalid_events_never_reach_database;
    Test_util.case "failed application preserves error and cursor"
      failed_application_preserves_error_and_cursor ]
