(** Sync checkpoint record and Transit (en)coding. *)

type sync_checkpoint =
  { graph_id : string
  ; schema_version : string
  ; applied_server_t : int
  }

val create : string -> string -> int -> sync_checkpoint
val encode : sync_checkpoint -> string
val decode : string -> (sync_checkpoint, string) result
val load_checkpoint : string -> (sync_checkpoint option, string) result
val save_checkpoint_atomic : string -> sync_checkpoint -> (unit, string) result
val decode_map :
  (Transit_core.Json.value * Transit_core.Json.value) list ->
  (sync_checkpoint, string) result
