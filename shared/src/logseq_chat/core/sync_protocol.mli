(** Sync wire protocol: Transit decoding of change sets and reset events. *)

type sync_entity =
  { id : Transit_core.Json.value
  ; attrs : (Transit_core.Json.value * Transit_core.Json.value) list
  }

type sync_change_set =
  { format_version : int
  ; graph_id : string
  ; schema_version : string
  ; t_before : int
  ; t : int
  ; upserts : sync_entity list
  ; deleted : Transit_core.Json.value list
  ; operation_ids : string list
  }

type sync_reset =
  { reason : string
  ; snapshot_required : bool
  }

type sync_event =
  | Graph_changes of sync_change_set
  | Reset of sync_reset

val identity_uuid : Transit_core.Json.value -> string option
val changed_block_uuids : sync_change_set -> string list
val decode_change_set : string -> (sync_change_set, string) result
val decode_event : string -> string -> (sync_event, string) result
