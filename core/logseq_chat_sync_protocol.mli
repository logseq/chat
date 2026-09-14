module Value = Transit_core.Json

type entity =
  { id : Value.value
  ; attrs : (Value.value * Value.value) list
  }

type change_set =
  { format_version : int
  ; graph_id : string
  ; schema_version : string
  ; t_before : int
  ; t : int
  ; upserts : entity list
  ; deleted : Value.value list
  ; operation_ids : string list
  }

type reset =
  { reason : string
  ; snapshot_required : bool
  }

type event =
  | Graph_changes of change_set
  | Reset of reset

val changed_block_uuids : change_set -> string list
val decode_change_set : string -> (change_set, string) result
val decode_event : event_name:string -> string -> (event, string) result
