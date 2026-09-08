open Yojson.Basic

module Model = Logseq_chat_model
module Api = Logseq_chat_api
module Http = Logseq_chat_http
module Pending_ops = Logseq_chat_pending_ops
module Flashcards = Logseq_chat_flashcards
module Outliner_state = Logseq_chat_outliner_state
module Outliner_effects = Logseq_chat_outliner_effects
module Order = Logseq_chat_fractional_order
module Graph_bootstrap = Logseq_chat_graph_bootstrap
module Markup = Logseq_chat_markup

type pending_transport =
  | Json_request of Api.request
  | File_upload of Api.file_upload

type pending_operation =
  | Create_block of Model.block
  | Upload_asset of Model.block
  | Move_created_asset of
      { block : Model.block
      ; remote_uuid : string
      }
  | Update_title of Model.block
  | Update_status of Model.block
  | Create_journal of
      { block : Model.block
      ; encrypted_title : string
      ; page_id : string
      ; journal_day : int
      }

type pending_active =
  { id : int
  ; transport : pending_transport
  ; operation : pending_operation
  ; cleanup_path : string option
  }

type pending_sync =
  { config : Api.config
  ; mutable remaining : Model.block list
  ; authoritative : (string, unit) Hashtbl.t
  ; resolved_journal_pages : (int, string) Hashtbl.t
  ; mutable active : pending_active option
  }

type semantic_pending =
  { operation : Pending_ops.t }

type semantic_active =
  { id : int
  ; pending : semantic_pending
  ; request : Api.request
  }

type node_route =
  { uuid : string
  ; is_tag : bool
  ; is_property : bool
  ; page : Logseq_chat_graph_read.sidebar_page
  ; zoom_to_block : bool
  ; related_blocks : Model.block list
  ; mutable state : Outliner_state.t
  }

type t =
  { mutable model : Model.t
  ; mutable config : Api.config option
  ; mutable available_graphs : Api.graph list
  ; mutable related_blocks : Model.block list
  ; mutable selected_sidebar_page : Logseq_chat_graph_read.sidebar_page option
  ; mutable node_routes : node_route list
  ; mutable node_base_state : Outliner_state.t option
  ; open_graph : (string -> (unit, string) result) option
  ; import_snapshot : (string -> (unit, string) result) option
  ; model_for_graph : (graph_id:string -> Model.t) option
  ; apply_sync_event : (string -> (unit, string) result) option
  ; sync_cursor : (unit -> int option) option
  ; mutable accepted_server_t : int option
  ; graph_blocks : (unit -> Model.block list option) option
  ; graph_sidebar_pages : (unit -> Logseq_chat_graph_read.sidebar_pages option) option
  ; graph_tag_pages : (unit -> Logseq_chat_graph_read.sidebar_page list option) option
  ; graph_node_is_tag : (string -> bool) option
  ; graph_node_is_property : (string -> bool) option
  ; graph_page_blocks : (string -> Model.block list option) option
  ; graph_node_destination :
      (string -> (Logseq_chat_graph_read.sidebar_page * bool) option) option
  ; graph_node_references : (string -> Model.block list option) option
  ; graph_tag_objects : (string -> Model.block list option) option
  ; graph_normalize_titles :
      (uuid:string -> string list -> string list * (string * string) list) option
  ; graph_search : (string -> Logseq_chat_search_index.hit list) option
  ; graph_due_flashcards : (now:int -> Flashcards.due_card list) option
  ; graph_review_flashcard :
      (uuid:string -> rating:Flashcards.rating -> now:int -> operation_id:string
       -> (unit, string) result) option
  ; graph_set_page_favorite :
      (page_uuid:string -> favorite:bool -> operation_id:string -> now:int
       -> (unit, string) result) option
  ; graph_delete_page :
      (page_uuid:string -> operation_id:string -> now:int -> (unit, string) result) option
  ; mutable flashcards : Flashcards.due_card list
  ; mutable search_results : Logseq_chat_search_index.hit list
  ; mutable search_query : string
  ; load_older_journals : (unit -> unit) option
  ; has_older_journals : (unit -> bool) option
  ; load_cached_graph_key : (Api.config -> (unit, string) result) option
  ; unlock_graph : (Api.config -> password:string -> (unit, string) result) option
  ; provision_graph_key : (Api.config -> (unit, string) result) option
  ; graph_unlocked : (graph_id:string -> bool) option
  ; encrypt_title : (graph_id:string -> string -> (string, string) result) option
  ; resolve_asset_path : string -> string
  ; encrypt_asset_file : (graph_id:string -> source_path:string -> (string * int, string) result) option
  ; journal_page_id : (journal_day:int -> string option) option
  ; send : Api.request -> (Api.response, string) result
  ; upload_file : Api.file_upload -> (Api.response, string) result
  ; cleanup_file : string -> unit
  ; mutable sync_connected : bool
  ; mutable pending_sync : pending_sync option
  ; mutable next_pending_request_id : int
  ; stage_operation : (Pending_ops.t -> (unit, string) result) option
  ; prepare_operation : (Pending_ops.t -> (string * string, string) result) option
  ; pending_operations : (unit -> Pending_ops.t list) option
  ; mutable semantic_queue : semantic_pending list
  ; mutable semantic_active : semantic_active option
  ; mutable outliner_state : Outliner_state.t
  ; mutable outliner_optimistic_blocks : Model.block list option
  ; mutable outliner_commands : Outliner_effects.platform_command list
  ; mutable outliner_revision : int
  ; save_graph_catalog : (string -> unit) option
  }

let current_server_t session =
  match Option.bind session.sync_cursor (fun cursor -> cursor ()), session.accepted_server_t with
  | Some authoritative_t, Some accepted_t -> Some (max authoritative_t accepted_t)
  | Some authoritative_t, None -> Some authoritative_t
  | None, Some accepted_t -> Some accepted_t
  | None, None -> None
;;

let projection_server_t session =
  Option.bind session.sync_cursor (fun cursor -> cursor ())
;;

let record_accepted_server_t session accepted_t =
  session.accepted_server_t <-
    Some (Option.fold ~none:accepted_t ~some:(max accepted_t) session.accepted_server_t)
;;

let debug format =
  Printf.ksprintf
    (fun message -> prerr_endline ("LogseqChat core " ^ message))
    format
;;

let fresh_squuid () =
  match Datascript.squuid () with
  | Datascript.Uuid uuid -> uuid
  | _ -> failwith "Datascript.squuid returned a non-UUID value"
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

let required_bool name fields =
  match assoc name fields with
  | Some (`Bool value) -> Ok value
  | Some _ -> Error ("field must be a boolean: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let required_string_list name fields =
  match assoc name fields with
  | Some (`List values) ->
    let rec loop result = function
      | [] -> Ok (List.rev result)
      | `String value :: rest when not (String.equal (String.trim value) "") ->
        loop (value :: result) rest
      | _ -> Error ("field must be a list of non-empty strings: " ^ name)
    in
    loop [] values
  | _ -> Error ("field must be a list: " ^ name)
;;

let required_moves fields =
  match assoc "moves" fields with
  | Some (`List values) ->
    let decode = function
      | `Assoc move ->
        (match required_string "uuid" move,
               required_string "pageUuid" move,
               required_string "parentUuid" move,
               required_string "order" move with
         | Ok uuid, Ok page_uuid, Ok parent_uuid, Ok order ->
           Ok Pending_ops.{ uuid; page_uuid; parent_uuid; order }
         | Error message, _, _, _ | _, Error message, _, _
         | _, _, Error message, _ | _, _, _, Error message -> Error message)
      | _ -> Error "moves must contain objects"
    in
    let rec loop result = function
      | [] -> Ok (List.rev result)
      | value :: rest ->
        (match decode value with
         | Ok move -> loop (move :: result) rest
         | Error _ as error -> error)
    in
    loop [] values
  | _ -> Error "field must be a list: moves"
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

let status_semantic_ref (status : Model.status) =
  match status.ident with
  | Some ident when not (String.equal (String.trim ident) "") -> Pending_ops.Ref_ident ident
  | Some _ | None -> Pending_ops.Ref_uuid status.uuid
;;

let block_json (block : Model.block) =
  let summary_json (summary : Model.entity_summary) =
    `Assoc [ "uuid", `String summary.uuid; "title", `String summary.title ]
  in
  let status_fields =
    match block.status with
    | None -> []
    | Some status ->
      [ "status", status_response_json status ]
  in
  `Assoc
    ([ "uuid", `String block.uuid
     ; "title", `String block.title
     ; "pageId", `String block.page_id
     ; "createdAt", `Int block.created_at
     ; "updatedAt", `Int block.updated_at
     ; "syncStatus", `String block.sync_status
     ; "isAsset", `Bool block.is_asset
     ; "tags", `List (List.map summary_json block.tags)
     ; "references", `List (List.map summary_json block.references)
     ; "breadcrumbs", `List (List.map summary_json block.breadcrumbs)
     ; ( "markup"
       , Logseq_chat_markup.parse
           ~references:block.references
           ~tags:block.tags
           block.title
         |> Logseq_chat_markup.to_yojson )
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

let flashcard_json (due_card : Flashcards.due_card) =
  `Assoc
    [ "block", block_json due_card.block
    ; "children", `List (List.map block_json due_card.children)
    ; "due", `Int due_card.card.due
    ; "repetitions", `Int due_card.card.reps
    ; "lapses", `Int due_card.card.lapses
    ; "state", `String (Flashcards.state_keyword due_card.card.state)
    ]
;;

let visible_block_json _model (block : Model.block) =
  match block.journal with
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
    ; "schemaVersion", Option.fold ~none:`Null ~some:(fun value -> `String value) graph.schema_version
    ; "isEncrypted", `Bool graph.e2ee
    ; "isReady", `Bool graph.ready
    ]
;;

let sidebar_page_json (page : Logseq_chat_graph_read.sidebar_page) =
  `Assoc [ "uuid", `String page.uuid; "title", `String page.title ]
;;

let search_hit_json (hit : Logseq_chat_search_index.hit) =
  `Assoc
    [ "uuid", `String hit.uuid
    ; "title", `String hit.title
    ; "isPage", `Bool hit.is_page
    ; ( "page"
      , match hit.page with
        | Some page -> sidebar_page_json page
        | None -> `Null )
    ; ( "breadcrumbs"
      , `List
          (List.map
             (fun (summary : Model.entity_summary) ->
               `Assoc [ "uuid", `String summary.uuid; "title", `String summary.title ])
             hit.breadcrumbs) )
    ]
;;

let pending_request_json session =
  let request_json id (request : Api.request) file_path content_type headers =
    let body_fields =
      match request.body with
      | Some body ->
        (match from_string body with
         | json -> [ "body", `String body; "bodyObject", json ]
         | exception _ -> [ "body", `String body ])
      | None -> []
    in
    `Assoc
      ([ "id", `Int id
       ; "method", `String request.Api.method_
       ; "url", `String request.url
       ; "token", `String request.token
       ; "contentType", `String content_type
       ; "headers", `Assoc (List.map (fun (key, value) -> key, `String value) headers)
       ]
       @ body_fields
       @ (match file_path with Some path -> [ "filePath", `String path ] | None -> []))
  in
  match session.semantic_active, session.pending_sync with
  | Some active, _ ->
    request_json active.id active.request None "application/json" []
  | None, Some { active = Some active; _ } ->
    (match active.transport with
     | Json_request request -> request_json active.id request None "application/json" []
     | File_upload upload ->
       request_json active.id upload.request (Some upload.file_path) upload.content_type upload.headers)
  | None, Some _ | None, None -> `Null
;;

let autocomplete_kind_json = function
  | Outliner_state.Node -> "node"
  | Tag -> "tag"
  | Property -> "property"
;;

let outliner_context_with_blocks ?sidebar_pages session blocks =
  let pages =
    let sidebar =
      match sidebar_pages, session.graph_sidebar_pages with
      | Some sidebar, _ -> sidebar
      | None, None -> Logseq_chat_graph_read.{ favorites = []; recent_pages = [] }
      | None, Some load ->
        Option.value
          (load ())
          ~default:Logseq_chat_graph_read.{ favorites = []; recent_pages = [] }
    in
      sidebar.favorites @ sidebar.recent_pages
      |> List.map (fun page ->
        Outliner_state.{ label = page.Logseq_chat_graph_read.title; value = page.uuid })
  in
  let tags =
    match session.graph_tag_pages with
    | None -> []
    | Some load ->
      Option.value (load ()) ~default:[]
      |> List.map (fun page ->
        Outliner_state.{ label = page.Logseq_chat_graph_read.title; value = page.uuid })
  in
  Outliner_state.{ blocks; pages; tags }
;;

let merge_live_block_metadata
      (optimistic : Model.block)
      (live : Model.block)
  =
  { optimistic with
    updated_at = live.updated_at
  ; sync_status = live.sync_status
  ; tags = live.tags
  ; references = live.references
  ; breadcrumbs = live.breadcrumbs
  ; status = live.status
  ; is_asset = live.is_asset
  ; asset_type = live.asset_type
  ; asset_size = live.asset_size
  ; asset_checksum = live.asset_checksum
  ; local_path = live.local_path
  ; journal = live.journal
  }
;;

let page_blocks_with_optimistic_overlay session page_uuid live_blocks =
  let base =
    match session.outliner_optimistic_blocks, Outliner_state.editing_uuid session.outliner_state with
    | Some cached, Some _ ->
      let live_by_uuid = Hashtbl.create (List.length live_blocks) in
      List.iter
        (fun (block : Model.block) -> Hashtbl.replace live_by_uuid block.uuid block)
        live_blocks;
      cached
      |> List.filter (fun (block : Model.block) -> String.equal block.page_id page_uuid)
      |> List.map (fun block ->
        match Hashtbl.find_opt live_by_uuid block.Model.uuid with
        | Some live -> merge_live_block_metadata block live
        | None -> block)
    | None, _ | Some _, None -> live_blocks
  in
  base
;;

let base_outliner_context_live session =
  let blocks =
    match session.selected_sidebar_page, session.graph_page_blocks, session.graph_blocks with
    | Some page, Some load, _ -> Option.value (load page.uuid) ~default:[]
    | _, _, Some load -> Option.value (load ()) ~default:[]
    | _ -> Model.visible_blocks session.model
  in
  outliner_context_with_blocks session blocks
;;

let base_outliner_context_with_blocks ?sidebar_pages session blocks =
  let context = outliner_context_with_blocks ?sidebar_pages session blocks in
  match session.selected_sidebar_page with
  | None -> context
  | Some page ->
    { context with
      Outliner_state.blocks =
        page_blocks_with_optimistic_overlay session page.uuid context.blocks
    }
;;

let base_outliner_context session =
  let context = base_outliner_context_live session in
  match session.selected_sidebar_page with
  | None -> context
  | Some page ->
    { context with
      Outliner_state.blocks =
        page_blocks_with_optimistic_overlay session page.uuid context.blocks
    }
;;

let page_outliner_context session page_uuid =
  Option.bind session.graph_page_blocks (fun load ->
    Option.map (outliner_context_with_blocks session) (load page_uuid))
;;

let node_route_context session route =
  let graph_blocks =
    match session.graph_page_blocks with
    | Some load -> Option.value (load route.page.uuid) ~default:[]
    | None -> []
  in
  outliner_context_with_blocks
    session
    (page_blocks_with_optimistic_overlay session route.page.uuid graph_blocks)
;;

let active_node_route session =
  match List.rev session.node_routes with route :: _ -> Some route | [] -> None
;;

(* Related blocks (tagged nodes or linked references) are recomputed on every
   projection so edits made to them stay visible; the list captured when the
   route was opened is only the offline fallback. *)
let node_route_related_blocks session route =
  let fresh =
    if route.is_tag
    then Option.bind session.graph_tag_objects (fun load -> load route.uuid)
    else Option.bind session.graph_node_references (fun load -> load route.uuid)
  in
  Option.value fresh ~default:route.related_blocks
;;

let node_route_linked_reference_blocks session route =
  if route.is_tag
  then
    Option.bind session.graph_node_references (fun load -> load route.uuid)
    |> Option.value ~default:[]
  else []
;;

let page_for_visible_block _session (block : Model.block) =
  let page_title =
    match block.Model.journal with
    | Some (title, _) when not (String.equal (String.trim title) "") -> title
    | _ ->
      (match
         List.find_opt
           (fun (summary : Model.entity_summary) ->
             String.equal summary.uuid block.Model.page_id)
           block.Model.breadcrumbs
       with
       | Some summary -> summary.title
       | None ->
         block.Model.title)
  in
  let page : Logseq_chat_graph_read.sidebar_page =
    { uuid = block.Model.page_id; title = page_title }
  in
  page
;;

(* Resolve against the same projected blocks that produced the visible UI. *)
let projected_node_destination session uuid =
  let graph_blocks =
    Option.bind session.graph_blocks (fun load -> load ())
    |> Option.value ~default:[]
  in
  let selected_page_blocks =
    match session.selected_sidebar_page, session.graph_page_blocks with
    | Some page, Some load -> Option.value (load page.uuid) ~default:[]
    | None, _ | _, None -> []
  in
  let routed_blocks =
    session.node_routes
    |> List.concat_map (fun route -> (node_route_context session route).blocks)
  in
  let optimistic_blocks = Option.value session.outliner_optimistic_blocks ~default:[] in
  let blocks =
    graph_blocks
    @ selected_page_blocks
    @ routed_blocks
    @ session.related_blocks
    @ optimistic_blocks
  in
  let candidate =
    match List.find_opt (fun (block : Model.block) -> String.equal block.uuid uuid) blocks with
    | Some block -> Some (block, true)
    | None ->
      Option.map
        (fun block -> block, false)
        (List.find_opt (fun (block : Model.block) -> String.equal block.page_id uuid) blocks)
  in
  Option.bind candidate (fun (block, zoom_to_block) ->
    if String.equal block.Model.page_id ""
    then None
    else
      Some (page_for_visible_block session block, zoom_to_block))
;;

(* Related blocks are editable in place, so the dispatch context must resolve
   them even though they belong to other pages. The display contexts
   (node_route_context / base_outliner_context) stay page-scoped. *)
let with_extra_blocks context extra =
  let missing =
    List.filter
      (fun (block : Model.block) ->
        not
          (List.exists
             (fun (existing : Model.block) -> String.equal existing.uuid block.uuid)
             context.Outliner_state.blocks))
      extra
  in
  { context with Outliner_state.blocks = context.Outliner_state.blocks @ missing }
;;

let outliner_context session =
  match active_node_route session with
  | Some route ->
    with_extra_blocks
      (node_route_context session route)
      (node_route_related_blocks session route @ node_route_linked_reference_blocks session route)
  | None -> with_extra_blocks (base_outliner_context session) session.related_blocks
;;

let rec project_outliner_intent blocks = function
  | Pending_ops.Save_title { uuid; title; _ } ->
    List.map
      (fun (block : Model.block) ->
        if String.equal block.uuid uuid then { block with title } else block)
      blocks
  | Insert_block { uuid; title; page_uuid; parent_uuid; order; created_at } ->
    blocks
    @ [ Model.
          { uuid
          ; title
          ; page_id = page_uuid
          ; parent_id = Some parent_uuid
          ; order = Some order
          ; created_at
          ; updated_at = created_at
          ; sync_status = "pending"
          ; tags = []
          ; references = []
          ; breadcrumbs = []
          ; status = None
          ; is_asset = false
          ; asset_type = None
          ; asset_size = None
          ; asset_checksum = None
          ; local_path = None
          ; journal = None
          }
      ]
  | Create_asset
      { uuid; title; page_uuid; parent_uuid; order; created_at; asset_type;
        asset_size; asset_checksum }
    ->
    let asset =
      Model.
        { uuid
        ; title
        ; page_id = page_uuid
        ; parent_id = Some parent_uuid
        ; order = Some order
        ; created_at
        ; updated_at = created_at
        ; sync_status = "pending"
        ; tags = []
        ; references = []
        ; breadcrumbs = []
        ; status = None
        ; is_asset = true
        ; asset_type = Some asset_type
        ; asset_size = Some asset_size
        ; asset_checksum = Some asset_checksum
        ; local_path = None
        ; journal = None
        }
    in
    if List.exists (fun (block : Model.block) -> String.equal block.uuid uuid) blocks
    then
      List.map
        (fun (block : Model.block) ->
          if String.equal block.uuid uuid
          then { asset with local_path = block.local_path }
          else block)
        blocks
    else blocks @ [ asset ]
  | Split_block { uuid; before; after; new_uuid; new_order; created_at; _ } ->
    (match
       List.find_opt
         (fun (block : Model.block) -> String.equal block.uuid uuid)
         blocks
     with
     | None -> blocks
     | Some source ->
       List.map
         (fun (block : Model.block) ->
           if String.equal block.uuid uuid then { block with title = before } else block)
         blocks
       @ [ Model.
             { uuid = new_uuid
             ; title = after
             ; page_id = source.page_id
             ; parent_id = source.parent_id
             ; order = Some new_order
             ; created_at
             ; updated_at = created_at
             ; sync_status = "pending"
             ; tags = []
             ; references = []
             ; breadcrumbs = []
             ; status = None
             ; is_asset = false
             ; asset_type = None
             ; asset_size = None
             ; asset_checksum = None
             ; local_path = None
             ; journal = source.journal
             }
         ])
  | Merge_backward { uuid; title; previous_uuid; merged_title; _ } ->
    let previous_title =
      List.find_opt
        (fun (block : Model.block) -> String.equal block.uuid previous_uuid)
        blocks
      |> Option.map (fun block -> block.Model.title)
      |> Option.value ~default:""
    in
    let title = Option.value merged_title ~default:(previous_title ^ title) in
    blocks
    |> List.filter (fun (block : Model.block) -> not (String.equal block.uuid uuid))
    |> List.map (fun (block : Model.block) ->
      if String.equal block.uuid previous_uuid
      then { block with title; sync_status = "pending" }
      else block)
  | Move_block move ->
    List.map
      (fun (block : Model.block) ->
        if String.equal block.uuid move.uuid
        then
          { block with
            page_id = move.page_uuid
          ; parent_id = Some move.parent_uuid
          ; order = Some move.order
          ; sync_status = "pending"
          }
        else block)
      blocks
  | Move_blocks { moves } ->
    List.fold_left
      (fun blocks move -> project_outliner_intent blocks (Pending_ops.Move_block move))
      blocks
      moves
  | Delete_blocks { uuids } ->
    List.filter
      (fun (block : Model.block) -> not (List.mem block.uuid uuids))
      blocks
  | Set_property { uuid; attr = "logseq.property/status"; value; _ } ->
    let status =
      Option.bind value (function
        | Pending_ops.Ref_ident ident ->
          let uuid, title =
            match ident with
            | "logseq.property/status.backlog" -> "backlog", "Backlog"
            | "logseq.property/status.todo" -> "todo", "Todo"
            | "logseq.property/status.doing" -> "doing", "Doing"
            | "logseq.property/status.in-review" -> "in-review", "In Review"
            | "logseq.property/status.done" -> "done", "Done"
            | "logseq.property/status.canceled" -> "canceled", "Canceled"
            | _ -> ident, ident
          in
          Some Model.
            { uuid
            ; ident = Some ident
            ; title
            ; icon_type = None
            ; icon_id = None
            ; icon_color = None
            }
        | Pending_ops.Ref_uuid uuid ->
          Some Model.
            { uuid
            ; ident = None
            ; title = uuid
            ; icon_type = None
            ; icon_id = None
            ; icon_color = None
            }
        | _ -> None)
    in
    List.map
      (fun (block : Model.block) ->
        if String.equal block.uuid uuid
        then { block with status; sync_status = "pending" }
        else block)
      blocks
  | Set_property _ | Set_properties _ | Create_tag _ | Create_page _ | Create_journal _ | Add_tag _
  | Set_favorite _ | Delete_page _ -> blocks
;;

let project_outliner_operations context operations =
  let blocks =
    List.fold_left
      (fun blocks (operation : Pending_ops.t) ->
        project_outliner_intent blocks operation.intent)
      context.Outliner_state.blocks
      operations
  in
  { context with Outliner_state.blocks }
;;

let outliner_state_json state =
  `Assoc
    [ ( "editing"
      , match state.Outliner_state.editing with
        | None -> `Null
        | Some editing ->
          `Assoc
            [ "uuid", `String editing.uuid
            ; "title", `String editing.title
            ; "caretUTF16Offset", `Int editing.caret
            ] )
    ; "selectedBlockIds", `List (List.map (fun uuid -> `String uuid) (Outliner_state.selected_uuids state))
    ; "collapsedBlockIds",
      `List
        (Outliner_state.String_set.elements state.collapsed
         |> List.map (fun uuid -> `String uuid))
    ; "zoomedBlockIds", `List (List.map (fun uuid -> `String uuid) state.zoomed)
    ; ( "autocomplete"
      , match state.autocomplete with
        | None -> `Null
        | Some autocomplete ->
          `Assoc
            [ "kind", `String (autocomplete_kind_json autocomplete.kind)
            ; "query", `String autocomplete.query
            ] )
    ]
;;

let contains_case_insensitive value fragment =
  try
    ignore
      (Str.search_forward
         (Str.regexp_string (String.lowercase_ascii fragment))
         (String.lowercase_ascii value)
         0);
    true
  with
  | Not_found -> false
;;

let is_youtube_url url =
  contains_case_insensitive url "youtube.com"
  || contains_case_insensitive url "youtu.be"
;;

let youtube_target_urls (blocks : Model.block list) =
  let _, targets =
    List.fold_left
      (fun (current_url, targets) (block : Model.block) ->
        let nodes = Markup.parse ~references:block.references ~tags:block.tags block.title in
        let current_url, target_url =
          List.fold_left
            (fun (current_url, target_url) node ->
              match node with
              | Markup.Video url when is_youtube_url url -> Some url, target_url
              | Markup.Youtube_timestamp _ ->
                current_url,
                (match current_url with Some _ -> current_url | None -> target_url)
              | _ -> current_url, target_url)
            (current_url, None)
            nodes
        in
        let targets =
          match target_url with
          | Some url -> (block.uuid, url) :: targets
          | None -> targets
        in
        current_url, targets)
      (None, [])
      blocks
  in
  List.rev targets
;;

let outliner_row_json_with ?youtube_target_url serialize_block row =
  `Assoc
    ([ "block", serialize_block row.Outliner_state.block
     ; "depth", `Int row.depth
     ; "hasChildren", `Bool row.has_children
     ; "isCollapsed", `Bool row.is_collapsed
     ]
     @
     match youtube_target_url with
     | Some url -> [ "youtubeTargetURL", `String url ]
     | None -> [])
;;

let outliner_rows_json ?serialize_block session context state =
  let serialize_block =
    Option.value serialize_block ~default:(visible_block_json session.model)
  in
  let rows = Outliner_state.visible_rows context state in
  let targets = youtube_target_urls (List.map (fun row -> row.Outliner_state.block) rows) in
  rows
  |> List.map (fun row ->
    outliner_row_json_with
      ?youtube_target_url:(List.assoc_opt row.Outliner_state.block.uuid targets)
      serialize_block
      row)
  |> fun rows -> `List rows
;;

let outliner_candidates_json context state =
  match state.Outliner_state.autocomplete with
  | None -> `List []
  | Some request ->
    Outliner_state.autocomplete_candidates context request
    |> List.map (fun candidate ->
      `Assoc
        [ "label", `String candidate.Outliner_state.label
        ; "value", `String candidate.value
        ])
    |> fun candidates -> `List candidates
;;

let node_routes_json session =
  let active = active_node_route session in
  session.node_routes
  |> List.map (fun route ->
    let state =
      match active with
      | Some active when String.equal active.uuid route.uuid -> session.outliner_state
      | _ -> route.state
    in
    let context = node_route_context session route in
    `Assoc
      [ "uuid", `String route.uuid
      ; "isTag", `Bool route.is_tag
      ; "isProperty", `Bool route.is_property
      ; "page", sidebar_page_json route.page
      ; "blocks", `List (List.map (visible_block_json session.model) context.blocks)
      ; "relatedBlocks",
        `List (List.map block_json (node_route_related_blocks session route))
      ; "linkedReferenceBlocks",
        `List (List.map block_json (node_route_linked_reference_blocks session route))
      ; "outlinerState", outliner_state_json state
      ; "outlinerRows", outliner_rows_json session context state
      ; "outlinerAutocompleteCandidates", outliner_candidates_json context state
      ])
  |> fun routes -> `List routes
;;

let haptic_json = function Outliner_state.Selection -> "selection" | Impact -> "impact"

let outliner_command_json = function
  | Outliner_effects.Haptic haptic ->
    `Assoc [ "type", `String "haptic"; "style", `String (haptic_json haptic) ]
  | Focus_block uuid -> `Assoc [ "type", `String "focusBlock"; "uuid", `String uuid ]
  | Confirm_delete uuids ->
    `Assoc
      [ "type", `String "confirmDelete"
      ; "uuids", `List (List.map (fun uuid -> `String uuid) uuids)
      ]
  | Set_clipboard_text text ->
    `Assoc [ "type", `String "setClipboardText"; "text", `String text ]
  | Set_clipboard_references uuids ->
    `Assoc
      [ "type", `String "setClipboardReferences"
      ; "uuids", `List (List.map (fun uuid -> `String uuid) uuids)
      ]
  | Set_clipboard_urls uuids ->
    `Assoc
      [ "type", `String "setClipboardURLs"
      ; "uuids", `List (List.map (fun uuid -> `String uuid) uuids)
      ]
  | Pick_attachment uuid ->
    `Assoc [ "type", `String "pickAttachment"; "uuid", `String uuid ]
  | Take_photo uuid ->
    `Assoc [ "type", `String "takePhoto"; "uuid", `String uuid ]
  | Record_audio uuid ->
    `Assoc [ "type", `String "recordAudio"; "uuid", `String uuid ]
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

(* A selected sidebar page that is a tag (class) lists its tagged objects,
   including instances of classes extending it via
   logseq.property.class/extends (handled by objects_for_tag). *)
let selected_page_is_tag session =
  match session.selected_sidebar_page, session.graph_node_is_tag with
  | Some page, Some is_tag -> is_tag page.Logseq_chat_graph_read.uuid
  | _ -> false
;;

let selected_page_is_property session =
  match session.selected_sidebar_page, session.graph_node_is_property with
  | Some page, Some is_property -> is_property page.Logseq_chat_graph_read.uuid
  | _ -> false
;;

let snapshot_related_blocks session =
  if selected_page_is_tag session
  then (
    match session.selected_sidebar_page, session.graph_tag_objects with
    | Some page, Some load ->
      Option.value (load page.Logseq_chat_graph_read.uuid) ~default:[]
    | _ -> [])
  else session.related_blocks
;;

let snapshot_linked_reference_blocks session =
  if selected_page_is_tag session
  then (
    match session.selected_sidebar_page, session.graph_node_references with
    | Some page, Some load ->
      Option.value (load page.Logseq_chat_graph_read.uuid) ~default:[]
    | _ -> [])
  else []
;;

let has_pending_operations session =
  session.semantic_queue <> []
  || Option.is_some session.semantic_active
  || Option.is_some session.pending_sync
  || Logseq_chat_model.pending_blocks session.model <> []
;;

let snapshot session ~context_blocks blocks =
  let started = Unix.gettimeofday () in
  let report stage =
    if Sys.getenv_opt "LOGSEQ_CHAT_TRACE_STARTUP" = Some "1" then
      Printf.eprintf "LOGSEQ_SNAPSHOT_METRIC stage=%s elapsed_ms=%.3f\n%!"
        stage ((Unix.gettimeofday () -. started) *. 1000.)
  in
  let sidebar_pages =
    Option.bind session.graph_sidebar_pages (fun load -> load ())
    |> Option.value ~default:Logseq_chat_graph_read.{ favorites = []; recent_pages = [] }
  in
  report "sidebar";
  let base_state = Option.value session.node_base_state ~default:session.outliner_state in
  let base_context =
    base_outliner_context_with_blocks ~sidebar_pages session context_blocks
  in
  report "context";
  let serialized_blocks = Hashtbl.create (List.length blocks) in
  let serialize_block (block : Model.block) =
    match Hashtbl.find_opt serialized_blocks block.uuid with
    | Some json -> json
    | None ->
      let json = visible_block_json session.model block in
      Hashtbl.add serialized_blocks block.uuid json;
      json
  in
  let response = success
    (`Assoc
      [ "revision", `Int session.model.revision
      ; "blocks", `List (List.map serialize_block blocks)
      ; "selectedBlock",
        (match Model.selected_block session.model with
         | Some block -> block_json block
         | None -> `Null)
      ; "relatedBlocks", `List (List.map block_json (snapshot_related_blocks session))
      ; "linkedReferenceBlocks",
        `List (List.map block_json (snapshot_linked_reference_blocks session))
      ; "selectedPageIsTag", `Bool (selected_page_is_tag session)
      ; "selectedPageIsProperty", `Bool (selected_page_is_property session)
      ; "searchQuery", `String session.search_query
      ; "searchResults", `List (List.map search_hit_json session.search_results)
      ; "flashcards", `List (List.map flashcard_json session.flashcards)
      ; "nodeRoutes", node_routes_json session
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
      ; "favorites", `List (List.map sidebar_page_json sidebar_pages.favorites)
      ; "recentPages", `List (List.map sidebar_page_json sidebar_pages.recent_pages)
      ; "selectedPage",
        (match session.selected_sidebar_page with
         | Some page -> sidebar_page_json page
         | None -> `Null)
      ; "isGraphEncrypted", `Bool (selected_graph_is_encrypted session)
      ; "isGraphUnlocked", `Bool (selected_graph_is_unlocked session)
      ; "appliedServerT",
        Option.fold ~none:`Null ~some:(fun value -> `Int value) (current_server_t session)
      ; "syncConnected", `Bool session.sync_connected
      ; "taskStatuses", `List (List.map status_response_json (Model.all_statuses session.model))
      ; "pendingSyncRequest", pending_request_json session
      ; "outlinerState", outliner_state_json base_state
      ; "outlinerAutocompleteCandidates",
        outliner_candidates_json base_context base_state
      ; "outlinerRows",
        outliner_rows_json ~serialize_block session base_context base_state
      ; "outlinerCommandRevision", `Int session.outliner_revision
      ; "outlinerCommands", `List (List.map outliner_command_json session.outliner_commands)
      ; "hasPendingSemanticOperations",
        `Bool (has_pending_operations session)
      ; "hasOlderJournals",
        `Bool (Option.fold ~none:false ~some:(fun read -> read ()) session.has_older_journals)
      ; "isOutlinerPatch", `Bool false
      ])
  in
  if session.flashcards <> [] then debug "flashcards snapshot encoded bytes=%d" (String.length response);
  response
;;

let outliner_patch_result
      session
      (context : Outliner_state.context)
      ~blocks
      ~deleted_block_ids
      ~row_splices
  =
  success
    (`Assoc
      [ "revision", `Int session.model.revision
      ; "blocks", `List (List.map (visible_block_json session.model) blocks)
      ; "deletedBlockIds", `List (List.map (fun uuid -> `String uuid) deleted_block_ids)
      ; "selectedBlock", `Null
      ; "outlinerState", outliner_state_json session.outliner_state
      ; "outlinerAutocompleteCandidates",
        outliner_candidates_json context session.outliner_state
      ; "outlinerRows", `List []
      ; "outlinerRowSplices", `List row_splices
      ; "outlinerCommandRevision", `Int session.outliner_revision
      ; "outlinerCommands", `List (List.map outliner_command_json session.outliner_commands)
      ; "hasPendingSemanticOperations",
        `Bool (has_pending_operations session)
      ; "isOutlinerPatch", `Bool true
      ])
;;

let outliner_patch ?(changed_uuids = []) session (context : Outliner_state.context) =
  let changed = Hashtbl.create (List.length changed_uuids) in
  List.iter (fun uuid -> Hashtbl.replace changed uuid ()) changed_uuids;
  let blocks =
    List.filter
      (fun (block : Model.block) -> Hashtbl.mem changed block.uuid)
      context.blocks
  in
  outliner_patch_result
    session
    context
    ~blocks
    ~deleted_block_ids:[]
    ~row_splices:[]
;;

let structural_outliner_patch
      ?(anchored = false)
      session
      ~(before_context : Outliner_state.context)
      ~before_state
      ~(after_context : Outliner_state.context)
  =
  let before_blocks = Hashtbl.create (List.length before_context.blocks) in
  let after_blocks = Hashtbl.create (List.length after_context.blocks) in
  List.iter
    (fun (block : Model.block) -> Hashtbl.replace before_blocks block.uuid block)
    before_context.blocks;
  List.iter
    (fun (block : Model.block) -> Hashtbl.replace after_blocks block.uuid block)
    after_context.blocks;
  let blocks =
    List.filter
      (fun (block : Model.block) ->
        match Hashtbl.find_opt before_blocks block.uuid with
        | Some previous -> previous <> block
        | None -> true)
      after_context.blocks
  in
  let deleted_block_ids =
    List.filter_map
      (fun (block : Model.block) ->
        if Hashtbl.mem after_blocks block.uuid then None else Some block.uuid)
      before_context.blocks
  in
  let before_rows =
    Outliner_state.visible_rows before_context before_state |> Array.of_list
  in
  let after_rows =
    Outliner_state.visible_rows after_context session.outliner_state |> Array.of_list
  in
  let after_youtube_targets =
    Array.to_list after_rows
    |> List.map (fun row -> row.Outliner_state.block)
    |> youtube_target_urls
  in
  let before_length = Array.length before_rows in
  let after_length = Array.length after_rows in
  let rec common_prefix index =
    if index < before_length
       && index < after_length
       && before_rows.(index) = after_rows.(index)
    then common_prefix (index + 1)
    else index
  in
  let start = common_prefix 0 in
  let rec common_suffix count =
    let before_index = before_length - count - 1 in
    let after_index = after_length - count - 1 in
    if before_index >= start
       && after_index >= start
       && before_rows.(before_index) = after_rows.(after_index)
    then common_suffix (count + 1)
    else count
  in
  let suffix = common_suffix 0 in
  let delete_count = before_length - start - suffix in
  let insert_count = after_length - start - suffix in
  let row_splices =
    if delete_count = 0 && insert_count = 0
    then []
    else
      let rows =
        Array.sub after_rows start insert_count
        |> Array.to_list
        |> List.map (fun row ->
          outliner_row_json_with
            ?youtube_target_url:
              (List.assoc_opt row.Outliner_state.block.uuid after_youtube_targets)
            (visible_block_json session.model)
            row)
      in
      let position =
        if not anchored
        then [ "start", `Int start ]
        else
          let after_anchor =
            if start > 0
            then
              [ ( "afterBlockId"
                , `String before_rows.(start - 1).Outliner_state.block.Model.uuid )
              ]
            else []
          in
          let before_anchor =
            if start < before_length
            then
              [ ( "beforeBlockId"
                , `String before_rows.(start).Outliner_state.block.Model.uuid )
              ]
            else []
          in
          match after_anchor @ before_anchor with
          | [] -> [ "start", `Int 0 ]
          | anchors -> anchors
      in
      [ `Assoc
          (position
           @ [ "deleteCount", `Int delete_count
             ; "rows", `List rows
             ])
      ]
  in
  outliner_patch_result
    session
    after_context
    ~blocks
    ~deleted_block_ids
    ~row_splices
;;

let snapshot_visible session =
  let started = Unix.gettimeofday () in
  let blocks =
    match session.selected_sidebar_page, session.graph_page_blocks with
    | Some page, Some graph_page_blocks ->
      Option.value (graph_page_blocks page.uuid) ~default:[]
    | _ ->
    match session.graph_blocks with
    | Some graph_blocks ->
      (match graph_blocks () with
     | Some blocks ->
       let local_by_uuid = Hashtbl.create (List.length blocks) in
       List.iter
         (fun (block : Model.block) -> Hashtbl.replace local_by_uuid block.uuid block)
         (Model.all_blocks session.model);
       List.map
         (fun (block : Model.block) ->
           match Hashtbl.find_opt local_by_uuid block.uuid with
           | Some local when Option.is_some local.local_path ->
             { block with local_path = local.local_path }
           | Some _ | None -> block)
         blocks
       | None -> [])
    | None -> Model.visible_blocks session.model
  in
  if session.flashcards <> [] then debug "flashcards visible blocks loaded count=%d" (List.length blocks);
  let context_blocks = blocks in
  let blocks =
    if Option.is_some session.graph_blocks || Option.is_some session.selected_sidebar_page
    then blocks
    else Model.visible_from session.model blocks
  in
  if Sys.getenv_opt "LOGSEQ_CHAT_TRACE_STARTUP" = Some "1" then
    Printf.eprintf "LOGSEQ_SNAPSHOT_METRIC stage=blocks elapsed_ms=%.3f\n%!" ((Unix.gettimeofday () -. started) *. 1000.);
  let result = snapshot session ~context_blocks blocks in
  if Sys.getenv_opt "LOGSEQ_CHAT_TRACE_STARTUP" = Some "1" then
    Printf.eprintf "LOGSEQ_SNAPSHOT_METRIC stage=complete elapsed_ms=%.3f\n%!" ((Unix.gettimeofday () -. started) *. 1000.);
  result
;;

let graph_catalog_snapshot session =
  success
    (`Assoc
      [ "graphName",
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
      ; "isGraphCatalogPatch", `Bool true
      ])
;;

let pending_sync_patch session =
  success
    (`Assoc
      [ "revision", `Int session.model.revision
      ; "blocks", `List []
      ; "selectedBlock", `Null
      ; "appliedServerT",
        Option.fold ~none:`Null ~some:(fun value -> `Int value) (current_server_t session)
      ; "pendingSyncRequest", pending_request_json session
      ; "hasPendingSemanticOperations",
        `Bool (has_pending_operations session)
      ; "isPendingSyncPatch", `Bool true
      ])
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

let flashcard_rating = function
  | "again" -> Ok Flashcards.Again
  | "hard" -> Ok Flashcards.Hard
  | "good" -> Ok Flashcards.Good
  | "easy" -> Ok Flashcards.Easy
  | _ -> Error "rating must be again, hard, good, or easy"
;;

let create
      ?storage
      ?open_graph
      ?import_snapshot
      ?model_for_graph
      ?apply_sync_event
      ?sync_cursor
      ?graph_blocks
      ?graph_sidebar_pages
      ?graph_tag_pages
      ?graph_node_is_tag
      ?graph_node_is_property
      ?graph_page_blocks
      ?graph_node_destination
      ?graph_node_references
      ?graph_tag_objects
      ?graph_normalize_titles
      ?graph_search
      ?graph_due_flashcards
      ?graph_review_flashcard
      ?graph_set_page_favorite
      ?graph_delete_page
      ?load_older_journals
      ?has_older_journals
      ?stage_operation
      ?prepare_operation
      ?pending_operations
      ?load_cached_graph_key
      ?unlock_graph
      ?provision_graph_key
      ?graph_unlocked
      ?encrypt_title
      ?(resolve_asset_path = Fun.id)
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
  ; selected_sidebar_page = None
  ; node_routes = []
  ; node_base_state = None
  ; open_graph
  ; import_snapshot
  ; model_for_graph
  ; apply_sync_event
  ; sync_cursor
  ; accepted_server_t = None
  ; graph_blocks
  ; graph_sidebar_pages
  ; graph_tag_pages
  ; graph_node_is_tag
  ; graph_node_is_property
  ; graph_page_blocks
  ; graph_node_destination
  ; graph_node_references
  ; graph_tag_objects
  ; graph_normalize_titles
  ; graph_search
  ; graph_due_flashcards
  ; graph_review_flashcard
  ; graph_set_page_favorite
  ; graph_delete_page
  ; flashcards = []
  ; search_results = []
  ; search_query = ""
  ; load_older_journals
  ; has_older_journals
  ; load_cached_graph_key
  ; unlock_graph
  ; provision_graph_key
  ; graph_unlocked
  ; encrypt_title
  ; resolve_asset_path
  ; encrypt_asset_file
  ; journal_page_id
  ; send
  ; upload_file
  ; cleanup_file
  ; sync_connected = false
  ; pending_sync = None
  ; next_pending_request_id = 0
  ; stage_operation
  ; prepare_operation
  ; pending_operations
  ; semantic_queue = []
  ; semantic_active = None
  ; outliner_state = Outliner_state.empty
  ; outliner_optimistic_blocks = None
  ; outliner_commands = []
  ; outliner_revision = 0
  ; save_graph_catalog
  }
;;

let discover_graphs session config =
  debug "graph discovery started";
  match session.send (Api.graphs_request config) with
  | Error message -> Error message
  | Ok response when response.Api.status < 200 || response.Api.status >= 300 ->
    debug
      "graph discovery failed status=%d body=%S"
      response.Api.status
      response.Api.body;
    Error ("Logseq graphs API returned HTTP " ^ string_of_int response.Api.status)
  | Ok response ->
    (try
       session.available_graphs <- Api.graphs_from_graphs_body response.body;
       Option.iter (fun save -> save response.body) session.save_graph_catalog;
       Ok ()
     with exn -> Error ("Could not parse Logseq graphs response: " ^ Printexc.to_string exn))
;;

let upload_initial_graph_snapshot session config ~graph_id ~e2ee =
  let graph_config = { config with Api.graph_id = graph_id } in
  let encrypt_text =
    if not e2ee
    then Ok (fun value -> Ok value)
    else
      match session.encrypt_title with
      | Some encrypt -> Ok (fun value -> encrypt ~graph_id value)
      | None -> Error "E2EE title encryption is unavailable"
  in
  match encrypt_text with
  | Error _ as error -> error
  | Ok encrypt_text ->
    (match Graph_bootstrap.prepare ~graph_id ~e2ee ~encrypt_text with
     | Error _ as error -> error
     | Ok prepared ->
       let upload =
         Api.initial_snapshot_upload_request
           graph_config
           ~file_path:prepared.file_path
           ~checksum:prepared.checksum
       in
       Fun.protect
         ~finally:(fun () -> session.cleanup_file prepared.file_path)
         (fun () ->
           match session.upload_file upload with
           | Ok response when response.status >= 200 && response.status < 300 ->
             debug
               "initial graph snapshot uploaded graph=%s rows=%d"
               graph_id
               prepared.row_count;
             Ok ()
           | Ok response ->
             Error
               (if String.equal response.body ""
                then Printf.sprintf "Initial snapshot upload failed with HTTP %d" response.status
                else response.body)
           | Error message -> Error message))
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

let same_status left right =
  match left, right with
  | None, None -> true
  | Some (left : Model.status), Some (right : Model.status) ->
    String.equal left.uuid right.uuid
  | _ -> false
;;

let same_pending_version (left : Model.block) (right : Model.block) =
  String.equal left.uuid right.uuid
  && String.equal left.title right.title
  && left.updated_at = right.updated_at
  && same_status left.status right.status
  && left.asset_size = right.asset_size
  && left.asset_checksum = right.asset_checksum
  && left.local_path = right.local_path
;;

let pending_block_unchanged session sent =
  Option.fold
    ~none:false
    ~some:(same_pending_version sent)
    (Model.read_block session.model sent.Model.uuid)
;;

let mark_pending_failed_if_unchanged session block =
  if pending_block_unchanged session block
  then ignore (Model.mark_block_sync_failed session.model ~uuid:block.uuid)
;;

let set_pending_active session pump ~transport ~operation ?cleanup_path () =
  session.next_pending_request_id <- session.next_pending_request_id + 1;
  pump.active <-
    Some
      { id = session.next_pending_request_id
      ; transport
      ; operation
      ; cleanup_path
      }
;;

let encrypted_title session config title =
  match session.encrypt_title with
  | Some encrypt -> encrypt ~graph_id:config.Api.graph_id title
  | None -> Error "encrypted graph title encryption is unavailable"
;;

let rec prepare_pending_next session pump =
  match pump.remaining with
  | [] ->
    pump.active <- None;
    session.pending_sync <- None
  | block :: rest ->
    pump.remaining <- rest;
    (match prepare_pending_block session pump block with
     | Ok () -> ()
     | Error message ->
       debug "prepare pending block failed uuid=%s message=%s" block.Model.uuid message;
       mark_pending_failed_if_unchanged session block;
       prepare_pending_next session pump)

and prepare_pending_block session pump (block : Model.block) =
  if Hashtbl.mem pump.authoritative block.uuid
  then
    let title =
      if selected_graph_is_encrypted session
      then encrypted_title session pump.config block.title
      else Ok block.title
    in
    Result.map
      (fun title ->
        set_pending_active
          session
          pump
          ~transport:(Json_request (Api.update_block_request pump.config ~uuid:block.uuid ~title))
          ~operation:(Update_title block)
          ())
      title
  else prepare_pending_creation session pump block

and prepare_pending_creation session pump (block : Model.block) =
  if selected_graph_is_encrypted session
  then
    match encrypted_title session pump.config block.title with
    | Error _ as error -> error
    | Ok title ->
      let journal_day = Model.journal_day_for_ms block.created_at in
      let cached_page = Hashtbl.find_opt pump.resolved_journal_pages journal_day in
      let graph_page =
        match cached_page, session.journal_page_id with
        | Some page_id, _ -> Some page_id
        | None, Some find -> find ~journal_day
        | None, None -> None
      in
      (match graph_page with
       | Some page_id -> prepare_pending_create_request session pump block ~title ~page_id:(Some page_id)
       | None ->
         let page_id = journal_page_uuid journal_day in
         let journal_title = journal_day_title journal_day in
         (match
            encrypted_title session pump.config journal_title,
            encrypted_title session pump.config (String.lowercase_ascii journal_title)
          with
          | Error message, _ | _, Error message -> Error message
          | Ok encrypted_journal_title, Ok encrypted_name ->
            let request =
              Api.encrypted_journal_page_request
                pump.config
                ~uuid:page_id
                ~title:encrypted_journal_title
                ~name:encrypted_name
                ~journal_day
            in
            set_pending_active
              session
              pump
              ~transport:(Json_request request)
              ~operation:(Create_journal { block; encrypted_title = title; page_id; journal_day })
              ();
            Ok ()))
  else
    let page_id = Option.map (fun _ -> block.page_id) block.parent_id in
    prepare_pending_create_request session pump block ~title:block.title ~page_id

and prepare_pending_create_request session pump (block : Model.block) ~title ~page_id =
  match block.status, block.local_path, block.asset_type, block.asset_size, block.asset_checksum with
  | Some status, _, _, _, _ ->
    set_pending_active
      session
      pump
      ~transport:(Json_request (Api.task_request ?page_id pump.config ~uuid:block.uuid ~status:status.uuid title))
      ~operation:(Create_block block)
      ();
    Ok ()
  | None, Some source_path, Some asset_type, Some _asset_size, Some checksum ->
    let source_path = session.resolve_asset_path source_path in
    if selected_graph_is_encrypted session
    then
      (match session.encrypt_asset_file with
       | None -> Error "encrypted asset encryption is unavailable"
       | Some encrypt_asset_file ->
         (match encrypt_asset_file ~graph_id:pump.config.graph_id ~source_path with
          | Error _ as error -> error
          | Ok (file_path, _upload_size) ->
            let upload =
              Api.raw_asset_upload_request
                pump.config
                ~uuid:block.uuid
                ~asset_type
                ~checksum
                ~file_path
                ~content_type:"text/plain"
            in
            set_pending_active
              session
              pump
              ~transport:(File_upload upload)
              ~operation:(Upload_asset block)
              ~cleanup_path:file_path
              ();
            Ok ()))
    else (
      let upload =
        Api.raw_asset_upload_request
          pump.config
          ~uuid:block.uuid
          ~asset_type
          ~checksum
          ~file_path:source_path
          ~content_type:(Api.content_type_for_asset_type asset_type)
      in
      set_pending_active
        session
        pump
        ~transport:(File_upload upload)
        ~operation:(Upload_asset block)
        ();
      Ok ())
  | None, None, None, None, None ->
    let request =
      match block.parent_id with
      | Some parent_uuid when not (String.equal parent_uuid block.page_id) ->
        Api.child_block_request pump.config ~parent_uuid ~uuid:block.uuid title
      | _ -> Api.capture_request ?page_id pump.config ~uuid:block.uuid title
    in
    set_pending_active
      session
      pump
      ~transport:(Json_request request)
      ~operation:(Create_block block)
      ();
    Ok ()
  | _ -> Error "pending block has incomplete semantic REST metadata"
;;

let activate_semantic_request ?t_before session config =
  match session.semantic_active, session.semantic_queue, session.prepare_operation with
  | Some _, _, _ | None, [], _ -> ()
  | None, pending :: rest, Some prepare ->
    (match prepare pending.operation with
     | Error message ->
       debug
         "semantic operation id=%s is waiting for authoritative dependencies: %s"
         pending.operation.Pending_ops.operation_id
         message
     | Ok (outliner_op, tx) ->
       let t_before =
         Option.value
           t_before
           ~default:
             (current_server_t session
              |> Option.value ~default:pending.operation.base_t)
       in
       let request =
         Api.tx_batch_request
           config
           ~t_before
           ~tx_id:pending.operation.operation_id
           ~outliner_op
           ~tx
       in
       session.next_pending_request_id <- session.next_pending_request_id + 1;
       session.semantic_queue <- rest;
       session.semantic_active <-
         Some { id = session.next_pending_request_id; pending; request })
  | None, _ :: _, None -> ()
;;

let enqueue_semantic session _config operation =
  match session.stage_operation, session.prepare_operation with
  | None, _ | _, None -> Error "projected graph operations are unavailable"
  | Some stage, Some _ ->
    (match stage operation with
     | Error _ as error -> error
     | Ok () ->
       session.semantic_queue <- session.semantic_queue @ [ { operation } ];
       Ok ())
;;

(* Editor text keeps page and tag names readable; stored titles use UUID
   references. New hashtags are staged before the title operation. *)
let normalize_operation_titles session (operation : Pending_ops.t) =
  match session.graph_normalize_titles with
  | None -> [ operation ]
  | Some normalize ->
    let created = ref [] in
    let normalize ~uuid titles =
      let titles, new_tags = normalize ~uuid titles in
      created := !created @ new_tags;
      titles
    in
    let intent =
      match operation.Pending_ops.intent with
      | Pending_ops.Save_title { uuid; expected_title; title } ->
        (match normalize ~uuid [ title ] with
         | [ title ] -> Pending_ops.Save_title { uuid; expected_title; title }
         | _ -> operation.Pending_ops.intent)
      | Pending_ops.Insert_block record ->
        (match normalize ~uuid:record.uuid [ record.title ] with
         | [ title ] -> Pending_ops.Insert_block { record with title }
         | _ -> operation.Pending_ops.intent)
      | Pending_ops.Split_block record ->
        (match normalize ~uuid:record.uuid [ record.before; record.after ] with
         | [ before; after ] -> Pending_ops.Split_block { record with before; after }
         | _ -> operation.Pending_ops.intent)
      | Pending_ops.Merge_backward record ->
        (match normalize ~uuid:record.uuid [ record.title ] with
         | [ title ] -> Pending_ops.Merge_backward { record with title }
         | _ -> operation.Pending_ops.intent)
      | intent -> intent
    in
    let create_operations =
      List.map
        (fun (uuid, title) ->
          Pending_ops.
            { operation_id = fresh_squuid ()
            ; base_t = operation.base_t
            ; state = Queued
            ; intent = Create_tag { uuid; title; created_at = now_ms () }
            })
        !created
    in
    create_operations @ [ { operation with Pending_ops.intent } ]
;;

let capture_operations session ~uuid ~title ~now ?status () =
  let base_t =
    current_server_t session
    |> Option.to_result ~none:"A current server cursor is required"
  in
  Result.bind base_t (fun base_t ->
    let journal_day = Model.journal_day_for_ms now in
    let page_uuid = Option.bind session.journal_page_id (fun find -> find ~journal_day) in
    let capture_operation =
      match page_uuid with
      | None ->
        Ok
          Pending_ops.
            { operation_id = fresh_squuid ()
            ; base_t
            ; state = Queued
            ; intent =
                Create_journal
                  { page_uuid = journal_page_uuid journal_day
                  ; block_uuid = uuid
                  ; title
                  ; journal_day
                  ; created_at = now
                  }
            }
      | Some page_uuid ->
        let orders =
          (base_outliner_context session).Outliner_state.blocks
          |> List.filter (fun (block : Model.block) ->
            String.equal block.page_id page_uuid
            && block.parent_id = Some page_uuid)
          |> List.filter_map (fun (block : Model.block) -> block.order)
          |> List.sort String.compare
          |> List.rev
        in
        let last_order = match orders with order :: _ -> Some order | [] -> None in
        Result.map
          (fun order ->
            Pending_ops.
              { operation_id = fresh_squuid ()
              ; base_t
              ; state = Queued
              ; intent =
                  Insert_block
                    { uuid
                    ; title
                    ; page_uuid
                    ; parent_uuid = page_uuid
                    ; order
                    ; created_at = now
                    }
              })
          (Order.between last_order None)
    in
    Result.map
      (fun capture_operation ->
        let status_operations =
          match status with
          | None -> []
          | Some (status : Model.status) ->
            let value =
              match status.ident with
              | Some ident -> Pending_ops.Ref_ident ident
              | None -> Ref_uuid status.uuid
            in
            [ Pending_ops.
                { operation_id = fresh_squuid ()
                ; base_t
                ; state = Queued
                ; intent =
                    Set_property
                      { uuid
                      ; attr = "logseq.property/status"
                      ; expected = None
                      ; value = Some value
                      }
                }
            ]
        in
        normalize_operation_titles session capture_operation @ status_operations)
      capture_operation)
;;

let enqueue_capture session config ~uuid ~title ~now ?status () =
  Result.bind
    (capture_operations session ~uuid ~title ~now ?status ())
    (fun operations ->
      List.fold_left
        (fun result operation ->
          Result.bind result (fun () -> enqueue_semantic session config operation))
        (Ok ())
        operations)
;;

let restore_semantic_queue session _config =
  match session.pending_operations with
  | Some pending_operations ->
    let active_operation_id =
      Option.map
        (fun active -> active.pending.operation.Pending_ops.operation_id)
        session.semantic_active
    in
    session.semantic_queue <-
      pending_operations ()
      |> List.filter (fun operation ->
        active_operation_id <> Some operation.Pending_ops.operation_id)
      |> List.map (fun operation -> { operation })
  | None -> ()
;;

let begin_pending_sync session (config : Api.config) =
  if String.equal (String.trim config.token) ""
  then ()
  else (
    restore_semantic_queue session config;
    activate_semantic_request session config;
    match session.semantic_active, session.pending_sync with
    | Some _, _ -> ()
    | None, Some _ -> ()
    | None, None ->
      let authoritative = Hashtbl.create 64 in
      Option.iter
        (fun blocks ->
          List.iter
            (fun (block : Model.block) -> Hashtbl.replace authoritative block.uuid ())
            blocks)
        (Option.bind session.graph_blocks (fun graph_blocks -> graph_blocks ()));
      let pump =
        { config
        ; remaining = Model.pending_blocks session.model
        ; authoritative
        ; resolved_journal_pages = Hashtbl.create 8
        ; active = None
        }
      in
      session.pending_sync <- Some pump;
      prepare_pending_next session pump)
;;

let finish_semantic_active session active ~succeeded ~accepted_t =
  let state =
    if not succeeded
    then Pending_ops.Retryable
    else
      match accepted_t with
      | Some accepted_t -> Pending_ops.Accepted accepted_t
      | None -> Pending_ops.Submitted
  in
  Option.iter
    (fun stage ->
      ignore (stage { active.pending.operation with state }))
    session.stage_operation;
  if succeeded then Option.iter (record_accepted_server_t session) accepted_t;
  session.semantic_active <- None;
  if succeeded
  then
    Option.iter
      (fun config -> activate_semantic_request ?t_before:accepted_t session config)
      session.config
;;

let cleanup_pending_active session (active : pending_active) =
  Option.iter session.cleanup_file active.cleanup_path
;;

let finish_pending_block session pump block ~succeeded =
  if succeeded
  then (
    if pending_block_unchanged session block
    then ignore (Model.mark_block_submitted session.model ~uuid:block.uuid))
  else mark_pending_failed_if_unchanged session block;
  pump.active <- None;
  prepare_pending_next session pump
;;

let asset_operation_id uuid = "asset:" ^ uuid

let asset_datoms_operation ?(state = Pending_ops.Queued) session (block : Model.block) =
  let base_t =
    current_server_t session
    |> Option.to_result ~none:"A current server cursor is required"
  in
  Result.bind base_t (fun base_t ->
    match block.asset_type, block.asset_size, block.asset_checksum with
    | Some asset_type, Some asset_size, Some asset_checksum ->
      let context = base_outliner_context session in
      let destination =
        match block.parent_id with
        | Some parent_uuid ->
          List.find_opt
            (fun (candidate : Model.block) -> String.equal candidate.uuid parent_uuid)
            context.blocks
          |> Option.map (fun (parent : Model.block) -> parent.page_id, parent_uuid)
        | None ->
          let journal_day = Model.journal_day_for_ms block.created_at in
          Option.bind session.journal_page_id (fun find -> find ~journal_day)
          |> Option.map (fun page_uuid -> page_uuid, page_uuid)
      in
      (match destination with
       | None -> Error "asset destination is not available"
       | Some (page_uuid, parent_uuid) ->
         let last_order =
           context.blocks
           |> List.filter (fun (candidate : Model.block) ->
             String.equal candidate.page_id page_uuid
             && candidate.parent_id = Some parent_uuid
             && not (String.equal candidate.uuid block.uuid))
           |> List.filter_map (fun (candidate : Model.block) -> candidate.order)
           |> List.sort String.compare
           |> List.rev
           |> function order :: _ -> Some order | [] -> None
         in
         Result.map
           (fun order ->
             Pending_ops.
               { operation_id = asset_operation_id block.uuid
               ; base_t
               ; state
               ; intent =
                   Create_asset
                     { uuid = block.uuid
                     ; title = block.title
                     ; page_uuid
                     ; parent_uuid
                     ; order
                     ; created_at = block.created_at
                     ; asset_type
                     ; asset_size
                     ; asset_checksum
                     }
               })
           (Order.between last_order None))
    | _ -> Error "asset metadata is incomplete")
;;

let complete_pending_active session pump (active : pending_active) response =
  let succeeded = response.Api.status >= 200 && response.status < 300 in
  match active.operation with
  | Update_title block when succeeded ->
    (match block.status with
     | Some status ->
       set_pending_active
         session
         pump
         ~transport:(Json_request (Api.update_block_status_request pump.config ~uuid:block.uuid ~status:status.uuid))
         ~operation:(Update_status block)
         ()
     | None -> finish_pending_block session pump block ~succeeded:true)
  | Update_title block | Update_status block ->
    finish_pending_block session pump block ~succeeded
  | Create_journal { block; encrypted_title; page_id; journal_day } when succeeded ->
    Hashtbl.replace pump.resolved_journal_pages journal_day page_id;
    pump.active <- None;
    (match prepare_pending_create_request session pump block ~title:encrypted_title ~page_id:(Some page_id) with
     | Ok () -> ()
     | Error message ->
       debug "prepare pending create after journal failed uuid=%s message=%s" block.uuid message;
       mark_pending_failed_if_unchanged session block;
       prepare_pending_next session pump)
  | Create_journal { block; _ } -> finish_pending_block session pump block ~succeeded:false
  | Upload_asset block when succeeded ->
    (match asset_datoms_operation session block with
     | Error message ->
       debug "prepare asset datoms failed uuid=%s message=%s" block.uuid message;
       finish_pending_block session pump block ~succeeded:false
     | Ok operation ->
       (match enqueue_semantic session pump.config operation with
        | Error message ->
          debug "stage asset datoms failed uuid=%s message=%s" block.uuid message;
          finish_pending_block session pump block ~succeeded:false
        | Ok () ->
          finish_pending_block session pump block ~succeeded:true;
          activate_semantic_request session pump.config))
  | Upload_asset block -> finish_pending_block session pump block ~succeeded:false
  | Create_block block when succeeded ->
    let remote_uuid =
      try Ok (Api.created_block_uuid_from_body response.body)
      with error -> Error (Printexc.to_string error)
    in
    (match remote_uuid with
     | Error message ->
       debug "pending creation response failed uuid=%s message=%s" block.uuid message;
       finish_pending_block session pump block ~succeeded:false
     | Ok remote_uuid ->
       (match block.local_path, block.parent_id with
        | Some _, Some parent_uuid ->
          set_pending_active
            session
            pump
            ~transport:(Json_request (Api.move_block_request pump.config ~uuid:remote_uuid ~target_uuid:parent_uuid))
            ~operation:(Move_created_asset { block; remote_uuid })
            ()
        | _ ->
          let sync_status =
            if pending_block_unchanged session block then "submitted" else "pending"
          in
          ignore
            (Model.reconcile_created_block
               ~sync_status
               session.model
               ~local_uuid:block.uuid
               ~remote_uuid);
          pump.active <- None;
          prepare_pending_next session pump))
  | Create_block block -> finish_pending_block session pump block ~succeeded:false
  | Move_created_asset { block; remote_uuid } when succeeded ->
    let sync_status =
      if pending_block_unchanged session block then "submitted" else "pending"
    in
    ignore
      (Model.reconcile_created_block
         ~sync_status session.model ~local_uuid:block.uuid ~remote_uuid);
    pump.active <- None;
    prepare_pending_next session pump
  | Move_created_asset { block; _ } -> finish_pending_block session pump block ~succeeded:false
;;

let complete_pending_sync session payload =
  let invalid message = Error message in
  let completion_id =
    match from_string payload with
    | `Assoc fields ->
      (match assoc "id" fields with
       | Some (`Int id) when id > 0 -> Some id
       | _ -> None)
    | _ -> None
  in
  let is_stale expected_id =
    Option.fold ~none:false ~some:(fun id -> id < expected_id) completion_id
  in
  let is_finished =
    Option.fold
      ~none:false
      ~some:(fun id -> id <= session.next_pending_request_id)
      completion_id
  in
  let parsed_completion expected_id =
    match from_string payload with
    | `Assoc fields ->
      (match assoc "id" fields with
       | Some (`Int id) when id = expected_id ->
         (match assoc "error" fields, assoc "status" fields with
          | Some (`String message), _ when not (String.equal message "") -> Ok (false, None)
          | _, Some (`Int status) ->
            let rejected, accepted_t =
              match assoc "body" fields with
              | Some (`String body) ->
                (try
                   match from_string body with
                   | `Assoc body_fields ->
                     let rejected =
                       assoc "type" body_fields = Some (`String "tx/reject")
                     in
                     let accepted_t =
                       match assoc "acceptedT" body_fields, assoc "t" body_fields with
                       | Some (`Int accepted_t), _ | _, Some (`Int accepted_t) ->
                         Some accepted_t
                       | _ -> None
                     in
                     rejected, accepted_t
                   | _ -> false, None
                 with _ -> false, None)
              | _ -> false, None
            in
            Ok
              ( status >= 200 && status < 300 && not rejected
              , if rejected then None else accepted_t )
          | _ -> invalid "pending transport returned no HTTP status")
       | Some (`Int _) -> invalid "pending sync request id does not match"
       | _ -> invalid "pending sync completion requires id")
    | _ -> invalid "pending sync completion must be an object"
  in
  match session.semantic_active, session.pending_sync with
  | Some active, _ when is_stale active.id -> Ok ()
  | Some active, _ ->
    (try
       Result.map
         (fun (succeeded, accepted_t) ->
           finish_semantic_active session active ~succeeded ~accepted_t)
         (parsed_completion active.id)
     with error -> invalid ("invalid pending sync completion: " ^ Printexc.to_string error))
  | None, None when is_finished -> Ok ()
  | None, None -> invalid "pending sync is not active"
  | None, Some pump ->
    (match pump.active with
     | None when is_finished -> Ok ()
     | None -> invalid "pending sync has no active request"
     | Some active when is_stale active.id -> Ok ()
     | Some active ->
       (try
          match from_string payload with
          | `Assoc fields ->
            (match assoc "id" fields with
             | Some (`Int id) when id = active.id ->
               let response =
                 match assoc "error" fields, assoc "status" fields with
                 | Some (`String message), _ when not (String.equal message "") -> Error message
                 | _, Some (`Int status) ->
                   let body =
                     match assoc "body" fields with Some (`String body) -> body | _ -> ""
                   in
                   Ok Api.{ status; body }
                 | _ -> Error "pending transport returned no HTTP status"
               in
               cleanup_pending_active session active;
               (match response with
                | Ok response -> complete_pending_active session pump active response
                | Error message ->
                  debug "pending transport failed id=%d message=%s" active.id message;
                  (match active.operation with
                   | Create_block block | Upload_asset block
                   | Update_title block | Update_status block
                   | Move_created_asset { block; _ }
                   | Create_journal { block; _ } ->
                     finish_pending_block session pump block ~succeeded:false));
               Ok ()
             | Some (`Int _) -> invalid "pending sync request id does not match"
             | _ -> invalid "pending sync completion requires id")
          | _ -> invalid "pending sync completion must be an object"
        with error -> invalid ("invalid pending sync completion: " ^ Printexc.to_string error)))
;;

let cancel_pending_sync session =
  (match session.semantic_active with
   | Some active ->
     session.semantic_queue <- active.pending :: session.semantic_queue;
     session.semantic_active <- None
   | None -> ());
  Option.iter
    (fun pump -> Option.iter (cleanup_pending_active session) pump.active)
    session.pending_sync;
  session.pending_sync <- None
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

let reset_outliner session =
  session.outliner_state <- Outliner_state.empty;
  session.outliner_optimistic_blocks <- None;
  session.outliner_commands <- [];
  session.outliner_revision <- session.outliner_revision + 1
;;

let clear_node_navigation session =
  (match session.node_base_state with
   | Some state -> session.outliner_state <- state
   | None -> ());
  session.node_routes <- [];
  session.node_base_state <- None
;;

let persist_active_node_state session =
  match active_node_route session with
  | Some route -> route.state <- session.outliner_state
  | None -> ()
;;

let initial_node_state session route =
  if not route.zoom_to_block
  then Outliner_state.empty
  else
    fst
      (Outliner_state.update
         (node_route_context session route)
         Outliner_state.empty
         (Outliner_state.Zoom_in route.uuid))
;;

let push_node_route session route =
  persist_active_node_state session;
  if session.node_routes = [] then session.node_base_state <- Some session.outliner_state;
  let state = initial_node_state session route in
  route.state <- state;
  session.node_routes <- session.node_routes @ [ route ];
  session.outliner_state <- state;
  session.outliner_commands <- [];
  session.outliner_revision <- session.outliner_revision + 1
;;

let pop_node_route session =
  persist_active_node_state session;
  match List.rev session.node_routes with
  | [] -> ()
  | _ :: remaining_reversed ->
    session.node_routes <- List.rev remaining_reversed;
    (match active_node_route session, session.node_base_state with
     | Some route, _ -> session.outliner_state <- route.state
     | None, Some state ->
       session.outliner_state <- state;
       session.node_base_state <- None
     | None, None -> session.outliner_state <- Outliner_state.empty);
    session.outliner_commands <- [];
    session.outliner_revision <- session.outliner_revision + 1
;;

let toolbar_action = function
  | "task" -> Ok Outliner_state.Task
  | "outdent" -> Ok Outdent
  | "indent" -> Ok Indent
  | "tag" -> Ok Tag_action
  | "pageReference" -> Ok Page_reference
  | "camera" -> Ok Camera
  | "audio" -> Ok Audio
  | "attachment" -> Ok Attachment
  | "hideKeyboard" -> Ok Hide_keyboard
  | "copy" -> Ok Copy
  | "delete" -> Ok Delete
  | "copyReference" -> Ok Copy_reference
  | "copyURL" -> Ok Copy_url
  | "unselect" -> Ok Unselect
  | _ -> Error "unknown outliner toolbar action"
;;

let outliner_message payload =
  let int fields name =
    match List.assoc_opt name fields with
    | Some (`Int value) -> Ok value
    | _ -> Error ("missing integer outliner event field: " ^ name)
  in
  match from_string payload with
  | `Assoc fields ->
    (match required_string "type" fields with
     | Error _ as error -> error
     | Ok "tapBlock" -> Result.map (fun uuid -> Outliner_state.Tap_block uuid) (required_string "uuid" fields)
     | Ok "longPressBlock" ->
       Result.map (fun uuid -> Outliner_state.Long_press_block uuid) (required_string "uuid" fields)
     | Ok "textChanged" ->
       (match required_string "title" fields, int fields "caretUTF16Offset" with
        | Ok title, Ok caret -> Ok (Outliner_state.Text_changed { title; caret })
        | Error message, _ | _, Error message -> Error message)
     | Ok "caretMoved" -> Result.map (fun caret -> Outliner_state.Caret_moved caret) (int fields "caretUTF16Offset")
     | Ok "returnPressed" ->
       (match List.assoc_opt "title" fields, List.assoc_opt "caretUTF16Offset" fields with
        | Some (`String title), Some (`Int caret) ->
          Ok (Outliner_state.Return_pressed_with_text { title; caret })
        | None, None -> Ok Outliner_state.Return_pressed
        | _ -> Error "returnPressed requires both title and caretUTF16Offset")
     | Ok "backspacePressed" ->
       Result.bind (int fields "selectionLength") (fun selection_length ->
         match List.assoc_opt "title" fields with
         | Some (`String title) ->
           Ok (Outliner_state.Backspace_pressed_with_text { title; selection_length })
         | None -> Ok (Outliner_state.Backspace_pressed { selection_length })
         | _ -> Error "backspacePressed title must be a string")
     | Ok "toolbar" ->
       Result.bind (required_string "action" fields) (fun action ->
         Result.map (fun action -> Outliner_state.Toolbar action) (toolbar_action action))
     | Ok "dropBlocks" ->
       (match required_string "targetUuid" fields, required_string "placement" fields with
        | Ok target_uuid, Ok placement ->
          let placement =
            match placement with
            | "before" -> Ok Outliner_state.Before
            | "inside" -> Ok Inside
            | "after" -> Ok After
            | _ -> Error "unknown outliner drop placement"
          in
          Result.map
            (fun placement -> Outliner_state.Drop_blocks { target_uuid; placement })
            placement
        | Error message, _ | _, Error message -> Error message)
     | Ok "chooseAutocomplete" ->
       Result.map
         (fun value -> Outliner_state.Choose_autocomplete value)
         (required_string "value" fields)
     | Ok "confirmDelete" -> Ok Outliner_state.Confirm_delete
     | Ok "saveEditing" -> Ok Outliner_state.Save_editing
     | Ok "cancelEditing" -> Ok Outliner_state.Cancel_editing
     | Ok "toggleCollapsed" ->
       Result.map
         (fun uuid -> Outliner_state.Toggle_collapsed uuid)
         (required_string "uuid" fields)
     | Ok "zoomIn" ->
       Result.map (fun uuid -> Outliner_state.Zoom_in uuid) (required_string "uuid" fields)
     | Ok "zoomOut" -> Ok Outliner_state.Zoom_out
     | Ok "addRootBlock" ->
       Result.map
         (fun uuid -> Outliner_state.Add_root_block uuid)
         (required_string "uuid" fields)
     | Ok "setTaskStatus" ->
       (match required_string "uuid" fields,
              optional_string "statusIdent" fields,
              optional_string "statusUuid" fields with
        | Ok uuid, Ok (Some ident), _ ->
          Ok (Outliner_state.Set_task_status { uuid; status = Ref_ident ident })
        | Ok uuid, Ok None, Ok (Some status_uuid) ->
          Ok (Outliner_state.Set_task_status { uuid; status = Ref_uuid status_uuid })
        | Ok _, Ok None, Ok None -> Error "setTaskStatus requires a status reference"
        | Error message, _, _ | _, Error message, _ | _, _, Error message -> Error message)
     | Ok _ -> Error "unknown outliner event type")
  | _ -> Error "outliner event must be an object"
  | exception _ -> Error "outliner event must be valid JSON"
;;

let outliner_structure_source payload =
  match from_string payload with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields, List.assoc_opt "uuid" fields with
     | Some (`String ("returnPressed" | "backspacePressed")), Some (`String uuid) ->
       Some uuid
     | _ -> None)
  | _ -> None
;;

let outliner_structure_source_matches state payload =
  match outliner_structure_source payload with
  | Some uuid -> Option.equal String.equal (Outliner_state.editing_uuid state) (Some uuid)
  | None -> true
;;

let aggregate_return_context session payload message =
  match
    session.selected_sidebar_page,
    session.node_routes,
    message,
    outliner_structure_source payload,
    session.graph_node_destination
  with
  | None, [], (Outliner_state.Return_pressed | Return_pressed_with_text _),
    Some source_uuid, Some destination ->
    Option.bind (destination source_uuid) (fun (page, _) ->
      Option.map
        (fun context -> context, page.Logseq_chat_graph_read.uuid)
        (page_outliner_context session page.uuid))
  | _ -> None
;;

let dispatch_outliner_event session payload =
  match outliner_message payload with
  | Error message -> failure ~code:"invalid_outliner_event" ~message
  | Ok _ when not (outliner_structure_source_matches session.outliner_state payload) ->
    outliner_patch ~changed_uuids:[] session (outliner_context session)
  | Ok message ->
    let context, aggregate_page_uuid =
      match aggregate_return_context session payload message with
      | Some (context, page_uuid) -> context, Some page_uuid
      | None -> outliner_context session, None
    in
    let previous_state = session.outliner_state in
    let next_state, commands = Outliner_state.update context previous_state message in
    let base_t = projection_server_t session |> Option.value ~default:(-1) in
    (match
       Result.map
         (fun (interpreted : Outliner_effects.result) ->
           { interpreted with
             Outliner_effects.operations =
               List.concat_map (normalize_operation_titles session) interpreted.operations
           })
         (Outliner_effects.interpret
            ~base_t
            ~now:now_ms
            ~fresh_uuid:fresh_squuid
            context
            commands)
     with
     | Error message -> failure ~code:"outliner_command_failed" ~message
     | Ok interpreted ->
       let enqueue_result =
         match interpreted.operations, session.config, base_t with
         | [], _, _ -> Ok ()
         | _, None, _ -> Error "Select a graph before editing"
         | _, _, -1 -> Error "A current server cursor is required"
         | operations, Some config, _ ->
           List.fold_left
             (fun result operation ->
               Result.bind result (fun () -> enqueue_semantic session config operation))
             (Ok ())
             operations
       in
       (match enqueue_result with
       | Error message -> failure ~code:"outliner_effect_failed" ~message
       | Ok () ->
          let projected_context, projected_page_scoped =
            if interpreted.operations = []
            then context, Option.is_some aggregate_page_uuid
            else
              ( project_outliner_operations context interpreted.operations
              , Option.is_some aggregate_page_uuid
                || Option.is_some session.selected_sidebar_page )
          in
          let projected_context =
            let saves_title = List.exists
              (fun operation -> match operation.Pending_ops.intent with Save_title _ -> true | _ -> false)
              interpreted.operations in
            if not saves_title then projected_context
            else
              let live =
                match aggregate_page_uuid with
                | Some page_uuid ->
                  (match page_outliner_context session page_uuid with
                   | Some context -> context
                   | None -> outliner_context session)
                | None -> outliner_context session
              in
              let metadata = Hashtbl.create (List.length live.blocks) in
              List.iter (fun (block : Model.block) -> Hashtbl.replace metadata block.uuid block) live.blocks;
              { projected_context with blocks =
                  List.map (fun (block : Model.block) ->
                    match Hashtbl.find_opt metadata block.uuid with
                    | Some current -> { block with references = current.references; tags = current.tags }
                    | None -> block) projected_context.blocks }
          in
          let next_state =
            List.fold_left
              (fun state operation ->
                fst
                  (Outliner_state.update
                     projected_context
                     state
                     (Operation_staged operation.Pending_ops.intent)))
              next_state
              interpreted.operations
          in
          session.outliner_state <- next_state;
          session.outliner_optimistic_blocks <- Some projected_context.blocks;
          session.outliner_commands <- interpreted.platform;
          session.outliner_revision <- session.outliner_revision + 1;
          let patch_uuids =
            match message, interpreted.operations with
            | Toggle_collapsed _, _ -> None
            | _, operations ->
            match operations with
            | [ { Pending_ops.intent = Save_title { uuid; _ }; _ } ] -> Some [ uuid ]
            | [ { intent = Set_property { uuid; _ }; _ } ] -> Some [ uuid ]
            | [] ->
              (match message with
               | Tap_block _ | Long_press_block _ | Text_changed _ | Caret_moved _
               | Choose_autocomplete _ | Save_editing | Cancel_editing | Toolbar _ -> Some []
               | Return_pressed | Return_pressed_with_text _ | Backspace_pressed _
               | Backspace_pressed_with_text _ | Drop_blocks _ | Confirm_delete
               | Set_task_status _ | Toggle_collapsed _ | Zoom_in _ | Zoom_out
               | Add_root_block _ | Operation_staged _ -> None)
            | _ -> None
          in
          match patch_uuids, session.node_routes with
          | Some changed_uuids, [] -> outliner_patch ~changed_uuids session projected_context
          | Some _, _ :: _ -> snapshot_visible session
          | None, [] when Option.is_some aggregate_page_uuid && not projected_page_scoped ->
            snapshot_visible session
          | None, [] ->
            structural_outliner_patch
              ~anchored:projected_page_scoped
              session
              ~before_context:context
              ~before_state:previous_state
              ~after_context:projected_context
          | None, _ :: _ -> snapshot_visible session))
;;

let switch_graph_model session payload =
  match session.model_for_graph with
  | None -> Ok ()
  | Some model_for_graph ->
    (try
       match from_string payload with
       | `Assoc fields ->
         (match List.assoc_opt "graphId" fields with
          | Some (`String graph_id) when not (String.equal graph_id "") ->
            session.model <- model_for_graph ~graph_id;
            session.accepted_server_t <- None;
            session.pending_sync <- None;
            session.semantic_queue <- [];
            session.semantic_active <- None;
            session.flashcards <- [];
            clear_node_navigation session;
            session.selected_sidebar_page <- None;
            reset_outliner session;
            Ok ()
          | _ -> Error "graph storage payload requires graphId")
       | _ -> Error "graph storage payload must be an object"
     with error -> Error (Printexc.to_string error))
;;

let dispatch session action payload =
  match action with
  | "outlinerEvent" ->
    (match payload with
     | Some payload -> dispatch_outliner_event session payload
     | None -> failure ~code:"invalid_params" ~message:"outlinerEvent requires a JSON payload")
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
             session.accepted_server_t <- None;
             session.config <- Some { Api.base_url; graph_id; graph_name; token };
             (match
                List.find_opt
                  (fun (graph : Api.graph) -> String.equal graph.id graph_id && graph.e2ee)
                  session.available_graphs,
                session.load_cached_graph_key
              with
              | Some _, Some load ->
                Option.iter (fun config -> ignore (load config)) session.config
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
     | None -> graph_catalog_snapshot session
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
          graph_catalog_snapshot session
        | Error message ->
          debug "graph catalog refresh failed: %s" message;
          graph_catalog_snapshot session))
  | "createSyncGraph" ->
    (match session.config, payload with
     | Some config, Some payload ->
       (try
          match from_string payload with
          | `Assoc fields ->
            (match required_string "name" fields,
                   List.assoc_opt "isEncrypted" fields with
             | Ok name, Some (`Bool is_encrypted)
               when not (String.equal (String.trim name) "") ->
               let request =
                 Api.create_graph_request
                   config
                   ~name:(String.trim name)
                   ~schema_version:"65.33"
                   ~e2ee:is_encrypted
               in
               (match session.send request with
                | Ok response when response.status >= 200 && response.status < 300 ->
                  let graph_id =
                    match from_string response.body with
                    | `Assoc response_fields ->
                      (match List.assoc_opt "graph-id" response_fields with
                       | Some (`String value) -> Some value
                       | _ -> None)
                    | _ -> None
                  in
                  let provision_result =
                    match graph_id, is_encrypted, session.provision_graph_key with
                    | Some graph_id, true, Some provision ->
                      provision { config with graph_id; graph_name = Some (String.trim name) }
                    | Some _, true, None -> Error "E2EE key provisioning is unavailable"
                    | _ -> Ok ()
                  in
                  (match graph_id, provision_result with
                   | Some _, Error message ->
                     failure ~code:"graph_key_provision_failed" ~message
                   | Some graph_id, Ok () ->
                     (match upload_initial_graph_snapshot session config ~graph_id ~e2ee:is_encrypted with
                      | Error message ->
                        failure ~code:"graph_initial_upload_failed" ~message
                      | Ok () ->
                        (match discover_graphs session config with
                         | Error message -> failure ~code:"graph_discovery_failed" ~message
                         | Ok () ->
                           session.accepted_server_t <- None;
                           session.config <-
                             Some
                               { config with
                                 graph_id
                               ; graph_name = Some (String.trim name)
                               };
                           snapshot_visible session))
                   | None, _ ->
                     failure ~code:"graph_create_failed" ~message:"Graph creation returned no graph id"
                  )
                | Ok response ->
                  failure
                    ~code:"graph_create_failed"
                    ~message:(if String.equal response.body "" then "Could not create graph" else response.body)
                | Error message -> failure ~code:"graph_create_failed" ~message)
             | Ok _, Some (`Bool _) ->
               failure ~code:"invalid_params" ~message:"Graph name cannot be empty"
             | _ ->
               failure
                 ~code:"invalid_params"
                 ~message:"createSyncGraph requires a name and isEncrypted flag")
          | _ -> failure ~code:"invalid_params" ~message:"createSyncGraph payload must be an object"
        with error -> failure ~code:"invalid_json" ~message:(Printexc.to_string error))
     | None, _ -> failure ~code:"graph_not_configured" ~message:"Configure Logseq before creating a graph"
     | _, None -> failure ~code:"invalid_params" ~message:"createSyncGraph requires a payload")
  | "selectGraph" ->
    (match session.config, payload with
     | Some config, Some graph_id ->
       (match List.find_opt (fun (graph : Api.graph) -> String.equal graph.id graph_id) session.available_graphs with
        | None -> failure ~code:"unknown_graph" ~message:"The selected graph is not available"
        | Some graph when not graph.ready ->
          failure ~code:"graph_not_ready" ~message:"The selected graph is not ready for sync"
        | Some graph ->
          clear_node_navigation session;
          session.selected_sidebar_page <- None;
          reset_outliner session;
          session.accepted_server_t <- None;
          session.config <- Some { config with graph_id = graph.id; graph_name = Some graph.name };
          if graph.e2ee
          then
            Option.iter
              (fun load ->
                Option.iter (fun config -> ignore (load config)) session.config)
              session.load_cached_graph_key;
          snapshot_visible session)
     | _ -> failure ~code:"invalid_params" ~message:"selectGraph requires a graph id")
  | "selectPage" ->
    (match payload, Option.bind session.graph_sidebar_pages (fun load -> load ()) with
     | Some uuid, Some pages ->
       let all_pages = pages.favorites @ pages.recent_pages in
       (match List.find_opt (fun page -> String.equal page.Logseq_chat_graph_read.uuid uuid) all_pages with
        | Some page ->
          clear_node_navigation session;
          session.selected_sidebar_page <- Some page;
          session.related_blocks <-
            (if selected_page_is_tag session
             then []
             else
               Option.bind session.graph_node_references (fun load -> load page.uuid)
               |> Option.value ~default:[]);
          reset_outliner session;
          snapshot_visible session
        | None -> failure ~code:"unknown_page" ~message:"The selected page is not available")
     | _ -> failure ~code:"invalid_params" ~message:"selectPage requires a page id")
  | "openNode" ->
    (match payload with
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "uuid" fields with
           | Ok uuid ->
             let destination =
               match
                 Option.bind session.graph_node_destination (fun resolve -> resolve uuid)
               with
               | Some _ as resolved -> resolved
               | None -> projected_node_destination session uuid
             in
             (match destination with
        | Some (page, zoom_to_block) ->
          let is_tag = Option.fold ~none:false ~some:(fun check -> check uuid) session.graph_node_is_tag in
          let is_property =
            Option.fold ~none:false ~some:(fun check -> check uuid) session.graph_node_is_property
          in
          let related_blocks =
            if is_tag
            then Option.bind session.graph_tag_objects (fun load -> load uuid)
                 |> Option.value ~default:[]
            else Option.bind session.graph_node_references (fun load -> load uuid)
                 |> Option.value ~default:[]
          in
          let route =
            { uuid; is_tag; is_property; page; zoom_to_block; related_blocks
            ; state = Outliner_state.empty
            }
          in
          push_node_route session route;
          snapshot_visible session
        | None -> failure ~code:"unknown_node" ~message:"The referenced node is not available")
           | Error message -> failure ~code:"invalid_params" ~message)
        | _ -> failure ~code:"invalid_params" ~message:"openNode payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"openNode payload must be valid JSON")
     | None -> failure ~code:"invalid_params" ~message:"openNode requires a node id")
  | "closeNode" ->
    pop_node_route session;
    snapshot_visible session
  | "clearSelectedPage" ->
    clear_node_navigation session;
    session.selected_sidebar_page <- None;
    reset_outliner session;
    snapshot_visible session
  | "loadOlderJournals" ->
    Option.iter (fun load -> load ()) session.load_older_journals;
    snapshot_visible session
  | "loadFlashcards" ->
    let now =
      match payload with
      | Some value -> Option.value (int_of_string_opt value) ~default:(now_ms ())
      | None -> now_ms ()
    in
    session.flashcards <-
      Option.fold
        ~none:[]
        ~some:(fun load -> load ~now)
        session.graph_due_flashcards;
    debug "loadFlashcards count=%d now=%d" (List.length session.flashcards) now;
    snapshot_visible session
  | "reviewFlashcard" ->
    (match payload, session.graph_review_flashcard with
     | Some payload, Some review ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "uuid" fields,
                 required_string "rating" fields,
                 optional_int "now" fields,
                 required_string "operationId" fields with
           | Ok uuid, Ok rating, Ok requested_now, Ok operation_id ->
             (match flashcard_rating rating with
              | Error message -> failure ~code:"invalid_params" ~message
              | Ok rating ->
                let now = Option.value requested_now ~default:(now_ms ()) in
                (match review ~uuid ~rating ~now ~operation_id with
                 | Error message -> failure ~code:"flashcard_review_failed" ~message
                 | Ok () ->
                   Option.iter (restore_semantic_queue session) session.config;
                   session.flashcards <-
                     Option.fold
                       ~none:[]
                       ~some:(fun load -> load ~now)
                       session.graph_due_flashcards;
                   snapshot_visible session))
           | Error message, _, _, _ | _, Error message, _, _
           | _, _, Error message, _ | _, _, _, Error message ->
             failure ~code:"invalid_params" ~message)
        | _ -> failure ~code:"invalid_params" ~message:"reviewFlashcard payload must be an object"
        | exception _ ->
          failure ~code:"invalid_json" ~message:"reviewFlashcard payload must be valid JSON")
     | None, _ -> failure ~code:"invalid_params" ~message:"reviewFlashcard requires a payload"
     | _, None -> failure ~code:"flashcards_unavailable" ~message:"No graph is open")
  | "setPageFavorite" ->
    (match payload, session.graph_set_page_favorite, session.config with
     | Some payload, Some set_favorite, Some config ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "pageUuid" fields,
                 required_bool "favorite" fields,
                 required_string "operationId" fields,
                 optional_int "now" fields with
           | Ok page_uuid, Ok favorite, Ok operation_id, Ok requested_now ->
             let now = Option.value requested_now ~default:(now_ms ()) in
             (match set_favorite ~page_uuid ~favorite ~operation_id ~now with
              | Ok () ->
                restore_semantic_queue session config;
                snapshot_visible session
              | Error message -> failure ~code:"set_page_favorite_failed" ~message)
           | Error message, _, _, _ | _, Error message, _, _
           | _, _, Error message, _ | _, _, _, Error message ->
             failure ~code:"invalid_params" ~message)
        | _ -> failure ~code:"invalid_params" ~message:"setPageFavorite payload must be an object"
        | exception _ ->
          failure ~code:"invalid_json" ~message:"setPageFavorite payload must be valid JSON")
     | None, _, _ -> failure ~code:"invalid_params" ~message:"setPageFavorite requires a payload"
     | _, None, _ -> failure ~code:"set_page_favorite_unavailable" ~message:"No graph is open"
     | _, _, None -> failure ~code:"graph_not_configured" ~message:"Select a graph first")
  | "deletePage" ->
    (match payload, session.graph_delete_page, session.config with
     | Some payload, Some delete_page, Some config ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "pageUuid" fields,
                 required_string "operationId" fields,
                 optional_int "now" fields with
           | Ok page_uuid, Ok operation_id, Ok requested_now ->
             let now = Option.value requested_now ~default:(now_ms ()) in
             (match delete_page ~page_uuid ~operation_id ~now with
              | Ok () ->
                restore_semantic_queue session config;
                snapshot_visible session
              | Error message -> failure ~code:"delete_page_failed" ~message)
           | Error message, _, _ | _, Error message, _ | _, _, Error message ->
             failure ~code:"invalid_params" ~message)
        | _ -> failure ~code:"invalid_params" ~message:"deletePage payload must be an object"
        | exception _ ->
          failure ~code:"invalid_json" ~message:"deletePage payload must be valid JSON")
     | None, _, _ -> failure ~code:"invalid_params" ~message:"deletePage requires a payload"
     | _, None, _ -> failure ~code:"delete_page_unavailable" ~message:"No graph is open"
     | _, _, None -> failure ~code:"graph_not_configured" ~message:"Select a graph first")
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
        | Ok () ->
          (match switch_graph_model session payload with
           | Ok () -> snapshot_visible session
           | Error message -> failure ~code:"graph_projection_failed" ~message)
        | Error message -> failure ~code:"snapshot_import_failed" ~message)
     | None, _ -> failure ~code:"snapshot_import_unavailable" ~message:"Snapshot import is unavailable"
     | _, None -> failure ~code:"invalid_params" ~message:"importSnapshot requires a JSON payload")
  | "openGraph" ->
    (match session.open_graph, payload with
     | Some open_graph, Some payload ->
       (match open_graph payload with
        | Ok () ->
          (match switch_graph_model session payload with
           | Ok () -> snapshot_visible session
           | Error message -> failure ~code:"graph_projection_failed" ~message)
        | Error message -> failure ~code:"graph_open_failed" ~message)
     | None, _ -> failure ~code:"graph_open_unavailable" ~message:"Graph storage is unavailable"
     | _, None -> failure ~code:"invalid_params" ~message:"openGraph requires a JSON payload")
  | "startWebSocket" ->
    session.sync_connected <- true;
    snapshot_visible session
  | "applySyncEvent" ->
    (match session.apply_sync_event, payload with
     | Some apply_sync_event, Some event ->
       (match apply_sync_event event with
        | Ok () ->
          reconcile_authoritative_blocks session;
          snapshot_visible session
        | Error message ->
          let code =
            if String.starts_with ~prefix:"snapshot required:" message
               || String.equal message "sync schema mismatch"
            then "snapshot_required"
            else "websocket_apply_failed"
          in
          failure ~code ~message)
     | None, _ ->
       failure ~code:"websocket_unavailable" ~message:"WebSocket sync is unavailable"
     | _, None -> failure ~code:"invalid_params" ~message:"applySyncEvent requires a payload")
  | "stopWebSocket" ->
    session.sync_connected <- false;
    snapshot_visible session
  | "searchNodes" ->
    let query = Option.value payload ~default:"" in
    session.search_query <- query;
    session.search_results <-
      (if String.equal (String.trim query) ""
       then []
       else Option.fold ~none:[] ~some:(fun search -> search query) session.graph_search);
    snapshot_visible session
  | "send" ->
    (match send_payload payload with
     | Error message -> failure ~code:"invalid_params" ~message
     | Ok (text, uuid, now) ->
       if String.equal text ""
       then snapshot_visible session
       else (
         let now = Option.value now ~default:(now_ms ()) in
         let uuid = Option.value uuid ~default:("local-" ^ string_of_int now) in
         match session.config, session.stage_operation, session.prepare_operation with
         | Some config, Some _, Some _ ->
           (match enqueue_capture session config ~uuid ~title:text ~now () with
            | Ok () -> snapshot_visible session
            | Error message -> failure ~code:"capture_failed" ~message)
         | _ ->
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
               let now = Option.value now ~default:(now_ms ()) in
               match session.config, session.stage_operation, session.prepare_operation with
               | Some config, Some _, Some _ ->
                 (match
                    enqueue_capture
                      session
                      config
                      ~uuid
                      ~title:text
                      ~now
                      ~status
                      ()
                  with
                  | Ok () -> snapshot_visible session
                  | Error message -> failure ~code:"capture_failed" ~message)
               | _ ->
                 Model.cache_local_task session.model ~uuid ~title:text ~status ~now;
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
                 required_string "localPath" fields, optional_string "targetBlockId" fields with
           | Ok uuid, Ok title, Ok now, Ok asset_type, Ok (Some asset_size),
             Ok asset_checksum, Ok local_path, Ok target_block_id ->
             let now = Option.value now ~default:(now_ms ()) in
             let asset_type = Api.normalize_asset_type asset_type in
             let before_context = outliner_context session in
             let before_state = session.outliner_state in
             Option.iter
               (fun target_uuid ->
                 if Option.is_none (Model.read_block session.model target_uuid)
                 then
                   let context = base_outliner_context session in
                   match
                     List.find_opt
                       (fun (block : Model.block) -> String.equal block.uuid target_uuid)
                       context.blocks
                   with
                   | Some target -> Model.upsert_blocks session.model [ target ] ~refresh_time:now
                   | None -> ())
               target_block_id;
             Model.cache_local_asset session.model ~uuid ~title ~asset_type ~asset_size
               ~asset_checksum ~local_path ?target_block_id
               ~now;
             let visible_asset_response () =
               match session.selected_sidebar_page, session.node_routes with
               | None, [] ->
                 structural_outliner_patch
                   session
                   ~before_context
                   ~before_state
                   ~after_context:(outliner_context session)
               | Some _, _ | None, _ :: _ -> snapshot_visible session
             in
             (match session.config, session.stage_operation,
                    Model.read_block session.model uuid with
              | Some _, Some stage, Some block ->
                (match asset_datoms_operation ~state:Applied session block with
                 | Ok operation ->
                   (match stage operation with
                   | Ok () -> visible_asset_response ()
                   | Error message -> failure ~code:"stage_operation_failed" ~message)
                 | Error message -> failure ~code:"asset_projection_failed" ~message)
              | _ -> visible_asset_response ())
           | _ -> failure ~code:"invalid_params" ~message:"addAsset requires complete file metadata")
        | _ -> failure ~code:"invalid_params" ~message:"addAsset payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"addAsset payload must be valid JSON")
     | None -> failure ~code:"invalid_params" ~message:"addAsset requires a JSON payload")
  | "addChildBlock" ->
    (match payload with
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "uuid" fields, required_string "title" fields,
                 required_string "parentId" fields, optional_int "now" fields with
           | Ok uuid, Ok title, Ok parent_id, Ok now ->
             let now = Option.value now ~default:(now_ms ()) in
             (match session.config, current_server_t session with
              | Some config, Some base_t ->
                let context = outliner_context session in
                (match
                   List.find_opt
                     (fun (block : Model.block) -> String.equal block.uuid parent_id)
                     context.blocks
                 with
                 | Some parent ->
                   let last_order =
                     context.blocks
                     |> List.filter (fun (block : Model.block) ->
                       String.equal block.page_id parent.page_id
                       && block.parent_id = Some parent.uuid)
                     |> List.filter_map (fun (block : Model.block) -> block.order)
                     |> List.sort String.compare
                     |> List.rev
                     |> function order :: _ -> Some order | [] -> None
                   in
                   (match Order.between last_order None with
                    | Error message -> failure ~code:"invalid_params" ~message
                    | Ok order ->
                      let operation =
                        Pending_ops.
                          { operation_id = fresh_squuid ()
                          ; base_t
                          ; state = Queued
                          ; intent =
                              Insert_block
                                { uuid; title; page_uuid = parent.page_id
                                ; parent_uuid = parent.uuid; order; created_at = now
                                }
                          }
                      in
                      (match enqueue_semantic session config operation with
                       | Ok () -> snapshot_visible session
                       | Error message ->
                         failure ~code:"stage_operation_failed" ~message))
                 | None -> failure ~code:"invalid_params" ~message:"parent block is unavailable")
              | Some _, None ->
                failure ~code:"invalid_params" ~message:"A current server cursor is required"
              | None, _ ->
                (match Model.cache_local_child session.model ~uuid ~title ~parent_id ~now with
                 | Ok () -> snapshot_visible session
                 | Error message -> failure ~code:"invalid_params" ~message))
           | Error message, _, _, _ | _, Error message, _, _
           | _, _, Error message, _ | _, _, _, Error message ->
             failure ~code:"invalid_params" ~message)
        | _ -> failure ~code:"invalid_params" ~message:"addChildBlock payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"addChildBlock payload must be valid JSON")
     | None -> failure ~code:"invalid_params" ~message:"addChildBlock requires a JSON payload")
  | "beginPendingSync" ->
    (match session.config with
     | None -> pending_sync_patch session
     | Some config ->
       (match resolve_graph session config with
        | Ok config ->
          begin_pending_sync session config;
          pending_sync_patch session
        | Error _ -> pending_sync_patch session))
  | "completePendingSync" ->
    (match payload with
     | Some payload ->
       let completing_semantic_operation = Option.is_some session.semantic_active in
       (match complete_pending_sync session payload with
        | Ok () ->
          if completing_semantic_operation
          then pending_sync_patch session
          else snapshot_visible session
        | Error message -> failure ~code:"invalid_pending_sync_completion" ~message)
     | None ->
       failure
         ~code:"invalid_params"
         ~message:"completePendingSync requires a JSON payload")
  | "cancelPendingSync" ->
    cancel_pending_sync session;
    snapshot_visible session
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
    (match payload, session.graph_tag_objects with
     | Some uuid, Some load ->
       session.related_blocks <- Option.value (load uuid) ~default:[];
       snapshot_visible session
     | _, Some _ -> snapshot_visible session
     | Some uuid, None ->
       (match session.config with
        | Some config ->
          (match resolve_graph session config with
           | Ok config -> load_related session (Api.tag_objects_request config uuid) "objects"
           | Error _ -> snapshot_visible session)
        | None -> snapshot_visible session)
     | None, None -> snapshot_visible session)
  | "clearRelated" ->
    session.related_blocks <- [];
    snapshot_visible session
  | "updateBlockStatus" ->
    (match payload with
     | None -> failure ~code:"invalid_params" ~message:"updateBlockStatus requires a JSON payload"
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match session.stage_operation with
           | Some _ ->
             (match required_string "uuid" fields,
                    required_string "operationId" fields,
                    optional_string "expectedStatusUuid" fields,
                    optional_string "expectedStatusIdent" fields,
                    status_payload fields,
                    session.config,
                    current_server_t session with
              | Ok uuid, Ok operation_id, Ok expected_status_uuid, Ok expected_status_ident, Ok status,
                Some config, Some base_t ->
                let expected =
                  match expected_status_ident, expected_status_uuid with
                  | Some ident, _ -> Some (Pending_ops.Ref_ident ident)
                  | None, Some uuid -> Some (Pending_ops.Ref_uuid uuid)
                  | None, None -> None
                in
                let operation =
                  Pending_ops.
                    { operation_id
                    ; base_t
                    ; state = Queued
                    ; intent =
                        Set_property
                          { uuid
                          ; attr = "logseq.property/status"
                          ; expected
                          ; value = Some (status_semantic_ref status)
                          }
                    }
                in
                (match enqueue_semantic session config operation with
                 | Ok () -> snapshot_visible session
                 | Error message -> failure ~code:"stage_operation_failed" ~message)
              | Error message, _, _, _, _, _, _ | _, Error message, _, _, _, _, _
              | _, _, Error message, _, _, _, _ | _, _, _, Error message, _, _, _
              | _, _, _, _, Error message, _, _ ->
                failure ~code:"invalid_params" ~message
              | _, _, _, _, _, _, None ->
                failure ~code:"stale_server_cursor" ~message:"A current server cursor is required"
              | _, _, _, _, _, None, _ ->
                failure ~code:"graph_not_configured" ~message:"Select a graph before editing")
           | None ->
             (match required_string "uuid" fields, status_payload fields with
              | Ok uuid, Ok status ->
                (match Model.update_block_status session.model ~uuid ~status ~now:(now_ms ()) with
                 | Error message -> failure ~code:"unknown_block" ~message
                 | Ok () -> snapshot_visible session)
              | Error message, _ | _, Error message ->
                failure ~code:"invalid_params" ~message))
        | _ -> failure ~code:"invalid_params" ~message:"updateBlockStatus payload must be an object"
        | exception _ ->
          failure ~code:"invalid_json" ~message:"updateBlockStatus payload must be valid JSON"))
  | "updateBlock" ->
    (match payload with
     | None -> failure ~code:"invalid_params" ~message:"updateBlock requires a JSON payload"
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match session.stage_operation with
           | Some _ ->
             (match required_string "uuid" fields,
                    required_string "operationId" fields,
                    required_string "expectedTitle" fields,
                    required_string "title" fields,
                    session.config,
                    current_server_t session with
              | Ok uuid, Ok operation_id, Ok expected_title, Ok title,
                Some config, Some base_t ->
                let title = String.trim title in
                if String.equal title ""
                then failure ~code:"invalid_params" ~message:"updateBlock title must not be empty"
                else
                  let operation =
                    Pending_ops.
                      { operation_id
                      ; base_t
                      ; state = Queued
                      ; intent = Save_title { uuid; expected_title; title }
                      }
                  in
                  (match enqueue_semantic session config operation with
                   | Ok () -> snapshot_visible session
                   | Error message -> failure ~code:"stage_operation_failed" ~message)
              | Error message, _, _, _, _, _ | _, Error message, _, _, _, _
              | _, _, Error message, _, _, _ | _, _, _, Error message, _, _ ->
                failure ~code:"invalid_params" ~message
              | _, _, _, _, _, None ->
                failure ~code:"stale_server_cursor" ~message:"A current server cursor is required"
              | _, _, _, _, None, _ ->
                failure ~code:"graph_not_configured" ~message:"Select a graph before editing")
           | None ->
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
                failure ~code:"invalid_params" ~message))
        | _ -> failure ~code:"invalid_params" ~message:"updateBlock payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"updateBlock payload must be valid JSON"))
  | "splitBlock" ->
    (match payload with
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "uuid" fields,
                 required_string "operationId" fields,
                 optional_int "expectedServerT" fields,
                 required_string "expectedTitle" fields,
                 required_string "before" fields,
                 required_string "after" fields,
                 required_string "newUuid" fields,
                 required_string "newOrder" fields,
                 optional_int "createdAt" fields,
                 session.config,
                 current_server_t session with
           | Ok uuid, Ok operation_id, Ok (Some expected_server_t), Ok expected_title,
             Ok before, Ok after, Ok new_uuid, Ok new_order, Ok (Some created_at),
             Some config, Some current_t
             when expected_server_t = current_t ->
             if String.equal uuid new_uuid
                || String.equal (String.trim new_uuid) ""
                || String.equal (String.trim new_order) ""
             then failure ~code:"invalid_params" ~message:"Invalid split block fragments or identity"
             else
               let operation =
                 Pending_ops.
                   { operation_id
                   ; base_t = current_t
                   ; state = Queued
                   ; intent =
                       Split_block
                         { uuid; expected_title; before; after; new_uuid; new_order; created_at }
                   }
               in
               (match enqueue_semantic session config operation with
                | Ok () -> snapshot_visible session
                | Error message -> failure ~code:"stage_operation_failed" ~message)
           | Error message, _, _, _, _, _, _, _, _, _, _
           | _, Error message, _, _, _, _, _, _, _, _, _
           | _, _, Error message, _, _, _, _, _, _, _, _
           | _, _, _, Error message, _, _, _, _, _, _, _
           | _, _, _, _, Error message, _, _, _, _, _, _
           | _, _, _, _, _, Error message, _, _, _, _, _
           | _, _, _, _, _, _, Error message, _, _, _, _
           | _, _, _, _, _, _, _, Error message, _, _, _
           | _, _, _, _, _, _, _, _, Error message, _, _ ->
             failure ~code:"invalid_params" ~message
           | _, _, Ok None, _, _, _, _, _, _, _, _
           | _, _, _, _, _, _, _, _, Ok None, _, _ ->
             failure ~code:"invalid_params" ~message:"splitBlock requires integer cursor and timestamp"
           | _, _, _, _, _, _, _, _, _, None, _ ->
             failure ~code:"graph_not_configured" ~message:"Select a graph before splitting"
           | _, _, _, _, _, _, _, _, _, _, None ->
             failure ~code:"stale_server_cursor" ~message:"A current server cursor is required"
           | _, _, Ok (Some _), _, _, _, _, _, Ok (Some _), Some _, Some _ ->
             failure ~code:"stale_server_cursor" ~message:"The graph changed before split")
        | _ -> failure ~code:"invalid_params" ~message:"splitBlock payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"splitBlock payload must be valid JSON")
     | None -> failure ~code:"invalid_params" ~message:"splitBlock requires a JSON payload")
  | "mergeBackward" ->
    (match payload with
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "uuid" fields,
                 required_string "operationId" fields,
                 optional_int "expectedServerT" fields,
                 required_string "expectedTitle" fields,
                 required_string "title" fields,
                 required_string "previousUuid" fields,
                 required_string "expectedPreviousTitle" fields,
                 session.config,
                 current_server_t session with
           | Ok uuid, Ok operation_id, Ok (Some expected_server_t), Ok expected_title,
             Ok title, Ok previous_uuid, Ok expected_previous_title, Some config, Some current_t
             when expected_server_t = current_t ->
             if String.equal uuid previous_uuid
             then failure ~code:"invalid_params" ~message:"merge source and target must differ"
             else
               let operation =
                 Pending_ops.
                   { operation_id
                   ; base_t = current_t
                   ; state = Queued
                   ; intent =
                       Merge_backward
                         { uuid
                         ; expected_title
                         ; title
                         ; previous_uuid
                         ; expected_previous_title
                         ; merged_title = None
                         }
                   }
               in
               (match enqueue_semantic session config operation with
                | Ok () -> snapshot_visible session
                | Error message -> failure ~code:"stage_operation_failed" ~message)
           | Error message, _, _, _, _, _, _, _, _
           | _, Error message, _, _, _, _, _, _, _
           | _, _, Error message, _, _, _, _, _, _
           | _, _, _, Error message, _, _, _, _, _
           | _, _, _, _, Error message, _, _, _, _
           | _, _, _, _, _, Error message, _, _, _
           | _, _, _, _, _, _, Error message, _, _ ->
             failure ~code:"invalid_params" ~message
           | _, _, Ok None, _, _, _, _, _, _ ->
             failure ~code:"invalid_params" ~message:"mergeBackward requires expectedServerT"
           | _, _, _, _, _, _, _, None, _ ->
             failure ~code:"graph_not_configured" ~message:"Select a graph before merging"
           | _, _, _, _, _, _, _, _, None ->
             failure ~code:"stale_server_cursor" ~message:"A current server cursor is required"
           | _, _, Ok (Some _), _, _, _, _, Some _, Some _ ->
             failure ~code:"stale_server_cursor" ~message:"The graph changed before merge")
        | _ -> failure ~code:"invalid_params" ~message:"mergeBackward payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"mergeBackward payload must be valid JSON")
     | None -> failure ~code:"invalid_params" ~message:"mergeBackward requires a JSON payload")
  | "moveBlocks" ->
    (match payload with
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "operationId" fields,
                 optional_int "expectedServerT" fields,
                 required_moves fields,
                 session.config,
                 current_server_t session with
           | Ok operation_id, Ok (Some expected_server_t), Ok moves, Some config, Some current_t
             when expected_server_t = current_t ->
             let identities = List.map (fun move -> move.Pending_ops.uuid) moves in
             if moves = [] || List.length identities <> List.length (List.sort_uniq String.compare identities)
             then failure ~code:"invalid_params" ~message:"moveBlocks requires distinct moves"
             else
               let operation =
                 Pending_ops.
                   { operation_id
                   ; base_t = current_t
                   ; state = Queued
                   ; intent = Move_blocks { moves }
                   }
               in
               (match enqueue_semantic session config operation with
                | Ok () -> snapshot_visible session
                | Error message -> failure ~code:"stage_operation_failed" ~message)
           | Error message, _, _, _, _ | _, Error message, _, _, _
           | _, _, Error message, _, _ -> failure ~code:"invalid_params" ~message
           | _, Ok None, _, _, _ ->
             failure ~code:"invalid_params" ~message:"moveBlocks requires expectedServerT"
           | _, _, _, None, _ ->
             failure ~code:"graph_not_configured" ~message:"Select a graph before moving"
           | _, _, _, _, None ->
             failure ~code:"stale_server_cursor" ~message:"A current server cursor is required"
           | _, Ok (Some _), _, Some _, Some _ ->
             failure ~code:"stale_server_cursor" ~message:"The graph changed before move")
        | _ -> failure ~code:"invalid_params" ~message:"moveBlocks payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"moveBlocks payload must be valid JSON")
     | None -> failure ~code:"invalid_params" ~message:"moveBlocks requires a JSON payload")
  | "deleteBlocks" ->
    (match payload with
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "operationId" fields,
                 optional_int "expectedServerT" fields,
                 required_string_list "uuids" fields,
                 session.config,
                 current_server_t session with
           | Ok operation_id, Ok (Some expected_server_t), Ok uuids, Some config, Some current_t
             when expected_server_t = current_t ->
             let uuids = List.sort_uniq String.compare uuids in
             if uuids = []
             then failure ~code:"invalid_params" ~message:"deleteBlocks requires block ids"
             else
               let operation =
                 Pending_ops.
                   { operation_id
                   ; base_t = current_t
                   ; state = Queued
                   ; intent = Delete_blocks { uuids }
                   }
               in
               (match enqueue_semantic session config operation with
                | Ok () -> snapshot_visible session
                | Error message -> failure ~code:"stage_operation_failed" ~message)
           | Error message, _, _, _, _ | _, Error message, _, _, _
           | _, _, Error message, _, _ -> failure ~code:"invalid_params" ~message
           | _, Ok None, _, _, _ ->
             failure ~code:"invalid_params" ~message:"deleteBlocks requires expectedServerT"
           | _, _, _, None, _ ->
             failure ~code:"graph_not_configured" ~message:"Select a graph before deleting"
           | _, _, _, _, None ->
             failure ~code:"stale_server_cursor" ~message:"A current server cursor is required"
           | _, Ok (Some _), _, Some _, Some _ ->
             failure ~code:"stale_server_cursor" ~message:"The graph changed before delete")
        | _ -> failure ~code:"invalid_params" ~message:"deleteBlocks payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"deleteBlocks payload must be valid JSON")
     | None -> failure ~code:"invalid_params" ~message:"deleteBlocks requires a JSON payload")
  | "deleteBlock" ->
    (match payload with
     | Some payload ->
       (match from_string payload with
        | `Assoc fields ->
          (match required_string "uuid" fields,
                 required_string "operationId" fields,
                 optional_int "expectedServerT" fields,
                 session.config,
                 current_server_t session with
           | Ok uuid, Ok operation_id, Ok (Some expected_server_t), Some config, Some current_t
             when expected_server_t = current_t ->
             let operation =
               Pending_ops.
                 { operation_id
                 ; base_t = current_t
                 ; state = Queued
                 ; intent = Delete_blocks { uuids = [ uuid ] }
                 }
             in
             (match enqueue_semantic session config operation with
              | Ok () -> snapshot_visible session
              | Error message -> failure ~code:"stage_operation_failed" ~message)
           | Error message, _, _, _, _ | _, Error message, _, _, _
           | _, _, Error message, _, _ -> failure ~code:"invalid_params" ~message
           | _, _, Ok None, _, _ ->
             failure ~code:"invalid_params" ~message:"deleteBlock requires expectedServerT"
           | _, _, _, None, _ ->
             failure ~code:"graph_not_configured" ~message:"Select a graph before deleting"
           | _, _, _, _, None ->
             failure ~code:"stale_server_cursor" ~message:"A current server cursor is required"
           | _, _, Ok (Some _), Some _, Some _ ->
             failure ~code:"stale_server_cursor" ~message:"The graph changed before delete")
        | _ -> failure ~code:"invalid_params" ~message:"deleteBlock payload must be an object"
        | exception _ -> failure ~code:"invalid_json" ~message:"deleteBlock payload must be valid JSON")
     | None -> failure ~code:"invalid_params" ~message:"deleteBlock requires a JSON payload")
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
