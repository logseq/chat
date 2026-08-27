module LG = Logseq_chat_lui_native
module Host_update = Logseq_chat_lui_host_update
module Snapshot = Logseq_chat_lui_snapshot

let sidebar_page (page : Snapshot.sidebar_page) : LG.sidebar_page =
  { uuid = page.uuid; title = page.title }
;;

let search_hit (hit : Snapshot.search_hit) : LG.search_hit =
  { uuid = hit.uuid
  ; title = hit.title
  ; breadcrumb = hit.breadcrumb
  ; breadcrumbs = Rrbvec.of_list (List.map sidebar_page hit.breadcrumbs)
  ; is_page = hit.is_page
  }
;;

let rec outline_row (row : Snapshot.outline_row) : LG.outline_row =
  { uuid = row.uuid
  ; title = row.title
  ; markup_json = row.markup_json
  ; youtube_target_url = row.youtube_target_url
  ; breadcrumb = row.breadcrumb
  ; breadcrumbs = Rrbvec.of_list (List.map sidebar_page row.breadcrumbs)
  ; opens_as_page = row.opens_as_page
  ; depth = row.depth
  ; has_children = row.has_children
  ; is_collapsed = row.is_collapsed
  ; is_asset = row.is_asset
  ; asset_type = row.asset_type
  ; local_path = row.local_path
  ; status =
      Option.map
        (fun (status : Snapshot.task_status) : LG.task_status ->
           { uuid = status.uuid
           ; ident = status.ident
           ; title = status.title
           ; icon_type = status.icon_type
           ; icon_id = status.icon_id
           ; icon_color = status.icon_color
           })
        row.status
  ; tags =
      Rrbvec.of_list
        (List.map
           sidebar_page
           row.tags)
  ; sync_status = row.sync_status
  ; page_id = row.page_id
  ; journal_title = row.journal_title
  ; journal_day = row.journal_day
  }
;;

let sidebar_projection (snapshot : Snapshot.t) : LG.sidebar_projection =
  { favorites = Rrbvec.of_list (List.map sidebar_page snapshot.favorites)
  ; recent_pages = Rrbvec.of_list (List.map sidebar_page snapshot.recent_pages)
  ; selected_page = Option.map sidebar_page snapshot.selected_page
  ; selected_page_is_tag = snapshot.selected_page_is_tag
  ; selected_page_is_property = snapshot.selected_page_is_property
  ; related_rows = Rrbvec.of_list (List.map outline_row snapshot.related_rows)
  ; linked_reference_rows =
      Rrbvec.of_list (List.map outline_row snapshot.linked_reference_rows)
  }
;;

let graph (graph : Snapshot.graph) : LG.graph =
  { id = graph.id
  ; name = graph.name
  ; is_encrypted = graph.is_encrypted
  ; is_ready = graph.is_ready
  }
;;

let task_status (status : Snapshot.task_status) : LG.task_status =
  { uuid = status.uuid
  ; ident = status.ident
  ; title = status.title
  ; icon_type = status.icon_type
  ; icon_id = status.icon_id
  ; icon_color = status.icon_color
  }
;;

let flashcard (card : Snapshot.flashcard) : LG.flashcard =
  { uuid = card.uuid
  ; question_hidden = card.question_hidden
  ; question_revealed = card.question_revealed
  ; answer_rows =
      Rrbvec.of_list
        (List.mapi
           (fun index (answer : Snapshot.flashcard_answer) : LG.flashcard_answer_row ->
              { uuid = answer.uuid; index; text = answer.text })
           card.answer_rows)
  ; has_cloze = card.has_cloze
  }
;;

let outliner_editing (editing : Snapshot.outliner_editing) : LG.outliner_editing =
  { uuid = editing.uuid
  ; title = editing.title
  ; caret_utf16_offset = editing.caret_utf16_offset
  }
;;

let outliner_autocomplete_kind = function
  | Snapshot.Node -> LG.NodeAutocomplete
  | Tag -> TagAutocomplete
  | Property -> PropertyAutocomplete
;;

let outliner_autocomplete
    (autocomplete : Snapshot.outliner_autocomplete)
  : LG.outliner_autocomplete
  =
  { kind = outliner_autocomplete_kind autocomplete.kind
  ; query = autocomplete.query
  }
;;

let outliner_autocomplete_candidate
    index
    (candidate : Snapshot.outliner_autocomplete_candidate)
  : LG.outliner_autocomplete_candidate
  =
  { index; label = candidate.label; value = candidate.value }
;;

let node_projection (route : Snapshot.node_route) : LG.node_projection =
  { uuid = route.uuid
  ; page_uuid = route.page_uuid
  ; title = route.title
  ; is_tag = route.is_tag
  ; is_property = route.is_property
  ; outliner_rows = Rrbvec.of_list (List.map outline_row route.outliner_rows)
  ; related_rows = Rrbvec.of_list (List.map outline_row route.related_rows)
  ; linked_reference_rows =
      Rrbvec.of_list (List.map outline_row route.linked_reference_rows)
  ; outliner_editing = Option.map outliner_editing route.outliner_editing
  ; outliner_autocomplete =
      Option.map outliner_autocomplete route.outliner_autocomplete
  ; outliner_autocomplete_candidates =
      Rrbvec.of_list
        (List.mapi
           outliner_autocomplete_candidate
           route.outliner_autocomplete_candidates)
  ; outliner_selected_block_ids =
      Rrbvec.of_list route.outliner_selected_block_ids
  }
;;

let outliner_row_splice (splice : Snapshot.outliner_row_splice) : LG.outline_row_splice =
  { start = splice.start
  ; after_block_id = splice.after_block_id
  ; before_block_id = splice.before_block_id
  ; delete_count = splice.delete_count
  ; rows = Rrbvec.of_list (List.map outline_row splice.rows)
  }
;;

let core_projection (snapshot : Snapshot.t) : LG.core_projection =
  { graph_name = snapshot.graph_name
  ; selected_graph_id = snapshot.selected_graph_id
  ; graphs = Rrbvec.of_list (List.map graph snapshot.graphs)
  ; is_graph_encrypted = snapshot.is_graph_encrypted
  ; is_graph_unlocked = snapshot.is_graph_unlocked
  ; sidebar = sidebar_projection snapshot
  ; task_statuses = Rrbvec.of_list (List.map task_status snapshot.task_statuses)
  ; flashcards = Rrbvec.of_list (List.map flashcard snapshot.flashcards)
  ; sync_connected = snapshot.sync_connected
  ; applied_server_t = snapshot.applied_server_t
  ; has_pending_semantic_operations = snapshot.has_pending_semantic_operations
  ; has_pending_sync_request = snapshot.has_pending_sync_request
  ; is_pending_sync_patch = snapshot.is_pending_sync_patch
  ; search_query = snapshot.search_query
  ; search_results = Rrbvec.of_list (List.map search_hit snapshot.search_results)
  ; node_routes = Rrbvec.of_list (List.map node_projection snapshot.node_routes)
  ; journal_outliner_rows =
      Rrbvec.of_list (List.map outline_row snapshot.journal_outliner_rows)
  ; outliner_editing = Option.map outliner_editing snapshot.outliner_editing
  ; outliner_autocomplete =
      Option.map outliner_autocomplete snapshot.outliner_autocomplete
  ; outliner_autocomplete_candidates =
      Rrbvec.of_list
        (List.mapi
           outliner_autocomplete_candidate
           snapshot.outliner_autocomplete_candidates)
  ; outliner_selected_block_ids = Rrbvec.of_list snapshot.outliner_selected_block_ids
  ; outliner_rows = Rrbvec.of_list (List.map outline_row snapshot.outliner_rows)
  ; has_older_journals = snapshot.has_older_journals
  ; is_outliner_patch = snapshot.is_outliner_patch
  ; outliner_row_splices =
      Rrbvec.of_list (List.map outliner_row_splice snapshot.outliner_row_splices)
  }
;;

let apply_response encoded =
  let action =
    match Snapshot.decode_response encoded with
    | Ok snapshot -> LG.ApplyCoreSnapshot (core_projection snapshot)
    | Error message -> LG.SyncFailed message
  in
  LG.logseq_chat_native_bridge_flush_action_bang action
;;

let runtime_log_record (record : Host_update.runtime_log_record) : LG.runtime_log_record =
  { id = record.id
  ; level = record.level
  ; source = record.source
  ; timestamp = record.timestamp
  ; message = record.message
  }
;;

let apply_host_update kind payload =
  let action =
    match Host_update.decode kind payload with
    | Ok (Settings settings) ->
      LG.ApplySettingsSnapshot
        { appearance = settings.appearance
        ; language = settings.language
        ; spell_check = settings.spell_check
        ; auto_correction = settings.auto_correction
        ; sidebar_tabs = Rrbvec.of_list settings.sidebar_tabs
        ; base_url = settings.base_url
        ; version = settings.version
        ; revision = settings.revision
        }
    | Ok (Runtime_log records) ->
      LG.ApplyRuntimeLog (Rrbvec.of_list (List.map runtime_log_record records))
    | Ok (Local_graph_ids graph_ids) ->
      LG.ApplyLocalGraphIds (Rrbvec.of_list graph_ids)
    | Ok (Composer_draft draft) -> LG.ApplyComposerDraft draft
    | Ok (Graph_loading loading) -> LG.ApplyGraphLoading loading
    | Ok (Authentication authentication) ->
      LG.ApplyAuthentication
        (authentication.state, authentication.error_message)
    | Ok Open_capture -> LG.ExpandComposer
    | Error message -> LG.SyncFailed message
  in
  LG.logseq_chat_native_bridge_flush_action_bang action
;;

let register_callbacks () =
  Callback.register "logseq_chat_lui_apply_snapshot" apply_response;
  Callback.register "logseq_chat_lui_apply_host_update" apply_host_update
;;
