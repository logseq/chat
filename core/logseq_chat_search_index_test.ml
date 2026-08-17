open Datascript
module Search = Logseq_chat_search_index

let assert_bool message condition = if not condition then failwith message

let assert_equal message expected actual =
  if not (String.equal expected actual)
  then failwith (Printf.sprintf "%s: expected %s but got %s" message expected actual)
;;

let one ?value_type ?(unique = None) () =
  { cardinality = One
  ; unique
  ; indexed = Option.is_some unique
  ; is_component = false
  ; no_history = false
  ; doc = None
  ; value_type
  ; tuple_attrs = None
  ; tuple_types = None
  }
;;

let schema =
  [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
  ; "block/name", one ~value_type:StringType ()
  ; "block/title", one ~value_type:StringType ()
  ; "block/page", one ~value_type:RefType ()
  ; "block/parent", one ~value_type:RefType ()
  ; "block/journal-day", one ()
  ; "logseq.property/built-in?", one ()
  ; "logseq.property/hide?", one ()
  ]
;;

let page_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec1"
let block_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec2"
let ref_block_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec3"
let journal_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec4"
let hidden_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec5"
let cjk_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec6"

let entity id attrs = Entity { db_id = Some (Temp_id id); attrs }

let seeded_conn () =
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ entity
           "page"
           [ "block/uuid", One_value (Uuid page_uuid)
           ; "block/name", One_value (String "movies")
           ; "block/title", One_value (String "Movies")
           ]
       ; entity
           "block"
           [ "block/uuid", One_value (Uuid block_uuid)
           ; "block/title", One_value (String "watch 4k movies tonight")
           ; "block/page", One_value (Ref_to (Temp_id "page"))
           ]
       ; entity
           "ref-block"
           [ "block/uuid", One_value (Uuid ref_block_uuid)
           ; "block/title", One_value (String ("[[" ^ page_uuid ^ "]] marathon plan"))
           ; "block/page", One_value (Ref_to (Temp_id "page"))
           ]
       ; entity
           "journal"
           [ "block/uuid", One_value (Uuid journal_uuid)
           ; "block/name", One_value (String "aug 16th, 2026")
           ; "block/title", One_value (String "Aug 16th, 2026")
           ; "block/journal-day", One_value (Int 20260816)
           ]
       ; entity
           "hidden"
           [ "block/uuid", One_value (Uuid hidden_uuid)
           ; "block/name", One_value (String "secret")
           ; "block/title", One_value (String "Secret movies page")
           ; "logseq.property/hide?", One_value (Bool true)
           ]
       ; entity
           "cjk"
           [ "block/uuid", One_value (Uuid cjk_uuid)
           ; "block/title", One_value (String "\230\153\154\228\184\138\231\156\139\231\148\181\229\189\177")
           ; "block/page", One_value (Ref_to (Temp_id "page"))
           ]
       ]);
  conn
;;

let temp_index () =
  let root = Filename.temp_file "logseq-chat-search" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Search.create ~path:(Filename.concat root "search/db.sqlite")
;;

let find_result results uuid =
  List.find_opt (fun (result : Search.result) -> String.equal result.Search.uuid uuid) results
;;

let () =
  (* get-match-input: punctuation and boolean operators behave like Logseq. *)
  assert_equal "plain word input" "movie" (Search.get_match_input "movie");
  assert_equal "boolean operators" "left AND right" (Search.get_match_input "left and right");
  assert_equal
    "punctuation becomes a phrase prefix"
    "\"block/title\"*"
    (Search.get_match_input "block/title");
  assert_equal
    "dangling operator becomes a phrase prefix"
    "\"left AND \"*"
    (Search.get_match_input "left and ")
;;

let () =
  (* Fuzzy score prefers prefixes and exact substrings, like Logseq. *)
  let prefix = Search.Fuzzy.score "mov" "movies" in
  let scattered = Search.Fuzzy.score "mov" "my old vase" in
  assert_bool "prefix match outranks scattered match" (prefix > scattered);
  assert_bool "unrelated text scores lower" (Search.Fuzzy.score "mov" "task" < 1.)
;;

let () =
  let conn = seeded_conn () in
  let index = temp_index () in
  Search.refresh index (conn_db conn);
  (* Page results rank above block results for the same term. *)
  (match Search.search index "movies" with
   | first :: _ as results ->
     assert_equal "page ranks first" page_uuid first.Search.uuid;
     assert_bool "page flagged as page" first.Search.is_page;
     assert_bool "block match present" (Option.is_some (find_result results block_uuid))
   | [] -> failwith "search should match seeded blocks");
  (* Trigram FTS matches substrings inside words. *)
  assert_bool
    "substring match through trigram"
    (Option.is_some (find_result (Search.search index "ovie") block_uuid));
  (* Short queries fall back to LIKE. *)
  assert_bool
    "two character query"
    (Option.is_some (find_result (Search.search index "4k") block_uuid));
  (* CJK queries shorter than three characters also fall back to LIKE. *)
  assert_bool
    "cjk substring query"
    (Option.is_some
       (find_result (Search.search index "\231\148\181\229\189\177") cjk_uuid));
  (* Stored uuid references are indexed as display text. *)
  (match find_result (Search.search index "Movies marathon") ref_block_uuid with
   | Some result ->
     assert_equal "ref replaced with page name" "[[Movies]] marathon plan" result.Search.title
   | None -> failwith "uuid reference should be searchable by page name");
  (* Journal pages index their journal day. *)
  assert_bool
    "journal day query"
    (Option.is_some (find_result (Search.search index "20260816") journal_uuid));
  (* Hidden pages stay out of the index. *)
  assert_bool
    "hidden page skipped"
    (Option.is_none (find_result (Search.search index "Secret") hidden_uuid));
  (* Refresh diffs: retitle one block, delete another. *)
  ignore
    (transact_conn
       conn
       [ Add
           ( Lookup_ref ("block/uuid", Uuid block_uuid)
           , "block/title"
           , String "listen to jazz records" )
       ]);
  Search.refresh index (conn_db conn);
  assert_bool
    "stale title no longer matches"
    (Option.is_none (find_result (Search.search index "4k movies") block_uuid));
  assert_bool
    "updated title matches"
    (Option.is_some (find_result (Search.search index "jazz") block_uuid));
  ignore
    (transact_conn
       conn
       [ RetractEntity (Lookup_ref ("block/uuid", Uuid block_uuid)) ]);
  Search.refresh index (conn_db conn);
  assert_bool
    "deleted block leaves the index"
    (Option.is_none (find_result (Search.search index "jazz") block_uuid))
;;
