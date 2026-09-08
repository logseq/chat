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

let ref_eids db eid attr =
  Datascript.datoms db Eavt ~e:eid ~a:attr ()
  |> Seq.filter_map (fun datom -> Ds_value.ref_eid db attr datom.v)
  |> List.of_seq
;;

let class_descendants db root_eid =
  let rec visit seen = function
    | [] -> seen
    | eid :: rest when Int_set.mem eid seen -> visit seen rest
    | eid :: rest ->
      let children =
        Ds_value.datoms_by_ref db Aevt "logseq.property.class/extends" eid
        |> Seq.map (fun datom -> datom.e)
        |> List.of_seq
      in
      visit (Int_set.add eid seen) (List.rev_append children rest)
  in
  visit Int_set.empty [ root_eid ]
;;

let entity_is_instance_of db eid class_ident =
  match Datascript.entid db "db/ident" (Keyword class_ident) with
  | None -> false
  | Some class_eid ->
    let accepted_classes = class_descendants db class_eid in
    ref_eids db eid "block/tags"
    |> List.exists (fun tag_eid -> Int_set.mem tag_eid accepted_classes)
;;

let entity_summary decrypt_title db eid =
  match uuid_for_eid db eid, protected_string decrypt_title (value db eid "block/title") with
  | Some uuid, Some title ->
    Some Model.{ uuid; title }
  | _ -> None
;;

let entity_summaries decrypt_title db eid attr =
  Datascript.datoms db Eavt ~e:eid ~a:attr ()
  |> List.of_seq
  |> List.filter_map (fun datom ->
    Option.bind (Ds_value.ref_eid db attr datom.v) (entity_summary decrypt_title db))
;;

let tag_is_visible_in_node db eid =
  match value db eid "db/ident", value db eid "logseq.property.class/hide-from-node" with
  | Some (Keyword "logseq.class/Task"), _ | _, Some (Bool true) -> false
  | _ -> true
;;

let visible_tag_summaries decrypt_title db eid =
  Datascript.datoms db Eavt ~e:eid ~a:"block/tags" ()
  |> List.of_seq
  |> List.filter_map (fun datom ->
    Option.bind (Ds_value.ref_eid db "block/tags" datom.v) (fun tag_eid ->
      if not (tag_is_visible_in_node db tag_eid)
      then None
      else
        if entity_is_instance_of db tag_eid "logseq.class/Tag"
        then entity_summary decrypt_title db tag_eid
        else None))
;;

let breadcrumbs decrypt_title db eid =
  let rec collect seen eid acc =
    if Int_set.mem eid seen
    then acc
    else
      let seen = Int_set.add eid seen in
      match Ds_value.optional_ref_eid db "block/parent" (value db eid "block/parent") with
      | None -> acc
      | Some parent_eid ->
        let acc =
          match entity_summary decrypt_title db parent_eid with
          | Some summary -> summary :: acc
          | None -> acc
        in
        collect seen parent_eid acc
  in
  collect Int_set.empty eid []
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
    let breadcrumbs = breadcrumbs decrypt_title db eid in
    let journal =
      Option.bind page_eid (fun page_eid ->
        match
          List.find_opt
            (fun (summary : Model.entity_summary) -> String.equal summary.uuid page_id)
            breadcrumbs
          |> Option.map (fun (summary : Model.entity_summary) -> summary.title),
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
    let is_asset = entity_is_instance_of db eid "logseq.class/Asset" in
    let asset_type = string_value (value db eid "logseq.property.asset/type") in
    Some
      Model.
        { uuid
        ; title
        ; page_id
        ; parent_id
        ; order
        ; created_at
        ; updated_at
        ; sync_status = "synced"
        ; tags = visible_tag_summaries decrypt_title db eid
        ; references = entity_summaries decrypt_title db eid "block/refs"
        ; breadcrumbs
        ; status
        ; is_asset
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

let favorite_page_eid db =
  Datascript.datoms db Aevt ~a:"block/name" ~v:(String "$$$favorites") ()
  |> Seq.uncons
  |> Option.map (fun (datom, _rest) -> datom.e)
;;

let recycle_page_eid db =
  Datascript.datoms db Aevt ~a:"block/name" ~v:(String "recycle") ()
  |> Seq.uncons
  |> Option.map (fun (datom, _rest) -> datom.e)
;;

let last_recycle_order db =
  match recycle_page_eid db with
  | None -> None
  | Some recycle_eid ->
    Ds_value.datoms_by_ref db Aevt "block/parent" recycle_eid
    |> Seq.filter_map (fun datom -> string_value (value db datom.e "block/order"))
    |> Seq.fold_left
         (fun latest order ->
           match latest with
           | Some current when String.compare current order >= 0 -> latest
           | Some _ | None -> Some order)
         None
;;

let favorite_block_eid db page_uuid =
  match favorite_page_eid db, Datascript.entid db "block/uuid" (Uuid page_uuid) with
  | Some favorites_eid, Some page_eid ->
    Ds_value.datoms_by_ref db Aevt "block/page" favorites_eid
    |> Seq.find_map (fun datom ->
      match Ds_value.optional_ref_eid db "block/link" (value db datom.e "block/link") with
      | Some linked_eid when linked_eid = page_eid -> Some datom.e
      | Some _ | None -> None)
  | _ -> None
;;

let favorite_block_uuid db page_uuid =
  Option.bind (favorite_block_eid db page_uuid) (uuid_for_eid db)
;;

let page_is_favorite db page_uuid = Option.is_some (favorite_block_eid db page_uuid)

let last_favorite_order db =
  match favorite_page_eid db with
  | None -> None
  | Some favorites_eid ->
    Ds_value.datoms_by_ref db Aevt "block/page" favorites_eid
    |> Seq.filter_map (fun datom -> string_value (value db datom.e "block/order"))
    |> Seq.fold_left
         (fun latest order ->
           match latest with
           | Some current when String.compare current order >= 0 -> latest
           | Some _ | None -> Some order)
         None
;;

let built_in_class db eid =
  match value db eid "db/ident" with
  | Some (Keyword ident) -> String.starts_with ~prefix:"logseq.class/" ident
  | _ -> false
;;

let sidebar_pages ?(decrypt_title = fun value -> Ok value) db =
  let favorites =
    favorite_page_eid db
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
  let favorite_uuids =
    List.fold_left
      (fun uuids page -> String_set.add page.uuid uuids)
      String_set.empty
      favorites
  in
  let recent_pages =
    let seen = Hashtbl.create 15 in
    (* Rank lightweight page metadata first; only decrypt and resolve titles
       until the visible window is full. *)
    Datascript.datoms db Aevt ~a:"block/name" ()
    |> List.of_seq
    |> List.filter (fun datom ->
      match datom.v with
      | String name -> not (String.starts_with ~prefix:"$$$" name)
      | _ -> false)
    |> List.filter_map (fun datom ->
      let attrs = Datascript.datoms db Eavt ~e:datom.e () |> List.of_seq in
      let attr name =
        List.find_opt (fun datom -> String.equal datom.a name) attrs
        |> Option.map (fun datom -> datom.v)
      in
      if attr "logseq.property/built-in?" = Some (Bool true)
         || built_in_class db datom.e
      then None
      else
        Some
        ( Option.value (int_value (attr "block/updated-at")) ~default:0
        , Option.value (int_value (attr "block/journal-day")) ~default:0
        , datom.e ))
    |> List.sort (fun (left_updated, left_journal, left_eid) (right_updated, right_journal, right_eid) ->
      match compare right_updated left_updated with
      | 0 ->
        (match compare right_journal left_journal with
         | 0 -> compare right_eid left_eid
         | order -> order)
      | order -> order)
    |> List.to_seq
    |> Seq.filter_map (fun (_updated_at, _journal_day, eid) ->
      if Hashtbl.mem seen eid then None
      else (
        Hashtbl.add seen eid ();
        match page_summary decrypt_title db eid with
        | Some page when not (String_set.mem page.uuid favorite_uuids) -> Some page
        | Some _ | None -> None))
    |> Seq.take 15
    |> List.of_seq
  in
  { favorites; recent_pages }
;;

(* Tag objects can be pages (for example journals tagged #Journal or property
   pages tagged #Property); represent them as page-level blocks so tagged-node
   lists can show them. *)
let page_block decrypt_title db eid =
  match page_summary decrypt_title db eid with
  | None -> None
  | Some page ->
    let created_at = Option.value (int_value (value db eid "block/created-at")) ~default:0 in
    let updated_at =
      Option.value (int_value (value db eid "block/updated-at")) ~default:created_at
    in
    let journal =
      Option.map
        (fun day -> page.title, day)
        (int_value (value db eid "block/journal-day"))
    in
    Some
      Model.
        { uuid = page.uuid
        ; title = page.title
        ; page_id = page.uuid
        ; parent_id = None
        ; order = None
        ; created_at
        ; updated_at
        ; sync_status = "synced"
        ; tags = visible_tag_summaries decrypt_title db eid
        ; references = []
        ; breadcrumbs = []
        ; status = None
        ; is_asset = false
        ; asset_type = None
        ; asset_size = None
        ; asset_checksum = None
        ; local_path = None
        ; journal
        }
;;

(* Match Logseq's get-all-classes filtering, independently of whether a tag
   is shown on a rendered node. In particular, Task remains selectable. *)
let tag_available_for_completion db eid =
  match value db eid "db/ident" with
  | Some (Keyword ident) ->
    not (List.mem ident
           [ "logseq.class/Root"; "logseq.class/Page"; "logseq.class/Property"
           ; "logseq.class/Tag"; "logseq.class/Asset"; "logseq.class/Journal"
           ; "logseq.class/Whiteboard"; "logseq.class/Pdf-annotation" ])
  | _ -> true
;;

let tag_last_used db eid =
  Ds_value.datoms_by_ref db Aevt "block/tags" eid
  |> Seq.fold_left (fun latest datom -> max latest datom.tx) 0
;;

let tag_pages ?(decrypt_title = fun value -> Ok value) db =
  match Datascript.entid db "db/ident" (Keyword "logseq.class/Tag") with
  | None -> []
  | Some tag_class_eid ->
    Ds_value.datoms_by_ref db Aevt "block/tags" tag_class_eid
    |> List.of_seq
    |> List.filter_map (fun datom ->
      if tag_available_for_completion db datom.e
      then Option.map (fun page -> tag_last_used db datom.e, page)
             (page_summary decrypt_title db datom.e)
      else None)
    |> List.sort (fun (left_used, left) (right_used, right) ->
      match compare right_used left_used with
      | 0 -> (match String.compare left.title right.title with
              | 0 -> String.compare left.uuid right.uuid
              | order -> order)
      | order -> order)
    |> List.map snd
;;

let node_is_tag db uuid =
  match Datascript.entid db "block/uuid" (Uuid uuid) with
  | None -> false
  | Some eid -> entity_is_instance_of db eid "logseq.class/Tag"
;;

let node_is_property db uuid =
  match Datascript.entid db "block/uuid" (Uuid uuid) with
  | None -> false
  | Some eid -> entity_is_instance_of db eid "logseq.class/Property"
;;

(* Resolve a page or tag name to the uuid of the unique entity carrying it;
   duplicated names stay unresolved so text never re-binds silently. *)
let unique_named_uuid ?(require_tag = false) db name =
  let key = String.lowercase_ascii (String.trim name) in
  if String.equal key ""
  then None
  else (
    let matches =
      Datascript.datoms db Aevt ~a:"block/name" ~v:(String key) ()
      |> List.of_seq
      |> List.map (fun datom -> datom.e)
      |> List.filter (fun eid ->
        (not require_tag) || entity_is_instance_of db eid "logseq.class/Tag")
    in
    match matches with
    | [ eid ] -> uuid_for_eid db eid
    | _ -> None)
;;

(* Editor text -> stored uuid form (Logseq's title-ref->id-ref): first match
   names against the block's existing refs and tags, then fall back to a
   unique db-wide page or tag name. Hashtag names that resolve to nothing are
   offered to [create_tag], which may mint a uuid for a brand-new tag. *)
let normalize_title_text ?(create_tag = fun _name -> None) db ~uuid title =
  let plain = fun value -> Ok value in
  let refs, tags =
    match Datascript.entid db "block/uuid" (Uuid uuid) with
    | None -> [], []
    | Some eid ->
      entity_summaries plain db eid "block/refs", entity_summaries plain db eid "block/tags"
  in
  let known summaries name =
    let key = String.lowercase_ascii (String.trim name) in
    if String.equal key ""
    then None
    else (
      match
        List.filter
          (fun (summary : Model.entity_summary) ->
            String.equal (String.lowercase_ascii summary.title) key)
          summaries
      with
      | [ summary ] -> Some summary.Model.uuid
      | _ -> None)
  in
  Logseq_chat_ref_text.to_ids
    ~resolve_ref:(fun name ->
      match known (refs @ tags) name with
      | Some uuid -> Some uuid
      | None -> unique_named_uuid db name)
    ~resolve_tag:(fun name ->
      match known tags name with
      | Some uuid -> Some uuid
      | None ->
        (match unique_named_uuid ~require_tag:true db name with
         | Some uuid -> Some uuid
         | None -> create_tag name))
    title
;;

(* Normalize all title payloads of one operation together, minting a shared
   fresh uuid for each hashtag that does not resolve to an existing tag. The
   caller creates the returned (uuid, title) tags before applying the
   operation. *)
let normalize_titles_creating_tags db ~fresh_uuid ~uuid titles =
  let created = ref [] in
  let create_tag name =
    let name = String.trim name in
    let key = String.lowercase_ascii name in
    if String.equal key ""
    then None
    else (
      match
        List.find_opt
          (fun (_, existing) -> String.equal (String.lowercase_ascii existing) key)
          !created
      with
      | Some (existing_uuid, _) -> Some existing_uuid
      | None ->
        let new_uuid = fresh_uuid () in
        created := !created @ [ new_uuid, name ];
        Some new_uuid)
  in
  let titles = List.map (normalize_title_text ~create_tag db ~uuid) titles in
  titles, !created
;;

let compare_blocks left right =
  match left.Model.order, right.Model.order with
  | Some left, Some right -> String.compare left right
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> compare left.created_at right.created_at
;;

let compare_journal_blocks left right =
  let journal_day block =
    match block.Model.journal with Some (_, day) -> day | None -> 0
  in
  match compare (journal_day right) (journal_day left) with
  | 0 -> compare_blocks left right
  | order -> order
;;

(* Match Logseq's related-content visibility rules: hidden or recycled nodes,
   nodes below them, and view definition nodes are implementation details and
   must not leak into linked references or class objects. *)
let related_candidate_is_visible db eid =
  not (page_is_hidden db Int_set.empty eid)
  && Option.is_none (value db eid "logseq.property/view-for")
;;

let blocks_referencing ?(decrypt_title = fun value -> Ok value) db ~attr target_uuid =
  match Datascript.entid db "block/uuid" (Uuid target_uuid) with
  | None -> []
  | Some target_eid ->
    Ds_value.datoms_by_ref db Aevt attr target_eid
    |> List.of_seq
    |> List.filter (fun datom -> related_candidate_is_visible db datom.e)
    |> List.filter_map (fun datom -> block decrypt_title db datom.e)
    |> List.sort compare_blocks
;;

let blocks_for_page ?(decrypt_title = fun value -> Ok value) db page_uuid =
  blocks_referencing ~decrypt_title db ~attr:"block/page" page_uuid
;;

let node_destination ?(decrypt_title = fun value -> Ok value) db uuid =
  match Datascript.entid db "block/uuid" (Uuid uuid) with
  | None -> None
  | Some eid when page_is_hidden db Int_set.empty eid -> None
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

(* Tagged nodes are ordinary blocks or whole pages (journals, property pages,
   class instances); newest journals sort first, then blocks in outliner
   order. *)
let objects_for_tag ?(decrypt_title = fun value -> Ok value) db tag_uuid =
  let journal_day (candidate : Model.block) =
    match candidate.journal with Some (_, day) -> day | None -> 0
  in
  let compare_objects left right =
    match compare (journal_day right) (journal_day left) with
    | 0 -> compare_blocks left right
    | order -> order
  in
  match Datascript.entid db "block/uuid" (Uuid tag_uuid) with
  | None -> []
  | Some tag_eid ->
    class_descendants db tag_eid
    |> Int_set.to_seq
    |> Seq.flat_map (Ds_value.datoms_by_ref db Aevt "block/tags")
    |> Seq.fold_left (fun eids datom -> Int_set.add datom.e eids) Int_set.empty
    |> Int_set.to_seq
    |> Seq.filter (related_candidate_is_visible db)
    |> Seq.filter_map (fun eid ->
      match block decrypt_title db eid with
      | Some value -> Some value
      | None -> page_block decrypt_title db eid)
    |> List.of_seq
    |> List.sort compare_objects
;;

let references_for_node ?(decrypt_title = fun value -> Ok value) db node_uuid =
  blocks_referencing ~decrypt_title db ~attr:"block/refs" node_uuid
;;

let recent_journal_page_ids ?(limit = 7) db =
  Datascript.datoms db Aevt ~a:"block/journal-day" ()
    |> List.of_seq
    |> List.filter_map (fun datom ->
      match datom.v with
      | Int day when not (page_is_hidden db Int_set.empty datom.e) ->
        Some (day, datom.e)
      | _ -> None)
    |> List.sort (fun (left, _) (right, _) -> compare right left)
    |> take limit
    |> List.map snd
;;

let journal_page_count db =
  Datascript.datoms db Aevt ~a:"block/journal-day" ()
  |> Seq.fold_left
       (fun count datom ->
         if page_is_hidden db Int_set.empty datom.e then count else count + 1)
       0
;;

let journal_page_uuid db ~journal_day =
  Datascript.datoms db Aevt ~a:"block/journal-day" ()
  |> Seq.find_map (fun datom ->
    match datom.v with
    | Int day
      when day = journal_day
           && not (page_is_hidden db Int_set.empty datom.e) ->
      uuid_for_eid db datom.e
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
  |> List.sort compare_journal_blocks
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
  |> List.sort compare_journal_blocks
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
  if not (Int_set.equal projection.recent_pages (recent_pages db))
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
