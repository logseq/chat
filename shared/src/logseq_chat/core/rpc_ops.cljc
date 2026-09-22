(ns logseq-chat.rpc-ops
  (:require [clojure.string :as string]
            [logseq-chat.rpc-wire :as wire]
            [logseq-chat.api :as api]
            [logseq-chat.graph-bootstrap :as bootstrap]
            [logseq-chat.outliner-effects :as effects]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.fractional-order :as order]
            [logseq-chat.outliner-state :as outliner]
            [ocaml.Stdlib :as stdlib]))

(defn same-status? [left right]
  (= (when-some [status left] (:uuid status))
     (when-some [status right] (:uuid status))))

(defn same-pending-version? [left right]
  (and (= (:uuid left) (:uuid right))
       (= (:title left) (:title right))
       (= (:updated-at left) (:updated-at right))
       (same-status? (:status left) (:status right))
       (= (:asset-size left) (:asset-size right))
       (= (:asset-checksum left) (:asset-checksum right))
       (= (:local-path left) (:local-path right))))

(defn reconcile-authoritative-blocks [cache blocks]
  (let [by-uuid (into {} (map (fn [block] (tuple (:uuid block) block)) blocks))]
    (run! (fn [block]
            (when-some [authoritative (get by-uuid (:uuid block))]
              (when (or (= "submitted" (:sync-status block))
                        (and (= (:title block) (:title authoritative))
                             (same-status? (:status block) (:status authoritative))))
                (model/mark-block-synced cache (:uuid block)))))
          (model/unsynced-blocks cache))))

(defn normalize-title-intent [normalize intent]
  (match intent
    (ops/Save-title value)
    (let [[titles tags] (normalize (:uuid value) [(:title value)])]
      (tuple (if (= 1 (count titles)) (ops/Save-title (assoc value :title (nth titles 0))) intent) tags))
    (ops/Insert-block value)
    (let [[titles tags] (normalize (:uuid value) [(:title value)])]
      (tuple (if (= 1 (count titles)) (ops/Insert-block (assoc value :title (nth titles 0))) intent) tags))
    (ops/Split-block value)
    (let [[titles tags] (normalize (:uuid value) [(:before value) (:after value)])]
      (tuple (if (= 2 (count titles))
               (ops/Split-block (assoc value :before (nth titles 0) :after (nth titles 1))) intent) tags))
    (ops/Merge-backward value)
    (let [[titles tags] (normalize (:uuid value) [(:title value)])]
      (tuple (if (= 1 (count titles)) (ops/Merge-backward (assoc value :title (nth titles 0))) intent) tags))
    _ (tuple intent [])))

(defn normalize-operation-titles [normalizer fresh-id clock operation]
  (if-some [normalize normalizer]
    (let [[intent tags] (normalize-title-intent normalize (:intent operation))
          created (mapv (fn [[uuid title]]
                          (record ops/pending-operation
                                  (operation-id (fresh-id)) (base-t (:base-t operation)) (state ops/Queued)
                                  (intent (ops/Create-tag
                                            (record ops/pending-create
                                                    (uuid uuid) (title title) (created-at (clock)))))))
                        tags)]
      (conj created (assoc operation :intent intent)))
    [operation]))

(defn capture-operation [base-t uuid title now load-context journal-page-id fresh-id]
  (let [journal-day (model/journal-day-for-ms now)
        page (when-some [find-page journal-page-id] (find-page journal-day))]
    (if-some [page-uuid page]
      (let [last-order (->> (effects/sorted-siblings (load-context) (Some page-uuid))
                            (filter #(= (:page-id %) page-uuid))
                            (keep :order)
                            last)]
        (let* [position (order/between last-order nil)]
          (Ok (effects/operation base-t fresh-id
                (ops/Insert-block (record ops/pending-insert
                                         (uuid uuid) (title title) (page-uuid page-uuid)
                                         (parent-uuid page-uuid) (order position) (created-at now)))))))
      (Ok (effects/operation base-t fresh-id
            (ops/Create-journal (record ops/pending-journal
                                       (page-uuid (wire/journal-page-uuid journal-day)) (block-uuid uuid)
                                       (title title) (journal-day journal-day) (created-at now))))))))

(defn capture-operations [cursor uuid title now status load-context journal-page-id fresh-id normalize]
  (if-some [base-t cursor]
    (let* [operation (capture-operation base-t uuid title now load-context journal-page-id fresh-id)]
      (let [status-operations
            (if-some [value status]
              [(effects/operation base-t fresh-id
                 (ops/Set-property (record ops/pending-property
                                           (uuid uuid) (attr "logseq.property/status") (expected nil)
                                           (value (Some (if-some [ident (:ident value)]
                                                          (ops/Ref-ident ident)
                                                          (ops/Ref-uuid (:uuid value))))))))]
              [])]
        (Ok (into (vec (normalize operation)) status-operations))))
    (Error "A current server cursor is required")))

(defn asset-destination [context block journal-page-id]
  (if-some [parent-uuid (:parent-id block)]
    (when-some [parent (outliner/find-block context parent-uuid)]
      (tuple (:page-id parent) parent-uuid))
    (when-some [find-page journal-page-id]
      (when-some [page-uuid (find-page (model/journal-day-for-ms (:created-at block)))]
        (tuple page-uuid page-uuid)))))

(defn asset-datoms-operation [cursor state block load-context journal-page-id]
  (if-some [base-t cursor]
    (match (tuple (:asset-type block) (:asset-size block) (:asset-checksum block))
      (tuple (Some asset-type) (Some asset-size) (Some asset-checksum))
      (let [context (load-context)]
        (if-some [[page-uuid parent-uuid] (asset-destination context block journal-page-id)]
          (let [last-order (->> (:blocks context)
                                (filter (fn [candidate]
                                          (and (= (:page-id candidate) page-uuid)
                                               (= (:parent-id candidate) (Some parent-uuid))
                                               (not= (:uuid candidate) (:uuid block)))))
                                (keep :order)
                                sort
                                last)]
            (let* [position (order/between last-order nil)]
              (Ok (record ops/pending-operation
                          (operation-id (str "asset:" (:uuid block)))
                          (base-t base-t) (state state)
                          (intent (ops/Create-asset
                                    (record ops/pending-asset
                                            (uuid (:uuid block)) (title (:title block))
                                            (page-uuid page-uuid) (parent-uuid parent-uuid)
                                            (order position) (created-at (:created-at block))
                                            (asset-type asset-type) (asset-size asset-size)
                                            (asset-checksum asset-checksum))))))))
          (Error "asset destination is not available")))
      _ (Error "asset metadata is incomplete"))
    (Error "A current server cursor is required")))

(defn projected-status [value]
  (match value
    (Some (ops/Ref-ident ident))
    (let [[uuid title] (case ident
                         "logseq.property/status.backlog" (tuple "backlog" "Backlog")
                         "logseq.property/status.todo" (tuple "todo" "Todo")
                         "logseq.property/status.doing" (tuple "doing" "Doing")
                         "logseq.property/status.in-review" (tuple "in-review" "In Review")
                         "logseq.property/status.done" (tuple "done" "Done")
                         "logseq.property/status.canceled" (tuple "canceled" "Canceled")
                         (tuple ident ident))]
      (Some (record model/status (uuid uuid) (title title) (ident (Some ident))
              (icon-type nil) (icon-id nil) (icon-color nil))))
    (Some (ops/Ref-uuid uuid))
    (Some (record model/status (uuid uuid) (title uuid) (ident nil)
            (icon-type nil) (icon-id nil) (icon-color nil)))
    _ nil))

(defn project-outliner-intent [blocks intent]
  (match intent
    (ops/Save-title value)
    (mapv #(if (= (:uuid %) (:uuid value)) (assoc % :title (:title value)) %) blocks)

    (ops/Insert-block value)
    (conj (vec blocks)
          (assoc (model/local-block (:uuid value) (:title value) (:page-uuid value)
                                    (Some (:parent-uuid value)) (:created-at value))
                 :order (Some (:order value))))

    (ops/Create-asset value)
    (let [asset (assoc (model/local-block (:uuid value) (:title value) (:page-uuid value)
                                          (Some (:parent-uuid value)) (:created-at value))
                       :order (Some (:order value)) :is-asset true
                       :asset-type (Some (:asset-type value)) :asset-size (Some (:asset-size value))
                       :asset-checksum (Some (:asset-checksum value)))]
      (if (some #(= (:uuid %) (:uuid value)) blocks)
        (mapv #(if (= (:uuid %) (:uuid value)) (assoc asset :local-path (:local-path %)) %) blocks)
        (conj (vec blocks) asset)))

    (ops/Split-block value)
    (if-some [source (first (filter #(= (:uuid %) (:uuid value)) blocks))]
      (conj (mapv #(if (= (:uuid %) (:uuid value)) (assoc % :title (:before value)) %) blocks)
            (assoc (model/local-block (:new-uuid value) (:after value) (:page-id source)
                                      (:parent-id source) (:created-at value))
                   :order (Some (:new-order value)) :journal (:journal source)))
      (vec blocks))

    (ops/Merge-backward value)
    (let [previous-title (if-some [previous (first (filter #(= (:uuid %) (:previous-uuid value)) blocks))]
                           (:title previous) "")
          title (if-some [merged (:merged-title value)] merged (str previous-title (:title value)))]
      (mapv #(if (= (:uuid %) (:previous-uuid value))
               (assoc % :title title :sync-status "pending") %)
            (remove #(= (:uuid %) (:uuid value)) blocks)))

    (ops/Move-block value)
    (mapv #(if (= (:uuid %) (:uuid value))
             (assoc % :page-id (:page-uuid value) :parent-id (Some (:parent-uuid value))
                      :order (Some (:order value)) :sync-status "pending") %)
          blocks)

    (ops/Move-blocks value)
    (reduce (fn [result move] (project-outliner-intent result (ops/Move-block move)))
            (vec blocks) (:moves value))

    (ops/Delete-blocks value)
    (let [deleted (set (:uuids value))]
      (filterv #(not (contains? deleted (:uuid %))) blocks))

    (ops/Set-property value)
    (if (= (:attr value) "logseq.property/status")
      (let [status (projected-status (:value value))]
        (mapv #(if (= (:uuid %) (:uuid value)) (assoc % :status status :sync-status "pending") %) blocks))
      (vec blocks))

    _ (vec blocks)))

(defn merge-live-block-metadata [optimistic live]
  (assoc optimistic
    :updated-at (:updated-at live) :sync-status (:sync-status live)
    :tags (:tags live) :references (:references live) :breadcrumbs (:breadcrumbs live)
    :status (:status live) :is-asset (:is-asset live) :asset-type (:asset-type live)
    :asset-size (:asset-size live) :asset-checksum (:asset-checksum live)
    :local-path (:local-path live) :journal (:journal live)))

(defn page-blocks-with-optimistic-overlay [cached editing? page-uuid live-blocks]
  (if editing?
    (if-some [blocks cached]
      (let [live-by-uuid (into {} (map (fn [block] (tuple (:uuid block) block)) live-blocks))]
        (mapv (fn [block]
                (if-some [live (get live-by-uuid (:uuid block))]
                  (merge-live-block-metadata block live)
                  block))
              (filter #(= (:page-id %) page-uuid) blocks)))
      (vec live-blocks))
    (vec live-blocks)))

(defn upload-initial-graph-snapshot [config e2ee encrypt-title upload-file cleanup-file]
  (let* [encrypt-text (if e2ee
                       (if-some [encrypt encrypt-title]
                         (Ok (fn [value] (encrypt (:graph-id config) value)))
                         (Error "E2EE title encryption is unavailable"))
                       (Ok (fn [value] (Ok value))))
         prepared (bootstrap/prepare (:graph-id config) e2ee encrypt-text)]
    (try
      (let* [response (upload-file
                       (api/initial-snapshot-upload-request config (:file-path prepared) (:checksum prepared)))]
        (if (<= 200 (:status response) 299)
          (do (stdlib/prerr-endline
                (format "LogseqChat core initial graph snapshot uploaded graph=%s rows=%d"
                        (:graph-id config) (:row-count prepared)))
              (Ok (stdlib/ignore 0)))
          (Error (if (= "" (:body response))
                   (format "Initial snapshot upload failed with HTTP %d" (:status response))
                   (:body response)))))
      (finally (cleanup-file (:file-path prepared))))))

(defn import-snapshot [payload importer project completed]
  (match (tuple importer payload)
    (tuple None _) (wire/failure "snapshot_import_unavailable" "Snapshot import is unavailable")
    (tuple _ None) (wire/failure "invalid_params" "importSnapshot requires a JSON payload")
    (tuple (Some importer) (Some payload))
    (wire/action-response
      (let* [_ (wire/graph-workflow-result "snapshot_import_failed" (importer payload))
             _ (wire/graph-workflow-result "graph_projection_failed" (project payload))]
        (Ok (completed))))))

(defn open-graph [payload open-storage project completed]
  (match (tuple open-storage payload)
    (tuple None _) (wire/failure "graph_open_unavailable" "Graph storage is unavailable")
    (tuple _ None) (wire/failure "invalid_params" "openGraph requires a JSON payload")
    (tuple (Some open-storage) (Some payload))
    (wire/action-response
      (let* [_ (wire/graph-workflow-result "graph_open_failed" (open-storage payload))
             _ (wire/graph-workflow-result "graph_projection_failed" (project payload))]
        (Ok (completed))))))

(defn apply-sync-event [payload apply-event completed]
  (match (tuple apply-event payload)
    (tuple None _) (wire/failure "websocket_unavailable" "WebSocket sync is unavailable")
    (tuple _ None) (wire/failure "invalid_params" "applySyncEvent requires a payload")
    (tuple (Some apply-event) (Some event))
    (match (apply-event event)
      (Ok _) (completed)
      (Error message)
      (wire/failure (if (or (string/starts-with? message "snapshot required:")
                       (= message "sync schema mismatch"))
                 "snapshot_required"
                 "websocket_apply_failed")
               message))))

(defn asset-metadata [fields]
  (match (tuple (wire/required-string fields "uuid") (wire/required-string fields "title")
                (wire/optional-int fields "now") (wire/required-string fields "assetType")
                (wire/optional-int fields "assetSize") (wire/required-string fields "assetChecksum")
                (wire/required-string fields "localPath") (wire/optional-string fields "targetBlockId"))
    (tuple (Ok uuid) (Ok title) (Ok now) (Ok asset-type) (Ok (Some asset-size))
           (Ok checksum) (Ok local-path) (Ok target))
    (Ok (tuple uuid title now asset-type asset-size checksum local-path target))
    _ (Error (tuple "invalid_params" "addAsset requires complete file metadata"))))

(defn add-asset [payload cache clock load-target prepare-view prepare-operation load-stage]
  (if-some [payload payload]
    (wire/action-response
      (let* [fields (wire/action-fields "addAsset" payload)
             metadata (asset-metadata fields)]
        (let [[uuid title requested-now asset-type asset-size checksum local-path target] metadata
              now (if-some [now requested-now] now (clock))
              asset-type (api/normalize-asset-type asset-type)
              completed (prepare-view)]
          (when-some [uuid target]
            (when (nil? (model/read-block cache uuid))
              (when-some [block (load-target uuid)]
                (model/upsert-blocks cache [block] now))))
          (model/cache-local-asset cache uuid title asset-type asset-size checksum local-path now target)
          (match (tuple (load-stage) (model/read-block cache uuid))
            (tuple (Some stage) (Some block))
            (let* [operation (wire/graph-workflow-result "asset_projection_failed" (prepare-operation block))
                   _ (wire/graph-workflow-result "stage_operation_failed" (stage operation))]
              (Ok (completed)))
            _ (Ok (completed))))))
    (wire/failure "invalid_params" "addAsset requires a JSON payload")))

(defn child-operation [base-t context uuid title parent-id now fresh-id]
  (if-some [parent (outliner/find-block context parent-id)]
    (let [last-order (->> (:blocks context)
                          (filter (fn [block]
                                    (and (= (:page-id block) (:page-id parent))
                                         (= (:parent-id block) (Some (:uuid parent))))))
                          (keep :order)
                          sort
                          last)]
      (let* [position (order/between last-order nil)]
        (Ok (effects/operation base-t fresh-id
              (ops/Insert-block (record ops/pending-insert
                                        (uuid uuid) (title title) (page-uuid (:page-id parent))
                                        (parent-uuid (:uuid parent)) (order position) (created-at now)))))))
    (Error "parent block is unavailable")))

(defn add-child-block [payload cache clock load-sync-state load-context enqueue fresh-id completed]
  (if-some [payload payload]
    (wire/action-response
      (let* [fields (wire/action-fields "addChildBlock" payload)
             uuid (wire/graph-workflow-result "invalid_params" (wire/required-string fields "uuid"))
             title (wire/graph-workflow-result "invalid_params" (wire/required-string fields "title"))
             parent-id (wire/graph-workflow-result "invalid_params" (wire/required-string fields "parentId"))
             requested-now (wire/graph-workflow-result "invalid_params" (wire/optional-int fields "now"))]
        (let [now (if-some [now requested-now] now (clock))]
          (match (load-sync-state)
            (tuple (Some config) (Some base-t))
            (let* [operation (wire/graph-workflow-result "invalid_params"
                              (child-operation base-t (load-context) uuid title parent-id now fresh-id))
                   _ (wire/graph-workflow-result "stage_operation_failed" (enqueue config operation))]
              (Ok (completed)))
            (tuple (Some _) None) (Error (tuple "invalid_params" "A current server cursor is required"))
            (tuple None _)
            (let* [_ (wire/graph-workflow-result "invalid_params" (model/cache-local-child cache uuid title parent-id now))]
              (Ok (completed)))))))
    (wire/failure "invalid_params" "addChildBlock requires a JSON payload")))

(defn review-flashcard [payload review clock completed]
  (match (tuple payload review)
    (tuple None _) (wire/failure "invalid_params" "reviewFlashcard requires a payload")
    (tuple _ None) (wire/failure "flashcards_unavailable" "No graph is open")
    (tuple (Some payload) (Some review))
    (wire/action-response
      (let* [fields (wire/action-fields "reviewFlashcard" payload)
             uuid (wire/graph-workflow-result "invalid_params" (wire/required-string fields "uuid"))
             rating (wire/graph-workflow-result "invalid_params" (wire/required-string fields "rating"))
             requested-now (wire/graph-workflow-result "invalid_params" (wire/optional-int fields "now"))
             operation-id (wire/graph-workflow-result "invalid_params" (wire/required-string fields "operationId"))
             rating (wire/graph-workflow-result "invalid_params" (wire/flashcard-rating rating))]
        (let [now (match requested-now (Some now) now None (clock))]
          (let* [_ (wire/graph-workflow-result "flashcard_review_failed" (review uuid rating now operation-id))]
            (Ok (completed now))))))))

(defn set-page-favorite [payload set-favorite configured? clock completed]
  (match (tuple payload set-favorite configured?)
    (tuple None _ _) (wire/failure "invalid_params" "setPageFavorite requires a payload")
    (tuple _ None _) (wire/failure "set_page_favorite_unavailable" "No graph is open")
    (tuple _ _ false) (wire/failure "graph_not_configured" "Select a graph first")
    (tuple (Some payload) (Some set-favorite) true)
    (wire/action-response
      (let* [fields (wire/action-fields "setPageFavorite" payload)
             page-uuid (wire/graph-workflow-result "invalid_params" (wire/required-string fields "pageUuid"))
             favorite (wire/graph-workflow-result "invalid_params" (wire/required-bool fields "favorite"))
             operation-id (wire/graph-workflow-result "invalid_params" (wire/required-string fields "operationId"))
             requested-now (wire/graph-workflow-result "invalid_params" (wire/optional-int fields "now"))]
        (let [now (match requested-now (Some now) now None (clock))]
          (let* [_ (wire/graph-workflow-result "set_page_favorite_failed" (set-favorite page-uuid favorite operation-id now))]
            (Ok (completed))))))))

(defn delete-page [payload delete configured? clock completed]
  (match (tuple payload delete configured?)
    (tuple None _ _) (wire/failure "invalid_params" "deletePage requires a payload")
    (tuple _ None _) (wire/failure "delete_page_unavailable" "No graph is open")
    (tuple _ _ false) (wire/failure "graph_not_configured" "Select a graph first")
    (tuple (Some payload) (Some delete) true)
    (wire/action-response
      (let* [fields (wire/action-fields "deletePage" payload)
             page-uuid (wire/graph-workflow-result "invalid_params" (wire/required-string fields "pageUuid"))
             operation-id (wire/graph-workflow-result "invalid_params" (wire/required-string fields "operationId"))
             requested-now (wire/graph-workflow-result "invalid_params" (wire/optional-int fields "now"))]
        (let [now (match requested-now (Some now) now None (clock))]
          (let* [_ (wire/graph-workflow-result "delete_page_failed" (delete page-uuid operation-id now))]
            (Ok (completed))))))))

(defn cache-remote-blocks [cache response now]
  (if (<= 200 (:status response) 299)
    (let [[blocks journals]
          (try (api/feed-from-body (:body response))
               (catch error
                 (let [message (Printexc/to-string error)]
                   (wire/debug (str "remote refresh parse failed: " message))
                   (throw (Failure (str "Could not parse Logseq search response: " message))))))]
      (run! (fn [journal]
              (model/upsert-journal-page cache (:uuid journal) (:journal-day journal) (:title journal)))
            journals)
      (wire/debug (format "remote refresh parsed blocks=%d" (count blocks)))
      (model/upsert-blocks cache blocks now)
      (Ok (stdlib/ignore 0)))
    (do (wire/debug (format "remote refresh HTTP failed status=%d" (:status response)))
        (Error (format "Logseq API returned HTTP %d" (:status response))))))

(defn cache-task-statuses [cache response]
  (if (<= 200 (:status response) 299)
    (let [statuses (api/statuses-from-property-body (:body response))]
      (wire/debug (format "remote task statuses parsed count=%d" (count statuses)))
      (model/upsert-statuses cache statuses)
      (Ok (stdlib/ignore 0)))
    (Error (format "Logseq status property returned HTTP %d" (:status response)))))

(defn refresh-from-remote [cache config send now snapshot]
  (wire/debug (str "remote refresh started graph=" (:graph-id config)))
  (let [result
        (let* [response (wire/graph-workflow-result "remote_refresh_failed"
                          (match (send (api/recent-blocks-request config (model/journal-day-for-ms now)))
                            (Error message)
                            (do (wire/debug (str "remote refresh request failed: " message)) (Error message))
                            (Ok response) (Ok response)))
               _ (wire/graph-workflow-result "remote_refresh_failed" (cache-remote-blocks cache response now))
               statuses (wire/graph-workflow-result "remote_statuses_failed" (send (api/task-statuses-request config)))
               _ (wire/graph-workflow-result "remote_statuses_failed" (cache-task-statuses cache statuses))]
          (Ok (snapshot)))]
    (match result
      (Ok response) response
      (Error (tuple code message)) (wire/failure code message))))

(defn create-sync-graph [config payload send provision initialize discover created]
  (match (tuple config payload)
    (tuple None _) (wire/failure "graph_not_configured" "Configure Logseq before creating a graph")
    (tuple _ None) (wire/failure "invalid_params" "createSyncGraph requires a payload")
    (tuple (Some config) (Some payload))
    (try
      (let [result
            (let* [[name encrypted] (wire/graph-creation-payload payload)
                   response (wire/graph-workflow-result "graph_create_failed"
                              (send (api/create-graph-request config name "65.33" encrypted)))
                   graph-id (wire/graph-workflow-result "graph_create_failed" (wire/graph-creation-response response))]
              (let [selected (assoc config :graph-id graph-id :graph-name (Some name))]
                (let* [_ (wire/graph-workflow-result "graph_key_provision_failed"
                           (if encrypted
                             (if-some [provision provision]
                               (provision selected)
                               (Error "E2EE key provisioning is unavailable"))
                             (Ok (stdlib/ignore 0))))
                       _ (wire/graph-workflow-result "graph_initial_upload_failed"
                           (initialize (assoc config :graph-id graph-id) encrypted))
                       _ (wire/graph-workflow-result "graph_discovery_failed" (discover config))]
                  (Ok (created selected)))))]
        (match result
          (Ok response) response
          (Error (tuple code message)) (wire/failure code message)))
      (catch error (wire/failure "invalid_json" (Printexc/to-string error))))))
