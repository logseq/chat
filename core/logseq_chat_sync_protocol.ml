module Value = Transit_core.Json
module LG = Logseq_chat_lg_core_native

type entity = LG.sync_entity =
  { id : Value.value
  ; attrs : (Value.value * Value.value) list
  }

type change_set = LG.sync_change_set =
  { format_version : int
  ; graph_id : string
  ; schema_version : string
  ; t_before : int
  ; t : int
  ; upserts : entity list
  ; deleted : Value.value list
  ; operation_ids : string list
  }

type reset = LG.sync_reset =
  { reason : string
  ; snapshot_required : bool
  }

type event = LG.sync_event =
  | Graph_changes of change_set
  | Reset of reset

let changed_block_uuids change =
  LG.logseq_chat_sync_protocol_changed_block_uuids change |> Rrbvec.to_list
;;

let decode_change_set wire =
  LG.logseq_chat_sync_protocol_decode_change_set wire
;;

let decode_event ~event_name wire =
  LG.logseq_chat_sync_protocol_decode_event event_name wire
;;
