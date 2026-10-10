(** Canonical graph bootstrap: schema, initial tx validation, and framed
    snapshot preparation. *)

type prepared_snapshot =
  { file_path : string
  ; row_count : int
  ; checksum : string
  }

val schema_version : string
val initial_checksum : string
val fresh_local_graph_uuid : unit -> string
val schema : Datascript.schema
val native_schema : Datascript.schema
val kv : string -> Datascript.value -> Datascript.tx_op
val graph_metadata : string -> bool -> int -> Datascript.tx_op list
val scalar_tx_value : Datascript.tx_value -> Datascript.value
val normalize_scalar_maps : Datascript.tx_op -> Datascript.tx_op
val valid_ref_value : Datascript.value -> bool
val validate_ref_values : Datascript.tx_op -> unit
val unique_identity_attr : string -> bool
val identity_only : Datascript.tx_op -> Datascript.tx_op option
val schema_definition_attr : string -> bool
val schema_definition_only : Datascript.tx_op -> Datascript.tx_op option
val unique_ref_key : Datascript.schema -> Datascript.value -> bool
val lookup_ref_collection : Datascript.schema -> Datascript.value list -> bool
val normalize_many_attributes :
  Datascript.schema -> Datascript.tx_op -> Datascript.tx_op
val refresh_initial_timestamps : int -> Datascript.tx_op -> Datascript.tx_op
val encrypt_database :
  (string -> (string, string) result) ->
  Datascript.db ->
  (Datascript.datom list, string) result
val install_canonical_entities :
  Datascript.tx_op list -> Datascript.storage -> Datascript.db
val database :
  string ->
  bool ->
  (string -> (string, string) result) ->
  (Datascript.db, string) result
val index_shift : Datascript.storage -> string -> int
val root_index_metadata :
  Datascript.db ->
  Datascript.storage ->
  Datascript.storage_root ->
  Storage_codec.storage_root_index_metadata
val storage_row :
  Datascript.db -> Datascript.storage -> string -> Snapshot.snapshot_row
val snapshot_rows :
  Datascript.db -> (Snapshot.snapshot_row list, string) result
val frame_rows : Snapshot.snapshot_row list -> string
val prepare :
  string ->
  bool ->
  (string -> (string, string) result) ->
  (prepared_snapshot, string) result
