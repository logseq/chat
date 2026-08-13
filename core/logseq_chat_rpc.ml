open Yojson.Basic

module Model = Logseq_chat_model
module Api = Logseq_chat_api
module Http = Logseq_chat_http

type t =
  { model : Model.t
  ; mutable config : Api.config option
  }

let success result =
  to_string (`Assoc [ "apiVersion", `Int 1; "ok", `Bool true; "result", result; "error", `Null ])
;;

let failure ~code ~message =
  to_string
    (`Assoc
      [ "apiVersion", `Int 1
      ; "ok", `Bool false
      ; "result", `Null
      ; "error", `Assoc [ "code", `String code; "message", `String message ]
      ])
;;

let assoc name fields = List.assoc_opt name fields

let required_string name fields =
  match assoc name fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error ("field must be a string: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let optional_string name fields =
  match assoc name fields with
  | Some (`String value) -> Ok (Some value)
  | Some `Null | None -> Ok None
  | Some _ -> Error ("field must be a string: " ^ name)
;;

let block_json (block : Model.block) =
  `Assoc
    ([ "uuid", `String block.uuid
     ; "kind", `String block.kind
     ; "title", `String block.title
     ; "pageId", `String block.page_id
     ; "createdAt", `Int block.created_at
     ; "updatedAt", `Int block.updated_at
     ]
     @
     match block.parent_id with
     | Some parent_id -> [ "parentId", `String parent_id ]
     | None -> [])
;;

let snapshot session blocks =
  success
    (`Assoc
      [ "revision", `Int session.model.revision
      ; "query", `String session.model.query
      ; "blocks", `List (List.map block_json blocks)
      ; "selectedBlock",
        (match Model.selected_block session.model with
         | Some block -> block_json block
         | None -> `Null)
      ; "lastRefreshAt",
        (match session.model.last_refresh_at with
         | Some value -> `Int value
         | None -> `Null)
      ; "isSearching", `Bool (not (String.equal (String.trim session.model.query) ""))
      ])
;;

let snapshot_visible session = snapshot session (Model.visible_blocks session.model)

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let create ?storage () = { model = Model.create ?storage (); config = None }

let cache_remote_blocks session response ~now =
  if response.Api.status >= 200 && response.Api.status < 300
  then (
    let blocks = Api.blocks_from_search_body response.body in
    Model.upsert_blocks session.model blocks ~refresh_time:now;
    Ok ())
  else Error ("Logseq API returned HTTP " ^ string_of_int response.Api.status)
;;

let refresh_from_remote session config =
  let now = now_ms () in
  match Http.send (Api.recent_blocks_request config) with
  | Ok response ->
    (match cache_remote_blocks session response ~now with
     | Ok () -> snapshot_visible session
     | Error message -> failure ~code:"remote_refresh_failed" ~message)
  | Error message -> failure ~code:"remote_refresh_failed" ~message
;;

let resolve_graph session config =
  if not (String.equal (String.trim config.Api.graph_id) "")
  then Ok config
  else (
    match Http.send (Api.graphs_request config) with
    | Error message -> Error message
    | Ok response when response.Api.status < 200 || response.Api.status >= 300 ->
      Error ("Logseq graphs API returned HTTP " ^ string_of_int response.Api.status)
    | Ok response ->
      (match Api.graph_id_from_graphs_body response.body with
       | Some graph_id ->
         let config = { config with graph_id } in
         session.config <- Some config;
         Ok config
       | None -> Error "PAT does not expose any Logseq graphs"))
;;

let search_remote session config query =
  let now = now_ms () in
  match Http.send (Api.search_request config query) with
  | Ok response ->
    (match cache_remote_blocks session response ~now with
     | Ok () -> snapshot session (Model.search session.model query)
     | Error _ -> snapshot session (Model.search session.model query))
  | Error _ -> snapshot session (Model.search session.model query)
;;

let dispatch session action payload =
  match action with
  | "configure" ->
    (match payload with
     | None -> failure ~code:"invalid_params" ~message:"configure requires a JSON payload"
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          let field name =
            match List.assoc_opt name fields with
            | Some (`String value) -> Some value
            | _ -> None
          in
          (match field "baseUrl", field "graphId", field "token" with
           | Some base_url, graph_id, Some token ->
             let graph_id = Option.value graph_id ~default:"" in
             session.config <- Some { Api.base_url; graph_id; token };
             snapshot_visible session
           | _ ->
             failure
               ~code:"invalid_params"
               ~message:"configure requires baseUrl and token strings")
        | _ -> failure ~code:"invalid_params" ~message:"configure payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"configure payload must be valid JSON"))
  | "refresh" ->
    (match session.config with
     | None -> snapshot_visible session
     | Some config ->
       (match resolve_graph session config with
        | Ok config -> refresh_from_remote session config
        | Error message -> failure ~code:"graph_discovery_failed" ~message))
  | "search" ->
    let query = Option.value payload ~default:"" in
    (match session.config, String.equal (String.trim query) "" with
     | Some config, false ->
       (match resolve_graph session config with
        | Ok config -> search_remote session config query
        | Error _ -> snapshot session (Model.search session.model query))
     | _ -> snapshot session (Model.search session.model query))
  | "send" ->
    let text = Option.value payload ~default:"" |> String.trim in
    if String.equal text ""
    then snapshot_visible session
    else (
      let now = now_ms () in
      let uuid = "local-" ^ string_of_int now in
      Model.cache_local_message session.model ~uuid ~title:text ~now;
      (match session.config with
       | Some config ->
         (match resolve_graph session config with
          | Error _ -> ()
          | Ok config ->
         (match Http.send (Api.capture_request config text) with
          | Ok response when response.Api.status >= 200 && response.Api.status < 300 -> ()
          | Ok _ | Error _ -> ()))
       | None -> ());
      snapshot_visible session)
  | "updateBlock" ->
    (match payload with
     | None -> failure ~code:"invalid_params" ~message:"updateBlock requires a JSON payload"
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "uuid" fields, required_string "title" fields with
           | Ok uuid, Ok title ->
             let title = String.trim title in
             if String.equal title ""
             then failure ~code:"invalid_params" ~message:"updateBlock title must not be empty"
             else (
               match Model.update_block_title session.model ~uuid ~title ~now:(now_ms ()) with
               | Ok () ->
                 (match session.config with
                  | Some config ->
                    (match resolve_graph session config with
                     | Error _ -> ()
                     | Ok config ->
                    (match Http.send (Api.update_block_request config ~uuid ~title) with
                     | Ok response when response.Api.status >= 200 && response.Api.status < 300
                       -> ()
                     | Ok _ | Error _ -> ()))
                  | None -> ());
                 snapshot_visible session
               | Error message -> failure ~code:"unknown_block" ~message)
           | Error message, _ | _, Error message -> failure ~code:"invalid_params" ~message)
        | _ -> failure ~code:"invalid_params" ~message:"updateBlock payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"updateBlock payload must be valid JSON"))
  | "select" ->
    (match payload with
     | Some uuid ->
       (match Model.select session.model uuid with
        | Ok () -> snapshot_visible session
        | Error message -> failure ~code:"unknown_block" ~message)
     | None -> failure ~code:"invalid_params" ~message:"select requires a block uuid")
  | "clearSelection" ->
    Model.clear_selection session.model;
    snapshot_visible session
  | _ -> failure ~code:"unknown_action" ~message:("unknown action: " ^ action)
;;

let route session json =
  match json with
  | `Assoc fields ->
    (match assoc "apiVersion" fields with
     | Some (`Int 1) ->
       (match required_string "method" fields, assoc "params" fields with
        | Error message, _ -> failure ~code:"invalid_request" ~message
        | _, Some (`Assoc params) ->
          (match required_string "method" fields with
           | Error message -> failure ~code:"invalid_request" ~message
           | Ok "snapshot" -> snapshot_visible session
           | Ok "dispatch" ->
             (match required_string "action" params, optional_string "payload" params with
              | Ok action, Ok payload -> dispatch session action payload
              | Error message, _ | _, Error message -> failure ~code:"invalid_params" ~message)
           | Ok "open" -> snapshot_visible session
           | Ok method_name ->
             failure ~code:"unknown_method" ~message:("unknown method: " ^ method_name))
        | _, Some _ -> failure ~code:"invalid_request" ~message:"params must be an object"
        | _, None -> failure ~code:"invalid_request" ~message:"missing field: params")
     | Some (`Int _) -> failure ~code:"unsupported_version" ~message:"only API version 1 is supported"
     | Some _ -> failure ~code:"invalid_request" ~message:"apiVersion must be an integer"
     | None -> failure ~code:"invalid_request" ~message:"missing field: apiVersion")
  | _ -> failure ~code:"invalid_request" ~message:"request must be an object"
;;

let call session request =
  try from_string request |> route session with
  | _ -> failure ~code:"invalid_json" ~message:"request must be valid JSON"
;;
