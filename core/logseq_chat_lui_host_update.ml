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

let authentication json =
  Authentication
    { state = string_field "state" json
    ; error_message = Yojson.Safe.Util.(json |> member "errorMessage" |> to_string_option)
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
    | "composer-asset" ->
      Ok (Composer_asset { uuid = string_field "uuid" json; title = string_field "title" json;
                           local_path = string_field "localPath" json; payload })
    | "save-ui-session" -> Ok Save_ui_session
    | "restore-ui-session" ->
      Ok (Restore_ui_session
        { graph_id = Yojson.Safe.Util.(json |> member "graphId" |> to_string_option)
        ; destination = string_field "destination" json
        ; draft = string_field "draft" json
        ; assets = Yojson.Safe.Util.(json |> member "assets" |> to_list)
            |> List.map (fun asset ->
                 { uuid = string_field "uuid" asset; title = string_field "title" asset;
                   local_path = string_field "localPath" asset; payload = string_field "payload" asset })
        ; composer_expanded = bool_field "composerExpanded" json
        ; search_open = bool_field "searchOpen" json
        ; query = string_field "query" json
        ; app_path = Yojson.Safe.Util.(json |> member "appPath" |> string_list)
        ; search_path = Yojson.Safe.Util.(json |> member "searchPath" |> string_list)
        ; selected_page_id = Yojson.Safe.Util.(json |> member "selectedPageId" |> to_string_option)
        ; settings_open = bool_field "settingsOpen" json
        })
    | "composer-draft" -> Ok (Composer_draft Yojson.Safe.Util.(json |> to_string))
    | "graph-loading" -> Ok (Graph_loading Yojson.Safe.Util.(json |> to_bool))
    | "authentication" -> Ok (authentication json)
    | "open-quick-action" -> Ok (Open_quick_action Yojson.Safe.Util.(json |> to_string))
    | "open-capture" -> Ok Open_capture
    | _ -> Error ("Unsupported host update: " ^ kind)
  with
  | Yojson.Json_error message -> Error ("Invalid host update JSON: " ^ message)
  | Yojson.Safe.Util.Type_error (message, _) ->
    Error ("Invalid " ^ kind ^ " host update: " ^ message)
;;
