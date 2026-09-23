(** Sync session state: snapshot import, change-set application, and
    checkpoint persistence. *)

type sync_session_state =
  { graph_id : string
  ; schema_version : string
  ; applied_server_t : int ref
  }

type sync_error =
  | Unsupported_format
  | Graph_mismatch
  | Schema_mismatch
  | Cursor_mismatch
  | Invalid_cursor
  | Apply_failed of string

type snapshot_metadata =
  { url : string
  ; content_encoding : string option
  ; baseline_t : int
  ; schema_version : string
  ; row_count : int
  }

val create_state : string -> string -> int -> sync_session_state
val applied_server_t : sync_session_state -> int
val submission_accepted : sync_session_state -> int -> unit
val sync_error_of_code : string -> sync_error
val apply_validated_change_set :
  sync_session_state ->
  Sync_protocol.sync_change_set ->
  (Sync_protocol.sync_change_set -> (unit, string) result) ->
  (unit, sync_error) result
val string_field : string -> Yojson.Basic.t -> (string, string) result
val non_negative_int_field :
  string -> Yojson.Basic.t -> (int, string) result
val decode_snapshot_metadata : string -> (snapshot_metadata, string) result
val cleanup_staging : string -> unit
val plaintext_datom :
  (string -> (string, string) result) ->
  Datascript.datom ->
  (Datascript.datom, string) result
val plaintext_snapshot_db :
  (string -> (string, string) result) ->
  Datascript.db ->
  (Datascript.db, string) result
val materialize_plaintext_snapshot :
  string ->
  (string -> (string, string) result) ->
  Datascript.db ->
  (unit, string) result
val stream_snapshot :
  string ->
  string ->
  Snapshot.snapshot_parser ->
  Snapshot.snapshot_import ->
  (unit, string) result
val import_snapshot :
  (string -> (string, string) result) option ->
  string ->
  string ->
  string ->
  snapshot_metadata ->
  string ->
  (Snapshot.snapshot_completed_import, string) result
val import_snapshot_file :
  (string -> (string, string) result) option ->
  string ->
  string ->
  string ->
  snapshot_metadata ->
  string ->
  (Snapshot.snapshot_completed_import, string) result
val error_message : sync_error -> string
val apply_change_set :
  (string -> (string, string) result) ->
  Datascript.conn ->
  string ->
  sync_session_state ->
  Sync_protocol.sync_change_set ->
  (unit, string) result
