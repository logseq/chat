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
  ; "block/order", one ~value_type:StringType ()
  ; "block/refs", many ~value_type:RefType ()
  ; "block/tags", many ~value_type:RefType ()
  ; "logseq.property.class/extends", many ~value_type:RefType ()
  ; "block/journal-day", one ~value_type:NumberType ~indexed:true ()
  ; "block/created-at", one ~value_type:NumberType ()
  ; "block/updated-at", one ~value_type:NumberType ()
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
  if List.length (Logseq_chat_graph_read.blocks db) <> 8
  then failwith "the initial fixture window must contain seven pages and the link source";
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
;;
