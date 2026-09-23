(** Fractional-order key generation (Logseq "order" attr values). *)

val digits : string
val zero : string
val lowercase : string
val uppercase : string
val minimum : string
val index_of_in : string -> string -> int option
val index_of : string -> int option
val suffix : string -> int -> string
val integer_length : string -> (int, string) result
val integer_part : string -> (string, string) result
val validate_integer_error : string -> string option
val validate_error : string -> string option
val validate_optional_error : string option -> string option
val increment : string -> (string option, string) result
val decrement : string -> (string option, string) result
val midpoint : string -> string option -> (string, string) result
val between : string option -> string option -> (string, string) result
val n_after : string option -> int -> (string list, string) result
val n_before : string option -> int -> (string list, string) result
val n_between :
  string option -> string option -> int -> (string list, string) result
