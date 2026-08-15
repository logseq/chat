open Yojson.Basic

module Model = Logseq_chat_model
module Api = Logseq_chat_api
module Http = Logseq_chat_http

type t =
  { model : Model.t
  ; mutable config : Api.config option
  ; mutable available_graphs : Api.graph list
  ; mutable related_blocks : Model.block list
  ; open_graph : (string -> (unit, string) result) option
  ; import_snapshot : (string -> (unit, string) result) option
  ; start_sse : (unit -> unit) option
  ; feed_sse : (string -> (unit, string) result) option
  ; sync_cursor : (unit -> int option) option
  ; graph_blocks : (unit -> Model.block list option) option
  ; load_cached_graph_key : (graph_id:string -> (unit, string) result) option
  ; unlock_graph : (Api.config -> password:string -> (unit, string) result) option
  ; graph_unlocked : (graph_id:string -> bool) option
  ; encrypt_title : (graph_id:string -> string -> (string, string) result) option
  ; encrypt_asset_file : (graph_id:string -> source_path:string -> (string * int, string) result) option
  ; journal_page_id : (journal_day:int -> string option) option
  ; send : Api.request -> (Api.response, string) result
  ; upload_file : Api.file_upload -> (Api.response, string) result
  ; cleanup_file : string -> unit
  ; mutable sync_connected : bool
  ; mutable sync_in_progress : bool
  ; save_graph_catalog : (string -> unit) option
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

let optional_status_payload fields =
  match assoc "status" fields with
  | None | Some `Null -> Ok None
  | Some _ -> Result.map Option.some (status_payload fields)
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
     @ (match block.order with Some value -> [ "order", `String value ] | None -> [])
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
  let journal =
    match block.journal with
    | Some _ as journal -> journal
    | None -> Model.journal_metadata model block.page_id
  in
  match journal with
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

let graph_json (graph : Api.graph) =
  `Assoc
    [ "id", `String graph.id
    ; "name", `String graph.name
    ; "isEncrypted", `Bool graph.e2ee
    ; "isReady", `Bool graph.ready
    ]
;;

let selected_graph session =
  match session.config with
  | Some config ->
    List.find_opt
      (fun (graph : Api.graph) -> String.equal graph.id config.graph_id)
      session.available_graphs
  | None -> None
;;

let selected_graph_is_encrypted session =
  Option.fold ~none:false ~some:(fun (graph : Api.graph) -> graph.e2ee) (selected_graph session)
;;

let selected_graph_is_unlocked session =
  match session.config, selected_graph session with
  | _, Some graph when not graph.e2ee -> true
  | Some config, Some _ ->
    Option.fold
      ~none:false
      ~some:(fun graph_unlocked -> graph_unlocked ~graph_id:config.graph_id)
      session.graph_unlocked
  | _ -> false
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
      ; "selectedGraphId",
        (match session.config with
         | Some { Api.graph_id; _ } when not (String.equal graph_id "") -> `String graph_id
         | _ -> `Null)
      ; "graphs", `List (List.map graph_json session.available_graphs)
      ; "isGraphEncrypted", `Bool (selected_graph_is_encrypted session)
      ; "isGraphUnlocked", `Bool (selected_graph_is_unlocked session)
      ; "appliedServerT",
        (match session.sync_cursor with
         | Some cursor -> Option.fold ~none:`Null ~some:(fun value -> `Int value) (cursor ())
         | None -> `Null)
      ; "syncConnected", `Bool session.sync_connected
      ; "isSearching", `Bool (not (String.equal (String.trim session.model.query) ""))
      ; "taskStatuses", `List (List.map status_response_json (Model.all_statuses session.model))
      ])
;;

let snapshot_visible session =
  let blocks =
    match session.graph_blocks with
    | Some graph_blocks ->
      (match graph_blocks () with
     | Some blocks ->
       let graph_uuids = Hashtbl.create (List.length blocks) in
       List.iter
         (fun (block : Model.block) -> Hashtbl.replace graph_uuids block.uuid ())
         blocks;
       let unsynced = Model.unsynced_blocks session.model in
       let local_by_uuid = Hashtbl.create (List.length unsynced) in
       List.iter
         (fun (block : Model.block) -> Hashtbl.replace local_by_uuid block.uuid block)
         (Model.all_blocks session.model);
       let unsynced_by_uuid = Hashtbl.create (List.length unsynced) in
       List.iter
         (fun (block : Model.block) -> Hashtbl.replace unsynced_by_uuid block.uuid block)
         unsynced;
       let merged_graph_blocks =
         List.map
           (fun (block : Model.block) ->
             match Hashtbl.find_opt unsynced_by_uuid block.uuid with
             | Some local -> local
             | None ->
               (match Hashtbl.find_opt local_by_uuid block.uuid with
                | Some local when Option.is_some local.local_path ->
                  { block with
                    kind = local.kind
                  ; asset_type = local.asset_type
                  ; asset_size = local.asset_size
                  ; asset_checksum = local.asset_checksum
                  ; local_path = local.local_path
                  }
                | _ -> block))
           blocks
       in
       let local_only =
         List.filter
           (fun (block : Model.block) -> not (Hashtbl.mem graph_uuids block.uuid))
           unsynced
       in
       merged_graph_blocks @ local_only
       | None -> Model.visible_blocks session.model)
    | None -> Model.visible_blocks session.model
  in
  let query = String.trim session.model.query |> String.lowercase_ascii in
  let blocks =
    if String.equal query ""
    then Model.visible_from session.model blocks
    else
      List.filter
        (fun (block : Model.block) ->
          let title = String.lowercase_ascii block.title in
          try
            ignore (Str.search_forward (Str.regexp_string query) title 0);
            true
          with Not_found -> false)
        blocks
  in
  snapshot session blocks
;;

let reconcile_authoritative_blocks session =
  match session.graph_blocks with
  | None -> ()
  | Some graph_blocks ->
    (match graph_blocks () with
     | None -> ()
     | Some blocks ->
       let authoritative_by_uuid = Hashtbl.create (List.length blocks) in
       List.iter
         (fun (block : Model.block) -> Hashtbl.replace authoritative_by_uuid block.uuid block)
         blocks;
       let same_status left right =
         match left, right with
         | None, None -> true
         | Some (left : Model.status), Some (right : Model.status) ->
           String.equal left.uuid right.uuid
         | _ -> false
       in
       Model.unsynced_blocks session.model
       |> List.iter (fun (block : Model.block) ->
         match Hashtbl.find_opt authoritative_by_uuid block.uuid with
         | Some authoritative when
             String.equal block.sync_status "submitted"
             || (String.equal block.title authoritative.title
                 && same_status block.status authoritative.status) ->
           ignore (Model.mark_block_synced session.model ~uuid:block.uuid)
         | Some _ | None -> ()))
;;

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let create
      ?storage
      ?open_graph
      ?import_snapshot
      ?start_sse
      ?feed_sse
      ?sync_cursor
      ?graph_blocks
      ?load_cached_graph_key
      ?unlock_graph
      ?graph_unlocked
      ?encrypt_title
      ?encrypt_asset_file
      ?journal_page_id
      ?(send = Http.send)
      ?(upload_file = Http.upload_file)
      ?(cleanup_file = fun path -> try Sys.remove path with _ -> ())
      ?load_graph_catalog
      ?save_graph_catalog
      ()
  =
  let model = Model.create ?storage () in
  let available_graphs =
    match Option.bind load_graph_catalog (fun load -> load ()) with
    | Some body ->
      (try Api.graphs_from_graphs_body body with
       | _ -> [])
    | None -> []
  in
  { model
  ; config = None
  ; available_graphs
  ; related_blocks = []
  ; open_graph
  ; import_snapshot
  ; start_sse
  ; feed_sse
  ; sync_cursor
  ; graph_blocks
  ; load_cached_graph_key
  ; unlock_graph
  ; graph_unlocked
  ; encrypt_title
  ; encrypt_asset_file
  ; journal_page_id
  ; send
  ; upload_file
  ; cleanup_file
  ; sync_connected = false
  ; sync_in_progress = false
  ; save_graph_catalog
  }
;;

let discover_graphs session config =
  debug "graph discovery started";
  match session.send (Api.graphs_request config) with
  | Error message -> Error message
  | Ok response when response.Api.status < 200 || response.Api.status >= 300 ->
    Error ("Logseq graphs API returned HTTP " ^ string_of_int response.Api.status)
  | Ok response ->
    (try
       session.available_graphs <- Api.graphs_from_graphs_body response.body;
       Option.iter (fun save -> save response.body) session.save_graph_catalog;
       Ok ()
     with exn -> Error ("Could not parse Logseq graphs response: " ^ Printexc.to_string exn))
;;

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
  match session.send (Api.recent_blocks_request config ~journal_day) with
  | Ok response ->
    (match cache_remote_blocks session response ~now with
     | Ok () ->
       (match session.send (Api.task_statuses_request config) with
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

let resolve_graph _session config =
  if not (String.equal (String.trim config.Api.graph_id) "")
  then (
    debug "graph discovery skipped graph=%s" config.Api.graph_id;
    Ok config)
  else Error "Select a Logseq graph before syncing"
;;

let update_remote_block_status session config ~uuid (status : Model.status) =
  match resolve_graph session config with
  | Error message -> Error message
  | Ok config ->
    (match session.send (Api.update_block_status_request config ~uuid ~status:status.uuid) with
     | Ok response when response.Api.status >= 200 && response.Api.status < 300 -> Ok ()
     | Ok response ->
       debug "update block status HTTP failed uuid=%s status=%d" uuid response.Api.status
       ; Error ("Logseq status API returned HTTP " ^ string_of_int response.Api.status)
     | Error message ->
       debug "update block status request failed uuid=%s message=%s" uuid message;
       Error message)
;;

let save_remote_block session config (block : Model.block) =
  let title =
    if selected_graph_is_encrypted session
    then
      (match session.encrypt_title with
       | Some encrypt -> encrypt ~graph_id:config.Api.graph_id block.title
       | None -> Error "encrypted graph title encryption is unavailable")
    else Ok block.title
  in
  match title with
  | Error _ as error -> error
  | Ok title ->
  match session.send (Api.update_block_request config ~uuid:block.uuid ~title) with
  | Error message -> Error message
  | Ok response when response.Api.status < 200 || response.Api.status >= 300 ->
    Error ("Logseq block API returned HTTP " ^ string_of_int response.Api.status)
  | Ok _ ->
    (match block.status with
     | None -> Ok ()
     | Some status -> update_remote_block_status session config ~uuid:block.uuid status)
;;

let search_remote session config query =
  let now = now_ms () in
  match session.send (Api.search_request config query) with
  | Ok response ->
    (match cache_search_blocks session response ~now with
     | Ok () -> snapshot session (Model.search session.model query)
     | Error _ -> snapshot session (Model.search session.model query))
  | Error _ -> snapshot session (Model.search session.model query)
;;

let journal_page_uuid journal_day =
  let year = journal_day / 10_000 in
  let month_and_day = journal_day mod 10_000 in
  Printf.sprintf "00000001-%04d-%04d-0000-000000000000" year month_and_day
;;

let journal_day_title journal_day =
  let month_names =
    [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"
     ; "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec"
    |]
  in
  let year = journal_day / 10_000 in
  let month = (journal_day / 100) mod 100 in
  let day = journal_day mod 100 in
  let suffix =
    if day mod 100 >= 11 && day mod 100 <= 13
    then "th"
    else
      match day mod 10 with
      | 1 -> "st"
      | 2 -> "nd"
      | 3 -> "rd"
      | _ -> "th"
  in
  let month_name =
    if month >= 1 && month <= Array.length month_names
    then month_names.(month - 1)
    else invalid_arg "invalid journal month"
  in
  Printf.sprintf "%s %d%s, %04d" month_name day suffix year
;;

let create_encrypted_journal_page session config ~journal_day =
  match session.encrypt_title with
  | None -> Error "encrypted graph title encryption is unavailable"
  | Some encrypt_title ->
    let page_id = journal_page_uuid journal_day in
    let title = journal_day_title journal_day in
    (match
       encrypt_title ~graph_id:config.Api.graph_id title,
       encrypt_title ~graph_id:config.Api.graph_id (String.lowercase_ascii title)
     with
     | Error message, _ | _, Error message -> Error message
     | Ok encrypted_title, Ok encrypted_name ->
       (match
          session.send
            (Api.encrypted_journal_page_request
               config
               ~uuid:page_id
               ~title:encrypted_title
               ~name:encrypted_name
               ~journal_day)
        with
        | Ok response when response.Api.status >= 200 && response.Api.status < 300 -> Ok page_id
        | Ok response ->
          Error
            ("Logseq encrypted journal page API returned HTTP "
             ^ string_of_int response.Api.status)
        | Error _ as error -> error))
;;

let sync_pending_unlocked session config =
  let pending_blocks = Model.pending_blocks session.model in
  let resolved_journal_pages = Hashtbl.create 8 in
  let resolve_journal_page journal_day =
    match Hashtbl.find_opt resolved_journal_pages journal_day with
    | Some page_id -> Ok page_id
    | None ->
      let result =
        match session.journal_page_id with
        | None -> Error "encrypted graph journal lookup is unavailable"
        | Some journal_page_id ->
          (match journal_page_id ~journal_day with
           | Some page_id -> Ok page_id
           | None -> create_encrypted_journal_page session config ~journal_day)
      in
      (match result with
       | Ok page_id -> Hashtbl.replace resolved_journal_pages journal_day page_id
       | Error _ -> ());
      result
  in
  let authoritative_uuids = Hashtbl.create 64 in
  Option.iter
    (fun blocks ->
      List.iter
        (fun (block : Model.block) -> Hashtbl.replace authoritative_uuids block.uuid ())
        blocks)
    (Option.bind session.graph_blocks (fun graph_blocks -> graph_blocks ()));
  debug "sync pending started count=%d graph=%s" (List.length pending_blocks) config.Api.graph_id;
  List.iter
    (fun (block : Model.block) ->
      if Hashtbl.mem authoritative_uuids block.uuid
      then (
        match save_remote_block session config block with
        | Ok () ->
          debug "sync pending update succeeded uuid=%s" block.uuid;
          ignore (Model.mark_block_submitted session.model ~uuid:block.uuid)
        | Error message ->
          debug "sync pending update failed uuid=%s message=%s" block.uuid message;
          ignore (Model.mark_block_sync_failed session.model ~uuid:block.uuid))
      else (
        let result =
          if selected_graph_is_encrypted session
          then (
            let journal_day = Model.journal_day_for_ms block.created_at in
            match session.encrypt_title with
            | Some encrypt_title ->
              (match encrypt_title ~graph_id:config.Api.graph_id block.title with
               | Error message -> Error message
               | Ok title ->
                 (match resolve_journal_page journal_day with
                  | Error message -> Error message
                  | Ok page_id ->
                 (match block.kind, block.status, block.local_path, block.asset_type,
                        block.asset_size, block.asset_checksum with
                  | "block", _, _, _, _, _ ->
                    session.send
                      (Api.capture_request ~page_id config ~uuid:block.uuid title)
                  | "task", Some status, _, _, _, _ ->
                    session.send
                      (Api.task_request ~page_id config ~uuid:block.uuid
                         ~status:status.uuid title)
                  | "asset", _, Some source_path, Some _asset_type, Some asset_size,
                    Some checksum ->
                    (match session.encrypt_asset_file with
                     | None -> Error "encrypted asset encryption is unavailable"
                     | Some encrypt_asset_file ->
                       (match encrypt_asset_file ~graph_id:config.graph_id ~source_path with
                        | Error _ as error -> error
                        | Ok (file_path, upload_size) ->
                          Fun.protect
                            ~finally:(fun () -> session.cleanup_file file_path)
                            (fun () ->
                              session.upload_file
                                (Api.encrypted_asset_upload_request
                                   config
                                   ~uuid:block.uuid
                                   ~file_name:block.title
                                   ~title
                                   ~page_id
                                   ~size:asset_size
                                   ~upload_size
                                   ~checksum
                                   ~file_path))))
                  | _ ->
                    session.send
                      (Api.capture_request ~page_id config ~uuid:block.uuid title))))
            | None -> Error "encrypted graph write support is unavailable")
          else
            match block.kind, block.status, block.local_path, block.asset_type,
                  block.asset_size, block.asset_checksum with
            | "block", _, _, _, _, _ ->
              session.send (Api.capture_request config ~uuid:block.uuid block.title)
            | "task", Some status, _, _, _, _ ->
              session.send (Api.task_request config ~uuid:block.uuid ~status:status.uuid block.title)
            | "asset", _, Some file_path, Some asset_type, Some asset_size, Some checksum ->
              session.upload_file
                (Api.asset_upload_request config ~uuid:block.uuid ~file_name:block.title
                   ~size:asset_size ~checksum ~file_path
                   ~content_type:(Api.content_type_for_asset_type asset_type))
            | _ ->
              session.send (Api.capture_request config ~uuid:block.uuid block.title)
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
    )
    pending_blocks;
  snapshot_visible session
;;

let sync_pending session config =
  if session.sync_in_progress
  then snapshot_visible session
  else (
    session.sync_in_progress <- true;
    Fun.protect
      ~finally:(fun () -> session.sync_in_progress <- false)
      (fun () -> sync_pending_unlocked session config))
;;

let load_related session request key =
  match session.send request with
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
             let graph_name =
               match Option.map String.trim (field "graphName") with
               | Some value when not (String.equal value "") -> Some value
               | Some _ | None ->
                 List.find_opt
                   (fun (graph : Api.graph) -> String.equal graph.id graph_id)
                   session.available_graphs
                 |> Option.map (fun (graph : Api.graph) -> graph.name)
             in
             session.config <- Some { Api.base_url; graph_id; graph_name; token };
             (match
                List.find_opt
                  (fun (graph : Api.graph) -> String.equal graph.id graph_id && graph.e2ee)
                  session.available_graphs,
                session.load_cached_graph_key
              with
              | Some _, Some load -> ignore (load ~graph_id)
              | _ -> ());
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
     | Some config when String.equal (String.trim config.Api.graph_id) "" ->
       (match discover_graphs session config with
        | Ok () -> snapshot_visible session
        | Error message -> failure ~code:"graph_discovery_failed" ~message)
     | Some _config when selected_graph_is_encrypted session ->
       if selected_graph_is_unlocked session
       then snapshot_visible session
       else failure ~code:"encrypted_graph_locked" ~message:"Unlock the encrypted graph first"
     | Some config -> refresh_from_remote session config)
  | "refreshGraphCatalog" ->
    (match session.config with
     | None -> snapshot_visible session
     | Some config ->
       (match discover_graphs session config with
        | Ok () ->
          let graph_name =
            List.find_opt
              (fun (graph : Api.graph) -> String.equal graph.id config.graph_id)
              session.available_graphs
            |> Option.map (fun (graph : Api.graph) -> graph.name)
          in
          session.config <- Some { config with graph_name };
          snapshot_visible session
        | Error message ->
          debug "graph catalog refresh failed: %s" message;
          snapshot_visible session))
  | "selectGraph" ->
    (match session.config, payload with
     | Some config, Some graph_id ->
       (match List.find_opt (fun (graph : Api.graph) -> String.equal graph.id graph_id) session.available_graphs with
        | None -> failure ~code:"unknown_graph" ~message:"The selected graph is not available"
        | Some graph when not graph.ready ->
          failure ~code:"graph_not_ready" ~message:"The selected graph is not ready for sync"
        | Some graph ->
          session.config <- Some { config with graph_id = graph.id; graph_name = Some graph.name };
          if graph.e2ee
          then
            Option.iter
              (fun load -> ignore (load ~graph_id:graph.id))
              session.load_cached_graph_key;
          snapshot_visible session)
     | _ -> failure ~code:"invalid_params" ~message:"selectGraph requires a graph id")
  | "unlockGraph" ->
    (match session.config, session.unlock_graph, payload with
     | Some config, Some unlock_graph, Some password when selected_graph_is_encrypted session ->
       (match unlock_graph config ~password with
        | Ok () -> snapshot_visible session
        | Error message -> failure ~code:"graph_unlock_failed" ~message)
     | Some _, _, _ when not (selected_graph_is_encrypted session) -> snapshot_visible session
     | _, None, _ -> failure ~code:"graph_unlock_unavailable" ~message:"Graph unlock is unavailable"
     | _ -> failure ~code:"invalid_params" ~message:"unlockGraph requires a selected graph and password")
  | "importSnapshot" ->
    (match session.import_snapshot, payload with
     | Some import_snapshot, Some payload ->
       (match import_snapshot payload with
        | Ok () -> snapshot_visible session
        | Error message -> failure ~code:"snapshot_import_failed" ~message)
     | None, _ -> failure ~code:"snapshot_import_unavailable" ~message:"Snapshot import is unavailable"
     | _, None -> failure ~code:"invalid_params" ~message:"importSnapshot requires a JSON payload")
  | "openGraph" ->
    (match session.open_graph, payload with
     | Some open_graph, Some payload ->
       (match open_graph payload with
        | Ok () -> snapshot_visible session
        | Error message -> failure ~code:"graph_open_failed" ~message)
     | None, _ -> failure ~code:"graph_open_unavailable" ~message:"Graph storage is unavailable"
     | _, None -> failure ~code:"invalid_params" ~message:"openGraph requires a JSON payload")
  | "startSSE" ->
    (match session.start_sse with
     | Some start_sse ->
       start_sse ();
       session.sync_connected <- true;
       snapshot_visible session
     | None -> failure ~code:"sse_unavailable" ~message:"SSE sync is unavailable")
  | "feedSSE" ->
    (match session.feed_sse, payload with
     | Some feed_sse, Some chunk ->
       (match feed_sse chunk with
        | Ok () ->
          reconcile_authoritative_blocks session;
          snapshot_visible session
        | Error message ->
          let code =
            if String.starts_with ~prefix:"snapshot required:" message
            then "snapshot_required"
            else "sse_apply_failed"
          in
          failure ~code ~message)
     | None, _ -> failure ~code:"sse_unavailable" ~message:"SSE sync is unavailable"
     | _, None -> failure ~code:"invalid_params" ~message:"feedSSE requires a raw chunk")
  | "stopSSE" ->
    session.sync_connected <- false;
    snapshot_visible session
  | "search" ->
    let query = Option.value payload ~default:"" in
    (match session.config, String.equal (String.trim query) "" with
     | Some _config, false when selected_graph_is_encrypted session ->
       snapshot session (Model.search session.model query)
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
  | "updateBlockStatus" ->
    (match payload with
     | None -> failure ~code:"invalid_params" ~message:"updateBlockStatus requires a JSON payload"
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "uuid" fields, status_payload fields with
           | Ok uuid, Ok status ->
             (match Model.update_block_status session.model ~uuid ~status ~now:(now_ms ()) with
             | Error message -> failure ~code:"unknown_block" ~message
             | Ok () ->
                snapshot_visible session)
           | Error message, _ | _, Error message ->
             failure ~code:"invalid_params" ~message)
        | _ -> failure ~code:"invalid_params" ~message:"updateBlockStatus payload must be an object"
        | exception _ ->
          failure ~code:"invalid_json" ~message:"updateBlockStatus payload must be valid JSON"))
  | "updateBlock" ->
    (match payload with
     | None -> failure ~code:"invalid_params" ~message:"updateBlock requires a JSON payload"
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match
             required_string "uuid" fields,
             required_string "title" fields,
             optional_status_payload fields
           with
           | Ok uuid, Ok title, Ok status ->
             let title = String.trim title in
             if String.equal title ""
             then failure ~code:"invalid_params" ~message:"updateBlock title must not be empty"
             else (
               match Model.update_block_title session.model ~uuid ~title ~now:(now_ms ()) with
               | Ok () ->
                 Option.iter
                   (fun status ->
                     ignore
                       (Model.update_block_status
                          session.model ~uuid ~status ~now:(now_ms ())))
                   status;
                 snapshot_visible session
               | Error message -> failure ~code:"unknown_block" ~message)
           | Error message, _, _ | _, Error message, _ | _, _, Error message ->
             failure ~code:"invalid_params" ~message)
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
