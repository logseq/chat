(** Server-side planning of outliner edit commands into mutations. *)

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

val plan_split :
  (string -> outliner_block option) ->
  split_command ->
  (mutation list, string) result

val plan_merge :
  (string -> outliner_block option) ->
  (string -> outliner_block list) ->
  merge_backward_command ->
  (mutation list, string) result

val plan :
  (string -> outliner_block option) ->
  (string -> outliner_block list) ->
  command ->
  (mutation list, string) result
