(ns logseq-chat.rpc-session
  (:require [clojure.string :as string]
            [logseq-chat.session-types :as types]
            [logseq-chat.session-outliner :as so]
            [logseq-chat.pending-pump :as pump]
            [logseq-chat.rpc :as rpc]
            [logseq-chat.cache-model :as model]
            [logseq-chat.api :as api]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.outliner-state :as outliner]
            [logseq-chat.outliner-effects :as effects]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Unix :as unix]
            [ocaml.Sys :as sys]
            [ocaml.Printexc :as exceptions]
            [ocaml.Stdlib :as stdlib]))

(def default-options types/default-options)
(def create-session types/create-session)
(def state types/state)
(def host types/host)
(def now-ms types/now-ms)
(def debug types/debug)
(def fresh-squuid types/fresh-squuid)
(def projection-server-t types/projection-server-t)
(def submission-server-t types/submission-server-t)
(def record-accepted-server-t! types/record-accepted-server-t!)
(def transport-operation-block types/transport-operation-block)
(def empty-sidebar types/empty-sidebar)
(def sidebar-pages so/sidebar-pages)
(def outliner-context-with-blocks so/outliner-context-with-blocks)
(def base-outliner-context-live so/base-outliner-context-live)
(def page-overlay so/page-overlay)
(def scope-selected-page so/scope-selected-page)
(def base-outliner-context-with-blocks so/base-outliner-context-with-blocks)
(def base-outliner-context so/base-outliner-context)
(def page-outliner-context so/page-outliner-context)
(def node-route-context so/node-route-context)
(def active-node-route so/active-node-route)
(def node-route-related-blocks so/node-route-related-blocks)
(def node-route-linked-reference-blocks so/node-route-linked-reference-blocks)
(def page-for-visible-block so/page-for-visible-block)
(def projected-node-destination so/projected-node-destination)
(def with-extra-blocks so/with-extra-blocks)
(def outliner-context so/outliner-context)
(def project-outliner-operations so/project-outliner-operations)
(def selected-graph so/selected-graph)
(def selected-graph-is-encrypted so/selected-graph-is-encrypted)
(def selected-graph-is-unlocked so/selected-graph-is-unlocked)
(def selected-page-is-tag so/selected-page-is-tag)
(def selected-page-is-property so/selected-page-is-property)
(def snapshot-related-blocks so/snapshot-related-blocks)
(def snapshot-linked-reference-blocks so/snapshot-linked-reference-blocks)
(def has-pending-operations so/has-pending-operations)
(def reset-outliner! so/reset-outliner!)
(def clear-node-navigation! so/clear-node-navigation!)
(def persist-active-node-state! so/persist-active-node-state!)
(def initial-node-state so/initial-node-state)
(def push-node-route! so/push-node-route!)
(def pop-node-route! so/pop-node-route!)
(def aggregate-return-context so/aggregate-return-context)
(def refresh-reference-metadata so/refresh-reference-metadata)
(def event-patch-plan so/event-patch-plan)
(def pending-request-json pump/pending-request-json)
(def pending-block-unchanged pump/pending-block-unchanged)
(def mark-pending-failed! pump/mark-pending-failed!)
(def set-pending-active! pump/set-pending-active!)
(def encrypted-title pump/encrypted-title)
(def prepare-pending-create-request pump/prepare-pending-create-request)
(def prepare-pending-creation pump/prepare-pending-creation)
(def prepare-pending-block pump/prepare-pending-block)
(def prepare-pending-next! pump/prepare-pending-next!)
(def activate-semantic-request pump/activate-semantic-request)
(def enqueue-semantic pump/enqueue-semantic)
(def normalize-operation-titles pump/normalize-operation-titles)
(def capture-operations pump/capture-operations)
(def enqueue-capture pump/enqueue-capture)
(def restore-semantic-queue! pump/restore-semantic-queue!)
(def begin-pending-sync! pump/begin-pending-sync!)
(def finish-semantic-active! pump/finish-semantic-active!)
(def cleanup-pending-active! pump/cleanup-pending-active!)
(def finish-pending-block! pump/finish-pending-block!)
(def asset-datoms-operation pump/asset-datoms-operation)
(def reconcile-created-block! pump/reconcile-created-block!)
(def complete-pending-active! pump/complete-pending-active!)
(def accepted-transaction pump/accepted-transaction)
(def completion-error pump/completion-error)
(def parse-semantic-completion pump/parse-semantic-completion)
(def parse-transport-completion pump/parse-transport-completion)
(def complete-pending-sync pump/complete-pending-sync)
(def cancel-pending-sync! pump/cancel-pending-sync!)

(defn node-routes-json [session ^:fn<model/block;Yojson.Basic.t> serialize ^:fn<model/block;Yojson.Basic.t> serialize-plain]
  (let [active (active-node-route session)]
    (rpc/json-list
     (map (fn [route]
            (let [current (if (match active (Some active) (= (:uuid active) (:uuid route)) None false)
                            (:outliner-state (state session)) (:state route))
                  context (node-route-context session route)]
              (rpc/json-object
               [(tuple "uuid" (tag String (:uuid route))) (tuple "isTag" (tag Bool (:is-tag route)))
                (tuple "isProperty" (tag Bool (:is-property route))) (tuple "page" (rpc/summary-json (:page route)))
                (tuple "blocks" (rpc/json-list (map serialize (:blocks context))))
                (tuple "relatedBlocks" (rpc/json-list (map serialize-plain (node-route-related-blocks session route))))
                (tuple "linkedReferenceBlocks" (rpc/json-list (map serialize-plain (node-route-linked-reference-blocks session route))))
                (tuple "outlinerState" (rpc/outliner-state-json current))
                (tuple "outlinerRows" (rpc/outliner-rows-json serialize context current))
                (tuple "outlinerAutocompleteCandidates" (rpc/outliner-candidates-json context current))])))
          (:node-routes (state session))))))

(defn trace-snapshot [started stage]
  (when (= (sys/getenv-opt "LOGSEQ_CHAT_TRACE_STARTUP") (Some "1"))
    (stdlib/prerr-endline
     (str "LOGSEQ_SNAPSHOT_METRIC stage=" stage
          " elapsed_ms=" (format "%.3f" (* (- (unix/gettimeofday) started) 1000.0))))))

(defn snapshot [session context-blocks blocks]
  (let [started (unix/gettimeofday) s (state session) h (host session)
        sidebar (sidebar-pages session)
        _ (trace-snapshot started "sidebar")
        current (or (:node-base-state s) (:outliner-state s))
        context (base-outliner-context-with-blocks session (Some sidebar) context-blocks)
        _ (trace-snapshot started "context")
        serialized (atom {})
        serialize (fn [block]
                    (if-some [value (get @serialized (:uuid block))] value
                             (let [value (rpc/visible-block-json block)]
                               (swap! serialized assoc (:uuid block) value) value)))
        serialized-plain (atom {})
        serialize-plain (fn [block]
                          (if-some [value (get @serialized-plain (:uuid block))] value
                                   (let [value (rpc/block-json block)]
                                     (swap! serialized-plain assoc (:uuid block) value) value)))
        config (:config s)
        response
        (rpc/success
         (rpc/json-object
          [(tuple "revision" (tag Int (.-revision (:model s))))
           (tuple "blocks" (rpc/json-list (map serialize blocks)))
           (tuple "selectedBlock" (if-some [block (model/selected-block (:model s))] (rpc/block-json block) (tag Null)))
           (tuple "relatedBlocks" (rpc/json-list (map rpc/block-json (snapshot-related-blocks session))))
           (tuple "linkedReferenceBlocks" (rpc/json-list (map rpc/block-json (snapshot-linked-reference-blocks session))))
           (tuple "selectedPageIsTag" (tag Bool (selected-page-is-tag session)))
           (tuple "selectedPageIsProperty" (tag Bool (selected-page-is-property session)))
           (tuple "searchQuery" (tag String (:search-query s)))
           (tuple "searchResults" (rpc/json-list (map rpc/search-hit-json (:search-results s))))
           (tuple "flashcards" (rpc/json-list (map rpc/flashcard-json (:flashcards s))))
           (tuple "nodeRoutes" (node-routes-json session serialize serialize-plain))
           (tuple "lastRefreshAt" (if-some [value (.-last-refresh-at (:model s))] (tag Int value) (tag Null)))
           (tuple "graphName" (if-some [name (when-some [config config] (:graph-name config))] (tag String name) (tag Null)))
           (tuple "selectedGraphId" (match config (Some config) (if (= (:graph-id config) "") (tag Null) (tag String (:graph-id config))) None (tag Null)))
           (tuple "graphs" (rpc/json-list (map rpc/graph-json (:available-graphs s))))
           (tuple "favorites" (rpc/json-list (map rpc/summary-json (:favorites sidebar))))
           (tuple "recentPages" (rpc/json-list (map rpc/summary-json (:recent-pages sidebar))))
           (tuple "selectedPage" (if-some [page (:selected-sidebar-page s)] (rpc/summary-json page) (tag Null)))
           (tuple "isGraphEncrypted" (tag Bool (selected-graph-is-encrypted session)))
           (tuple "isGraphUnlocked" (tag Bool (selected-graph-is-unlocked session)))
           (tuple "appliedServerT" (if-some [value (projection-server-t session)] (tag Int value) (tag Null)))
           (tuple "syncConnected" (tag Bool (:sync-connected s)))
           (tuple "taskStatuses" (rpc/json-list (map rpc/status-response-json (model/all-statuses (:model s)))))
           (tuple "pendingSyncRequest" (pending-request-json session))
           (tuple "outlinerState" (rpc/outliner-state-json current))
           (tuple "outlinerAutocompleteCandidates" (rpc/outliner-candidates-json context current))
           (tuple "outlinerRows" (rpc/outliner-rows-json serialize context current))
           (tuple "outlinerCommandRevision" (tag Int (:outliner-revision s)))
           (tuple "outlinerCommands" (rpc/json-list (map rpc/outliner-command-json (:outliner-commands s))))
           (tuple "hasPendingSemanticOperations" (tag Bool (has-pending-operations session)))
           (tuple "hasOlderJournals" (tag Bool (if-some [read (:has-older-journals h)] (read) false)))
           (tuple "isOutlinerPatch" (tag Bool false))]))]
    (when (not (empty? (:flashcards s))) (debug (str "flashcards snapshot encoded bytes=" (count response))))
    response))

(defn outliner-patch-result [session context blocks deleted splices]
  (let [s (state session)]
    (rpc/outliner-patch-result (.-revision (:model s)) context (:outliner-state s) (:outliner-revision s)
                               (:outliner-commands s) (has-pending-operations session) blocks deleted splices)))

(defn outliner-patch [session context changed-ids]
  (let [changed (set changed-ids)]
    (outliner-patch-result session context (filter #(contains? changed (:uuid %)) (:blocks context)) [] [])))

(defn structural-outliner-patch [anchored session before-context before-state after-context]
  (let [[blocks deleted splices] (rpc/structural-outliner-delta anchored before-context before-state after-context
                                                                (:outliner-state (state session)))]
    (outliner-patch-result session after-context blocks deleted splices)))

(defn snapshot-visible [session]
  (let [started (unix/gettimeofday) s (state session) h (host session)
        context-blocks
        (match (tuple (:selected-sidebar-page s) (:graph-page-blocks h))
          (tuple (Some page) (Some load)) (vec (or (load (:uuid page)) (list)))
          _ (if-some [load (:graph-blocks h)]
              (let [blocks (vec (or (load) (list)))
                    local (model/all-blocks (:model s))
                    by-id (zipmap (map :uuid local) local)]
                (mapv (fn [block]
                        (if-some [local (get by-id (:uuid block))]
                          (if (some? (:local-path local)) (assoc block :local-path (:local-path local)) block) block)) blocks))
              (model/visible-blocks (:model s))))
        _ (when (not (empty? (:flashcards s))) (debug (str "flashcards visible blocks loaded count=" (count context-blocks))))
        blocks (if (or (some? (:graph-blocks h)) (some? (:selected-sidebar-page s))) context-blocks
                   (model/visible-from (:model s) context-blocks))
        _ (trace-snapshot started "blocks")
        result (snapshot session context-blocks blocks)]
    (trace-snapshot started "complete") result))

(defn graph-catalog-snapshot [session]
  (let [s (state session)]
    (rpc/success
     (rpc/json-object
      [(tuple "graphName" (if-some [name (when-some [config (:config s)] (:graph-name config))] (tag String name) (tag Null)))
       (tuple "selectedGraphId" (match (:config s) (Some config) (if (= (:graph-id config) "") (tag Null) (tag String (:graph-id config))) None (tag Null)))
       (tuple "graphs" (rpc/json-list (map rpc/graph-json (:available-graphs s))))
       (tuple "isGraphEncrypted" (tag Bool (selected-graph-is-encrypted session)))
       (tuple "isGraphUnlocked" (tag Bool (selected-graph-is-unlocked session)))
       (tuple "isGraphCatalogPatch" (tag Bool true))]))))

(defn pending-sync-patch [session]
  (rpc/success
   (rpc/json-object
    [(tuple "revision" (tag Int (.-revision (:model (state session)))))
     (tuple "blocks" (rpc/json-list [])) (tuple "selectedBlock" (tag Null))
     (tuple "appliedServerT" (if-some [value (projection-server-t session)] (tag Int value) (tag Null)))
     (tuple "pendingSyncRequest" (pending-request-json session))
     (tuple "hasPendingSemanticOperations" (tag Bool (has-pending-operations session)))
     (tuple "isPendingSyncPatch" (tag Bool true))])))

(defn reconcile-authoritative-blocks! [session]
  (when-some [load (:authoritative-graph-blocks (host session))]
    (when-some [blocks (load)] (rpc/reconcile-authoritative-blocks (:model (state session)) blocks))))

(defn discover-graphs [session config]
  (debug "graph discovery started")
  (match ((:send (host session)) (api/graphs-request config))
    (Error message) (Error message)
    (Ok response)
    (if (or (< (:status response) 200) (>= (:status response) 300))
      (do (debug (format "graph discovery failed status=%d body=%S" (:status response) (:body response)))
          (Error (str "Logseq graphs API returned HTTP " (:status response))))
      (try
        (swap! (:state session) assoc :available-graphs (vec (api/graphs-from-graphs-body (:body response))))
        (when-some [save (:save-graph-catalog (host session))] (save (:body response)))
        (Ok (stdlib/ignore 0))
        (catch error (Error (str "Could not parse Logseq graphs response: " (exceptions/to-string error))))))))

(defn refresh-from-remote [session config]
  (rpc/refresh-from-remote (:model (state session)) config (:send (host session)) (now-ms) #(snapshot-visible session)))

(defn resolve-graph [^:api/api-config config]
  (if (not (string/blank? (:graph-id config)))
    (do (debug (str "graph discovery skipped graph=" (:graph-id config))) (Ok config))
    (Error "Select a Logseq graph before syncing")))

(defn load-related [session request key]
  (let [blocks (match ((:send (host session)) request)
                 (Ok response) (if (<= 200 (:status response) 299) (vec (api/blocks-from-list-body key (:body response)))
                                   (do (debug (str "related blocks HTTP failed status=" (:status response))) []))
                 (Error message) (do (debug (str "related blocks request failed message=" message)) []))]
    (swap! (:state session) assoc :related-blocks blocks)
    (snapshot-visible session)))

(defn dispatch-outliner-event [session payload]
  (match (rpc/outliner-message payload)
    (Error message) (rpc/failure "invalid_outliner_event" message)
    (Ok message)
    (if (not (rpc/outliner-structure-source-matches? (:outliner-state (state session)) payload))
      (outliner-patch session (outliner-context session) [])
      (let [[context aggregate] (if-some [[context uuid] (aggregate-return-context session payload message)]
                                  (tuple context (Some uuid)) (tuple (outliner-context session) nil))
            previous (:outliner-state (state session))
            [next-state commands] (outliner/update context previous message)
            base-t (or (projection-server-t session) -1)]
        (match (effects/interpret base-t now-ms fresh-squuid context commands)
          (Error error) (rpc/failure "outliner_command_failed" error)
          (Ok interpreted)
          (let [operations (vec (mapcat #(normalize-operation-titles session %) (:operations interpreted)))
                enqueue-result
                (cond (empty? operations) (Ok (stdlib/ignore 0))
                      (nil? (:config (state session))) (Error "Select a graph before editing")
                      (= base-t -1) (Error "A current server cursor is required")
                      :else (reduce (fn [result operation] (let* [_ result] (enqueue-semantic session operation)))
                                    (Ok (stdlib/ignore 0)) operations))]
            (match enqueue-result
              (Error error) (rpc/failure "outliner_effect_failed" error)
              (Ok _)
              (let [page-scoped (or (some? aggregate) (and (not (empty? operations)) (some? (:selected-sidebar-page (state session)))))
                    projected (if (empty? operations) context (project-outliner-operations context operations))
                    projected (refresh-reference-metadata session aggregate projected operations)
                    next-state (reduce (fn [current operation]
                                         (let [[next _] (outliner/update projected current (outliner/Operation_staged (:intent operation)))] next))
                                       next-state operations)]
                (swap! (:state session) assoc :outliner-state next-state
                       :outliner-optimistic-blocks (Some (vec (:blocks projected)))
                       :outliner-commands (vec (:platform interpreted))
                       :outliner-revision (inc (:outliner-revision (state session))))
                (if (not (empty? (:node-routes (state session)))) (snapshot-visible session)
                    (match (event-patch-plan message operations)
                      (so/Patch-blocks changed) (outliner-patch session projected changed)
                      so/Structural-diff
                      (if (and (some? aggregate) (not page-scoped)) (snapshot-visible session)
                          (structural-outliner-patch page-scoped session context previous projected))))))))))))

(defn switch-graph-model [session payload]
  (if-some [load (:model-for-graph (host session))]
    (try
      (match (json/from-string payload)
        (tag Assoc fields)
        (match (get (into {} (reverse fields)) "graphId")
          (Some (tag String uuid))
          (if (= uuid "") (Error "graph storage payload requires graphId")
              (do (swap! (:state session) assoc :model (load uuid) :accepted-server-t nil :pending-sync nil
                         :semantic-queue [] :semantic-active nil :flashcards [])
                  (clear-node-navigation! session)
                  (swap! (:state session) assoc :selected-sidebar-page nil)
                  (reset-outliner! session)
                  (Ok (stdlib/ignore 0))))
          _ (Error "graph storage payload requires graphId"))
        _ (Error "graph storage payload must be an object"))
      (catch error (Error (exceptions/to-string error))))
    (Ok (stdlib/ignore 0))))

(defn with-object [action payload missing handle]
  (if-some [payload payload]
    (match (try (Ok (json/from-string payload)) (catch _ (Error (str action " payload must be valid JSON"))))
      (Error message) (rpc/failure "invalid_json" message)
      (Ok input) (match input
                   (tag Assoc fields) (handle input (into {} (reverse fields)))
                   _ (rpc/failure "invalid_params" (str action " payload must be an object"))))
    (rpc/failure "invalid_params" missing)))

(defn stage-result [session operation-id base-t intent]
  (match (enqueue-semantic session (record ops/pending-operation (operation-id operation-id) (base-t base-t)
                                           (state ops/Queued) (intent intent)))
    (Ok _) (snapshot-visible session)
    (Error message) (rpc/failure "stage_operation_failed" message)))

(defn editing-cursor [session]
  (match (projection-server-t session)
    None (Error (tuple "stale_server_cursor" "A current server cursor is required"))
    (Some cursor) (if (nil? (:config (state session)))
                    (Error (tuple "graph_not_configured" "Select a graph before editing")) (Ok cursor))))

(defn checked-edit [session operation-id expected verb missing build]
  (cond
    (nil? expected) (rpc/failure "invalid_params" missing)
    (nil? (:config (state session)))
    (rpc/failure "graph_not_configured"
                 (str "Select a graph before "
                      (case verb "split" "splitting" "merge" "merging" "move" "moving" "deleting")))
    :else (if-some [cursor (projection-server-t session)]
            (if (not= expected (Some cursor)) (rpc/failure "stale_server_cursor" (str "The graph changed before " verb))
                (match (build) (Error message) (rpc/failure "invalid_params" message)
                       (Ok intent) (stage-result session operation-id cursor intent)))
            (rpc/failure "stale_server_cursor" "A current server cursor is required"))))

(defn configure [session input fields]
  (let [field (fn [name] (match (get fields name) (Some (tag String value)) (Some value) _ nil))]
    (match (tuple (field "baseUrl") (field "token"))
      (tuple (Some base-url) (Some token))
      (let [uuid (or (field "graphId") "")
            name (or (when-some [name (field "graphName")] (when (not (string/blank? name)) (Some (string/trim name))))
                     (when-some [graph (first (filter #(= (:id %) uuid) (:available-graphs (state session))))] (Some (:name graph))))
            config (record api/api-config (base-url base-url) (graph-id uuid) (graph-name name) (token token))]
        (swap! (:state session) assoc :accepted-server-t nil :config (Some config))
        (when (some #(and (= (:id %) uuid) (:e2ee %)) (:available-graphs (state session)))
          (when-some [load (:load-cached-graph-key (host session))] (load config)))
        (snapshot-visible session))
      _ (rpc/failure "invalid_params" "configure requires baseUrl and token strings"))))

(defn select-graph [session payload]
  (match (tuple (:config (state session)) payload)
    (tuple (Some config) (Some uuid))
    (if-some [graph (first (filter #(= (:id %) uuid) (:available-graphs (state session))))]
      (if (not (:ready graph)) (rpc/failure "graph_not_ready" "The selected graph is not ready for sync")
          (let [config (assoc config :graph-id (:id graph) :graph-name (Some (:name graph)))]
            (clear-node-navigation! session)
            (swap! (:state session) assoc :selected-sidebar-page nil :accepted-server-t nil :config (Some config))
            (reset-outliner! session)
            (when (:e2ee graph) (when-some [load (:load-cached-graph-key (host session))] (load config)))
            (snapshot-visible session)))
      (rpc/failure "unknown_graph" "The selected graph is not available"))
    _ (rpc/failure "invalid_params" "selectGraph requires a graph id")))

(defn select-page [session payload]
  (match (tuple payload (when-some [load (:graph-sidebar-pages (host session))] (load)))
    (tuple (Some uuid) (Some pages))
    (if-some [page (first (filter #(= (:uuid %) uuid) (concat (:favorites pages) (:recent-pages pages))))]
      (do (clear-node-navigation! session)
          (swap! (:state session) assoc :selected-sidebar-page (Some page))
          (swap! (:state session) assoc :related-blocks
                 (if (selected-page-is-tag session) []
                     (vec (or (when-some [load (:graph-node-references (host session))] (load (:uuid page))) (list)))))
          (reset-outliner! session) (snapshot-visible session))
      (rpc/failure "unknown_page" "The selected page is not available"))
    _ (rpc/failure "invalid_params" "selectPage requires a page id")))

(defn open-node [session fields]
  (match (rpc/required-string fields "uuid")
    (Error message) (rpc/failure "invalid_params" message)
    (Ok uuid)
    (if-some [[page zoom] (or (when-some [resolve (:graph-node-destination (host session))] (resolve uuid))
                              (projected-node-destination session uuid))]
      (let [tag? (if-some [check (:graph-node-is-tag (host session))] (check uuid) false)
            property? (if-some [check (:graph-node-is-property (host session))] (check uuid) false)
            loader (if tag? (:graph-tag-objects (host session)) (:graph-node-references (host session)))
            related (vec (or (when-some [load loader] (load uuid)) (list)))
            route (record types/node-route (uuid uuid) (is-tag tag?) (is-property property?) (page page)
                          (zoom-to-block zoom) (related-blocks related) (state outliner/empty))]
        (push-node-route! session route) (snapshot-visible session))
      (rpc/failure "unknown_node" "The referenced node is not available"))))

(defn send-message [session payload]
  (match (rpc/send-payload payload)
    (Error message) (rpc/failure "invalid_params" message)
    (Ok (tuple text uuid now))
    (if (= text "") (snapshot-visible session)
        (let [now (or now (now-ms)) uuid (or uuid (str "local-" now)) h (host session)]
          (if (and (some? (:config (state session))) (some? (:stage-operation h)) (some? (:prepare-operation h)))
            (match (enqueue-capture session uuid text now nil)
              (Ok _) (snapshot-visible session) (Error message) (rpc/failure "capture_failed" message))
            (do (model/cache-local-message (:model (state session)) uuid text now) (snapshot-visible session)))))))

(defn send-task [session input fields]
  (match (let* [text (rpc/required-string fields "text") uuid (rpc/required-string fields "uuid")
                now (rpc/optional-int fields "now") status (rpc/status-payload input)]
           (Ok (tuple text uuid now status)))
    (Error message) (rpc/failure "invalid_params" message)
    (Ok (tuple text uuid now status))
    (let [text (string/trim text)]
      (if (= text "") (snapshot-visible session)
          (let [now (or now (now-ms)) h (host session)]
            (if (and (some? (:config (state session))) (some? (:stage-operation h)) (some? (:prepare-operation h)))
              (match (enqueue-capture session uuid text now (Some status))
                (Ok _) (snapshot-visible session) (Error message) (rpc/failure "capture_failed" message))
              (do (model/cache-local-task (:model (state session)) uuid text status now) (snapshot-visible session))))))))

(defn update-block-status [session input fields]
  (if (some? (:stage-operation (host session)))
    (match (let* [uuid (rpc/required-string fields "uuid") operation-id (rpc/required-string fields "operationId")
                  expected-uuid (rpc/optional-string fields "expectedStatusUuid")
                  expected-ident (rpc/optional-string fields "expectedStatusIdent") status (rpc/status-payload input)]
             (Ok (tuple uuid operation-id expected-uuid expected-ident status)))
      (Error message) (rpc/failure "invalid_params" message)
      (Ok (tuple uuid operation-id expected-uuid expected-ident status))
      (match (editing-cursor session)
        (Error (tuple code message)) (rpc/failure code message)
        (Ok cursor)
        (let [expected (if-some [ident expected-ident] (Some (ops/Ref-ident ident))
                                (when-some [uuid expected-uuid] (Some (ops/Ref-uuid uuid))))]
          (stage-result session operation-id cursor
                        (ops/Set-property (record ops/pending-property (uuid uuid) (attr "logseq.property/status")
                                                  (expected expected) (value (Some (rpc/status-semantic-ref status)))))))))
    (match (let* [uuid (rpc/required-string fields "uuid") status (rpc/status-payload input)] (Ok (tuple uuid status)))
      (Error message) (rpc/failure "invalid_params" message)
      (Ok (tuple uuid status))
      (match (model/update-block-status (:model (state session)) uuid status (now-ms))
        (Ok _) (snapshot-visible session) (Error message) (rpc/failure "unknown_block" message)))))

(defn update-block [session input fields]
  (if (some? (:stage-operation (host session)))
    (match (let* [uuid (rpc/required-string fields "uuid") operation-id (rpc/required-string fields "operationId")
                  expected (rpc/required-string fields "expectedTitle") title (rpc/required-string fields "title")]
             (Ok (tuple uuid operation-id expected (string/trim title))))
      (Error message) (rpc/failure "invalid_params" message)
      (Ok (tuple uuid operation-id expected title))
      (match (editing-cursor session)
        (Error (tuple code message)) (rpc/failure code message)
        (Ok cursor) (if (= title "") (rpc/failure "invalid_params" "updateBlock title must not be empty")
                        (stage-result session operation-id cursor
                                      (ops/Save-title (record ops/pending-title (uuid uuid) (expected-title expected) (title title)))))))
    (match (let* [uuid (rpc/required-string fields "uuid") title (rpc/required-string fields "title")
                  status (rpc/optional-status-payload input)] (Ok (tuple uuid (string/trim title) status)))
      (Error message) (rpc/failure "invalid_params" message)
      (Ok (tuple uuid title status))
      (if (= title "") (rpc/failure "invalid_params" "updateBlock title must not be empty")
          (match (model/update-block-title (:model (state session)) uuid title (now-ms))
            (Error message) (rpc/failure "unknown_block" message)
            (Ok _) (do (when-some [status status] (model/update-block-status (:model (state session)) uuid status (now-ms)))
                       (snapshot-visible session)))))))

(defn split-block [session fields]
  (match (let* [uuid (rpc/required-string fields "uuid") operation-id (rpc/required-string fields "operationId")
                expected (rpc/optional-int fields "expectedServerT") title (rpc/required-string fields "expectedTitle")
                before (rpc/required-string fields "before") after (rpc/required-string fields "after")
                new-uuid (rpc/required-string fields "newUuid") order (rpc/required-string fields "newOrder")
                created (rpc/optional-int fields "createdAt")]
           (Ok (tuple operation-id expected created
                      (record ops/pending-split (uuid uuid) (expected-title title) (before before) (after after)
                              (new-uuid new-uuid) (new-order order) (created-at (or created 0))))))
    (Error message) (rpc/failure "invalid_params" message)
    (Ok (tuple operation-id expected created value))
    (if (nil? created) (rpc/failure "invalid_params" "splitBlock requires integer cursor and timestamp")
        (checked-edit session operation-id expected "split" "splitBlock requires integer cursor and timestamp"
                      (fn [] (if (or (= (:uuid value) (:new-uuid value)) (string/blank? (:new-uuid value)) (string/blank? (:new-order value)))
                               (Error "Invalid split block fragments or identity") (Ok (ops/Split-block value))))))))

(defn merge-backward [session fields]
  (match (let* [uuid (rpc/required-string fields "uuid") operation-id (rpc/required-string fields "operationId")
                expected (rpc/optional-int fields "expectedServerT") expected-title (rpc/required-string fields "expectedTitle")
                title (rpc/required-string fields "title") previous (rpc/required-string fields "previousUuid")
                previous-title (rpc/required-string fields "expectedPreviousTitle")]
           (Ok (tuple operation-id expected
                      (record ops/pending-merge (uuid uuid) (expected-title expected-title) (title title)
                              (previous-uuid previous) (expected-previous-title previous-title) (merged-title nil)))))
    (Error message) (rpc/failure "invalid_params" message)
    (Ok (tuple operation-id expected value))
    (checked-edit session operation-id expected "merge" "mergeBackward requires expectedServerT"
                  (fn [] (if (= (:uuid value) (:previous-uuid value)) (Error "merge source and target must differ")
                             (Ok (ops/Merge-backward value)))))))

(defn move-blocks [session input fields]
  (match (let* [operation-id (rpc/required-string fields "operationId") expected (rpc/optional-int fields "expectedServerT")
                moves (rpc/required-moves input)] (Ok (tuple operation-id expected moves)))
    (Error message) (rpc/failure "invalid_params" message)
    (Ok (tuple operation-id expected moves))
    (checked-edit session operation-id expected "move" "moveBlocks requires expectedServerT"
                  (fn [] (if (or (empty? moves) (not= (count moves) (count (set (map :uuid moves)))))
                           (Error "moveBlocks requires distinct moves") (Ok (ops/Move-blocks (record ops/pending-moves (moves moves)))))))))

(defn delete-blocks [session input fields]
  (match (let* [operation-id (rpc/required-string fields "operationId") expected (rpc/optional-int fields "expectedServerT")
                uuids (rpc/required-string-list "uuids" input)] (Ok (tuple operation-id expected uuids)))
    (Error message) (rpc/failure "invalid_params" message)
    (Ok (tuple operation-id expected uuids))
    (checked-edit session operation-id expected "delete" "deleteBlocks requires expectedServerT"
                  (fn [] (if (empty? uuids) (Error "deleteBlocks requires block ids")
                             (Ok (ops/Delete-blocks (record ops/pending-delete (uuids (vec (sort (set uuids))))))))))))

(defn delete-block [session fields]
  (match (let* [uuid (rpc/required-string fields "uuid") operation-id (rpc/required-string fields "operationId")
                expected (rpc/optional-int fields "expectedServerT")] (Ok (tuple uuid operation-id expected)))
    (Error message) (rpc/failure "invalid_params" message)
    (Ok (tuple uuid operation-id expected))
    (checked-edit session operation-id expected "delete" "deleteBlock requires expectedServerT"
                  (fn [] (Ok (ops/Delete-blocks (record ops/pending-delete (uuids [uuid]))))))))

(defn reload-flashcards! [session now]
  (swap! (:state session) assoc :flashcards
         (if-some [load (:graph-due-flashcards (host session))] (vec (load now)) []))
  (stdlib/ignore 0))

(defn load-references [session payload request key]
  (match (tuple (:config (state session)) payload)
    (tuple (Some config) (Some uuid))
    (match (resolve-graph config) (Ok config) (load-related session (request config uuid) key) _ (snapshot-visible session))
    _ (snapshot-visible session)))

(defn dispatch [session action payload]
  (let [s (state session) h (host session)
        object-action (fn [handle] (with-object action payload (str action " requires a JSON payload") handle))]
    (case action
      "outlinerEvent" (if-some [payload payload] (dispatch-outliner-event session payload)
                               (rpc/failure "invalid_params" "outlinerEvent requires a JSON payload"))
      "configure" (object-action #(configure session %1 %2))
      "refresh"
      (if-some [config (:config s)]
        (cond
          (string/blank? (:graph-id config))
          (match (discover-graphs session config) (Ok _) (snapshot-visible session)
                 (Error message) (rpc/failure "graph_discovery_failed" message))
          (selected-graph-is-encrypted session)
          (if (selected-graph-is-unlocked session) (snapshot-visible session)
              (rpc/failure "encrypted_graph_locked" "Unlock the encrypted graph first"))
          :else (refresh-from-remote session config))
        (snapshot-visible session))
      "refreshGraphCatalog"
      (if-some [config (:config s)]
        (do (match (discover-graphs session config)
              (Ok _)
              (let [name (when-some [graph (first (filter #(= (:id %) (:graph-id config)) (:available-graphs (state session))))]
                           (Some (:name graph)))]
                (swap! (:state session) assoc :config (Some (assoc config :graph-name name))) (stdlib/ignore 0))
              (Error message) (debug (str "graph catalog refresh failed: " message)))
            (graph-catalog-snapshot session))
        (graph-catalog-snapshot session))
      "createSyncGraph"
      (rpc/create-sync-graph (:config s) payload (:send h) (:provision-graph-key h)
                             (fn [config encrypted] (rpc/upload-initial-graph-snapshot config encrypted (:encrypt-title h) (:upload-file h) (:cleanup-file h)))
                             #(discover-graphs session %)
                             (fn [config] (swap! (:state session) assoc :accepted-server-t nil :config (Some config)) (snapshot-visible session)))
      "selectGraph" (select-graph session payload)
      "selectPage" (select-page session payload)
      "openNode" (with-object action payload "openNode requires a node id" (fn [_ fields] (open-node session fields)))
      "closeNode" (do (pop-node-route! session) (snapshot-visible session))
      "clearSelectedPage"
      (do (clear-node-navigation! session)
          (swap! (:state session) assoc :selected-sidebar-page nil)
          (reset-outliner! session)
          (snapshot-visible session))
      "loadOlderJournals" (do (when-some [load (:load-older-journals h)] (load)) (snapshot-visible session))
      "loadFlashcards"
      (let [now (or (when-some [value payload] (stdlib/int-of-string-opt value)) (now-ms))]
        (reload-flashcards! session now)
        (debug (str "loadFlashcards count=" (count (:flashcards (state session))) " now=" now))
        (snapshot-visible session))
      "reviewFlashcard"
      (rpc/review-flashcard payload (:graph-review-flashcard h) now-ms
                            (fn [now]
                              (when (some? (:config (state session))) (restore-semantic-queue! session))
                              (reload-flashcards! session now)
                              (snapshot-visible session)))
      "setPageFavorite"
      (rpc/set-page-favorite payload (:graph-set-page-favorite h) (some? (:config s)) now-ms
                             (fn [] (when (some? (:config s)) (restore-semantic-queue! session)) (snapshot-visible session)))
      "deletePage"
      (rpc/delete-page payload (:graph-delete-page h) (some? (:config s)) now-ms
                       (fn [] (when (some? (:config s)) (restore-semantic-queue! session)) (snapshot-visible session)))
      "unlockGraph"
      (match (tuple (:config s) (:unlock-graph h) payload)
        (tuple (Some config) (Some unlock) (Some password))
        (if (selected-graph-is-encrypted session)
          (match (unlock config password) (Ok _) (snapshot-visible session) (Error message) (rpc/failure "graph_unlock_failed" message))
          (snapshot-visible session))
        _ (cond (and (some? (:config s)) (not (selected-graph-is-encrypted session)))
                (snapshot-visible session)
                (nil? (:unlock-graph h)) (rpc/failure "graph_unlock_unavailable" "Graph unlock is unavailable")
                :else (rpc/failure "invalid_params" "unlockGraph requires a selected graph and password")))
      "importSnapshot" (rpc/import-snapshot payload (:import-snapshot h) #(switch-graph-model session %) #(snapshot-visible session))
      "openGraph" (rpc/open-graph payload (:open-graph h) #(switch-graph-model session %) #(snapshot-visible session))
      "startWebSocket" (do (swap! (:state session) assoc :sync-connected true) (snapshot-visible session))
      "applySyncEvent" (rpc/apply-sync-event payload (:apply-sync-event h)
                                             (fn [] (reconcile-authoritative-blocks! session) (snapshot-visible session)))
      "stopWebSocket" (do (swap! (:state session) assoc :sync-connected false) (snapshot-visible session))
      "searchNodes"
      (let [query (or payload "")
            found (if (string/blank? query) [] (if-some [search (:graph-search h)] (vec (search query)) []))]
        (swap! (:state session) assoc :search-query query :search-results found) (snapshot-visible session))
      "send" (send-message session payload)
      "sendTask" (object-action #(send-task session %1 %2))
      "addAsset"
      (let [prepare-view (fn []
                           (let [before (outliner-context session) previous (:outliner-state (state session))]
                             (fn [] (let [s (state session)]
                                      (if (and (nil? (:selected-sidebar-page s)) (empty? (:node-routes s)))
                                        (structural-outliner-patch false session before previous (outliner-context session))
                                        (snapshot-visible session))))))
            target (fn [uuid] (first (filter #(= (:uuid %) uuid) (:blocks (base-outliner-context session)))))
            stage (fn [] (when (some? (:config (state session))) (:stage-operation (host session))))]
        (rpc/add-asset payload (:model s) now-ms target prepare-view #(asset-datoms-operation session % ops/Applied) stage))
      "addChildBlock"
      (rpc/add-child-block payload (:model s) now-ms #(tuple (:config (state session)) (projection-server-t session))
                           #(outliner-context session) (fn [_ operation] (enqueue-semantic session operation)) fresh-squuid #(snapshot-visible session))
      "beginPendingSync"
      (do (when-some [config (:config s)]
            (match (resolve-graph config) (Ok config) (begin-pending-sync! session config) _ (stdlib/ignore 0)))
          (pending-sync-patch session))
      "completePendingSync"
      (if-some [payload payload]
        (let [semantic? (some? (:semantic-active s))]
          (match (complete-pending-sync session payload)
            (Ok _) (if semantic? (pending-sync-patch session) (snapshot-visible session))
            (Error message) (rpc/failure "invalid_pending_sync_completion" message)))
        (rpc/failure "invalid_params" "completePendingSync requires a JSON payload"))
      "cancelPendingSync" (do (cancel-pending-sync! session) (snapshot-visible session))
      "loadBlockReferences" (load-references session payload api/block-references-request "references")
      "loadPageReferences" (load-references session payload api/page-references-request "references")
      "loadTagObjects"
      (if-some [load (:graph-tag-objects h)]
        (do (when-some [uuid payload] (swap! (:state session) assoc :related-blocks (vec (or (load uuid) (list)))))
            (snapshot-visible session))
        (load-references session payload api/tag-objects-request "objects"))
      "clearRelated" (do (swap! (:state session) assoc :related-blocks []) (snapshot-visible session))
      "updateBlockStatus" (object-action #(update-block-status session %1 %2))
      "updateBlock" (object-action #(update-block session %1 %2))
      "splitBlock" (object-action (fn [_ fields] (split-block session fields)))
      "mergeBackward" (object-action (fn [_ fields] (merge-backward session fields)))
      "moveBlocks" (object-action #(move-blocks session %1 %2))
      "deleteBlocks" (object-action #(delete-blocks session %1 %2))
      "deleteBlock" (object-action (fn [_ fields] (delete-block session fields)))
      "select" (if-some [uuid payload]
                 (match (model/select (:model s) uuid) (Ok _) (snapshot-visible session) (Error message) (rpc/failure "unknown_block" message))
                 (rpc/failure "invalid_params" "select requires a block uuid"))
      "clearSelection" (do (model/clear-selection (:model s)) (snapshot-visible session))
      (rpc/failure "unknown_action" (str "unknown action: " action)))))

(defn call [session request]
  (rpc/call #(snapshot-visible session) #(dispatch session %1 %2) request))
