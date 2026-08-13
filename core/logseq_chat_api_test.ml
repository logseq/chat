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
  let block, journal =
    required_feed
      {|{"blocks":[{"uuid":"block-1","title":"Message","kind":"block","page-id":"journal-new","created-at":1776000000000}],"journals":[{"uuid":"journal-new","title":"Aug 13th, 2026","kind":"page","journal-day":20260813}]}|}
  in
  assert_equal "feed block" "block-1" block.uuid;
  assert_equal "feed journal" "journal-new" journal.uuid;
  assert_equal "feed journal title" "Aug 13th, 2026" journal.title;
  assert_int_equal "feed journal day" 20_260_813 journal.journal_day
;;
