(** EDN decode/encode wrappers over melange-edn-native. *)

val decode : string -> (Melange_edn_native.any, string) result
val encode : Melange_edn_native.any -> string
