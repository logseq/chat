open Datascript
module Search = Logseq_chat_lg_core_native

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
  (Search.logseq_chat_search_index_create
     (Filename.concat root "search/db.sqlite"))
;;

let find_result results uuid =
  List.find_opt (fun (result : Search.search_result) -> String.equal result.Search.uuid uuid) results
;;

let () =
  (* get-match-input: punctuation and boolean operators behave like Logseq. *)
  assert_equal "plain word input" "movie" (Search.logseq_chat_search_index_get_match_input "movie");
  assert_equal "boolean operators" "left AND right" (Search.logseq_chat_search_index_get_match_input "left and right");
  assert_equal
    "punctuation becomes a phrase prefix"
    "\"block/title\"*"
    (Search.logseq_chat_search_index_get_match_input "block/title");
  assert_equal
    "dangling operator becomes a phrase prefix"
    "\"left AND \"*"
    (Search.logseq_chat_search_index_get_match_input "left and ")
;;

let () =
  (* Fuzzy score prefers prefixes and exact substrings, like Logseq. *)
  let prefix = (Search.logseq_chat_search_index_fuzzy_score "mov" "movies") in
  let scattered = (Search.logseq_chat_search_index_fuzzy_score "mov" "my old vase") in
  assert_bool "prefix match outranks scattered match" (prefix > scattered);
  assert_bool "unrelated text scores lower" ((Search.logseq_chat_search_index_fuzzy_score "mov" "task") < 1.)
;;

let () =
  let cjk = "\231\148\181" and emoji = "\240\159\152\128" in
  let text = "a" ^ cjk ^ emoji in
  assert_bool "UTF-8 lengths count leading bytes" ((Search.logseq_chat_search_index_utf8_length text) = 3);
  assert_bool "UTF-8 LIKE segmentation preserves complete characters"
    ((Rrbvec.to_list (Search.logseq_chat_search_index_utf8_chars text)) = ["a"; cjk; emoji]);
  assert_equal "LIKE wildcard characters are escaped"
    "%\\%%\\_%\\\\%" (Search.logseq_chat_search_index_fuzzy_like_pattern "%_\\");
  assert_equal "FTS embedded quotes are doubled"
    "\"say \"\"hello\"\"\"*" (Search.logseq_chat_search_index_get_match_input "say \"hello\"");
  assert_bool "fuzzy exact score is preserved" ((Search.logseq_chat_search_index_fuzzy_score "abc" "abc") = 1018.);
  assert_bool "fuzzy empty score is preserved" ((Search.logseq_chat_search_index_fuzzy_score "" "") = 1012.)
;;

let () =
  let conn = seeded_conn () in
  let index = temp_index () in
  (Search.logseq_chat_search_index_refresh index (conn_db conn));
  let results = (Rrbvec.to_list
                   (Search.logseq_chat_search_index_search (fun _ -> false) 100 index
                      "movies")) in
  let ids = List.map (fun (result : Search.search_result) -> result.uuid) results in
  assert_bool "overlapping exact, FTS, and fuzzy candidates are deduplicated"
    (List.length ids = List.length (List.sort_uniq String.compare ids));
  assert_bool "limit zero returns no hits" ((Rrbvec.to_list
                                               (Search.logseq_chat_search_index_search (fun _ -> false) 0 index "movies")) = []);
  assert_bool "negative limit returns no hits" ((Rrbvec.to_list
                                                   (Search.logseq_chat_search_index_search (fun _ -> false) (-1) index
                                                      "movies")) = []);
  assert_bool "blank query returns no hits" ((Rrbvec.to_list
                                                (Search.logseq_chat_search_index_search (fun _ -> false) 100 index " \t\n")) = []);
  assert_bool "limit keeps the highest ranked hit"
    ((Rrbvec.to_list
        (Search.logseq_chat_search_index_search (fun _ -> false) 1 index "movies")) = [List.hd results]);
  assert_bool "SQL failure is an empty candidate set"
    ((Rrbvec.to_list
        (Search.logseq_chat_search_index_query_rows index
           "select id, page, title from missing_table"
           (Lg_runtime.Runtime_seq.of_list, []))) = []);
  (Search.logseq_chat_search_index_refresh index (conn_db conn));
  assert_bool "refresh is idempotent" ((Rrbvec.to_list
                                          (Search.logseq_chat_search_index_search (fun _ -> false) 100 index
                                             "movies")) = results)
;;

let () =
  let conn = seeded_conn () in
  let index = temp_index () in
  (Search.logseq_chat_search_index_refresh index (conn_db conn));
  (* Page results rank above block results for the same term. *)
  (match (Rrbvec.to_list
            (Search.logseq_chat_search_index_search (fun _ -> false) 100 index
               "movies")) with
   | first :: _ as results ->
     assert_equal "page ranks first" page_uuid first.Search.uuid;
     assert_bool "page flagged as page" first.Search.is_page;
     assert_bool "block match present" (Option.is_some (find_result results block_uuid))
   | [] -> failwith "search should match seeded blocks");
  (* Trigram FTS matches substrings inside words. *)
  assert_bool
    "substring match through trigram"
    (Option.is_some (find_result (Rrbvec.to_list
                                    (Search.logseq_chat_search_index_search (fun _ -> false) 100 index "ovie")) block_uuid));
  (* Short queries fall back to LIKE. *)
  assert_bool
    "two character query"
    (Option.is_some (find_result (Rrbvec.to_list
                                    (Search.logseq_chat_search_index_search (fun _ -> false) 100 index "4k")) block_uuid));
  (* CJK queries shorter than three characters also fall back to LIKE. *)
  assert_bool
    "cjk substring query"
    (Option.is_some
       (find_result (Rrbvec.to_list
                       (Search.logseq_chat_search_index_search (fun _ -> false) 100 index
                          "\231\148\181\229\189\177")) cjk_uuid));
  (* Stored uuid references are indexed as display text. *)
  (match find_result (Rrbvec.to_list
                        (Search.logseq_chat_search_index_search (fun _ -> false) 100 index
                           "Movies marathon")) ref_block_uuid with
   | Some result ->
     assert_equal "ref replaced with page name" "[[Movies]] marathon plan" result.Search.title
   | None -> failwith "uuid reference should be searchable by page name");
  (* Journal pages index their journal day. *)
  assert_bool
    "journal day query"
    (Option.is_some (find_result (Rrbvec.to_list
                                    (Search.logseq_chat_search_index_search (fun _ -> false) 100 index
                                       "20260816")) journal_uuid));
  (* Hidden pages stay out of the index. *)
  assert_bool
    "hidden page skipped"
    (Option.is_none (find_result (Rrbvec.to_list
                                    (Search.logseq_chat_search_index_search (fun _ -> false) 100 index
                                       "Secret")) hidden_uuid));
  (* Refresh diffs: retitle one block, delete another. *)
  ignore
    (transact_conn
       conn
       [ Add
           ( Lookup_ref ("block/uuid", Uuid block_uuid)
           , "block/title"
           , String "listen to jazz records" )
       ]);
  (Search.logseq_chat_search_index_refresh index (conn_db conn));
  assert_bool
    "stale title no longer matches"
    (Option.is_none (find_result (Rrbvec.to_list
                                    (Search.logseq_chat_search_index_search (fun _ -> false) 100 index
                                       "4k movies")) block_uuid));
  assert_bool
    "updated title matches"
    (Option.is_some (find_result (Rrbvec.to_list
                                    (Search.logseq_chat_search_index_search (fun _ -> false) 100 index "jazz")) block_uuid));
  ignore
    (transact_conn
       conn
       [ RetractEntity (Lookup_ref ("block/uuid", Uuid block_uuid)) ]);
  (Search.logseq_chat_search_index_refresh index (conn_db conn));
  assert_bool
    "deleted block leaves the index"
    (Option.is_none (find_result (Rrbvec.to_list
                                    (Search.logseq_chat_search_index_search (fun _ -> false) 100 index "jazz")) block_uuid))
;;
