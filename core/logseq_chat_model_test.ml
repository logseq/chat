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

let block ~uuid ~title ~page_id ~created_at =
  Logseq_chat_lg_core_native.
    { uuid; title; page_id; parent_id = None; order = None; created_at
    ; updated_at = created_at; sync_status = "synced"; tags = []; references = []; breadcrumbs = []
    ; status = None; is_asset = false; asset_type = None; asset_size = None; asset_checksum = None
    ; local_path = None; journal = None }
;;

let assert_recent_blocks_limit_and_order () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let base_time = 1_776_000_000_000 in
  for index = 0 to 104 do
    (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_message (model) ((Printf.sprintf "local-%03d" index)) ((Printf.sprintf "Capture %03d" index)) ((base_time + index)))
  done;
  let recent_blocks = (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_recent_blocks (model))) in
  assert_int_equal "recent block count" 100 (List.length recent_blocks);
  (match recent_blocks with
   | oldest_kept :: _ ->
     assert_equal "oldest kept block uuid" "local-005" oldest_kept.uuid;
     assert_equal "oldest kept block title" "Capture 005" oldest_kept.title
   | [] -> failwith "expected recent blocks");
  (match List.rev recent_blocks with
   | newest :: _ ->
     assert_equal "newest block uuid" "local-104" newest.uuid;
     assert_equal "newest block title" "Capture 104" newest.title
   | [] -> failwith "expected recent blocks")
;;

let () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([])) (42));
  assert_int_equal "empty refresh does not commit" 0 model.revision;
  if model.last_refresh_at <> Some 42 then failwith "empty refresh must record its timestamp";
  (match Logseq_chat_lg_core_native.logseq_chat_cache_model_select model "missing" with
   | Error "unknown block: missing" -> ()
   | _ -> failwith "missing selection must fail without changing state");
  let row uuid parent order =
    { (block ~uuid ~title:uuid ~page_id:"page" ~created_at:1) with
      parent_id = Some parent; order = Some order }
  in
  let rows = [row "orphan" "missing" "a2"; row "root" "page" "a1";
              row "child" "root" "a0"; row "cycle-a" "cycle-b" "a3";
              row "cycle-b" "cycle-a" "a4"] in
  let ordered = (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_outliner_preorder ("page") (List.to_seq, (rows)))) in
  let ids = List.map (fun (block : Logseq_chat_lg_core_native.block) -> block.uuid) ordered in
  if ids <> ["root"; "child"; "orphan"; "cycle-a"; "cycle-b"]
  then failwith "outliner traversal must preserve orphans and cyclic leftovers once";
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, (rows)) (43));
  (match Logseq_chat_lg_core_native.logseq_chat_cache_model_select model "child" with
   | Ok () -> () | Error message -> failwith message);
  assert_equal "selected block" "child" (Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_selected_block model)).uuid;
  Logseq_chat_lg_core_native.logseq_chat_cache_model_clear_selection model;
  if Logseq_chat_lg_core_native.logseq_chat_cache_model_selected_block model <> None then failwith "selection did not clear"
;;

let assert_refresh_preserves_existing_created_at_when_remote_omits_it () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let created_at = 1_776_000_000_000 in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_message (model) ("stable-created-at") ("Original") (created_at));
  let remote_block =
    block ~uuid:"stable-created-at" ~title:"Updated remotely"
      ~page_id:"page-1" ~created_at:0
  in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ remote_block ])) ((created_at + 10_000)));
  match Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "stable-created-at" with
  | None -> failwith "expected refreshed block"
  | Some block ->
    assert_int_equal "refresh preserves created-at" created_at block.created_at;
    assert_int_equal "refresh preserves updated-at" created_at block.updated_at
;;

let assert_recent_blocks_excludes_pages_and_empty_blocks () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let block uuid title created_at =
    block ~uuid ~title ~page_id:"journal-1" ~created_at
  in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ block "empty-block" "   " 200
    ; block "real-block" "Visible" 100
    ])) (400));
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_journal_page (model) ("journal-1") (20260813) "");
  match (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_recent_blocks (model))) with
  | [ block ] -> assert_equal "only actual non-empty block" "real-block" block.uuid
  | blocks -> failwith (Printf.sprintf "expected one recent block, got %d" (List.length blocks))
;;

let assert_visible_graph_blocks_keep_empty_outliner_rows () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let empty =
    { (block ~uuid:"empty-block" ~title:"" ~page_id:"journal-1" ~created_at:100) with
      journal = Some ("Aug 22nd, 2026", 20260822)
    }
  in
  match (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_visible_from (model) (Some List.to_seq, ([ empty ])))) with
  | [ block ] -> assert_equal "editable empty graph block" "empty-block" block.uuid
  | blocks ->
    failwith
      (Printf.sprintf "expected one editable empty graph block, got %d" (List.length blocks))
;;

let assert_recent_blocks_require_a_current_or_past_journal_page () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let block uuid page_id created_at =
    block ~uuid ~title:uuid ~page_id ~created_at
  in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_journal_page (model) ("past-journal") (20260812) "");
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_journal_page (model) ("future-journal") (20990101) "");
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ block "past-block" "past-journal" 300
    ; block "future-block" "future-journal" 400
    ; block "ordinary-page-block" "ordinary-page" 500
    ])) (600));
  match (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_recent_blocks (model))) with
  | [ recent ] -> assert_equal "only past journal block is recent" "past-block" recent.uuid
  | blocks -> failwith (Printf.sprintf "expected one past journal block, got %d" (List.length blocks))
;;

let assert_journal_blocks_follow_page_tree_and_outliner_order () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_journal_page (model) ("journal-today") (20260815) "");
  let journal_block uuid parent_id order created_at =
    { (block ~uuid ~title:uuid ~page_id:"journal-today" ~created_at) with
      parent_id = Some parent_id
    ; order = Some order
    }
  in
  let other_page =
    { (block ~uuid:"other-page" ~title:"Other" ~page_id:"project" ~created_at:500) with
      parent_id = Some "project"
    ; order = Some "a0"
    }
  in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ journal_block "second-root" "journal-today" "a2" 100
    ; other_page
    ; journal_block "child" "first-root" "a0" 300
    ; journal_block "first-root" "journal-today" "a1" 400
    ])) (500));
  let uuids =
    (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_recent_blocks (model)))
    |> List.map (fun (block : Logseq_chat_lg_core_native.block) -> block.uuid)
  in
  match uuids with
  | [ "first-root"; "child"; "second-root" ] -> ()
  | _ -> failwith ("unexpected journal outliner order: " ^ String.concat ", " uuids)
;;

let assert_partial_search_result_preserves_journal_relation () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let block =
    block ~uuid:"search-block" ~title:"Before search"
      ~page_id:"journal-1" ~created_at:100
  in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_journal_page (model) ("journal-1") (20260813) ("Aug 13th, 2026"));
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ block ])) (100));
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ { block with title = "Search result"; page_id = ""; created_at = 0; updated_at = 0 } ])) (200));
  match (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_recent_blocks (model))) with
  | [ preserved ] ->
    assert_equal "search preserves journal page" "journal-1" preserved.page_id;
    assert_equal "search updates title" "Search result" preserved.title
  | blocks -> failwith (Printf.sprintf "expected preserved recent block, got %d" (List.length blocks))
;;

let assert_task_and_asset_metadata_persist () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let now = 1_776_000_000_000 in
  let status =
    Logseq_chat_lg_core_native.
      { uuid = "status-waiting"
      ; ident = Some "user.status/waiting"
      ; title = "Waiting"
      ; icon_type = Some "tabler-icon"
      ; icon_id = Some "clock"
      ; icon_color = Some "#7c3aed"
      }
  in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_task (model) ("task-local") ("Follow up") (status) (now));
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_asset (model) ("asset-local") ("voice.m4a") ("m4a") (4096) ("checksum") ("/documents/voice.m4a") ((now + 1)) None);
  let task = Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "task-local") in
  assert_equal "task status" "Waiting" (Option.get task.status).title;
  let asset = Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "asset-local") in
  assert_equal "asset type" "m4a" (Option.get asset.asset_type);
  assert_equal "asset local path" "/documents/voice.m4a" (Option.get asset.local_path)
;;

let assert_targeted_asset_is_a_child_of_the_editing_block () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let parent =
    { (block ~uuid:"editing-block" ~title:"Editing" ~page_id:"page-target" ~created_at:100) with
      parent_id = Some "page-target"
    }
  in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ parent ])) (100));
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_asset (model) ("audio-asset") ("Audio.m4a") ("m4a") (4096) ("checksum") ("/documents/Audio.m4a") (200) (Some ("editing-block")));
  let asset = Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "audio-asset") in
  assert_equal "targeted asset page" "page-target" asset.page_id;
  assert_equal "targeted asset parent" "editing-block" (Option.get asset.parent_id)
  ;
  (match
     (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_child (model) ("transcript") ("Transcript") ("audio-asset") (201))
   with
   | Ok () -> ()
   | Error message -> failwith message);
  let transcript = Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "transcript") in
  assert_equal "transcript page" "page-target" transcript.page_id;
  assert_equal "transcript parent" "audio-asset" (Option.get transcript.parent_id)
;;

let assert_uploaded_asset_reconciles_server_uuid () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_asset (model) ("local-asset") ("photo.jpg") ("jpg") (2048) ("checksum") ("/documents/photo.jpg") (1_776_000_000_000) None);
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ { uuid = "server-asset"; title = "photo"; page_id = "remote-journal"
      ; parent_id = Some "remote-journal"; order = None; created_at = 1_776_000_000_100
      ; updated_at = 1_776_000_000_100; sync_status = "synced"; tags = []; references = []; breadcrumbs = []
      ; status = None; is_asset = false; asset_type = None; asset_size = None; asset_checksum = None
      ; local_path = None; journal = None } ])) (1_776_000_000_100));
  (match
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_reconcile_created_block (model) ("local-asset") ("server-asset") "submitted")
   with
   | Ok () -> ()
   | Error message -> failwith message);
  if Option.is_some (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "local-asset")
  then failwith "local asset should be removed after the server assigns a different uuid";
  let asset = Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "server-asset") in
  assert_equal "reconciled local path" "/documents/photo.jpg" (Option.get asset.local_path);
  assert_equal "reconciled checksum" "checksum" (Option.get asset.asset_checksum);
  assert_equal "reconciled sync status" "submitted" asset.sync_status;
  assert_int_equal
    "one asset remains after uuid reconciliation"
    1
    ((Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_all_blocks (model)))
     |> List.filter (fun (block : Logseq_chat_lg_core_native.block) -> Option.is_some block.asset_type)
     |> List.length)
;;

let assert_remote_refresh_preserves_synced_local_asset_metadata () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_asset (model) ("stable-asset") ("photo.jpg") ("jpg") (2048) ("checksum") ("/documents/photo.jpg") (1_776_000_000_000) None);
  (match (Logseq_chat_lg_core_native.logseq_chat_cache_model_mark_block_synced (model) ("stable-asset")) with
   | Ok () -> ()
   | Error message -> failwith message);
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ block
        ~uuid:"stable-asset"
        ~title:"photo.jpg"
        ~page_id:"journal/2026-08-15"
        ~created_at:1_776_000_000_000
    ])) (1_776_000_000_100));
  let asset = Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "stable-asset") in
  assert_equal "refreshed asset type" "jpg" (Option.get asset.asset_type);
  assert_equal "refreshed asset checksum" "checksum" (Option.get asset.asset_checksum);
  assert_equal "refreshed asset path" "/documents/photo.jpg" (Option.get asset.local_path)
;;

let assert_created_block_reconciles_server_uuid () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_message (model) ("local-block") ("Offline capture") (1_776_000_000_000));
  (match
     (Logseq_chat_lg_core_native.logseq_chat_cache_model_reconcile_created_block (model) ("local-block") ("server-block") "submitted")
   with
   | Ok () -> ()
   | Error message -> failwith message);
  if Option.is_some (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "local-block")
  then failwith "local block should be removed after uuid reconciliation";
  let block = Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "server-block") in
  assert_equal "reconciled block title" "Offline capture" block.title;
  assert_equal "reconciled block status" "submitted" block.sync_status
;;

let assert_remote_refresh_preserves_offline_edit () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let original =
    block
      ~uuid:"offline-edit"
      ~title:"Server title"
      ~page_id:"journal/2026-08-15"
      ~created_at:1_776_000_000_000
  in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ original ])) (1_776_000_000_000));
  (match
     (Logseq_chat_lg_core_native.logseq_chat_cache_model_update_block_title (model) ("offline-edit") ("Edited offline") (1_776_000_000_100))
   with
   | Ok () -> ()
   | Error message -> failwith message);
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (model) (List.to_seq, ([ original ])) (1_776_000_000_200));
  let restored = Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "offline-edit") in
  assert_equal "offline edit survives remote refresh" "Edited offline" restored.title;
  assert_equal "offline edit remains queued" "pending" restored.sync_status
;;

let () =
  let model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let now = 1_776_000_000_000 in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_message (model) ("local-test") ("Capture note") (now));
  match Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "local-test" with
  | None -> failwith "expected cached local block"
  | Some block ->
    if String.equal block.page_id "local-pending"
    then failwith "local captures must be attached to today's journal page";
    assert_equal "journal page id prefix" "journal/" (String.sub block.page_id 0 8);
    assert_equal "new local capture sync status" "pending" block.sync_status;
    (match (Logseq_chat_lg_core_native.logseq_chat_cache_model_mark_block_synced (model) ("local-test")) with
     | Error message -> failwith message
     | Ok () ->
       (match Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "local-test" with
        | None -> failwith "expected synced local block"
        | Some synced_block ->
          assert_equal "synced local capture status" "synced" synced_block.sync_status));
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_message (model) ("local-failed") ("Capture failed") ((now + 1)));
  (match (Logseq_chat_lg_core_native.logseq_chat_cache_model_mark_block_sync_failed (model) ("local-failed")) with
   | Error message -> failwith message
   | Ok () ->
     (match Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block model "local-failed" with
      | None -> failwith "expected failed local block"
      | Some failed_block ->
        assert_equal "failed local capture status" "failed" failed_block.sync_status));
  let pending_blocks = (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (model))) in
  if
    not
      (List.exists
         (fun (block : Logseq_chat_lg_core_native.block) -> String.equal block.uuid "local-failed")
         pending_blocks)
  then failwith "failed blocks must remain retryable";
  assert_recent_blocks_limit_and_order ();
  assert_refresh_preserves_existing_created_at_when_remote_omits_it ();
  assert_recent_blocks_excludes_pages_and_empty_blocks ();
  assert_visible_graph_blocks_keep_empty_outliner_rows ();
  assert_recent_blocks_require_a_current_or_past_journal_page ();
  assert_journal_blocks_follow_page_tree_and_outliner_order ();
  assert_partial_search_result_preserves_journal_relation ();
  assert_task_and_asset_metadata_persist ();
  assert_targeted_asset_is_a_child_of_the_editing_block ();
  assert_uploaded_asset_reconciles_server_uuid ();
  assert_remote_refresh_preserves_synced_local_asset_metadata ();
  assert_created_block_reconciles_server_uuid ();
  assert_remote_refresh_preserves_offline_edit ()
;;

let () =
  let open Datascript in
  let module Model = Logseq_chat_lg_core_native in
  let model = (Model.logseq_chat_cache_model_create None) in
  (Model.logseq_chat_cache_model_commit (model) (List.to_seq, ([ Add (Temp_id "minimal", "block/uuid", String "minimal") ])));
  let minimal = Option.get (Model.logseq_chat_cache_model_read_block model "minimal") in
  assert_equal "missing title keeps default" "" minimal.title;
  assert_int_equal "missing timestamp keeps default" 0 minimal.created_at;
  assert_equal "missing sync status keeps default" "synced" minimal.sync_status;
  if minimal.asset_size <> None then failwith "missing asset size must remain absent";
  if Model.logseq_chat_cache_model_read_block model "absent" <> None then failwith "missing block must remain absent";
  let failures = ref [] in
  List.iter
    (fun (attr, value) ->
      let model = (Model.logseq_chat_cache_model_create None) in
      model.db <- empty_db ~schema:[ Rrbvec.nth Model.logseq_chat_cache_model_schema 0 ] ();
      (Model.logseq_chat_cache_model_commit (model) (List.to_seq, ([ Add (Temp_id "invalid", "block/uuid", String "invalid")
        ; Add (Temp_id "invalid", attr, value)
        ])));
      match Model.logseq_chat_cache_model_read_block model "invalid" with
      | _ -> failures := attr :: !failures
      | exception Datascript_lg.Invalid_data error ->
        if not (String.starts_with ~prefix:attr error.path)
        then failwith ("missing attribute in decode error: " ^ error.path))
    [ "block/title", Int 42
    ; "block/created-at", Float 1.5
    ; "block/asset-size", String "large"
    ; "block/local-path", Bool false
    ];
  if !failures <> []
  then failwith ("malformed cached attributes silently accepted: " ^ String.concat ", " !failures)
;;
