open Yojson.Basic

module LG = Logseq_chat_lg_core_native

let assoc name fields = List.assoc_opt name fields

let required_assoc name fields =
  match assoc name fields with
  | Some (`Assoc value) -> value
  | _ -> failwith ("missing object field: " ^ name)
;;

let required_list name fields =
  match assoc name fields with
  | Some (`List value) -> value
  | _ -> failwith ("missing list field: " ^ name)
;;

let required_string name fields =
  match assoc name fields with
  | Some (`String value) -> value
  | _ -> failwith ("missing string field: " ^ name)
;;

let required_int name fields =
  match assoc name fields with
  | Some (`Int value) -> value
  | _ -> failwith ("missing int field: " ^ name)
;;

let required_bool name fields =
  match assoc name fields with
  | Some (`Bool value) -> value
  | _ -> failwith ("missing bool field: " ^ name)
;;

let assert_equal label expected actual =
  if not (String.equal expected actual)
  then
    failwith
      (Printf.sprintf "%s: expected %S, got %S" label expected actual)
;;

let assert_int_equal label expected actual =
  if expected <> actual
  then
    failwith
      (Printf.sprintf "%s: expected %d, got %d" label expected actual)
;;



let plain_graph_catalog =
  {|{"graphs":[{"graph-id":"plain-1","graph-name":"Plain","graph-e2ee?":false,"graph-ready-for-use?":true}]}|}
;;

let configure_plain_graph session =
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"configure","payload":"{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}"}}|})
;;


let pending_request response =
  match from_string response with
  | `Assoc fields ->
    let result = required_assoc "result" fields in
    (match assoc "pendingSyncRequest" result with
     | Some (`Assoc request) -> Some request
     | Some `Null | None -> None
     | Some _ -> failwith "pendingSyncRequest must be an object or null")
  | _ -> failwith "pending sync should return an RPC response"
;;








let remote_block uuid title =
  Logseq_chat_lg_core_native.
    { uuid
    ; title
    ; page_id = "page"
    ; parent_id = Some "page"
    ; order = Some "a0"
    ; created_at = 1
    ; updated_at = 1
    ; sync_status = "synced"
    ; tags = []
    ; references = []
    ; breadcrumbs = []
    ; status = None
    ; is_asset = false
    ; asset_type = None
    ; asset_size = None
    ; asset_checksum = None
    ; local_path = None
    ; journal = None
    }
;;



let prepare_test_operation operation =
  Ok
    ( (Logseq_chat_lg_core_native.logseq_chat_pending_ops_outliner_op
         operation.Logseq_chat_lg_core_native.intent)
    , "[]" )
;;



let dispatch_outliner session payload =
  let request =
    `Assoc
      [ "apiVersion", `Int 1
      ; "method", `String "dispatch"
      ; ( "params"
        , `Assoc
            [ "action", `String "outlinerEvent"
            ; "payload", `String (to_string payload)
            ] )
      ]
    |> to_string
  in
  match Logseq_chat_rpc.call session request |> from_string with
  | `Assoc fields when required_bool "ok" fields -> required_assoc "result" fields
  | `Assoc fields ->
    let error = required_assoc "error" fields in
    failwith ("outliner event failed: " ^ required_string "message" error)
  | _ -> failwith "outliner event should return an RPC response"
;;









let () =
  let graph_a_model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let graph_b_model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let session =
    Logseq_chat_rpc.create
      ~open_graph:(fun _ -> Ok ())
      ~model_for_graph:(fun ~graph_id ->
        if String.equal graph_id "graph-a" then graph_a_model else graph_b_model)
      ()
  in
  let open_graph graph_id =
    let payload =
      Yojson.Basic.to_string
        (`Assoc
          [ "graphId", `String graph_id
          ; "activePath", `String ("/graphs/" ^ graph_id ^ "/graph.sqlite")
          ; "checkpointPath", `String ("/graphs/" ^ graph_id ^ "/sync.checkpoint")
          ])
    in
    let request =
      Yojson.Basic.to_string
        (`Assoc
          [ "apiVersion", `Int 1
          ; "method", `String "dispatch"
          ; ( "params"
            , `Assoc [ "action", `String "openGraph"; "payload", `String payload ] )
          ])
    in
    ignore (Logseq_chat_rpc.call session request)
  in
  open_graph "graph-a";
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"graph-a-asset\",\"title\":\"photo.jpg\",\"now\":1,\"assetType\":\"jpg\",\"assetSize\":4,\"assetChecksum\":\"abcd\",\"localPath\":\"Assets/photo.jpg\"}"}}|});
  if List.length (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (session.model))) <> 1
  then failwith "graph A should contain its pending asset";
  open_graph "graph-b";
  if (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (session.model))) <> []
  then failwith "graph B must not inherit graph A's optimistic projection";
  open_graph "graph-a";
  if List.length (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (session.model))) <> 1
  then failwith "switching back should restore graph A's optimistic projection"
;;


let () =
  let parent = remote_block "parent" "Parent" in
  let child = { (remote_block "child" "Child") with Logseq_chat_lg_core_native.parent_id = Some "parent" } in
  let staged = ref [] in
  let session = Logseq_chat_rpc.create
    ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
    ~sync_cursor:(fun () -> Some 92)
    ~graph_blocks:(fun () -> Some [parent; child])
    ~stage_operation:(fun operation -> staged := operation :: !staged; Ok ())
    ~prepare_operation:prepare_test_operation () in
  configure_plain_graph session;
  ignore (dispatch_outliner session (`Assoc ["type", `String "tapBlock"; "uuid", `String "parent"]));
  ignore (dispatch_outliner session (`Assoc ["type", `String "textChanged"; "title", `String "Changed parent"; "caretUTF16Offset", `Int 14]));
  let collapsed = dispatch_outliner session (`Assoc ["type", `String "toggleCollapsed"; "uuid", `String "parent"]) in
  if List.assoc_opt "editing" (required_assoc "outlinerState" collapsed) <> Some `Null
  then failwith "collapse must finish the active editor";
  if required_list "outlinerRowSplices" collapsed = []
  then failwith "collapse after editing must remove child rows as well as saving the title";
  if List.length !staged <> 1 then failwith "collapse saves the pending title exactly once"
;;

let () =
  let staged = ref [] in
  let session = Logseq_chat_rpc.create
    ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
    ~sync_cursor:(fun () -> Some 92)
    ~graph_blocks:(fun () -> Some [remote_block "editing" "Original"])
    ~stage_operation:(fun operation -> staged := operation :: !staged; Ok ())
    ~prepare_operation:prepare_test_operation () in
  configure_plain_graph session;
  ignore (dispatch_outliner session (`Assoc ["type", `String "tapBlock"; "uuid", `String "editing"]));
  ignore (dispatch_outliner session (`Assoc ["type", `String "textChanged"; "title", `String "Draft [[Novel]]"; "caretUTF16Offset", `Int 13]));
  let result = dispatch_outliner session (`Assoc ["type", `String "chooseAutocomplete"; "value", `String "Novel"]) in
  let editing = required_assoc "editing" (required_assoc "outlinerState" result) in
  assert_equal "new page keeps paired reference in the draft" "Draft [[Novel]]" (required_string "title" editing);
  match !staged with
  | [operation] ->
    (match (Logseq_chat_lg_core_native.logseq_chat_pending_ops_intent_json
              operation.intent) with
     | `Assoc fields -> assert_equal "new page stages creation without saving the block" "create-page" (required_string "type" fields)
     | _ -> failwith "new page operation must be serializable")
  | _ -> failwith "choosing New page must create exactly one real page without saving the draft"
;;

let () =
  let live = ref (remote_block "source" "Original") in
  let session = Logseq_chat_rpc.create
    ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
    ~sync_cursor:(fun () -> Some 92)
    ~graph_blocks:(fun () -> Some [!live])
    ~stage_operation:(fun operation ->
        (match operation.Logseq_chat_lg_core_native.intent with
       | Save_title { title; _ } ->
         live := { !live with title; references = [{ uuid = "target"; title = "New page" }] }
       | _ -> ());
      Ok ())
    ~prepare_operation:prepare_test_operation () in
  configure_plain_graph session;
  ignore (dispatch_outliner session (`Assoc ["type", `String "tapBlock"; "uuid", `String "source"]));
  ignore (dispatch_outliner session (`Assoc ["type", `String "textChanged"; "title", `String "See [[target]]"; "caretUTF16Offset", `Int 14]));
  let result = dispatch_outliner session (`Assoc ["type", `String "saveEditing"]) in
  let rec has_reference = function
    | `Assoc fields ->
      List.assoc_opt "type" fields = Some (`String "nodeReference")
      || List.exists (fun (_, value) -> has_reference value) fields
    | `List values -> List.exists has_reference values
    | _ -> false in
  if not (has_reference (`Assoc result))
  then failwith "save patch must immediately render newly staged reference metadata"
;;

let () =
  (* Exercise the host-visible cursor used by entity/pull while several asset
     uploads and metadata acknowledgements run ahead of WebSocket replay. *)
  List.iter (fun timing ->
    let replay_first = timing = 1 in
    let deferred_replay = timing = 2 in
    let state = Logseq_chat_lg_core_native.logseq_chat_sync_session_create_state
        "plain-1" "65.33" 42 in
    let attribute =
      { Datascript.cardinality = One; unique = Some Identity; indexed = true;
        is_component = false; no_history = false; doc = None;
        value_type = Some UuidType; tuple_attrs = None; tuple_types = None } in
    let conn = Datascript.create_conn ~schema:["block/uuid", attribute] () in
    let applied_count = ref 0 in
    let session = Logseq_chat_rpc.create
        ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
        ~sync_cursor:(fun () -> Some (Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state))
        ~graph_blocks:(fun () -> Some [])
        ~journal_page_id:(fun ~journal_day:_ -> Some "journal-page")
        ~stage_operation:(fun _ -> Ok ())
        ~prepare_operation:prepare_test_operation
        ~apply_sync_event:(fun payload ->
          let fields = from_string payload |> function `Assoc fields -> fields | _ -> assert false in
          let change : Logseq_chat_lg_core_native.sync_change_set = { format_version = 1;
            graph_id = "plain-1"; schema_version = "65.33";
            t_before = required_int "before" fields; t = required_int "t" fields;
            upserts = List.init (required_int "t" fields - required_int "before" fields)
              (fun offset ->
                let module V = Transit_core.Json in
                let index = required_int "before" fields - 42 + offset + 1 in
                let uuid = Printf.sprintf "00000000-0000-4000-8000-%012d" index in
                { Logseq_chat_lg_core_native.id = V.Array [V.Keyword "block/uuid"; V.Uuid uuid];
                  attrs = [V.Keyword "block/uuid", V.Uuid uuid;
                           V.Keyword "block/title", V.String "photo.jpg"] });
            deleted = []; operation_ids = [] } in
          Logseq_chat_lg_core_native.logseq_chat_sync_session_apply_validated_change_set state change
            (fun change ->
              Logseq_chat_lg_core_native.logseq_chat_entity_sync_apply_change_set
                (fun value -> Ok value)
                conn
                change
              |> Result.map (fun () -> incr applied_count))
          |> Result.map_error (fun _ -> "sync cursor mismatch")) () in
    let dispatch action payload =
      let params = ["action", `String action] @
        (match payload with None -> [] | Some value -> ["payload", `String (to_string value)]) in
      Logseq_chat_rpc.call session
        (to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
                           "params", `Assoc params])) in
    let result response = match from_string response with
      | `Assoc fields when assoc "ok" fields = Some (`Bool true) -> required_assoc "result" fields
      | _ -> failwith ("multi-asset dispatch failed: " ^ response) in
    let complete request body = dispatch "completePendingSync" (Some (`Assoc
      ["id", `Int (required_int "id" request); "status", `Int 200;
       "body", `String (to_string body); "error", `Null])) in
    configure_plain_graph session;
    for index = 1 to 3 do
      ignore (dispatch "addAsset" (Some (`Assoc [
        "uuid", `String (Printf.sprintf "00000000-0000-4000-8000-%012d" index);
        "title", `String "photo.jpg"; "now", `Int (1788000000000 + index);
        "assetType", `String "jpg"; "assetSize", `Int 4;
        "assetChecksum", `String "abcd"; "localPath", `String "Assets/photo.jpg"])))
    done;
    let next = ref (dispatch "beginPendingSync" None |> pending_request |> Option.get) in
    for index = 1 to 3 do
      assert_equal "each asset uploads bytes first" "PUT" (required_string "method" !next);
      let tx = complete !next (`Assoc ["ok", `Bool true]) |> pending_request |> Option.get in
      let before = Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state in
      let accepted = 42 + index in
      if replay_first then ignore (dispatch "applySyncEvent"
        (Some (`Assoc ["before", `Int before; "t", `Int accepted])) |> result);
      let completion = complete tx (`Assoc ["type", `String "tx/batch/ok"; "t", `Int accepted]) in
      let visible = completion |> result |> required_int "appliedServerT" in
      assert_int_equal "asset completion reports only the applied cursor"
        (Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state) visible;
      let snapshot_cursor = dispatch "startWebSocket" None |> result |> required_int "appliedServerT" in
      assert_int_equal "full snapshots preserve the same applied cursor" visible snapshot_cursor;
      if not replay_first && not deferred_replay then ignore (dispatch "applySyncEvent"
        (Some (`Assoc ["before", `Int snapshot_cursor; "t", `Int accepted])) |> result);
      if index < 3 then next := (dispatch "beginPendingSync" None |> pending_request |> Option.get)
    done;
    if deferred_replay then ignore (dispatch "applySyncEvent"
      (Some (`Assoc ["before", `Int 42; "t", `Int 45])) |> result);
    assert_int_equal "all asset replays applied" (if deferred_replay then 1 else 3) !applied_count;
    assert_int_equal "final applied cursor" 45 (Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state);
    let asset_count = Datascript.datoms (Datascript.conn_db conn) Datascript.Aevt
      ~a:"block/uuid" () |> List.of_seq |> List.length in
    assert_int_equal "replay materializes every asset exactly once" 3 asset_count
  ) [0; 1; 2]
;;

let () =
  let session = Logseq_chat_rpc.create
      ~sync_cursor:(fun () -> Some 60)
      ~prepare_operation:prepare_test_operation () in
  let operation : Logseq_chat_lg_core_native.pending_operation =
    { operation_id = "late-ack"; base_t = 60; state = Queued;
      intent = Save_title { uuid = "remote"; expected_title = "Old"; title = "New" } } in
  configure_plain_graph session;
  session.semantic_queue <- [{ Logseq_chat_rpc.operation }];
  Logseq_chat_rpc.activate_semantic_request ~t_before:43 session (Option.get session.config);
  let request = Option.get session.semantic_active in
  let body = from_string (Option.get request.request.body) in
  match body with
  | `Assoc fields -> assert_int_equal "late HTTP acknowledgement cannot rewind transport cursor"
      60 (required_int "t-before" fields)
  | _ -> failwith "expected transaction request body"
;;
