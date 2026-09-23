let apply_change_set_error state_graph_id state_schema_version
    state_applied_server_t format_version change_graph_id
    change_schema_version change_t_before change_t =
  if format_version <> 1 then Some "unsupported-format"
  else if change_graph_id <> state_graph_id then Some "graph-mismatch"
  else if change_schema_version <> state_schema_version then
    Some "schema-mismatch"
  else if change_t_before <> state_applied_server_t then Some "cursor-mismatch"
  else if change_t < change_t_before then Some "invalid-cursor"
  else None
