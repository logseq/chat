(** Rewrite [[ref titles]] and #tag text to plain text or canonical uuid refs. *)

type text_step =
  { step_index : int
  ; step_result : string
  }

val is_uuid : string -> bool
val to_text :
  (string -> string option) -> (string -> string option) -> string -> string
val to_ids :
  (string -> string option) -> (string -> string option) -> string -> string
