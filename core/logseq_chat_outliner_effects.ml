module State = Logseq_chat_outliner_state
module Ops = Logseq_chat_pending_ops
module Model = Logseq_chat_model
module Order = Logseq_chat_fractional_order

type platform_command =
  | Haptic of State.haptic
  | Focus_block of string
  | Confirm_delete of string list
  | Set_clipboard_text of string
  | Set_clipboard_references of string list
  | Set_clipboard_urls of string list
  | Pick_attachment of string
  | Take_photo of string
  | Record_audio of string

type result =
  { operations : Ops.t list
  ; platform : platform_command list
  }

let find_block (context : State.context) uuid =
  List.find_opt (fun (block : Model.block) -> String.equal block.uuid uuid) context.blocks
;;

let sorted_siblings (context : State.context) parent_id =
  context.blocks
  |> List.filter (fun (block : Model.block) -> block.parent_id = parent_id)
  |> List.sort (fun (left : Model.block) (right : Model.block) ->
    match left.order, right.order with
    | Some left, Some right when not (String.equal left right) -> String.compare left right
    | Some _, None -> -1
    | None, Some _ -> 1
    | _ -> String.compare left.uuid right.uuid)
;;

let next_order context (block : Model.block) =
  let siblings = sorted_siblings context block.parent_id in
  let rec first_strictly_greater lower = function
    | [] -> None
    | (candidate : Model.block) :: rest ->
      (match lower, candidate.order with
       | Some lower, Some candidate when String.compare candidate lower > 0 -> Some candidate
       | _ -> first_strictly_greater lower rest)
  in
  let rec loop = function
    | current :: rest when String.equal current.Model.uuid block.uuid ->
      first_strictly_greater block.order rest
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop siblings
;;

let operation ~base_t ~fresh_uuid intent =
  Ops.{ operation_id = fresh_uuid (); base_t; state = Queued; intent }
;;

let status_reference (status : Model.status) =
  match status.ident with
  | Some ident -> Ops.Ref_ident ident
  | None -> Ops.Ref_uuid status.uuid
;;

let next_status_value block =
  let current_ident = Option.bind block.Model.status (fun status -> status.Model.ident) in
  match current_ident with
  | Some "logseq.property/status.todo" ->
    Some (Ops.Ref_ident "logseq.property/status.doing")
  | Some "logseq.property/status.doing" ->
    Some (Ops.Ref_ident "logseq.property/status.done")
  | Some "logseq.property/status.done" -> None
  | _ -> Some (Ops.Ref_ident "logseq.property/status.todo")
;;

let append_result left right =
  { operations = left.operations @ right.operations
  ; platform = left.platform @ right.platform
  }
;;

let command ~base_t ~now ~fresh_uuid context = function
  | State.Haptic haptic -> Ok { operations = []; platform = [ Haptic haptic ] }
  | State.Commit_title { uuid; expected_title; title } ->
    Ok
      { operations = [ operation ~base_t ~fresh_uuid (Save_title { uuid; expected_title; title }) ]
      ; platform = []
      }
  | State.Split_at { uuid; expected_title; before; after } ->
    (match find_block context uuid with
     | None -> Error "split source no longer exists"
     | Some block ->
       let lower = block.Model.order in
       let upper = next_order context block in
       Result.bind (Order.between lower upper) (fun new_order ->
         let operation_id = fresh_uuid () in
         let new_uuid = fresh_uuid () in
         Ok
           { operations =
               [ Ops.
                   { operation_id
                   ; base_t
                   ; state = Queued
                   ; intent =
                       Split_block
                         { uuid
                         ; expected_title
                         ; before
                         ; after
                         ; new_uuid
                         ; new_order
                         ; created_at = now ()
                         }
                   }
               ]
           ; platform = [ Focus_block new_uuid ]
           }))
  | State.Merge_backward
      { uuid; expected_title; title; previous_uuid; expected_previous_title } ->
    Ok
      { operations =
          [ operation
              ~base_t
              ~fresh_uuid
              (Merge_backward
                 { uuid
                 ; expected_title
                 ; title
                 ; previous_uuid
                 ; expected_previous_title
                 ; merged_title = None
                 })
          ]
      ; platform = [ Focus_block previous_uuid ]
      }
  | State.Move_blocks moves ->
    if moves = []
    then Error "move batch must not be empty"
    else
      Ok
        { operations = [ operation ~base_t ~fresh_uuid (Move_blocks { moves }) ]
        ; platform = []
        }
  | State.Request_delete_confirmation uuids ->
    Ok { operations = []; platform = [ Confirm_delete uuids ] }
  | State.Delete_blocks uuids ->
    if uuids = []
    then Ok { operations = []; platform = [] }
    else
      Ok
        { operations = [ operation ~base_t ~fresh_uuid (Delete_blocks { uuids }) ]
        ; platform = []
        }
  | State.Cycle_task_status uuid ->
    (match find_block context uuid with
     | None -> Error "task block no longer exists"
     | Some block ->
       Ok
         { operations =
             [ operation
                 ~base_t
                 ~fresh_uuid
                 (Set_property
                    { uuid
                    ; attr = "logseq.property/status"
                    ; expected = Option.map status_reference block.status
                    ; value = next_status_value block
                    })
             ]
         ; platform = []
         })
  | State.Set_task_status_value { uuid; status } ->
    (match find_block context uuid with
     | None -> Error "task block no longer exists"
     | Some block ->
       Ok
         { operations =
             [ operation
                 ~base_t
                 ~fresh_uuid
                 (Set_property
                    { uuid
                    ; attr = "logseq.property/status"
                    ; expected = Option.map status_reference block.status
                    ; value = Some status
                    })
             ]
         ; platform = []
         })
  | State.Assign_tag { uuid; value } ->
    (match find_block context uuid with
     | None -> Error "tag target block no longer exists"
     | Some _ ->
       let existing =
         List.find_opt
           (fun candidate -> String.equal candidate.State.value value)
           context.tags
       in
       (match existing with
        | Some candidate ->
          Ok
            { operations =
                [ operation ~base_t ~fresh_uuid (Add_tag { uuid; tag_uuid = candidate.value }) ]
            ; platform = []
            }
        | None ->
          let title = String.trim value in
          if String.equal title ""
          then Error "tag title must not be empty"
          else
            let tag_uuid = fresh_uuid () in
            Ok
              { operations =
                  [ operation
                      ~base_t
                      ~fresh_uuid
                      (Create_tag { uuid = tag_uuid; title; created_at = now () })
                  ; operation ~base_t ~fresh_uuid (Add_tag { uuid; tag_uuid })
                  ]
              ; platform = []
              }))
  | State.Insert_root_block { page_uuid } ->
    let lower =
      match List.rev (sorted_siblings context (Some page_uuid)) with
      | last :: _ -> last.Model.order
      | [] -> None
    in
    Result.bind (Order.between lower None) (fun order ->
      let operation_id = fresh_uuid () in
      let new_uuid = fresh_uuid () in
      Ok
        { operations =
            [ Ops.
                { operation_id
                ; base_t
                ; state = Queued
                ; intent =
                    Insert_block
                      { uuid = new_uuid
                      ; title = ""
                      ; page_uuid
                      ; parent_uuid = page_uuid
                      ; order
                      ; created_at = now ()
                      }
                }
            ]
        ; platform = [ Focus_block new_uuid ]
        })
  | State.Pick_attachment uuid ->
    Ok { operations = []; platform = [ Pick_attachment uuid ] }
  | State.Take_photo uuid ->
    Ok { operations = []; platform = [ Take_photo uuid ] }
  | State.Record_audio uuid ->
    Ok { operations = []; platform = [ Record_audio uuid ] }
  | State.Copy_text text ->
    Ok { operations = []; platform = [ Set_clipboard_text text ] }
  | State.Copy_references uuids ->
    Ok { operations = []; platform = [ Set_clipboard_references uuids ] }
  | State.Copy_urls uuids ->
    Ok { operations = []; platform = [ Set_clipboard_urls uuids ] }
;;

let interpret ~base_t ~now ~fresh_uuid context commands =
  List.fold_left
    (fun result next ->
      Result.bind result (fun accumulated ->
        Result.map (append_result accumulated) (command ~base_t ~now ~fresh_uuid context next)))
    (Ok { operations = []; platform = [] })
    commands
;;
