(** Transit codec for DataScript storage payloads (Logseq on-disk format). *)

type storage_index_metadata =
  { count : int
  ; shift : int
  }

type storage_root_index_metadata =
  { eavt : storage_index_metadata
  ; aevt : storage_index_metadata
  ; avet : storage_index_metadata
  }

val default_schema_attr : Datascript.schema_attr
val decode : string option -> string -> Datascript.storage_payload
val encode :
  storage_root_index_metadata option ->
  Datascript.storage_payload ->
  string * string option
