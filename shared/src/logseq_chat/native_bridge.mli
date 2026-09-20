val send_patch_bang : string -> bool

val operating_system : int -> operating_system

val host_kind : int -> host_kind

val app : unit -> (chat_model, chat_action) reducer_app

val flush_event_bang : event -> string

val flush_action_bang : chat_action -> string

val encode_string_vector : string Rrbvec.t -> string

val encode_option_string : string option -> string

val encode_task_status : task_status -> string

val encode_asset_presentation : string -> string -> string -> string

val encode_settings : settings_projection -> string

val encode_runtime_log_record : runtime_log_record -> string

val encode_runtime_log_records : runtime_log_record Rrbvec.t -> string

val encode_effect : chat_effect -> string

val encode_effect_dispatch : chat_effect -> string -> string

val take_effect : unit -> string

val resolve_effect : int -> bool -> string -> string

val initialize : int -> int -> int -> string

val linked : unit -> bool

val appear : int -> string

val press : int -> string

val long_press : int -> string

val text_changed : int -> string -> string

val submit : int -> string

val toggle_changed : int -> bool -> string

val change : int -> string

val value_changed : int -> float -> string

val dismiss : int -> string

val double_press : int -> string

val extension_event : int -> string -> string -> string -> int -> string

val dispose : unit -> string

val root_node : unit -> int

val encode_session_asset : composer_asset -> string

val encode_session_routes : navigation_route Rrbvec.t -> string

val encode_ui_session : ui_session -> string
