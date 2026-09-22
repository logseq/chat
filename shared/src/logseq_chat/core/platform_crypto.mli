(** JSON-RPC bridge to the host platform's crypto implementation. *)

val hex : string -> string
val unhex : string -> (string, string) result
val invoke :
  (string -> string) ->
  string ->
  (string * Yojson.Basic.t) list ->
  (Yojson.Basic.t, string) result
val crypto : (string -> string) -> E2ee.e2ee_crypto
val save_graph_key : (string -> string) -> string -> string -> (unit, string) result
val load_graph_key :
  (string -> string) -> string -> (string option, string) result
val save_e2ee_password : (string -> string) -> string -> (unit, string) result
val load_e2ee_password : (string -> string) -> (string option, string) result
val create_keyring :
  (string -> string) ->
  (Api.api_request -> (Api.api_response, string) result) ->
  E2ee_keyring.e2ee_keyring
