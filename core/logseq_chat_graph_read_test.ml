open Datascript
module Protocol = Logseq_chat_lg_core_native
module Transit = Transit_core.Json

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

let many ?value_type () =
  { cardinality = Many
  ; unique = None
  ; indexed = true
  ; is_component = false
  ; no_history = false
  ; doc = None
  ; value_type
  ; tuple_attrs = None
  ; tuple_types = None
  }
;;

let identity uuid =
  Transit.Array [ Transit.Keyword "block/uuid"; Transit.Uuid uuid ]
;;

let change ?(upserts = []) ?(deleted = []) t : Protocol.sync_change_set =
  { format_version = 1
  ; graph_id = "graph-1"
  ; schema_version = "65.33"
  ; t_before = t - 1
  ; t
  ; upserts
  ; deleted
  ; operation_ids = []
  }
;;

let () =
  let page_uuid = "028f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" in
  let first_uuid = "028f7850-c6aa-7da0-8b3f-6dbb64aa4ec9" in
  let second_uuid = "028f7850-c6aa-7da0-8b3f-6dbb64aa4eca" in
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/name", one ~value_type:StringType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ~value_type:RefType ()
    ; "block/parent", one ~value_type:RefType ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "block/journal-day", one ()
    ; "logseq.property/deleted-at", one ~value_type:InstantType ()
    ]
  in
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "incremental-page")
           ; attrs =
               [ "block/uuid", One_value (Uuid page_uuid)
               ; "block/name", One_value (String "incremental-page")
               ; "block/title", One_value (String "Journal")
               ; "block/journal-day", One_value (Int 20260816)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid first_uuid)
               ; "block/title", One_value (String "First")
               ; "block/page", One_value (Ref_to (Temp_id "incremental-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "incremental-page"))
               ; "block/created-at", One_value (Instant 1)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid second_uuid)
               ; "block/title", One_value (String "Second")
               ; "block/page", One_value (Ref_to (Temp_id "incremental-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "incremental-page"))
               ; "block/created-at", One_value (Instant 2)
               ]
           }
       ]);
  let decrypted_titles = ref 0 in
  let decrypt_title title =
    incr decrypted_titles;
    Ok title
  in
  let projection =
    Logseq_chat_graph_projection.create ~decrypt_title (conn_db conn)
  in
  decrypted_titles := 0;
  ignore
    (transact_conn
       conn
       [ Add
           ( Lookup_ref ("block/uuid", Uuid first_uuid)
           , "block/title"
           , String "First updated" )
       ]);
  let first_change =
    change
      ~upserts:
        [ { Protocol.id = identity first_uuid
          ; attrs = [ Transit.Keyword "block/title", Transit.String "First updated" ]
          }
        ]
      2
  in
  Logseq_chat_graph_projection.update projection (conn_db conn) first_change;
  if !decrypted_titles > 2
  then failwith "a block update rebuilt unrelated journal blocks";
  (match Logseq_chat_graph_projection.blocks projection with
   | [ first; second ] ->
     if first.title <> "First updated" || second.title <> "Second"
     then failwith "incremental block projection returned stale titles"
   | _ -> failwith "incremental projection lost a journal block");
  decrypted_titles := 0;
  ignore
    (transact_conn
       conn
       [ Add
           ( Lookup_ref ("block/uuid", Uuid page_uuid)
           , "block/title"
           , String "Journal updated" )
       ]);
  Logseq_chat_graph_projection.update
    projection
    (conn_db conn)
    (change
       ~upserts:
         [ { Protocol.id = identity page_uuid
           ; attrs = [ Transit.Keyword "block/title", Transit.String "Journal updated" ]
           }
         ]
       3);
  if !decrypted_titles > 4
  then failwith "a page title update rebuilt the journal projection";
  (match Logseq_chat_graph_projection.blocks projection with
   | [ first; second ] ->
     if first.journal <> Some ("Journal updated", 20260816)
        || second.journal <> Some ("Journal updated", 20260816)
     then failwith "page metadata was not refreshed for dependent blocks"
   | _ -> failwith "page metadata refresh lost a journal block");
  let first_eid = Option.get (entid (conn_db conn) "block/uuid" (Uuid first_uuid)) in
  ignore (transact_conn conn [ RetractEntity (Entity_id first_eid) ]);
  Logseq_chat_graph_projection.update
    projection
    (conn_db conn)
    (change ~deleted:[ identity first_uuid ] 4);
  (match Logseq_chat_graph_projection.blocks projection with
   | [ remaining ] when remaining.uuid = second_uuid -> ()
   | _ -> failwith "incremental projection did not remove a deleted block");
  let next_page_uuid = "028f7850-c6aa-7da0-8b3f-6dbb64aa4ecb" in
  let next_block_uuid = "028f7850-c6aa-7da0-8b3f-6dbb64aa4ecc" in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "next-page")
           ; attrs =
               [ "block/uuid", One_value (Uuid next_page_uuid)
               ; "block/name", One_value (String "next-page")
               ; "block/title", One_value (String "Next journal")
               ; "block/journal-day", One_value (Int 20260817)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid next_block_uuid)
               ; "block/title", One_value (String "Next block")
               ; "block/page", One_value (Ref_to (Temp_id "next-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "next-page"))
               ; "block/created-at", One_value (Instant 3)
               ]
           }
       ]);
  Logseq_chat_graph_projection.update
    projection
    (conn_db conn)
    (change
       ~upserts:
         [ { Protocol.id = identity next_page_uuid
           ; attrs = [ Transit.Keyword "block/journal-day", Transit.Int 20260817 ]
           }
         ]
       5);
  let latest_page_eid = Option.get (entid (conn_db conn) "block/uuid" (Uuid next_page_uuid)) in
  if Logseq_chat_graph_read.recent_journal_page_ids ~limit:1 (conn_db conn)
     <> [ latest_page_eid ]
  then failwith "journal reads must honor the bounded newest-first window";
  if Logseq_chat_graph_read.journal_page_count (conn_db conn) <> 2
  then failwith "journal pagination must expose whether older pages remain";
  ignore
    (transact_conn
       conn
       [ Add
           ( Lookup_ref ("block/uuid", Uuid next_page_uuid)
           , "logseq.property/deleted-at"
           , Instant 6 )
       ]);
  if Logseq_chat_graph_read.recent_journal_page_ids (conn_db conn) <> [
       Option.get (entid (conn_db conn) "block/uuid" (Uuid page_uuid))
     ]
  then failwith "recycled journals must be excluded from the journal window";
  if List.exists
       (fun (block : Logseq_chat_model.block) -> block.page_id = next_page_uuid)
       (Logseq_chat_graph_read.blocks (conn_db conn))
  then failwith "blocks below a recycled journal must not remain visible";
  if Logseq_chat_graph_read.journal_page_count (conn_db conn) <> 1
  then failwith "recycled journals must not count toward pagination";
  if Logseq_chat_graph_read.journal_page_uuid (conn_db conn) ~journal_day:20260817 <> None
  then failwith "recycled journals must not resolve as today's journal";
  Logseq_chat_graph_projection.update
    projection
    (conn_db conn)
    (change
       ~upserts:
         [ { Protocol.id = identity next_page_uuid
           ; attrs =
               [ Transit.Keyword "logseq.property/deleted-at", Transit.Date 6L ]
           }
         ]
       6);
  match Logseq_chat_graph_projection.blocks projection with
  | [ old_block ] when old_block.uuid = second_uuid -> ()
  | _ -> failwith "recycling a journal did not evict its blocks from the projection"
;;

let () =
  let page_uuid = "038f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" in
  let block_uuid = "038f7850-c6aa-7da0-8b3f-6dbb64aa4ec9" in
  let tag_uuid = "038f7850-c6aa-7da0-8b3f-6dbb64aa4eca" in
  let object_uuid = "038f7850-c6aa-7da0-8b3f-6dbb64aa4ecb" in
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/name", one ~value_type:StringType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ~value_type:RefType ()
    ; "block/parent", one ~value_type:RefType ()
    ; "block/tags", many ~value_type:RefType ()
    ; "block/refs", many ~value_type:RefType ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "logseq.property/hide?", one ()
    ; "logseq.property/deleted-at", one ~value_type:InstantType ()
    ; "logseq.property/view-for", one ~value_type:RefType ()
    ]
  in
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "node-page")
           ; attrs =
               [ "block/uuid", One_value (Uuid page_uuid)
               ; "block/name", One_value (String "node-page")
               ; "block/title", One_value (String "Node page")
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "tag")
           ; attrs =
               [ "block/uuid", One_value (Uuid tag_uuid)
               ; "block/name", One_value (String "project")
               ; "block/title", One_value (String "Project")
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "parent-block")
           ; attrs =
               [ "block/uuid", One_value (Uuid "parent-block")
               ; "block/title", One_value (String "Parent block")
               ; "block/page", One_value (Ref_to (Temp_id "node-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "node-page"))
               ; "block/created-at", One_value (Instant 1)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid block_uuid)
               ; "block/title", One_value (String "Referenced block")
               ; "block/page", One_value (Ref_to (Temp_id "node-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "node-page"))
               ; "block/created-at", One_value (Instant 1)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid object_uuid)
               ; "block/title", One_value (String "Tagged object")
               ; "block/page", One_value (Ref_to (Temp_id "node-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "parent-block"))
               ; "block/tags", Many_values [ Ref_to (Temp_id "tag") ]
               ; "block/created-at", One_value (Instant 2)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "linked-reference")
               ; "block/title", One_value (String "Linked reference")
               ; "block/page", One_value (Ref_to (Temp_id "node-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "node-page"))
               ; "block/refs", Many_values [ Ref_to (Temp_id "node-page") ]
               ; "block/created-at", One_value (Instant 3)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "hidden-tagged-object")
               ; "block/title", One_value (String "Hidden tagged object")
               ; "block/page", One_value (Ref_to (Temp_id "node-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "node-page"))
               ; "block/tags", Many_values [ Ref_to (Temp_id "tag") ]
               ; "logseq.property/hide?", One_value (Bool true)
               ; "block/created-at", One_value (Instant 4)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "view-linked-reference")
               ; "block/title", One_value (String "View linked reference")
               ; "block/page", One_value (Ref_to (Temp_id "node-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "node-page"))
               ; "block/refs", Many_values [ Ref_to (Temp_id "node-page") ]
               ; "logseq.property/view-for", One_value (Ref_to (Temp_id "tag"))
               ; "block/created-at", One_value (Instant 5)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "recycled-linked-reference")
               ; "block/title", One_value (String "Recycled linked reference")
               ; "block/page", One_value (Ref_to (Temp_id "node-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "node-page"))
               ; "block/refs", Many_values [ Ref_to (Temp_id "node-page") ]
               ; "logseq.property/deleted-at", One_value (Instant 6)
               ; "block/created-at", One_value (Instant 6)
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "hidden-parent")
           ; attrs =
               [ "block/uuid", One_value (Uuid "hidden-parent")
               ; "block/title", One_value (String "Hidden parent")
               ; "block/page", One_value (Ref_to (Temp_id "node-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "node-page"))
               ; "logseq.property/hide?", One_value (Bool true)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "hidden-child")
               ; "block/title", One_value (String "Hidden child")
               ; "block/page", One_value (Ref_to (Temp_id "node-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "hidden-parent"))
               ]
           }
       ]);
  let db = conn_db conn in
  (match Logseq_chat_graph_read.node_destination db page_uuid with
   | Some (page, false) when page.uuid = page_uuid && page.title = "Node page" -> ()
   | _ -> failwith "a page node reference did not resolve to its outliner page");
  (match Logseq_chat_graph_read.node_destination db block_uuid with
   | Some (page, true) when page.uuid = page_uuid -> ()
   | _ -> failwith "an ordinary block node reference did not resolve to its containing page");
  if Logseq_chat_graph_read.node_destination db "hidden-parent" <> None
     || Logseq_chat_graph_read.node_destination db "hidden-child" <> None
  then failwith "hidden blocks must not remain node navigation destinations";
  (match Logseq_chat_graph_read.objects_for_tag db tag_uuid with
   | [ block ]
     when block.uuid = object_uuid
          && block.title = "Tagged object"
          && List.map
               (fun (summary : Logseq_chat_model.entity_summary) -> summary.title)
               block.breadcrumbs
             = [ "Node page"; "Parent block" ] -> ()
   | _ -> failwith "tag objects were not read from the projected Datascript DB");
  (match Logseq_chat_graph_read.references_for_node db page_uuid with
   | [ block ]
     when block.uuid = "linked-reference"
          && block.title = "Linked reference"
          && List.map
               (fun (summary : Logseq_chat_model.entity_summary) -> summary.title)
               block.breadcrumbs
             = [ "Node page" ] -> ()
   | _ -> failwith "linked references were not read from the projected Datascript DB")
;;

let () =
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/name", one ~value_type:StringType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ~value_type:RefType ()
    ; "block/parent", one ~value_type:RefType ()
    ; "block/order", one ~value_type:StringType ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "block/journal-day", one ()
    ]
  in
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "older-page")
           ; attrs =
               [ "block/uuid", One_value (Uuid "older-page")
               ; "block/name", One_value (String "older-page")
               ; "block/title", One_value (String "Older")
               ; "block/journal-day", One_value (Int 20260827)
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "newer-page")
           ; attrs =
               [ "block/uuid", One_value (Uuid "newer-page")
               ; "block/name", One_value (String "newer-page")
               ; "block/title", One_value (String "Newer")
               ; "block/journal-day", One_value (Int 20260828)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "older-first")
               ; "block/title", One_value (String "Older first")
               ; "block/page", One_value (Ref_to (Temp_id "older-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "older-page"))
               ; "block/order", One_value (String "a0")
               ; "block/created-at", One_value (Instant 10)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "newer-second")
               ; "block/title", One_value (String "Newer second")
               ; "block/page", One_value (Ref_to (Temp_id "newer-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "newer-page"))
               ; "block/order", One_value (String "a1")
               ; "block/created-at", One_value (Instant 20)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "older-second")
               ; "block/title", One_value (String "Older second")
               ; "block/page", One_value (Ref_to (Temp_id "older-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "older-page"))
               ; "block/order", One_value (String "a1")
               ; "block/created-at", One_value (Instant 30)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "newer-first")
               ; "block/title", One_value (String "Newer first")
               ; "block/page", One_value (Ref_to (Temp_id "newer-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "newer-page"))
               ; "block/order", One_value (String "a0")
               ; "block/created-at", One_value (Instant 40)
               ]
           }
       ]);
  let uuids =
    Logseq_chat_graph_read.blocks ~journal_limit:2 (conn_db conn)
    |> List.map (fun block -> block.Logseq_chat_model.uuid)
  in
  if uuids <> [ "newer-first"; "newer-second"; "older-first"; "older-second" ]
  then failwith "journal blocks must stay grouped newest-first in outliner order"
;;

let () =
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/name", one ~value_type:StringType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ~value_type:RefType ()
    ; "block/parent", one ~value_type:RefType ()
    ; "block/tags", many ~value_type:RefType ()
    ; "logseq.property.class/extends", many ~value_type:RefType ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "db/ident", one ~value_type:KeywordType ~unique:(Some Identity) ()
    ]
  in
  let conn = create_conn ~schema () in
  let entity id attrs = Entity { db_id = Some (Temp_id id); attrs } in
  ignore
    (transact_conn
       conn
       [ entity "tag-class" [ "db/ident", One_value (Keyword "logseq.class/Tag") ]
       ; entity "asset-class" [ "db/ident", One_value (Keyword "logseq.class/Asset") ]
       ; entity "property-class" [ "db/ident", One_value (Keyword "logseq.class/Property") ]
       ; entity
           "status-property"
           [ "block/uuid", One_value (Uuid "status-property")
           ; "block/name", One_value (String "status")
           ; "block/title", One_value (String "Status")
           ; "block/tags", Many_values [ Ref_to (Temp_id "property-class") ]
           ]
       ; entity
           "page"
           [ "block/uuid", One_value (Uuid "page")
           ; "block/name", One_value (String "page")
           ; "block/title", One_value (String "Page")
           ]
       ; entity
           "parent-tag"
           [ "block/uuid", One_value (Uuid "parent-tag")
           ; "block/name", One_value (String "parent tag")
           ; "block/title", One_value (String "Parent tag")
           ; "block/tags", Many_values [ Ref_to (Temp_id "tag-class") ]
           ; ( "logseq.property.class/extends"
             , Many_values [ Ref_to (Temp_id "grandchild-tag") ] )
           ]
       ; entity
           "child-tag"
           [ "block/uuid", One_value (Uuid "child-tag")
           ; "block/name", One_value (String "child tag")
           ; "block/title", One_value (String "Child tag")
           ; "block/tags", Many_values [ Ref_to (Temp_id "tag-class") ]
           ; ( "logseq.property.class/extends"
             , Many_values [ Ref_to (Temp_id "parent-tag") ] )
           ]
       ; entity
           "grandchild-tag"
           [ "block/uuid", One_value (Uuid "grandchild-tag")
           ; "block/name", One_value (String "grandchild tag")
           ; "block/title", One_value (String "Grandchild tag")
           ; "block/tags", Many_values [ Ref_to (Temp_id "tag-class") ]
           ; ( "logseq.property.class/extends"
             , Many_values [ Ref_to (Temp_id "child-tag") ] )
           ]
       ; entity
           "tagged-object"
           [ "block/uuid", One_value (Uuid "tagged-object")
           ; "block/title", One_value (String "Tagged through a descendant")
           ; "block/page", One_value (Ref_to (Temp_id "page"))
           ; "block/parent", One_value (Ref_to (Temp_id "page"))
           ; "block/tags", Many_values [ Ref_to (Temp_id "grandchild-tag") ]
           ; "block/created-at", One_value (Instant 1)
           ]
       ; entity
           "tagged-page"
           [ "block/uuid", One_value (Uuid "tagged-page")
           ; "block/name", One_value (String "tagged page")
           ; "block/title", One_value (String "Tagged page")
           ; "block/tags", Many_values [ Ref_to (Temp_id "grandchild-tag") ]
           ; "block/created-at", One_value (Instant 3)
           ]
       ; entity
           "asset-child"
           [ "block/uuid", One_value (Uuid "asset-child")
           ; "block/name", One_value (String "asset child")
           ; "block/title", One_value (String "Asset child")
           ; ( "logseq.property.class/extends"
             , Many_values [ Ref_to (Temp_id "asset-class") ] )
           ]
       ; entity
           "asset-object"
           [ "block/uuid", One_value (Uuid "asset-object")
           ; "block/title", One_value (String "Asset")
           ; "block/page", One_value (Ref_to (Temp_id "page"))
           ; "block/parent", One_value (Ref_to (Temp_id "page"))
           ; "block/tags", Many_values [ Ref_to (Temp_id "asset-child") ]
           ; "block/created-at", One_value (Instant 2)
           ]
       ]);
  let db = conn_db conn in
  if not (Logseq_chat_graph_read.node_is_tag db "child-tag")
  then failwith "a class that extends another tag must still use the tag node route";
  if not (Logseq_chat_graph_read.node_is_property db "status-property")
  then failwith "pages tagged #Property must be identified as property nodes";
  if Logseq_chat_graph_read.node_is_property db "tagged-page"
  then failwith "ordinary pages must not be identified as property nodes";
  (* Tagged nodes are ordinary blocks and whole pages (like journals tagged
     #Journal or property pages tagged #Property). *)
  (match Logseq_chat_graph_read.objects_for_tag db "parent-tag" with
   | [ block; page ]
     when String.equal block.uuid "tagged-object"
          && String.equal page.uuid "tagged-page"
          && String.equal page.page_id "tagged-page"
          && page.parent_id = None -> ()
   | _ ->
     failwith
       "tagged nodes must include blocks and page entities of transitively extending tags");
  match Logseq_chat_graph_read.blocks_for_page db "page" with
  | blocks ->
    (match
       List.find_opt
         (fun (block : Logseq_chat_model.block) -> String.equal block.uuid "asset-object")
         blocks
     with
     | Some block when block.is_asset -> ()
     | _ -> failwith "asset classification must follow block/tags and class extends")
;;

let () =
  let page_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" in
  let block_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec9" in
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/name", one ~value_type:StringType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ~value_type:RefType ()
    ; "block/parent", one ~value_type:RefType ()
    ; "block/order", one ~value_type:StringType ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "block/updated-at", one ~value_type:InstantType ()
    ; "logseq.property/hide?", one ()
    ; "block/journal-day", one ()
    ]
  in
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "page")
           ; attrs =
               [ "block/uuid", One_value (Uuid page_uuid)
               ; "block/name", One_value (String "page")
               ; "block/title", One_value (String "Page")
               ; "block/journal-day", One_value (Int 20260815)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid block_uuid)
               ; "block/title", One_value (String "Desktop seed")
               ; "block/page", One_value (Ref_to (Temp_id "page"))
               ; "block/parent", One_value (Ref_to (Temp_id "page"))
               ; "block/order", One_value (String "a1")
               ; "block/created-at", One_value (Instant 1_776_000_000_000)
               ; "block/updated-at", One_value (Instant 1_776_000_000_001)
               ]
           }
       ]);
  if Logseq_chat_graph_read.journal_page_uuid (conn_db conn) ~journal_day:20260815
     <> Some page_uuid
  then failwith "journal day must resolve to the graph page UUID";
  if Logseq_chat_graph_read.journal_page_uuid (conn_db conn) ~journal_day:20260816
     <> None
  then failwith "missing journal day must not resolve to a placeholder";
  (match Logseq_chat_graph_read.blocks (conn_db conn) with
  | [ block ] ->
    if not (String.equal block.Logseq_chat_model.uuid block_uuid)
    then failwith "graph block UUID changed";
    if not (String.equal block.title "Desktop seed")
    then failwith "graph block title changed";
    if not (String.equal block.page_id page_uuid)
    then failwith "graph page reference was not projected";
    if block.order <> Some "a1"
    then failwith "graph outliner order was not projected";
    if block.created_at <> 1_776_000_000_000
    then failwith "graph instant timestamp changed";
    if block.journal <> Some ("Page", 20260815)
    then failwith "graph journal metadata was not projected"
  | _ -> failwith "graph reader must return non-page blocks only");
  ignore
    (transact_conn
       conn
       [ Add (Lookup_ref ("block/uuid", Uuid block_uuid), "block/title", String "cipher-block")
       ; Add (Lookup_ref ("block/uuid", Uuid page_uuid), "block/title", String "cipher-page")
       ]);
  let decrypt_title = function
    | "cipher-block" -> Ok "Decrypted block"
    | "cipher-page" -> Ok "Decrypted journal"
    | value -> Ok value
  in
  match Logseq_chat_graph_read.blocks ~decrypt_title (conn_db conn) with
  | [ block ] ->
    if not (String.equal block.Logseq_chat_model.title "Decrypted block")
    then failwith "encrypted block title was not decrypted for the projection";
    if block.journal <> Some ("Decrypted journal", 20260815)
    then failwith "encrypted journal title was not decrypted for the projection"
  | _ -> failwith "encrypted graph reader must return non-page blocks only"
;;

let () =
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/name", one ~value_type:StringType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ()
    ; "block/parent", one ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "block/journal-day", one ()
    ; "block/refs", many ~value_type:RefType ()
    ; "block/tags", many ~value_type:RefType ()
    ; "logseq.property.class/hide-from-node", one ()
    ; "db/ident", one ~value_type:KeywordType ~unique:(Some Identity) ()
    ]
  in
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "tag-class")
           ; attrs = [ "db/ident", One_value (Keyword "logseq.class/Tag") ]
           }
       ; Entity
           { db_id = Some (Temp_id "journal")
           ; attrs =
               [ "block/uuid", One_value (Uuid "journal")
               ; "block/name", One_value (String "journal")
               ; "block/title", One_value (String "Journal")
               ; "block/journal-day", One_value (Int 20260817)
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "page-target")
           ; attrs =
               [ "block/uuid", One_value (Uuid "page-target")
               ; "block/name", One_value (String "page target")
               ; "block/title", One_value (String "Page target")
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "block-target")
           ; attrs =
               [ "block/uuid", One_value (Uuid "block-target")
               ; "block/title", One_value (String "Block target")
               ; "block/page", One_value (Ref_to (Temp_id "journal"))
               ; "block/parent", One_value (Ref_to (Temp_id "journal"))
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "tag-target")
           ; attrs =
               [ "block/uuid", One_value (Uuid "tag-target")
               ; "block/name", One_value (String "project")
               ; "block/title", One_value (String "Project")
               ; "block/tags", Many_values [ Ref_to (Temp_id "tag-class") ]
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "public-built-in-tag")
           ; attrs =
               [ "block/uuid", One_value (Uuid "public-built-in-tag")
               ; "block/name", One_value (String "card")
               ; "block/title", One_value (String "Card")
               ; "block/tags", Many_values [ Ref_to (Temp_id "tag-class") ]
               ; "db/ident", One_value (Keyword "logseq.class/Card")
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "internal-tag")
           ; attrs =
               [ "block/uuid", One_value (Uuid "internal-tag")
               ; "block/name", One_value (String "task")
               ; "block/title", One_value (String "Task")
               ; "block/tags", Many_values [ Ref_to (Temp_id "tag-class") ]
               ; "db/ident", One_value (Keyword "logseq.class/Task")
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid "source")
               ; "block/title", One_value (String "Source")
               ; "block/page", One_value (Ref_to (Temp_id "journal"))
               ; "block/parent", One_value (Ref_to (Temp_id "journal"))
               ; "block/created-at", One_value (Instant 1)
               ; ( "block/refs"
                 , Many_values
                     [ Ref_to (Temp_id "page-target"); Ref_to (Temp_id "block-target") ] )
               ; ( "block/tags"
                 , Many_values
                     [ Ref_to (Temp_id "tag-target")
                     ; Ref_to (Temp_id "public-built-in-tag")
                     ; Ref_to (Temp_id "internal-tag")
                     ] )
               ]
           }
       ]);
  let db = conn_db conn in
  (match
     Logseq_chat_graph_read.tag_pages db
     |> List.map (fun (tag : Logseq_chat_graph_read.sidebar_page) -> tag.uuid, tag.title)
     |> List.sort compare
   with
   | [ "internal-tag", "Task"; "public-built-in-tag", "Card"; "tag-target", "Project" ] -> ()
   | _ ->
     failwith
       "tag autocomplete pages must include public built-ins and hide internal tags");
  match
    Logseq_chat_graph_read.blocks db
    |> List.find_opt (fun block -> String.equal block.Logseq_chat_model.uuid "source")
  with
  | None -> failwith "source block missing from graph projection"
  | Some block ->
    let summaries values =
      List.map
        (fun (summary : Logseq_chat_model.entity_summary) ->
          summary.uuid, summary.title)
        values
      |> List.sort compare
    in
    if
      summaries block.references
      <> [ "block-target", "Block target"
         ; "page-target", "Page target"
         ]
    then failwith "node references must resolve page and ordinary-block targets";
    if
      summaries block.tags
      <> [ "public-built-in-tag", "Card"; "tag-target", "Project" ]
    then
      failwith
        "visible tags must include public built-ins and hide internal tags";
    let projection = Logseq_chat_graph_projection.create (conn_db conn) in
    ignore
      (transact_conn
         conn
         [ Add
             ( Lookup_ref ("block/uuid", Uuid "page-target")
             , "block/title"
             , String "Renamed page" )
         ]);
    Logseq_chat_graph_projection.update
      projection
      (conn_db conn)
      (change
         ~upserts:
           [ { Protocol.id = identity "page-target"
             ; attrs = [ Transit.Keyword "block/title", Transit.String "Renamed page" ]
             }
           ]
         2);
    (match
       Logseq_chat_graph_projection.blocks projection
       |> List.find_opt (fun block -> String.equal block.Logseq_chat_model.uuid "source")
     with
     | Some source
       when summaries source.references
            = [ "block-target", "Block target"
              ; "page-target", "Renamed page"
              ] -> ()
     | _ -> failwith "referenced target changes must refresh referring projection blocks")
;;

let () =
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/name", one ~value_type:StringType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ~value_type:RefType ()
    ; "block/link", one ~value_type:RefType ()
    ; "block/order", one ~value_type:StringType ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "block/updated-at", one ~value_type:InstantType ()
    ]
  in
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "favorites")
           ; attrs =
               [ "block/uuid", One_value (Uuid "favorites-page")
               ; "block/name", One_value (String "$$$favorites")
               ; "block/title", One_value (String "Favorites")
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "alpha")
           ; attrs =
               [ "block/uuid", One_value (Uuid "page-alpha")
               ; "block/name", One_value (String "alpha")
               ; "block/title", One_value (String "Alpha")
               ; "block/updated-at", One_value (Instant 200)
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "beta")
           ; attrs =
               [ "block/uuid", One_value (Uuid "page-beta")
               ; "block/name", One_value (String "beta")
               ; "block/title", One_value (String "Beta")
               ; "block/updated-at", One_value (Instant 300)
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "hidden")
           ; attrs =
               [ "block/uuid", One_value (Uuid "page-hidden")
               ; "block/name", One_value (String "hidden")
               ; "block/title", One_value (String "Hidden")
               ; "block/updated-at", One_value (Instant 400)
               ; "logseq.property/hide?", One_value (Bool true)
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "seeded-recent")
           ; attrs =
               [ "block/uuid", One_value (Uuid "page-seeded-recent")
               ; "block/name", One_value (String "seeded-recent")
               ; "block/title", One_value (String "Seeded recent")
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "built-in-page")
           ; attrs =
               [ "block/uuid", One_value (Uuid "page-built-in")
               ; "block/name", One_value (String "built-in-page")
               ; "block/title", One_value (String "Built-in page")
               ; "block/updated-at", One_value (Instant 500)
               ; "logseq.property/built-in?", One_value (Bool true)
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "favorite-alpha")
           ; attrs =
               [ "block/uuid", One_value (Uuid "favorite-alpha")
               ; "block/title", One_value (String "")
               ; "block/page", One_value (Ref_to (Temp_id "favorites"))
               ; "block/link", One_value (Ref_to (Temp_id "alpha"))
               ; "block/order", One_value (String "b")
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "favorite-beta")
           ; attrs =
               [ "block/uuid", One_value (Uuid "favorite-beta")
               ; "block/title", One_value (String "")
               ; "block/page", One_value (Ref_to (Temp_id "favorites"))
               ; "block/link", One_value (Ref_to (Temp_id "beta"))
               ; "block/order", One_value (String "a")
               ]
           }
       ; Entity
           { db_id = Some (Temp_id "alpha-block")
           ; attrs =
               [ "block/uuid", One_value (Uuid "alpha-block")
               ; "block/title", One_value (String "Alpha content")
               ; "block/page", One_value (Ref_to (Temp_id "alpha"))
               ; "block/created-at", One_value (Instant 100)
               ; "block/updated-at", One_value (Instant 100)
               ]
           }
       ]);
  let sidebar = Logseq_chat_graph_read.sidebar_pages (conn_db conn) in
  if List.map (fun page -> page.Logseq_chat_graph_read.uuid) sidebar.favorites
     <> [ "page-beta"; "page-alpha" ]
  then failwith "favorites must preserve their graph order";
  if List.map (fun page -> page.Logseq_chat_graph_read.uuid) sidebar.recent_pages
     <> [ "page-seeded-recent" ]
  then failwith "recent pages must exclude favorites and built-in pages";
  if List.exists
       (fun page -> page.Logseq_chat_graph_read.uuid = "favorites-page")
       sidebar.recent_pages
  then failwith "hidden built-in pages must not appear in recent pages"
  else
    match Logseq_chat_graph_read.blocks_for_page (conn_db conn) "page-alpha" with
    | [ block ] when block.Logseq_chat_model.uuid = "alpha-block" -> ()
    | _ -> failwith "opening a sidebar page must read that page's blocks by UUID"
;;

let () =
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/name", one ~value_type:StringType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ~value_type:RefType ()
    ; "block/parent", one ~value_type:RefType ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "block/journal-day", one ()
    ]
  in
  let conn = create_conn ~schema () in
  let entities =
    List.init 1_000 (fun index ->
      let page_id = "large-page-" ^ string_of_int index in
      [ Entity
          { db_id = Some (Temp_id page_id)
          ; attrs =
              [ "block/uuid", One_value (Uuid page_id)
              ; "block/name", One_value (String page_id)
              ; "block/title", One_value (String ("Journal " ^ string_of_int index))
              ; "block/journal-day", One_value (Int (2_000_000 + index))
              ]
          }
      ; Entity
          { db_id = None
          ; attrs =
              [ "block/uuid", One_value (Uuid ("large-block-" ^ string_of_int index))
              ; "block/title", One_value (String ("Block " ^ string_of_int index))
              ; "block/page", One_value (Ref_to (Temp_id page_id))
              ; "block/parent", One_value (Ref_to (Temp_id page_id))
              ; "block/created-at", One_value (Instant index)
              ]
          }
      ])
    |> List.concat
  in
  ignore (transact_conn conn entities);
  let decrypt_count = ref 0 in
  let decrypt_title value =
    incr decrypt_count;
    Ok value
  in
  let visible =
    Logseq_chat_graph_read.blocks ~decrypt_title ~journal_limit:7 (conn_db conn)
  in
  if List.length visible <> 7
  then failwith "large graphs must materialize only the requested journal window";
  if !decrypt_count <> 14
  then failwith "older journal titles must not be decrypted or materialized";
  if Logseq_chat_graph_read.journal_page_count (conn_db conn) <> 1_000
  then failwith "bounded reads must retain an accurate older-journal indicator";
  if
    List.map (fun block -> block.Logseq_chat_model.uuid) visible
    <> List.init 7 (fun offset -> "large-block-" ^ string_of_int (999 - offset))
  then failwith "bounded journal reads must preserve stable block identities and order"
;;

let () =
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/name", one ~value_type:StringType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ()
    ; "block/parent", one ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "block/journal-day", one ()
    ]
  in
  let db =
    empty_db ~schema ()
    |> db_with
         [ Raw_datom (datom ~e:1 ~a:"block/uuid" ~v:(Uuid "raw-page") ())
         ; Raw_datom (datom ~e:1 ~a:"block/name" ~v:(String "raw-page") ())
         ; Raw_datom (datom ~e:1 ~a:"block/title" ~v:(String "Raw journal") ())
         ; Raw_datom (datom ~e:1 ~a:"block/journal-day" ~v:(Int 20260817) ())
         ; Raw_datom (datom ~e:2 ~a:"block/uuid" ~v:(Uuid "raw-block") ())
         ; Raw_datom (datom ~e:2 ~a:"block/title" ~v:(String "Restored block") ())
         ; Raw_datom (datom ~e:2 ~a:"block/page" ~v:(Int 1) ())
         ; Raw_datom (datom ~e:2 ~a:"block/parent" ~v:(Int 1) ())
         ; Raw_datom (datom ~e:2 ~a:"block/created-at" ~v:(Instant 1) ())
         ]
  in
  match Logseq_chat_graph_read.blocks db with
  | [ block ]
    when block.Logseq_chat_model.uuid = "raw-block"
         && block.page_id = "raw-page"
         && block.parent_id = Some "raw-page"
         && block.journal = Some ("Raw journal", 20260817) -> ()
  | _ -> failwith "raw numeric values under ref schema must remain navigable after restore"
;;

let () =
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; (* Page names are not unique in db graphs; duplicates must be detected. *)
      "block/name", { (one ~value_type:StringType ()) with indexed = true }
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ~value_type:RefType ()
    ; "block/parent", one ~value_type:RefType ()
    ; "block/refs", many ~value_type:RefType ()
    ; "block/tags", many ~value_type:RefType ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "db/ident", one ~value_type:KeywordType ~unique:(Some Identity) ()
    ]
  in
  let conn = create_conn ~schema () in
  let entity id attrs = Entity { db_id = Some (Temp_id id); attrs } in
  ignore
    (transact_conn
       conn
       [ entity "tag-class" [ "db/ident", One_value (Keyword "logseq.class/Tag") ]
       ; entity
           "project-tag"
           [ "block/uuid", One_value (Uuid "project-tag-uuid")
           ; "block/name", One_value (String "project")
           ; "block/title", One_value (String "Project")
           ; "block/tags", Many_values [ Ref_to (Temp_id "tag-class") ]
           ]
       ; entity
           "roadmap-page"
           [ "block/uuid", One_value (Uuid "roadmap-page-uuid")
           ; "block/name", One_value (String "roadmap")
           ; "block/title", One_value (String "Roadmap")
           ]
       ; entity
           "dup-a"
           [ "block/uuid", One_value (Uuid "dup-a-uuid")
           ; "block/name", One_value (String "dup")
           ; "block/title", One_value (String "Dup")
           ]
       ; entity
           "dup-b"
           [ "block/uuid", One_value (Uuid "dup-b-uuid")
           ; "block/name", One_value (String "dup")
           ; "block/title", One_value (String "Dup")
           ]
       ; entity
           "note"
           [ "block/uuid", One_value (Uuid "note-uuid")
           ; "block/title", One_value (String "Note")
           ; "block/refs", Many_values [ Ref_to (Temp_id "roadmap-page") ]
           ]
       ]);
  let db = conn_db conn in
  let normalize = Logseq_chat_graph_read.normalize_title_text db ~uuid:"note-uuid" in
  assert
    (String.equal
       (normalize "Ship [[Roadmap]] as #project and #[[Project]]")
       "Ship [[roadmap-page-uuid]] as #[[project-tag-uuid]] and #[[project-tag-uuid]]");
  (* A tag name is matched case-insensitively even for a brand-new mention. *)
  assert (String.equal (normalize "todo #PROJECT.") "todo #[[project-tag-uuid]].");
  (* An unknown or duplicated name must stay plain text instead of re-binding. *)
  assert (String.equal (normalize "see [[Dup]] and #nothing") "see [[Dup]] and #nothing");
  (* Page names never satisfy a hashtag, and uuid forms pass through. *)
  assert (String.equal (normalize "#roadmap stays") "#roadmap stays");
  assert (String.equal (normalize "kept [[roadmap-page-uuid]]") "kept [[roadmap-page-uuid]]");
  (* Hashtags naming no existing tag mint one shared fresh tag per name. *)
  let counter = ref 0 in
  let fresh_uuid () = incr counter; "fresh-" ^ string_of_int !counter in
  let titles, created =
    Logseq_chat_graph_read.normalize_titles_creating_tags
      db
      ~fresh_uuid
      ~uuid:"note-uuid"
      [ "start #foobar"; "end #FooBar and #project" ]
  in
  assert (titles = [ "start #[[fresh-1]]"; "end #[[fresh-1]] and #[[project-tag-uuid]]" ]);
  assert (created = [ "fresh-1", "foobar" ]);
  (* Without new hashtags nothing is created. *)
  let unchanged, none_created =
    Logseq_chat_graph_read.normalize_titles_creating_tags
      db
      ~fresh_uuid
      ~uuid:"note-uuid"
      [ "plain #project" ]
  in
  assert (unchanged = [ "plain #[[project-tag-uuid]]" ] && none_created = [])
;;

let () =
  let conn = create_conn () in
  let page eid title attrs =
    Entity
      { db_id = Some (Entity_id eid)
      ; attrs =
          [ "block/uuid", One_value (Uuid ("recent-" ^ string_of_int eid))
          ; "block/name", One_value (String ("recent-" ^ string_of_int eid))
          ; "block/title", One_value (String title)
          ; "block/updated-at", One_value (Instant eid)
          ] @ attrs
      }
  in
  ignore (transact_conn conn
    (List.init 100 (fun index -> page (index + 1) (string_of_int (index + 1)) [])
     @ [ page 101 "Hidden" ["logseq.property/hide?", One_value (Bool true)]
       ; page 102 "Built-in" ["logseq.property/built-in?", One_value (Bool true)]
       ; page 103 "Deleted" ["logseq.property/deleted-at", One_value (Instant 1)]
       ; page 104 "  " []
       ; page 105 "Hidden child" ["block/parent", One_value (Ref 101)]
       ]));
  let decrypted = ref [] in
  let decrypt_title title = decrypted := title :: !decrypted; Ok title in
  let sidebar = Logseq_chat_graph_read.sidebar_pages ~decrypt_title (conn_db conn) in
  let actual = List.map (fun page -> page.Logseq_chat_graph_read.uuid) sidebar.recent_pages in
  let expected = List.init 15 (fun index -> "recent-" ^ string_of_int (100 - index)) in
  if actual <> expected then failwith "recent window must fill past hidden and blank pages in newest-first order";
  if List.exists (fun title -> List.mem title !decrypted) ["1"; "85"]
  then failwith "recent window must not decrypt titles outside the visible 15 pages";
  if (Logseq_chat_graph_read.sidebar_pages (empty_db ())).recent_pages <> []
  then failwith "an empty graph must have no recent pages"
;;

let () =
  let schema =
    [ "block/uuid", one ~unique:(Some Identity) ()
    ; "db/ident", one ~unique:(Some Identity) ()
    ; "block/name", one ()
    ; "block/title", one ()
    ; "block/tags", many ~value_type:RefType ()
    ] in
  let conn = create_conn ~schema () in
  let tag eid name ident =
    [Add (Entity_id eid, "block/uuid", Uuid name);
     Add (Entity_id eid, "block/name", String (String.lowercase_ascii name));
     Add (Entity_id eid, "block/title", String name);
     Add (Entity_id eid, "db/ident", Keyword ident);
     Add (Entity_id eid, "block/tags", Ref 1)] in
  ignore (transact_conn conn
    (List.concat
       [ tag 1 "Tag" "logseq.class/Tag"; tag 2 "Root" "logseq.class/Root"
       ; tag 3 "Journal" "logseq.class/Journal"; tag 4 "Card" "logseq.class/Card"
       ; tag 5 "Task" "logseq.class/Task"; tag 6 "Alpha" "user.class/alpha"
       ; tag 7 "Zeta" "user.class/zeta"; tag 8 "Asset" "logseq.class/Asset"
       ; tag 9 "Page" "logseq.class/Page"; tag 10 "Property" "logseq.class/Property"
       ; tag 11 "Whiteboard" "logseq.class/Whiteboard"
       ; tag 12 "Pdf" "logseq.class/Pdf-annotation" ]));
  ignore (transact_conn conn [Add (Entity_id 20, "block/uuid", Uuid "older-use"); Add (Entity_id 20, "block/tags", Ref 6)]);
  ignore (transact_conn conn [Add (Entity_id 21, "block/uuid", Uuid "newer-use"); Add (Entity_id 21, "block/tags", Ref 7)]);
  let db = conn_db conn in
  let names pages = List.map (fun (page : Logseq_chat_graph_read.sidebar_page) -> page.title) pages in
  let recent = names (Logseq_chat_graph_read.sidebar_pages db).recent_pages in
  let tags = names (Logseq_chat_graph_read.tag_pages db) in
  let failures = ref [] in
  let check label condition =
    Printf.printf "%s: %s\n%!" (if condition then "PASS" else "FAIL") label;
    if not condition then failures := label :: !failures in
  check "Recent excludes built-in class idents even without a built-in flag"
    (List.sort String.compare recent = ["Alpha"; "Zeta"]);
  check "tag completion excludes Logseq private classes and Root but keeps public Task/Card"
    (List.sort String.compare tags = ["Alpha"; "Card"; "Task"; "Zeta"]);
  check "most recently assigned tags precede older tags"
    (match tags with "Zeta" :: "Alpha" :: _ -> true | _ -> false);
  if !failures <> [] then failwith (String.concat "; " !failures)
;;
