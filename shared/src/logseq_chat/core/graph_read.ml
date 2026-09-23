module Ds = Datascript
module Model = Cache_model
module Ds_value = Datascript_value
module S = String_kit

type sidebar_pages =
  { favorites : Model.entity_summary list
  ; recent_pages : Model.entity_summary list
  }

let value db eid attr =
  match
    List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:attr ())
  with
  | datom :: _ -> Some datom.Ds.v
  | [] -> None

let string_value = function
  | Some (Ds.String value) -> Some value
  | _ -> None

let uuid_value = function
  | Some (Ds.Uuid value) | Some (Ds.String value) -> Some value
  | _ -> None

let int_value = function
  | Some (Ds.Int value) | Some (Ds.Instant value) -> Some value
  | _ -> None

let protected_string decrypt_title value =
  match string_value value with
  | Some value ->
    (match decrypt_title value with
     | Ok value -> Some value
     | Error message -> failwith ("decrypt graph title: " ^ message))
  | None -> None

let uuid_for_eid db eid = uuid_value (value db eid "block/uuid")

let has_ref db eid attr target_eid =
  Seq.exists
    (fun (datom : Ds.datom) ->
      Ds_value.ref_eid db attr datom.v = Some target_eid)
    (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:attr ())

let ref_eids db eid attr =
  List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:attr ())
  |> List.filter_map (fun (datom : Ds.datom) -> Ds_value.ref_eid db attr datom.v)

let class_descendants db root_eid =
  let rec loop pending seen =
    match pending with
    | [] -> seen
    | eid :: rest ->
      if List.mem eid seen then loop rest seen
      else
        loop
          (List.of_seq
             (Ds_value.datoms_by_ref db Ds.Aevt "logseq.property.class/extends"
                eid)
          |> List.map (fun (datom : Ds.datom) -> datom.e)
          |> fun children -> children @ rest)
          (eid :: seen)
  in
  loop [ root_eid ] []

let entity_is_instance_of db eid class_ident =
  match Ds.entid db "db/ident" (Ds.Keyword class_ident) with
  | Some class_eid ->
    let accepted = class_descendants db class_eid in
    List.exists
      (fun eid -> List.mem eid accepted)
      (ref_eids db eid "block/tags")
  | None -> false

let entity_summary decrypt_title db eid =
  let uuid = uuid_for_eid db eid in
  let title = protected_string decrypt_title (value db eid "block/title") in
  match (uuid, title) with
  | Some uuid, Some title -> Some { Model.uuid; title }
  | _ -> None

let entity_summaries decrypt_title db eid attr =
  List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:attr ())
  |> List.filter_map (fun (datom : Ds.datom) ->
    match Ds_value.ref_eid db attr datom.v with
    | Some eid -> entity_summary decrypt_title db eid
    | None -> None)

let tag_is_visible_in_node db eid =
  value db eid "db/ident" <> Some (Ds.Keyword "logseq.class/Task")
  && value db eid "logseq.property.class/hide-from-node"
     <> Some (Ds.Bool true)

let visible_tag_summaries decrypt_title db eid =
  List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:"block/tags" ())
  |> List.filter_map (fun (datom : Ds.datom) ->
    match Ds_value.ref_eid db "block/tags" datom.v with
    | Some tag_eid ->
      if
        tag_is_visible_in_node db tag_eid
        && entity_is_instance_of db tag_eid "logseq.class/Tag"
      then entity_summary decrypt_title db tag_eid
      else None
    | None -> None)

let rec breadcrumbs_loop decrypt_title db seen eid ancestors =
  if List.mem eid seen then ancestors
  else
    match
      Ds_value.optional_ref_eid db "block/parent"
        (value db eid "block/parent")
    with
    | Some parent_eid ->
      let ancestors =
        match entity_summary decrypt_title db parent_eid with
        | Some summary -> summary :: ancestors
        | None -> ancestors
      in
      breadcrumbs_loop decrypt_title db (eid :: seen) parent_eid ancestors
    | None -> ancestors

let breadcrumbs decrypt_title db eid =
  breadcrumbs_loop decrypt_title db [] eid []

let status_for_eid decrypt_title db eid =
  match
    Ds_value.optional_ref_eid db "logseq.property/status"
      (value db eid "logseq.property/status")
  with
  | Some status_eid ->
    let ident =
      match value db status_eid "db/ident" with
      | Some (Ds.Keyword ident) -> Some ident
      | _ -> None
    in
    let uuid = Option.value ~default:(Option.value ~default:"" ident) (uuid_for_eid db status_eid) in
    let title =
      Option.value ~default:uuid
        (protected_string decrypt_title (value db status_eid "block/title"))
    in
    if uuid <> "" then
      Some
        {
          Model.uuid;
          ident;
          title;
          icon_type = None;
          icon_id = None;
          icon_color = None;
        }
    else None
  | None -> None

let block decrypt_title db eid =
  let uuid = uuid_for_eid db eid in
  let title = protected_string decrypt_title (value db eid "block/title") in
  let name = value db eid "block/name" in
  match name with
  | Some _ -> None
  | None ->
    (match (uuid, title) with
     | Some uuid, Some title ->
       let referenced_uuid attr =
         match
           Ds_value.optional_ref_eid db attr (value db eid attr)
         with
         | Some eid -> uuid_for_eid db eid
         | None -> None
       in
       let page_eid =
         Ds_value.optional_ref_eid db "block/page" (value db eid "block/page")
       in
       let page_id =
         Option.value ~default:""
           (match page_eid with
            | Some eid -> uuid_for_eid db eid
            | None -> None)
       in
       let ancestors = breadcrumbs decrypt_title db eid in
       let journal =
         match page_eid with
         | Some page_eid ->
           let title =
             List.find_map
               (fun (summary : Model.entity_summary) ->
                 if summary.uuid = page_id then Some summary.title else None)
               ancestors
           in
           let day = int_value (value db page_eid "block/journal-day") in
           (match (title, day) with
            | Some title, Some day -> Some (title, day)
            | _ -> None)
         | None -> None
       in
       let created_at =
         Option.value ~default:0 (int_value (value db eid "block/created-at"))
       in
       Some
         {
           Model.uuid;
           title;
           page_id;
           parent_id = referenced_uuid "block/parent";
           order = string_value (value db eid "block/order");
           created_at;
           updated_at =
             Option.value ~default:created_at
               (int_value (value db eid "block/updated-at"));
           sync_status = "synced";
           tags = visible_tag_summaries decrypt_title db eid;
           references = entity_summaries decrypt_title db eid "block/refs";
           breadcrumbs = ancestors;
           status = status_for_eid decrypt_title db eid;
           is_asset = entity_is_instance_of db eid "logseq.class/Asset";
           asset_type =
             string_value (value db eid "logseq.property.asset/type");
           asset_size =
             int_value (value db eid "logseq.property.asset/size");
           asset_checksum =
             string_value (value db eid "logseq.property.asset/checksum");
           local_path = None;
           journal;
         }
     | _ -> None)

let page_is_hidden db eid =
  let rec loop seen eid =
    if List.mem eid seen then false
    else if value db eid "logseq.property/hide?" = Some (Ds.Bool true) then true
    else if Option.is_some (value db eid "logseq.property/deleted-at") then true
    else
      match
        Ds_value.optional_ref_eid db "block/parent"
          (value db eid "block/parent")
      with
      | Some parent_eid -> loop (eid :: seen) parent_eid
      | None -> false
  in
  loop [] eid

let page_summary decrypt_title db eid =
  let uuid = uuid_for_eid db eid in
  let title = protected_string decrypt_title (value db eid "block/title") in
  let name = string_value (value db eid "block/name") in
  match (uuid, title, name) with
  | Some uuid, Some title, Some name ->
    if
      S.trim title <> ""
      && not (S.starts_with ~prefix:"$$$" name)
      && not (page_is_hidden db eid)
    then Some { Model.uuid; title }
    else None
  | _ -> None

let favorite_page_eid db =
  match
    List.of_seq
      (Ds.Db.datoms db Ds.Aevt ~a:"block/name" ~v:(Ds.String "$$$favorites") ())
  with
  | datom :: _ -> Some datom.Ds.e
  | [] -> None

let recycle_page_eid db =
  match
    List.of_seq
      (Ds.Db.datoms db Ds.Aevt ~a:"block/name" ~v:(Ds.String "recycle") ())
  with
  | datom :: _ -> Some datom.Ds.e
  | [] -> None

let last_order db attr eid =
  let orders =
    List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt attr eid)
    |> List.filter_map (fun (datom : Ds.datom) ->
      string_value (value db datom.e "block/order"))
  in
  match orders with
  | first :: rest ->
    Some (List.fold_left (fun latest order -> if compare latest order >= 0 then latest else order) first rest)
  | [] -> None

let last_recycle_order db =
  match recycle_page_eid db with
  | Some eid -> last_order db "block/parent" eid
  | None -> None

let last_favorite_order db =
  match favorite_page_eid db with
  | Some eid -> last_order db "block/page" eid
  | None -> None

let favorite_block_eid db page_uuid =
  match (favorite_page_eid db, Ds.entid db "block/uuid" (Ds.Uuid page_uuid)) with
  | Some favorites_eid, Some page_eid ->
    List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/page" favorites_eid)
    |> List.find_map (fun (datom : Ds.datom) ->
      if
        Ds_value.optional_ref_eid db "block/link"
          (value db datom.e "block/link")
        = Some page_eid
      then Some datom.e
      else None)
  | _ -> None

let favorite_block_uuid db page_uuid =
  match favorite_block_eid db page_uuid with
  | Some eid -> uuid_for_eid db eid
  | None -> None

let page_is_favorite db page_uuid =
  Option.is_some (favorite_block_eid db page_uuid)

let built_in_class db eid =
  match value db eid "db/ident" with
  | Some (Ds.Keyword ident) -> S.starts_with ~prefix:"logseq.class/" ident
  | _ -> false

let sidebar_pages decrypt_title db =
  let favorites =
    match favorite_page_eid db with
    | Some eid ->
      List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/page" eid)
      |> List.filter_map (fun (datom : Ds.datom) ->
        match
          Ds_value.optional_ref_eid db "block/link"
            (value db datom.e "block/link")
        with
        | Some page_eid ->
          (match page_summary decrypt_title db page_eid with
           | Some page ->
             Some
               ( Option.value ~default:""
                   (string_value (value db datom.e "block/order"))
               , page )
           | None -> None)
        | None -> None)
      |> List.sort (fun (left, _) (right, _) -> compare left right)
      |> List.map snd
    | None -> []
  in
  let favorite_uuids =
    List.fold_left (fun set (page : Model.entity_summary) -> page.uuid :: set) [] favorites
  in
  let candidates =
    List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/name" ())
    |> List.filter_map (fun (datom : Ds.datom) ->
      match datom.v with
      | Ds.String name ->
        if S.starts_with ~prefix:"$$$" name then None
        else (
          let attrs =
            List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:datom.e ())
            |> List.map (fun (datom : Ds.datom) -> (datom.a, datom.v))
          in
          let built_in =
            match List.assoc_opt "db/ident" attrs with
            | Some (Ds.Keyword ident) ->
              S.starts_with ~prefix:"logseq.class/" ident
            | _ -> false
          in
          if
            (not built_in)
            && List.assoc_opt "logseq.property/built-in?" attrs
               <> Some (Ds.Bool true)
          then
            Some
              ( Option.value ~default:0
                  (int_value (List.assoc_opt "block/updated-at" attrs))
              , Option.value ~default:0
                  (int_value (List.assoc_opt "block/journal-day" attrs))
              , datom.e )
          else None)
      | _ -> None)
  in
  let ranked =
    List.sort
      (fun (left_updated, left_day, left_eid) (right_updated, right_day, right_eid) ->
        let updated = compare right_updated left_updated in
        let day = compare right_day left_day in
        if updated <> 0 then updated
        else if day <> 0 then day
        else compare right_eid left_eid)
      candidates
  in

  (* Resolve and decrypt only enough ranked pages to fill the window:
     stay lazy like the original seq pipeline. *)
  let seq_distinct xs =
    let seen = Hashtbl.create 16 in
    let rec loop xs () =
      match xs () with
      | Seq.Nil -> Seq.Nil
      | Seq.Cons (x, rest) ->
        if Hashtbl.mem seen x then loop rest ()
        else (
          Hashtbl.replace seen x ();
          Seq.Cons (x, loop rest))
    in
    loop xs
  in
  let recent_seq =
    List.to_seq ranked
    |> Seq.map (fun (_, _, eid) -> eid)
    |> seq_distinct
    |> Seq.filter_map (fun eid ->
      match page_summary decrypt_title db eid with
      | Some page ->
        if List.mem page.Model.uuid favorite_uuids then None else Some page
      | None -> None)
  in
  let rec take n xs () =
    if n <= 0 then Seq.Nil
    else
      match xs () with
      | Seq.Nil -> Seq.Nil
      | Seq.Cons (x, rest) -> Seq.Cons (x, take (n - 1) rest)
  in
  { favorites; recent_pages = List.of_seq (take 15 recent_seq) }

let page_block decrypt_title db eid =
  match page_summary decrypt_title db eid with
  | Some page ->
    let created_at =
      Option.value ~default:0 (int_value (value db eid "block/created-at"))
    in
    Some
      {
        Model.uuid = page.uuid;
        title = page.title;
        page_id = page.uuid;
        parent_id = None;
        order = None;
        created_at;
        updated_at =
          Option.value ~default:created_at
            (int_value (value db eid "block/updated-at"));
        sync_status = "synced";
        tags = visible_tag_summaries decrypt_title db eid;
        references = [];
        breadcrumbs = [];
        status = None;
        is_asset = false;
        asset_type = None;
        asset_size = None;
        asset_checksum = None;
        local_path = None;
        journal =
          (match int_value (value db eid "block/journal-day") with
           | Some day -> Some (page.title, day)
           | None -> None);
      }
  | None -> None

let tag_available_for_completion db eid =
  match value db eid "db/ident" with
  | Some (Ds.Keyword ident) ->
    not
      (List.mem ident
         [
           "logseq.class/Root";
           "logseq.class/Page";
           "logseq.class/Property";
           "logseq.class/Tag";
           "logseq.class/Asset";
           "logseq.class/Journal";
           "logseq.class/Whiteboard";
           "logseq.class/Pdf-annotation";
         ])
  | _ -> true

let tag_last_used db eid =
  List.fold_left
    (fun latest (datom : Ds.datom) -> max latest datom.tx)
    0
    (List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/tags" eid))

let tag_pages decrypt_title db =
  match Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Tag") with
  | Some eid ->
    List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/tags" eid)
    |> List.filter_map (fun (datom : Ds.datom) ->
      if tag_available_for_completion db datom.e then
        match page_summary decrypt_title db datom.e with
        | Some page -> Some (tag_last_used db datom.e, page)
        | None -> None
      else None)
    |> List.sort
         (fun (left_used, (left : Model.entity_summary))
              (right_used, (right : Model.entity_summary)) ->
           let used = compare right_used left_used in
           let title = compare left.title right.title in
           if used <> 0 then used
           else if title <> 0 then title
           else compare left.uuid right.uuid)
    |> List.map snd
  | None -> []

let node_is_tag db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> entity_is_instance_of db eid "logseq.class/Tag"
  | None -> false

let node_is_property db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> entity_is_instance_of db eid "logseq.class/Property"
  | None -> false

let unique_named_uuid require_tag db name =
  let key = String.lowercase_ascii (S.trim name) in
  if key = "" then None
  else (
    let matches =
      List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/name" ~v:(Ds.String key) ())
      |> List.map (fun (datom : Ds.datom) -> datom.e)
      |> List.filter (fun eid ->
        (not require_tag) || entity_is_instance_of db eid "logseq.class/Tag")
    in
    match matches with
    | [ eid ] -> uuid_for_eid db eid
    | _ -> None)

let known_title summaries name =
  let key = String.lowercase_ascii (S.trim name) in
  if key = "" then None
  else (
    let matches =
      List.filter
        (fun (summary : Model.entity_summary) ->
          String.lowercase_ascii summary.title = key)
        summaries
    in
    match matches with
    | [ summary ] -> Some summary.Model.uuid
    | _ -> None)

let normalize_title_text create_tag db uuid title =
  let refs, tags =
    match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
    | Some eid ->
      ( entity_summaries (fun value -> Ok value) db eid "block/refs"
      , entity_summaries (fun value -> Ok value) db eid "block/tags" )
    | None -> ([], [])
  in
  Ref_text.to_ids
    (fun name ->
      match known_title (refs @ tags) name with
      | Some uuid -> Some uuid
      | None -> unique_named_uuid false db name)
    (fun name ->
      match known_title tags name with
      | Some uuid -> Some uuid
      | None ->
        (match unique_named_uuid true db name with
         | Some uuid -> Some uuid
         | None -> create_tag name))
    title

type created_tags =
  { entries : (string * string) list ref
  }

let normalize_titles_creating_tags db fresh_uuid uuid titles =
  let created = { entries = ref [] } in
  let create_tag name =
    let name = S.trim name in
    let key = String.lowercase_ascii name in
    if key = "" then None
    else
      match
        List.find_map
          (fun (uuid, existing) ->
            if String.lowercase_ascii existing = key then Some uuid else None)
          !(created.entries)
      with
      | Some uuid -> Some uuid
      | None ->
        let uuid = fresh_uuid () in
        created.entries := (uuid, name) :: !(created.entries);
        Some uuid
  in
  let titles = List.map (normalize_title_text create_tag db uuid) titles in
  (titles, List.rev !(created.entries))

let compare_blocks left right =
  match (left.Model.order, right.Model.order) with
  | Some left_order, Some right_order -> compare left_order right_order
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> compare left.Model.created_at right.Model.created_at

let journal_day (block : Model.block) =
  match block.journal with Some (_, day) -> day | None -> 0

let compare_journal_blocks left right =
  let order = compare (journal_day right) (journal_day left) in
  if order = 0 then compare_blocks left right else order

let related_candidate_is_visible db eid =
  (not (page_is_hidden db eid))
  && value db eid "logseq.property/view-for" = None

let blocks_referencing decrypt_title db attr target_uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid target_uuid) with
  | Some eid ->
    List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt attr eid)
    |> List.filter_map (fun (datom : Ds.datom) ->
      if related_candidate_is_visible db datom.e then
        block decrypt_title db datom.e
      else None)
    |> List.sort compare_blocks
  | None -> []

let blocks_for_page decrypt_title db uuid =
  blocks_referencing decrypt_title db "block/page" uuid

let references_for_node decrypt_title db uuid =
  blocks_referencing decrypt_title db "block/refs" uuid

let node_destination decrypt_title db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid ->
    if page_is_hidden db eid then None
    else (
      let is_page =
        Option.is_some (string_value (value db eid "block/name"))
      in
      let page_eid =
        if is_page then Some eid
        else
          Ds_value.optional_ref_eid db "block/page"
            (value db eid "block/page")
      in
      match page_eid with
      | Some page_eid ->
        (match page_summary decrypt_title db page_eid with
         | Some page -> Some (page, not is_page)
         | None -> None)
      | None -> None)
  | None -> None

let objects_for_tag decrypt_title db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid ->
    let ids =
      class_descendants db eid
      |> List.sort_uniq compare
      |> List.concat_map (fun eid ->
        List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/tags" eid)
        |> List.map (fun (datom : Ds.datom) -> datom.e))
      |> List.sort_uniq compare
    in
    ids
    |> List.filter_map (fun eid ->
      if related_candidate_is_visible db eid then
        match block decrypt_title db eid with
        | Some block -> Some block
        | None -> page_block decrypt_title db eid
      else None)
    |> List.sort compare_journal_blocks
  | None -> []

let recent_journal_page_ids limit db =
  List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/journal-day" ())
  |> List.filter_map (fun (datom : Ds.datom) ->
    match datom.v with
    | Ds.Int day ->
      if page_is_hidden db datom.e then None else Some (day, datom.e)
    | _ -> None)
  |> List.sort (fun (left, _) (right, _) -> compare right left)
  |> fun pairs ->
  let rec take n l =
    match l with
    | [] -> []
    | x :: rest -> if n = 0 then [] else x :: take (n - 1) rest
  in
  take limit pairs |> List.map snd

let journal_page_count db =
  List.fold_left
    (fun count (datom : Ds.datom) ->
      if page_is_hidden db datom.e then count else count + 1)
    0
    (List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/journal-day" ()))

let journal_page_uuid db day =
  List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/journal-day" ())
  |> List.find_map (fun (datom : Ds.datom) ->
    match datom.v with
    | Ds.Int candidate ->
      if candidate = day && not (page_is_hidden db datom.e) then
        uuid_for_eid db datom.e
      else None
    | _ -> None)

let blocks decrypt_title journal_limit db =
  let ids =
    recent_journal_page_ids journal_limit db
    |> List.concat_map (fun eid ->
      List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/page" eid)
      |> List.map (fun (datom : Ds.datom) -> datom.e))
    |> List.sort_uniq compare
  in
  ids
  |> List.filter_map (fun eid -> block decrypt_title db eid)
  |> List.sort compare_journal_blocks
