open Datascript
module Model = Logseq_chat_model

module Int_set = Set.Make (Int)
module String_set = Set.Make (String)

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

let ref_value = function
  | Some (Ref eid) -> Some eid
  | _ -> None
;;

let uuid_for_eid db eid = uuid_value (value db eid "block/uuid")

let status_for_eid decrypt_title db eid =
  match ref_value (value db eid "logseq.property/status") with
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
      match ref_value (value db eid attr) with
      | Some referenced_eid -> uuid_for_eid db referenced_eid
      | None -> None
    in
    let page_eid = ref_value (value db eid "block/page") in
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
        ; tags = []
        ; references = []
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

let recent_journal_page_ids db =
  Datascript.datoms db Aevt ~a:"block/journal-day" ()
    |> List.of_seq
    |> List.filter_map (fun datom ->
      match datom.v with
      | Int day -> Some (day, datom.e)
      | _ -> None)
    |> List.sort (fun (left, _) (right, _) -> compare right left)
    |> take 7
    |> List.map snd
;;

let journal_page_uuid db ~journal_day =
  Datascript.datoms db Aevt ~a:"block/journal-day" ()
  |> Seq.find_map (fun datom ->
    match datom.v with
    | Int day when day = journal_day -> uuid_for_eid db datom.e
    | _ -> None)
;;

let blocks ?(decrypt_title = fun value -> Ok value) db =
  let entity_ids =
    recent_journal_page_ids db
    |> List.fold_left
         (fun ids page_eid ->
           Datascript.datoms db Aevt ~a:"block/page" ~v:(Ref page_eid) ()
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
      match ref_value (value db eid "block/page") with
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
        if String_set.mem block.page_id changed_uuids || status_changed
        then affected := String_set.add uuid !affected)
      projection.blocks_by_uuid;
    String_set.iter (refresh_block projection db) !affected)
;;
