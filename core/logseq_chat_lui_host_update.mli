type composer_asset =
  { uuid : string; title : string; local_path : string; payload : string }

type ui_session =
  { graph_id : string option
  ; destination : string
  ; draft : string
  ; assets : composer_asset list
  ; composer_expanded : bool
  ; search_open : bool
  ; query : string
  ; app_path : string list
  ; search_path : string list
  ; selected_page_id : string option
  ; settings_open : bool
  }

type settings =
  { appearance : string
  ; language : string
  ; spell_check : bool
  ; auto_correction : bool
  ; sidebar_tabs : string list
  ; base_url : string
  ; version : string
  ; revision : string
  }

type runtime_log_record =
  { id : string
  ; level : string
  ; source : string
  ; timestamp : string
  ; message : string
  }

type authentication =
  { state : string
  ; error_message : string option
  }

type t =
  | Settings of settings
  | Runtime_log of runtime_log_record list
  | Local_graph_ids of string list
  | Save_ui_session
  | Restore_ui_session of ui_session
  | Composer_draft of string
  | Composer_asset of composer_asset
  | Graph_loading of bool
  | Authentication of authentication
  | Open_quick_action of string
  | Open_capture

val decode : string -> string -> (t, string) result
