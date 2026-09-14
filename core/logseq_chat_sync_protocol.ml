module Value = Transit_core.Json
module LG = Logseq_chat_lg_core_native

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

let entity_of_lg (entity : LG.sync_entity) = { id = entity.id; attrs = entity.attrs }

let change_set_of_lg (change : LG.sync_change_set) =
  { format_version = change.format_version
  ; graph_id = change.graph_id
  ; schema_version = change.schema_version
  ; t_before = change.t_before
  ; t = change.t
  ; upserts = List.map entity_of_lg change.upserts
  ; deleted = change.deleted
  ; operation_ids = change.operation_ids
  }
;;

let reset_of_lg (reset : LG.sync_reset) =
  { reason = reset.reason; snapshot_required = reset.snapshot_required }
;;

let changed_block_uuids change =
  LG.logseq_chat_sync_protocol_changed_block_uuids
    { format_version = change.format_version
    ; graph_id = change.graph_id
    ; schema_version = change.schema_version
    ; t_before = change.t_before
    ; t = change.t
    ; upserts =
        List.map
          (fun (entity : entity) : LG.sync_entity -> { id = entity.id; attrs = entity.attrs })
          change.upserts
    ; deleted = change.deleted
    ; operation_ids = change.operation_ids
    }
  |> Rrbvec.to_list
;;

let decode_change_set wire =
  Result.map change_set_of_lg (LG.logseq_chat_sync_protocol_decode_change_set wire)
;;

let decode_event ~event_name wire =
  match LG.logseq_chat_sync_protocol_decode_event event_name wire with
  | Ok (Graph_changes change) -> Ok (Graph_changes (change_set_of_lg change))
  | Ok (Reset reset) -> Ok (Reset (reset_of_lg reset))
  | Error _ as error -> error
;;
