open Datascript

type entity_summary =
  { uuid : string
  ; title : string
  }

type status =
  { uuid : string
  ; ident : string option
  ; title : string
  ; icon_type : string option
  ; icon_id : string option
  ; icon_color : string option
  }

type block =
  { uuid : string
  ; title : string
  ; page_id : string
  ; parent_id : string option
  ; order : string option
  ; created_at : int
  ; updated_at : int
  ; sync_status : string
  ; tags : entity_summary list
  ; references : entity_summary list
  ; breadcrumbs : entity_summary list
  ; status : status option
  ; is_asset : bool
  ; asset_type : string option
  ; asset_size : int option
  ; asset_checksum : string option
  ; local_path : string option
  ; journal : (string * int) option
  }

type t =
  { mutable db : db
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

module Attribute = Datascript_lg.Attribute
module Codec = Datascript_lg.Codec

module Attr = struct
  let block_uuid =
    Attribute.make "block/uuid" Codec.string (one ~unique:Identity ~value_type:StringType ~indexed:true ())
  let block_title =
    Attribute.make "block/title" Codec.string (one ~value_type:StringType ())
  let block_page_id =
    Attribute.make "block/page-id" Codec.string (one ~value_type:StringType ~indexed:true ())
  let block_parent_id =
    Attribute.make "block/parent-id" Codec.string (one ~value_type:StringType ())
  let block_order =
    Attribute.make "block/order" Codec.string (one ~value_type:StringType ~indexed:true ())
  let block_created_at =
    Attribute.make "block/created-at" Codec.int (one ~value_type:NumberType ~indexed:true ())
  let block_updated_at =
    Attribute.make "block/updated-at" Codec.int (one ~value_type:NumberType ~indexed:true ())
  let block_sync_status =
    Attribute.make "block/sync-status" Codec.string (one ~value_type:StringType ~indexed:true ())
  let block_tags_json =
    Attribute.make "block/tags-json" Codec.string (one ~value_type:StringType ())
  let block_references_json =
    Attribute.make "block/references-json" Codec.string (one ~value_type:StringType ())
  let block_breadcrumbs_json =
    Attribute.make "block/breadcrumbs-json" Codec.string (one ~value_type:StringType ())
  let block_status_json =
    Attribute.make "block/status-json" Codec.string (one ~value_type:StringType ())
  let block_asset_type =
    Attribute.make "block/asset-type" Codec.string (one ~value_type:StringType ~indexed:true ())
  let block_asset_size =
    Attribute.make "block/asset-size" Codec.int (one ~value_type:NumberType ())
  let block_asset_checksum =
    Attribute.make "block/asset-checksum" Codec.string (one ~value_type:StringType ())
  let block_local_path =
    Attribute.make "block/local-path" Codec.string (one ~value_type:StringType ())
  let page_journal_day =
    Attribute.make "page/journal-day" Codec.int (one ~value_type:NumberType ~indexed:true ())
  let page_title =
    Attribute.make "page/title" Codec.string (one ~value_type:StringType ())
end

let schema =
  [ Attribute.schema Attr.block_uuid
  ; Attribute.schema Attr.block_title
  ; Attribute.schema Attr.block_page_id
  ; Attribute.schema Attr.block_parent_id
  ; Attribute.schema Attr.block_order
  ; Attribute.schema Attr.block_created_at
  ; Attribute.schema Attr.block_updated_at
  ; Attribute.schema Attr.block_sync_status
  ; Attribute.schema Attr.block_tags_json
  ; Attribute.schema Attr.block_references_json
  ; Attribute.schema Attr.block_breadcrumbs_json
  ; Attribute.schema Attr.block_status_json
  ; Attribute.schema Attr.block_asset_type
  ; Attribute.schema Attr.block_asset_size
  ; Attribute.schema Attr.block_asset_checksum
  ; Attribute.schema Attr.block_local_path
  ; Attribute.schema Attr.page_journal_day
  ; Attribute.schema Attr.page_title
  ]
;;

let add attribute entity_ref value =
  Add (entity_ref, Attribute.name attribute, Codec.encode (Attribute.codec attribute) value)
;;

let read attribute entity =
  Option.bind entity (fun entity ->
    Datascript_lg.or_raise (Attribute.read_one attribute entity))
;;

let block_ref uuid =
  Lookup_ref (Attribute.name Attr.block_uuid, Codec.encode (Attribute.codec Attr.block_uuid) uuid)

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
  { db; selected_block_uuid = None; last_refresh_at = None; revision = 0 }
;;

let summaries_json (summaries : entity_summary list) =
  `List
    (List.map
       (fun (summary : entity_summary) ->
         `Assoc
           [ "uuid", `String summary.uuid
           ; "title", `String summary.title
           ])
       summaries)
  |> Yojson.Basic.to_string
;;

let summaries_of_json value =
  match Yojson.Basic.from_string value with
  | `List values ->
    List.filter_map
      (function
        | `Assoc fields ->
          (match List.assoc_opt "uuid" fields, List.assoc_opt "title" fields with
           | Some (`String uuid), Some (`String title) ->
             Some { uuid; title }
           | _ -> None)
        | _ -> None)
      values
  | _ -> []
  | exception _ -> []
;;

let status_json (status : status) =
  let optional name = function Some value -> [ name, `String value ] | None -> [] in
  `Assoc
    ([ "uuid", `String status.uuid; "title", `String status.title ]
     @ optional "ident" status.ident
     @ optional "icon-type" status.icon_type
     @ optional "icon-id" status.icon_id
     @ optional "icon-color" status.icon_color)
  |> Yojson.Basic.to_string
;;

let status_of_json value =
  let string fields name =
    match List.assoc_opt name fields with Some (`String value) -> Some value | _ -> None
  in
  match Yojson.Basic.from_string value with
  | `Assoc fields ->
    (match string fields "uuid", string fields "title" with
     | Some uuid, Some title ->
       Some
         { uuid
         ; ident = string fields "ident"
         ; title
         ; icon_type = string fields "icon-type"
         ; icon_id = string fields "icon-id"
         ; icon_color = string fields "icon-color"
         }
     | _ -> None)
  | _ -> None
  | exception _ -> None
;;

let block_exists model uuid =
  Option.is_some (read Attr.block_uuid (entity model.db (block_ref uuid)))
;;

let read_block model uuid =
  let entity = entity model.db (block_ref uuid) in
  match read Attr.block_uuid entity with
  | None -> None
  | Some uuid ->
    let read attribute = read attribute entity in
    let default attribute value = Option.value (read attribute) ~default:value in
    let asset_type = read Attr.block_asset_type in
    Some
      { uuid
      ; title = default Attr.block_title ""
      ; page_id = default Attr.block_page_id ""
      ; parent_id = read Attr.block_parent_id
      ; order = read Attr.block_order
      ; created_at = default Attr.block_created_at 0
      ; updated_at = default Attr.block_updated_at 0
      ; sync_status = default Attr.block_sync_status "synced"
      ; tags = summaries_of_json (default Attr.block_tags_json "[]")
      ; references = summaries_of_json (default Attr.block_references_json "[]")
      ; breadcrumbs = summaries_of_json (default Attr.block_breadcrumbs_json "[]")
      ; status = Option.bind (read Attr.block_status_json) status_of_json
      ; is_asset = Option.is_some asset_type
      ; asset_type
      ; asset_size = read Attr.block_asset_size
      ; asset_checksum = read Attr.block_asset_checksum
      ; local_path = read Attr.block_local_path
      ; journal = None
      }
;;

let journal_metadata model page_id =
  let entity = entity model.db (block_ref page_id) in
  let journal_day = Option.value (read Attr.page_journal_day entity) ~default:0 in
  if journal_day <= 0 then None
  else Some (Option.value (read Attr.page_title entity) ~default:"", journal_day)
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

let all_statuses model =
  let prefix = "status-catalog/" in
  datoms model.db Aevt ~a:"block/uuid" () |> List.of_seq
  |> List.filter_map (fun datom ->
    match datom.v with
    | String uuid when
        String.length uuid > String.length prefix
        && String.equal (String.sub uuid 0 (String.length prefix)) prefix ->
      Option.bind (read_block model uuid) (fun block -> block.status)
    | _ -> None)
;;

let journal_day_for_ms now =
  let timestamp = float_of_int now /. 1000.0 in
  let tm = Unix.localtime timestamp in
  ((tm.tm_year + 1900) * 10000) + ((tm.tm_mon + 1) * 100) + tm.tm_mday
;;

let block_journal_metadata model block =
  match block.journal with
  | Some _ as journal -> journal
  | None -> journal_metadata model block.page_id
;;

let is_journal_feed_block model block =
  block.page_id <> ""
  &&
  match block_journal_metadata model block with
  | Some (_, journal_day) ->
    journal_day <= journal_day_for_ms (int_of_float (Unix.gettimeofday () *. 1000.0))
  | None -> false
;;

let is_recent_feed_block model block =
  not (String.equal (String.trim block.title) "")
  && is_journal_feed_block model block
;;

let compare_recent left right =
  match Int.compare right.created_at left.created_at with
  | 0 -> String.compare left.uuid right.uuid
  | value -> value
;;

let compare_outliner left right =
  match left.order, right.order with
  | Some left_order, Some right_order ->
    (match String.compare left_order right_order with
     | 0 -> String.compare left.uuid right.uuid
     | value -> value)
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None ->
    (match Int.compare left.created_at right.created_at with
     | 0 -> String.compare left.uuid right.uuid
     | value -> value)
;;

let outliner_preorder ~page_id blocks =
  let by_uuid = Hashtbl.create (List.length blocks) in
  let children = Hashtbl.create (List.length blocks) in
  List.iter (fun block -> Hashtbl.replace by_uuid block.uuid block) blocks;
  List.iter
    (fun block ->
      let parent =
        match block.parent_id with
        | Some parent_id when Hashtbl.mem by_uuid parent_id -> parent_id
        | Some parent_id when String.equal parent_id page_id -> page_id
        | Some _ | None -> page_id
      in
      let siblings = Option.value (Hashtbl.find_opt children parent) ~default:[] in
      Hashtbl.replace children parent (block :: siblings))
    blocks;
  let visited = Hashtbl.create (List.length blocks) in
  let rec walk parent =
    Option.value (Hashtbl.find_opt children parent) ~default:[]
    |> List.sort compare_outliner
    |> List.concat_map (fun block ->
      if Hashtbl.mem visited block.uuid
      then []
      else (
        Hashtbl.replace visited block.uuid ();
        block :: walk block.uuid))
  in
  let ordered = walk page_id in
  let remaining =
    blocks
    |> List.filter (fun block -> not (Hashtbl.mem visited block.uuid))
    |> List.sort compare_outliner
  in
  ordered @ remaining
;;

let journal_blocks ?(include_empty = false) model blocks =
  let by_page = Hashtbl.create 8 in
  List.iter
    (fun block ->
      if
        (if include_empty
         then is_journal_feed_block model block
         else is_recent_feed_block model block)
      then (
        let page_blocks = Option.value (Hashtbl.find_opt by_page block.page_id) ~default:[] in
        Hashtbl.replace by_page block.page_id (block :: page_blocks)))
    blocks;
  Hashtbl.to_seq by_page
  |> List.of_seq
  |> List.sort (fun (left_page, left_blocks) (right_page, right_blocks) ->
    let journal_day page_id = function
      | block :: _ ->
        Option.fold
          ~none:0
          ~some:snd
          (block_journal_metadata model block)
      | [] -> Option.fold ~none:0 ~some:snd (journal_metadata model page_id)
    in
    let left_day = journal_day left_page left_blocks in
    let right_day = journal_day right_page right_blocks in
    match Int.compare left_day right_day with
    | 0 -> String.compare left_page right_page
    | value -> value)
  |> List.concat_map (fun (page_id, page_blocks) -> outliner_preorder ~page_id page_blocks)
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
  all_blocks model
  |> List.filter (is_recent_feed_block model)
  |> List.sort compare_recent
  |> take 100
  |> journal_blocks model
;;

let selected_block model =
  match model.selected_block_uuid with
  | Some uuid -> read_block model uuid
  | None -> None
;;

let commit model transactions =
  let report = transact model.db transactions in
  model.db <- report.db_after;
  model.revision <- model.revision + 1;
  match storage model.db with
  | Some storage -> store ~storage model.db
  | None -> ()
;;

let upsert_statuses model statuses =
  let transactions =
    List.concat_map
      (fun (status : status) ->
        let uuid = "status-catalog/" ^ status.uuid in
        let entity_ref =
          if block_exists model uuid then block_ref uuid else Temp_id ("status-" ^ status.uuid)
        in
        [ add Attr.block_uuid entity_ref uuid
        ; add Attr.block_title entity_ref ""
        ; add Attr.block_page_id entity_ref ""
        ; add Attr.block_created_at entity_ref 0
        ; add Attr.block_updated_at entity_ref 0
        ; add Attr.block_sync_status entity_ref "synced"
        ; add Attr.block_status_json entity_ref (status_json status)
        ])
      statuses
  in
  if transactions <> [] then commit model transactions
;;

let upsert_blocks ?in_recent_feed:_ model blocks ~refresh_time =
  let tx =
    List.concat_map
      (fun block ->
        let existing_block = read_block model block.uuid in
        let block =
          match existing_block with
          | Some existing when
              not (String.equal existing.sync_status "synced")
              && String.equal block.sync_status "synced" ->
            existing
          | Some existing when
              Option.is_some existing.local_path && Option.is_none block.local_path ->
            let prefer_local local_value remote_value =
              match local_value with Some _ -> local_value | None -> remote_value
            in
            { block with
              is_asset = existing.is_asset || block.is_asset
            ; asset_type = prefer_local existing.asset_type block.asset_type
            ; asset_size = prefer_local existing.asset_size block.asset_size
            ; asset_checksum = prefer_local existing.asset_checksum block.asset_checksum
            ; local_path = existing.local_path
            }
          | Some _ | None -> block
        in
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
        let order =
          match block.order with
          | Some _ -> block.order
          | None -> Option.bind existing_block (fun existing -> existing.order)
        in
        [ add Attr.block_uuid entity_ref block.uuid
        ; add Attr.block_title entity_ref block.title
        ; add Attr.block_page_id entity_ref page_id
        ; add Attr.block_created_at entity_ref created_at
        ; add Attr.block_updated_at entity_ref updated_at
        ; add Attr.block_sync_status entity_ref block.sync_status
        ; add Attr.block_tags_json entity_ref (summaries_json block.tags)
        ; add Attr.block_references_json entity_ref (summaries_json block.references)
        ; add Attr.block_breadcrumbs_json entity_ref (summaries_json block.breadcrumbs)
        ]
        @ (match block.status with
           | Some status -> [ add Attr.block_status_json entity_ref (status_json status) ]
           | None -> [])
        @ (match block.asset_type with
           | Some value -> [ add Attr.block_asset_type entity_ref value ]
           | None -> [])
        @ (match block.asset_size with
           | Some value -> [ add Attr.block_asset_size entity_ref value ]
           | None -> [])
        @ (match block.asset_checksum with
           | Some value -> [ add Attr.block_asset_checksum entity_ref value ]
           | None -> [])
        @ (match block.local_path with
           | Some value -> [ add Attr.block_local_path entity_ref value ]
           | None -> [])
        @ (match order with
           | Some value -> [ add Attr.block_order entity_ref value ]
           | None -> [])
        @
        match block.parent_id with
        | Some parent_id -> [ add Attr.block_parent_id entity_ref parent_id ]
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
    [ add Attr.block_uuid entity_ref uuid
    ; add Attr.page_journal_day entity_ref journal_day
    ; add Attr.page_title entity_ref title
    ]
;;

let cache_local_message model ~uuid ~title ~now =
  let page_id = journal_page_id_for_ms now in
  upsert_journal_page model ~uuid:page_id ~journal_day:(journal_day_for_ms now);
  upsert_blocks
    model
    [ { uuid
      ; title
      ; page_id
      ; parent_id = None
      ; order = None
      ; created_at = now
      ; updated_at = now
      ; sync_status = "pending"
      ; tags = []
      ; references = []
      ; breadcrumbs = []
      ; status = None
      ; is_asset = false
      ; asset_type = None
      ; asset_size = None
      ; asset_checksum = None
      ; local_path = None
      ; journal = None
      }
    ]
    ~refresh_time:now
;;

let cache_local_task model ~uuid ~title ~status ~now =
  let page_id = journal_page_id_for_ms now in
  upsert_journal_page model ~uuid:page_id ~journal_day:(journal_day_for_ms now);
  upsert_blocks model
    [ { uuid; title; page_id; parent_id = None; order = None; created_at = now
      ; updated_at = now; sync_status = "pending"; tags = []; references = []; breadcrumbs = []
      ; status = Some status; is_asset = false; asset_type = None; asset_size = None
      ; asset_checksum = None; local_path = None; journal = None } ]
    ~refresh_time:now
;;

let cache_local_asset ?target_block_id model ~uuid ~title ~asset_type ~asset_size ~asset_checksum ~local_path ~now =
  let target = Option.bind target_block_id (read_block model) in
  let page_id =
    match target with
    | Some block -> block.page_id
    | None -> journal_page_id_for_ms now
  in
  if Option.is_none target
  then upsert_journal_page model ~uuid:page_id ~journal_day:(journal_day_for_ms now);
  upsert_blocks model
    [ { uuid; title; page_id; parent_id = Option.map (fun block -> block.uuid) target
      ; order = None; created_at = now
      ; updated_at = now; sync_status = "pending"; tags = []; references = []; breadcrumbs = []
      ; status = None; is_asset = true; asset_type = Some asset_type; asset_size = Some asset_size
      ; asset_checksum = Some asset_checksum; local_path = Some local_path; journal = None } ]
    ~refresh_time:now
;;

let cache_local_child model ~uuid ~title ~parent_id ~now =
  match read_block model parent_id with
  | None -> Error ("unknown parent block: " ^ parent_id)
  | Some parent ->
    upsert_blocks model
      [ { uuid; title; page_id = parent.page_id; parent_id = Some parent_id; order = None
        ; created_at = now; updated_at = now; sync_status = "pending"; tags = []
        ; references = []; breadcrumbs = []; status = None; is_asset = false
        ; asset_type = None; asset_size = None; asset_checksum = None; local_path = None
        ; journal = None
        }
      ]
      ~refresh_time:now;
    Ok ()
;;

let pending_blocks model =
  all_blocks model
  |> List.filter (fun block ->
    String.equal block.sync_status "pending" || String.equal block.sync_status "failed")
  |> List.sort compare_recent
;;

let unsynced_blocks model =
  all_blocks model
  |> List.filter (fun block -> not (String.equal block.sync_status "synced"))
  |> List.sort compare_recent
;;

let mark_block_synced model ~uuid =
  if not (block_exists model uuid)
  then Error ("unknown block: " ^ uuid)
  else (
    commit model [ add Attr.block_sync_status (block_ref uuid) "synced" ];
    Ok ())
;;

let mark_block_submitted model ~uuid =
  if not (block_exists model uuid)
  then Error ("unknown block: " ^ uuid)
  else (
    commit model [ add Attr.block_sync_status (block_ref uuid) "submitted" ];
    Ok ())
;;

let reconcile_created_block ?(sync_status = "submitted") model ~local_uuid ~remote_uuid =
  match read_block model local_uuid with
  | None -> Error ("unknown block: " ^ local_uuid)
  | Some _ when String.equal local_uuid remote_uuid ->
    commit model [ add Attr.block_sync_status (block_ref local_uuid) sync_status ];
    Ok ()
  | Some local ->
    let remote = read_block model remote_uuid in
    let base = Option.value remote ~default:local in
    let prefer_local local_value remote_value =
      match local_value with Some _ -> local_value | None -> remote_value
    in
    let reconciled =
      { base with
        uuid = remote_uuid
      ; sync_status
      ; is_asset = local.is_asset || base.is_asset
      ; asset_type = prefer_local local.asset_type base.asset_type
      ; asset_size = prefer_local local.asset_size base.asset_size
      ; asset_checksum = prefer_local local.asset_checksum base.asset_checksum
      ; local_path = prefer_local local.local_path base.local_path
      }
    in
    upsert_blocks model [ reconciled ] ~refresh_time:(max local.updated_at base.updated_at);
    commit model [ RetractEntity (block_ref local_uuid) ];
    Ok ()
;;

let mark_block_sync_failed model ~uuid =
  if not (block_exists model uuid)
  then Error ("unknown block: " ^ uuid)
  else (
    commit model [ add Attr.block_sync_status (block_ref uuid) "failed" ];
    Ok ())
;;

let update_block_title model ~uuid ~title ~now =
  if not (block_exists model uuid)
  then Error ("unknown block: " ^ uuid)
  else (
    commit
      model
      [ add Attr.block_title (block_ref uuid) title
      ; add Attr.block_updated_at (block_ref uuid) now
      ; add Attr.block_sync_status (block_ref uuid) "pending"
      ];
    Ok ())
;;

let update_block_status model ~uuid ~status ~now =
  if not (block_exists model uuid)
  then Error ("unknown block: " ^ uuid)
  else (
    commit
      model
      [ add Attr.block_status_json (block_ref uuid) (status_json status)
      ; add Attr.block_updated_at (block_ref uuid) now
      ; add Attr.block_sync_status (block_ref uuid) "pending"
      ];
    Ok ())
;;

let visible_blocks model = recent_blocks model

let visible_from model blocks =
  blocks
  |> List.filter (is_journal_feed_block model)
  |> List.sort compare_recent
  |> take 100
  |> journal_blocks ~include_empty:true model
;;
