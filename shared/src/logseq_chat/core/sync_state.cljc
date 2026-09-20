(ns logseq-chat.sync-state)

(defn apply-change-set-error
  [state-graph-id state-schema-version state-applied-server-t
   format-version change-graph-id change-schema-version change-t-before change-t]
  (cond
    (not= format-version 1) (Some "unsupported-format")
    (not= change-graph-id state-graph-id) (Some "graph-mismatch")
    (not= change-schema-version state-schema-version) (Some "schema-mismatch")
    (not= change-t-before state-applied-server-t) (Some "cursor-mismatch")
    (< change-t change-t-before) (Some "invalid-cursor")
    :else None))
