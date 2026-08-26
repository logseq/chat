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

let apply_response encoded =
  let action =
    match Snapshot.decode_response encoded with
    | Ok snapshot ->
      LG.ApplyCoreSnapshot
        ( snapshot.graph_name
        , snapshot.sync_connected
        , snapshot.search_query
        , Rrbvec.of_list (List.map search_hit snapshot.search_results)
        , Rrbvec.of_list (List.map outline_row snapshot.outliner_rows) )
    | Error message -> LG.SyncFailed message
  in
  LG.logseq_chat_native_bridge_flush_action_bang action
;;

let () = Callback.register "logseq_chat_lui_apply_snapshot" apply_response
