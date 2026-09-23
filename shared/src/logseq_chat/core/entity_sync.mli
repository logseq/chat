(** Convert server sync change-set entities into DataScript tx ops. *)

type pending_temp_id =
  { identity_attr : string
  ; identity_value : Datascript.value
  ; entity_ref : Datascript.entity_ref
  }

type entity_identity =
  { identity_attr : string
  ; identity_value : Datascript.value
  ; identity_ref : Datascript.entity_ref
  }

val identity_parts :
  Transit_core.Json.value -> (entity_identity, string) result
val generic_value : Transit_core.Json.value -> Datascript.value
val protected_attr : string -> bool
val pending_temp_ids :
  Datascript.db ->
  Sync_protocol.sync_entity list ->
  (pending_temp_id list, string) result
val apply_change_set :
  (string -> (string, string) result) ->
  Datascript.conn ->
  Sync_protocol.sync_change_set ->
  (unit, string) result
