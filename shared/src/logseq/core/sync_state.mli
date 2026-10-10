(** Change-set validation shared by the sync protocol and its tests. *)

val apply_change_set_error :
  string -> string -> int -> int -> string -> string -> int -> int -> string option
