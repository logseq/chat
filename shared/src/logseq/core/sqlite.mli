(** SQLite kvs storage session and DataScript storage backend. *)

type session =
  { connection : Sqlite3.db
  ; closed : bool ref
  }

val ensure_open : session -> unit
val check_result : session -> string -> Sqlite3.Rc.t -> unit
val execute : session -> string -> unit
val close : session -> unit
val open_session : string -> session
val with_statement : session -> string -> (Sqlite3.stmt -> 'a) -> 'a
val transaction : session -> (unit -> unit) -> unit
val store_raw : session -> (string * string) list -> unit
val restore_raw : session -> string -> string option
val envelope : string -> string -> string
val decode_envelope : string -> string -> string option
val store_string : session -> string -> string -> unit
val restore_string : session -> string -> string option
val list_addresses : session -> string list
val delete_addresses : session -> string list -> unit
val decode_payload : string -> Datascript.storage_payload option
val storage : session -> Datascript.storage
val migrate_datascript_storage : session -> session -> unit
