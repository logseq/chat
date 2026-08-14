open Yojson.Basic

module Model = Logseq_chat_model
module Api = Logseq_chat_api
module Http = Logseq_chat_http

type t =
  { model : Model.t
  ; mutable config : Api.config option
  ; mutable related_blocks : Model.block list
  }

let debug format =
  Printf.ksprintf
    (fun message -> prerr_endline ("LogseqChat core " ^ message))
    format
;;

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

let optional_int name fields =
  match assoc name fields with
  | Some (`Int value) -> Ok (Some value)
  | Some `Null | None -> Ok None
  | Some _ -> Error ("field must be an integer: " ^ name)
;;

let send_payload payload =
  let raw = Option.value payload ~default:"" in
  match from_string raw with
  | `Assoc fields ->
    (match required_string "text" fields, optional_string "uuid" fields, optional_int "now" fields with
     | Ok text, Ok uuid, Ok now -> Ok (String.trim text, uuid, now)
     | Error message, _, _ | _, Error message, _ | _, _, Error message -> Error message)
  | _ -> Ok (String.trim raw, None, None)
  | exception _ -> Ok (String.trim raw, None, None)
;;

let status_payload fields =
  match assoc "status" fields with
  | Some (`Assoc status) ->
    (match required_string "uuid" status, required_string "title" status,
           optional_string "ident" status, optional_string "iconType" status,
           optional_string "iconId" status, optional_string "iconColor" status with
     | Ok uuid, Ok title, Ok ident, Ok icon_type, Ok icon_id, Ok icon_color ->
       Ok Model.{ uuid; ident; title; icon_type; icon_id; icon_color }
     | Error message, _, _, _, _, _ | _, Error message, _, _, _, _
     | _, _, Error message, _, _, _ | _, _, _, Error message, _, _
     | _, _, _, _, Error message, _ | _, _, _, _, _, Error message -> Error message)
  | _ -> Error "missing field: status"
;;

let status_response_json (status : Model.status) =
  `Assoc
    ([ "uuid", `String status.uuid; "title", `String status.title ]
     @ (match status.ident with Some value -> [ "ident", `String value ] | None -> [])
     @ (match status.icon_type, status.icon_id with
        | Some icon_type, Some icon_id ->
          [ "icon", `Assoc
              ([ "type", `String icon_type; "id", `String icon_id ]
               @ (match status.icon_color with
                  | Some color -> [ "color", `String color ]
                  | None -> [])) ]
        | _ -> []))
;;

let block_json (block : Model.block) =
  let summary_json (summary : Model.entity_summary) =
    `Assoc [ "uuid", `String summary.uuid; "kind", `String summary.kind; "title", `String summary.title ]
  in
  let status_fields =
    match block.status with
    | None -> []
    | Some status ->
      [ "status", status_response_json status ]
  in
  `Assoc
    ([ "uuid", `String block.uuid
     ; "kind", `String block.kind
     ; "title", `String block.title
     ; "pageId", `String block.page_id
     ; "createdAt", `Int block.created_at
     ; "updatedAt", `Int block.updated_at
     ; "syncStatus", `String block.sync_status
     ; "tags", `List (List.map summary_json block.tags)
     ; "references", `List (List.map summary_json block.references)
     ]
     @ status_fields
     @ (match block.asset_type with Some value -> [ "assetType", `String value ] | None -> [])
     @ (match block.asset_size with Some value -> [ "assetSize", `Int value ] | None -> [])
     @ (match block.asset_checksum with Some value -> [ "assetChecksum", `String value ] | None -> [])
     @ (match block.local_path with Some value -> [ "localPath", `String value ] | None -> [])
     @
     match block.parent_id with
     | Some parent_id -> [ "parentId", `String parent_id ]
     | None -> [])
;;

let visible_block_json model (block : Model.block) =
  match Model.journal_metadata model block.page_id with
  | Some (journal_title, journal_day) ->
    (match block_json block with
     | `Assoc fields ->
       `Assoc
         (("journalTitle", `String journal_title)
          :: ("journalDay", `Int journal_day)
          :: fields)
     | json -> json)
  | None -> block_json block
;;

let snapshot session blocks =
  success
    (`Assoc
      [ "revision", `Int session.model.revision
      ; "query", `String session.model.query
      ; "blocks", `List (List.map (visible_block_json session.model) blocks)
      ; "selectedBlock",
        (match Model.selected_block session.model with
         | Some block -> block_json block
         | None -> `Null)
      ; "relatedBlocks", `List (List.map (block_json) session.related_blocks)
      ; "lastRefreshAt",
        (match session.model.last_refresh_at with
         | Some value -> `Int value
         | None -> `Null)
      ; "graphName",
        (match session.config with
         | Some { Api.graph_name = Some graph_name; _ } -> `String graph_name
         | _ -> `Null)
      ; "isSearching", `Bool (not (String.equal (String.trim session.model.query) ""))
      ; "taskStatuses", `List (List.map status_response_json (Model.all_statuses session.model))
      ])
;;

let snapshot_visible session = snapshot session (Model.visible_blocks session.model)

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let create ?storage () = { model = Model.create ?storage (); config = None; related_blocks = [] }

let cache_remote_blocks session response ~now =
  if response.Api.status >= 200 && response.Api.status < 300
  then (
    let blocks, journals =
      match Api.feed_from_body response.body with
      | feed -> feed
      | exception exn ->
        let message = Printexc.to_string exn in
        debug "remote refresh parse failed: %s" message;
        raise (Failure ("Could not parse Logseq search response: " ^ message))
    in
    List.iter
      (fun (journal : Api.journal) ->
        Model.upsert_journal_page
          ~title:journal.title
          session.model
          ~uuid:journal.uuid
          ~journal_day:journal.journal_day)
      journals;
    debug "remote refresh parsed blocks=%d" (List.length blocks);
    Model.upsert_blocks session.model blocks ~refresh_time:now;
    Ok ())
  else (
    debug "remote refresh HTTP failed status=%d" response.Api.status;
    Error ("Logseq API returned HTTP " ^ string_of_int response.Api.status))
;;

let cache_search_blocks session response ~now =
  if response.Api.status >= 200 && response.Api.status < 300
  then (
    let blocks = Api.blocks_from_search_body response.body in
    let journals = Api.journals_from_search_body response.body in
    List.iter
      (fun (journal : Api.journal) ->
        Model.upsert_journal_page
          ~title:journal.title
          session.model
          ~uuid:journal.uuid
          ~journal_day:journal.journal_day)
      journals;
    Model.upsert_blocks ~in_recent_feed:false session.model blocks ~refresh_time:now;
    Ok ())
  else Error ("Logseq API returned HTTP " ^ string_of_int response.Api.status)
;;

let cache_task_statuses session response =
  if response.Api.status >= 200 && response.Api.status < 300
  then (
    let statuses = Api.statuses_from_property_body response.body in
    debug "remote task statuses parsed count=%d" (List.length statuses);
    Model.upsert_statuses session.model statuses;
    Ok ())
  else Error ("Logseq status property returned HTTP " ^ string_of_int response.Api.status)
;;

let refresh_from_remote session config =
  let now = now_ms () in
  debug "remote refresh started graph=%s" config.Api.graph_id;
  let journal_day = Model.journal_day_for_ms now in
  match Http.send (Api.recent_blocks_request config ~journal_day) with
  | Ok response ->
    (match cache_remote_blocks session response ~now with
     | Ok () ->
       (match Http.send (Api.task_statuses_request config) with
        | Ok status_response ->
          (match cache_task_statuses session status_response with
           | Ok () -> snapshot_visible session
           | Error message -> failure ~code:"remote_statuses_failed" ~message)
        | Error message -> failure ~code:"remote_statuses_failed" ~message)
     | Error message -> failure ~code:"remote_refresh_failed" ~message)
  | Error message ->
    debug "remote refresh request failed: %s" message;
    failure ~code:"remote_refresh_failed" ~message
;;

let resolve_graph session config =
  if not (String.equal (String.trim config.Api.graph_id) "")
  then (
    debug "graph discovery skipped graph=%s" config.Api.graph_id;
    Ok config)
  else (
    debug "graph discovery started";
    match Http.send (Api.graphs_request config) with
    | Error message ->
      debug "graph discovery request failed: %s" message;
      Error message
    | Ok response when response.Api.status < 200 || response.Api.status >= 300 ->
      debug "graph discovery HTTP failed status=%d" response.Api.status;
      Error ("Logseq graphs API returned HTTP " ^ string_of_int response.Api.status)
    | Ok response ->
      (match
         try Ok (Api.graph_from_graphs_body response.body) with
         | exn -> Error (Printexc.to_string exn)
       with
       | Error message ->
         debug "graph discovery parse failed: %s" message;
         Error ("Could not parse Logseq graphs response: " ^ message)
       | Ok graph ->
         (match graph with
          | Some (graph_id, graph_name) ->
            let config = { config with graph_id; graph_name } in
            session.config <- Some config;
            debug
              "graph discovery resolved graph=%s name=%s"
              graph_id
              (Option.value graph_name ~default:"<none>");
            Ok config
          | None ->
            debug "graph discovery found no graphs";
            Error "PAT does not expose any Logseq graphs")))
;;

let search_remote session config query =
  let now = now_ms () in
  match Http.send (Api.search_request config query) with
  | Ok response ->
    (match cache_search_blocks session response ~now with
     | Ok () -> snapshot session (Model.search session.model query)
     | Error _ -> snapshot session (Model.search session.model query))
  | Error _ -> snapshot session (Model.search session.model query)
;;

let sync_pending session config =
  let pending_blocks = Model.pending_blocks session.model in
  debug "sync pending started count=%d graph=%s" (List.length pending_blocks) config.Api.graph_id;
  List.iter
    (fun (block : Model.block) ->
      let result =
        match block.kind, block.status, block.local_path, block.asset_type,
              block.asset_size, block.asset_checksum with
        | "task", Some status, _, _, _, _ ->
          Http.send (Api.task_request config ~uuid:block.uuid ~status:status.uuid block.title)
        | "asset", _, Some file_path, Some asset_type, Some asset_size, Some checksum ->
          Http.upload_file
            (Api.asset_upload_request config ~uuid:block.uuid ~file_name:block.title
               ~size:asset_size ~checksum ~file_path
               ~content_type:(Api.content_type_for_asset_type asset_type))
        | _ -> Http.send (Api.capture_request config ~uuid:block.uuid block.title)
      in
      match result with
      | Ok response when response.Api.status >= 200 && response.Api.status < 300 ->
        (try
           let remote_uuid = Api.created_block_uuid_from_body response.body in
           debug
             "sync pending creation succeeded kind=%s local_uuid=%s remote_uuid=%s status=%d"
             block.kind block.uuid remote_uuid response.Api.status;
           ignore
             (Model.reconcile_created_block
                session.model ~local_uuid:block.uuid ~remote_uuid)
         with exn ->
           debug
             "sync pending creation response failed kind=%s uuid=%s message=%s"
             block.kind block.uuid (Printexc.to_string exn);
           ignore (Model.mark_block_sync_failed session.model ~uuid:block.uuid))
      | Ok response ->
        debug "sync pending block HTTP failed uuid=%s status=%d" block.uuid response.Api.status;
        ignore (Model.mark_block_sync_failed session.model ~uuid:block.uuid)
      | Error message ->
        debug "sync pending block request failed uuid=%s message=%s" block.uuid message;
        ignore (Model.mark_block_sync_failed session.model ~uuid:block.uuid))
    pending_blocks;
  snapshot_visible session
;;

let load_related session request key =
  match Http.send request with
  | Ok response when response.Api.status >= 200 && response.Api.status < 300 ->
    session.related_blocks <- Api.blocks_from_list_body key response.body;
    snapshot_visible session
  | Ok response ->
    debug "related blocks HTTP failed status=%d" response.Api.status;
    session.related_blocks <- [];
    snapshot_visible session
  | Error message ->
    debug "related blocks request failed message=%s" message;
    session.related_blocks <- [];
    snapshot_visible session
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
             session.config <- Some { Api.base_url; graph_id; graph_name = None; token };
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
  | "searchLocal" ->
    let query = Option.value payload ~default:"" in
    snapshot session (Model.search session.model query)
  | "send" ->
    (match send_payload payload with
     | Error message -> failure ~code:"invalid_params" ~message
     | Ok (text, uuid, now) ->
       if String.equal text ""
       then snapshot_visible session
       else (
         let now = Option.value now ~default:(now_ms ()) in
         let uuid = Option.value uuid ~default:("local-" ^ string_of_int now) in
         Model.cache_local_message session.model ~uuid ~title:text ~now;
         snapshot_visible session))
  | "sendTask" ->
    (match payload with
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "text" fields, required_string "uuid" fields,
                 optional_int "now" fields, status_payload fields with
           | Ok text, Ok uuid, Ok now, Ok status ->
             let text = String.trim text in
             if text = "" then snapshot_visible session
             else (
               Model.cache_local_task session.model ~uuid ~title:text ~status
                 ~now:(Option.value now ~default:(now_ms ()));
               snapshot_visible session)
           | Error message, _, _, _ | _, Error message, _, _
           | _, _, Error message, _ | _, _, _, Error message ->
             failure ~code:"invalid_params" ~message)
        | _ -> failure ~code:"invalid_params" ~message:"sendTask payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"sendTask payload must be valid JSON")
     | None -> failure ~code:"invalid_params" ~message:"sendTask requires a JSON payload")
  | "addAsset" ->
    (match payload with
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "uuid" fields, required_string "title" fields,
                 optional_int "now" fields, required_string "assetType" fields,
                 optional_int "assetSize" fields, required_string "assetChecksum" fields,
                 required_string "localPath" fields with
           | Ok uuid, Ok title, Ok now, Ok asset_type, Ok (Some asset_size),
             Ok asset_checksum, Ok local_path ->
             Model.cache_local_asset session.model ~uuid ~title ~asset_type ~asset_size
               ~asset_checksum ~local_path ~now:(Option.value now ~default:(now_ms ()));
             snapshot_visible session
           | _ -> failure ~code:"invalid_params" ~message:"addAsset requires complete file metadata")
        | _ -> failure ~code:"invalid_params" ~message:"addAsset payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"addAsset payload must be valid JSON")
     | None -> failure ~code:"invalid_params" ~message:"addAsset requires a JSON payload")
  | "syncPending" ->
    (match session.config with
     | None -> snapshot_visible session
     | Some config ->
       (match resolve_graph session config with
        | Ok config -> sync_pending session config
       | Error _ -> snapshot_visible session))
  | "loadBlockReferences" ->
    (match session.config, payload with
     | Some config, Some uuid ->
       (match resolve_graph session config with
        | Ok config -> load_related session (Api.block_references_request config uuid) "references"
        | Error _ -> snapshot_visible session)
     | _ -> snapshot_visible session)
  | "loadPageReferences" ->
    (match session.config, payload with
     | Some config, Some uuid ->
       (match resolve_graph session config with
        | Ok config -> load_related session (Api.page_references_request config uuid) "references"
        | Error _ -> snapshot_visible session)
     | _ -> snapshot_visible session)
  | "loadTagObjects" ->
    (match session.config, payload with
     | Some config, Some uuid ->
       (match resolve_graph session config with
        | Ok config -> load_related session (Api.tag_objects_request config uuid) "objects"
        | Error _ -> snapshot_visible session)
     | _ -> snapshot_visible session)
  | "clearRelated" ->
    session.related_blocks <- [];
    snapshot_visible session
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
