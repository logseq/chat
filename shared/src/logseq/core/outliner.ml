type outliner_block =
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

type title_mutation =
  { uuid : string
  ; title : string
  }

type insert_mutation =
  { insert_block : outliner_block
  ; created_at : int
  }

type reparent_mutation =
  { uuid : string
  ; page_uuid : string
  ; parent_uuid : string
  }

type delete_mutation = { uuid : string }

type mutation =
  | Set_title of title_mutation
  | Insert of insert_mutation
  | Reparent of reparent_mutation
  | Delete of delete_mutation

let nonblank value = String.trim value <> ""

let contains_block blocks uuid =
  List.exists (fun (block : outliner_block) -> block.uuid = uuid) blocks

let plan_split (find : string -> outliner_block option)
    (request : split_command) =
  match find request.source_uuid with
  | None -> Error "split source no longer exists"
  | Some source ->
    if request.source_uuid = request.new_uuid || not (nonblank request.new_uuid)
    then Error "split requires a distinct new block UUID"
    else
      (match find request.new_uuid with
       | Some inserted ->
         if
           inserted.title = request.after
           && inserted.page_uuid = source.page_uuid
           && inserted.parent_uuid = source.parent_uuid
           && inserted.order = request.new_order
           && source.title = request.before
         then Ok []
         else Error "split block UUID already exists"
       | None ->
         if source.title <> request.expected_title then
           Error "split source title changed on the server"
         else
           Ok
             [
               Set_title { uuid = source.uuid; title = request.before };
               Insert
                 {
                   insert_block =
                     {
                       uuid = request.new_uuid;
                       title = request.after;
                       page_uuid = source.page_uuid;
                       parent_uuid = source.parent_uuid;
                       order = request.new_order;
                     };
                   created_at = request.created_at;
                 };
             ])

let plan_merge (find : string -> outliner_block option)
    (children : string -> outliner_block list)
    (request : merge_backward_command) =
  match (find request.source_uuid, find request.previous_uuid) with
  | None, _ -> Error "merge source no longer exists"
  | _, None -> Error "merge target no longer exists"
  | Some source, Some previous ->
    if source.uuid = previous.uuid then
      Error "merge source and target must be different blocks"
    else if source.title <> request.expected_source_title then
      Error "merge source title changed on the server"
    else if previous.title <> request.expected_previous_title then
      Error "merge target title changed on the server"
    else if source.page_uuid <> previous.page_uuid then
      Error "merge source and target must belong to the same page"
    else
      let direct_children = children source.uuid in
      if contains_block direct_children previous.uuid then
        Error "merge target cannot be a child of the source"
      else
        let merged_title =
          match request.merged_title with
          | Some title -> title
          | None -> previous.title ^ request.source_title
        in
        Ok
          ([ Set_title { uuid = previous.uuid; title = merged_title } ]
          @ List.map
              (fun (child : outliner_block) ->
                Reparent
                  {
                    uuid = child.uuid;
                    page_uuid = previous.page_uuid;
                    parent_uuid = previous.uuid;
                  })
              direct_children
          @ [ Delete { uuid = source.uuid } ])

let plan (find : string -> outliner_block option)
    (children : string -> outliner_block list) command =
  match command with
  | Split request -> plan_split find request
  | Merge_backward request -> plan_merge find children request
