module State = Logseq_chat_outliner_state
module Model = Logseq_chat_model

let fail label = failwith label
let assert_bool label value = if not value then fail label

let block
      ?(page_id = "page")
      ?(parent_id = Some "page")
      ?(order = Some "a0")
      ?(journal = None)
      uuid
      title
  =
  Model.
    { uuid
    ; title
    ; page_id
    ; parent_id
    ; order
    ; created_at = 0
    ; updated_at = 0
    ; sync_status = "synced"
    ; tags = []
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

let () =
  let blocks =
    [ block
        ~page_id:"older-page"
        ~parent_id:(Some "older-page")
        ~order:(Some "a0")
        ~journal:(Some ("Older", 20260827))
        "older-first"
        "Older first"
    ; block
        ~page_id:"newer-page"
        ~parent_id:(Some "newer-page")
        ~order:(Some "a1")
        ~journal:(Some ("Newer", 20260828))
        "newer-second"
        "Newer second"
    ; block
        ~page_id:"older-page"
        ~parent_id:(Some "older-page")
        ~order:(Some "a1")
        ~journal:(Some ("Older", 20260827))
        "older-second"
        "Older second"
    ; block
        ~page_id:"newer-page"
        ~parent_id:(Some "newer-page")
        ~order:(Some "a0")
        ~journal:(Some ("Newer", 20260828))
        "newer-first"
        "Newer first"
    ]
  in
  let uuids =
    State.visible_rows State.{ blocks; pages = []; tags = [] } State.empty
    |> List.map (fun row -> row.State.block.uuid)
  in
  assert_bool
    "journal roots stay grouped newest-first in outliner order"
    (uuids = [ "newer-first"; "newer-second"; "older-first"; "older-second" ])
;;

let context = State.{ blocks = [ block "a" "Alpha"; block ~order:(Some "a1") "b" "Beta" ]; pages = []; tags = [] }

let () =
  let state, effects = State.update context State.empty (Tap_block "a") in
  assert_bool "tap starts inline editing" (State.editing_uuid state = Some "a");
  assert_bool "tap has no effect" (effects = []);
  let state, effects = State.update context state (Text_changed { title = "A [[Pro"; caret = 7 }) in
  assert_bool "text change remains pure" (effects = []);
  assert_bool "node autocomplete is derived in the reducer"
    (match State.autocomplete state with
     | Some { kind = Node; query = "Pro" } -> true
     | _ -> false);
  let state, effects = State.update context state (Choose_autocomplete "Project") in
  assert_bool "autocomplete completion updates editor text"
    (State.editing_title state = Some "A [[Project]]");
  assert_bool "autocomplete completion requests selection feedback"
    (effects = [ State.Haptic Selection ])
;;

let () =
  let tag_uuid = "tag-uuid" in
  let context =
    State.
      { blocks = [ block "a" "Alpha" ]
      ; pages = []
      ; tags = [ { label = "Project"; value = tag_uuid } ]
      }
  in
  let state, _ = State.update context State.empty (Tap_block "a") in
  let state, _ =
    State.update context state (Text_changed { title = "Alpha #Pro"; caret = 10 })
  in
  assert_bool "inline tag autocomplete is recognized"
    (match State.autocomplete state with
     | Some { kind = Tag; query = "Pro" } -> true
     | _ -> false);
  let state, effects = State.update context state (Choose_autocomplete tag_uuid) in
  assert_bool "tag completion removes the inline token from the editor"
    (State.editing_title state = Some "Alpha");
  assert_bool "tag completion keeps editing active and emits a semantic tag command"
    (State.editing_uuid state = Some "a" && List.length effects = 2)
;;

let () =
  let tag_uuid = "tag-uuid" in
  let context =
    State.
      { blocks = [ block "a" "Alpha" ]
      ; pages = []
      ; tags = [ { label = "favorite book"; value = tag_uuid } ]
      }
  in
  let state, _ = State.update context State.empty (Tap_block "a") in
  let state, _ = State.update context state (Text_changed { title = "Alpha #fav"; caret = 10 }) in
  let state, _ = State.update context state (Choose_autocomplete tag_uuid) in
  assert_bool "spaced tag completion also removes the inline token"
    (State.editing_title state = Some "Alpha")
;;

let () =
  let summary uuid title = Model.{ uuid; title } in
  let stored =
    { (block "a" "Ship [[page-uuid-1]] with #[[tag-uuid-1]] and #[[tag-uuid-2]]") with
      Model.references = [ summary "page-uuid-1" "Roadmap" ]
    ; tags = [ summary "tag-uuid-1" "Project"; summary "tag-uuid-2" "favorite book" ]
    }
  in
  let context = State.{ blocks = [ stored ]; pages = []; tags = [] } in
  let state, _ = State.update context State.empty (Tap_block "a") in
  assert_bool "editing shows names instead of stored uuid references"
    (State.editing_title state = Some "Ship [[Roadmap]] with #Project and #[[favorite book]]");
  let _, effects = State.update context state Cancel_editing in
  assert_bool "leaving an untouched display title does not emit a commit" (effects = [])
;;

let () =
  let summary uuid title = Model.{ uuid; title } in
  let stored =
    { (block "a" "See [[page-uuid-1]] or [[page-uuid-2]]") with
      Model.references = [ summary "page-uuid-1" "Roadmap"; summary "page-uuid-2" "roadmap" ]
    }
  in
  let context = State.{ blocks = [ stored ]; pages = []; tags = [] } in
  let state, _ = State.update context State.empty (Tap_block "a") in
  assert_bool "duplicated reference names stay uuid-addressed in the editor"
    (State.editing_title state = Some "See [[page-uuid-1]] or [[page-uuid-2]]")
;;

let () =
  let context =
    State.
      { blocks = [ block "alpha" "Alpha block"; block ~order:(Some "a1") "beta" "Beta" ]
      ; pages = [ { label = "Project Alpha"; value = "Project Alpha" } ]
      ; tags = []
      }
  in
  let node_candidates =
    State.autocomplete_candidates context State.{ kind = Node; query = "alpha" }
  in
  assert_bool "node autocomplete combines pages and blocks in OCaml"
    (node_candidates
     = [ State.{ label = "Project Alpha"; value = "Project Alpha" }
       ; State.{ label = "Alpha block"; value = "alpha" }
       ])
;;

let () =
  let blocks =
    [ block "parent" "Parent"
    ; block ~parent_id:(Some "parent") "child" "Child"
    ; block ~order:(Some "a1") "sibling" "Sibling"
    ]
  in
  let context = State.{ blocks; pages = []; tags = [] } in
  let state, effects = State.update context State.empty (Toggle_collapsed "parent") in
  assert_bool "collapse emits only a platform haptic" (effects = [ State.Haptic Impact ]);
  assert_bool "collapsed child is absent from visible rows"
    (State.visible_rows context state |> List.map (fun row -> row.State.block.uuid)
     = [ "parent"; "sibling" ]);
  let state, effects = State.update context state (Zoom_in "parent") in
  assert_bool "zoom emits only a platform haptic" (effects = [ State.Haptic Selection ]);
  assert_bool "zoom owns the visible subtree"
    (match State.visible_rows context state with
     | [ { State.block = { uuid = "parent"; _ }; depth = 0; _ } ] -> true
     | _ -> false);
  let state, _ = State.update context state Zoom_out in
  assert_bool "zoom out restores the full outline"
    (State.visible_rows context state |> List.map (fun row -> row.State.block.uuid)
     = [ "parent"; "sibling" ])
;;

let () =
  let blocks =
    [ block "parent" "Parent"
    ; block ~parent_id:(Some "parent") "child" "Child"
    ]
  in
  let context = State.{ blocks; pages = []; tags = [] } in
  let editing, _ = State.update context State.empty (Tap_block "parent") in
  let editing, _ =
    State.update context editing (Text_changed { title = "Changed"; caret = 7 })
  in
  let navigated, effects = State.update context editing (Zoom_in "child") in
  assert_bool "page navigation exits editing and selection"
    (State.editing_uuid navigated = None && State.selected_uuids navigated = []);
  assert_bool "page navigation commits the editor before navigating"
    (effects
     = [ State.Commit_title
           { uuid = "parent"; expected_title = "Parent"; title = "Changed" }
       ; State.Haptic State.Selection
       ]);
  let selected, _ = State.update context State.empty (Long_press_block "parent") in
  let selected, _ = State.update context selected (Zoom_in "parent") in
  assert_bool "page navigation exits selection" (State.selected_uuids selected = []);
  let zoomed, _ = State.update context State.empty (Zoom_in "parent") in
  let editing, _ = State.update context zoomed (Tap_block "child") in
  let editing, _ =
    State.update context editing (Text_changed { title = "Edited child"; caret = 12 })
  in
  let backed, effects = State.update context editing Zoom_out in
  assert_bool "back exits editing and returns to the previous page"
    (State.editing_uuid backed = None && State.zoom_path backed = []);
  assert_bool "back commits the editor before navigating"
    (effects
     = [ State.Commit_title
           { uuid = "child"; expected_title = "Child"; title = "Edited child" }
       ; State.Haptic State.Selection
       ]);
  let selected, _ = State.update context zoomed (Long_press_block "child") in
  let backed, _ = State.update context selected Zoom_out in
  assert_bool "back exits selection" (State.selected_uuids backed = [])
;;

let () =
  let state, _ = State.update context State.empty (Long_press_block "a") in
  assert_bool "long press selects" (State.selected_uuids state = [ "a" ]);
  let state, _ = State.update context state (Tap_block "b") in
  assert_bool "tap toggles another selection" (State.selected_uuids state = [ "a"; "b" ]);
  let state, _ = State.update context state (Tap_block "a") in
  assert_bool "tap removes a selected block" (State.selected_uuids state = [ "b" ]);
  let state, _ = State.update context state (Long_press_block "a") in
  assert_bool "a new long press starts a fresh selection" (State.selected_uuids state = [ "a" ])
;;

let () =
  let state, _ = State.update context State.empty (Tap_block "a") in
  let unchanged, effects = State.update context state (Toolbar Task) in
  assert_bool "task toolbar keeps inline editing active" (unchanged = state);
  assert_bool "task toolbar cycles the editing block status"
    (effects = [ State.Cycle_task_status "a"; State.Haptic State.Impact ])
;;

let () =
  let state, _ = State.update context State.empty (Tap_block "a") in
  let state, _ = State.update context state (Text_changed { title = "Alpha Beta"; caret = 5 }) in
  let state, effects = State.update context state Return_pressed in
  assert_bool "return leaves editing" (State.editing_uuid state = None);
  assert_bool "return requests one split effect"
    (effects
     = [ State.Split_at
           { uuid = "a"
           ; expected_title = "Alpha"
           ; before = "Alpha"
           ; after = " Beta"
           }
       ])
;;

let () =
  let state, _ = State.update context State.empty (Tap_block "a") in
  let state, effects =
    State.update context state (Return_pressed_with_text { title = "Changed text"; caret = 7 })
  in
  assert_bool "atomic return leaves editing" (State.editing_uuid state = None);
  assert_bool "atomic return splits the final UIKit text without an intermediate render"
    (effects
     = [ State.Split_at
           { uuid = "a"
           ; expected_title = "Alpha"
           ; before = "Changed"
           ; after = " text"
           }
       ])
;;

let () =
  let unchanged_return, return_effects =
    State.update
      context
      State.empty
      (Return_pressed_with_text { title = "Draft"; caret = 5 })
  in
  let unchanged_backspace, backspace_effects =
    State.update
      context
      State.empty
      (Backspace_pressed_with_text { title = "Draft"; selection_length = 0 })
  in
  let state, _ = State.update context State.empty (Tap_block "a") in
  let selected_backspace, selected_effects =
    State.update
      context
      state
      (Backspace_pressed_with_text { title = "Draft"; selection_length = 1 })
  in
  assert_bool "atomic return without an editor is ignored"
    (unchanged_return = State.empty && return_effects = []);
  assert_bool "atomic backspace without an editor is ignored"
    (unchanged_backspace = State.empty && backspace_effects = []);
  assert_bool "atomic backspace with a selection stays inside UIKit"
    (selected_backspace = state && selected_effects = [])
;;

let () =
  let state, _ = State.update context State.empty (Tap_block "b") in
  let state, _ = State.update context state (Caret_moved 0) in
  let _, effects = State.update context state (Backspace_pressed { selection_length = 0 }) in
  assert_bool "backspace at start requests merge"
    (effects
     = [ State.Merge_backward
           { uuid = "b"
           ; expected_title = "Beta"
           ; title = "Beta"
           ; previous_uuid = "a"
           ; expected_previous_title = "Alpha"
           }
       ])
;;

let () =
  let blocks =
    [ block "journal-one" "First journal block"
    ; block
        ~page_id:"journal-two"
        ~parent_id:(Some "journal-two")
        ~order:(Some "a1")
        "journal-two-block"
        "Second journal block"
    ; block
        ~page_id:"journal-two"
        ~parent_id:(Some "journal-two")
        ~order:(Some "a2")
        "journal-two-next"
        "Next journal block"
    ]
  in
  let context = State.{ blocks; pages = []; tags = [] } in
  let state, _ =
    State.update context State.empty (Tap_block "journal-two-block")
  in
  let state, effects =
    State.update
      context
      state
      (Backspace_pressed_with_text
         { title = "Second journal block"; selection_length = 0 })
  in
  assert_bool
    "backspace deletes the first block of a journal without closing its editor"
    (State.editing_uuid state = Some "journal-two-next"
     && effects = [ State.Delete_blocks [ "journal-two-block" ] ])
;;

let () =
  let blocks =
    [ block "parent" "Parent"
    ; block ~parent_id:(Some "parent") ~order:(Some "a0") "child" "Child"
    ; block ~parent_id:(Some "parent") ~order:(Some "a1") "empty" ""
    ]
  in
  let nested_context = State.{ blocks; pages = []; tags = [] } in
  let state, _ = State.update nested_context State.empty (Tap_block "empty") in
  let state, effects =
    State.update nested_context state (Return_pressed_with_text { title = ""; caret = 0 })
  in
  assert_bool "return on the final empty child keeps that block focused"
    (State.editing_uuid state = Some "empty");
  assert_bool "return on the final empty child outdents instead of splitting"
    (match effects with
     | [ State.Move_blocks [ move ] ] ->
       String.equal move.Logseq_chat_pending_ops.uuid "empty"
       && String.equal move.parent_uuid "page"
     | _ -> false)
;;

let () =
  let blocks =
    [ block "parent" "Parent"
    ; block ~parent_id:(Some "parent") ~order:(Some "a0") "empty" ""
    ; block ~parent_id:(Some "parent") ~order:(Some "a1") "following" "Following"
    ]
  in
  let nested_context = State.{ blocks; pages = []; tags = [] } in
  let state, _ = State.update nested_context State.empty (Tap_block "empty") in
  let state, effects = State.update nested_context state Return_pressed in
  assert_bool "an empty child that is not last still follows normal split behavior"
    (State.editing_uuid state = None
     && match effects with [ State.Split_at _ ] -> true | _ -> false)
;;

let () =
  let state, _ = State.update context State.empty (Tap_block "b") in
  let _, effects =
    State.update context state
      (Backspace_pressed_with_text { title = "Changed"; selection_length = 0 })
  in
  assert_bool "atomic backspace merges the final UIKit text"
    (effects
     = [ State.Merge_backward
           { uuid = "b"
           ; expected_title = "Beta"
           ; title = "Changed"
           ; previous_uuid = "a"
           ; expected_previous_title = "Alpha"
           }
       ])
;;

let () =
  let blocks =
    [ block "first" "First"
    ; block ~order:(Some "a1") "second" "Second"
    ; block ~order:(Some "a2") "third" "Third"
    ]
  in
  let context = State.{ blocks; pages = []; tags = [] } in
  let state, _ = State.update context State.empty (Long_press_block "second") in
  let state, _ = State.update context state (Tap_block "third") in
  let state, effects = State.update context state (Toolbar Indent) in
  assert_bool "indent preserves selection for repeated structural commands"
    (State.selected_uuids state = [ "second"; "third" ]);
  assert_bool "indent emits one atomic move batch"
    (match effects with
     | [ State.Move_blocks moves; State.Haptic State.Impact ] ->
       List.map (fun move -> move.Logseq_chat_pending_ops.uuid) moves = [ "second"; "third" ]
       && List.for_all
            (fun move -> String.equal move.Logseq_chat_pending_ops.parent_uuid "first")
            moves
     | _ -> false)
;;

let () =
  let state, _ = State.update context State.empty (Long_press_block "a") in
  let state, effects = State.update context state (Toolbar Delete) in
  assert_bool "delete asks the UI for confirmation without mutating data"
    (effects = [ State.Request_delete_confirmation [ "a" ]; State.Haptic State.Impact ]);
  assert_bool "delete closes the selection immediately"
    (State.selected_uuids state = []);
  let state, effects = State.update context state Confirm_delete in
  assert_bool "confirmed delete becomes a domain effect"
    (effects = [ State.Delete_blocks [ "a" ] ]);
  let _, effects = State.update context state Confirm_delete in
  assert_bool "confirmation is consumed after the delete" (effects = [])
;;

let () =
  let blocks =
    [ block "parent" "Parent"
    ; block ~parent_id:(Some "parent") "child-a" "A"
    ; block ~parent_id:(Some "parent") ~order:(Some "a1") "child-b" "B"
    ; block ~order:(Some "a1") "next" "Next"
    ]
  in
  let context = State.{ blocks; pages = []; tags = [] } in
  let state, _ = State.update context State.empty (Long_press_block "child-a") in
  let state, _ = State.update context state (Tap_block "child-b") in
  let state, effects = State.update context state (Toolbar Outdent) in
  assert_bool "outdent preserves selection for repeated structural commands"
    (State.selected_uuids state = [ "child-a"; "child-b" ]);
  assert_bool "outdent inserts selection immediately after parent"
    (match effects with
     | [ State.Move_blocks [ first; second ]; State.Haptic State.Impact ] ->
       String.equal first.parent_uuid "page"
       && String.equal second.parent_uuid "page"
       && String.compare "a0" first.order < 0
       && String.compare first.order second.order < 0
       && String.compare second.order "a1" < 0
     | _ -> false)
;;

let () =
  let blocks =
    [ block "parent" "Parent"
    ; block ~parent_id:(Some "parent") "child" "Child"
    ; block ~order:(Some "a1") "target" "Target"
    ]
  in
  let context = State.{ blocks; pages = []; tags = [] } in
  let state, _ = State.update context State.empty (Long_press_block "parent") in
  let unchanged, effects =
    State.update context state (Drop_blocks { target_uuid = "child"; placement = After })
  in
  assert_bool "drop onto descendant is rejected" (unchanged = state && effects = []);
  let moved, effects =
    State.update context state (Drop_blocks { target_uuid = "target"; placement = Inside })
  in
  assert_bool "valid drop clears selection" (State.selected_uuids moved = []);
  assert_bool "valid drop emits one move batch"
    (match effects with
     | [ State.Move_blocks [ move ]; State.Haptic State.Impact ] ->
       String.equal move.uuid "parent" && String.equal move.parent_uuid "target"
     | _ -> false)
;;

let () =
  let state, _ = State.update context State.empty (Tap_block "b") in
  let state, effects = State.update context state (Toolbar Indent) in
  assert_bool "editor indent keeps the same block focused" (State.editing_uuid state = Some "b");
  assert_bool "editor indent moves the editing block"
    (match effects with
     | [ State.Move_blocks [ move ]; State.Haptic State.Impact ] ->
       String.equal move.Logseq_chat_pending_ops.uuid "b"
       && String.equal move.parent_uuid "a"
     | _ -> false)
;;

let () =
  let blocks =
    [ block "parent" "Parent"
    ; block ~parent_id:(Some "parent") "child" "Child"
    ; block ~order:(Some "a1") "next" "Next"
    ]
  in
  let child_context = State.{ blocks; pages = []; tags = [] } in
  let state, _ = State.update child_context State.empty (Tap_block "child") in
  let state, effects = State.update child_context state (Toolbar Outdent) in
  assert_bool "editor outdent keeps the same block focused"
    (State.editing_uuid state = Some "child");
  assert_bool "editor outdent moves the editing block"
    (match effects with
     | [ State.Move_blocks [ move ]; State.Haptic State.Impact ] ->
       String.equal move.Logseq_chat_pending_ops.uuid "child"
       && String.equal move.parent_uuid "page"
     | _ -> false)
;;

let () =
  let insert action expected_title expected_caret expected_autocomplete =
    let state, _ = State.update context State.empty (Tap_block "a") in
    let state, _ = State.update context state (Text_changed { title = "AlphaBeta"; caret = 5 }) in
    let state, effects = State.update context state (Toolbar action) in
    assert_bool "toolbar insertion keeps inline editing active"
      (State.editing_uuid state = Some "a");
    assert_bool "toolbar insertion edits at the caret"
      (State.editing_title state = Some expected_title);
    assert_bool "toolbar insertion moves the caret correctly"
      (Option.map (fun editing -> editing.State.caret) state.editing = Some expected_caret);
    assert_bool "toolbar insertion opens the matching autocomplete"
      (match State.autocomplete state, expected_autocomplete with
       | Some actual, Some expected -> actual.kind = expected
       | None, None -> true
       | _ -> false);
    assert_bool "toolbar insertion provides haptic feedback"
      (effects = [ State.Haptic State.Impact ])
  in
  insert Tag_action "Alpha #Beta" 7 (Some State.Tag);
  insert Page_reference "Alpha [[]]Beta" 8 (Some State.Node)
;;

let () =
  let state, _ = State.update context State.empty (Tap_block "a") in
  let assert_media action expected =
    let unchanged, effects = State.update context state (Toolbar action) in
    assert_bool "media toolbar action keeps inline editing active" (unchanged = state);
    assert_bool "media toolbar action targets the editing block"
      (effects = [ expected; State.Haptic State.Impact ])
  in
  assert_media Camera (State.Take_photo "a");
  assert_media Audio (State.Record_audio "a");
  assert_media Attachment (State.Pick_attachment "a")
;;

let () =
  let state, _ = State.update context State.empty (Tap_block "a") in
  let state, _ = State.update context state (Text_changed { title = "Changed"; caret = 7 }) in
  let state, effects = State.update context state (Toolbar Hide_keyboard) in
  assert_bool "keyboard toolbar action ends editing" (State.editing_uuid state = None);
  assert_bool "keyboard toolbar action commits the current draft"
    (effects =
       [ State.Commit_title { uuid = "a"; expected_title = "Alpha"; title = "Changed" }
       ; State.Haptic State.Impact
       ])
;;

let () =
  let state, _ = State.update context State.empty (Long_press_block "a") in
  let copied, copy = State.update context state (Toolbar Copy) in
  let referenced, copy_reference = State.update context state (Toolbar Copy_reference) in
  let linked, copy_url = State.update context state (Toolbar Copy_url) in
  assert_bool "selection copy command is complete"
    (copy = [ State.Copy_text "Alpha"; State.Haptic State.Impact ]);
  assert_bool "selection copy reference command is complete"
    (copy_reference = [ State.Copy_references [ "a" ]; State.Haptic State.Impact ]);
  assert_bool "selection copy URL command is complete"
    (copy_url = [ State.Copy_urls [ "a" ]; State.Haptic State.Impact ]);
  assert_bool "copy commands close the selection"
    (State.selected_uuids copied = []
     && State.selected_uuids referenced = []
     && State.selected_uuids linked = []);
  let state, effects = State.update context state (Toolbar Unselect) in
  assert_bool "unselect clears selection"
    (State.selected_uuids state = [] && effects = [ State.Haptic State.Impact ])
;;

let () =
  let blocks =
    [ block "parent" "Parent"
    ; block ~parent_id:(Some "parent") "child" "Child"
    ; block ~parent_id:(Some "child") "grandchild" "Grandchild"
    ; block ~order:(Some "a1") "sibling" "Sibling"
    ]
  in
  let nested_context = State.{ blocks; pages = []; tags = [] } in
  let state, _ = State.update nested_context State.empty (Zoom_in "parent") in
  let state, _ = State.update nested_context state (Zoom_in "child") in
  assert_bool "zoom is nested page navigation"
    (State.zoom_path state = [ "parent"; "child" ]);
  assert_bool "nested zoom shows the destination page tree"
    (State.visible_rows nested_context state
     |> List.map (fun row -> row.State.block.uuid)
     = [ "child"; "grandchild" ]);
  let state, _ = State.update nested_context state Zoom_out in
  assert_bool "zoom back returns to the previous page"
    (State.zoom_path state = [ "parent" ]);
  let state, _ = State.update nested_context state Zoom_out in
  assert_bool "zoom back from the first page returns to the journal"
    (State.zoom_path state = [])
;;

let () =
  let blocks =
    [ block "parent" "Parent"
    ; block ~parent_id:(Some "parent") "child" "Child"
    ]
  in
  let before_delete = State.{ blocks; pages = []; tags = [] } in
  let state, _ = State.update before_delete State.empty (Zoom_in "parent") in
  let state, _ = State.update before_delete state (Zoom_in "child") in
  let after_delete = State.{ blocks = []; pages = []; tags = [] } in
  let state, _ =
    State.update
      after_delete
      state
      (Operation_staged (Logseq_chat_pending_ops.Delete_blocks { uuids = [ "parent" ] }))
  in
  assert_bool "deleting the zoom destination returns to a valid page"
    (State.zoom_path state = [])
;;

let () =
  let count = 5_000 in
  let rec make_chain index previous acc =
    if index = count
    then List.rev acc
    else
      let uuid = "performance-" ^ string_of_int index in
      let parent_id = if index = 0 then Some "page" else previous in
      make_chain
        (index + 1)
        (Some uuid)
        (block ~parent_id uuid uuid :: acc)
  in
  let large_context = State.{ blocks = make_chain 0 None []; pages = []; tags = [] } in
  let started = Unix.gettimeofday () in
  let rows = State.visible_rows large_context State.empty in
  let elapsed = Unix.gettimeofday () -. started in
  assert_bool "large outlines remain linear enough for user-visible actions"
    (List.length rows = count && elapsed < 0.1)
;;

let () =
  assert_bool "option mapper covers present and absent values"
    (State.option_value_map (Some 2) ~default:0 ~f:(( + ) 1) = 3
     && State.option_value_map None ~default:0 ~f:(( + ) 1) = 0);
  assert_bool "list_last covers present and absent lists"
    (State.list_last [ 1; 2 ] = Some 2 && State.list_last [] = None);
  assert_bool "UTF-8 sequence lengths cover every encoded width"
    (State.utf8_sequence_length 0x41 = 1
     && State.utf8_sequence_length 0xC3 = 2
     && State.utf8_sequence_length 0xE4 = 3
     && State.utf8_sequence_length 0xF0 = 4
     && State.utf8_sequence_length 0x80 = 1);
  let unicode = "Aé中😀" in
  assert_bool "UTF-16 caret conversion handles BMP and supplementary characters"
    (State.utf16_length unicode = 5
     && State.byte_index_of_utf16 unicode 0 = 0
     && State.byte_index_of_utf16 unicode 2 = 3
     && State.byte_index_of_utf16 unicode 5 = String.length unicode
     && State.byte_index_of_utf16 unicode 99 = String.length unicode);
  assert_bool "empty substring is intentionally not searchable"
    (State.last_substring "value" "" = None);
  assert_bool "substring search returns the last occurrence"
    (State.last_substring "aba" "a" = Some 2);
  assert_bool "empty autocomplete query matches every candidate"
    (State.includes_case_insensitive "Value" "  ")
;;

let () =
  let candidates_context =
    State.
      { blocks = [ block "alpha" "Alpha" ]
      ; pages =
          [ { label = "Project"; value = "project" }
          ; { label = "Project duplicate"; value = "project" }
          ]
      ; tags =
          [ { label = "Project"; value = "project" }
          ; { label = "Project duplicate"; value = "project" }
          ]
      }
  in
  assert_bool "autocomplete candidates deduplicate by value"
    (State.autocomplete_candidates candidates_context State.{ kind = Node; query = "project" }
     = [ State.{ label = "Project"; value = "project" } ]);
  let context_with_blank_block =
    State.{ candidates_context with blocks = block "blank" "" :: candidates_context.blocks }
  in
  assert_bool "node autocomplete excludes blank blocks"
    (State.autocomplete_candidates context_with_blank_block State.{ kind = Node; query = "" }
     |> List.for_all (fun candidate -> not (String.equal candidate.State.label "")));
  assert_bool "tag candidates reuse page entities"
    (List.length
       (State.autocomplete_candidates candidates_context State.{ kind = Tag; query = "project" })
     = 1);
  assert_bool "an exact tag match offers no create candidate"
    (State.autocomplete_candidates candidates_context State.{ kind = Tag; query = "Project" }
     = [ State.{ label = "Project"; value = "project" } ]);
  assert_bool "a novel tag query offers a create candidate"
    (State.autocomplete_candidates candidates_context State.{ kind = Tag; query = "foobar" }
     = [ State.{ label = "New tag: foobar"; value = "foobar" } ]);
  assert_bool "an empty tag query offers no create candidate"
    (State.autocomplete_candidates
       State.{ blocks = []; pages = []; tags = [] }
       State.{ kind = Tag; query = "" }
     = []);
  assert_bool "property candidates are core-owned"
    (State.autocomplete_candidates candidates_context State.{ kind = Property; query = "prio" }
     = [ State.{ label = "priority"; value = "priority" } ]);
  let many_pages =
    List.init 20 (fun index -> State.{ label = string_of_int index; value = string_of_int index })
  in
  assert_bool "autocomplete result count is bounded"
    (List.length
       (State.autocomplete_candidates State.{ blocks = []; pages = many_pages; tags = [] }
          State.{ kind = Node; query = "" })
     = 12)
;;

let assert_autocomplete label expected title =
  assert_bool label (State.autocomplete_for title (State.utf16_length title) = expected)
;;

let () =
  assert_autocomplete "node autocomplete token"
    (Some State.{ kind = Node; query = "Al" }) "[[Al";
  assert_autocomplete "property autocomplete token"
    (Some State.{ kind = Property; query = "property" }) "property::";
  assert_autocomplete "tag autocomplete token"
    (Some State.{ kind = Tag; query = "tag" }) "#tag";
  assert_autocomplete "tag token after whitespace"
    (Some State.{ kind = Tag; query = "tag" }) "text #tag";
  assert_autocomplete "tag token after newline"
    (Some State.{ kind = Tag; query = "tag" }) "text\n#tag";
  assert_autocomplete
    "typing a tag marker immediately opens autocomplete"
    (Some State.{ kind = Tag; query = "tag" })
    "text#tag";
  assert_autocomplete
    "tag query supports spaces"
    (Some State.{ kind = Tag; query = "two words" })
    "#two words";
  assert_bool "tag token helper allows spaces but stops at a newline"
    (State.token_request State.Tag '#' "#two words"
     = Some State.{ kind = Tag; query = "two words" }
     && State.token_request State.Tag '#' "#two\nwords" = None);
  assert_autocomplete "closed node token is inactive" None "[[Page]]";
  assert_autocomplete "legacy block token is inactive" None "((Block";
  assert_autocomplete "slash command token is inactive" None "/query";
  assert_autocomplete "missing token is inactive" None "plain text"
;;

let editing title =
  State.{ uuid = "a"; expected_title = title; title; caret = utf16_length title }
;;

let completed_title kind title value =
  Option.map
    (fun editing -> editing.State.title)
    (State.complete context (editing title) kind value)
;;

let () =
  assert_bool "node completion replaces the open token"
    (completed_title State.Node "[[Pr" "Project" = Some "[[Project]]");
  assert_bool "tag completion with a brand-new plain name inserts a hashtag"
    (completed_title State.Tag "#ta" "tag" = Some "#tag");
  assert_bool "tag completion with an unknown uuid keeps the uuid form"
    (completed_title State.Tag "#ta" "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8"
     = Some "#[[018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8]]");
  assert_bool "tag completion with a brand-new spaced name uses the bracket form"
    (completed_title State.Tag "#ta" "two words" = Some "#[[two words]]");
  assert_bool "property completion replaces the current line"
    (completed_title State.Property "before\nsta::" "status" = Some "before\nstatus:: ");
  assert_bool "completion without its marker is ignored"
    (State.complete context (editing "plain") State.Node "Project" = None);
  assert_bool "unchanged title does not emit a commit"
    (State.commit_effect context (Some (editing "Alpha")) = []
     && State.commit_effect context None = []);
  let empty_editing : State.editing =
    { uuid = "a"; expected_title = ""; title = ""; caret = 0 }
  in
  assert_bool "insert at empty caret needs no separator"
    ((State.insert_at_caret empty_editing "#" ~backward_utf16:0).title = "#");
  let spaced = { empty_editing with title = "A "; expected_title = "A "; caret = 2 } in
  assert_bool "insert after whitespace needs no extra separator"
    ((State.insert_at_caret spaced "#" ~backward_utf16:0).title = "A #")
;;

let () =
  let unordered =
    [ block ~order:None "later" "Later"
    ; { (block ~order:None "earlier" "Earlier") with created_at = -1 }
    ; block ~order:(Some "a0") "ordered" "Ordered"
    ]
  in
  assert_bool "block ordering handles missing order and creation fallback"
    (List.sort State.compare_blocks unordered |> List.map (fun block -> block.Model.uuid)
     = [ "ordered"; "earlier"; "later" ]);
  let same_created = [ block ~order:None "b" "B"; block ~order:None "a" "A" ] in
  assert_bool "block ordering finally falls back to UUID"
    (List.sort State.compare_blocks same_created |> List.map (fun block -> block.Model.uuid)
     = [ "a"; "b" ])
;;

let () =
  let invalid_bounds_roots = [ block "root" "Root" ] in
  assert_bool "move order allocation reports invalid bounds without throwing"
    (State.moves_with_orders invalid_bounds_roots ~parent_uuid:"page"
       (Some "a1") (Some "a0")
     = None);
  assert_bool "empty structural selections are no-ops"
    (State.indent context State.String_set.empty = None
     && State.outdent context State.String_set.empty = None
     && State.drop context State.String_set.empty "a" State.After = None);
  assert_bool "drop rejects a missing target"
    (State.drop context (State.String_set.singleton "a") "missing" State.After = None)
;;

let () =
  let blocks =
    [ block "first" "First"
    ; block ~order:(Some "a1") "middle" "Middle"
    ; block ~order:(Some "a2") "last" "Last"
    ]
  in
  let drop_context = State.{ blocks; pages = []; tags = [] } in
  let selected = State.String_set.singleton "middle" in
  let before = State.drop drop_context selected "first" State.Before in
  let after = State.drop drop_context selected "last" State.After in
  assert_bool "drop before first creates an order below the target"
    (match before with
     | Some [ move ] -> String.compare move.Logseq_chat_pending_ops.order "a0" < 0
     | _ -> false);
  assert_bool "drop after last creates an order above the target"
    (match after with
     | Some [ move ] -> String.compare move.Logseq_chat_pending_ops.order "a2" > 0
     | _ -> false);
  assert_bool "drop onto the selected root is rejected"
    (State.drop drop_context selected "middle" State.Inside = None)
;;

let () =
  let state, no_tap = State.update context State.empty (Tap_block "missing") in
  assert_bool "tap missing block is ignored" (state = State.empty && no_tap = []);
  let unchanged, no_text = State.update context State.empty (Text_changed { title = "x"; caret = 1 }) in
  assert_bool "text change without editor is ignored" (unchanged = State.empty && no_text = []);
  let unchanged, no_caret = State.update context State.empty (Caret_moved 1) in
  assert_bool "caret move without editor is ignored" (unchanged = State.empty && no_caret = []);
  let unchanged, no_return = State.update context State.empty Return_pressed in
  assert_bool "return without editor is ignored" (unchanged = State.empty && no_return = []);
  let unchanged, no_backspace =
    State.update context State.empty (Backspace_pressed { selection_length = 0 })
  in
  assert_bool "backspace without editor is ignored"
    (unchanged = State.empty && no_backspace = []);
  let unchanged, selected_backspace =
    State.update context State.empty (Backspace_pressed { selection_length = 1 })
  in
  assert_bool "backspace with native selection stays native"
    (unchanged = State.empty && selected_backspace = []);
  let unchanged, no_choice = State.update context State.empty (Choose_autocomplete "value") in
  assert_bool "autocomplete choice without editor is ignored"
    (unchanged = State.empty && no_choice = []);
  let unchanged, no_confirm = State.update context State.empty Confirm_delete in
  assert_bool "delete confirmation without selection is ignored"
    (unchanged = State.empty && no_confirm = [])
;;

let () =
  let idle_actions = [ State.Task; Tag_action; Page_reference; Camera; Attachment ] in
  List.iter
    (fun action ->
      let state, effects = State.update context State.empty (Toolbar action) in
      assert_bool "editor-only toolbar action is idle without an editor"
        (state = State.empty && effects = []))
    idle_actions;
  let state, effects = State.update context State.empty (Toolbar State.Indent) in
  assert_bool "invalid idle indent still provides feedback"
    (state = State.empty && effects = [ State.Haptic State.Impact ]);
  let state, effects = State.update context State.empty (Toolbar State.Outdent) in
  assert_bool "invalid idle outdent still provides feedback"
    (state = State.empty && effects = [ State.Haptic State.Impact ]);
  let state, effects = State.update context State.empty Cancel_editing in
  assert_bool "cancel without editor is a no-op" (state = State.empty && effects = [])
;;

let () =
  let unchanged, effects = State.update context State.empty (Zoom_in "missing") in
  assert_bool "zoom into missing block is ignored" (unchanged = State.empty && effects = []);
  let state, _ = State.update context State.empty (Zoom_in "a") in
  let same, effects = State.update context state (Zoom_in "a") in
  assert_bool "zoom into current block does not duplicate the path"
    (State.zoom_path same = [ "a" ] && effects = [ State.Haptic State.Selection ]);
  let state, effects = State.update context State.empty Zoom_out in
  assert_bool "zoom out at journal root stays at root"
    (State.zoom_path state = [] && effects = [ State.Haptic State.Selection ]);
  let unchanged, effects =
    State.update context State.empty
      (Operation_staged
         (Logseq_chat_pending_ops.Merge_backward
            { uuid = "a"; expected_title = "Alpha"; title = "Alpha"
            ; previous_uuid = "missing"; expected_previous_title = "Missing"
            ; merged_title = None }))
  in
  assert_bool "staged merge with missing survivor is ignored"
    (unchanged = State.empty && effects = []);
  let state, effects =
    State.update context State.empty
      (Operation_staged
         (Logseq_chat_pending_ops.Split_block
            { uuid = "a"; expected_title = "Alpha"; before = "A"; after = "lpha"
            ; new_uuid = "new"; new_order = "a1"; created_at = 1 }))
  in
  assert_bool "staged split focuses its optimistic block title"
    (State.editing_uuid state = Some "new"
     && State.editing_title state = Some "lpha"
     && effects = [])
;;

let () =
  let state, effects = State.update context State.empty (Add_root_block "page-1") in
  assert_bool "add root block stages a focused insert"
    (state = State.empty
     && effects
        = [ State.Insert_root_block { page_uuid = "page-1" }; State.Haptic State.Impact ]);
  let state, effects =
    State.update context State.empty
      (Operation_staged
         (Logseq_chat_pending_ops.Insert_block
            { uuid = "new-root"; title = ""; page_uuid = "page-1"
            ; parent_uuid = "page-1"; order = "a0"; created_at = 1 }))
  in
  assert_bool "staged insert opens the editor on the new block"
    (State.editing_uuid state = Some "new-root"
     && State.editing_title state = Some ""
     && effects = [])
;;

let () =
  assert_autocomplete "slash command after newline is inactive" None "text\n/query";
  assert_autocomplete "property query starts at the current line"
    (Some State.{ kind = Property; query = "status" }) "before\nstatus::";
  let malformed_state : State.t =
    { State.empty with
      editing = Some (editing "plain")
    ; autocomplete = Some { kind = Node; query = "" }
    }
  in
  let unchanged, effects = State.update context malformed_state (Choose_autocomplete "Project") in
  assert_bool "autocomplete completion with a stale marker is ignored"
    (unchanged = malformed_state && effects = [])
;;

let () =
  let stale_editing = State.{ uuid = "missing"; expected_title = ""; title = ""; caret = 0 } in
  let stale_state = State.{ empty with editing = Some stale_editing } in
  let unchanged, effects =
    State.update context stale_state (Backspace_pressed { selection_length = 0 })
  in
  assert_bool "backspace on an editor absent from the outline is ignored"
    (unchanged = stale_state && effects = [])
;;

let () =
  let ordered = block ~order:(Some "a0") "ordered" "Ordered" in
  let unordered = block ~order:None "unordered" "Unordered" in
  assert_bool "ordered blocks sort before unordered blocks in either comparator direction"
    (State.compare_blocks ordered unordered < 0
     && State.compare_blocks unordered ordered > 0);
  assert_bool "index lookup covers an empty sibling list"
    (State.index_of_uuid "missing" [] = None);
  assert_bool "empty roots are not contiguous"
    (not (State.selection_is_contiguous [] [ ordered ]));
  assert_bool "unselected siblings are excluded from contiguity indices"
    (State.selection_is_contiguous [ ordered ] [ unordered; ordered ])
;;

let () =
  let blocks =
    [ block "first" "First"
    ; block ~order:(Some "a1") "second" "Second"
    ; block ~order:(Some "a2") "third" "Third"
    ; block ~order:(Some "a3") "fourth" "Fourth"
    ; block ~parent_id:(Some "other") "other-child" "Other child"
    ]
  in
  let structural = State.{ blocks; pages = []; tags = [] } in
  assert_bool "indent rejects the first sibling"
    (State.indent structural (State.String_set.singleton "first") = None);
  let noncontiguous =
    State.String_set.(empty |> add "second" |> add "fourth")
  in
  assert_bool "indent rejects noncontiguous roots"
    (State.indent structural noncontiguous = None);
  let different_parents =
    State.String_set.(empty |> add "second" |> add "other-child")
  in
  assert_bool "indent rejects roots from different parents"
    (State.indent structural different_parents = None);
  let with_existing_child =
    State.
      { blocks =
          [ block "first" "First"
          ; block ~parent_id:(Some "first") "existing" "Existing"
          ; block ~order:(Some "a1") "second" "Second"
          ]
      ; pages = []; tags = []
      }
  in
  assert_bool "indent appends after existing children"
    (match State.indent with_existing_child (State.String_set.singleton "second") with
     | Some [ move ] -> String.compare move.Logseq_chat_pending_ops.order "a0" > 0
     | _ -> false)
;;

let () =
  let top_level = State.String_set.singleton "a" in
  assert_bool "outdent rejects a block whose parent is not a block"
    (State.outdent context top_level = None);
  let blocks =
    [ block "parent" "Parent"
    ; block ~parent_id:(Some "parent") "first" "First"
    ; block ~parent_id:(Some "parent") ~order:(Some "a1") "second" "Second"
    ; block ~parent_id:(Some "parent") ~order:(Some "a2") "third" "Third"
    ; block ~parent_id:(Some "other") "other-child" "Other child"
    ]
  in
  let structural = State.{ blocks; pages = []; tags = [] } in
  assert_bool "outdent rejects noncontiguous children"
    (State.outdent structural State.String_set.(empty |> add "first" |> add "third") = None);
  assert_bool "outdent rejects roots from different parents"
    (State.outdent structural State.String_set.(empty |> add "first" |> add "other-child") = None);
  let parent_without_outer_membership =
    State.
      { blocks =
          [ block ~parent_id:None "parent" "Parent"
          ; block ~parent_id:(Some "parent") "child" "Child"
          ]
      ; pages = []; tags = []
      }
  in
  assert_bool "outdent rejects a parent missing from its outer sibling list"
    (State.outdent parent_without_outer_membership (State.String_set.singleton "child") = None);
  let no_next_outer =
    State.
      { blocks =
          [ block "parent" "Parent"
          ; block ~parent_id:(Some "parent") "child" "Child"
          ]
      ; pages = []; tags = []
      }
  in
  assert_bool "outdent after the final outer sibling allocates an unbounded order"
    (match State.outdent no_next_outer (State.String_set.singleton "child") with
     | Some [ move ] -> String.compare move.Logseq_chat_pending_ops.order "a0" > 0
     | _ -> false)
;;

let () =
  let cyclic_a = block ~parent_id:(Some "cyclic-b") "cyclic-a" "A" in
  let cyclic_b = block ~parent_id:(Some "cyclic-a") "cyclic-b" "B" in
  let cyclic = State.{ blocks = [ cyclic_a; cyclic_b ]; pages = []; tags = [] } in
  assert_bool "ancestor traversal terminates on malformed cycles"
    (State.String_set.cardinal (State.ancestor_uuids cyclic cyclic_a) = 2);
  let roots =
    State.selected_roots cyclic State.String_set.(empty |> add "cyclic-a" |> add "cyclic-b")
  in
  assert_bool "selected-root traversal terminates on malformed cycles" (roots = [])
;;

let () =
  let blocks =
    [ block "first" "First"
    ; block ~order:(Some "a1") "middle" "Middle"
    ; block ~order:(Some "a2") "last" "Last"
    ; block ~parent_id:(Some "last") "last-child" "Last child"
    ; block ~parent_id:None "detached" "Detached"
    ]
  in
  let drop_context = State.{ blocks; pages = []; tags = [] } in
  let selected = State.String_set.singleton "middle" in
  assert_bool "drop inside appends after existing children"
    (match State.drop drop_context selected "last" State.Inside with
     | Some [ move ] -> String.compare move.Logseq_chat_pending_ops.order "a0" > 0
     | _ -> false);
  assert_bool "drop before a non-first target uses the previous order"
    (match State.drop drop_context selected "last" State.Before with
     | Some [ move ] ->
       String.compare move.Logseq_chat_pending_ops.order "a0" > 0
       && String.compare move.order "a2" < 0
     | _ -> false);
  assert_bool "drop after a non-final target uses the next order"
    (match State.drop drop_context selected "first" State.After with
     | Some [ move ] ->
       String.compare move.Logseq_chat_pending_ops.order "a0" > 0
       && String.compare move.order "a2" < 0
     | _ -> false);
  assert_bool "drop target absent from normalized siblings is rejected by order allocation"
    (State.drop drop_context selected "detached" State.Before = None)
;;

let () =
  let state, _ = State.update context State.empty (Tap_block "a") in
  let state, _ = State.update context state (Caret_moved 0) in
  let unchanged, effects =
    State.update context state (Backspace_pressed { selection_length = 0 })
  in
  assert_bool "backspace deletes the first visible block and focuses its successor"
    (State.editing_uuid unchanged = Some "b" && effects = [ State.Delete_blocks [ "a" ] ]);
  let collapsed, _ = State.update context State.empty (Toggle_collapsed "a") in
  let expanded, effects = State.update context collapsed (Toggle_collapsed "a") in
  assert_bool "second collapse toggle expands the block"
    (expanded.collapsed = State.String_set.empty && effects = [ State.Haptic State.Impact ])
;;

let () =
  let selected = block ~parent_id:(Some "cycle-a") "selected" "Selected" in
  let cycle_a = block ~parent_id:(Some "cycle-b") "cycle-a" "A" in
  let cycle_b = block ~parent_id:(Some "cycle-a") "cycle-b" "B" in
  let cycle_context = State.{ blocks = [ selected; cycle_a; cycle_b ]; pages = []; tags = [] } in
  assert_bool "selected-root ancestor scan stops when unselected ancestors cycle"
    (State.selected_roots cycle_context (State.String_set.singleton "selected") = [ selected ]);
  let state, _ = State.update context State.empty (Tap_block "a") in
  let without_editing_block = State.{ blocks = [ block "other" "Other" ]; pages = []; tags = [] } in
  let unchanged, effects =
    State.update without_editing_block state (Backspace_pressed { selection_length = 0 })
  in
  assert_bool "backspace ignores an editor whose block disappeared during rebase"
    (unchanged = state && effects = [])
;;
