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

type t =
  | Settings of settings
  | Runtime_log of runtime_log_record list
  | Local_graph_ids of string list
  | Open_capture

val decode : string -> string -> (t, string) result
