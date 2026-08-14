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

let block ~uuid ~kind ~title ~page_id ~created_at =
  Logseq_chat_model.
    { uuid; kind; title; page_id; parent_id = None; order = None; created_at
    ; updated_at = created_at; sync_status = "synced"; tags = []; references = []
    ; status = None; asset_type = None; asset_size = None; asset_checksum = None
    ; local_path = None }
;;

let assert_recent_blocks_limit_and_order () =
  let model = Logseq_chat_model.create () in
  let base_time = 1_776_000_000_000 in
  for index = 0 to 104 do
    Logseq_chat_model.cache_local_message
      model
      ~uuid:(Printf.sprintf "local-%03d" index)
      ~title:(Printf.sprintf "Capture %03d" index)
      ~now:(base_time + index)
  done;
  let recent_blocks = Logseq_chat_model.recent_blocks model in
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

let assert_refresh_preserves_existing_created_at_when_remote_omits_it () =
  let model = Logseq_chat_model.create () in
  let created_at = 1_776_000_000_000 in
  Logseq_chat_model.cache_local_message
    model
    ~uuid:"stable-created-at"
    ~title:"Original"
    ~now:created_at;
  let remote_block =
    block ~uuid:"stable-created-at" ~kind:"block" ~title:"Updated remotely"
      ~page_id:"page-1" ~created_at:0
  in
  Logseq_chat_model.upsert_blocks model [ remote_block ] ~refresh_time:(created_at + 10_000);
  match Logseq_chat_model.read_block model "stable-created-at" with
  | None -> failwith "expected refreshed block"
  | Some block ->
    assert_int_equal "refresh preserves created-at" created_at block.created_at;
    assert_int_equal "refresh preserves updated-at" created_at block.updated_at
;;

let assert_recent_blocks_excludes_pages_and_empty_blocks () =
  let model = Logseq_chat_model.create () in
  let block kind uuid title created_at =
    block ~kind ~uuid ~title ~page_id:"journal-1" ~created_at
  in
  Logseq_chat_model.upsert_blocks
    model
    [ block "page" "page-entity" "Journal page" 300
    ; block "block" "empty-block" "   " 200
    ; block "block" "real-block" "Visible" 100
    ]
    ~refresh_time:400;
  Logseq_chat_model.upsert_journal_page model ~uuid:"journal-1" ~journal_day:20260813;
  match Logseq_chat_model.recent_blocks model with
  | [ block ] -> assert_equal "only actual non-empty block" "real-block" block.uuid
  | blocks -> failwith (Printf.sprintf "expected one recent block, got %d" (List.length blocks))
;;

let assert_recent_blocks_require_a_current_or_past_journal_page () =
  let model = Logseq_chat_model.create () in
  let block uuid page_id created_at =
    block ~uuid ~kind:"block" ~title:uuid ~page_id ~created_at
  in
  Logseq_chat_model.upsert_journal_page model ~uuid:"past-journal" ~journal_day:20260812;
  Logseq_chat_model.upsert_journal_page model ~uuid:"future-journal" ~journal_day:20990101;
  Logseq_chat_model.upsert_blocks
    model
    [ block "past-block" "past-journal" 300
    ; block "future-block" "future-journal" 400
    ; block "ordinary-page-block" "ordinary-page" 500
    ]
    ~refresh_time:600;
  match Logseq_chat_model.recent_blocks model with
  | [ recent ] -> assert_equal "only past journal block is recent" "past-block" recent.uuid
  | blocks -> failwith (Printf.sprintf "expected one past journal block, got %d" (List.length blocks))
;;

let assert_journal_blocks_follow_page_tree_and_outliner_order () =
  let model = Logseq_chat_model.create () in
  Logseq_chat_model.upsert_journal_page model ~uuid:"journal-today" ~journal_day:20260815;
  let journal_block uuid parent_id order created_at =
    { (block ~uuid ~kind:"block" ~title:uuid ~page_id:"journal-today" ~created_at) with
      parent_id = Some parent_id
    ; order = Some order
    }
  in
  let other_page =
    { (block ~uuid:"other-page" ~kind:"block" ~title:"Other" ~page_id:"project" ~created_at:500) with
      parent_id = Some "project"
    ; order = Some "a0"
    }
  in
  Logseq_chat_model.upsert_blocks
    model
    [ journal_block "second-root" "journal-today" "a2" 100
    ; other_page
    ; journal_block "child" "first-root" "a0" 300
    ; journal_block "first-root" "journal-today" "a1" 400
    ]
    ~refresh_time:500;
  let uuids =
    Logseq_chat_model.recent_blocks model
    |> List.map (fun (block : Logseq_chat_model.block) -> block.uuid)
  in
  match uuids with
  | [ "first-root"; "child"; "second-root" ] -> ()
  | _ -> failwith ("unexpected journal outliner order: " ^ String.concat ", " uuids)
;;

let assert_search_excludes_pages_and_empty_blocks () =
  let model = Logseq_chat_model.create () in
  let entity kind uuid title =
    block ~kind ~uuid ~title ~page_id:"journal-1" ~created_at:100
  in
  Logseq_chat_model.upsert_journal_page model ~uuid:"journal-1" ~journal_day:20260813;
  Logseq_chat_model.upsert_blocks
    model
    [ entity "page" "matching-page" "Match page"
    ; entity "block" "matching-empty" "   "
    ; entity "block" "matching-block" "Match block"
    ]
    ~refresh_time:100;
  match Logseq_chat_model.search model "match" with
  | [ block ] -> assert_equal "search returns only blocks" "matching-block" block.uuid
  | blocks -> failwith (Printf.sprintf "expected one search block, got %d" (List.length blocks))
;;

let assert_partial_search_result_preserves_journal_relation () =
  let model = Logseq_chat_model.create () in
  let block =
    block ~uuid:"search-block" ~kind:"block" ~title:"Before search"
      ~page_id:"journal-1" ~created_at:100
  in
  Logseq_chat_model.upsert_journal_page
    ~title:"Aug 13th, 2026"
    model
    ~uuid:"journal-1"
    ~journal_day:20260813;
  Logseq_chat_model.upsert_blocks model [ block ] ~refresh_time:100;
  Logseq_chat_model.upsert_blocks
    model
    [ { block with title = "Search result"; page_id = ""; created_at = 0; updated_at = 0 } ]
    ~refresh_time:200;
  match Logseq_chat_model.recent_blocks model with
  | [ preserved ] ->
    assert_equal "search preserves journal page" "journal-1" preserved.page_id;
    assert_equal "search updates title" "Search result" preserved.title
  | blocks -> failwith (Printf.sprintf "expected preserved recent block, got %d" (List.length blocks))
;;

let assert_task_and_asset_metadata_persist () =
  let model = Logseq_chat_model.create () in
  let now = 1_776_000_000_000 in
  let status =
    Logseq_chat_model.
      { uuid = "status-waiting"
      ; ident = Some "user.status/waiting"
      ; title = "Waiting"
      ; icon_type = Some "tabler-icon"
      ; icon_id = Some "clock"
      ; icon_color = Some "#7c3aed"
      }
  in
  Logseq_chat_model.cache_local_task
    model ~uuid:"task-local" ~title:"Follow up" ~status ~now;
  Logseq_chat_model.cache_local_asset
    model
    ~uuid:"asset-local"
    ~title:"voice.m4a"
    ~asset_type:"m4a"
    ~asset_size:4096
    ~asset_checksum:"checksum"
    ~local_path:"/documents/voice.m4a"
    ~now:(now + 1);
  let task = Option.get (Logseq_chat_model.read_block model "task-local") in
  assert_equal "task kind" "task" task.kind;
  assert_equal "task status" "Waiting" (Option.get task.status).title;
  let asset = Option.get (Logseq_chat_model.read_block model "asset-local") in
  assert_equal "asset kind" "asset" asset.kind;
  assert_equal "asset type" "m4a" (Option.get asset.asset_type);
  assert_equal "asset local path" "/documents/voice.m4a" (Option.get asset.local_path)
;;

let assert_uploaded_asset_reconciles_server_uuid () =
  let model = Logseq_chat_model.create () in
  Logseq_chat_model.cache_local_asset
    model
    ~uuid:"local-asset"
    ~title:"photo.jpg"
    ~asset_type:"jpg"
    ~asset_size:2048
    ~asset_checksum:"checksum"
    ~local_path:"/documents/photo.jpg"
    ~now:1_776_000_000_000;
  Logseq_chat_model.upsert_blocks
    model
    [ { uuid = "server-asset"; kind = "asset"; title = "photo"; page_id = "remote-journal"
      ; parent_id = Some "remote-journal"; order = None; created_at = 1_776_000_000_100
      ; updated_at = 1_776_000_000_100; sync_status = "synced"; tags = []; references = []
      ; status = None; asset_type = None; asset_size = None; asset_checksum = None
      ; local_path = None } ]
    ~refresh_time:1_776_000_000_100;
  (match
  Logseq_chat_model.reconcile_created_block
       model ~local_uuid:"local-asset" ~remote_uuid:"server-asset"
   with
   | Ok () -> ()
   | Error message -> failwith message);
  if Option.is_some (Logseq_chat_model.read_block model "local-asset")
  then failwith "local asset should be removed after the server assigns a different uuid";
  let asset = Option.get (Logseq_chat_model.read_block model "server-asset") in
  assert_equal "reconciled asset kind" "asset" asset.kind;
  assert_equal "reconciled local path" "/documents/photo.jpg" (Option.get asset.local_path);
  assert_equal "reconciled checksum" "checksum" (Option.get asset.asset_checksum);
  assert_equal "reconciled sync status" "submitted" asset.sync_status;
  assert_int_equal
    "one asset remains after uuid reconciliation"
    1
    (Logseq_chat_model.all_blocks model
     |> List.filter (fun (block : Logseq_chat_model.block) -> String.equal block.kind "asset")
     |> List.length)
;;

let assert_created_block_reconciles_server_uuid () =
  let model = Logseq_chat_model.create () in
  Logseq_chat_model.cache_local_message
    model ~uuid:"local-block" ~title:"Offline capture" ~now:1_776_000_000_000;
  (match
     Logseq_chat_model.reconcile_created_block
       model ~local_uuid:"local-block" ~remote_uuid:"server-block"
   with
   | Ok () -> ()
   | Error message -> failwith message);
  if Option.is_some (Logseq_chat_model.read_block model "local-block")
  then failwith "local block should be removed after uuid reconciliation";
  let block = Option.get (Logseq_chat_model.read_block model "server-block") in
  assert_equal "reconciled block title" "Offline capture" block.title;
  assert_equal "reconciled block status" "submitted" block.sync_status
;;

let assert_remote_refresh_preserves_offline_edit () =
  let model = Logseq_chat_model.create () in
  let original =
    block
      ~uuid:"offline-edit"
      ~kind:"block"
      ~title:"Server title"
      ~page_id:"journal/2026-08-15"
      ~created_at:1_776_000_000_000
  in
  Logseq_chat_model.upsert_blocks model [ original ] ~refresh_time:1_776_000_000_000;
  (match
     Logseq_chat_model.update_block_title
       model ~uuid:"offline-edit" ~title:"Edited offline" ~now:1_776_000_000_100
   with
   | Ok () -> ()
   | Error message -> failwith message);
  Logseq_chat_model.upsert_blocks
    model [ original ] ~refresh_time:1_776_000_000_200;
  let restored = Option.get (Logseq_chat_model.read_block model "offline-edit") in
  assert_equal "offline edit survives remote refresh" "Edited offline" restored.title;
  assert_equal "offline edit remains queued" "pending" restored.sync_status
;;

let () =
  let model = Logseq_chat_model.create () in
  let now = 1_776_000_000_000 in
  Logseq_chat_model.cache_local_message model ~uuid:"local-test" ~title:"Capture note" ~now;
  match Logseq_chat_model.read_block model "local-test" with
  | None -> failwith "expected cached local block"
  | Some block ->
    if String.equal block.page_id "local-pending"
    then failwith "local captures must be attached to today's journal page";
    assert_equal "journal page id prefix" "journal/" (String.sub block.page_id 0 8);
    assert_equal "new local capture sync status" "pending" block.sync_status;
    (match Logseq_chat_model.mark_block_synced model ~uuid:"local-test" with
     | Error message -> failwith message
     | Ok () ->
       (match Logseq_chat_model.read_block model "local-test" with
        | None -> failwith "expected synced local block"
        | Some synced_block ->
          assert_equal "synced local capture status" "synced" synced_block.sync_status));
  Logseq_chat_model.cache_local_message
    model
    ~uuid:"local-failed"
    ~title:"Capture failed"
    ~now:(now + 1);
  (match Logseq_chat_model.mark_block_sync_failed model ~uuid:"local-failed" with
   | Error message -> failwith message
   | Ok () ->
     (match Logseq_chat_model.read_block model "local-failed" with
      | None -> failwith "expected failed local block"
      | Some failed_block ->
        assert_equal "failed local capture status" "failed" failed_block.sync_status));
  let pending_blocks = Logseq_chat_model.pending_blocks model in
  if
    not
      (List.exists
         (fun (block : Logseq_chat_model.block) -> String.equal block.uuid "local-failed")
         pending_blocks)
  then failwith "failed blocks must remain retryable";
  assert_recent_blocks_limit_and_order ();
  assert_refresh_preserves_existing_created_at_when_remote_omits_it ();
  assert_recent_blocks_excludes_pages_and_empty_blocks ();
  assert_recent_blocks_require_a_current_or_past_journal_page ();
  assert_journal_blocks_follow_page_tree_and_outliner_order ();
  assert_search_excludes_pages_and_empty_blocks ();
  assert_partial_search_result_preserves_journal_relation ();
  assert_task_and_asset_metadata_persist ();
  assert_uploaded_asset_reconciles_server_uuid ();
  assert_created_block_reconciles_server_uuid ();
  assert_remote_refresh_preserves_offline_edit ()
;;
