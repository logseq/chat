open Datascript
module Model = Logseq_chat_model
module Ds_value = Logseq_chat_datascript_value

module Int_set = Set.Make (Int)
module String_set = Set.Make (String)

type sidebar_page =
  { uuid : string
  ; title : string
  }

type sidebar_pages =
  { favorites : sidebar_page list
  ; recent_pages : sidebar_page list
  }

let value db eid attr =
  Datascript.datoms db Eavt ~e:eid ~a:attr ()
  |> Seq.uncons
  |> Option.map (fun (datom, _rest) -> datom.v)
;;

let string_value = function
  | Some (String value) -> Some value
  | _ -> None
;;

let protected_string decrypt_title value =
  match string_value value with
  | None -> None
  | Some value ->
    (match decrypt_title value with
     | Ok decrypted -> Some decrypted
     | Error message -> failwith ("decrypt graph title: " ^ message))
;;

let uuid_value = function
  | Some (Uuid value) | Some (String value) -> Some value
  | _ -> None
;;

let int_value = function
  | Some (Int value) | Some (Instant value) -> Some value
  | _ -> None
;;

let uuid_for_eid db eid = uuid_value (value db eid "block/uuid")

let has_ref db eid attr target_eid =
  Datascript.datoms db Eavt ~e:eid ~a:attr ()
  |> Seq.exists (fun datom -> Ds_value.ref_eid db attr datom.v = Some target_eid)
;;

let entity_summary decrypt_title db eid =
  match uuid_for_eid db eid, protected_string decrypt_title (value db eid "block/title") with
  | Some uuid, Some title ->
    let is_tag =
      Datascript.entid db "db/ident" (Keyword "logseq.class/Tag")
      |> Option.exists (has_ref db eid "block/tags")
    in
    let kind =
      if is_tag then "tag"
      else if Option.is_some (value db eid "block/name") then "page"
      else "block"
    in
    Some Model.{ uuid; kind; title }
  | _ -> None
;;

let entity_summaries decrypt_title db eid attr =
  Datascript.datoms db Eavt ~e:eid ~a:attr ()
  |> List.of_seq
  |> List.filter_map (fun datom ->
    Option.bind (Ds_value.ref_eid db attr datom.v) (entity_summary decrypt_title db))
;;

let visible_tag_summaries decrypt_title db eid =
  Datascript.datoms db Eavt ~e:eid ~a:"block/tags" ()
  |> List.of_seq
  |> List.filter_map (fun datom ->
    Option.bind (Ds_value.ref_eid db "block/tags" datom.v) (fun tag_eid ->
      let internal =
        match value db tag_eid "db/ident" with
        | Some (Keyword ident) -> String.starts_with ~prefix:"logseq." ident
        | _ -> false
      in
      if internal
      then None
      else
        Option.bind (entity_summary decrypt_title db tag_eid) (fun summary ->
          if String.equal summary.Model.kind "tag" then Some summary else None)))
;;

let status_for_eid decrypt_title db eid =
  match Ds_value.optional_ref_eid db "logseq.property/status" (value db eid "logseq.property/status") with
  | None -> None
  | Some status_eid ->
    let ident =
      match value db status_eid "db/ident" with
      | Some (Keyword value) -> Some value
      | _ -> None
    in
    let uuid = Option.value (uuid_for_eid db status_eid) ~default:(Option.value ident ~default:"") in
    let title =
      Option.value (protected_string decrypt_title (value db status_eid "block/title")) ~default:uuid
    in
    if String.equal uuid ""
    then None
    else
      Some
        Model.
          { uuid
          ; ident
          ; title
          ; icon_type = None
          ; icon_id = None
          ; icon_color = None
          }
;;

let block decrypt_title db eid =
  let uuid = uuid_for_eid db eid in
  let title = protected_string decrypt_title (value db eid "block/title") in
  let name = value db eid "block/name" in
  match uuid, title with
  | Some uuid, Some title when Option.is_none name ->
    let referenced_uuid attr =
      match Ds_value.optional_ref_eid db attr (value db eid attr) with
      | Some referenced_eid -> uuid_for_eid db referenced_eid
      | None -> None
    in
    let page_eid = Ds_value.optional_ref_eid db "block/page" (value db eid "block/page") in
    let page_id = Option.bind page_eid (uuid_for_eid db) |> Option.value ~default:"" in
    let journal =
      Option.bind page_eid (fun page_eid ->
        match
          protected_string decrypt_title (value db page_eid "block/title"),
          int_value (value db page_eid "block/journal-day")
        with
        | Some title, Some day -> Some (title, day)
        | _ -> None)
    in
    let parent_id = referenced_uuid "block/parent" in
    let order = string_value (value db eid "block/order") in
    let created_at = Option.value (int_value (value db eid "block/created-at")) ~default:0 in
    let updated_at =
      Option.value (int_value (value db eid "block/updated-at")) ~default:created_at
    in
    let status = status_for_eid decrypt_title db eid in
    let asset_type = string_value (value db eid "logseq.property.asset/type") in
    let kind =
      match asset_type, status with
      | Some _, _ -> "asset"
      | None, Some _ -> "task"
      | None, None -> "block"
    in
    Some
      Model.
        { uuid
        ; kind
        ; title
        ; page_id
        ; parent_id
        ; order
        ; created_at
        ; updated_at
        ; sync_status = "synced"
        ; tags = visible_tag_summaries decrypt_title db eid
        ; references = entity_summaries decrypt_title db eid "block/refs"
        ; status
        ; asset_type
        ; asset_size = int_value (value db eid "logseq.property.asset/size")
        ; asset_checksum = string_value (value db eid "logseq.property.asset/checksum")
        ; local_path = None
        ; journal
        }
  | _ -> None
;;

let take count values =
  let rec loop remaining acc = function
    | _ when remaining = 0 -> List.rev acc
    | [] -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop count [] values
;;

let rec page_is_hidden db seen eid =
  if Int_set.mem eid seen
  then false
  else
    let seen = Int_set.add eid seen in
    match value db eid "logseq.property/hide?", value db eid "logseq.property/deleted-at" with
    | Some (Bool true), _ | _, Some _ -> true
    | _ ->
      (match Ds_value.optional_ref_eid db "block/parent" (value db eid "block/parent") with
       | Some parent_eid -> page_is_hidden db seen parent_eid
       | None -> false)
;;

let page_summary decrypt_title db eid =
  match
    uuid_for_eid db eid,
    protected_string decrypt_title (value db eid "block/title"),
    string_value (value db eid "block/name")
  with
  | Some uuid, Some title, Some name
    when not (String.equal (String.trim title) "")
         && not (String.starts_with ~prefix:"$$$" name)
         && not (page_is_hidden db Int_set.empty eid) ->
    Some { uuid; title }
  | _ -> None
;;

let sidebar_pages ?(decrypt_title = fun value -> Ok value) db =
  let favorites =
    Datascript.datoms db Aevt ~a:"block/name" ~v:(String "$$$favorites") ()
    |> Seq.uncons
    |> Option.map (fun (favorite_page, _rest) -> favorite_page.e)
    |> Option.fold ~none:[] ~some:(fun favorite_page_eid ->
      Ds_value.datoms_by_ref db Aevt "block/page" favorite_page_eid
      |> List.of_seq
      |> List.filter_map (fun datom ->
        match Ds_value.optional_ref_eid db "block/link" (value db datom.e "block/link") with
        | None -> None
        | Some page_eid ->
          Option.map
            (fun page ->
              Option.value (string_value (value db datom.e "block/order")) ~default:"", page)
            (page_summary decrypt_title db page_eid))
      |> List.sort (fun (left, _) (right, _) -> String.compare left right)
      |> List.map snd)
  in
  let recent_pages =
    Datascript.datoms db Aevt ~a:"block/name" ()
    |> List.of_seq
    |> List.filter_map (fun datom ->
      Option.map
        (fun page ->
          Option.value (int_value (value db datom.e "block/updated-at")) ~default:0,
          Option.value (int_value (value db datom.e "block/journal-day")) ~default:0,
          datom.e,
          page)
        (page_summary decrypt_title db datom.e))
    |> List.sort (fun (left_updated, left_journal, left_eid, _) (right_updated, right_journal, right_eid, _) ->
      match compare right_updated left_updated with
      | 0 ->
        (match compare right_journal left_journal with
         | 0 -> compare right_eid left_eid
         | order -> order)
      | order -> order)
    |> List.fold_left
         (fun (seen, pages) (_updated_at, _journal_day, eid, page) ->
           if Int_set.mem eid seen then seen, pages
           else Int_set.add eid seen, page :: pages)
         (Int_set.empty, [])
    |> snd
    |> List.rev
    |> take 15
  in
  { favorites; recent_pages }
;;

let compare_blocks left right =
  match left.Model.order, right.Model.order with
  | Some left, Some right -> String.compare left right
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> compare left.created_at right.created_at
;;

let blocks_referencing ?(decrypt_title = fun value -> Ok value) db ~attr target_uuid =
  match Datascript.entid db "block/uuid" (Uuid target_uuid) with
  | None -> []
  | Some target_eid ->
    Ds_value.datoms_by_ref db Aevt attr target_eid
    |> List.of_seq
    |> List.filter_map (fun datom -> block decrypt_title db datom.e)
    |> List.sort compare_blocks
;;

let blocks_for_page ?(decrypt_title = fun value -> Ok value) db page_uuid =
  blocks_referencing ~decrypt_title db ~attr:"block/page" page_uuid
;;

let node_destination ?(decrypt_title = fun value -> Ok value) db uuid =
  match Datascript.entid db "block/uuid" (Uuid uuid) with
  | None -> None
  | Some eid ->
    let is_page = Option.is_some (string_value (value db eid "block/name")) in
    let page_eid =
      if is_page
      then Some eid
      else Ds_value.optional_ref_eid db "block/page" (value db eid "block/page")
    in
    Option.bind page_eid (fun page_eid ->
      Option.map (fun page -> page, not is_page) (page_summary decrypt_title db page_eid))
;;

let objects_for_tag ?(decrypt_title = fun value -> Ok value) db tag_uuid =
  blocks_referencing ~decrypt_title db ~attr:"block/tags" tag_uuid
;;

let references_for_node ?(decrypt_title = fun value -> Ok value) db node_uuid =
  blocks_referencing ~decrypt_title db ~attr:"block/refs" node_uuid
;;

let recent_journal_page_ids ?(limit = 7) db =
  Datascript.datoms db Aevt ~a:"block/journal-day" ()
    |> List.of_seq
    |> List.filter_map (fun datom ->
      match datom.v with
      | Int day -> Some (day, datom.e)
      | _ -> None)
    |> List.sort (fun (left, _) (right, _) -> compare right left)
    |> take limit
    |> List.map snd
;;

let journal_page_count db =
  Datascript.datoms db Aevt ~a:"block/journal-day" ()
  |> Seq.fold_left (fun count _ -> count + 1) 0
;;

let journal_page_uuid db ~journal_day =
  Datascript.datoms db Aevt ~a:"block/journal-day" ()
  |> Seq.find_map (fun datom ->
    match datom.v with
    | Int day when day = journal_day -> uuid_for_eid db datom.e
    | _ -> None)
;;

let blocks ?(decrypt_title = fun value -> Ok value) ?(journal_limit = 7) db =
  let entity_ids =
    recent_journal_page_ids ~limit:journal_limit db
    |> List.fold_left
         (fun ids page_eid ->
           Ds_value.datoms_by_ref db Aevt "block/page" page_eid
           |> List.of_seq
           |> List.fold_left (fun ids datom -> Int_set.add datom.e ids) ids)
         Int_set.empty
  in
  entity_ids
  |> Int_set.to_seq
  |> Seq.filter_map (block decrypt_title db)
  |> List.of_seq
  |> List.sort (fun left right -> compare left.Model.created_at right.Model.created_at)
;;

type projection =
  { decrypt_title : string -> (string, string) result
  ; mutable recent_pages : Int_set.t
  ; blocks_by_uuid : (string, Model.block) Hashtbl.t
  }

let recent_pages db =
  recent_journal_page_ids db
  |> List.fold_left (fun pages eid -> Int_set.add eid pages) Int_set.empty
;;

let rebuild_projection projection db =
  projection.recent_pages <- recent_pages db;
  Hashtbl.clear projection.blocks_by_uuid;
  blocks ~decrypt_title:projection.decrypt_title db
  |> List.iter (fun (block : Model.block) ->
    Hashtbl.replace projection.blocks_by_uuid block.uuid block)
;;

let create_projection ?(decrypt_title = fun value -> Ok value) db =
  let projection =
    { decrypt_title; recent_pages = Int_set.empty; blocks_by_uuid = Hashtbl.create 128 }
  in
  rebuild_projection projection db;
  projection
;;

let projection_blocks projection =
  Hashtbl.to_seq_values projection.blocks_by_uuid
  |> List.of_seq
  |> List.sort (fun left right -> compare left.Model.created_at right.Model.created_at)
;;

let identity = function
  | Transit_core.Json.Array
      [ Transit_core.Json.Keyword "block/uuid"; Transit_core.Json.Uuid uuid ] ->
    Some (`Uuid uuid)
  | Transit_core.Json.Array
      [ Transit_core.Json.Keyword "db/ident"; Transit_core.Json.Keyword ident ] ->
    Some (`Ident ident)
  | _ -> None
;;

let has_journal_day (entity : Logseq_chat_sync_protocol.entity) =
  List.exists
    (function
      | Transit_core.Json.Keyword "block/journal-day", _ -> true
      | _ -> false)
    entity.attrs
;;

let refresh_block projection db uuid =
  match Datascript.entid db "block/uuid" (Uuid uuid) with
  | None -> Hashtbl.remove projection.blocks_by_uuid uuid
  | Some eid ->
    let page_is_recent =
      match Ds_value.optional_ref_eid db "block/page" (value db eid "block/page") with
      | Some page_eid -> Int_set.mem page_eid projection.recent_pages
      | None -> false
    in
    if page_is_recent
    then
      (match block projection.decrypt_title db eid with
       | Some block -> Hashtbl.replace projection.blocks_by_uuid uuid block
       | None -> Hashtbl.remove projection.blocks_by_uuid uuid)
    else Hashtbl.remove projection.blocks_by_uuid uuid
;;

let update_projection projection db (change : Logseq_chat_sync_protocol.change_set) =
  let deleted_uuids =
    List.fold_left
      (fun uuids identity_value ->
        match identity identity_value with
        | Some (`Uuid uuid) -> String_set.add uuid uuids
        | Some (`Ident _) | None -> uuids)
      String_set.empty
      change.deleted
  in
  let changed_uuids, changed_idents =
    List.fold_left
      (fun (uuids, idents) (entity : Logseq_chat_sync_protocol.entity) ->
        match identity entity.id with
        | Some (`Uuid uuid) -> String_set.add uuid uuids, idents
        | Some (`Ident ident) -> uuids, String_set.add ident idents
        | None -> uuids, idents)
      (String_set.empty, String_set.empty)
      change.upserts
  in
  let changed_uuids, changed_idents =
    List.fold_left
      (fun (uuids, idents) identity_value ->
        match identity identity_value with
        | Some (`Uuid uuid) -> String_set.add uuid uuids, idents
        | Some (`Ident ident) -> uuids, String_set.add ident idents
        | None -> uuids, idents)
      (changed_uuids, changed_idents)
      change.deleted
  in
  let current_journal_deleted =
    Hashtbl.to_seq_values projection.blocks_by_uuid
    |> Seq.exists (fun (block : Model.block) -> String_set.mem block.page_id deleted_uuids)
  in
  if List.exists has_journal_day change.upserts || current_journal_deleted
  then rebuild_projection projection db
  else (
    let affected = ref changed_uuids in
    Hashtbl.iter
      (fun uuid (block : Model.block) ->
        let related_entity_changed =
          List.exists
            (fun (summary : Model.entity_summary) ->
              String_set.mem summary.uuid changed_uuids)
            (block.tags @ block.references)
        in
        let status_changed =
          match block.status with
          | None -> false
          | Some status ->
            String_set.mem status.uuid changed_uuids
            || Option.fold
                 ~none:false
                 ~some:(fun ident -> String_set.mem ident changed_idents)
                 status.ident
        in
        if String_set.mem block.page_id changed_uuids
           || related_entity_changed
           || status_changed
        then affected := String_set.add uuid !affected)
      projection.blocks_by_uuid;
    String_set.iter (refresh_block projection db) !affected)
;;
