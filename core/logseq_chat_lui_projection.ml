module LG = Logseq_chat_lui_native
module Snapshot = Logseq_chat_lui_snapshot

let search_hit (hit : Snapshot.search_hit) : LG.search_hit =
  { uuid = hit.uuid
  ; title = hit.title
  ; breadcrumb = hit.breadcrumb
  ; is_page = hit.is_page
  }
;;

let rec node_projection (route : Snapshot.node_route) : LG.node_projection =
  { uuid = route.uuid
  ; page_uuid = route.page_uuid
  ; title = route.title
  ; is_tag = route.is_tag
  ; is_property = route.is_property
  ; related_rows = Rrbvec.of_list (List.map outline_row route.related_rows)
  ; linked_reference_rows =
      Rrbvec.of_list (List.map outline_row route.linked_reference_rows)
  }
and outline_row (row : Snapshot.outline_row) : LG.outline_row =
  { uuid = row.uuid
  ; title = row.title
  ; markup_json = row.markup_json
  ; youtube_target_url = row.youtube_target_url
  ; breadcrumb = row.breadcrumb
  ; opens_as_page = row.opens_as_page
  ; depth = row.depth
  ; has_children = row.has_children
  ; is_collapsed = row.is_collapsed
  }
;;

let sidebar_page (page : Snapshot.sidebar_page) : LG.sidebar_page =
  { uuid = page.uuid; title = page.title }
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

let outliner_row_splice (splice : Snapshot.outliner_row_splice) : LG.outline_row_splice =
  { start = splice.start
  ; after_block_id = splice.after_block_id
  ; before_block_id = splice.before_block_id
  ; delete_count = splice.delete_count
  ; rows = Rrbvec.of_list (List.map outline_row splice.rows)
  }
;;

let apply_response encoded =
  let action =
    match Snapshot.decode_response encoded with
    | Ok snapshot ->
      LG.ApplyCoreSnapshot
        ( snapshot.graph_name
        , sidebar_projection snapshot
        , Rrbvec.of_list (List.map flashcard snapshot.flashcards)
        , snapshot.sync_connected
        , snapshot.search_query
        , Rrbvec.of_list (List.map search_hit snapshot.search_results)
        , Rrbvec.of_list (List.map node_projection snapshot.node_routes)
        , Option.map outliner_editing snapshot.outliner_editing
        , Option.map outliner_autocomplete snapshot.outliner_autocomplete
        , Rrbvec.of_list
            (List.mapi
               outliner_autocomplete_candidate
               snapshot.outliner_autocomplete_candidates)
        , Rrbvec.of_list snapshot.outliner_selected_block_ids
        , Rrbvec.of_list (List.map outline_row snapshot.outliner_rows)
        , snapshot.is_outliner_patch
        , Rrbvec.of_list
            (List.map outliner_row_splice snapshot.outliner_row_splices) )
    | Error message -> LG.SyncFailed message
  in
  LG.logseq_chat_native_bridge_flush_action_bang action
;;

let () = Callback.register "logseq_chat_lui_apply_snapshot" apply_response
