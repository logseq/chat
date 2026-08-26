(ns logseq-chat.model)

(defn initial []
  (record chat-model
    (selected-graph None)
    (sync-state OfflineState)
    (search-open false)
    (search-query "")))

(defn update [current action]
  (match action
    (SelectGraph graph-name)
    (assoc current :selected-graph (Some graph-name))

    BeginSync
    (assoc current :sync-state SyncingState)

    SyncSucceeded
    (assoc current :sync-state SyncedState)

    (SyncFailed reason)
    (assoc current :sync-state (FailedState reason))

    OpenSearch
    (assoc current :search-open true)

    (ChangeSearchQuery query)
    (assoc current :search-query query)

    CloseSearch
    (assoc current :search-open false :search-query "")))
