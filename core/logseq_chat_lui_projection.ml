module LG = Logseq_chat_lui_native
module Snapshot = Logseq_chat_lui_snapshot

let search_hit (hit : Snapshot.search_hit) : LG.search_hit =
  { uuid = hit.uuid
  ; title = hit.title
  ; breadcrumb = hit.breadcrumb
  ; is_page = hit.is_page
  }
;;

let outline_row (row : Snapshot.outline_row) : LG.outline_row =
  { uuid = row.uuid
  ; title = row.title
  ; depth = row.depth
  ; has_children = row.has_children
  ; is_collapsed = row.is_collapsed
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
        , snapshot.sync_connected
        , snapshot.search_query
        , Rrbvec.of_list (List.map search_hit snapshot.search_results)
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
