(ns logseq-chat.graph-runtime
  (:require [logseq-chat.pending-ops :as ops]
            [logseq-chat.pending-projection :as projection]
            [logseq-chat.graph-read :as read]
            [logseq-chat.search-index :as index]
            [logseq-chat.sync-tx :as sync-tx]
            [logseq-chat.cache-model :as model]
            [logseq-chat.flashcards :as cards]
            [logseq-chat.fractional-order :as order]
            [logseq-chat.journal :as journal]
            [ocaml.Datascript :as ds]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]))

(type-record runtime-options
             (encrypt-title :fn<string;result<string;string>>)
             (search-index-path :option<string>) (auto-create-today :bool))

(type-record runtime-state
             (server-t :int) (snapshot :projection/pending-projection-snapshot)
             (sidebar-cache :option<tuple<Datascript.db;read/sidebar-pages>>)
             (prepared :map<string;ops/pending-operation>)
             (journal-limit :int) (search-index-is-fresh :bool))

(type-record graph-runtime
             (path :string) (conn :Datascript.conn)
             (encrypt-title :fn<string;result<string;string>>)
             (search-index :option<index/search-index>) (state :ref<runtime-state>))

(def default-options
  (record runtime-options (encrypt-title (fn [value] (Ok value)))
          (search-index-path nil) (auto-create-today false)))

(defn state [runtime] @(:state runtime))

(defn db [runtime] (:db (:snapshot (state runtime))))

(defn operation-statuses [runtime] (:statuses (:snapshot (state runtime))))

(defn trace-stage [metric started stage]
  (when (= (sys/getenv-opt "LOGSEQ_CHAT_TRACE_STARTUP") (Some "1"))
    (stdlib/prerr-endline
     (str metric " stage=" stage " elapsed_ms="
          (format "%.3f" (* (- (unix/gettimeofday) started) 1000.0))))))

(defn search-error [stage error]
  (stdlib/prerr-endline
   (str "LOGSEQ_SEARCH_INDEX_ERROR stage=" stage " error=" (Printexc/to-string error))))

(defn refresh-search [runtime]
  (when-some [search-index (:search-index runtime)]
    (try
      (index/refresh search-index (db runtime))
      (swap! (:state runtime) assoc :search-index-is-fresh true)
      (catch error
             (search-error "refresh" error)
        (swap! (:state runtime) assoc :search-index-is-fresh false))))
  (stdlib/ignore 0))

(defn refresh-search-affected [runtime before intent]
  (when (:search-index-is-fresh (state runtime))
    (when-some [search-index (:search-index runtime)]
      (try (index/refresh-uuids search-index before (db runtime) (ops/affected-uuids before intent))
           (catch (Failure _) (stdlib/ignore (swap! (:state runtime) assoc :search-index-is-fresh false))))))
  (stdlib/ignore 0))

(defn refresh-search-after-rebase [runtime before operations changed-uuids]
  (when (:search-index-is-fresh (state runtime))
    (when-some [search-index (:search-index runtime)]
      (let [after (db runtime)
            affected (into (vec changed-uuids)
                           (mapcat (fn [operation]
                                     (concat (ops/affected-uuids before (:intent operation))
                                             (ops/affected-uuids after (:intent operation))))
                                   operations))]
        (try (index/refresh-uuids search-index before after affected)
             (catch (Failure _) (stdlib/ignore (swap! (:state runtime) assoc :search-index-is-fresh false)))))))
  (stdlib/ignore 0))

(defn confirmed-operation? [confirmed server-t authoritative operation]
  (or (and (contains? confirmed (:operation-id operation))
           (projection/satisfied authoritative (:intent operation)))
      (and (match (:state operation) ops/Submitted true (ops/Accepted _) true _ false)
           (projection/satisfied authoritative (:intent operation)))
      (ops/committed-despite-later-changes? server-t authoritative operation)))

(defn rebase-operation [runtime server-t projected operation]
  (let [persist-conflict (fn [operation message]
                           (ops/save (:path runtime) (assoc operation :state (ops/Conflicted message)))
                           (ops/Conflicted message))
        apply-tx (fn [tx] (swap! projected #(ds/db-with (apply list tx) %)) ops/Applied)]
    (match (:state operation)
      (ops/Conflicted message) (ops/Conflicted message)
      (or (ops/Accepted _) ops/Applied)
      (match (projection/compile @projected (:intent operation))
        (Ok tx) (apply-tx tx)
        (Error message) (persist-conflict operation message))
      _
      (do
        (swap! (:state runtime) update :prepared dissoc (:operation-id operation))
        (match (if (and (not= (:base-t operation) server-t) (not (ops/safe-to-rebase? (:intent operation))))
                 (Error "the server changed while the structural operation was pending")
                 (projection/compile @projected (:intent operation)))
          (Error message) (persist-conflict (assoc operation :base-t server-t) message)
          (Ok tx)
          (do (apply-tx tx)
              (when (not= (:base-t operation) server-t)
                (ops/save (:path runtime) (assoc operation :base-t server-t :state ops/Queued)))
              ops/Applied))))))

(defn rebase [runtime server-t operation-ids changed-uuids]
  (let [started (unix/gettimeofday) confirmed (set operation-ids)
        before (db runtime) authoritative (ds/conn-db (:conn runtime))]
    (swap! (:state runtime) update :prepared #(reduce dissoc % operation-ids))
    (let [operations (filterv (fn [operation]
                                (if (confirmed-operation? confirmed server-t authoritative operation)
                                  (do (ops/remove (:path runtime) (:operation-id operation)) false)
                                  true))
                              (ops/list (:path runtime)))
          projected (atom authoritative)]
      (trace-stage "LOGSEQ_REBASE_METRIC" started "confirmed")
      (swap! (:state runtime) assoc :server-t server-t)
      (let [statuses (mapv (fn [operation]
                             (tuple (:operation-id operation) (rebase-operation runtime server-t projected operation)))
                           operations)]
        ;; Publish the projection already built during reconciliation, without replaying it.
        (swap! (:state runtime) assoc :snapshot
               (record projection/pending-projection-snapshot (db @projected) (server-t server-t) (statuses statuses))))
      (trace-stage "LOGSEQ_REBASE_METRIC" started "projected")
      (refresh-search-after-rebase runtime before operations changed-uuids)
      (trace-stage "LOGSEQ_REBASE_METRIC" started "complete"))))

(defn create-base [path server-t conn options]
  (let [started (unix/gettimeofday)
        search-index (when-some [path (:search-index-path options)]
                       (try (Some (index/create path)) (catch error (search-error "open" error) nil)))
        runtime (record graph-runtime
                        (path path) (conn conn) (encrypt-title (:encrypt-title options)) (search-index search-index)
                        (state (atom (record runtime-state
                                             (server-t server-t)
                                             (snapshot (record projection/pending-projection-snapshot
                                                               (db (ds/conn-db conn)) (server-t server-t) (statuses [])))
                                             (sidebar-cache nil) (prepared {}) (journal-limit 1) (search-index-is-fresh false)))))]
    (trace-stage "LOGSEQ_RUNTIME_METRIC" started "search")
    (rebase runtime server-t [] [])
    runtime))

(defn fresh-uuid []
  (match (ds/squuid) (ds/Uuid uuid) uuid _ (throw (Failure "Datascript.squuid returned a non-UUID value"))))

(defn pending-operations [runtime]
  (let [projected-states (into {} (operation-statuses runtime))]
    (filterv (fn [operation]
               (and (match (:state operation) ops/Queued true ops/Retryable true ops/Submitted true _ false)
                    (match (get projected-states (:operation-id operation)) (Some (ops/Conflicted _)) false _ true)))
             (ops/list (:path runtime)))))

(defn db-before-operation [runtime operation-id]
  (let [authoritative (ds/conn-db (:conn runtime)) operations (ops/list (:path runtime))
        previous (vec (take-while #(not= (:operation-id %) operation-id) operations))]
    (if (= (count previous) (count operations)) authoritative
        (:db (projection/build (:server-t (state runtime)) authoritative previous)))))

(defn prepare-sync [runtime operation]
  (let [operation (or (first (filter #(= (:operation-id %) (:operation-id operation)) (ops/list (:path runtime)))) operation)]
    (if (not= (:base-t operation) (:server-t (state runtime)))
      (Error "operation was created against a stale server cursor")
      (let [before (db-before-operation runtime (:operation-id operation))]
        (let* [normalized (ops/normalize-operation before operation)
               tx (projection/compile before (:intent normalized))
               wire (sync-tx/encode (:encrypt-title runtime) before (apply list tx))]
          (swap! (:state runtime) update :prepared assoc (:operation-id operation) normalized)
          (Ok (tuple (ops/outliner-op (:intent normalized)) wire)))))))

(defn transport-state? [value]
  (match value ops/Submitted true (ops/Accepted _) true ops/Retryable true _ false))

(defn stage [runtime operation]
  (let [s (state runtime) snapshot (:snapshot s) operation-id (:operation-id operation)
        known? (some #(= (first %) operation-id) (:statuses snapshot))
        existing (if known? (ops/list (:path runtime)) [])
        replacing (first (filter #(= (:operation-id %) operation-id) existing))
        prepared (get (:prepared s) operation-id)
        operation (if-some [normalized prepared] (assoc normalized :state (:state operation)) operation)
        state-only (when-some [previous replacing]
                     (when (and (transport-state? (:state operation))
                                (match (:state previous) (ops/Conflicted _) false _ true))
                       (Some (assoc previous :state (:state operation)
                                    :intent (if-some [normalized prepared] (:intent normalized) (:intent previous))))))]
    (cond
      (some? state-only) (do (when-some [operation state-only] (ops/save (:path runtime) operation)) (Ok (stdlib/ignore 0)))
      (nil? replacing)
      (if (not= (:base-t operation) (:server-t s))
        (Error "operation was created against a stale server cursor")
        (let* [tx (projection/compile (:db snapshot) (:intent operation))]
          (ops/save (:path runtime) operation)
          (swap! (:state runtime) assoc :snapshot
                 (assoc snapshot :db (ds/db-with (apply list tx) (:db snapshot))
                        :statuses (conj (:statuses snapshot) (tuple operation-id ops/Applied))))
          (refresh-search-affected runtime (:db snapshot) (:intent operation))
          (Ok (stdlib/ignore 0))))
      :else
      (let [candidates (conj (filterv #(not= (:operation-id %) operation-id) existing) operation)
            candidate (projection/build (:server-t s) (ds/conn-db (:conn runtime)) candidates)]
        (match (get (into {} (:statuses candidate)) operation-id)
          (Some ops/Applied)
          (do (ops/save (:path runtime) operation)
              (swap! (:state runtime) assoc :snapshot candidate)
              (refresh-search-affected runtime (:db snapshot) (:intent operation))
              (Ok (stdlib/ignore 0)))
          (Some (ops/Conflicted message)) (Error message)
          _ (Error "operation could not be projected"))))))

(defn queued-operation [runtime operation-id intent]
  (record ops/pending-operation (operation-id operation-id) (base-t (:server-t (state runtime)))
          (state ops/Queued) (intent intent)))

(defn ensure-today-journal [runtime]
  (let [created-at (int (* (unix/gettimeofday) 1000.0)) day (model/journal-day-for-ms created-at)]
    (if (some? (read/journal-page-uuid (db runtime) day)) (Ok (stdlib/ignore 0))
        (stage runtime
               (queued-operation runtime (fresh-uuid)
                                 (ops/Create-journal
                                  (record ops/pending-journal
                                          (page-uuid (format "00000001-%04d-%04d-0000-000000000000" (quot day 10000) (mod day 10000)))
                                          (block-uuid (fresh-uuid)) (title (journal/day-title day))
                                          (journal-day day) (created-at created-at))))))))

(defn create [path server-t conn options]
  (let [started (unix/gettimeofday) runtime (create-base path server-t conn options)]
    (trace-stage "LOGSEQ_RUNTIME_METRIC" started "base")
    (when (:auto-create-today options)
      (match (ensure-today-journal runtime) (Ok _) (stdlib/ignore 0)
             (Error message) (throw (Failure (str "create today's journal: " message)))))
    runtime))

(defn blocks [runtime] (read/blocks #(Ok %) (:journal-limit (state runtime)) (db runtime)))

(defn due-flashcards [runtime now] (vec (cards/due-cards (db runtime) now)))

(defn semantic-option [value]
  (if-some [value value] (let* [value (ops/semantic-value-from-datascript value)] (Ok (Some value))) (Ok nil)))

(defn review-flashcard [runtime uuid rating now operation-id]
  (let [database (db runtime)]
    (if-some [card (cards/card-for-uuid database now uuid)]
      (let [repeated (cards/repeat now (:card card) rating)
            eid (ds/entid database "block/uuid" (ds/Uuid uuid))
            current (fn [attr] (when-some [eid eid] (read/value database eid attr)))]
        (let* [expected-state (semantic-option (current "logseq.property.fsrs/state"))
               expected-due (semantic-option (current "logseq.property.fsrs/due"))
               value (ops/semantic-value-from-datascript (cards/state-value repeated))]
          (stage runtime
                 (queued-operation runtime operation-id
                                   (ops/Set-properties
                                    (record ops/pending-properties (uuid uuid)
                                            (changes [(record ops/property-change (attr "logseq.property.fsrs/state")
                                                              (expected expected-state) (value (Some value)))
                                                      (record ops/property-change (attr "logseq.property.fsrs/due")
                                                              (expected expected-due) (value (Some (ops/Int-value (:due repeated)))))])))))))
      (Error "block is not a flashcard"))))

(defn has-older-journals [runtime]
  (< (:journal-limit (state runtime)) (read/journal-page-count (db runtime))))

(defn load-older-journals [runtime]
  (swap! (:state runtime) update :journal-limit + 2)
  (stdlib/ignore 0))

(defn blocks-for-page [runtime page-uuid] (read/blocks-for-page #(Ok %) (db runtime) page-uuid))

(defn sidebar-pages [runtime]
  (let [database (db runtime)]
    (match (:sidebar-cache (state runtime))
      (Some (tuple cached pages))
      (if (identical? cached database) pages
          (let [pages (read/sidebar-pages #(Ok %) database)]
            (swap! (:state runtime) assoc :sidebar-cache (Some (tuple database pages))) pages))
      None
      (let [pages (read/sidebar-pages #(Ok %) database)]
        (swap! (:state runtime) assoc :sidebar-cache (Some (tuple database pages))) pages))))

(defn set-page-favorite [runtime page-uuid favorite operation-id now]
  (let [database (db runtime)
        save (fn [favorite-uuid order]
               (stage runtime (queued-operation runtime operation-id
                                                (ops/Set-favorite
                                                 (record ops/pending-favorite (page-uuid page-uuid)
                                                         (favorite-uuid favorite-uuid) (favorite favorite)
                                                         (order order) (created-at now))))))]
    (cond
      (= (read/page-is-favorite? database page-uuid) favorite) (Ok (stdlib/ignore 0))
      favorite (let* [value (order/between (read/last-favorite-order database) nil)] (save (fresh-uuid) value))
      :else (if-some [uuid (read/favorite-block-uuid database page-uuid)] (save uuid "") (Ok (stdlib/ignore 0))))))

(defn delete-page [runtime page-uuid operation-id now]
  (let* [order (order/between (read/last-recycle-order (db runtime)) nil)]
    (stage runtime (queued-operation runtime operation-id
                                     (ops/Delete-page (record ops/pending-page-delete
                                                              (page-uuid page-uuid) (order order) (deleted-at now)))))))

(defn node-destination [runtime uuid] (read/node-destination #(Ok %) (db runtime) uuid))

(defn objects-for-tag [runtime uuid] (read/objects-for-tag #(Ok %) (db runtime) uuid))

(defn tag-pages [runtime] (read/tag-pages #(Ok %) (db runtime)))

(defn node-is-tag [runtime uuid] (read/node-is-tag? (db runtime) uuid))

(defn node-is-property [runtime uuid] (read/node-is-property? (db runtime) uuid))

(defn references-for-node [runtime uuid] (read/references-for-node #(Ok %) (db runtime) uuid))

(defn journal-page-uuid [runtime journal-day] (read/journal-page-uuid (db runtime) journal-day))

(defn normalize-titles [runtime uuid titles] (read/normalize-titles-creating-tags (db runtime) fresh-uuid uuid titles))

(defn search [runtime query]
  (if-some [search-index (:search-index runtime)]
    (do
      (when (not (:search-index-is-fresh (state runtime))) (refresh-search runtime))
      (try
        (let [hits (index/search-hits 100 search-index (db runtime) query)]
          (stdlib/prerr-endline (format "LOGSEQ_SEARCH_INDEX_QUERY query=%S fresh=%b hits=%d"
                                        query (:search-index-is-fresh (state runtime)) (count hits)))
          hits)
        (catch error
               (stdlib/prerr-endline (format "LOGSEQ_SEARCH_INDEX_ERROR stage=query query=%S error=%s"
                                             query (Printexc/to-string error)))
          [])))
    []))
