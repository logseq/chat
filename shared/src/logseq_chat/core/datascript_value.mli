(** DataScript value helpers shared by readers and projections. *)

val built_in_ref_attrs : string list
val built_in_ref_attr : string -> bool
val value_type_is_ref : Datascript.db -> Datascript.value -> bool
val entity_declares_ref : Datascript.db -> string -> bool
val is_ref_attr : Datascript.db -> string -> bool
val ref_eid : Datascript.db -> string -> Datascript.value -> int option
val optional_ref_eid : Datascript.db -> string -> Datascript.value option -> int option
val datoms_by_ref : Datascript.db -> Datascript.index -> string -> int -> Datascript.datom Seq.t
