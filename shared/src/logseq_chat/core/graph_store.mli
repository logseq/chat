(** SQLite-backed DataScript storage and snapshot staging. *)

val staging_path : string -> string
val begin_import : string -> (unit, string) result
val append_rows : string -> Snapshot.snapshot_row list -> (unit, string) result
val activate : string -> (unit, string) result
val read_row : string -> int -> ((string * string option) option, string) result
val int_of_address : string -> int
val storage_with_paths : string -> string -> Datascript.storage
val storage : string -> Datascript.storage
val import_storage : string -> Datascript.storage
val restore_db : string -> (Datascript.db, string) result
val restore_conn : string -> (Datascript.conn, string) result
