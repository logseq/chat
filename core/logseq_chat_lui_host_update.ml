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

let string_field name json = Yojson.Safe.Util.(json |> member name |> to_string)
let bool_field name json = Yojson.Safe.Util.(json |> member name |> to_bool)

let string_list json = Yojson.Safe.Util.(json |> to_list |> List.map to_string)

let settings json =
  Settings
    { appearance = string_field "appearance" json
    ; language = string_field "language" json
    ; spell_check = bool_field "spellCheck" json
    ; auto_correction = bool_field "autoCorrection" json
    ; sidebar_tabs = Yojson.Safe.Util.(json |> member "sidebarTabs" |> string_list)
    ; base_url = string_field "baseURL" json
    ; version = string_field "version" json
    ; revision = string_field "revision" json
    }
;;

let runtime_log_record json =
  { id = string_field "id" json
  ; level = string_field "level" json
  ; source = string_field "source" json
  ; timestamp = string_field "timestamp" json
  ; message = string_field "message" json
  }
;;

let decode kind payload =
  try
    let json = Yojson.Safe.from_string payload in
    match kind with
    | "settings" -> Ok (settings json)
    | "runtime-log" ->
      Ok (Runtime_log Yojson.Safe.Util.(json |> to_list |> List.map runtime_log_record))
    | "local-graph-ids" -> Ok (Local_graph_ids (string_list json))
    | _ -> Error ("Unsupported host update: " ^ kind)
  with
  | Yojson.Json_error message -> Error ("Invalid host update JSON: " ^ message)
  | Yojson.Safe.Util.Type_error (message, _) ->
    Error ("Invalid " ^ kind ^ " host update: " ^ message)
;;
