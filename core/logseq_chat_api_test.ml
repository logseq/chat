let assert_int_equal label expected actual =
  if expected <> actual
  then failwith (Printf.sprintf "%s: expected %d, got %d" label expected actual)
;;

let required_single_block body =
  match Logseq_chat_api.blocks_from_list_body "results" body with
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
      {|{"results":[{"uuid":"block-explicit","title":"Explicit","order":"a1","created-at":1776000000000,"updated-at":1776000100000}]}|}
  in
  assert_some_string "explicit outliner order" "a1" explicit.order;
  assert_int_equal "explicit created-at" 1_776_000_000_000 explicit.created_at;
  assert_int_equal "explicit updated-at" 1_776_000_100_000 explicit.updated_at;
  let missing =
    required_single_block
      {|{"results":[{"uuid":"block-missing","title":"Missing"}]}|}
  in
  assert_int_equal "missing created-at is not fabricated" 0 missing.created_at;
  assert_int_equal "missing updated-at is not fabricated" 0 missing.updated_at;
  let semantic =
    required_single_block
      {|{"results":[{"uuid":"semantic","title":"Review [[Project]]","tags":[{"uuid":"tag-1","title":"Project"}],"references":[{"uuid":"page-1","title":"Project"}],"status":{"uuid":"status-1","ident":"logseq.property/status.todo","title":"Todo","icon":{"type":"tabler-icon","id":"circle"}},"asset-type":"jpg","asset-size":2048,"asset-checksum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}|}
  in
  assert_equal "tag title" "Project" (List.hd semantic.tags).title;
  assert_equal "reference title" "Project" (List.hd semantic.references).title;
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
  assert_equal
    "graph discovery uses the authenticated db-sync graph index"
    "https://api.example/graphs"
    (Logseq_chat_api.graphs_request config).url;
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
      {|{"references":[{"uuid":"backlink","title":"Uses Project"}]}|}
  in
  assert_equal "related block" "backlink" (List.hd related).uuid;
  let capture = Logseq_chat_api.capture_request config ~uuid:"client-block" "Offline" in
  assert_equal
    "capture preserves client uuid"
    {|{"blocks":[{"uuid":"client-block","title":"Offline"}]}|}
    (Option.value capture.body ~default:"");
  let encrypted_capture =
    Logseq_chat_api.capture_request
      config
      ~page_id:"journal-1"
      ~uuid:"encrypted-block"
      "encrypted-title"
  in
  assert_equal
    "encrypted capture includes its existing journal page"
    {|{"page-id":"journal-1","blocks":[{"uuid":"encrypted-block","title":"encrypted-title"}]}|}
    (Option.value encrypted_capture.body ~default:"");
  let task =
    Logseq_chat_api.task_request config ~uuid:"client-task" ~status:"waiting" "Follow up"
  in
  assert_equal "task method" "POST" task.method_;
  assert_equal
    "task body"
    {|{"uuid":"client-task","title":"Follow up","status":"waiting"}|}
    (Option.value task.body ~default:"");
  let encrypted_task =
    Logseq_chat_api.task_request
      config
      ~page_id:"journal-1"
      ~uuid:"encrypted-task"
      ~status:"waiting"
      "encrypted-title"
  in
  assert_equal
    "encrypted task includes its existing journal page"
    {|{"uuid":"encrypted-task","title":"encrypted-title","status":"waiting","page-id":"journal-1"}|}
    (Option.value encrypted_task.body ~default:"");
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
  let tx_batch =
    Logseq_chat_api.tx_batch_request
      config
      ~t_before:42
      ~tx_id:"018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8"
      ~outliner_op:"split-block"
      ~tx:"[\"~:db/add\"]"
  in
  assert_equal "outliner tx batch method" "POST" tx_batch.method_;
  assert_equal
    "outliner tx batch URL"
    "https://api.example/sync/graph-1/tx/batch"
    tx_batch.url;
  assert_equal
    "outliner tx batch body"
    {|{"t-before":42,"txs":[{"tx-id":"018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8","tx":"[\"~:db/add\"]","outliner-op":"split-block"}]}|}
    (Option.value tx_batch.body ~default:"");
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
  let encrypted_upload =
    Logseq_chat_api.encrypted_asset_upload_request
      config
      ~uuid:"encrypted-asset"
      ~file_name:"photo.jpg"
      ~title:"encrypted-title"
      ~page_id:"journal-1"
      ~size:2048
      ~upload_size:4096
      ~checksum:"abc123"
      ~file_path:"/documents/encrypted-photo.transit"
  in
  if not (contains encrypted_upload.request.url "upload-size=4096")
  then failwith "encrypted asset upload must declare its encrypted payload size";
  if not (contains encrypted_upload.request.url "title=encrypted-title")
  then failwith "encrypted asset upload must send its ciphertext title";
  assert_equal "encrypted asset content type" "text/plain" encrypted_upload.content_type;
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
      {|{"blocks":[{"uuid":"block-1","title":"Message","page-id":"journal-new","created-at":1776000000000}],"journals":[{"uuid":"journal-new","title":"Aug 13th, 2026","journal-day":20260813}]}|}
  in
  assert_equal "feed block" "block-1" block.uuid;
  assert_equal "feed journal" "journal-new" journal.uuid;
  assert_equal "feed journal title" "Aug 13th, 2026" journal.title;
  assert_int_equal "feed journal day" 20_260_813 journal.journal_day;
  assert_equal
    "user key endpoint"
    "https://api.example/e2ee/user-keys"
    (Logseq_chat_api.user_keys_request config).url;
  assert_equal
    "graph key endpoint"
    "https://api.example/e2ee/graphs/graph-1/aes-key"
    (Logseq_chat_api.graph_key_request config).url;
  let upsert = Logseq_chat_api.upsert_graph_key_request config ~encrypted_key:"wrapped" in
  assert_equal "upsert graph key method" "POST" upsert.method_;
  (match upsert.body with
   | Some body ->
     (match Yojson.Basic.from_string body with
      | `Assoc fields ->
        assert_equal
          "upsert encrypted graph key"
          "wrapped"
          (match List.assoc_opt "encrypted-aes-key" fields with
           | Some (`String value) -> value
           | _ -> "")
      | _ -> failwith "upsert graph key body must be an object")
   | None -> failwith "upsert graph key body is missing");
  let key_pair =
    Logseq_chat_api.user_keys_from_body
      {|{"public-key":"public","encrypted-private-key":"private-package"}|}
  in
  assert_equal "encrypted private key package" "private-package" key_pair.encrypted_private_key;
  assert_equal
    "encrypted graph key package"
    "graph-package"
    (Logseq_chat_api.graph_key_from_body {|{"encrypted-aes-key":"graph-package"}|})
;;

let () =
  let config =
    Logseq_chat_api.
      { base_url = "https://api.example.com/api"
      ; graph_id = ""
      ; graph_name = None
      ; token = "token"
      }
  in
  let request =
    Logseq_chat_api.create_graph_request
      config
      ~name:"Private notes"
      ~schema_version:"65.33"
      ~e2ee:true
  in
  assert_equal "create graph method" "POST" request.method_;
  assert_equal "create graph url" "https://api.example.com/graphs" request.url;
  (match request.body with
   | Some body ->
     (match Yojson.Basic.from_string body with
      | `Assoc fields ->
        (match List.assoc_opt "graph-name" fields,
               List.assoc_opt "schema-version" fields,
               List.assoc_opt "graph-e2ee?" fields with
         | Some (`String name), Some (`String schema), Some (`Bool true) ->
           assert_equal "create graph name" "Private notes" name;
           assert_equal "create graph schema" "65.33" schema
         | _ -> failwith "create graph body must preserve name, schema, and encryption")
      | _ -> failwith "create graph body must be an object")
   | None -> failwith "create graph request must have a body")
;;

let () =
  let graphs =
    Logseq_chat_api.graphs_from_graphs_body
      {|{"graphs":[{"graph-id":"plain-1","graph-name":"Plain","schema-version":"65.33","graph-e2ee?":false,"graph-ready-for-use?":true},{"graph-id":"encrypted-1","graph-name":"Encrypted","graph-e2ee?":true,"graph-ready-for-use?":false}]}|}
  in
  assert_equal "graph schema version" "65.33" (Option.get (List.hd graphs).schema_version);
  match graphs with
  | [ plain; encrypted ] ->
    assert_equal "plain graph id" "plain-1" plain.Logseq_chat_api.id;
    assert_equal "plain graph name" "Plain" plain.name;
    if plain.e2ee then failwith "plain graph must remain unencrypted";
    if not plain.ready then failwith "plain graph must remain ready";
    assert_equal "encrypted graph id" "encrypted-1" encrypted.id;
    if not encrypted.e2ee then failwith "encrypted graph must remain encrypted";
    if encrypted.ready then failwith "encrypted graph must remain not ready"
  | _ -> failwith "graph discovery must preserve every valid graph"
;;
