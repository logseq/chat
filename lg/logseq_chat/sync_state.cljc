(ns logseq-chat.sync-state)

(defn apply-change-set-error
  [state-graph-id state-schema-version state-applied-server-t
   format-version change-graph-id change-schema-version change-t-before change-t]
  (if (not (= format-version 1))
    (Some "unsupported-format")
    (if (not (= change-graph-id state-graph-id))
      (Some "graph-mismatch")
      (if (not (= change-schema-version state-schema-version))
        (Some "schema-mismatch")
        (if (not (= change-t-before state-applied-server-t))
          (Some "cursor-mismatch")
          (if (< change-t change-t-before)
            (Some "invalid-cursor")
            None))))))
