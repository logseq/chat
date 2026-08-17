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
  ; "block/title", one ~value_type:StringType ()
  ; "block/page-id", one ~value_type:StringType ~indexed:true ()
  ; "block/parent-id", one ~value_type:StringType ()
  ; "block/order", one ~value_type:StringType ~indexed:true ()
  ; "block/created-at", one ~value_type:NumberType ~indexed:true ()
  ; "block/updated-at", one ~value_type:NumberType ~indexed:true ()
  ; "block/sync-status", one ~value_type:StringType ~indexed:true ()
  ; "block/tags-json", one ~value_type:StringType ()
  ; "block/references-json", one ~value_type:StringType ()
  ; "block/breadcrumbs-json", one ~value_type:StringType ()
  ; "block/status-json", one ~value_type:StringType ()
  ; "block/asset-type", one ~value_type:StringType ~indexed:true ()
  ; "block/asset-size", one ~value_type:NumberType ()
  ; "block/asset-checksum", one ~value_type:StringType ()
  ; "block/local-path", one ~value_type:StringType ()
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
  entity_attr_value model.db (block_ref uuid) "block/uuid" <> None
;;

let read_block model uuid =
  if not (block_exists model uuid)
  then None
  else (
    let entity_ref = block_ref uuid in
    Some
      { uuid
      ; title = string_attr model.db entity_ref "block/title" ""
      ; page_id = string_attr model.db entity_ref "block/page-id" ""
      ; parent_id = option_string_attr model.db entity_ref "block/parent-id"
      ; order = option_string_attr model.db entity_ref "block/order"
      ; created_at = int_attr model.db entity_ref "block/created-at" 0
      ; updated_at = int_attr model.db entity_ref "block/updated-at" 0
      ; sync_status = string_attr model.db entity_ref "block/sync-status" "synced"
      ; tags = summaries_of_json (string_attr model.db entity_ref "block/tags-json" "[]")
      ; references = summaries_of_json (string_attr model.db entity_ref "block/references-json" "[]")
      ; breadcrumbs = summaries_of_json (string_attr model.db entity_ref "block/breadcrumbs-json" "[]")
      ; status = Option.bind (option_string_attr model.db entity_ref "block/status-json") status_of_json
      ; is_asset = Option.is_some (option_string_attr model.db entity_ref "block/asset-type")
      ; asset_type = option_string_attr model.db entity_ref "block/asset-type"
      ; asset_size = Option.bind (entity_attr_value model.db entity_ref "block/asset-size") value_int
      ; asset_checksum = option_string_attr model.db entity_ref "block/asset-checksum"
      ; local_path = option_string_attr model.db entity_ref "block/local-path"
      ; journal = None
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
  | None ->
    let journal_day = int_attr model.db (block_ref block.page_id) "page/journal-day" 0 in
    if journal_day <= 0
    then None
    else Some (string_attr model.db (block_ref block.page_id) "page/title" "", journal_day)
;;

let is_recent_feed_block model block =
  not (String.equal (String.trim block.title) "")
  && block.page_id <> ""
  &&
  match block_journal_metadata model block with
  | Some (_, journal_day) ->
    journal_day <= journal_day_for_ms (int_of_float (Unix.gettimeofday () *. 1000.0))
  | None -> false
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

let journal_blocks model blocks =
  let by_page = Hashtbl.create 8 in
  List.iter
    (fun block ->
      if is_recent_feed_block model block
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
      | [] -> int_attr model.db (block_ref page_id) "page/journal-day" 0
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
    not (String.equal (String.trim block.title) ""))
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

let upsert_statuses model statuses =
  let transactions =
    List.concat_map
      (fun (status : status) ->
        let uuid = "status-catalog/" ^ status.uuid in
        let entity_ref =
          if block_exists model uuid then block_ref uuid else Temp_id ("status-" ^ status.uuid)
        in
        [ Add (entity_ref, "block/uuid", String uuid)
        ; Add (entity_ref, "block/title", String "")
        ; Add (entity_ref, "block/page-id", String "")
        ; Add (entity_ref, "block/created-at", Int 0)
        ; Add (entity_ref, "block/updated-at", Int 0)
        ; Add (entity_ref, "block/sync-status", String "synced")
        ; Add (entity_ref, "block/status-json", String (status_json status))
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
        [ Add (entity_ref, "block/uuid", String block.uuid)
        ; Add (entity_ref, "block/title", String block.title)
        ; Add (entity_ref, "block/page-id", String page_id)
        ; Add (entity_ref, "block/created-at", Int created_at)
        ; Add (entity_ref, "block/updated-at", Int updated_at)
        ; Add (entity_ref, "block/sync-status", String block.sync_status)
        ; Add (entity_ref, "block/tags-json", String (summaries_json block.tags))
        ; Add (entity_ref, "block/references-json", String (summaries_json block.references))
        ; Add (entity_ref, "block/breadcrumbs-json", String (summaries_json block.breadcrumbs))
        ]
        @ (match block.status with
           | Some status -> [ Add (entity_ref, "block/status-json", String (status_json status)) ]
           | None -> [])
        @ (match block.asset_type with
           | Some value -> [ Add (entity_ref, "block/asset-type", String value) ]
           | None -> [])
        @ (match block.asset_size with
           | Some value -> [ Add (entity_ref, "block/asset-size", Int value) ]
           | None -> [])
        @ (match block.asset_checksum with
           | Some value -> [ Add (entity_ref, "block/asset-checksum", String value) ]
           | None -> [])
        @ (match block.local_path with
           | Some value -> [ Add (entity_ref, "block/local-path", String value) ]
           | None -> [])
        @ (match order with
           | Some value -> [ Add (entity_ref, "block/order", String value) ]
           | None -> [])
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

let cache_local_asset model ~uuid ~title ~asset_type ~asset_size ~asset_checksum ~local_path ~now =
  let page_id = journal_page_id_for_ms now in
  upsert_journal_page model ~uuid:page_id ~journal_day:(journal_day_for_ms now);
  upsert_blocks model
    [ { uuid; title; page_id; parent_id = None; order = None; created_at = now
      ; updated_at = now; sync_status = "pending"; tags = []; references = []; breadcrumbs = []
      ; status = None; is_asset = true; asset_type = Some asset_type; asset_size = Some asset_size
      ; asset_checksum = Some asset_checksum; local_path = Some local_path; journal = None } ]
    ~refresh_time:now
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
    commit model [ Add (block_ref uuid, "block/sync-status", String "synced") ];
    Ok ())
;;

let mark_block_submitted model ~uuid =
  if not (block_exists model uuid)
  then Error ("unknown block: " ^ uuid)
  else (
    commit model [ Add (block_ref uuid, "block/sync-status", String "submitted") ];
    Ok ())
;;

let reconcile_created_block ?(sync_status = "submitted") model ~local_uuid ~remote_uuid =
  match read_block model local_uuid with
  | None -> Error ("unknown block: " ^ local_uuid)
  | Some _ when String.equal local_uuid remote_uuid ->
    commit model [ Add (block_ref local_uuid, "block/sync-status", String sync_status) ];
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
      ; Add (block_ref uuid, "block/sync-status", String "pending")
      ];
    Ok ())
;;

let update_block_status model ~uuid ~status ~now =
  if not (block_exists model uuid)
  then Error ("unknown block: " ^ uuid)
  else (
    commit
      model
      [ Add (block_ref uuid, "block/status-json", String (status_json status))
      ; Add (block_ref uuid, "block/updated-at", Int now)
      ; Add (block_ref uuid, "block/sync-status", String "pending")
      ];
    Ok ())
;;

let visible_blocks model =
  if String.equal (String.trim model.query) "" then recent_blocks model else search model model.query
;;

let visible_from model blocks =
  if String.equal (String.trim model.query) ""
  then
    blocks
    |> List.filter (is_recent_feed_block model)
    |> List.sort compare_recent
    |> take 100
    |> journal_blocks model
  else
    blocks
    |> List.filter (fun block ->
      not (String.equal (String.trim block.title) "")
      && title_matches model.query block)
    |> List.sort compare_recent
    |> take 100
;;
