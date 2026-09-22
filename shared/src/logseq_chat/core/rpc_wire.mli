(** JSON wire protocol for the host-facing RPC boundary. *)

val journal_page_uuid : int -> string
val journal_day_title : int -> string
val fields_of : (string * Yojson.Basic.t) list -> (string * Yojson.Basic.t) list
val outliner_structure_source : string -> string option
val outliner_structure_source_matches :
  Outliner_state.outliner_state -> string -> bool
val toolbar_action :
  string -> (Outliner_state.outliner_toolbar, string) result
val flashcard_rating :
  string -> (Flashcards.flashcard_rating, string) result
val required_string :
  (string * Yojson.Basic.t) list -> string -> (string, string) result
val optional_string :
  (string * Yojson.Basic.t) list -> string -> (string option, string) result
val required_string_list :
  string -> Yojson.Basic.t -> (string list, string) result
val decode_move : Yojson.Basic.t -> (Pending_ops.pending_move, string) result
val required_moves : Yojson.Basic.t -> (Pending_ops.pending_move list, string) result
val status_payload : Yojson.Basic.t -> (Cache_model.status, string) result
val optional_status_payload :
  Yojson.Basic.t -> (Cache_model.status option, string) result
val status_semantic_ref : Cache_model.status -> Pending_ops.semantic_value
val optional_int :
  (string * Yojson.Basic.t) list -> string -> (int option, string) result
val send_payload : string option -> (string * string option * int option, string) result
val event_int :
  (string * Yojson.Basic.t) list -> string -> (int, string) result
val drop_placement :
  string -> (Outliner_state.outliner_placement, string) result
val decode_outliner_event :
  (string * Yojson.Basic.t) list ->
  (Outliner_state.outliner_message, string) result
val outliner_message :
  string -> (Outliner_state.outliner_message, string) result
val json_strings : string list -> Yojson.Basic.t
val json_object : (string * Yojson.Basic.t) list -> Yojson.Basic.t
val json_list : Yojson.Basic.t list -> Yojson.Basic.t
val success : Yojson.Basic.t -> string
val failure : string -> string -> string
val graph_creation_payload : string -> (string * bool, string * string) result
val graph_creation_response : Api.api_response -> (string, string) result
val graph_workflow_result :
  string -> ('a, string) result -> ('a, string * string) result
val action_fields :
  string -> string -> ((string * Yojson.Basic.t) list, string * string) result
val action_response : (string, string * string) result -> string
val required_bool :
  (string * Yojson.Basic.t) list -> string -> (bool, string) result
val debug : string -> unit
val route : (unit -> string) -> (string -> string option -> string) -> Yojson.Basic.t -> string
val call :
  (unit -> string) -> (string -> string option -> string) -> string -> string
val request_json :
  int ->
  Api.api_request ->
  string option ->
  string ->
  (string * string) list ->
  Yojson.Basic.t
