open Datascript
open Logseq_chat_pending_ops

module Outliner = Logseq_chat_outliner
module Ds_value = Logseq_chat_datascript_value

type snapshot =
  { db : db
  ; server_t : int
  ; statuses : (string * state) list
  }

let lookup uuid = Lookup_ref ("block/uuid", Uuid uuid)

let one_value db entity_ref attr =
  match entity db entity_ref with
  | None -> None
  | Some entity ->
    (match Datascript.Entity.entity_attr_raw entity attr with
     | Some (One_value value) -> Some value
     | _ -> None)
;;

let string_value = function Some (String value) -> Some value | _ -> None

let has_ref db eid attr target_eid =
  datoms db Eavt ~e:eid ~a:attr ()
  |> Seq.exists (fun datom -> Ds_value.ref_eid db attr datom.v = Some target_eid)
;;

let datascript_value = function
  | String_value value -> String value
  | Int_value value -> Int value
  | Bool_value value -> Bool value
  | Ref_uuid uuid -> Ref_to (lookup uuid)
  | Ref_ident ident -> Ref_to (Lookup_ref ("db/ident", Keyword ident))
;;

let semantic_value_equal db left right =
  match left, right with
  | None, None -> true
  | Some (String value), Some (String_value expected) -> String.equal value expected
  | Some (Int value), Some (Int_value expected) -> value = expected
  | Some (Bool value), Some (Bool_value expected) -> value = expected
  | Some ((Ref eid | Int eid)), Some (Ref_uuid uuid) ->
    entid db "block/uuid" (Uuid uuid) = Some eid
  | Some ((Ref eid | Int eid)), Some (Ref_ident ident) ->
    entid db "db/ident" (Keyword ident) = Some eid
  | _ -> false
;;

let page_names title =
  let length = String.length title in
  let rec find_open index acc =
    if index + 1 >= length
    then List.rev acc
    else if title.[index] = '[' && title.[index + 1] = '['
    then find_close (index + 2) (index + 2) acc
    else find_open (index + 1) acc
  and find_close start index acc =
    if index + 1 >= length
    then List.rev acc
    else if title.[index] = ']' && title.[index + 1] = ']'
    then
      let name = String.sub title start (index - start) |> String.trim in
      find_open (index + 2) (if String.equal name "" then acc else name :: acc)
    else find_close start (index + 1) acc
  in
  find_open 0 []
;;

let inline_tag_names title =
  let length = String.length title in
  let rec find_open index acc =
    if index + 2 >= length
    then List.rev acc
    else if title.[index] = '#' && title.[index + 1] = '[' && title.[index + 2] = '['
    then find_close (index + 3) (index + 3) acc
    else find_open (index + 1) acc
  and find_close start index acc =
    if index + 1 >= length
    then List.rev acc
    else if title.[index] = ']' && title.[index + 1] = ']'
    then
      let name = String.sub title start (index - start) |> String.trim in
      find_open (index + 2) (if String.equal name "" then acc else name :: acc)
    else find_close start (index + 1) acc
  in
  find_open 0 []
;;

let eid_for_node db value =
  match entid db "block/uuid" (Uuid value) with
  | Some _ as eid -> eid
  | None ->
    datoms db Aevt ~a:"block/name" ~v:(String (String.lowercase_ascii value)) ()
    |> Seq.uncons
    |> Option.map (fun (datom, _) -> datom.e)
;;

let refs_for_title db title =
  page_names title
  |> List.filter_map (eid_for_node db)
  |> List.sort_uniq compare
;;

let tag_eids_for_title db title =
  inline_tag_names title
  |> List.filter_map (eid_for_node db)
  |> List.filter (fun eid ->
    match entid db "db/ident" (Keyword "logseq.class/Tag") with
    | None -> false
    | Some tag_class_eid ->
      datoms db Eavt ~e:eid ~a:"block/tags" ()
      |> Seq.exists (fun datom -> Ds_value.ref_eid db "block/tags" datom.v = Some tag_class_eid))
  |> List.sort_uniq compare
;;

let title_tx db uuid title =
  let entity_ref = lookup uuid in
  let retract_refs, retract_inline_tags =
    match entid db "block/uuid" (Uuid uuid) with
    | None -> [], []
    | Some eid ->
      let refs =
        datoms db Eavt ~e:eid ~a:"block/refs" ()
        |> List.of_seq
        |> List.map (fun datom -> Retract (entity_ref, "block/refs", Some datom.v))
      in
      let old_title = Option.value (string_value (one_value db entity_ref "block/title")) ~default:"" in
      let tags =
        tag_eids_for_title db old_title
        |> List.map (fun tag_eid -> Retract (entity_ref, "block/tags", Some (Ref tag_eid)))
      in
      refs, tags
  in
  let tag_eids = tag_eids_for_title db title in
  Add (entity_ref, "block/title", String title)
  :: retract_refs
  @ retract_inline_tags
  @ List.map (fun eid -> Add (entity_ref, "block/refs", Ref eid)) (refs_for_title db title)
  @ List.map (fun eid -> Add (entity_ref, "block/tags", Ref eid)) tag_eids
;;

let uuid_for_eid db eid =
  match one_value db (Entity_id eid) "block/uuid" with
  | Some (Uuid uuid) -> Some uuid
  | _ -> None
;;

let outliner_block db uuid =
  match string_value (one_value db (lookup uuid) "block/title"),
        one_value db (lookup uuid) "block/page",
        one_value db (lookup uuid) "block/parent",
        string_value (one_value db (lookup uuid) "block/order") with
  | Some title, Some page_value, Some parent_value, Some order ->
    (match
       Ds_value.ref_eid db "block/page" page_value,
       Ds_value.ref_eid db "block/parent" parent_value
     with
     | Some page_eid, Some parent_eid ->
    (match uuid_for_eid db page_eid, uuid_for_eid db parent_eid with
     | Some page_uuid, Some parent_uuid ->
       Some Outliner.{ uuid; title; page_uuid; parent_uuid; order }
     | _ -> None)
     | _ -> None)
  | _ -> None
;;

let insert_tx db (block : Outliner.block) created_at =
  let many attr eids =
    match eids with
    | [] -> []
    | eids -> [ attr, Many_values (List.map (fun eid -> Ref_to (Entity_id eid)) eids) ]
  in
  [ Entity
      { db_id = Some (Temp_id ("pending/" ^ block.uuid))
      ; attrs =
          [ "block/uuid", One_value (Uuid block.uuid)
          ; "block/title", One_value (String block.title)
          ; "block/page", One_value (Ref_to (lookup block.page_uuid))
          ; "block/parent", One_value (Ref_to (lookup block.parent_uuid))
          ; "block/order", One_value (String block.order)
          ; "block/created-at", One_value (Int created_at)
          ; "block/updated-at", One_value (Int created_at)
          ]
          @ many "block/refs" (refs_for_title db block.title)
          @ many "block/tags" (tag_eids_for_title db block.title)
      }
  ]
;;

let outliner_mutation_tx db = function
  | Outliner.Set_title { uuid; title } -> title_tx db uuid title
  | Outliner.Insert { block; created_at } -> insert_tx db block created_at
  | Outliner.Reparent { uuid; page_uuid; parent_uuid } ->
    [ Add (lookup uuid, "block/page", Ref_to (lookup page_uuid))
    ; Add (lookup uuid, "block/parent", Ref_to (lookup parent_uuid))
    ]
  | Outliner.Delete { uuid } ->
    (match entid db "block/uuid" (Uuid uuid) with
     | Some eid -> [ RetractEntity (Entity_id eid) ]
     | None -> [])
;;

let compile_outliner db command =
  let find uuid = outliner_block db uuid in
  let children uuid =
    entid db "block/uuid" (Uuid uuid)
    |> Option.to_list
    |> List.concat_map (fun eid ->
      Ds_value.datoms_by_ref db Aevt "block/parent" eid
      |> List.of_seq
      |> List.filter_map (fun datom -> uuid_for_eid db datom.e)
      |> List.filter_map find)
  in
  match Outliner.plan ~find ~children command with
  | Error message -> Error message
  | Ok mutations -> Ok (List.concat_map (outliner_mutation_tx db) mutations)
;;

let children db eid =
  Ds_value.datoms_by_ref db Aevt "block/parent" eid
  |> List.of_seq
  |> List.map (fun datom -> datom.e)
;;

let subtree db roots =
  let seen = Hashtbl.create 32 in
  let rec visit eid =
    if Hashtbl.mem seen eid
    then []
    else (
      Hashtbl.add seen eid ();
      eid :: List.concat_map visit (children db eid))
  in
  List.concat_map visit roots
;;

let page_entity db eid =
  datoms db Eavt ~e:eid ~a:"block/name" () |> Seq.is_empty |> not
  || (datoms db Eavt ~e:eid ~a:"block/journal-day" () |> Seq.is_empty |> not)
;;

let would_create_cycle db ~moving_eid ~parent_eid =
  List.mem parent_eid (subtree db [ moving_eid ])
;;

let rec compile db = function
  | Save_title { uuid; expected_title; title } ->
    (match string_value (one_value db (lookup uuid) "block/title") with
     | Some current when String.equal current expected_title -> Ok (title_tx db uuid title)
     | Some _ -> Error "title changed on the server"
     | None -> Error "block no longer exists")
  | Set_property { uuid; attr; expected; value } ->
    if Option.is_none (entid db "block/uuid" (Uuid uuid))
    then Error "block no longer exists"
    else
      let current = one_value db (lookup uuid) attr in
      if not (semantic_value_equal db current expected)
      then Error "property changed on the server"
      else
        Ok
          [ (match value with
             | Some value -> Add (lookup uuid, attr, datascript_value value)
             | None -> RetractAttr (lookup uuid, attr)) ]
  | Insert_block { uuid; title; page_uuid; parent_uuid; order; created_at } ->
    if Option.is_some (entid db "block/uuid" (Uuid uuid))
    then Error "inserted block UUID already exists"
    else if Option.is_none (entid db "block/uuid" (Uuid page_uuid))
            || Option.is_none (entid db "block/uuid" (Uuid parent_uuid))
    then Error "insert parent or page no longer exists"
    else
      Ok (insert_tx db Outliner.{ uuid; title; page_uuid; parent_uuid; order } created_at)
  | Move_block { uuid; page_uuid; parent_uuid; order } ->
    (match entid db "block/uuid" (Uuid uuid),
           entid db "block/uuid" (Uuid page_uuid),
           entid db "block/uuid" (Uuid parent_uuid) with
     | Some moving_eid, Some _, Some parent_eid
       when not (would_create_cycle db ~moving_eid ~parent_eid) ->
       Ok
         [ Add (lookup uuid, "block/page", Ref_to (lookup page_uuid))
         ; Add (lookup uuid, "block/parent", Ref_to (lookup parent_uuid))
         ; Add (lookup uuid, "block/order", String order)
         ]
     | Some _, Some _, Some _ -> Error "move would create an outliner cycle"
     | _ -> Error "move target no longer exists")
  | Move_blocks { moves } ->
    if moves = []
    then Error "move batch must not be empty"
    else
      let rec compile_moves db tx = function
        | [] -> Ok (List.rev tx |> List.concat)
        | { uuid; page_uuid; parent_uuid; order } :: rest ->
          (match compile db (Move_block { uuid; page_uuid; parent_uuid; order }) with
           | Error _ as error -> error
           | Ok move_tx -> compile_moves (db_with move_tx db) (move_tx :: tx) rest)
      in
      compile_moves db [] moves
  | Split_block { uuid; expected_title; before; after; new_uuid; new_order; created_at } ->
    compile_outliner db
      (Outliner.Split
         { source_uuid = uuid
         ; expected_title
         ; before
         ; after
         ; new_uuid
         ; new_order
         ; created_at
         })
  | Merge_backward
      { uuid; expected_title; title; previous_uuid; expected_previous_title; merged_title }
    ->
    compile_outliner db
      (Outliner.Merge_backward
         { source_uuid = uuid
         ; expected_source_title = expected_title
         ; source_title = title
         ; previous_uuid
         ; expected_previous_title
         ; merged_title
         })
  | Delete_blocks { uuids } ->
    let roots = List.filter_map (fun uuid -> entid db "block/uuid" (Uuid uuid)) uuids in
    if roots = []
    then Error "block no longer exists"
    else if List.exists (page_entity db) roots
    then Error "ordinary block delete cannot delete a page"
    else Ok (List.map (fun eid -> RetractEntity (Entity_id eid)) (subtree db roots))
  | Create_tag { uuid; title; created_at } ->
    if Option.is_some (entid db "block/uuid" (Uuid uuid))
    then Ok []
    else if Option.is_none (entid db "db/ident" (Keyword "logseq.class/Tag"))
    then Error "the graph does not define logseq.class/Tag"
    else
      Ok
        [ Entity
            { db_id = Some (Temp_id ("pending/" ^ uuid))
            ; attrs =
                [ "block/uuid", One_value (Uuid uuid)
                ; "block/name", One_value (String (String.lowercase_ascii title))
                ; "block/title", One_value (String title)
                ; ( "block/tags"
                  , Many_values [ Ref_to (Lookup_ref ("db/ident", Keyword "logseq.class/Tag")) ] )
                ; "block/created-at", One_value (Int created_at)
                ; "block/updated-at", One_value (Int created_at)
                ]
            }
        ]
  | Create_journal { page_uuid; block_uuid; title; journal_day; created_at } ->
    if Option.is_some (entid db "block/journal-day" (Int journal_day))
    then Ok []
    else
      let page_id = Temp_id ("pending/" ^ page_uuid) in
      Ok
        [ Entity
            { db_id = Some page_id
            ; attrs =
                [ "block/uuid", One_value (Uuid page_uuid)
                ; "block/name", One_value (String (String.lowercase_ascii title))
                ; "block/title", One_value (String title)
                ; "block/journal-day", One_value (Int journal_day)
                ; "block/created-at", One_value (Int created_at)
                ; "block/updated-at", One_value (Int created_at)
                ]
            }
        ; Entity
            { db_id = Some (Temp_id ("pending/" ^ block_uuid))
            ; attrs =
                [ "block/uuid", One_value (Uuid block_uuid)
                ; "block/title", One_value (String "")
                ; "block/page", One_value (Ref_to page_id)
                ; "block/parent", One_value (Ref_to page_id)
                ; "block/order", One_value (String "a0")
                ; "block/created-at", One_value (Int created_at)
                ; "block/updated-at", One_value (Int created_at)
                ]
            }
        ]
  | Add_tag { uuid; tag_uuid } ->
    (match entid db "block/uuid" (Uuid uuid), entid db "block/uuid" (Uuid tag_uuid) with
     | Some block_eid, Some tag_eid ->
       if has_ref db block_eid "block/tags" tag_eid
       then Ok []
       else Ok [ Add (lookup uuid, "block/tags", Ref tag_eid) ]
     | None, _ -> Error "block no longer exists"
     | _, None -> Error "tag no longer exists")
;;

let rec satisfied db = function
  | Save_title { uuid; title; _ } ->
    string_value (one_value db (lookup uuid) "block/title") = Some title
  | Set_property { uuid; attr; value; _ } ->
    semantic_value_equal db (one_value db (lookup uuid) attr) value
  | Insert_block { uuid; title; page_uuid; parent_uuid; order; _ } ->
    Option.is_some (entid db "block/uuid" (Uuid uuid))
    && string_value (one_value db (lookup uuid) "block/title") = Some title
    && semantic_value_equal db (one_value db (lookup uuid) "block/page") (Some (Ref_uuid page_uuid))
    && semantic_value_equal db (one_value db (lookup uuid) "block/parent") (Some (Ref_uuid parent_uuid))
    && string_value (one_value db (lookup uuid) "block/order") = Some order
  | Move_block { uuid; page_uuid; parent_uuid; order } ->
    Option.is_some (entid db "block/uuid" (Uuid uuid))
    && semantic_value_equal db (one_value db (lookup uuid) "block/page") (Some (Ref_uuid page_uuid))
    && semantic_value_equal db (one_value db (lookup uuid) "block/parent") (Some (Ref_uuid parent_uuid))
    && string_value (one_value db (lookup uuid) "block/order") = Some order
  | Move_blocks { moves } ->
    moves <> []
    && List.for_all
         (fun { uuid; page_uuid; parent_uuid; order } ->
           satisfied db (Move_block { uuid; page_uuid; parent_uuid; order }))
         moves
  | Split_block { uuid; before; after; new_uuid; new_order; _ } ->
    string_value (one_value db (lookup uuid) "block/title") = Some before
    && string_value (one_value db (lookup new_uuid) "block/title") = Some after
    && string_value (one_value db (lookup new_uuid) "block/order") = Some new_order
  | Merge_backward { uuid; title; previous_uuid; expected_previous_title; merged_title; _ } ->
    Option.is_none (entid db "block/uuid" (Uuid uuid))
    && string_value (one_value db (lookup previous_uuid) "block/title")
       = Some (Option.value merged_title ~default:(expected_previous_title ^ title))
  | Delete_blocks { uuids } ->
    List.for_all (fun uuid -> Option.is_none (entid db "block/uuid" (Uuid uuid))) uuids
  | Create_tag { uuid; _ } -> Option.is_some (entid db "block/uuid" (Uuid uuid))
  | Create_journal { journal_day; _ } ->
    Option.is_some (entid db "block/journal-day" (Int journal_day))
  | Add_tag { uuid; tag_uuid } ->
    (match entid db "block/uuid" (Uuid uuid), entid db "block/uuid" (Uuid tag_uuid) with
     | Some block_eid, Some tag_eid -> has_ref db block_eid "block/tags" tag_eid
     | _ -> false)
;;

let build ~server_t authoritative operations =
  let db, statuses =
    List.fold_left
      (fun (db, statuses) operation ->
        match operation.state with
        | Conflicted message -> db, (operation.operation_id, Conflicted message) :: statuses
        | _ ->
          (match compile db operation.intent with
           | Ok tx -> db_with tx db, (operation.operation_id, Applied) :: statuses
           | Error message -> db, (operation.operation_id, Conflicted message) :: statuses))
      (authoritative, [])
      operations
  in
  { db; server_t; statuses = List.rev statuses }
;;
