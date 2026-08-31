open Datascript

module Ops = Logseq_chat_pending_ops
module Projection = Logseq_chat_pending_projection

let fail label message = failwith (label ^ ": " ^ message)
let assert_bool label value = if not value then fail label "expected true"

let assert_string label expected actual =
  if not (String.equal expected actual)
  then fail label (Printf.sprintf "expected %S, got %S" expected actual)
;;

let one ?unique ?value_type ?(indexed = false) () =
  { cardinality = One; unique; indexed; is_component = false; no_history = false
  ; doc = None; value_type; tuple_attrs = None; tuple_types = None }
;;

let many ?value_type ?(indexed = false) () =
  { (one ?value_type ~indexed ()) with cardinality = Many }
;;

let schema =
  [ "block/uuid", one ~unique:Identity ~value_type:UuidType ~indexed:true ()
  ; "db/ident", one ~unique:Identity ~value_type:KeywordType ~indexed:true ()
  ; "block/title", one ~value_type:StringType ~indexed:true ()
  ; "block/name", one ~value_type:StringType ~indexed:true ()
  ; "block/page", one ~value_type:RefType ~indexed:true ()
  ; "block/parent", one ~value_type:RefType ~indexed:true ()
  ; "block/link", one ~value_type:RefType ~indexed:true ()
  ; "block/order", one ~value_type:StringType ~indexed:true ()
  ; "block/refs", many ~value_type:RefType ~indexed:true ()
  ; "block/tags", many ~value_type:RefType ~indexed:true ()
  ; "block/journal-day", one ~value_type:NumberType ~indexed:true ()
  ; "logseq.property/built-in?", one ~indexed:true ()
  ; "logseq.property/hide?", one ~indexed:true ()
  ; "logseq.property/deleted-at", one ~value_type:InstantType ~indexed:true ()
  ; "logseq.property.recycle/original-parent", one ~value_type:RefType ~indexed:true ()
  ; "logseq.property.recycle/original-page", one ~value_type:RefType ~indexed:true ()
  ; "logseq.property.recycle/original-order", one ~value_type:StringType ~indexed:true ()
  ; "logseq.property/status", one ~value_type:RefType ~indexed:true ()
  ; "logseq.property.class/extends", many ~value_type:RefType ~indexed:true ()
  ; "logseq.property.asset/type", one ~value_type:StringType ~indexed:true ()
  ; "logseq.property.asset/size", one ~value_type:NumberType ~indexed:true ()
  ; "logseq.property.asset/checksum", one ~value_type:StringType ~indexed:true ()
  ; "logseq.property.asset/remote-metadata", one ()
  ; "user.property/effort", one ~value_type:NumberType ~indexed:true ()
  ; "user.property/label", one ~value_type:StringType ~indexed:true ()
  ; "user.property/enabled", one ~indexed:true () ]
;;

let lookup uuid = Lookup_ref ("block/uuid", Uuid uuid)

let title db uuid =
  match entity db (lookup uuid) with
  | Some entity ->
    (match entity_attr entity "block/title" with
     | Some (One_value (String value)) -> value
     | _ -> fail "title" ("missing title for " ^ uuid))
  | None -> fail "title" ("missing entity for " ^ uuid)
;;

let has_ref db ~source ~target =
  match entid db "block/uuid" (Uuid source), entid db "block/uuid" (Uuid target) with
  | Some source_eid, Some target_eid ->
    datoms db Aevt ~a:"block/refs" ~v:(Ref target_eid) ()
    |> Seq.exists (fun datom -> datom.e = source_eid)
  | _ -> false
;;

let has_tag db ~source ~target =
  match entid db "block/uuid" (Uuid source), entid db "block/uuid" (Uuid target) with
  | Some source_eid, Some target_eid ->
    datoms db Eavt ~e:source_eid ~a:"block/tags" ()
    |> Seq.exists (fun datom ->
      Logseq_chat_datascript_value.ref_eid db "block/tags" datom.v = Some target_eid)
  | _ -> false
;;

let has_ident_tag db ~source ~target =
  match entid db "block/uuid" (Uuid source), entid db "db/ident" (Keyword target) with
  | Some source_eid, Some target_eid ->
    datoms db Eavt ~e:source_eid ~a:"block/tags" ()
    |> Seq.exists (fun datom ->
      Logseq_chat_datascript_value.ref_eid db "block/tags" datom.v = Some target_eid)
  | _ -> false
;;

let operation id base_t intent =
  Ops.{ operation_id = id; base_t; state = Queued; intent }
;;

let base_db () =
  empty_db ~schema ()
  |> db_with
       [ Add (Entity_id 1, "block/uuid", Uuid "page")
       ; Add (Entity_id 1, "block/title", String "Page")
       ; Add (Entity_id 1, "block/name", String "page")
       ; Add (Entity_id 2, "block/uuid", Uuid "project")
       ; Add (Entity_id 2, "block/title", String "Project")
       ; Add (Entity_id 2, "block/name", String "project")
       ; Add (Entity_id 2, "block/tags", Ref 4)
       ; Add (Entity_id 3, "block/uuid", Uuid "old-ref")
       ; Add (Entity_id 3, "block/title", String "Old ref")
       ; Add (Entity_id 3, "block/name", String "old ref")
       ; Add (Entity_id 4, "db/ident", Keyword "logseq.class/Tag")
       ; Add (Entity_id 6, "db/ident", Keyword "logseq.class/Root")
       ; Add (Entity_id 7, "db/ident", Keyword "logseq.class/Asset")
       ; Add (Entity_id 5, "block/uuid", Uuid "non-inline-tag")
       ; Add (Entity_id 5, "block/title", String "Non-inline")
       ; Add (Entity_id 5, "block/name", String "non-inline")
       ; Add (Entity_id 5, "block/tags", Ref 4)
       ; Add (Entity_id 10, "block/uuid", Uuid "block")
       ; Add (Entity_id 10, "block/title", String "Old")
       ; Add (Entity_id 10, "block/page", Ref 1)
       ; Add (Entity_id 10, "block/parent", Ref 1)
       ; Add (Entity_id 10, "block/order", String "a0")
       ; Add (Entity_id 10, "block/refs", Ref 3)
       ; Add (Entity_id 10, "block/tags", Ref 5) ]
;;

let () =
  let intent =
    Ops.Create_asset
      { uuid = "asset"
      ; title = "photo.png"
      ; page_uuid = "page"
      ; parent_uuid = "block"
      ; order = "a1"
      ; created_at = 100
      ; asset_type = "png"
      ; asset_size = 2048
      ; asset_checksum = "abc123"
      }
  in
  let projected =
    match Projection.compile (base_db ()) intent with
    | Ok tx -> db_with tx (base_db ())
    | Error message -> fail "asset projection" message
  in
  assert_bool "asset projection is satisfied" (Projection.satisfied projected intent);
  assert_string "asset projection preserves title" "photo.png" (title projected "asset");
  assert_bool "asset projection uses the built-in Asset class"
    (has_ident_tag projected ~source:"asset" ~target:"logseq.class/Asset");
  let asset = Option.get (entity projected (lookup "asset")) in
  assert_bool "asset projection stores its type"
    (entity_attr asset "logseq.property.asset/type" = Some (One_value (String "png")));
  assert_bool "asset projection stores its decoded size"
    (entity_attr asset "logseq.property.asset/size" = Some (One_value (Int 2048)));
  assert_bool "asset projection stores its checksum"
    (entity_attr asset "logseq.property.asset/checksum" = Some (One_value (String "abc123")));
  assert_bool "asset projection records uploaded remote metadata"
    (match entity_attr asset "logseq.property.asset/remote-metadata" with
     | Some (One_value (Map entries)) ->
       List.mem (Keyword "checksum", String "abc123") entries
       && List.mem (Keyword "type", String "png") entries
     | _ -> false)
;;

let () =
  let db =
    base_db ()
    |> db_with
         [ Add (Entity_id 20, "block/uuid", Uuid "favorites-page")
         ; Add (Entity_id 20, "block/title", String "Favorites")
         ; Add (Entity_id 20, "block/name", String "$$$favorites")
         ]
  in
  let favorite =
    Ops.Set_favorite
      { page_uuid = "project"
      ; favorite_uuid = "favorite-project"
      ; favorite = true
      ; order = "a0"
      ; created_at = 100
      }
  in
  let favorited =
    match Projection.compile db favorite with
    | Ok tx -> db_with tx db
    | Error message -> fail "favorite projection" message
  in
  assert_bool "favorite operation is satisfied after projection"
    (Projection.satisfied favorited favorite);
  assert_bool "favorite projection appears in sidebar"
    (match (Logseq_chat_graph_read.sidebar_pages favorited).favorites with
     | [ page ] -> String.equal page.uuid "project"
     | _ -> false);
  let unfavorite =
    Ops.Set_favorite
      { page_uuid = "project"
      ; favorite_uuid = "favorite-project"
      ; favorite = false
      ; order = "a0"
      ; created_at = 100
      }
  in
  let unfavorited =
    match Projection.compile favorited unfavorite with
    | Ok tx -> db_with tx favorited
    | Error message -> fail "unfavorite projection" message
  in
  assert_bool "unfavorite operation is satisfied after projection"
    (Projection.satisfied unfavorited unfavorite);
  assert_bool "unfavorite projection leaves sidebar"
    ((Logseq_chat_graph_read.sidebar_pages unfavorited).favorites = [])
;;

let () =
  let db =
    base_db ()
    |> db_with
         [ Add (Entity_id 1, "block/parent", Ref 6)
         ; Add (Entity_id 1, "block/order", String "a1")
         ; Add (Entity_id 30, "block/uuid", Uuid "recycle-page")
         ; Add (Entity_id 30, "block/title", String "Recycle")
         ; Add (Entity_id 30, "block/name", String "recycle")
         ; Add (Entity_id 30, "logseq.property/built-in?", Bool true)
         ; Add (Entity_id 30, "logseq.property/hide?", Bool true)
         ]
  in
  let intent =
    Ops.Delete_page
      { page_uuid = "page"
      ; order = "a0"
      ; deleted_at = 100
      }
  in
  let recycled =
    match Projection.compile db intent with
    | Ok tx -> db_with tx db
    | Error message -> fail "page recycle projection" message
  in
  assert_bool "page recycle is satisfied after projection"
    (Projection.satisfied recycled intent);
  assert_bool "recycled page is hidden from recent pages"
    (not
       (List.exists
          (fun page -> String.equal page.Logseq_chat_graph_read.uuid "page")
          (Logseq_chat_graph_read.sidebar_pages recycled).recent_pages));
  assert_bool "recycled page is no longer a node destination"
    (Logseq_chat_graph_read.node_destination recycled "page" = None);
  assert_bool "a block below a recycled page is no longer a node destination"
    (Logseq_chat_graph_read.node_destination recycled "block" = None);
  assert_bool "page recycle preserves its original parent"
    (Logseq_chat_datascript_value.optional_ref_eid
       recycled
       "logseq.property.recycle/original-parent"
       (Datascript.datoms
          recycled
          Eavt
          ~e:(Option.get (Datascript.entid recycled "block/uuid" (Uuid "page")))
          ~a:"logseq.property.recycle/original-parent"
          ()
        |> Seq.uncons
        |> Option.map (fun (datom, _) -> datom.v))
     = Some 6);
  assert_bool "page recycle preserves its original page and order"
    (Logseq_chat_datascript_value.optional_ref_eid
       recycled
       "logseq.property.recycle/original-page"
       (Datascript.datoms
          recycled
          Eavt
          ~e:(Option.get (Datascript.entid recycled "block/uuid" (Uuid "page")))
          ~a:"logseq.property.recycle/original-page"
          ()
        |> Seq.uncons
        |> Option.map (fun (datom, _) -> datom.v))
     = Datascript.entid recycled "block/uuid" (Uuid "page")
     && title recycled "page" = "Page")
;;

let () =
  let authoritative = base_db () in
  let op =
    operation
      "op-inline-tag"
      42
      (Save_title
         { uuid = "block"
         ; expected_title = "Old"
         ; title = "New #[[project]]"
         })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ op ] in
  assert_bool "inline tag edit projects the canonical block/tags relation"
    (has_tag snapshot.db ~source:"block" ~target:"project");
  assert_bool "inline tag edit preserves independently assigned non-inline tags"
    (has_tag snapshot.db ~source:"block" ~target:"non-inline-tag");
  let with_inline =
    authoritative
    |> db_with
         [ Add (lookup "block", "block/title", String "Old #[[project]]")
         ; Add (lookup "block", "block/tags", Ref 2)
         ]
  in
  let remove =
    operation
      "op-remove-inline-tag"
      42
      (Save_title
         { uuid = "block"
         ; expected_title = "Old #[[project]]"
         ; title = "Plain"
         })
  in
  let removed = Projection.build ~server_t:42 with_inline [ remove ] in
  assert_bool "removing inline syntax retracts only its derived tag relation"
    (not (has_tag removed.db ~source:"block" ~target:"project")
     && has_tag removed.db ~source:"block" ~target:"non-inline-tag")
;;

let () =
  let authoritative = base_db () in
  let create =
    operation
      "op-create-tag"
      42
      (Create_tag { uuid = "new-tag"; title = "Foobar"; created_at = 99 })
  in
  let save =
    operation
      "op-save-with-new-tag"
      42
      (Save_title { uuid = "block"; expected_title = "Old"; title = "New #[[new-tag]]" })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ create; save ] in
  assert_string "created tag title" "Foobar" (title snapshot.db "new-tag");
  assert_bool "created tag is an instance of logseq.class/Tag"
    (match entid snapshot.db "block/uuid" (Uuid "new-tag"),
           entid snapshot.db "db/ident" (Keyword "logseq.class/Tag") with
     | Some tag_eid, Some class_eid ->
       datoms snapshot.db Eavt ~e:tag_eid ~a:"block/tags" ()
       |> Seq.exists (fun datom ->
         Logseq_chat_datascript_value.ref_eid snapshot.db "block/tags" datom.v
         = Some class_eid)
     | _ -> false);
  assert_bool "created tag has a canonical user class ident"
    (match entid snapshot.db "block/uuid" (Uuid "new-tag") with
     | Some tag_eid ->
       datoms snapshot.db Eavt ~e:tag_eid ~a:"db/ident" ()
       |> Seq.exists (fun datom ->
         match datom.v with
         | Keyword ident -> String.starts_with ~prefix:"user.class/" ident
         | _ -> false)
     | None -> false);
  assert_bool "created tag extends logseq.class/Root"
    (match entid snapshot.db "block/uuid" (Uuid "new-tag"),
           entid snapshot.db "db/ident" (Keyword "logseq.class/Root") with
     | Some tag_eid, Some root_eid ->
       datoms snapshot.db Eavt ~e:tag_eid ~a:"logseq.property.class/extends" ()
       |> Seq.exists (fun datom ->
         Logseq_chat_datascript_value.ref_eid
           snapshot.db
           "logseq.property.class/extends"
           datom.v
         = Some root_eid)
     | _ -> false);
  assert_bool "block links the freshly created tag"
    (has_tag snapshot.db ~source:"block" ~target:"new-tag");
  assert_bool "creating an already existing tag is a no-op"
    (Projection.compile snapshot.db
       (Ops.Create_tag { uuid = "new-tag"; title = "Foobar"; created_at = 99 })
     = Ok []);
  assert_bool "tag creation requires the graph Tag class"
    (match
       Projection.compile
         (empty_db ~schema ())
         (Ops.Create_tag { uuid = "new-tag"; title = "Foobar"; created_at = 99 })
     with
     | Error _ -> true
     | Ok _ -> false);
  assert_bool "tag creation is satisfied once the tag exists"
    (Projection.satisfied snapshot.db
       (Ops.Create_tag { uuid = "new-tag"; title = "Foobar"; created_at = 99 })
     && not
          (Projection.satisfied authoritative
             (Ops.Create_tag { uuid = "new-tag"; title = "Foobar"; created_at = 99 })))
;;

let () =
  let journal_day = 20260822 in
  let schema =
    List.map
      (fun (attr, definition) ->
        if String.equal attr "block/journal-day"
        then attr, { definition with unique = Some Identity }
        else attr, definition)
      schema
  in
  let page_only =
    empty_db ~schema ()
    |> db_with
         [ Add (Entity_id 20, "block/uuid", Uuid "today-page")
         ; Add (Entity_id 20, "block/name", String "aug 22nd, 2026")
         ; Add (Entity_id 20, "block/title", String "Aug 22nd, 2026")
         ; Add (Entity_id 20, "block/journal-day", Int journal_day)
         ]
  in
  let intent =
    Ops.Create_journal
      { page_uuid = "today-page"
      ; block_uuid = "today-block"
      ; title = "Aug 22nd, 2026"
      ; journal_day
      ; created_at = 99
      }
  in
  assert_bool "partial journal fixture contains the authoritative page"
    (Option.is_some (entid page_only "block/journal-day" (Int journal_day)));
  assert_bool "partial journal fixture does not contain the first block"
    (Option.is_none (entid page_only "block/uuid" (Uuid "today-block")));
  let projected = Projection.build ~server_t:1 page_only [ operation "op-journal" 0 intent ] in
  assert_bool "partially applied journal creation still projects its first block"
    (Option.is_some (entid projected.db "block/uuid" (Uuid "today-block")));
  assert_bool "journal creation is not satisfied until its first block exists"
    (not (Projection.satisfied page_only intent))
;;

let () =
  let journal_day = 20260822 in
  let authoritative =
    empty_db ~schema ()
    |> db_with [ Add (Entity_id 1, "db/ident", Keyword "logseq.class/Journal") ]
  in
  let intent =
    Ops.Create_journal
      { page_uuid = "today-page"
      ; block_uuid = "today-block"
      ; title = "Aug 22nd, 2026"
      ; journal_day
      ; created_at = 99
      }
  in
  let projected = Projection.build ~server_t:1 authoritative [ operation "op-journal" 0 intent ] in
  assert_bool "journal creation tags the page with the canonical Logseq Journal class"
    (has_ident_tag projected.db ~source:"today-page" ~target:"logseq.class/Journal")
;;

let () =
  let authoritative = base_db () in
  let op = operation "op-title" 42
      (Save_title { uuid = "block"; expected_title = "Old"; title = "New [[Project]]" }) in
  let snapshot = Projection.build ~server_t:42 authoritative [ op ] in
  assert_string "projected title" "New [[Project]]" (title snapshot.db "block");
  assert_bool "projected linked ref" (has_ref snapshot.db ~source:"block" ~target:"project");
  assert_bool "stale linked ref removed" (not (has_ref snapshot.db ~source:"block" ~target:"old-ref"));
  assert_string "authoritative title stays immutable" "Old" (title authoritative "block");
  assert_bool "authoritative refs stay immutable" (has_ref authoritative ~source:"block" ~target:"old-ref");
  assert_bool "operation applied" (List.assoc_opt "op-title" snapshot.statuses = Some Ops.Applied)
;;

let () =
  let db = base_db () in
  assert_bool "page reference parser ignores empty and unfinished references"
    (Projection.page_names "[[]] [[Project]] [[" = [ "Project" ]);
  assert_bool "page reference parser handles text without references"
    (Projection.page_names "plain" = []);
  assert_bool "inline tag parser ignores empty and unfinished tags"
    (Projection.inline_tag_names "#[[]] #[[unfinished" = []);
  let db_without_tag_class =
    empty_db ~schema ()
    |> db_with
         [ Add (Entity_id 1, "block/uuid", Uuid "project")
         ; Add (Entity_id 1, "block/name", String "project")
         ]
  in
  assert_bool "inline tags require the graph Tag class"
    (Projection.tag_eids_for_title db_without_tag_class "#[[project]]" = []);
  assert_bool "one-value lookup rejects missing entities and cardinality-many attributes"
    (Projection.one_value db (lookup "missing") "block/title" = None
     && Projection.one_value db (lookup "block") "block/refs" = None);
  assert_bool "UUID lookup rejects entities without UUID values"
    (Projection.uuid_for_eid db 999 = None);
  assert_bool "outliner lookup rejects missing and incomplete blocks"
    (Projection.outliner_block db "missing" = None
     && Projection.outliner_block db "project" = None);
  assert_bool "semantic equality supports primitive values"
    (Projection.semantic_value_equal db (Some (Int 8)) (Some (Int_value 8))
     && Projection.semantic_value_equal db (Some (Bool true)) (Some (Bool_value true)));
  let ident_db = db_with [ Add (Entity_id 50, "db/ident", Keyword "status.todo") ] db in
  assert_bool "semantic equality resolves ident references"
    (Projection.semantic_value_equal
       ident_db
       (Some (Ref 50))
       (Some (Ref_ident "status.todo"))
     && Projection.semantic_value_equal
          ident_db
          (Some (Int 50))
          (Some (Ref_ident "status.todo")));
  assert_bool "title transaction for a missing UUID has no stale refs to retract"
    (Projection.title_tx db "new-title-target" "New" =
     [ Add (lookup "new-title-target", "block/title", String "New") ]);
  (match
     Projection.compile
       db
       (Insert_block
          { uuid = "inline-tagged-insert"
          ; title = "New #[[project]]"
          ; page_uuid = "page"
          ; parent_uuid = "page"
          ; order = "a1"
          ; created_at = 1
          })
   with
   | Ok ([ Entity { attrs; _ } ] as tx) ->
     assert_bool "insert transaction contains the derived inline tag"
       (List.mem_assoc "block/tags" attrs);
     let projected = db_with tx db in
     assert_bool "insert derives the canonical inline tag relation"
       (has_tag projected ~source:"inline-tagged-insert" ~target:"project")
   | Ok _ -> fail "inline tagged insert" "expected one entity transaction"
   | Error message -> fail "inline tagged insert" message);
  assert_bool "outliner delete mutation ignores an already missing entity"
    (Projection.outliner_mutation_tx db (Projection.Outliner.Delete { uuid = "missing" }) = []);
  let dangling =
    db_with
      [ Add (Entity_id 41, "block/title", String "No UUID")
      ; Add (Entity_id 40, "block/uuid", Uuid "dangling")
      ; Add (Entity_id 40, "block/title", String "Dangling")
      ; Add (Entity_id 40, "block/page", Ref 41)
      ; Add (Entity_id 40, "block/parent", Ref 1)
      ; Add (Entity_id 40, "block/order", String "a9")
      ]
      db
  in
  assert_bool "outliner lookup rejects dangling structural references"
    (Projection.outliner_block dangling "dangling" = None);
  let malformed_ref =
    db_with
      [ Add (Entity_id 42, "block/uuid", Uuid "malformed-ref")
      ; Add (Entity_id 42, "block/title", String "Malformed ref")
      ; Raw_datom (datom ~e:42 ~a:"block/page" ~v:(String "not-a-ref") ())
      ; Add (Entity_id 42, "block/parent", Ref 1)
      ; Add (Entity_id 42, "block/order", String "b0")
      ]
      db
  in
  assert_bool "outliner lookup rejects non-reference structural values"
    (Projection.outliner_block malformed_ref "malformed-ref" = None)
;;

let () =
  let db =
    empty_db ~schema ()
    |> db_with
         [ Raw_datom (datom ~e:1 ~a:"block/uuid" ~v:(Uuid "raw-page") ())
         ; Raw_datom (datom ~e:1 ~a:"block/name" ~v:(String "raw-page") ())
         ; Raw_datom (datom ~e:1 ~a:"block/title" ~v:(String "Raw page") ())
         ; Raw_datom (datom ~e:10 ~a:"block/uuid" ~v:(Uuid "raw-parent") ())
         ; Raw_datom (datom ~e:10 ~a:"block/title" ~v:(String "Parent") ())
         ; Raw_datom (datom ~e:10 ~a:"block/page" ~v:(Int 1) ())
         ; Raw_datom (datom ~e:10 ~a:"block/parent" ~v:(Int 1) ())
         ; Raw_datom (datom ~e:10 ~a:"block/order" ~v:(String "a0") ())
         ; Raw_datom (datom ~e:11 ~a:"block/uuid" ~v:(Uuid "raw-child") ())
         ; Raw_datom (datom ~e:11 ~a:"block/title" ~v:(String "Child") ())
         ; Raw_datom (datom ~e:11 ~a:"block/page" ~v:(Int 1) ())
         ; Raw_datom (datom ~e:11 ~a:"block/parent" ~v:(Int 10) ())
         ; Raw_datom (datom ~e:11 ~a:"block/order" ~v:(String "a0") ())
         ]
  in
  assert_bool "raw numeric ref properties preserve semantic equality"
    (Projection.semantic_value_equal
       db
       (Projection.one_value db (lookup "raw-child") "block/parent")
       (Some (Ref_uuid "raw-parent")));
  assert_bool "raw numeric structural refs produce editable outliner blocks"
    (match Projection.outliner_block db "raw-child" with
     | Some block -> block.page_uuid = "raw-page" && block.parent_uuid = "raw-parent"
     | None -> false);
  assert_bool "raw numeric parent refs participate in recursive deletion"
    (match Projection.compile db (Delete_blocks { uuids = [ "raw-parent" ] }) with
     | Ok tx ->
       db_with tx db
       |> fun projected ->
       Option.is_none (entid projected "block/uuid" (Uuid "raw-parent"))
       && Option.is_none (entid projected "block/uuid" (Uuid "raw-child"))
     | Error _ -> false)
;;

let () =
  let authoritative =
    base_db ()
    |> db_with
         [ Add (lookup "block", "user.property/label", String "Old label")
         ; Add (lookup "block", "user.property/enabled", Bool false)
         ]
  in
  let operations =
    [ operation "string" 42
        (Set_property
           { uuid = "block"; attr = "user.property/label"
           ; expected = Some (String_value "Old label")
           ; value = Some (String_value "New label") })
    ; operation "bool" 42
        (Set_property
           { uuid = "block"; attr = "user.property/enabled"
           ; expected = Some (Bool_value false); value = Some (Bool_value true) })
    ; operation "retract" 42
        (Set_property
           { uuid = "block"; attr = "user.property/label"
           ; expected = Some (String_value "New label"); value = None })
    ]
  in
  let snapshot = Projection.build ~server_t:42 authoritative operations in
  assert_bool "string, boolean, and retraction property values project"
    (Projection.one_value snapshot.db (lookup "block") "user.property/label" = None
     && Projection.one_value snapshot.db (lookup "block") "user.property/enabled"
        = Some (Bool true));
  let conflict =
    operation "wrong-bool" 42
      (Set_property
         { uuid = "block"; attr = "user.property/enabled"
         ; expected = Some (Bool_value false); value = Some (Bool_value true) })
  in
  assert_bool "property comparison rejects a mismatched semantic value"
    (match Projection.compile snapshot.db conflict.intent with Error _ -> true | Ok _ -> false)
;;

let () =
  let authoritative = base_db () in
  let state =
    Ops.Map_value
      [ "state", Ops.Keyword_value "learning"
      ; "stability", Ops.Float_value 0.4
      ; "reps", Ops.Int_value 1
      ]
  in
  let intent =
    Ops.Set_properties
      { uuid = "block"
      ; changes =
          [ { attr = "logseq.property.fsrs/state"; expected = None; value = Some state }
          ; { attr = "logseq.property.fsrs/due"; expected = None
            ; value = Some (Ops.Int_value 1_776_000_060_000) }
          ]
      }
  in
  let projected =
    match Projection.compile authoritative intent with
    | Ok tx -> db_with tx authoritative
    | Error message -> failwith ("flashcard properties must compile atomically: " ^ message)
  in
  assert_bool "flashcard state and due project in one operation"
    (Projection.semantic_value_equal
       projected
       (Projection.one_value projected (lookup "block") "logseq.property.fsrs/state")
       (Some state)
     && Projection.semantic_value_equal
          projected
          (Projection.one_value projected (lookup "block") "logseq.property.fsrs/due")
          (Some (Ops.Int_value 1_776_000_060_000)));
  let changed =
    db_with
      [ Add (lookup "block", "logseq.property.fsrs/due", Int 99) ]
      authoritative
  in
  assert_bool "one stale flashcard property rejects the whole atomic review"
    (match Projection.compile changed intent with Error _ -> true | Ok _ -> false)
;;

let () =
  let authoritative =
    base_db ()
    |> db_with
         [ Add (Entity_id 11, "block/uuid", Uuid "second")
         ; Add (Entity_id 11, "block/title", String "Second")
         ; Add (Entity_id 11, "block/page", Ref 1)
         ; Add (Entity_id 11, "block/parent", Ref 1)
         ; Add (Entity_id 11, "block/order", String "a1")
         ; Add (Entity_id 12, "block/uuid", Uuid "target")
         ; Add (Entity_id 12, "block/title", String "Target")
         ; Add (Entity_id 12, "block/page", Ref 1)
         ; Add (Entity_id 12, "block/parent", Ref 1)
         ; Add (Entity_id 12, "block/order", String "a2")
         ]
  in
  let batch =
    operation "op-move-batch" 42
      (Move_blocks
         { moves =
             [ { uuid = "block"; page_uuid = "page"; parent_uuid = "target"; order = "a0" }
             ; { uuid = "second"; page_uuid = "page"; parent_uuid = "target"; order = "a1" }
             ]
         })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ batch ] in
  let target_eid = Option.get (entid snapshot.db "block/uuid" (Uuid "target")) in
  List.iter
    (fun uuid ->
      let eid = Option.get (entid snapshot.db "block/uuid" (Uuid uuid)) in
      assert_bool ("batch move reparents " ^ uuid)
        (datoms snapshot.db Eavt ~e:eid ~a:"block/parent" ~v:(Ref target_eid) ()
         |> Seq.exists (fun _ -> true)))
    [ "block"; "second" ];
  assert_bool "batch move remains one projected operation"
    (List.assoc_opt "op-move-batch" snapshot.statuses = Some Ops.Applied)
;;

let () =
  let authoritative =
    base_db ()
    |> db_with
         [ Add (Entity_id 20, "db/ident", Keyword "logseq.property/status.todo")
         ; Add (Entity_id 20, "block/title", String "Todo")
         ; Add (Entity_id 21, "db/ident", Keyword "logseq.property/status.doing")
         ; Add (Entity_id 21, "block/title", String "Doing")
         ; Add (Entity_id 10, "logseq.property/status", Ref 20)
         ]
  in
  let status =
    operation "op-builtin-status" 42
      (Set_property
         { uuid = "block"
         ; attr = "logseq.property/status"
         ; expected = Some (Ref_ident "logseq.property/status.todo")
         ; value = Some (Ref_ident "logseq.property/status.doing")
         })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ status ] in
  let block_eid = Option.get (entid snapshot.db "block/uuid" (Uuid "block")) in
  let doing_eid =
    Option.get (entid snapshot.db "db/ident" (Keyword "logseq.property/status.doing"))
  in
  assert_bool "built-in status refs project by ident"
    (datoms snapshot.db Eavt ~e:block_eid ~a:"logseq.property/status" ~v:(Ref doing_eid) ()
     |> Seq.exists (fun _ -> true));
  assert_bool "built-in status projection remains applied"
    (List.assoc_opt "op-builtin-status" snapshot.statuses = Some Ops.Applied)
;;

let () =
  let authoritative = base_db () in
  let first = operation "op-first" 42
      (Save_title { uuid = "block"; expected_title = "Old"; title = "First" }) in
  let second = operation "op-second" 42
      (Save_title { uuid = "block"; expected_title = "First"; title = "Second" }) in
  let snapshot = Projection.build ~server_t:42 authoritative [ first; second ] in
  assert_string "ordered semantic replay" "Second" (title snapshot.db "block");
  assert_bool "both edits applied"
    (List.for_all (fun id -> List.assoc_opt id snapshot.statuses = Some Ops.Applied)
       [ "op-first"; "op-second" ])
;;

let () =
  let authoritative = base_db () in
  let op = operation "op-property" 42
      (Set_property { uuid = "block"; attr = "user.property/effort";
                      expected = None; value = Some (Int_value 8) }) in
  let snapshot = Projection.build ~server_t:42 authoritative [ op ] in
  assert_bool "generic Datalog-visible pending property"
    (datoms snapshot.db Aevt ~a:"user.property/effort" ~v:(Int 8) () |> Seq.exists (fun _ -> true));
  assert_bool "authoritative property is unchanged"
    (datoms authoritative Aevt ~a:"user.property/effort" () |> Seq.is_empty)
;;

let () =
  let authoritative = base_db () |> db_with
      [ Add (Entity_id 11, "block/uuid", Uuid "child")
      ; Add (Entity_id 11, "block/title", String "Child")
      ; Add (Entity_id 11, "block/page", Ref 1)
      ; Add (Entity_id 11, "block/parent", Ref 10)
      ; Add (Entity_id 11, "block/order", String "a0") ] in
  let snapshot = Projection.build ~server_t:42 authoritative
      [ operation "op-delete" 42 (Delete_blocks { uuids = [ "block" ] }) ] in
  assert_bool "delete hides target" (Option.is_none (entid snapshot.db "block/uuid" (Uuid "block")));
  assert_bool "delete hides descendants" (Option.is_none (entid snapshot.db "block/uuid" (Uuid "child")));
  assert_bool "delete does not mutate authoritative target" (Option.is_some (entid authoritative "block/uuid" (Uuid "block")));
  assert_bool "delete does not mutate authoritative descendant" (Option.is_some (entid authoritative "block/uuid" (Uuid "child")))
;;

let () =
  let remote = base_db () |> db_with [ Add (lookup "block", "block/title", String "Remote") ] in
  let op = operation "op-conflict" 42
      (Save_title { uuid = "block"; expected_title = "Old"; title = "Local" }) in
  let rebased = Projection.build ~server_t:43 remote [ op ] in
  assert_string "conflict preserves remote title" "Remote" (title rebased.db "block");
  assert_bool "conflict is explicit"
    (match List.assoc_opt "op-conflict" rebased.statuses with
     | Some (Ops.Conflicted _) -> true | _ -> false)
;;

let () =
  let authoritative = base_db () in
  let insert =
    operation "op-insert" 42
      (Insert_block
         { uuid = "inserted"
         ; title = "Inserted [[Project]]"
         ; page_uuid = "page"
         ; parent_uuid = "block"
         ; order = "a1"
         ; created_at = 100
         })
  in
  let moved =
    operation "op-move" 42
      (Move_block
         { uuid = "inserted"; page_uuid = "page"; parent_uuid = "page"; order = "a2" })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ insert; moved ] in
  assert_string "pending insert title" "Inserted [[Project]]" (title snapshot.db "inserted");
  assert_bool "pending insert refs participate in linked refs"
    (has_ref snapshot.db ~source:"inserted" ~target:"project");
  let inserted_eid = Option.get (entid snapshot.db "block/uuid" (Uuid "inserted")) in
  let page_eid = Option.get (entid snapshot.db "block/uuid" (Uuid "page")) in
  assert_bool "pending move rewrites parent"
    (datoms snapshot.db Eavt ~e:inserted_eid ~a:"block/parent" ~v:(Ref page_eid) ()
     |> Seq.exists (fun _ -> true));
  assert_bool "pending insert and move do not mutate authoritative"
    (Option.is_none (entid authoritative "block/uuid" (Uuid "inserted")))
;;

let () =
  let authoritative = base_db () in
  let missing_target =
    operation "op-missing-target" 42
      (Set_property
         { uuid = "missing"
         ; attr = "block/title"
         ; expected = None
         ; value = Some (String_value "Must not transact")
         })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ missing_target ] in
  assert_bool "missing property target is a conflict instead of a DataScript exception"
    (match List.assoc_opt "op-missing-target" snapshot.statuses with
     | Some (Ops.Conflicted _) -> true
     | _ -> false)
;;

let () =
  let authoritative = base_db () in
  let split =
    operation "op-split" 42
      (Split_block
         { uuid = "block"
         ; expected_title = "Old"
         ; before = "O"
         ; after = "ld"
         ; new_uuid = "split-new"
         ; new_order = "a1"
         ; created_at = 100
         })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ split ] in
  assert_string "split updates source title atomically" "O" (title snapshot.db "block");
  assert_string "split inserts suffix sibling atomically" "ld" (title snapshot.db "split-new");
  assert_bool "split keeps authoritative source unchanged"
    (String.equal "Old" (title authoritative "block"));
  assert_bool "split does not insert into authoritative db"
    (Option.is_none (entid authoritative "block/uuid" (Uuid "split-new")))
;;

let () =
  let authoritative =
    base_db ()
    |> db_with
         [ Add (Entity_id 9, "block/uuid", Uuid "previous")
         ; Add (Entity_id 9, "block/title", String "Before ")
         ; Add (Entity_id 9, "block/page", Ref 1)
         ; Add (Entity_id 9, "block/parent", Ref 1)
         ; Add (Entity_id 9, "block/order", String "a0")
         ; Add (Entity_id 11, "block/uuid", Uuid "child")
         ; Add (Entity_id 11, "block/title", String "Child")
         ; Add (Entity_id 11, "block/page", Ref 1)
         ; Add (Entity_id 11, "block/parent", Ref 10)
         ; Add (Entity_id 11, "block/order", String "a0")
         ]
  in
  let merge =
    operation "op-merge" 42
      (Merge_backward
         { uuid = "block"
         ; expected_title = "Old"
         ; title = "Old"
         ; previous_uuid = "previous"
         ; expected_previous_title = "Before "
         ; merged_title = None
         })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ merge ] in
  assert_string "merge combines titles" "Before Old" (title snapshot.db "previous");
  assert_bool "merge retracts source"
    (Option.is_none (entid snapshot.db "block/uuid" (Uuid "block")));
  let child_eid = Option.get (entid snapshot.db "block/uuid" (Uuid "child")) in
  let previous_eid = Option.get (entid snapshot.db "block/uuid" (Uuid "previous")) in
  assert_bool "merge reparents children before deleting source"
    (datoms snapshot.db Eavt ~e:child_eid ~a:"block/parent" ~v:(Ref previous_eid) ()
     |> Seq.exists (fun _ -> true));
  assert_bool "merge leaves authoritative source intact"
    (Option.is_some (entid authoritative "block/uuid" (Uuid "block")))
;;

let () =
  let authoritative = base_db () in
  let invalid_move =
    operation "op-cycle" 42
      (Move_block
         { uuid = "block"; page_uuid = "page"; parent_uuid = "block"; order = "a0" })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ invalid_move ] in
  assert_bool "self-parent move conflicts"
    (match List.assoc_opt "op-cycle" snapshot.statuses with
     | Some (Ops.Conflicted _) -> true
     | _ -> false)
;;

let () =
  let authoritative = base_db () in
  let status =
    operation "op-status" 42
      (Set_property
         { uuid = "block"
         ; attr = "logseq.property/status"
         ; expected = None
         ; value = Some (Ref_uuid "project")
         })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ status ] in
  let block_eid = Option.get (entid snapshot.db "block/uuid" (Uuid "block")) in
  let project_eid = Option.get (entid snapshot.db "block/uuid" (Uuid "project")) in
  assert_bool "pending ref property is queryable"
    (datoms snapshot.db Eavt ~e:block_eid ~a:"logseq.property/status" ~v:(Ref project_eid) ()
     |> Seq.exists (fun _ -> true));
  let wrong_expected =
    operation "op-wrong-ref-cas" 42
      (Set_property
         { uuid = "block"
         ; attr = "logseq.property/status"
         ; expected = Some (Ref_uuid "old-ref")
         ; value = None
         })
  in
  let conflicted = Projection.build ~server_t:42 snapshot.db [ wrong_expected ] in
  assert_bool "ref CAS compares stable identity rather than numeric eid"
    (match List.assoc_opt "op-wrong-ref-cas" conflicted.statuses with
     | Some (Ops.Conflicted _) -> true
     | _ -> false)
;;

let () =
  let authoritative = base_db () in
  let delete_page =
    operation "op-delete-page" 42 (Delete_blocks { uuids = [ "page" ] })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ delete_page ] in
  assert_bool "ordinary block delete rejects pages"
    (match List.assoc_opt "op-delete-page" snapshot.statuses with
     | Some (Ops.Conflicted _) -> true
     | _ -> false);
  assert_bool "rejected page remains visible"
    (Option.is_some (entid snapshot.db "block/uuid" (Uuid "page")))
;;

let () =
  let authoritative = base_db () in
  let missing_parent =
    operation "op-missing-parent" 42
      (Insert_block
         { uuid = "orphan"
         ; title = "Orphan"
         ; page_uuid = "page"
         ; parent_uuid = "missing"
         ; order = "a0"
         ; created_at = 100
         })
  in
  let snapshot = Projection.build ~server_t:42 authoritative [ missing_parent ] in
  assert_bool "insert with missing parent conflicts"
    (match List.assoc_opt "op-missing-parent" snapshot.statuses with
     | Some (Ops.Conflicted _) -> true
     | _ -> false)
;;

let expect_error label = function Error _ -> () | Ok _ -> fail label "expected an error"

let () =
  let db = base_db () in
  expect_error "save title CAS conflict"
    (Projection.compile db
       (Save_title { uuid = "block"; expected_title = "Wrong"; title = "New" }));
  expect_error "save missing block"
    (Projection.compile db
       (Save_title { uuid = "missing"; expected_title = ""; title = "New" }));
  expect_error "property missing block"
    (Projection.compile db
       (Set_property
          { uuid = "missing"; attr = "user.property/label"; expected = None
          ; value = Some (String_value "New") }));
  expect_error "insert duplicate UUID"
    (Projection.compile db
       (Insert_block
          { uuid = "block"; title = "Duplicate"; page_uuid = "page"
          ; parent_uuid = "page"; order = "a1"; created_at = 1 }));
  expect_error "insert missing page"
    (Projection.compile db
       (Insert_block
          { uuid = "new"; title = "New"; page_uuid = "missing"
          ; parent_uuid = "page"; order = "a1"; created_at = 1 }));
  expect_error "move missing target"
    (Projection.compile db
       (Move_block
          { uuid = "block"; page_uuid = "page"; parent_uuid = "missing"; order = "a1" }));
  expect_error "empty move batch"
    (Projection.compile db (Move_blocks { moves = [] }));
  expect_error "move batch stops at a conflicting move"
    (Projection.compile db
       (Move_blocks
          { moves =
              [ { uuid = "block"; page_uuid = "page"; parent_uuid = "page"; order = "a1" }
              ; { uuid = "missing"; page_uuid = "page"; parent_uuid = "page"; order = "a2" }
              ] }));
  expect_error "split missing source"
    (Projection.compile db
       (Split_block
          { uuid = "missing"; expected_title = ""; before = ""; after = ""
          ; new_uuid = "new"; new_order = "a1"; created_at = 1 }));
  expect_error "delete missing roots"
    (Projection.compile db (Delete_blocks { uuids = [ "missing" ] }))
;;

let () =
  let db = base_db () in
  assert_bool "save satisfaction compares projected title"
    (Projection.satisfied db
       (Save_title { uuid = "block"; expected_title = "Before"; title = "Old" })
     && not
          (Projection.satisfied db
             (Save_title { uuid = "block"; expected_title = "Old"; title = "Other" })));
  assert_bool "property satisfaction compares semantic values"
    (Projection.satisfied db
       (Set_property
          { uuid = "block"; attr = "user.property/label"; expected = None; value = None })
     && not
          (Projection.satisfied db
             (Set_property
                { uuid = "block"; attr = "user.property/label"; expected = None
                ; value = Some (String_value "value") })));
  let insert_intent : Ops.intent =
    Insert_block
      { uuid = "inserted"; title = "Inserted"; page_uuid = "page"; parent_uuid = "page"
      ; order = "a1"; created_at = 1 }
  in
  let inserted = db_with (Result.get_ok (Projection.compile db insert_intent)) db in
  assert_bool "insert satisfaction checks every structural field"
    (Projection.satisfied inserted insert_intent
     && not
          (Projection.satisfied inserted
             (Insert_block
                { uuid = "inserted"; title = "Inserted"; page_uuid = "page"
                ; parent_uuid = "block"; order = "a1"; created_at = 1 })));
  let current_move : Ops.intent =
    Move_block { uuid = "block"; page_uuid = "page"; parent_uuid = "page"; order = "a0" }
  in
  assert_bool "move and move-batch satisfaction check every move"
    (Projection.satisfied db current_move
     && Projection.satisfied db (Move_blocks { moves = [ { uuid = "block"; page_uuid = "page"; parent_uuid = "page"; order = "a0" } ] })
     && not (Projection.satisfied db (Move_blocks { moves = [] }))
     && not
          (Projection.satisfied db
             (Move_blocks { moves = [ { uuid = "block"; page_uuid = "page"; parent_uuid = "page"; order = "wrong" } ] })));
  let split_intent : Ops.intent =
    Split_block
      { uuid = "block"; expected_title = "Old"; before = "O"; after = "ld"
      ; new_uuid = "split"; new_order = "a1"; created_at = 1 }
  in
  let split_db = db_with (Result.get_ok (Projection.compile db split_intent)) db in
  assert_bool "split satisfaction checks source, sibling title, and order"
    (Projection.satisfied split_db split_intent
     && not
          (Projection.satisfied split_db
             (Split_block
                { uuid = "block"; expected_title = "Old"; before = "O"; after = "ld"
                ; new_uuid = "split"; new_order = "wrong"; created_at = 1 })));
  let linked_split : Ops.intent =
    Split_block
      { uuid = "block"; expected_title = "Old"; before = "O"; after = "[[Project]]"
      ; new_uuid = "linked-split"; new_order = "a1"; created_at = 1 }
  in
  let linked_split_db = db_with (Result.get_ok (Projection.compile db linked_split)) db in
  assert_bool "outliner insert mutations derive linked references"
    (has_ref linked_split_db ~source:"linked-split" ~target:"project");
  let merge_intent : Ops.intent =
    Merge_backward
      { uuid = "split"; expected_title = "ld"; title = "ld"; previous_uuid = "block"
      ; expected_previous_title = "O"; merged_title = Some "Old" }
  in
  let merged_db = db_with (Result.get_ok (Projection.compile split_db merge_intent)) split_db in
  assert_bool "merge satisfaction supports an explicit merged title"
    (Projection.satisfied merged_db merge_intent);
  assert_bool "delete satisfaction requires every UUID to be absent"
    (Projection.satisfied db (Delete_blocks { uuids = [ "missing" ] })
     && not (Projection.satisfied db (Delete_blocks { uuids = [ "block" ] })))
;;

let () =
  let journal_only =
    base_db ()
    |> db_with
         [ Add (Entity_id 30, "block/uuid", Uuid "journal")
         ; Add (Entity_id 30, "block/title", String "Journal")
         ; Add (Entity_id 30, "block/journal-day", Int 20260817)
         ]
  in
  expect_error "journal entities cannot be deleted as ordinary blocks"
    (Projection.compile journal_only (Delete_blocks { uuids = [ "journal" ] }));
  let cyclic =
    base_db ()
    |> db_with
         [ Add (lookup "block", "block/parent", Ref_to (lookup "block")) ]
  in
  expect_error "cycle traversal terminates"
    (Projection.compile cyclic
       (Move_block { uuid = "block"; page_uuid = "page"; parent_uuid = "block"; order = "a0" }))
;;

let with_temp_db f =
  let path = Filename.temp_file "logseq-chat-pending-ops" ".sqlite" in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Sys.remove path) (fun () -> f path)
;;

let () =
  with_temp_db (fun path ->
    Logseq_chat_graph_store.prepare_staging path;
    let first = operation "op-persisted" 42
        (Save_title { uuid = "block"; expected_title = "Old"; title = "Offline" }) in
    Ops.save ~path first;
    assert_bool "pending op round trip" (Ops.list ~path = [ first ]);
    Ops.set_state ~path ~operation_id:first.operation_id Submitted;
    assert_bool "pending state update"
      (match Ops.list ~path with [ { state = Submitted; _ } ] -> true | _ -> false);
    Ops.remove ~path ~operation_id:first.operation_id;
    assert_bool "pending removal" (Ops.list ~path = []))
;;

let () =
  with_temp_db (fun path ->
    Logseq_chat_graph_store.prepare_staging path;
    let operations =
      [ operation "01-save" 42
          (Save_title { uuid = "block"; expected_title = "Old"; title = "你好 [[Project]]" })
      ; operation "02-property" 42
          (Set_property { uuid = "block"; attr = "user.property/effort";
                          expected = Some (Int_value 1); value = Some (Int_value 2) })
      ; operation "03-insert" 42
          (Insert_block { uuid = "new"; title = "New"; page_uuid = "page";
                          parent_uuid = "block"; order = "a0"; created_at = 7 })
      ; operation "04-move" 42
          (Move_block { uuid = "new"; page_uuid = "page"; parent_uuid = "page"; order = "a1" })
      ; operation "04b-move-batch" 42
          (Move_blocks
             { moves =
                 [ { uuid = "new"; page_uuid = "page"; parent_uuid = "block"; order = "a1" }
                 ]
             })
      ; operation "05-split" 42
          (Split_block { uuid = "block"; expected_title = "Old"; before = "O"; after = "ld";
                         new_uuid = "split"; new_order = "a2"; created_at = 8 })
      ; operation "06-merge" 42
          (Merge_backward { uuid = "split"; expected_title = "ld"; title = "ld"; previous_uuid = "block";
                            expected_previous_title = "O"; merged_title = None })
      ; operation "07-delete" 42 (Delete_blocks { uuids = [ "block"; "new" ] })
      ; operation "08-favorite" 42
          (Set_favorite
             { page_uuid = "project"; favorite_uuid = "favorite-project"; favorite = true
             ; order = "a0"; created_at = 9 })
      ; operation "09-delete-page" 42
          (Delete_page { page_uuid = "project"; order = "a1"; deleted_at = 10 }) ]
    in
    List.iter (Ops.save ~path) operations;
    assert_bool "all semantic intents round trip in insertion order" (Ops.list ~path = operations);
    let replacement =
      { (List.hd operations) with
        state = Retryable;
        intent = Save_title { uuid = "block"; expected_title = "Old"; title = "Replacement" } }
    in
    Ops.save ~path replacement;
    let restored = Ops.list ~path in
    assert_bool "operation-id upsert does not duplicate or reorder" (List.length restored = 10);
    assert_bool "operation-id upsert replaces payload" (List.hd restored = replacement))
;;

let () =
  with_temp_db (fun path ->
    Logseq_chat_graph_store.prepare_staging path;
    let first = operation "op-first" 42
        (Save_title { uuid = "block"; expected_title = "Old"; title = "First" }) in
    let second = operation "op-second" 42
        (Save_title { uuid = "block"; expected_title = "First"; title = "Second" }) in
    Ops.save ~path { first with state = Accepted 43 };
    Ops.save ~path { second with state = Submitted };
    Ops.confirm ~path ~operation_ids:[];
    assert_bool "cursor advance without operation identity confirms nothing"
      (List.map (fun op -> op.Ops.operation_id) (Ops.list ~path) = [ "op-first"; "op-second" ]);
    Ops.confirm ~path ~operation_ids:[ "op-first"; "unknown" ];
    assert_bool "WebSocket sync confirms only matching operation identities"
      (List.map (fun op -> op.Ops.operation_id) (Ops.list ~path) = [ "op-second" ]))
;;

let () =
  with_temp_db (fun active_path ->
    Logseq_chat_graph_store.prepare_staging active_path;
    let op = operation "op-survives-snapshot" 42
        (Save_title { uuid = "block"; expected_title = "Old"; title = "Offline" }) in
    Ops.save ~path:active_path op;
    (match Logseq_chat_graph_store.begin_import ~active_path with Ok () -> () | Error message -> fail "begin import" message);
    (match Logseq_chat_graph_store.activate ~active_path with Ok () -> () | Error message -> fail "activate import" message);
    assert_bool "snapshot replacement preserves pending ops" (Ops.list ~path:active_path = [ op ]))
;;
