open Datascript
module Model = Logseq_chat_model

module Int_set = Set.Make (Int)

let value db eid attr =
  Datascript.datoms db Eavt ~e:eid ~a:attr ()
  |> Seq.uncons
  |> Option.map (fun (datom, _rest) -> datom.v)
;;

let string_value = function
  | Some (String value) -> Some value
  | _ -> None
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

let status_for_eid db eid =
  match ref_value (value db eid "logseq.property/status") with
  | None -> None
  | Some status_eid ->
    let ident =
      match value db status_eid "db/ident" with
      | Some (Keyword value) -> Some value
      | _ -> None
    in
    let uuid = Option.value (uuid_for_eid db status_eid) ~default:(Option.value ident ~default:"") in
    let title = Option.value (string_value (value db status_eid "block/title")) ~default:uuid in
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

let block db eid =
  let uuid = uuid_for_eid db eid in
  let title = string_value (value db eid "block/title") in
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
          string_value (value db page_eid "block/title"),
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
    let status = status_for_eid db eid in
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

let blocks db =
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
  |> Seq.filter_map (block db)
  |> List.of_seq
  |> List.sort (fun left right -> compare left.Model.created_at right.Model.created_at)
;;
