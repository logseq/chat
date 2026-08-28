open Datascript
module Seed = Logseq_chat_e2e_seed_data

let one ?value_type ?unique ?(indexed = false) () =
  { cardinality = One; unique; indexed; is_component = false; no_history = false
  ; doc = None; value_type; tuple_attrs = None; tuple_types = None }
;;

let many ?value_type () =
  { (one ?value_type ~indexed:true ()) with cardinality = Many }
;;

let schema =
  [ "block/uuid", one ~unique:Identity ~value_type:UuidType ~indexed:true ()
  ; "block/name", one ~unique:Identity ~value_type:StringType ~indexed:true ()
  ; "block/title", one ~value_type:StringType ()
  ; "block/page", one ~value_type:RefType ~indexed:true ()
  ; "block/parent", one ~value_type:RefType ~indexed:true ()
  ; "block/link", one ~value_type:RefType ~indexed:true ()
  ; "block/order", one ~value_type:StringType ()
  ; "block/refs", many ~value_type:RefType ()
  ; "block/tags", many ~value_type:RefType ()
  ; "logseq.property.class/extends", many ~value_type:RefType ()
  ; "block/journal-day", one ~value_type:NumberType ~indexed:true ()
  ; "block/created-at", one ~value_type:NumberType ()
  ; "block/updated-at", one ~value_type:NumberType ()
  ; "logseq.property/built-in?", one ()
  ; "db/ident", one ~unique:Identity ~value_type:KeywordType ~indexed:true ()
  ]
;;

let () =
  let conn = create_conn ~schema () in
  (match Seed.seed conn with
   | Error message -> failwith message
   | Ok () -> ());
  let db = conn_db conn in
  if Logseq_chat_graph_read.journal_page_count db <> 8
  then failwith "the E2E fixture must exercise journal pagination";
  (match (Logseq_chat_graph_read.sidebar_pages db).favorites with
   | [ favorite ] when String.equal favorite.uuid (Seed.page_uuid 7) -> ()
   | _ -> failwith "the E2E fixture must expose the target page as a favorite");
  if List.length (Logseq_chat_graph_read.blocks db) <> 18
  then failwith "the initial fixture window must contain links and rich block examples";
  if
    Logseq_chat_graph_read.blocks db
    |> List.exists (fun block -> String.equal block.Logseq_chat_model.uuid Seed.older_block_uuid)
  then failwith "the earliest journal must stay outside the initial window";
  (match
     Logseq_chat_graph_read.blocks db
     |> List.find_opt (fun block -> String.equal block.Logseq_chat_model.uuid Seed.source_uuid)
   with
   | Some source ->
     if List.length source.references <> 2
     then failwith "the E2E source must cover both page and block references";
     if
       List.map
         (fun (item : Logseq_chat_model.entity_summary) -> item.uuid, item.title)
         source.tags
       |> List.sort compare
       <> [ Seed.tag_uuid, "E2E Project"; Seed.trailing_tag_uuid, "E2E Trailing" ]
     then failwith "the E2E source must cover inline and non-inline tag navigation";
     let rendered =
       Logseq_chat_markup.parse ~references:source.references ~tags:source.tags source.title
       |> List.map Logseq_chat_markup.debug_string
       |> String.concat " "
     in
     if not (String.contains rendered '(')
     then failwith "legacy parentheses must remain ordinary rendered text";
     let inline_tags =
       Logseq_chat_markup.parse ~references:source.references ~tags:source.tags source.title
       |> List.filter_map (function
         | Logseq_chat_markup.Tag_ref tag -> Some tag.uuid
         | _ -> None)
     in
     if inline_tags <> [ Seed.tag_uuid ]
     then failwith "only the tag encoded in the title may be rendered inline"
   | None -> failwith "the E2E link source is missing");
  if
    Logseq_chat_graph_read.objects_for_tag db Seed.tag_uuid
    |> List.exists (fun block -> String.equal block.Logseq_chat_model.title "E2E Child Tag Object")
    |> not
  then failwith "parent tagged nodes must include objects of extending tags"
  else
    match Logseq_chat_flashcards.due_cards db ~now:2_000_000_100_000 with
    | [ card ]
      when String.equal card.block.uuid "e2e00000-0000-4000-8000-000000000020"
           && String.equal card.block.title "The capital of France is {{cloze Paris}}"
           && List.map (fun child -> child.Logseq_chat_model.title) card.children
              = [ "Paris is the answer" ] -> ()
    | _ -> failwith "the E2E fixture must expose a due Logseq Card with its answer"
;;

let () =
  let conn = create_conn ~schema () in
  (match Seed.seed_outliner conn ~now:1_787_893_600_000 with
   | Error message -> failwith message
   | Ok () -> ());
  (match Seed.seed_outliner conn ~now:1_787_893_600_000 with
   | Error message -> failwith message
   | Ok () -> ());
  let db = conn_db conn in
  if Logseq_chat_graph_read.journal_page_count db <> 1
  then failwith "the resettable outliner fixture must keep only today's journal";
  if Datascript.entid db "block/uuid" (Uuid Seed.outliner_block_uuid) = None
  then failwith "the resettable outliner fixture must expose today's writable block";
  let visible_block_count = List.length (Logseq_chat_graph_read.blocks db) in
  if visible_block_count <> 1
  then
    failwith
      (Printf.sprintf
         "the resettable outliner fixture must remain idempotent (got %d visible blocks)"
         visible_block_count)
;;

let () =
  let conn = create_conn ~schema () in
  (match Seed.seed_fixture conn with
   | Error message -> failwith message
   | Ok () -> ());
  (match Seed.seed_fixture conn with
   | Error message -> failwith message
   | Ok () -> ());
  let db = conn_db conn in
  if Logseq_chat_graph_read.journal_page_count db <> 8
  then failwith "the resettable standard fixture must keep eight journals";
  if List.length (Logseq_chat_graph_read.blocks db) <> 18
  then failwith "the resettable standard fixture must remain idempotent"
;;

let () =
  let conn = create_conn ~schema () in
  (match Seed.seed_performance conn ~now:1_788_000_000_000 with
   | Error message -> failwith message
   | Ok () -> ());
  (match Seed.seed_performance conn ~now:1_788_000_000_000 with
   | Error message -> failwith message
   | Ok () -> ());
  let db = conn_db conn in
  if Logseq_chat_graph_read.journal_page_count db <> 100
  then failwith "the performance fixture must keep one hundred journals";
  if List.length (Logseq_chat_graph_read.blocks db) <> 56
  then failwith "the performance fixture must expose eight rows for seven journals"
;;

let () =
  let conn = create_conn ~schema () in
  (match Seed.seed_header_navigation conn with
   | Error message -> failwith message
   | Ok () -> ());
  let db = conn_db conn in
  if Logseq_chat_graph_read.journal_page_count db <> 1
  then failwith "the header fixture must create exactly one journal";
  match Logseq_chat_graph_read.blocks db with
  | [ block ]
    when block.journal = Some ("Aug 24th, 2026", 20260824)
         && String.equal block.title "E2E Header Navigation" -> ()
  | _ -> failwith "the header fixture must expose the Aug 24 navigation target"
;;

let () =
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "built-in-page")
           ; attrs =
               [ "block/uuid", One_value (Uuid "00000002-0000-4000-8000-000000000001")
               ; "block/title", One_value (String "Built in")
               ; "logseq.property/built-in?", One_value (Bool true)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "00000004-0000-4000-8000-000000000001")
               ; "block/title", One_value (String "Built-in child")
               ; "block/page", One_value (Ref_to (Temp_id "built-in-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "built-in-page"))
               ; "block/order", One_value (String "a0")
               ; "logseq.property/built-in?", One_value (Bool true)
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "stale-page")
           ; attrs =
               [ "block/uuid", One_value (Uuid "e2e-stale-page")
               ; "block/name", One_value (String "stale journal")
               ; "block/title", One_value (String "Stale Journal")
               ; "block/journal-day", One_value (Int 20260827)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "e2e-stale-block")
               ; "block/title", One_value (String "Stale composer traffic")
               ; "block/page", One_value (Ref_to (Temp_id "stale-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "stale-page"))
               ; "block/order", One_value (String "a0")
               ]
           }
       ]);
  (match Seed.seed_composer conn ~now:1_787_893_600_000 with
   | Error message -> failwith message
   | Ok () -> ());
  (match Seed.seed_composer conn ~now:1_787_893_600_000 with
   | Error message -> failwith message
   | Ok () -> ());
  let db = conn_db conn in
  if
    Datascript.entid db "block/uuid" (Uuid "00000002-0000-4000-8000-000000000001")
    = None
  then failwith "composer reset must preserve built-in graph entities";
  if
    Datascript.entid db "block/uuid" (Uuid "00000004-0000-4000-8000-000000000001")
    = None
  then failwith "composer reset must preserve built-in child entities";
  if Datascript.entid db "block/uuid" (Uuid "e2e-stale-page") <> None
  then failwith "composer reset must remove stale user pages";
  if Datascript.entid db "block/uuid" (Uuid "e2e-stale-block") <> None
  then failwith "composer reset must remove stale user blocks";
  if Logseq_chat_graph_read.journal_page_count db <> 1
  then failwith "composer reset must leave exactly one current journal";
  match Logseq_chat_graph_read.blocks db with
  | [ block ] when String.equal block.title "E2E Composer Fixture" -> ()
  | _ -> failwith "composer reset must be idempotent and expose one fixture block"
;;
