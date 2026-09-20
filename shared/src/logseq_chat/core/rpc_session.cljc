(ns logseq-chat.rpc-session
  (:require [clojure.string :as string]
            [logseq-chat.rpc :as rpc]
            [logseq-chat.cache-model :as model]
            [logseq-chat.api :as api]
            [logseq-chat.http :as http]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.outliner-state :as outliner]
            [logseq-chat.outliner-effects :as effects]
            [logseq-chat.graph-read :as graph]
            [logseq-chat.search-index :as search]
            [logseq-chat.flashcards :as cards]
            [ocaml.Datascript :as ds]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Unix :as unix]
            [ocaml.Sys :as sys]
            [ocaml.Printexc :as exceptions]
            [ocaml.Stdlib :as stdlib]))

(type-variant pending-transport (Json-request :api/api-request) (File-upload :api/api-file-upload))

(type-record moved-asset (block :model/block) (remote-uuid :string))

(type-record created-journal
             (block :model/block) (encrypted-title :string) (page-id :string) (journal-day :int))

(type-variant transport-operation
              (Create-block :model/block) (Upload-asset :model/block) (Move-created-asset :moved-asset)
              (Update-title :model/block) (Update-status :model/block) (Create-journal :created-journal))

(type-record pending-active
             (id :int) (transport :pending-transport) (operation :transport-operation) (cleanup-path :option<string>))

(type-record pending-sync
             (config :api/api-config) (remaining :ref<vector<model/block>>) (authoritative :set<string>)
             (resolved-journal-pages :ref<map<int;string>>) (active :ref<option<pending-active>>))

(type-record semantic-pending (operation :ops/pending-operation))

(type-record semantic-active (id :int) (pending :semantic-pending) (request :api/api-request))

(type-record node-route
             (uuid :string) (is-tag :bool) (is-property :bool) (page :model/entity-summary)
             (zoom-to-block :bool) (related-blocks :vector<model/block>) (state :outliner/outliner-state))

(type-record host-options
             (storage :option<Datascript.storage>)
             (open-graph :option<fn<string;result<unit;string>>>)
             (import-snapshot :option<fn<string;result<unit;string>>>)
             (model-for-graph :option<fn<string;model/CacheModel>>)
             (apply-sync-event :option<fn<string;result<unit;string>>>)
             (sync-cursor :option<fn<option<int>>>)
             (graph-blocks :option<fn<option<list<model/block>>>>)
             (authoritative-graph-blocks :option<fn<option<list<model/block>>>>)
             (graph-sidebar-pages :option<fn<option<graph/sidebar-pages>>>)
             (graph-tag-pages :option<fn<option<list<model/entity-summary>>>>)
             (graph-node-is-tag :option<fn<string;bool>>)
             (graph-node-is-property :option<fn<string;bool>>)
             (graph-page-blocks :option<fn<string;option<list<model/block>>>>)
             (graph-node-destination :option<fn<string;option<tuple<model/entity-summary;bool>>>>)
             (graph-node-references :option<fn<string;option<list<model/block>>>>)
             (graph-tag-objects :option<fn<string;option<list<model/block>>>>)
             (graph-normalize-titles :option<fn<string;list<string>;tuple<list<string>;list<tuple<string;string>>>>>)
             (graph-search :option<fn<string;list<search/indexed-search-hit>>>)
             (graph-due-flashcards :option<fn<int;list<cards/due-card>>>)
             (graph-review-flashcard :option<fn<string;cards/flashcard-rating;int;string;result<unit;string>>>)
             (graph-set-page-favorite :option<fn<string;bool;string;int;result<unit;string>>>)
             (graph-delete-page :option<fn<string;string;int;result<unit;string>>>)
             (load-older-journals :option<fn<unit>>) (has-older-journals :option<fn<bool>>)
             (load-cached-graph-key :option<fn<api/api-config;result<unit;string>>>)
             (unlock-graph :option<fn<api/api-config;string;result<unit;string>>>)
             (provision-graph-key :option<fn<api/api-config;result<unit;string>>>)
             (graph-unlocked :option<fn<string;bool>>)
             (encrypt-title :option<fn<string;string;result<string;string>>>)
             (resolve-asset-path :fn<string;string>)
             (encrypt-asset-file :option<fn<string;string;result<tuple<string;int>;string>>>)
             (journal-page-id :option<fn<int;option<string>>>)
             (send :fn<api/api-request;result<api/api-response;string>>)
             (upload-file :fn<api/api-file-upload;result<api/api-response;string>>)
             (cleanup-file :fn<string;unit>)
             (stage-operation :option<fn<ops/pending-operation;result<unit;string>>>)
             (prepare-operation :option<fn<ops/pending-operation;result<tuple<string;string>;string>>>)
             (pending-operations :option<fn<list<ops/pending-operation>>>)
             (load-graph-catalog :option<fn<option<string>>>) (save-graph-catalog :option<fn<string;unit>>))

(type-record session-state
             (model :model/CacheModel) (config :option<api/api-config>) (available-graphs :vector<api/api-graph>)
             (related-blocks :vector<model/block>) (selected-sidebar-page :option<model/entity-summary>)
             (node-routes :vector<node-route>) (node-base-state :option<outliner/outliner-state>)
             (accepted-server-t :option<int>) (flashcards :vector<cards/due-card>)
             (search-results :vector<search/indexed-search-hit>) (search-query :string)
             (sync-connected :bool) (pending-sync :option<pending-sync>) (next-pending-request-id :int)
             (semantic-queue :vector<semantic-pending>) (semantic-active :option<semantic-active>)
             (outliner-state :outliner/outliner-state) (outliner-optimistic-blocks :option<vector<model/block>>)
             (outliner-commands :vector<effects/outliner-platform-command>) (outliner-revision :int))

(type-record session (host :host-options) (state :ref<session-state>))

(def default-options
  (record host-options
          (storage nil) (open-graph nil) (import-snapshot nil) (model-for-graph nil) (apply-sync-event nil)
          (sync-cursor nil) (graph-blocks nil) (authoritative-graph-blocks nil) (graph-sidebar-pages nil)
          (graph-tag-pages nil) (graph-node-is-tag nil) (graph-node-is-property nil) (graph-page-blocks nil)
          (graph-node-destination nil) (graph-node-references nil) (graph-tag-objects nil)
          (graph-normalize-titles nil) (graph-search nil) (graph-due-flashcards nil) (graph-review-flashcard nil)
          (graph-set-page-favorite nil) (graph-delete-page nil) (load-older-journals nil) (has-older-journals nil)
          (load-cached-graph-key nil) (unlock-graph nil) (provision-graph-key nil) (graph-unlocked nil)
          (encrypt-title nil) (resolve-asset-path identity) (encrypt-asset-file nil) (journal-page-id nil)
          (send http/send) (upload-file http/upload-file)
          (cleanup-file (fn [path] (try (sys/remove path) (catch _ (stdlib/ignore 0)))))
          (stage-operation nil) (prepare-operation nil) (pending-operations nil)
          (load-graph-catalog nil) (save-graph-catalog nil)))

(defn state [session] @(:state session))

(defn host [session] (:host session))

(defn now-ms [] (int (* (unix/gettimeofday) 1000.0)))

(defn debug [message] (stdlib/prerr-endline (str "LogseqChat core " message)))

(defn fresh-squuid []
  (match (ds/squuid) (ds/Uuid uuid) uuid _ (stdlib/failwith "Datascript.squuid returned a non-UUID value")))

(defn projection-server-t [session] (when-some [cursor (:sync-cursor (host session))] (cursor)))

(defn submission-server-t [session]
  (match (tuple (projection-server-t session) (:accepted-server-t (state session)))
    (tuple (Some applied) (Some accepted)) (Some (max applied accepted))
    (tuple (Some applied) None) (Some applied)
    (tuple None accepted) accepted))

(defn record-accepted-server-t! [session accepted]
  (swap! (:state session) assoc :accepted-server-t
         (Some (if-some [previous (:accepted-server-t (state session))] (max previous accepted) accepted))))

(defn create-session [options]
  (let [options (assoc options :authoritative-graph-blocks
                       (or (:authoritative-graph-blocks options) (:graph-blocks options)))
        catalog (when-some [load (:load-graph-catalog options)] (load))
        graphs (if-some [body catalog] (try (vec (api/graphs-from-graphs-body body)) (catch _ [])) [])]
    (record session
            (host options)
            (state (atom (record session-state
                                 (model (model/create (:storage options))) (config nil) (available-graphs graphs)
                                 (related-blocks []) (selected-sidebar-page nil) (node-routes []) (node-base-state nil)
                                 (accepted-server-t nil) (flashcards []) (search-results []) (search-query "")
                                 (sync-connected false) (pending-sync nil) (next-pending-request-id 0)
                                 (semantic-queue []) (semantic-active nil) (outliner-state outliner/empty)
                                 (outliner-optimistic-blocks nil) (outliner-commands []) (outliner-revision 0)))))))

(defn pending-request-json [session]
  (if-some [active (:semantic-active (state session))]
    (rpc/request-json (:id active) (:request active) nil "application/json" [])
    (if-some [pump (:pending-sync (state session))]
      (if-some [active @(:active pump)]
        (match (:transport active)
          (Json-request request) (rpc/request-json (:id active) request nil "application/json" [])
          (File-upload upload) (rpc/request-json (:id active) (:request upload) (Some (:file-path upload))
                                                 (:content-type upload) (:headers upload)))
        (tag Null))
      (tag Null))))

(def empty-sidebar (record graph/sidebar-pages (favorites []) (recent-pages [])))

(defn sidebar-pages [session]
  (or (when-some [load (:graph-sidebar-pages (host session))] (load)) empty-sidebar))

(defn outliner-context-with-blocks [session sidebar blocks]
  (let [sidebar (or sidebar (sidebar-pages session))
        pages (mapv (fn [page] (record outliner/outliner-candidate (label (:title page)) (value (:uuid page))))
                    (concat (:favorites sidebar) (:recent-pages sidebar)))
        tags (if-some [load (:graph-tag-pages (host session))]
               (mapv (fn [page] (record outliner/outliner-candidate (label (:title page)) (value (:uuid page))))
                     (or (load) (list))) [])]
    (record outliner/outliner-context (blocks (apply list blocks)) (pages (apply list pages)) (tags (apply list tags)))))

(defn base-outliner-context-live [session]
  (let [s (state session) h (host session)
        blocks (match (tuple (:selected-sidebar-page s) (:graph-page-blocks h) (:graph-blocks h))
                 (tuple (Some page) (Some load) _) (vec (or (load (:uuid page)) (list)))
                 (tuple _ _ (Some load)) (vec (or (load) (list)))
                 _ (model/visible-blocks (:model s)))]
    (outliner-context-with-blocks session nil blocks)))

(defn page-overlay [session page-id blocks]
  (rpc/page-blocks-with-optimistic-overlay (:outliner-optimistic-blocks (state session))
                                           (outliner/editing-uuid (:outliner-state (state session))) page-id blocks))

(defn scope-selected-page [session context]
  (if-some [page (:selected-sidebar-page (state session))]
    (assoc context :blocks (apply list (page-overlay session (:uuid page) (:blocks context)))) context))

(defn base-outliner-context-with-blocks [session sidebar blocks]
  (scope-selected-page session (outliner-context-with-blocks session sidebar blocks)))

(defn base-outliner-context [session] (scope-selected-page session (base-outliner-context-live session)))

(defn page-outliner-context [session uuid]
  (when-some [load (:graph-page-blocks (host session))]
    (when-some [blocks (load uuid)] (Some (outliner-context-with-blocks session nil blocks)))))

(defn node-route-context [session route]
  (let [blocks (if-some [load (:graph-page-blocks (host session))] (or (load (:uuid (:page route))) (list)) (list))]
    (outliner-context-with-blocks session nil (page-overlay session (:uuid (:page route)) blocks))))

(defn active-node-route [session] (last (:node-routes (state session))))

(defn node-route-related-blocks [session route]
  (let [loader (if (:is-tag route) (:graph-tag-objects (host session)) (:graph-node-references (host session)))]
    (if-some [blocks (when-some [load loader] (load (:uuid route)))] (vec blocks) (:related-blocks route))))

(defn node-route-linked-reference-blocks [session route]
  (if (:is-tag route)
    (vec (or (when-some [load (:graph-node-references (host session))] (load (:uuid route))) (list))) []))

(defn page-for-visible-block [block]
  (let [title (match (:journal block)
                (Some (tuple title _)) (when (not (string/blank? title)) (Some title))
                None nil)
        title (or title (when-some [page (first (filter #(= (:uuid %) (:page-id block)) (:breadcrumbs block)))]
                          (Some (:title page))) (:title block))]
    (record model/entity-summary (uuid (:page-id block)) (title title))))

(defn projected-node-destination [session uuid]
  (let [s (state session) h (host session)
        graph-blocks (or (when-some [load (:graph-blocks h)] (load)) (list))
        selected-blocks (match (tuple (:selected-sidebar-page s) (:graph-page-blocks h))
                          (tuple (Some page) (Some load)) (or (load (:uuid page)) (list)) _ (list))
        blocks (vec (concat graph-blocks selected-blocks
                            (mapcat #(vec (:blocks (node-route-context session %))) (:node-routes s))
                            (:related-blocks s) (or (:outliner-optimistic-blocks s) [])))
        candidate (if-some [block (first (filter #(= (:uuid %) uuid) blocks))]
                    (Some (tuple block true))
                    (when-some [block (first (filter #(= (:page-id %) uuid) blocks))] (Some (tuple block false))))]
    (when-some [[block zoom] candidate]
      (when (not= (:page-id block) "") (Some (tuple (page-for-visible-block block) zoom))))))

(defn with-extra-blocks [context extra]
  (let [present (set (map :uuid (:blocks context)))]
    (assoc context :blocks (apply list (concat (:blocks context) (filter #(not (contains? present (:uuid %))) extra))))))

(defn outliner-context [session]
  (if-some [route (active-node-route session)]
    (with-extra-blocks (node-route-context session route)
      (concat (node-route-related-blocks session route) (node-route-linked-reference-blocks session route)))
    (with-extra-blocks (base-outliner-context session) (:related-blocks (state session)))))

(defn project-outliner-operations [context operations]
  (assoc context :blocks
         (apply list (reduce (fn [blocks operation] (rpc/project-outliner-intent blocks (:intent operation)))
                             (vec (:blocks context)) operations))))

(defn selected-graph [session]
  (when-some [config (:config (state session))]
    (first (filter #(= (:id %) (:graph-id config)) (:available-graphs (state session))))))

(defn selected-graph-is-encrypted [session]
  (if-some [graph (selected-graph session)] (:e2ee graph) false))

(defn selected-graph-is-unlocked [session]
  (match (tuple (:config (state session)) (selected-graph session))
    (tuple config (Some graph))
    (if (not (:e2ee graph)) true
        (match (tuple config (:graph-unlocked (host session)))
          (tuple (Some config) (Some unlocked)) (unlocked (:graph-id config)) _ false))
    _ false))

(defn selected-page-is-tag [session]
  (match (tuple (:selected-sidebar-page (state session)) (:graph-node-is-tag (host session)))
    (tuple (Some page) (Some check)) (check (:uuid page)) _ false))

(defn selected-page-is-property [session]
  (match (tuple (:selected-sidebar-page (state session)) (:graph-node-is-property (host session)))
    (tuple (Some page) (Some check)) (check (:uuid page)) _ false))

(defn snapshot-related-blocks [session]
  (if (selected-page-is-tag session)
    (match (tuple (:selected-sidebar-page (state session)) (:graph-tag-objects (host session)))
      (tuple (Some page) (Some load)) (vec (or (load (:uuid page)) (list))) _ [])
    (:related-blocks (state session))))

(defn snapshot-linked-reference-blocks [session]
  (if (selected-page-is-tag session)
    (match (tuple (:selected-sidebar-page (state session)) (:graph-node-references (host session)))
      (tuple (Some page) (Some load)) (vec (or (load (:uuid page)) (list))) _ []) []))

(defn has-pending-operations [session]
  (let [s (state session)]
    (or (not (empty? (:semantic-queue s))) (some? (:semantic-active s)) (some? (:pending-sync s))
        (not (empty? (model/pending-blocks (:model s)))))))

(defn node-routes-json [session]
  (let [active (active-node-route session)]
    (rpc/json-list
     (map (fn [route]
            (let [current (if (match active (Some active) (= (:uuid active) (:uuid route)) None false)
                            (:outliner-state (state session)) (:state route))
                  context (node-route-context session route)]
              (rpc/json-object
               [(tuple "uuid" (tag String (:uuid route))) (tuple "isTag" (tag Bool (:is-tag route)))
                (tuple "isProperty" (tag Bool (:is-property route))) (tuple "page" (rpc/summary-json (:page route)))
                (tuple "blocks" (rpc/json-list (map rpc/visible-block-json (:blocks context))))
                (tuple "relatedBlocks" (rpc/json-list (map rpc/block-json (node-route-related-blocks session route))))
                (tuple "linkedReferenceBlocks" (rpc/json-list (map rpc/block-json (node-route-linked-reference-blocks session route))))
                (tuple "outlinerState" (rpc/outliner-state-json current))
                (tuple "outlinerRows" (rpc/outliner-rows-json rpc/visible-block-json context current))
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
           (tuple "nodeRoutes" (node-routes-json session))
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

(defn pending-block-unchanged [session sent]
  (if-some [current (model/read-block (:model (state session)) (:uuid sent))] (rpc/same-pending-version? sent current) false))

(defn mark-pending-failed! [session block]
  (when (pending-block-unchanged session block) (model/mark-block-sync-failed (:model (state session)) (:uuid block))))

(defn set-pending-active! [session pump transport operation cleanup]
  (let [next-id (inc (:next-pending-request-id (state session)))]
    (swap! (:state session) assoc :next-pending-request-id next-id)
    (reset! (:active pump) (Some (record pending-active (id next-id) (transport transport) (operation operation) (cleanup-path cleanup))))))

(defn encrypted-title [session config title]
  (if-some [encrypt (:encrypt-title (host session))] (encrypt (:graph-id config) title)
           (Error "encrypted graph title encryption is unavailable")))

(defn prepare-pending-create-request [session pump block title page-id]
  (let [config (:config pump)]
    (match (tuple (:status block) (:local-path block) (:asset-type block) (:asset-size block) (:asset-checksum block))
      (tuple (Some status) _ _ _ _)
      (do (set-pending-active! session pump (Json-request (api/task-request page-id config (:uuid block) (:uuid status) title))
                               (Create-block block) nil)
          (Ok (stdlib/ignore 0)))
      (tuple None (Some source) (Some asset-type) (Some _) (Some checksum))
      (let [source ((:resolve-asset-path (host session)) source)]
        (if (selected-graph-is-encrypted session)
          (if-some [encrypt (:encrypt-asset-file (host session))]
            (let* [[path _] (encrypt (:graph-id config) source)]
              (set-pending-active! session pump
                                   (File-upload (api/raw-asset-upload-request config (:uuid block) asset-type checksum path "text/plain"))
                                   (Upload-asset block) (Some path))
              (Ok (stdlib/ignore 0)))
            (Error "encrypted asset encryption is unavailable"))
          (do (set-pending-active! session pump
                                   (File-upload (api/raw-asset-upload-request config (:uuid block) asset-type checksum source
                                                                              (api/content-type-for-asset-type asset-type)))
                                   (Upload-asset block) nil)
              (Ok (stdlib/ignore 0)))))
      (tuple None None None None None)
      (let [request (match (:parent-id block)
                      (Some parent) (if (not= parent (:page-id block))
                                      (api/child-block-request config parent (:uuid block) title)
                                      (api/capture-request page-id config (:uuid block) title))
                      None (api/capture-request page-id config (:uuid block) title))]
        (set-pending-active! session pump (Json-request request) (Create-block block) nil)
        (Ok (stdlib/ignore 0)))
      _ (Error "pending block has incomplete semantic REST metadata"))))

(defn prepare-pending-creation [session pump block]
  (if (selected-graph-is-encrypted session)
    (let* [title (encrypted-title session (:config pump) (:title block))]
      (let [day (model/journal-day-for-ms (:created-at block))
            page (or (get @(:resolved-journal-pages pump) day)
                     (when-some [find (:journal-page-id (host session))] (find day)))]
        (if-some [page page]
          (prepare-pending-create-request session pump block title (Some page))
          (let [page (rpc/journal-page-uuid day) journal-title (rpc/journal-day-title day)
                encrypted-journal-title (encrypted-title session (:config pump) journal-title)
                encrypted-name (encrypted-title session (:config pump) (string/lower-case journal-title))]
            (let* [journal-title encrypted-journal-title journal-name encrypted-name]
              (set-pending-active! session pump
                                   (Json-request (api/encrypted-journal-page-request (:config pump) page journal-title journal-name day))
                                   (Create-journal (record created-journal (block block) (encrypted-title title) (page-id page) (journal-day day))) nil)
              (Ok (stdlib/ignore 0)))))))
    (prepare-pending-create-request session pump block (:title block)
                                    (when (some? (:parent-id block)) (Some (:page-id block))))))

(defn prepare-pending-block [session pump block]
  (if (contains? (:authoritative pump) (:uuid block))
    (let* [title (if (selected-graph-is-encrypted session) (encrypted-title session (:config pump) (:title block)) (Ok (:title block)))]
      (set-pending-active! session pump (Json-request (api/update-block-request (:config pump) (:uuid block) title))
                           (Update-title block) nil)
      (Ok (stdlib/ignore 0)))
    (prepare-pending-creation session pump block)))

(defn prepare-pending-next! [session pump]
  (if-some [block (first @(:remaining pump))]
    (do (swap! (:remaining pump) #(subvec % 1))
        (match (prepare-pending-block session pump block)
          (Ok _) (stdlib/ignore 0)
          (Error message)
          (do (debug (str "prepare pending block failed uuid=" (:uuid block) " message=" message))
              (mark-pending-failed! session block)
              (prepare-pending-next! session pump))))
    (do (reset! (:active pump) nil) (swap! (:state session) assoc :pending-sync nil) (stdlib/ignore 0))))

(defn activate-semantic-request [session config accepted]
  (let [s (state session)]
    (when (nil? (:semantic-active s))
      (when-some [pending (first (:semantic-queue s))]
        (when-some [prepare (:prepare-operation (host session))]
          (match (prepare (:operation pending))
            (Error message) (debug (str "semantic operation id=" (:operation-id (:operation pending))
                                        " is waiting for authoritative dependencies: " message))
            (Ok (tuple outliner-op tx))
            (let [operation (:operation pending)
                  latest (or (submission-server-t session) (:base-t operation))
                  before (if-some [accepted accepted] (max latest accepted) latest)
                  tx-id (match (:intent operation) (ops/Create-asset asset) (:uuid asset) _ (:operation-id operation))
                  request (api/tx-batch-request config before tx-id outliner-op tx)
                  next-id (inc (:next-pending-request-id s))]
              (stdlib/ignore
               (swap! (:state session) assoc :next-pending-request-id next-id
                      :semantic-queue (subvec (:semantic-queue s) 1)
                      :semantic-active (Some (record semantic-active (id next-id) (pending pending) (request request)))))))))))
  (stdlib/ignore 0))

(defn enqueue-semantic [session operation]
  (match (tuple (:stage-operation (host session)) (:prepare-operation (host session)))
    (tuple (Some stage) (Some _))
    (let* [_ (stage operation)]
      (swap! (:state session) update :semantic-queue conj (record semantic-pending (operation operation)))
      (Ok (stdlib/ignore 0)))
    _ (Error "projected graph operations are unavailable")))

(defn normalize-operation-titles [session operation]
  (let [normalizer (when-some [normalize (:graph-normalize-titles (host session))]
                     (Some (fn [uuid titles]
                             (let [[titles tags] (normalize uuid (apply list titles))]
                               (tuple (vec titles) (mapv (fn [[uuid title]] [uuid title]) tags))))))]
    (rpc/normalize-operation-titles normalizer fresh-squuid now-ms operation)))

(defn capture-operations [session uuid title now status]
  (rpc/capture-operations (projection-server-t session) uuid title now status
                          #(base-outliner-context session) (:journal-page-id (host session)) fresh-squuid
                          #(normalize-operation-titles session %)))

(defn enqueue-capture [session uuid title now status]
  (let* [operations (capture-operations session uuid title now status)]
    (reduce (fn [result operation] (let* [_ result] (enqueue-semantic session operation))) (Ok (stdlib/ignore 0)) operations)))

(defn restore-semantic-queue! [session]
  (when-some [pending (:pending-operations (host session))]
    (let [active (when-some [active (:semantic-active (state session))] (Some (:operation-id (:operation (:pending active)))))]
      (swap! (:state session) assoc :semantic-queue
             (mapv (fn [operation] (record semantic-pending (operation operation)))
                   (filter #(not= active (Some (:operation-id %))) (pending)))))))

(defn begin-pending-sync! [session config]
  (when (not (string/blank? (:token config)))
    (restore-semantic-queue! session)
    (let [pending (model/pending-blocks (:model (state session)))
          assets (filterv :is-asset pending)]
      (when (empty? assets) (activate-semantic-request session config nil))
      (let [s (state session)]
        (when (and (nil? (:semantic-active s)) (nil? (:pending-sync s)))
          (let [authoritative (set (map :uuid (or (when-some [load (:authoritative-graph-blocks (host session))] (load)) (list))))
                pump (record pending-sync (config config) (remaining (atom (if (empty? assets) pending assets)))
                             (authoritative authoritative) (resolved-journal-pages (atom {})) (active (atom nil)))]
            (swap! (:state session) assoc :pending-sync (Some pump))
            (prepare-pending-next! session pump))))))
  (stdlib/ignore 0))

(defn finish-semantic-active! [session active succeeded accepted]
  (let [next-state (cond (not succeeded) ops/Retryable
                         (some? accepted) (match accepted (Some t) (ops/Accepted t) None ops/Submitted)
                         :else ops/Submitted)]
    (when-some [stage (:stage-operation (host session))] (stage (assoc (:operation (:pending active)) :state next-state)))
    (when succeeded (when-some [accepted accepted] (record-accepted-server-t! session accepted)))
    (swap! (:state session) assoc :semantic-active nil)
    (when succeeded (when-some [config (:config (state session))] (activate-semantic-request session config accepted)))
    (stdlib/ignore 0)))

(defn cleanup-pending-active! [session active]
  (when-some [path (:cleanup-path active)] ((:cleanup-file (host session)) path)))

(defn finish-pending-block! [session pump block succeeded]
  (if succeeded
    (when (pending-block-unchanged session block) (model/mark-block-submitted (:model (state session)) (:uuid block)))
    (mark-pending-failed! session block))
  (reset! (:active pump) nil)
  (prepare-pending-next! session pump))

(defn asset-datoms-operation [session block status]
  (rpc/asset-datoms-operation (projection-server-t session) status block #(base-outliner-context session)
                              (:journal-page-id (host session))))

(defn reconcile-created-block! [session pump block remote-uuid]
  (model/reconcile-created-block (:model (state session)) (:uuid block) remote-uuid
                                 (if (pending-block-unchanged session block) "submitted" "pending"))
  (reset! (:active pump) nil)
  (prepare-pending-next! session pump))

(defn transport-operation-block [operation]
  (match operation
    (Create-block block) block (Upload-asset block) block
    (Update-title block) block (Update-status block) block
    (Move-created-asset moved) (:block moved)
    (Create-journal journal) (:block journal)))

(defn complete-pending-active! [session pump active response]
  (if-not (<= 200 (:status response) 299)
    (finish-pending-block! session pump (transport-operation-block (:operation active)) false)
    (match (:operation active)
      (Update-title block)
      (if-some [status (:status block)]
        (do (set-pending-active! session pump
                                (Json-request (api/update-block-status-request (:config pump) (:uuid block) (:uuid status)))
                                (Update-status block) nil)
            (stdlib/ignore 0))
        (finish-pending-block! session pump block true))

      (Update-status block)
      (finish-pending-block! session pump block true)

      (Create-journal journal)
      (do (swap! (:resolved-journal-pages pump) assoc (:journal-day journal) (:page-id journal))
          (reset! (:active pump) nil)
          (match (prepare-pending-create-request session pump (:block journal) (:encrypted-title journal) (Some (:page-id journal)))
            (Ok _) (stdlib/ignore 0)
            (Error message)
            (do (debug (str "prepare pending create after journal failed uuid=" (:uuid (:block journal)) " message=" message))
                (mark-pending-failed! session (:block journal))
                (prepare-pending-next! session pump))))

      (Upload-asset block)
      (match (asset-datoms-operation session block ops/Queued)
        (Error message)
        (do (debug (str "prepare asset datoms failed uuid=" (:uuid block) " message=" message))
            (finish-pending-block! session pump block false))
        (Ok operation)
        (match (enqueue-semantic session operation)
          (Error message)
          (do (debug (str "stage asset datoms failed uuid=" (:uuid block) " message=" message))
              (finish-pending-block! session pump block false))
          (Ok _)
          (do (let [queue (:semantic-queue (state session))
                    asset? (fn [pending] (= (:operation-id (:operation pending)) (:operation-id operation)))]
                (swap! (:state session) assoc :semantic-queue (into (filterv asset? queue) (remove asset? queue))))
              (finish-pending-block! session pump block true)
              (activate-semantic-request session (:config pump) nil))))

      (Create-block block)
      (match (try (Ok (api/created-block-uuid-from-body (:body response)))
                  (catch error (Error (exceptions/to-string error))))
        (Error message)
        (do (debug (str "pending creation response failed uuid=" (:uuid block) " message=" message))
            (finish-pending-block! session pump block false))
        (Ok remote)
        (match (tuple (:local-path block) (:parent-id block))
          (tuple (Some _) (Some parent))
          (do (set-pending-active! session pump (Json-request (api/move-block-request (:config pump) remote parent))
                                  (Move-created-asset (record moved-asset (block block) (remote-uuid remote))) nil)
              (stdlib/ignore 0))
          _ (reconcile-created-block! session pump block remote)))

      (Move-created-asset moved)
      (reconcile-created-block! session pump (:block moved) (:remote-uuid moved)))))

(defn accepted-transaction [body]
  (try
    (let [body (json/from-string body)]
      (match body
        (tag Assoc _)
        (let [rejected (= (json-util/member "type" body) (tag String "tx/reject"))
              accepted (match (tuple (json-util/member "acceptedT" body) (json-util/member "t" body))
                         (tuple (tag Int t) _) (Some t) (tuple _ (tag Int t)) (Some t) _ nil)]
          (tuple rejected accepted))
        _ (tuple false nil)))
    (catch _ (tuple false nil))))

(defn completion-error [input]
  (match (json-util/member "error" input)
    (tag String message) (when (not= message "") (Some message))
    _ nil))

(defn- validate-completion-id [input expected-id]
  (match input
    (tag Assoc _)
    (match (json-util/member "id" input)
      (tag Int id)
      (if (= id expected-id)
        (Ok id)
        (Error "pending sync request id does not match"))
      _ (Error "pending sync completion requires id"))
    _ (Error "pending sync completion must be an object")))

(defn parse-semantic-completion [input expected-id]
  (let* [_ (validate-completion-id input expected-id)]
    (if (some? (completion-error input))
      (Ok (tuple false nil))
      (match (json-util/member "status" input)
        (tag Int status)
        (let [[rejected accepted] (match (json-util/member "body" input)
                                    (tag String body) (accepted-transaction body)
                                    _ (tuple false nil))]
          (Ok (tuple (and (<= 200 status 299) (not rejected))
                     (if rejected nil accepted))))
        _ (Error "pending transport returned no HTTP status")))))

(defn parse-transport-completion [input expected-id]
  (let* [_ (validate-completion-id input expected-id)]
    (Ok (if-some [message (completion-error input)]
          (Error message)
          (match (json-util/member "status" input)
            (tag Int status)
            (Ok (record api/api-response
                  (status status)
                  (body (match (json-util/member "body" input) (tag String body) body _ ""))))
            _ (Error "pending transport returned no HTTP status"))))))

(defn- complete-semantic-response! [session active input]
  (try
    (let* [[succeeded accepted] (parse-semantic-completion input (:id active))]
      (finish-semantic-active! session active succeeded accepted)
      (Ok (stdlib/ignore 0)))
    (catch error (Error (str "invalid pending sync completion: " (exceptions/to-string error))))))

(defn- complete-transport-response! [session pump active input]
  (try
    (let* [response (parse-transport-completion input (:id active))]
      (cleanup-pending-active! session active)
      (match response
        (Ok response) (complete-pending-active! session pump active response)
        (Error message)
        (do (debug (str "pending transport failed id=" (:id active) " message=" message))
            (finish-pending-block! session pump (transport-operation-block (:operation active)) false)))
      (Ok (stdlib/ignore 0)))
    (catch error (Error (str "invalid pending sync completion: " (exceptions/to-string error))))))

(defn complete-pending-sync [session payload]
  (let [input (json/from-string payload)
        id (match input (tag Assoc _) (match (json-util/member "id" input) (tag Int id) (when (> id 0) (Some id)) _ nil) _ nil)
        stale? (fn [expected] (if-some [id id] (< id expected) false))
        finished? (if-some [id id] (<= id (:next-pending-request-id (state session))) false)]
    (if-some [active (:semantic-active (state session))]
      (if (stale? (:id active))
        (Ok (stdlib/ignore 0))
        (complete-semantic-response! session active input))
      (if-some [pump (:pending-sync (state session))]
        (if-some [active @(:active pump)]
          (if (stale? (:id active))
            (Ok (stdlib/ignore 0))
            (complete-transport-response! session pump active input))
          (if finished? (Ok (stdlib/ignore 0)) (Error "pending sync has no active request")))
        (if finished? (Ok (stdlib/ignore 0)) (Error "pending sync is not active"))))))

(defn cancel-pending-sync! [session]
  (when-some [active (:semantic-active (state session))]
    (swap! (:state session) update :semantic-queue #(into [(:pending active)] %))
    (swap! (:state session) assoc :semantic-active nil))
  (when-some [pump (:pending-sync (state session))]
    (when-some [active @(:active pump)] (cleanup-pending-active! session active)))
  (swap! (:state session) assoc :pending-sync nil)
  (stdlib/ignore 0))

(defn load-related [session request key]
  (let [blocks (match ((:send (host session)) request)
                 (Ok response) (if (<= 200 (:status response) 299) (vec (api/blocks-from-list-body key (:body response)))
                                   (do (debug (str "related blocks HTTP failed status=" (:status response))) []))
                 (Error message) (do (debug (str "related blocks request failed message=" message)) []))]
    (swap! (:state session) assoc :related-blocks blocks)
    (snapshot-visible session)))

(defn reset-outliner! [session]
  (swap! (:state session) assoc :outliner-state outliner/empty :outliner-optimistic-blocks nil
         :outliner-commands [] :outliner-revision (inc (:outliner-revision (state session))))
  (stdlib/ignore 0))

(defn clear-node-navigation! [session]
  (when-some [base (:node-base-state (state session))] (swap! (:state session) assoc :outliner-state base))
  (swap! (:state session) assoc :node-routes [] :node-base-state nil)
  (stdlib/ignore 0))

(defn persist-active-node-state! [session]
  (let [s (state session) routes (:node-routes s)]
    (when (not (empty? routes))
      (swap! (:state session) assoc :node-routes
             (assoc routes (dec (count routes)) (assoc (nth routes (dec (count routes))) :state (:outliner-state s))))))
  (stdlib/ignore 0))

(defn initial-node-state [session route]
  (if (:zoom-to-block route)
    (let [[state _] (outliner/update (node-route-context session route) outliner/empty (outliner/Zoom_in (:uuid route)))] state)
    outliner/empty))

(defn push-node-route! [session route]
  (persist-active-node-state! session)
  (when (empty? (:node-routes (state session)))
    (swap! (:state session) assoc :node-base-state (Some (:outliner-state (state session)))))
  (let [current (initial-node-state session route)]
    (swap! (:state session) update :node-routes conj (assoc route :state current))
    (swap! (:state session) assoc :outliner-state current :outliner-commands []
           :outliner-revision (inc (:outliner-revision (state session)))))
  (stdlib/ignore 0))

(defn pop-node-route! [session]
  (persist-active-node-state! session)
  (let [routes (:node-routes (state session))]
    (when (not (empty? routes))
      (swap! (:state session) assoc :node-routes (subvec routes 0 (dec (count routes))))
      (if-some [route (active-node-route session)]
        (swap! (:state session) assoc :outliner-state (:state route))
        (swap! (:state session) assoc :outliner-state (or (:node-base-state (state session)) outliner/empty) :node-base-state nil))
      (swap! (:state session) assoc :outliner-commands [] :outliner-revision (inc (:outliner-revision (state session))))))
  (stdlib/ignore 0))

(defn aggregate-return-context [session payload message]
  (let [s (state session)
        return? (match message outliner/Return_pressed true (outliner/Return_pressed_with_text _) true _ false)]
    (when (and (nil? (:selected-sidebar-page s)) (empty? (:node-routes s)) return?)
      (when-some [source (rpc/outliner-structure-source payload)]
        (when-some [destination (:graph-node-destination (host session))]
          (when-some [[page _] (destination source)]
            (when-some [context (page-outliner-context session (:uuid page))]
              (Some (tuple context (:uuid page))))))))))

(defn event-patch-ids [message operations]
  (match message
    (outliner/Toggle_collapsed _) nil
    _ (cond
        (= (count operations) 1)
        (match (:intent (nth operations 0))
          (ops/Save-title title) (Some [(:uuid title)])
          (ops/Set-property property) (Some [(:uuid property)])
          _ nil)
        (empty? operations)
        (match message
          (outliner/Tap_block _) (Some []) (outliner/Long_press_block _) (Some [])
          (outliner/Text_changed _) (Some []) (outliner/Caret_moved _) (Some [])
          (outliner/Choose_autocomplete _) (Some []) outliner/Save_editing (Some [])
          outliner/Cancel_editing (Some []) (outliner/Toolbar _) (Some []) _ nil)
        :else nil)))

(defn refresh-reference-metadata [session aggregate projected operations]
  (if (some #(match (:intent %) (ops/Save-title _) true (ops/Add-tag _) true _ false) operations)
    (let [live (if-some [uuid aggregate] (or (page-outliner-context session uuid) (outliner-context session))
                        (outliner-context session))
          by-id (zipmap (map :uuid (:blocks live)) (:blocks live))]
      (assoc projected :blocks
             (apply list (map (fn [block]
                                (if-some [current (get by-id (:uuid block))]
                                  (assoc block :references (:references current) :tags (:tags current)) block)) (:blocks projected)))))
    projected))

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
                    (if-some [changed (event-patch-ids message operations)]
                      (outliner-patch session projected changed)
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
            route (record node-route (uuid uuid) (is-tag tag?) (is-property property?) (page page)
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
