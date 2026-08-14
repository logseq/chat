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

let apply_change_set
      (state : t)
      (change : Logseq_chat_sync_protocol.change_set)
      ~apply
  =
  let open Logseq_chat_sync_protocol in
  if change.format_version <> 1
  then Error Unsupported_format
  else if not (String.equal change.graph_id state.graph_id)
  then Error Graph_mismatch
  else if not (String.equal change.schema_version state.schema_version)
  then Error Schema_mismatch
  else if change.t_before <> state.applied_server_t
  then Error Cursor_mismatch
  else if change.t < change.t_before
  then Error Invalid_cursor
  else
    match apply change with
    | Error message -> Error (Apply_failed message)
    | Ok () ->
      state.applied_server_t <- change.t;
      Ok ()
;;
