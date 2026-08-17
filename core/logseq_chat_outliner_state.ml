module String_set = Set.Make (String)
module Model = Logseq_chat_model
module Ops = Logseq_chat_pending_ops
module Order = Logseq_chat_fractional_order

let option_value_map option ~default ~f = match option with Some value -> f value | None -> default
let list_last values = match List.rev values with value :: _ -> Some value | [] -> None

type autocomplete_kind =
  | Node
  | Tag
  | Property

type autocomplete =
  { kind : autocomplete_kind
  ; query : string
  }

type autocomplete_candidate =
  { label : string
  ; value : string
  }

type editing =
  { uuid : string
  ; expected_title : string
  ; title : string
  ; caret : int
  }

type t =
  { editing : editing option
  ; selected : String_set.t
  ; autocomplete : autocomplete option
  ; collapsed : String_set.t
  ; zoomed : string list
  }

type toolbar_action =
  | Task
  | Outdent
  | Indent
  | Tag_action
  | Page_reference
  | Camera
  | Attachment
  | Hide_keyboard
  | Copy
  | Delete
  | Copy_reference
  | Copy_url
  | Unselect

type drop_placement =
  | Before
  | Inside
  | After

type msg =
  | Tap_block of string
  | Long_press_block of string
  | Text_changed of
      { title : string
      ; caret : int
      }
  | Caret_moved of int
  | Return_pressed
  | Return_pressed_with_text of
      { title : string
      ; caret : int
      }
  | Backspace_pressed of { selection_length : int }
  | Backspace_pressed_with_text of
      { title : string
      ; selection_length : int
      }
  | Toolbar of toolbar_action
  | Drop_blocks of
      { target_uuid : string
      ; placement : drop_placement
      }
  | Choose_autocomplete of string
  | Confirm_delete
  | Cancel_editing
  | Set_task_status of
      { uuid : string
      ; status : Ops.semantic_value
      }
  | Toggle_collapsed of string
  | Zoom_in of string
  | Zoom_out
  | Operation_staged of Ops.intent

type haptic =
  | Selection
  | Impact

type cmd =
  | Haptic of haptic
  | Commit_title of
      { uuid : string
      ; expected_title : string
      ; title : string
      }
  | Split_at of
      { uuid : string
      ; expected_title : string
      ; before : string
      ; after : string
      }
  | Merge_backward of
      { uuid : string
      ; expected_title : string
      ; title : string
      ; previous_uuid : string
      ; expected_previous_title : string
      }
  | Move_blocks of Ops.move list
  | Request_delete_confirmation of string list
  | Delete_blocks of string list
  | Cycle_task_status of string
  | Set_task_status_value of
      { uuid : string
      ; status : Ops.semantic_value
      }
  | Pick_attachment of string
  | Take_photo of string
  | Copy_text of string
  | Copy_references of string list
  | Copy_urls of string list

type context =
  { blocks : Model.block list
  ; pages : autocomplete_candidate list
  ; tags : autocomplete_candidate list
  }

let empty =
  { editing = None
  ; selected = String_set.empty
  ; autocomplete = None
  ; collapsed = String_set.empty
  ; zoomed = []
  }
let editing_uuid state = Option.map (fun editing -> editing.uuid) state.editing
let editing_title state = Option.map (fun editing -> editing.title) state.editing
let selected_uuids state = String_set.elements state.selected
let autocomplete state = state.autocomplete
let zoom_path state = state.zoomed

let find_block context uuid =
  List.find_opt (fun (block : Model.block) -> String.equal block.uuid uuid) context.blocks
;;

let utf8_sequence_length byte =
  if byte land 0x80 = 0 then 1
  else if byte land 0xE0 = 0xC0 then 2
  else if byte land 0xF0 = 0xE0 then 3
  else if byte land 0xF8 = 0xF0 then 4
  else 1
;;

let utf16_units byte = if utf8_sequence_length byte = 4 then 2 else 1

let byte_index_of_utf16 value offset =
  let target = max 0 offset in
  let rec loop byte_index units =
    if byte_index >= String.length value || units >= target
    then byte_index
    else
      let byte = Char.code value.[byte_index] in
      loop
        (min (String.length value) (byte_index + utf8_sequence_length byte))
        (units + utf16_units byte)
  in
  loop 0 0
;;

let utf16_length value =
  let rec loop byte_index units =
    if byte_index >= String.length value
    then units
    else
      let byte = Char.code value.[byte_index] in
      loop
        (min (String.length value) (byte_index + utf8_sequence_length byte))
        (units + utf16_units byte)
  in
  loop 0 0
;;

let prefix_at value caret = String.sub value 0 (byte_index_of_utf16 value caret)

let last_substring value needle =
  let needle_length = String.length needle in
  let rec loop index found =
    if index + needle_length > String.length value
    then found
    else
      let found =
        if String.equal (String.sub value index needle_length) needle then Some index else found
      in
      loop (index + 1) found
  in
  if needle_length = 0 then None else loop 0 None
;;

let includes_case_insensitive value query =
  let value = String.lowercase_ascii value in
  let query = String.lowercase_ascii (String.trim query) in
  String.equal query "" || Option.is_some (last_substring value query)
;;

let autocomplete_candidates context request =
  let raw =
    match request.kind with
    | Node ->
      context.pages
      @ List.map
          (fun (block : Model.block) -> { label = block.title; value = block.uuid })
          context.blocks
    | Tag -> context.tags
    | Property ->
      List.map (fun value -> { label = value; value }) [ "status"; "tags"; "alias"; "priority" ]
  in
  let seen = Hashtbl.create (List.length raw) in
  raw
  |> List.filter (fun candidate ->
    includes_case_insensitive candidate.label request.query
    && if Hashtbl.mem seen candidate.value then false else (Hashtbl.add seen candidate.value (); true))
  |> List.to_seq |> Seq.take 12 |> List.of_seq
;;

let contains_from value start needle =
  Option.is_some (last_substring (String.sub value start (String.length value - start)) needle)
;;

let token_request kind marker prefix =
  match String.rindex_opt prefix marker with
  | None -> None
  | Some index ->
    let valid_start = index = 0 || Char.equal prefix.[index - 1] ' ' || Char.equal prefix.[index - 1] '\n' in
    let query = String.sub prefix (index + 1) (String.length prefix - index - 1) in
    if valid_start && not (String.exists (fun character -> character = ' ' || character = '\n') query)
    then Some { kind; query }
    else None
;;

let autocomplete_for title caret =
  let prefix = prefix_at title caret in
  match last_substring prefix "[[" with
  | Some index when not (contains_from prefix (index + 2) "]]" ) ->
    Some { kind = Node; query = String.sub prefix (index + 2) (String.length prefix - index - 2) }
  | _ ->
    (match last_substring prefix "::" with
     | Some index ->
       let line_start = option_value_map (String.rindex_from_opt prefix index '\n') ~default:0 ~f:(fun i -> i + 1) in
       Some { kind = Property; query = String.sub prefix line_start (index - line_start) }
     | None -> token_request Tag '#' prefix)
;;

let replace_range value start finish replacement =
  String.sub value 0 start
  ^ replacement
  ^ String.sub value finish (String.length value - finish)
;;

let complete editing kind value =
  let caret_byte = byte_index_of_utf16 editing.title editing.caret in
  let prefix = String.sub editing.title 0 caret_byte in
  let completion =
    match kind with
    | Node -> Option.map (fun index -> index, "[[" ^ value ^ "]]" ) (last_substring prefix "[[")
    | Tag -> Option.map (fun index -> index, "#[[" ^ value ^ "]]" ) (String.rindex_opt prefix '#')
    | Property ->
      let start = option_value_map (String.rindex_opt prefix '\n') ~default:0 ~f:(fun index -> index + 1) in
      Some (start, value ^ ":: ")
  in
  Option.map
    (fun (start, replacement) ->
      let title = replace_range editing.title start caret_byte replacement in
      let completed_prefix = String.sub title 0 (start + String.length replacement) in
      { editing with title; caret = utf16_length completed_prefix })
    completion
;;

let commit_effect = function
  | Some editing when not (String.equal editing.title editing.expected_title) ->
    [ Commit_title
        { uuid = editing.uuid
        ; expected_title = editing.expected_title
        ; title = editing.title
        }
    ]
  | _ -> []
;;

let insert_at_caret editing text ~backward_utf16 =
  let index = byte_index_of_utf16 editing.title editing.caret in
  let prefix = String.sub editing.title 0 index in
  let suffix = String.sub editing.title index (String.length editing.title - index) in
  let separator =
    if String.equal prefix "" || prefix.[String.length prefix - 1] = ' ' then "" else " "
  in
  let inserted = separator ^ text in
  let title = prefix ^ inserted ^ suffix in
  let caret = utf16_length (prefix ^ inserted) - backward_utf16 in
  { editing with title; caret }
;;

let compare_blocks (left : Model.block) (right : Model.block) =
  match left.order, right.order with
  | Some left, Some right when not (String.equal left right) -> String.compare left right
  | Some _, None -> -1
  | None, Some _ -> 1
  | _ ->
    let created = compare left.created_at right.created_at in
    if created <> 0 then created else String.compare left.uuid right.uuid
;;

let sorted_siblings context parent_id =
  context.blocks
  |> List.filter (fun (block : Model.block) -> block.parent_id = parent_id)
  |> List.sort compare_blocks
;;

type visible_row =
  { block : Model.block
  ; depth : int
  ; has_children : bool
  ; is_collapsed : bool
  }

let visible_rows context state =
  let block_ids =
    List.fold_left
      (fun ids (block : Model.block) -> String_set.add block.uuid ids)
      String_set.empty
      context.blocks
  in
  let children_by_parent = Hashtbl.create (List.length context.blocks) in
  List.iter
    (fun (block : Model.block) ->
      let siblings = Option.value (Hashtbl.find_opt children_by_parent block.parent_id) ~default:[] in
      Hashtbl.replace children_by_parent block.parent_id (block :: siblings))
    context.blocks;
  Hashtbl.iter
    (fun parent siblings -> Hashtbl.replace children_by_parent parent (List.sort compare_blocks siblings))
    children_by_parent;
  let children uuid =
    Option.value (Hashtbl.find_opt children_by_parent (Some uuid)) ~default:[]
  in
  let roots =
    context.blocks
    |> List.filter (fun (block : Model.block) ->
      match block.parent_id with
      | Some parent -> not (String_set.mem parent block_ids)
      | None -> true)
    |> List.sort compare_blocks
  in
  let visited = ref String_set.empty in
  let rec hide_descendants uuid =
    List.iter
      (fun (block : Model.block) ->
        if not (String_set.mem block.uuid !visited)
        then (
          visited := String_set.add block.uuid !visited;
          hide_descendants block.uuid))
      (children uuid)
  in
  let rec append depth rows (block : Model.block) =
    if String_set.mem block.uuid !visited
    then rows
    else (
      visited := String_set.add block.uuid !visited;
      let descendants = children block.uuid in
      let is_collapsed = String_set.mem block.uuid state.collapsed in
      let rows =
        { block; depth; has_children = descendants <> []; is_collapsed } :: rows
      in
      if is_collapsed
      then (hide_descendants block.uuid; rows)
      else List.fold_left (append (depth + 1)) rows descendants)
  in
  let rows =
    match Option.bind (list_last state.zoomed) (find_block context) with
    | Some root -> append 0 [] root
    | None -> List.fold_left (append 0) [] roots
  in
  let rows =
    match state.zoomed with
    | _ :: _ -> rows
    | [] -> List.fold_left (append 0) rows context.blocks
  in
  List.rev rows
;;

let selected_roots context selected =
  let by_uuid = Hashtbl.create (List.length context.blocks) in
  List.iter (fun (block : Model.block) -> Hashtbl.replace by_uuid block.uuid block) context.blocks;
  let has_selected_ancestor block =
    let rec loop visited = function
      | None -> false
      | Some uuid when String_set.mem uuid visited -> false
      | Some uuid when String_set.mem uuid selected -> true
      | Some uuid ->
        let visited = String_set.add uuid visited in
        loop visited (Option.bind (Hashtbl.find_opt by_uuid uuid) (fun block -> block.Model.parent_id))
    in
    loop String_set.empty block.Model.parent_id
  in
  context.blocks
  |> List.filter (fun (block : Model.block) ->
    String_set.mem block.uuid selected && not (has_selected_ancestor block))
;;

let moves_with_orders roots ~parent_uuid lower upper =
  match Order.n_between lower upper (List.length roots) with
  | Error _ -> None
  | Ok orders ->
    Some
      (List.map2
         (fun (block : Model.block) order ->
           Ops.{ uuid = block.uuid; page_uuid = block.page_id; parent_uuid; order })
         roots
         orders)
;;

let indent context selected =
  match selected_roots context selected with
  | [] -> None
  | first :: _ as roots ->
    if not (List.for_all (fun (block : Model.block) -> block.parent_id = first.Model.parent_id) roots)
    then None
    else
      let siblings = sorted_siblings context first.parent_id in
      let root_ids = List.map (fun (block : Model.block) -> block.uuid) roots in
      let indices =
        siblings
        |> List.mapi (fun index (block : Model.block) -> index, block.uuid)
        |> List.filter_map (fun (index, uuid) -> if List.mem uuid root_ids then Some index else None)
      in
      let first_index = List.hd indices in
      if first_index = 0
      then None
      else
         let contiguous =
           List.mapi (fun offset index -> index = first_index + offset) indices |> List.for_all Fun.id
         in
         if not contiguous
         then None
         else
           let parent = List.nth siblings (first_index - 1) in
           let children = sorted_siblings context (Some parent.uuid) in
           moves_with_orders roots ~parent_uuid:parent.uuid (Option.bind (list_last children) (fun block -> block.Model.order)) None
;;

let index_of_uuid uuid blocks =
  let rec loop index = function
    | [] -> None
    | (block : Model.block) :: _ when String.equal block.uuid uuid -> Some index
    | _ :: rest -> loop (index + 1) rest
  in
  loop 0 blocks
;;

let selection_is_contiguous roots siblings =
  let root_ids = List.map (fun (block : Model.block) -> block.uuid) roots in
  let indices =
    siblings
    |> List.mapi (fun index (block : Model.block) -> index, block.uuid)
    |> List.filter_map (fun (index, uuid) -> if List.mem uuid root_ids then Some index else None)
  in
  match indices with
  | [] -> false
  | first :: _ ->
    List.length indices = List.length roots
    && (List.mapi (fun offset index -> index = first + offset) indices |> List.for_all Fun.id)
;;

let outdent context selected =
  match selected_roots context selected with
  | [] -> None
  | first :: _ as roots ->
    if not (List.for_all (fun (block : Model.block) -> block.parent_id = first.Model.parent_id) roots)
    then None
    else
      (match Option.bind first.parent_id (find_block context) with
       | None -> None
       | Some parent ->
         let inner_siblings = sorted_siblings context (Some parent.uuid) in
         if not (selection_is_contiguous roots inner_siblings)
         then None
         else
           let parent_uuid = Option.value parent.parent_id ~default:parent.page_id in
           let outer_siblings = sorted_siblings context (Some parent_uuid) in
           (match index_of_uuid parent.uuid outer_siblings with
            | None -> None
            | Some parent_index ->
              let upper =
                if parent_index + 1 < List.length outer_siblings
                then (List.nth outer_siblings (parent_index + 1)).Model.order
                else None
              in
              moves_with_orders roots ~parent_uuid parent.order upper))
;;

let ancestor_uuids context block =
  let rec loop visited result = function
    | None -> result
    | Some uuid when String_set.mem uuid visited -> result
    | Some uuid ->
      let visited = String_set.add uuid visited in
      let parent = Option.bind (find_block context uuid) (fun block -> block.Model.parent_id) in
      loop visited (String_set.add uuid result) parent
  in
  loop String_set.empty String_set.empty block.Model.parent_id
;;

let drop context selected target_uuid placement =
  let roots = selected_roots context selected in
  match roots, find_block context target_uuid with
  | [], _ | _, None -> None
  | roots, Some target ->
    let root_ids = List.fold_left (fun set block -> String_set.add block.Model.uuid set) String_set.empty roots in
    if String_set.mem target_uuid root_ids
       || not (String_set.is_empty (String_set.inter root_ids (ancestor_uuids context target)))
    then None
    else
      let moving_ids = root_ids in
      let position =
        match placement with
        | Inside ->
          let children = sorted_siblings context (Some target.uuid) in
          Some
            ( target.uuid
            , Option.bind (list_last children) (fun block -> block.Model.order)
            , None )
        | Before | After ->
          let parent_uuid = Option.value target.parent_id ~default:target.page_id in
          let siblings =
            sorted_siblings context (Some parent_uuid)
            |> List.filter (fun block -> not (String_set.mem block.Model.uuid moving_ids))
          in
          (match index_of_uuid target.uuid siblings with
           | None -> None
           | Some index ->
             if placement = Before
             then
               Some
                 ( parent_uuid
                 , (if index = 0 then None else (List.nth siblings (index - 1)).Model.order)
                 , target.order )
             else
               Some
                 ( parent_uuid
                 , target.order
                 , (if index + 1 < List.length siblings
                    then (List.nth siblings (index + 1)).Model.order
                    else None) ))
      in
      Option.bind position (fun (parent_uuid, lower, upper) ->
        moves_with_orders roots ~parent_uuid lower upper)
;;

let update context state message =
  let rec existing_zoom_prefix acc = function
    | uuid :: rest when Option.is_some (find_block context uuid) ->
      existing_zoom_prefix (uuid :: acc) rest
    | _ -> List.rev acc
  in
  let state = { state with zoomed = existing_zoom_prefix [] state.zoomed } in
  let leave_interaction state =
    ( { state with
        editing = None
      ; selected = String_set.empty
      ; autocomplete = None
      }
    , commit_effect state.editing )
  in
  let split_editing editing =
    let index = byte_index_of_utf16 editing.title editing.caret in
    let before = String.sub editing.title 0 index in
    let after = String.sub editing.title index (String.length editing.title - index) in
    { state with editing = None; autocomplete = None },
    [ Split_at
        { uuid = editing.uuid
        ; expected_title = editing.expected_title
        ; before
        ; after
        }
    ]
  in
  let merge_backward editing =
    let rows = visible_rows context state in
    let rec previous candidate = function
      | [] -> None
      | row :: _ when String.equal row.block.Model.uuid editing.uuid -> candidate
      | row :: rest -> previous (Some row.block) rest
    in
    match previous None rows with
    | None -> state, []
    | Some block ->
      ( state
      , [ Merge_backward
            { uuid = editing.uuid
            ; expected_title = editing.expected_title
            ; title = editing.title
            ; previous_uuid = block.uuid
            ; expected_previous_title = block.title
            }
        ] )
  in
  match message with
  | Tap_block uuid when not (String_set.is_empty state.selected) ->
    let selected =
      if String_set.mem uuid state.selected
      then String_set.remove uuid state.selected
      else String_set.add uuid state.selected
    in
    { state with selected }, []
  | Tap_block uuid ->
    (match find_block context uuid with
     | None -> state, []
     | Some block ->
       let effects = commit_effect state.editing in
       ( { state with
           editing = Some { uuid; expected_title = block.title; title = block.title; caret = utf16_length block.title }
         ; selected = String_set.empty
         ; autocomplete = None
         }
       , effects ))
  | Long_press_block uuid ->
    ( { state with editing = None
      ; selected = String_set.singleton uuid
      ; autocomplete = None
      }
    , commit_effect state.editing @ [ Haptic Selection ] )
  | Text_changed { title; caret } ->
    (match state.editing with
     | None -> state, []
     | Some editing ->
       { state with editing = Some { editing with title; caret }; autocomplete = autocomplete_for title caret }, [])
  | Caret_moved caret ->
    (match state.editing with
     | None -> state, []
     | Some editing ->
       { state with editing = Some { editing with caret }; autocomplete = autocomplete_for editing.title caret }, [])
  | Choose_autocomplete value ->
    (match state.editing, state.autocomplete with
     | Some editing, Some autocomplete ->
       (match complete editing autocomplete.kind value with
        | Some editing ->
          { state with editing = Some editing; autocomplete = None }, [ Haptic Selection ]
        | None -> state, [])
     | _ -> state, [])
  | Return_pressed ->
    (match state.editing with
     | None -> state, []
     | Some editing -> split_editing editing)
  | Return_pressed_with_text { title; caret } ->
    (match state.editing with
     | None -> state, []
     | Some editing -> split_editing { editing with title; caret })
  | Backspace_pressed { selection_length = 0 } ->
    (match state.editing with
     | Some editing when editing.caret = 0 -> merge_backward editing
     | _ -> state, [])
  | Backspace_pressed _ -> state, []
  | Backspace_pressed_with_text { title; selection_length = 0 } ->
    (match state.editing with
     | Some editing -> merge_backward { editing with title; caret = 0 }
     | None -> state, [])
  | Backspace_pressed_with_text _ -> state, []
  | Toolbar Indent ->
    let targets =
      if String_set.is_empty state.selected
      then Option.fold ~none:String_set.empty ~some:(fun editing -> String_set.singleton editing.uuid) state.editing
      else state.selected
    in
    (match indent context targets with
     | Some moves -> state, [ Move_blocks moves; Haptic Impact ]
     | None -> state, [ Haptic Impact ])
  | Toolbar Delete -> state, [ Request_delete_confirmation (selected_uuids state); Haptic Impact ]
  | Confirm_delete ->
    let uuids = selected_uuids state in
    if uuids = [] then state, [] else { state with selected = String_set.empty }, [ Delete_blocks uuids ]
  | Toolbar Unselect -> { state with selected = String_set.empty }, [ Haptic Impact ]
  | Toolbar Task ->
    (match state.editing with Some editing -> state, [ Cycle_task_status editing.uuid; Haptic Impact ] | None -> state, [])
  | Toolbar Hide_keyboard ->
    { state with editing = None; autocomplete = None }, commit_effect state.editing @ [ Haptic Impact ]
  | Cancel_editing ->
    { state with editing = None; autocomplete = None }, commit_effect state.editing
  | Toolbar Tag_action ->
    (match state.editing with
     | None -> state, []
     | Some editing ->
       let editing = insert_at_caret editing "#" ~backward_utf16:0 in
       { state with editing = Some editing; autocomplete = autocomplete_for editing.title editing.caret }, [ Haptic Impact ])
  | Toolbar Page_reference ->
    (match state.editing with
     | None -> state, []
     | Some editing ->
       let editing = insert_at_caret editing "[[]]" ~backward_utf16:2 in
       { state with editing = Some editing; autocomplete = autocomplete_for editing.title editing.caret }, [ Haptic Impact ])
  | Toolbar Camera ->
    (match state.editing with Some editing -> state, [ Take_photo editing.uuid; Haptic Impact ] | None -> state, [])
  | Toolbar Attachment ->
    (match state.editing with Some editing -> state, [ Pick_attachment editing.uuid; Haptic Impact ] | None -> state, [])
  | Toolbar Copy ->
    let titles =
      context.blocks
      |> List.filter (fun (block : Model.block) -> String_set.mem block.uuid state.selected)
      |> List.map (fun block -> block.Model.title)
    in
    state, [ Copy_text (String.concat "\n" titles); Haptic Impact ]
  | Toolbar Copy_reference -> state, [ Copy_references (selected_uuids state); Haptic Impact ]
  | Toolbar Copy_url -> state, [ Copy_urls (selected_uuids state); Haptic Impact ]
  | Toolbar Outdent ->
    let targets =
      if String_set.is_empty state.selected
      then Option.fold ~none:String_set.empty ~some:(fun editing -> String_set.singleton editing.uuid) state.editing
      else state.selected
    in
    (match outdent context targets with
     | Some moves -> state, [ Move_blocks moves; Haptic Impact ]
     | None -> state, [ Haptic Impact ])
  | Drop_blocks { target_uuid; placement } ->
    (match drop context state.selected target_uuid placement with
     | Some moves -> { state with selected = String_set.empty }, [ Move_blocks moves; Haptic Impact ]
     | None -> state, [])
  | Set_task_status { uuid; status } ->
    state, [ Set_task_status_value { uuid; status }; Haptic Impact ]
  | Toggle_collapsed uuid ->
    let collapsed =
      if String_set.mem uuid state.collapsed
      then String_set.remove uuid state.collapsed
      else String_set.add uuid state.collapsed
    in
    { state with collapsed }, [ Haptic Impact ]
  | Zoom_in uuid ->
    (match find_block context uuid with
     | None -> state, []
     | Some _ ->
       let state, effects = leave_interaction state in
       let zoomed =
         match list_last state.zoomed with
         | Some current when String.equal current uuid -> state.zoomed
         | _ -> state.zoomed @ [ uuid ]
       in
       { state with zoomed }, effects @ [ Haptic Selection ])
  | Zoom_out ->
    let state, effects = leave_interaction state in
    let zoomed = match List.rev state.zoomed with _ :: rest -> List.rev rest | [] -> [] in
    { state with zoomed }, effects @ [ Haptic Selection ]
  | Operation_staged (Ops.Split_block { new_uuid; after; _ }) ->
    let title = Option.fold ~none:after ~some:(fun block -> block.Model.title) (find_block context new_uuid) in
    ( { state with editing =
          Some
            { uuid = new_uuid
            ; expected_title = title
            ; title
            ; caret = 0
            }
      ; selected = String_set.empty
      ; autocomplete = None
      }
    , [] )
  | Operation_staged (Ops.Merge_backward { previous_uuid; _ }) ->
    (match find_block context previous_uuid with
     | None -> state, []
     | Some block ->
       ( { state with editing =
             Some
               { uuid = previous_uuid
               ; expected_title = block.title
               ; title = block.title
               ; caret = utf16_length block.title
               }
         ; selected = String_set.empty
         ; autocomplete = None
         }
       , [] ))
  | Operation_staged _ -> state, []
;;
