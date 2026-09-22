(** DataScript transaction encoding to Transit, with E2EE of protected
    attributes. *)

val lookup_value : Datascript.entity -> string -> Datascript.value option
val stable_entity_ref : Datascript.db -> int -> Datascript.entity_ref
val transit_of_entity_ref :
  Datascript.db -> Datascript.entity_ref -> Transit_core.Json.value
val transit_of_value :
  Datascript.db -> Datascript.value -> Transit_core.Json.value
val transit_of_tx_value :
  Datascript.db -> Datascript.tx_value -> Transit_core.Json.value
val transit_of_entity :
  Datascript.db -> Datascript.tx_entity -> Transit_core.Json.value
val protected_attr : string -> bool
val encrypt_value :
  (string -> (string, string) result) ->
  string ->
  Datascript.value ->
  (Datascript.value, string) result
val encrypt_values :
  (string -> (string, string) result) ->
  string ->
  Datascript.value list ->
  (Datascript.value list, string) result
val encrypt_entity :
  (string -> (string, string) result) ->
  Datascript.tx_entity ->
  (Datascript.tx_entity, string) result
val encrypt_entities :
  (string -> (string, string) result) ->
  Datascript.tx_entity list ->
  (Datascript.tx_entity list, string) result
val encrypt_tx_value :
  (string -> (string, string) result) ->
  string ->
  Datascript.tx_value ->
  (Datascript.tx_value, string) result
val encrypt_tx_op :
  (string -> (string, string) result) ->
  Datascript.tx_op ->
  (Datascript.tx_op, string) result
val transit_of_tx_op :
  Datascript.db ->
  Datascript.tx_op ->
  (Transit_core.Json.value, string) result
val encode :
  (string -> (string, string) result) ->
  Datascript.db ->
  Datascript.tx_op list ->
  (string, string) result
