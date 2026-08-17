type block =
  { uuid : string
  ; title : string
  ; page_uuid : string
  ; parent_uuid : string
  ; order : string
  }

type split_command =
  { source_uuid : string
  ; expected_title : string
  ; before : string
  ; after : string
  ; new_uuid : string
  ; new_order : string
  ; created_at : int
  }

type merge_backward_command =
  { source_uuid : string
  ; expected_source_title : string
  ; source_title : string
  ; previous_uuid : string
  ; expected_previous_title : string
  ; merged_title : string option
  }

type command =
  | Split of split_command
  | Merge_backward of merge_backward_command

type mutation =
  | Set_title of
      { uuid : string
      ; title : string
      }
  | Insert of
      { block : block
      ; created_at : int
      }
  | Reparent of
      { uuid : string
      ; page_uuid : string
      ; parent_uuid : string
      }
  | Delete of { uuid : string }

let nonblank value = not (String.equal (String.trim value) "")

let plan_split ~find (request : split_command) =
  match find request.source_uuid with
  | None -> Error "split source no longer exists"
  | Some source when not (String.equal source.title request.expected_title) ->
    Error "split source title changed on the server"
  | Some _ when String.equal request.source_uuid request.new_uuid || not (nonblank request.new_uuid) ->
    Error "split requires a distinct new block UUID"
  | Some _ when Option.is_some (find request.new_uuid) ->
    Error "split block UUID already exists"
  | Some source ->
    Ok
      [ Set_title { uuid = source.uuid; title = request.before }
      ; Insert
          { block =
              { uuid = request.new_uuid
              ; title = request.after
              ; page_uuid = source.page_uuid
              ; parent_uuid = source.parent_uuid
              ; order = request.new_order
              }
          ; created_at = request.created_at
          }
      ]
;;

let plan_merge ~find ~children (request : merge_backward_command) =
  match find request.source_uuid, find request.previous_uuid with
  | None, _ -> Error "merge source no longer exists"
  | _, None -> Error "merge target no longer exists"
  | Some source, Some previous
    when String.equal source.uuid previous.uuid ->
    Error "merge source and target must be different blocks"
  | Some source, Some _
    when not (String.equal source.title request.expected_source_title) ->
    Error "merge source title changed on the server"
  | Some _, Some previous
    when not (String.equal previous.title request.expected_previous_title) ->
    Error "merge target title changed on the server"
  | Some source, Some previous
    when not (String.equal source.page_uuid previous.page_uuid) ->
    Error "merge source and target must belong to the same page"
  | Some source, Some previous ->
    let direct_children = children source.uuid in
    if List.exists (fun child -> String.equal child.uuid previous.uuid) direct_children
    then Error "merge target cannot be a child of the source"
    else
      Ok
       (Set_title
           { uuid = previous.uuid
           ; title = Option.value request.merged_title ~default:(previous.title ^ request.source_title)
           }
         :: List.map
              (fun child ->
                Reparent
                  { uuid = child.uuid
                  ; page_uuid = previous.page_uuid
                  ; parent_uuid = previous.uuid
                  })
              direct_children
         @ [ Delete { uuid = source.uuid } ])
;;

let plan ~find ~children = function
  | Split request -> plan_split ~find request
  | Merge_backward request -> plan_merge ~find ~children request
;;
