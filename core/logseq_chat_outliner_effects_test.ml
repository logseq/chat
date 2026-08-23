module State = Logseq_chat_outliner_state
module Effects = Logseq_chat_outliner_effects
module Model = Logseq_chat_model
module Ops = Logseq_chat_pending_ops

let fail label = failwith label
let assert_bool label value = if not value then fail label

let block ?(parent_id = Some "page") ?(order = Some "a0") uuid title =
  Model.
    { uuid; title; page_id = "page"; parent_id; order
    ; created_at = 0; updated_at = 0; sync_status = "synced"; tags = []
    ; references = []; breadcrumbs = []; status = None; is_asset = false; asset_type = None; asset_size = None
    ; asset_checksum = None; local_path = None; journal = None }
;;

let context =
  State.
    { blocks =
        [ block "first" "First"
        ; block ~order:(Some "a1") "second" "Second"
        ; block ~order:(Some "a2") "third" "Third"
        ]
    ; pages = []; tags = []
    }
;;

let ids = ref [ "operation-1"; "new-block"; "operation-2"; "operation-3"; "operation-4" ]

let fresh_uuid () =
  match !ids with
  | value :: rest -> ids := rest; value
  | [] -> fail "fresh UUID exhausted"
;;

let () =
  let result =
    Effects.interpret
      ~base_t:42
      ~now:(fun () -> 100)
      ~fresh_uuid
      context
      [ State.Split_at
          { uuid = "second"; expected_title = "Second"; before = "Sec"; after = "ond" }
      ]
  in
  match result with
  | Error message -> fail ("split interpreter failed: " ^ message)
  | Ok result ->
    assert_bool "split creates one semantic operation" (List.length result.operations = 1);
    (match List.hd result.operations with
     | { Ops.operation_id = "operation-1"; base_t = 42
       ; intent = Split_block { new_uuid = "new-block"; new_order; created_at = 100; _ }; _ } ->
       assert_bool "split order is between siblings"
         (String.compare "a1" new_order < 0 && String.compare new_order "a2" < 0)
     | _ -> fail "split operation shape is wrong");
    assert_bool "split requests focus for the new block"
      (result.platform = [ Effects.Focus_block "new-block" ])
;;

let () =
  let duplicate_order_context =
    State.
      { context with
        blocks =
          [ block "first" "First"
          ; block ~order:(Some "a1") "second" "Second"
          ; block ~order:(Some "a1") "duplicate" "Duplicate"
          ; block ~order:(Some "a2") "third" "Third"
          ]
      }
  in
  let duplicate_ids = ref [ "duplicate-operation"; "duplicate-new-block" ] in
  let duplicate_fresh_uuid () =
    match !duplicate_ids with
    | value :: rest -> duplicate_ids := rest; value
    | [] -> fail "duplicate-order fresh UUID exhausted"
  in
  let result =
    Effects.interpret
      ~base_t:42
      ~now:(fun () -> 100)
      ~fresh_uuid:duplicate_fresh_uuid
      duplicate_order_context
      [ State.Split_at
          { uuid = "second"; expected_title = "Second"; before = "Second"; after = "" }
      ]
  in
  match result with
  | Error message -> fail ("split after duplicate sibling order failed: " ^ message)
  | Ok result ->
    (match List.hd result.operations with
     | { Ops.intent = Split_block { new_order; _ }; _ } ->
       assert_bool
         "split skips equal sibling orders and remains below the next greater order"
         (String.compare "a1" new_order < 0 && String.compare new_order "a2" < 0)
     | _ -> fail "duplicate-order split operation shape is wrong")
;;

let () =
  let result =
    Effects.interpret
      ~base_t:43
      ~now:(fun () -> 100)
      ~fresh_uuid
      context
      [ State.Set_task_status_value { uuid = "first"; status = Ops.Ref_uuid "waiting" }
      ; State.Haptic State.Impact
      ]
  in
  match result with
  | Error message -> fail ("explicit task status interpreter failed: " ^ message)
  | Ok result ->
    assert_bool "explicit status becomes a guarded semantic operation"
      (match result.operations with
       | [ { Ops.base_t = 43
           ; intent = Set_property { uuid = "first"; expected = None;
                                     value = Some (Ref_uuid "waiting"); _ }
           ; _ } ] -> true
       | _ -> false);
    assert_bool "explicit status preserves its haptic platform effect"
      (result.platform = [ Effects.Haptic State.Impact ])
;;

let () =
  let move = Ops.{ uuid = "second"; page_uuid = "page"; parent_uuid = "first"; order = "a0" } in
  let result =
    Effects.interpret
      ~base_t:42
      ~now:(fun () -> 100)
      ~fresh_uuid
      context
      [ State.Move_blocks [ move ]; State.Haptic State.Impact ]
  in
  match result with
  | Error message -> fail ("move interpreter failed: " ^ message)
  | Ok result ->
    assert_bool "move batch stays one operation"
      (match result.operations with
       | [ { Ops.intent = Move_blocks { moves = [ actual ] }; _ } ] -> actual = move
       | _ -> false);
    assert_bool "haptic stays a platform command"
      (result.platform = [ Effects.Haptic State.Impact ])
;;

let () =
  let result =
    Effects.interpret
      ~base_t:42
      ~now:(fun () -> 100)
      ~fresh_uuid
      context
      [ State.Cycle_task_status "first" ]
  in
  match result with
  | Error message -> fail ("task status interpreter failed: " ^ message)
  | Ok result ->
    assert_bool "task status is a reusable semantic operation"
      (match result.operations with
       | [ { Ops.intent =
               Set_property
                 { uuid = "first"
                 ; attr = "logseq.property/status"
                 ; expected = None
                 ; value = Some (Ref_ident "logseq.property/status.todo")
                 }
           ; _ } ] -> true
       | _ -> false);
    assert_bool "task status does not round-trip through Swift"
      (result.platform = [])
;;

let interpret_platform command =
  Effects.interpret
    ~base_t:42
    ~now:(fun () -> 100)
    ~fresh_uuid
    context
    [ command ]
;;

let () =
  let cases =
    [ State.Haptic State.Selection, Effects.Haptic State.Selection
    ; State.Pick_attachment "first", Effects.Pick_attachment "first"
    ; State.Record_audio "first", Effects.Record_audio "first"
    ; State.Take_photo "first", Effects.Take_photo "first"
    ; State.Copy_text "First", Effects.Set_clipboard_text "First"
    ; State.Copy_references [ "first" ], Effects.Set_clipboard_references [ "first" ]
    ; State.Copy_urls [ "first" ], Effects.Set_clipboard_urls [ "first" ]
    ; State.Request_delete_confirmation [ "first" ], Effects.Confirm_delete [ "first" ]
    ]
  in
  List.iter
    (fun (command, expected) ->
      match interpret_platform command with
      | Error message -> fail ("platform command interpreter failed: " ^ message)
      | Ok result ->
        assert_bool "platform command is mapped exactly"
          (result.operations = [] && result.platform = [ expected ]))
    cases
;;

let fresh_values values =
  let remaining = ref values in
  fun () ->
    match !remaining with
    | value :: rest -> remaining := rest; value
    | [] -> fail "fresh UUID exhausted"
;;

let interpret ?(context = context) ?(ids = [ "operation" ]) commands =
  Effects.interpret
    ~base_t:42
    ~now:(fun () -> 100)
    ~fresh_uuid:(fresh_values ids)
    context
    commands
;;

let assert_error label expected = function
  | Error actual -> assert_bool label (String.equal actual expected)
  | Ok _ -> fail (label ^ ": expected an error")
;;

let () =
  let unordered_context =
    State.
      { blocks =
          [ block ~order:None "z" "Z"
          ; block ~order:(Some "a0") "ordered" "Ordered"
          ; block ~order:None "a" "A"
          ]
      ; pages = []; tags = []
      }
  in
  assert_bool "siblings sort ordered values before missing values and then by UUID"
    (List.map
       (fun (item : Model.block) -> item.uuid)
       (Effects.sorted_siblings unordered_context (Some "page"))
     = [ "ordered"; "a"; "z" ])
;;

let () =
  assert_error "split rejects a missing source" "split source no longer exists"
    (interpret [ State.Split_at
                   { uuid = "missing"; expected_title = ""; before = ""; after = "" }
               ]);
  assert_error "empty move batches are rejected" "move batch must not be empty"
    (interpret [ State.Move_blocks [] ]);
  assert_error "cycling a missing task is rejected" "task block no longer exists"
    (interpret [ State.Cycle_task_status "missing" ]);
  assert_error "setting a missing task is rejected" "task block no longer exists"
    (interpret
       [ State.Set_task_status_value { uuid = "missing"; status = Ops.Ref_uuid "todo" } ]);
  assert_bool "empty delete is an intentional no-op"
    (interpret [ State.Delete_blocks [] ]
     = Ok Effects.{ operations = []; platform = [] });
  assert_bool "nonempty delete is one semantic operation"
    (match interpret [ State.Delete_blocks [ "first" ] ] with
     | Ok { operations = [ { Ops.intent = Delete_blocks { uuids = [ "first" ] }; _ } ]; _ } ->
       true
     | _ -> false)
;;

let () =
  assert_bool "commit title becomes one guarded semantic operation"
    (match
       interpret
         [ State.Commit_title { uuid = "first"; expected_title = "First"; title = "Edited" } ]
     with
     | Ok
         { operations =
             [ { Ops.intent = Save_title
                   { uuid = "first"; expected_title = "First"; title = "Edited" }
               ; _
               }
             ]
         ; platform = []
         } -> true
     | _ -> false);
  assert_bool "merge focuses the surviving previous block"
    (match
       interpret
         [ State.Merge_backward
             { uuid = "second"
             ; expected_title = "Second"
             ; title = "Second"
             ; previous_uuid = "first"
             ; expected_previous_title = "First"
             }
         ]
     with
     | Ok
         { operations = [ { Ops.intent = Merge_backward { previous_uuid = "first"; _ }; _ } ]
         ; platform = [ Effects.Focus_block "first" ]
         } -> true
     | _ -> false)
;;

let () =
  (* Adding the first block to an empty page starts at the first fractional
     order and focuses the new block for editing. *)
  (match
     interpret
       ~context:State.{ blocks = []; pages = []; tags = [] }
       ~ids:[ "operation"; "new-root" ]
       [ State.Insert_root_block { page_uuid = "page-1" } ]
   with
   | Ok
       { operations =
           [ { Ops.intent =
                 Insert_block
                   { uuid = "new-root"
                   ; title = ""
                   ; page_uuid = "page-1"
                   ; parent_uuid = "page-1"
                   ; order
                   ; created_at = 100
                   }
             ; _
             }
           ]
       ; platform = [ Effects.Focus_block "new-root" ]
       } -> assert_bool "first root block gets a valid order" (String.length order > 0)
   | _ -> fail "inserting the first root block must stage one focused insert");
  (* Appending to a non-empty page orders the new block after the last root. *)
  match
    interpret ~ids:[ "operation"; "new-root" ] [ State.Insert_root_block { page_uuid = "page" } ]
  with
  | Ok { operations = [ { Ops.intent = Insert_block { order; _ }; _ } ]; _ } ->
    assert_bool "appended root block sorts after existing roots" (String.compare order "a2" > 0)
  | _ -> fail "inserting a root block on a populated page must stage one insert"
;;

let status ?ident uuid =
  Model.
    { uuid; ident; title = uuid; icon_type = None; icon_id = None; icon_color = None }
;;

let context_with_status status =
  State.
    { blocks = [ { (block "task" "Task") with status = Some status } ]
    ; pages = []; tags = []
    }
;;

let cycle_value status =
  match interpret ~context:(context_with_status status) [ State.Cycle_task_status "task" ] with
  | Ok
      { operations =
          [ { Ops.intent = Set_property { expected; value; _ }; _ } ]
      ; _
      } -> expected, value
  | _ -> fail "task cycle did not produce a property operation"
;;

let () =
  assert_bool "task cycle follows Logseq Todo Doing Done order"
    (cycle_value (status ~ident:"logseq.property/status.todo" "todo")
     = ( Some (Ops.Ref_ident "logseq.property/status.todo")
       , Some (Ops.Ref_ident "logseq.property/status.doing") ));
  assert_bool "task cycle advances Doing to Done"
    (cycle_value (status ~ident:"logseq.property/status.doing" "doing")
     = ( Some (Ops.Ref_ident "logseq.property/status.doing")
       , Some (Ops.Ref_ident "logseq.property/status.done") ));
  assert_bool "task cycle clears Done"
    (cycle_value (status ~ident:"logseq.property/status.done" "done")
     = ( Some (Ops.Ref_ident "logseq.property/status.done")
       , None ));
  assert_bool "task cycle resets an unknown status"
    (cycle_value (status ~ident:"user.status/custom" "custom")
     = ( Some (Ops.Ref_ident "user.status/custom")
       , Some (Ops.Ref_ident "logseq.property/status.todo") ));
  assert_bool "task cycle guards a UUID-only status"
    (cycle_value (status "uuid-only")
     = ( Some (Ops.Ref_uuid "uuid-only")
       , Some (Ops.Ref_ident "logseq.property/status.todo") ))
;;
