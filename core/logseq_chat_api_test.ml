let assert_int_equal label expected actual =
  if expected <> actual
  then failwith (Printf.sprintf "%s: expected %d, got %d" label expected actual)
;;

let required_single_block body =
  match Logseq_chat_api.blocks_from_search_body body with
  | [ block ] -> block
  | blocks -> failwith (Printf.sprintf "expected one block, got %d" (List.length blocks))
;;

let required_feed body =
  match Logseq_chat_api.feed_from_body body with
  | [ block ], [ journal ] -> block, journal
  | blocks, journals ->
    failwith
      (Printf.sprintf
         "expected one block and one journal, got %d and %d"
         (List.length blocks)
         (List.length journals))
;;

let assert_equal label expected actual =
  if not (String.equal expected actual)
  then failwith (Printf.sprintf "%s: expected %S, got %S" label expected actual)
;;

let assert_some_string label expected = function
  | Some actual -> assert_equal label expected actual
  | None -> failwith (label ^ ": expected a value")
;;

let contains text substring =
  let text_length = String.length text in
  let substring_length = String.length substring in
  let rec loop index =
    index + substring_length <= text_length
    && (String.equal (String.sub text index substring_length) substring || loop (index + 1))
  in
  substring_length = 0 || loop 0
;;

let () =
  let explicit =
    required_single_block
      {|{"results":[{"uuid":"block-explicit","title":"Explicit","kind":"block","created-at":1776000000000,"updated-at":1776000100000}]}|}
  in
  assert_int_equal "explicit created-at" 1_776_000_000_000 explicit.created_at;
  assert_int_equal "explicit updated-at" 1_776_000_100_000 explicit.updated_at;
  let missing =
    required_single_block
      {|{"results":[{"uuid":"block-missing","title":"Missing","kind":"block"}]}|}
  in
  assert_int_equal "missing created-at is not fabricated" 0 missing.created_at;
  assert_int_equal "missing updated-at is not fabricated" 0 missing.updated_at;
  let semantic =
    required_single_block
      {|{"results":[{"uuid":"semantic","title":"Review [[Project]]","kind":"asset","tags":[{"uuid":"tag-1","kind":"tag","title":"Project"}],"references":[{"uuid":"page-1","kind":"page","title":"Project"}],"status":{"uuid":"status-1","ident":"logseq.property/status.todo","title":"Todo","icon":{"type":"tabler-icon","id":"circle"}},"asset-type":"jpg","asset-size":2048,"asset-checksum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}|}
  in
  assert_equal "tag title" "Project" (List.hd semantic.tags).title;
  assert_equal "reference kind" "page" (List.hd semantic.references).kind;
  assert_some_string "status title" "Todo"
    (Option.map (fun (status : Logseq_chat_model.status) -> status.title) semantic.status);
  assert_some_string "status icon" "circle"
    (Option.bind semantic.status (fun (status : Logseq_chat_model.status) -> status.icon_id));
  let statuses =
    Logseq_chat_api.statuses_from_property_body
      {|{"results":[{"uuid":"property-status","ident":"logseq.property/status","title":"Status","choices":[{"uuid":"status-waiting","ident":"user.status/waiting","title":"Waiting","icon":{"type":"tabler-icon","id":"clock","color":"#7c3aed"}}]}]}|}
  in
  assert_int_equal "status choice count" 1 (List.length statuses);
  let custom_status = List.hd statuses in
  assert_equal "status choice title" "Waiting" custom_status.title;
  assert_some_string "status choice color" "#7c3aed" custom_status.icon_color;
  assert_some_string "asset type" "jpg" semantic.asset_type;
  assert_int_equal "asset size" 2048 (Option.value semantic.asset_size ~default:0);
  let search_journals =
    Logseq_chat_api.journals_from_search_body
      {|{"results":[{"uuid":"block-search","title":"Search","kind":"block","page-id":"journal-search","journal-title":"Aug 13th, 2026","journal-day":20260813}]}|}
  in
  (match search_journals with
   | [ journal ] ->
     assert_equal "search journal id" "journal-search" journal.uuid;
     assert_equal "search journal title" "Aug 13th, 2026" journal.title;
     assert_int_equal "search journal day" 20_260_813 journal.journal_day
   | journals -> failwith (Printf.sprintf "expected one search journal, got %d" (List.length journals)));
  let config =
    Logseq_chat_api.
      { base_url = "https://api.example"
      ; graph_id = "graph-1"
      ; graph_name = None
      ; token = "token"
      }
  in
  let feed_request = Logseq_chat_api.recent_blocks_request config ~journal_day:20260813 in
  assert_equal "recent blocks method" "GET" feed_request.method_;
  assert_equal
    "recent blocks URL"
    "https://api.example/api/v1/graphs/graph-1/blocks?journal-only=true&journal-day-at-most=20260813&sort=created-at-desc&limit=100"
    feed_request.url;
  assert_equal
    "task statuses URL"
    "https://api.example/api/v1/graphs/graph-1/search?q=Status&types=properties&limit=100"
    (Logseq_chat_api.task_statuses_request config).url;
  let search_request = Logseq_chat_api.search_request config "voice" in
  if not (String.contains search_request.url ',')
  then failwith "remote search must include block and asset resources";
  assert_equal "block references URL"
    "https://api.example/api/v1/graphs/graph-1/blocks/block-1/references?limit=100"
    (Logseq_chat_api.block_references_request config "block-1").url;
  assert_equal "tag objects URL"
    "https://api.example/api/v1/graphs/graph-1/tags/tag-1/objects?limit=100"
    (Logseq_chat_api.tag_objects_request config "tag-1").url;
  assert_equal "page references URL"
    "https://api.example/api/v1/graphs/graph-1/pages/page-1/references?limit=100"
    (Logseq_chat_api.page_references_request config "page-1").url;
  let related =
    Logseq_chat_api.blocks_from_list_body "references"
      {|{"references":[{"uuid":"backlink","kind":"block","title":"Uses Project"}]}|}
  in
  assert_equal "related block" "backlink" (List.hd related).uuid;
  let capture = Logseq_chat_api.capture_request config ~uuid:"client-block" "Offline" in
  assert_equal
    "capture preserves client uuid"
    {|{"blocks":[{"uuid":"client-block","title":"Offline"}]}|}
    (Option.value capture.body ~default:"");
  let task =
    Logseq_chat_api.task_request config ~uuid:"client-task" ~status:"waiting" "Follow up"
  in
  assert_equal "task method" "POST" task.method_;
  assert_equal
    "task body"
    {|{"uuid":"client-task","title":"Follow up","status":"waiting"}|}
    (Option.value task.body ~default:"");
  let status_update =
    Logseq_chat_api.update_block_status_request
      config
      ~uuid:"task-1"
      ~status:"custom-waiting"
  in
  assert_equal "status update method" "PUT" status_update.method_;
  assert_equal
    "status update URL"
    "https://api.example/api/v1/graphs/graph-1/blocks/task-1/properties/Status"
    status_update.url;
  assert_equal
    "status update body"
    {|{"value":"custom-waiting"}|}
    (Option.value status_update.body ~default:"");
  let upload =
    Logseq_chat_api.asset_upload_request
      config
      ~uuid:"client-asset"
      ~file_name:"photo.jpg"
      ~size:2048
      ~checksum:"abc123"
      ~file_path:"/documents/photo.jpg"
      ~content_type:"image/jpeg"
  in
  assert_equal "asset upload path" "/documents/photo.jpg" upload.file_path;
  assert_equal "asset content type" "image/jpeg" upload.content_type;
  if upload.request.body <> None then failwith "asset bytes must not be encoded in request JSON";
  if not (contains upload.request.url "?uuid=client-asset&")
  then failwith "asset upload must preserve the local block uuid in the query";
  assert_equal
    "asset upload response uuid"
    "server-asset"
    (Logseq_chat_api.created_block_uuid_from_body
       {|{"uuid":"server-asset","title":"photo.jpg","type":"jpg","size":2048,"checksum":"abc123"}|});
  assert_equal
    "task response uuid"
    "server-task"
    (Logseq_chat_api.created_block_uuid_from_body
       {|{"uuid":"server-task","title":"Follow up","status":{"title":"Todo"}}|});
  assert_equal
    "capture response uuid"
    "server-block"
    (Logseq_chat_api.created_block_uuid_from_body
       {|{"page-id":"journal","blocks":[{"uuid":"server-block","title":"Offline"}]}|});
  let block, journal =
    required_feed
      {|{"blocks":[{"uuid":"block-1","title":"Message","kind":"block","page-id":"journal-new","created-at":1776000000000}],"journals":[{"uuid":"journal-new","title":"Aug 13th, 2026","kind":"page","journal-day":20260813}]}|}
  in
  assert_equal "feed block" "block-1" block.uuid;
  assert_equal "feed journal" "journal-new" journal.uuid;
  assert_equal "feed journal title" "Aug 13th, 2026" journal.title;
  assert_int_equal "feed journal day" 20_260_813 journal.journal_day
;;
