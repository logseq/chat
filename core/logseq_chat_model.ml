open Datascript

type block =
  { uuid : string
  ; kind : string
  ; title : string
  ; page_id : string
  ; parent_id : string option
  ; created_at : int
  ; updated_at : int
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
  all_blocks model |> List.sort compare_recent |> take 100
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
  all_blocks model |> List.sort compare_recent |> List.filter (title_matches query) |> take 100
;;

let commit model transactions =
  let report = transact model.db transactions in
  model.db <- report.db_after;
  model.revision <- model.revision + 1;
  match storage model.db with
  | Some storage -> store ~storage model.db
  | None -> ()
;;

let upsert_blocks model blocks ~refresh_time =
  let tx =
    List.concat_map
      (fun block ->
        let entity_ref =
          if block_exists model block.uuid
          then block_ref block.uuid
          else Temp_id ("block-" ^ block.uuid)
        in
        [ Add (entity_ref, "block/uuid", String block.uuid)
        ; Add (entity_ref, "block/kind", String block.kind)
        ; Add (entity_ref, "block/title", String block.title)
        ; Add (entity_ref, "block/page-id", String block.page_id)
        ; Add (entity_ref, "block/created-at", Int block.created_at)
        ; Add (entity_ref, "block/updated-at", Int block.updated_at)
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

let cache_local_message model ~uuid ~title ~now =
  upsert_blocks
    model
    [ { uuid
      ; kind = "block"
      ; title
      ; page_id = "local-pending"
      ; parent_id = None
      ; created_at = now
      ; updated_at = now
      }
    ]
    ~refresh_time:now
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
