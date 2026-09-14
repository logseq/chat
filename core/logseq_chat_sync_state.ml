type error =
  | Unsupported_format
  | Graph_mismatch
  | Schema_mismatch
  | Cursor_mismatch
  | Invalid_cursor
  | Apply_failed of string

type t =
  { graph_id : string
  ; schema_version : string
  ; mutable applied_server_t : int
  }

let create ~graph_id ~schema_version ~applied_server_t =
  { graph_id; schema_version; applied_server_t }
;;

let applied_server_t state = state.applied_server_t

let submission_accepted _state ~server_t:_ = ()

let error_of_lg_code = function
  | "unsupported-format" -> Unsupported_format
  | "graph-mismatch" -> Graph_mismatch
  | "schema-mismatch" -> Schema_mismatch
  | "cursor-mismatch" -> Cursor_mismatch
  | "invalid-cursor" -> Invalid_cursor
  | code -> Apply_failed ("Unknown LG sync-state error: " ^ code)
;;

let apply_change_set
      (state : t)
      (change : Logseq_chat_sync_protocol.change_set)
      ~apply
  =
  let open Logseq_chat_sync_protocol in
  match
    Logseq_chat_lg_core_native.logseq_chat_sync_state_apply_change_set_error
      state.graph_id
      state.schema_version
      state.applied_server_t
      change.format_version
      change.graph_id
      change.schema_version
      change.t_before
      change.t
  with
  | Some code -> Error (error_of_lg_code code)
  | None ->
    match apply change with
    | Error message -> Error (Apply_failed message)
    | Ok () ->
      state.applied_server_t <- change.t;
      Ok ()
;;
