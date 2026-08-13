open Datascript

type block =
  { uuid : string
  ; kind : string
  ; title : string
  ; page_id : string
  ; parent_id : string option
  ; created_at : int
  ; updated_at : int
  ; sync_status : string
  }

type t =
  { mutable db : db
  ; mutable query : string
  ; mutable selected_block_uuid : string option
  ; mutable last_refresh_at : int option
  ; mutable revision : int
  }

let one ?unique ?value_type ?(indexed = false) () =
  { cardinality = One
  ; unique
  ; indexed
  ; is_component = false
  ; no_history = false
  ; doc = None
  ; value_type
  ; tuple_attrs = None
  ; tuple_types = None
  }
;;

let schema =
  [ "block/uuid", one ~unique:Identity ~value_type:StringType ~indexed:true ()
  ; "block/kind", one ~value_type:StringType ~indexed:true ()
  ; "block/title", one ~value_type:StringType ()
  ; "block/page-id", one ~value_type:StringType ~indexed:true ()
  ; "block/parent-id", one ~value_type:StringType ()
  ; "block/created-at", one ~value_type:NumberType ~indexed:true ()
  ; "block/updated-at", one ~value_type:NumberType ~indexed:true ()
  ; "block/sync-status", one ~value_type:StringType ~indexed:true ()
  ; "page/journal-day", one ~value_type:NumberType ~indexed:true ()
  ; "page/title", one ~value_type:StringType ()
  ]
;;

let block_ref uuid = Lookup_ref ("block/uuid", String uuid)

let create ?storage () =
  let db =
    match storage with
    | Some storage ->
      (match restore storage with
       | Some db -> db
       | None ->
         let db = empty_db ~schema ~storage () in
         store ~storage db;
         db)
    | None -> empty_db ~schema ()
  in
  { db; query = ""; selected_block_uuid = None; last_refresh_at = None; revision = 0 }
;;

let value_string = function
  | String value -> Some value
  | _ -> None
;;

let value_int = function
  | Int value -> Some value
  | _ -> None
;;

let entity_attr_value db entity_ref attr =
  match entity db entity_ref with
  | None -> None
  | Some entity ->
    (match entity_attr entity attr with
     | Some (One_value value) -> Some value
     | _ -> None)
;;

let string_attr db entity_ref attr default =
  match entity_attr_value db entity_ref attr with
  | Some value -> Option.value (value_string value) ~default
  | None -> default
;;

let int_attr db entity_ref attr default =
  match entity_attr_value db entity_ref attr with
  | Some value -> Option.value (value_int value) ~default
  | None -> default
;;

let option_string_attr db entity_ref attr =
  match entity_attr_value db entity_ref attr with
  | Some value -> value_string value
  | None -> None
;;

let block_exists model uuid =
  entity_attr_value model.db (block_ref uuid) "block/uuid" <> None
;;

let read_block model uuid =
  if not (block_exists model uuid)
  then None
  else (
    let entity_ref = block_ref uuid in
    Some
      { uuid
      ; kind = string_attr model.db entity_ref "block/kind" "block"
      ; title = string_attr model.db entity_ref "block/title" ""
      ; page_id = string_attr model.db entity_ref "block/page-id" ""
      ; parent_id = option_string_attr model.db entity_ref "block/parent-id"
      ; created_at = int_attr model.db entity_ref "block/created-at" 0
      ; updated_at = int_attr model.db entity_ref "block/updated-at" 0
      ; sync_status = string_attr model.db entity_ref "block/sync-status" "synced"
      })
;;

let all_block_uuids model =
  datoms model.db Aevt ~a:"block/uuid" () |> List.of_seq
  |> List.filter_map (fun datom ->
    match datom.v with
    | String uuid -> Some uuid
    | _ -> None)
;;

let all_blocks model =
  all_block_uuids model |> List.filter_map (read_block model)
;;

let journal_day_for_ms now =
  let timestamp = float_of_int now /. 1000.0 in
  let tm = Unix.localtime timestamp in
  ((tm.tm_year + 1900) * 10000) + ((tm.tm_mon + 1) * 100) + tm.tm_mday
;;

let is_recent_feed_block model block =
  String.equal block.kind "block"
  && not (String.equal (String.trim block.title) "")
  && block.page_id <> ""
  &&
  let journal_day =
    int_attr model.db (block_ref block.page_id) "page/journal-day" 0
  in
  journal_day > 0
  && journal_day <= journal_day_for_ms (int_of_float (Unix.gettimeofday () *. 1000.0))
;;

let compare_recent left right =
  match Int.compare right.created_at left.created_at with
  | 0 -> String.compare left.uuid right.uuid
  | value -> value
;;

let take count values =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop count [] values
;;

let recent_blocks model =
  all_blocks model |> List.filter (is_recent_feed_block model) |> List.sort compare_recent |> take 100
;;

let selected_block model =
  match model.selected_block_uuid with
  | Some uuid -> read_block model uuid
  | None -> None
;;

let lowercase value = String.lowercase_ascii value

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec check_at index needle_index =
    needle_index = needle_len
    || (index + needle_index < haystack_len
        && haystack.[index + needle_index] = needle.[needle_index]
        && check_at index (needle_index + 1))
  in
  let rec loop index =
    needle_len = 0
    || (index + needle_len <= haystack_len && (check_at index 0 || loop (index + 1)))
  in
  loop 0
;;

let title_matches query block =
  let query = lowercase (String.trim query) in
  String.equal query ""
  || contains_substring (lowercase block.title) query
;;

let search model query =
  model.query <- query;
  all_blocks model
  |> List.filter (fun block ->
    String.equal block.kind "block"
    && not (String.equal (String.trim block.title) ""))
  |> List.sort compare_recent
  |> List.filter (title_matches query)
  |> take 100
;;

let commit model transactions =
  let report = transact model.db transactions in
  model.db <- report.db_after;
  model.revision <- model.revision + 1;
  match storage model.db with
  | Some storage -> store ~storage model.db
  | None -> ()
;;

let upsert_blocks ?in_recent_feed:_ model blocks ~refresh_time =
  let tx =
    List.concat_map
      (fun block ->
        let existing_block = read_block model block.uuid in
        let entity_ref =
          match existing_block with
          | Some _ -> block_ref block.uuid
          | None -> Temp_id ("block-" ^ block.uuid)
        in
        let created_at =
          if block.created_at > 0
          then block.created_at
          else Option.fold ~none:0 ~some:(fun existing -> existing.created_at) existing_block
        in
        let updated_at =
          if block.updated_at > 0
          then block.updated_at
          else Option.fold ~none:created_at ~some:(fun existing -> existing.updated_at) existing_block
        in
        let page_id =
          if not (String.equal block.page_id "")
          then block.page_id
          else Option.fold ~none:"" ~some:(fun existing -> existing.page_id) existing_block
        in
        [ Add (entity_ref, "block/uuid", String block.uuid)
        ; Add (entity_ref, "block/kind", String block.kind)
        ; Add (entity_ref, "block/title", String block.title)
        ; Add (entity_ref, "block/page-id", String page_id)
        ; Add (entity_ref, "block/created-at", Int created_at)
        ; Add (entity_ref, "block/updated-at", Int updated_at)
        ; Add (entity_ref, "block/sync-status", String block.sync_status)
        ]
        @
        match block.parent_id with
        | Some parent_id -> [ Add (entity_ref, "block/parent-id", String parent_id) ]
        | None -> [])
      blocks
  in
  if tx <> [] then commit model tx;
  model.last_refresh_at <- Some refresh_time
;;

let select model uuid =
  if block_exists model uuid
  then (
    model.selected_block_uuid <- Some uuid;
    Ok ())
  else Error ("unknown block: " ^ uuid)
;;

let clear_selection model =
  model.selected_block_uuid <- None
;;

let journal_page_id_for_ms now =
  let timestamp = float_of_int now /. 1000.0 in
  let tm = Unix.localtime timestamp in
  Printf.sprintf "journal/%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
;;

let upsert_journal_page ?(title = "") model ~uuid ~journal_day =
  let entity_ref =
    if block_exists model uuid then block_ref uuid else Temp_id ("page-" ^ uuid)
  in
  commit
    model
    [ Add (entity_ref, "block/uuid", String uuid)
    ; Add (entity_ref, "block/kind", String "page")
    ; Add (entity_ref, "page/journal-day", Int journal_day)
    ; Add (entity_ref, "page/title", String title)
    ]
;;

let journal_metadata model page_id =
  let entity_ref = block_ref page_id in
  let journal_day = int_attr model.db entity_ref "page/journal-day" 0 in
  if journal_day <= 0
  then None
  else Some (string_attr model.db entity_ref "page/title" "", journal_day)
;;

let cache_local_message model ~uuid ~title ~now =
  let page_id = journal_page_id_for_ms now in
  upsert_journal_page model ~uuid:page_id ~journal_day:(journal_day_for_ms now);
  upsert_blocks
    model
    [ { uuid
      ; kind = "block"
      ; title
      ; page_id
      ; parent_id = None
      ; created_at = now
      ; updated_at = now
      ; sync_status = "pending"
      }
    ]
    ~refresh_time:now
;;

let pending_blocks model =
  all_blocks model
  |> List.filter (fun block ->
    String.equal block.sync_status "pending" || String.equal block.sync_status "failed")
  |> List.sort compare_recent
;;

let mark_block_synced model ~uuid =
  if not (block_exists model uuid)
  then Error ("unknown block: " ^ uuid)
  else (
    commit model [ Add (block_ref uuid, "block/sync-status", String "synced") ];
    Ok ())
;;

let mark_block_sync_failed model ~uuid =
  if not (block_exists model uuid)
  then Error ("unknown block: " ^ uuid)
  else (
    commit model [ Add (block_ref uuid, "block/sync-status", String "failed") ];
    Ok ())
;;

let update_block_title model ~uuid ~title ~now =
  if not (block_exists model uuid)
  then Error ("unknown block: " ^ uuid)
  else (
    commit
      model
      [ Add (block_ref uuid, "block/title", String title)
      ; Add (block_ref uuid, "block/updated-at", Int now)
      ];
    Ok ())
;;

let visible_blocks model =
  if String.equal (String.trim model.query) "" then recent_blocks model else search model model.query
;;
