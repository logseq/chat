(ns logseq-chat.rpc-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [ocaml.Sys :as sys]
            [ocaml.Stdlib :as stdlib]
            [logseq-chat.rpc :as rpc]
            [logseq-chat.rpc-session :as rpc-session]
            [logseq-chat.graph-read :as graph]
            [logseq-chat.fractional-order :as fractional]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.cache-model :as model]
            [logseq-chat.api :as api]
            [logseq-chat.search-index :as search]
            [logseq-chat.outliner-effects :as effects]
            [logseq-chat.sync-session :as sync-session]
            [logseq-chat.sync-protocol :as protocol]
            [logseq-chat.entity-sync :as entity-sync]
            [logseq-chat.storage-codec :as storage]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Transit_core.Json :as transit]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [logseq-chat.outliner-state :as outliner]
            [logseq-chat.flashcards :as flashcards]))

(deftest semantic-completion-preserves-error-and-status-precedence
  (run! (fn [[wire expected]]
          (is (= expected (rpc-session/parse-semantic-completion (json/from-string wire) 1))))
        [(tuple "{\"id\":1,\"error\":\"\",\"status\":200}" (Ok (tuple true nil)))
         (tuple "{\"id\":1,\"error\":\" \"}" (Ok (tuple false nil)))
         (tuple "{\"id\":1,\"error\":false,\"status\":299}" (Ok (tuple true nil)))
         (tuple "{\"id\":1,\"status\":300}" (Ok (tuple false nil)))
         (tuple "{\"id\":1,\"error\":\"\"}" (Error "pending transport returned no HTTP status"))
         (tuple "{\"id\":2,\"error\":\"failed\"}" (Error "pending sync request id does not match"))
         (tuple "{}" (Error "pending sync completion requires id"))
         (tuple "null" (Error "pending sync completion must be an object"))]))

(deftest required-string-lists-preserve-order-and-validate-every-item
  (is (= (Ok []) (rpc/required-string-list "uuids" (json/from-string "{\"uuids\":[]}"))))
  (is (= (Ok [" b " "a" "a"])
         (rpc/required-string-list "uuids" (json/from-string "{\"uuids\":[\" b \",\"a\",\"a\"]}"))))
  (run! (fn [wire]
          (is (= (Error "field must be a list: uuids") (rpc/required-string-list "uuids" (json/from-string wire)))))
        ["{}" "{\"uuids\":null}" "{\"uuids\":1}"])
  (run! (fn [wire]
          (is (= (Error "field must be a list of non-empty strings: uuids")
                 (rpc/required-string-list "uuids" (json/from-string wire)))))
        ["{\"uuids\":[\"\"]}" "{\"uuids\":[\" \"]}" "{\"uuids\":[\"a\",null]}"]))

(deftest move-payloads-preserve-order-and-first-validation-error
  (is (= (Ok []) (rpc/required-moves (json/from-string "{\"moves\":[]}"))))
  (let [move (record ops/pending-move (uuid "a") (page-uuid "page") (parent-uuid "parent") (order "a0"))
        wire "{\"moves\":[{\"uuid\":\"a\",\"pageUuid\":\"page\",\"parentUuid\":\"parent\",\"order\":\"a0\"},{\"uuid\":\"a\",\"pageUuid\":\"page\",\"parentUuid\":\"parent\",\"order\":\"a0\"}]}"]
    (is (= (Ok [move move]) (rpc/required-moves (json/from-string wire)))))
  (run! (fn [[wire message]] (is (= (Error message) (rpc/required-moves (json/from-string wire)))))
        [(tuple "{}" "field must be a list: moves")
         (tuple "{\"moves\":[null]}" "moves must contain objects")
         (tuple "{\"moves\":[{},null]}" "missing field: uuid")
         (tuple "{\"moves\":[{\"uuid\":1,\"pageUuid\":1}]}" "field must be a string: uuid")
         (tuple "{\"moves\":[{\"uuid\":\"a\"}]}" "missing field: pageUuid")
         (tuple "{\"moves\":[{\"uuid\":\"a\",\"pageUuid\":\"p\"}]}" "missing field: parentUuid")
         (tuple "{\"moves\":[{\"uuid\":\"a\",\"pageUuid\":\"p\",\"parentUuid\":\"p\"}]}" "missing field: order")]))

(deftest status-payload-preserves-validation-and-optional-fields
  (run! (fn [[wire message]]
          (is (= (Error message) (rpc/status-payload (json/from-string wire)))))
        [(tuple "{}" "missing field: status")
         (tuple "{\"status\":null}" "missing field: status")
         (tuple "{\"status\":{}}" "missing field: uuid")
         (tuple "{\"status\":{\"uuid\":1,\"title\":1}}" "field must be a string: uuid")
         (tuple "{\"status\":{\"uuid\":\"s\"}}" "missing field: title")
         (tuple "{\"status\":{\"uuid\":\"s\",\"title\":\"Todo\",\"ident\":1}}" "field must be a string: ident")
         (tuple "{\"status\":{\"uuid\":\"s\",\"title\":\"Todo\",\"iconColor\":false}}" "field must be a string: iconColor")])
  (let [wire (json/from-string "{\"status\":{\"uuid\":\"s\",\"title\":\"Todo\",\"ident\":\"todo\",\"iconType\":\"tabler-icon\",\"iconId\":\"circle\",\"iconColor\":\"red\"}}")
        expected (record model/status (uuid "s") (title "Todo") (ident (Some "todo"))
                         (icon-type (Some "tabler-icon")) (icon-id (Some "circle")) (icon-color (Some "red")))]
    (is (= (Ok expected) (rpc/status-payload wire)))
    (is (= (Ok (Some expected)) (rpc/optional-status-payload wire))))
  (run! (fn [wire] (is (= (Ok nil) (rpc/optional-status-payload (json/from-string wire)))))
        ["{}" "{\"status\":null}"])
  (is (= (Error "missing field: uuid") (rpc/optional-status-payload (json/from-string "{\"status\":{}}")))))

(deftest status-reference-prefers-nonblank-ident-without-trimming-it
  (let [status (record model/status (uuid "s") (title "Todo") (ident nil)
                       (icon-type nil) (icon-id nil) (icon-color nil))]
    (run! (fn [ident]
            (is (= (ops/Ref-uuid "s") (rpc/status-semantic-ref (assoc status :ident (Some ident))))))
          ["" " \n\t"])
    (is (= (ops/Ref-uuid "s") (rpc/status-semantic-ref status)))
    (is (= (ops/Ref-ident " todo ") (rpc/status-semantic-ref (assoc status :ident (Some " todo ")))))))

(deftest journal-identifiers-and-titles-preserve-wire-format
  (is (= "00000001-2026-0916-0000-000000000000" (rpc/journal-page-uuid 20260916)))
  (run! (fn [[day title]] (is (= title (rpc/journal-day-title day))))
        [(tuple 20260101 "Jan 1st, 2026") (tuple 20260202 "Feb 2nd, 2026")
         (tuple 20260303 "Mar 3rd, 2026") (tuple 20260411 "Apr 11th, 2026")
         (tuple 20260512 "May 12th, 2026") (tuple 20260613 "Jun 13th, 2026")
         (tuple 20260721 "Jul 21st, 2026") (tuple 20260822 "Aug 22nd, 2026")
         (tuple 20260923 "Sep 23rd, 2026") (tuple 20261024 "Oct 24th, 2026")
         (tuple 20261130 "Nov 30th, 2026") (tuple 20261231 "Dec 31st, 2026")])
  (run! (fn [day]
          (is (try (do (rpc/journal-day-title day) false) (catch _ true))))
        [20260001 20261301]))

(deftest pending-version-compares-content-and-asset-identity
  (let [block (model/local-block "b" "Title" "page" nil 10)
        status (record model/status (uuid "s") (title "Todo") (ident nil)
                       (icon-type nil) (icon-id nil) (icon-color nil))
        tagged (assoc block :status (Some status))]
    (is (rpc/same-pending-version? block block))
    (is (rpc/same-pending-version? tagged
                                   (assoc tagged :status (Some (assoc status :title "Renamed")))))
    (run! (fn [changed] (is (not (rpc/same-pending-version? block changed))))
          [(assoc block :uuid "other") (assoc block :title "Changed")
           (assoc block :updated-at 11) tagged (assoc block :asset-size (Some 2))
           (assoc block :asset-checksum (Some "hash")) (assoc block :local-path (Some "file"))])
    (is (not (rpc/same-pending-version? tagged block)))))

(deftest structural-events-preserve-source-and-ignore-other-event-types
  (run! (fn [kind]
          (is (= (Some "b") (rpc/outliner-structure-source
                             (str "{\"type\":\"" kind "\",\"uuid\":\"b\"}")))))
        ["returnPressed" "backspacePressed"])
  (run! (fn [wire] (is (nil? (rpc/outliner-structure-source wire))))
        ["null" "[]" "{}" "{\"type\":\"returnPressed\"}"
         "{\"type\":\"returnPressed\",\"uuid\":1}"
         "{\"type\":\"textChanged\",\"uuid\":\"b\"}"]))

(deftest authoritative-reconciliation-preserves-newer-local-edits
  (let [cache (model/create nil)
        same (model/local-block "same" "Same" "page" nil 1)
        changed (model/local-block "changed" "Local" "page" nil 1)
        submitted (assoc (model/local-block "submitted" "Local" "page" nil 1)
                         :sync-status "submitted")
        missing (model/local-block "missing" "Missing" "page" nil 1)]
    (model/upsert-blocks cache [same changed submitted missing] 1)
    (rpc/reconcile-authoritative-blocks cache
                                        [same (assoc changed :title "Remote") (assoc submitted :title "Remote")])
    (run! (fn [[uuid expected]]
            (is (= (Some expected)
                   (when-some [block (model/read-block cache uuid)] (:sync-status block)))))
          [(tuple "same" "synced") (tuple "changed" "pending")
           (tuple "submitted" "synced") (tuple "missing" "pending")])))

(defn dispatch-json [session action payload]
  (json/from-string
   (rpc-session/call session
                     (json/to-string
                      (rpc/json-object
                       [(tuple "apiVersion" (tag Int 1)) (tuple "method" (tag String "dispatch"))
                        (tuple "params" (rpc/json-object
                                         [(tuple "action" (tag String action))
                                          (tuple "payload" (tag String payload))]))])))))

(defn response-result [response]
  (is (json-util/to-bool (json-util/member "ok" response)))
  (json-util/member "result" response))

(defn json-items [key value]
  (vec (json-util/to-list (json-util/member key value))))

(deftest node-navigation-preserves-independent-projections-and-editing
  (let [page (record model/entity-summary (uuid "page-1") (title "Page one"))
        block (assoc (model/local-block
                      "block-1" "Referenced block" "page-1" nil 1)
                     :parent-id (Some "page-1") :order (Some "a0")
                     :sync-status "synced" :breadcrumbs (list page))
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-node-destination (Some (fn [uuid] (cond (= uuid "block-1") (Some (tuple page true))
                                                                                                  (or (= uuid "page-1") (= uuid "tag-1")) (Some (tuple page false))
                                                                                                  :else nil)))
                                                   :graph-page-blocks (Some (fn [uuid] (when (= uuid "page-1") (Some (list block)))))
                                                   :graph-tag-pages (Some (fn [] (Some (list (record model/entity-summary
                                                                                                     (uuid "tag-1") (title "Tag one"))))))
                                                   :graph-node-is-tag (Some #(= % "tag-1"))
                                                   :graph-node-references (Some (fn [uuid] (when (= uuid "block-1") (Some (list block)))))
                                                   :graph-tag-objects (Some (fn [uuid] (when (= uuid "tag-1") (Some (list block)))))))]
    (let [result (response-result (dispatch-json session "openNode" "{\"uuid\":\"block-1\"}"))
          route (nth (json-items "nodeRoutes" result) 0)
          related (nth (json-items "relatedBlocks" route) 0)]
      (is (= (tag Null) (json-util/member "selectedPage" result)))
      (is (= (tag String "block-1") (json-util/member "uuid" route)))
      (is (= (tag String "page-1") (json-util/member "uuid" (json-util/member "page" route))))
      (is (= [(tag String "block-1")] (json-items "zoomedBlockIds" (json-util/member "outlinerState" route))))
      (is (= (tag String "block-1") (json-util/member "uuid" related)))
      (is (= 1 (count (json-items "breadcrumbs" related)))))
    (let [result (response-result (dispatch-json session "outlinerEvent" "{\"type\":\"tapBlock\",\"uuid\":\"block-1\"}"))
          route (nth (json-items "nodeRoutes" result) 0)]
      (is (= (tag Bool false) (json-util/member "isOutlinerPatch" result)))
      (is (= (tag String "block-1")
             (json-util/member "uuid" (json-util/member "editing" (json-util/member "outlinerState" route))))))
    (let [result (response-result (dispatch-json session "openNode" "{\"uuid\":\"tag-1\"}"))
          routes (json-items "nodeRoutes" result)
          route (nth routes 1)
          related (nth (json-items "relatedBlocks" route) 0)]
      (is (= 2 (count routes)))
      (is (= (tag Bool true) (json-util/member "isTag" route)))
      (is (= (tag String "block-1") (json-util/member "uuid" related)))
      (is (= 1 (count (json-items "breadcrumbs" related)))))
    (let [routes (json-items "nodeRoutes" (response-result (dispatch-json session "closeNode" "")))]
      (is (= 1 (count routes)))
      (is (= (tag String "block-1") (json-util/member "uuid" (nth routes 0)))))))

(deftest sidebar-tag-selection-projects-objects-and-linked-references
  (let [page (record model/entity-summary (uuid "tag-1") (title "Task"))
        tagged (assoc (model/local-block
                       "task-1" "Do the thing" "page-1" nil 1)
                      :parent-id (Some "page-1") :order (Some "a0") :sync-status "synced")
        linked (assoc tagged :uuid "reference-1" :title "Links Task")
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-sidebar-pages (Some (fn [] (Some (record graph/sidebar-pages
                                                                                                   (favorites [page]) (recent-pages [])))))
                                                   :graph-page-blocks (Some (fn [_] (Some (list))))
                                                   :graph-node-is-tag (Some #(= % "tag-1"))
                                                   :graph-tag-objects (Some (fn [uuid] (when (= uuid "tag-1") (Some (list tagged)))))
                                                   :graph-node-references (Some (fn [uuid] (when (= uuid "tag-1") (Some (list linked)))))))
        result (response-result (dispatch-json session "selectPage" "tag-1"))]
    (is (= (tag Bool true) (json-util/member "selectedPageIsTag" result)))
    (is (= (tag String "task-1") (json-util/member "uuid" (nth (json-items "relatedBlocks" result) 0))))
    (is (= (tag String "reference-1") (json-util/member "uuid" (nth (json-items "linkedReferenceBlocks" result) 0))))))

(deftest sidebar-page-selection-projects-references-without-node-routes
  (let [page (record model/entity-summary (uuid "page-1") (title "Page one"))
        reference (assoc (model/local-block
                          "reference-1" "Links Page one" "journal-1" nil 1)
                         :parent-id (Some "journal-1") :order (Some "a0") :sync-status "synced")
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-sidebar-pages (Some (fn [] (Some (record graph/sidebar-pages
                                                                                                   (favorites [page]) (recent-pages [])))))
                                                   :graph-page-blocks (Some (fn [_] (Some (list))))
                                                   :graph-node-references (Some (fn [uuid] (when (= uuid "page-1") (Some (list reference)))))))
        result (response-result (dispatch-json session "selectPage" "page-1"))]
    (is (= (tag Bool false) (json-util/member "selectedPageIsTag" result)))
    (is (= (tag String "reference-1") (json-util/member "uuid" (nth (json-items "relatedBlocks" result) 0))))
    (is (empty? (json-items "nodeRoutes" result)))))

(deftest search-projects-page-context-and-clears-blank-queries
  (let [page (record model/entity-summary (uuid "page-1") (title "Page one"))
        hit (record search/indexed-search-hit (uuid "block-1") (title "Search me")
                    (is-page false) (page (Some page)) (breadcrumbs [page]))
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-search (Some (fn [query] (if (= query "search") (list hit) (list))))))
        result (response-result (dispatch-json session "searchNodes" "search"))
        found (nth (json-items "searchResults" result) 0)]
    (is (= (tag String "search") (json-util/member "searchQuery" result)))
    (is (= (tag String "block-1") (json-util/member "uuid" found)))
    (is (= (tag String "Search me") (json-util/member "title" found)))
    (is (= (tag Bool false) (json-util/member "isPage" found)))
    (is (= (tag String "page-1") (json-util/member "uuid" (json-util/member "page" found))))
    (is (= 1 (count (json-items "breadcrumbs" found))))
    (is (= (tag String "Page one") (json-util/member "title" (nth (json-items "breadcrumbs" found) 0))))
    (is (empty? (json-items "searchResults" (response-result (dispatch-json session "searchNodes" "")))))))

(deftest node-navigation-resolves-projected-pages-and-blocks
  (let [page (record model/entity-summary (uuid "projected-page") (title "Projected page"))
        block (assoc (model/local-block
                      "projected-block" "Projected block" "projected-page" nil 1)
                     :parent-id (Some "projected-page") :order (Some "a0") :breadcrumbs (list page))
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-blocks (Some (fn [] (Some (list block))))
                                                   :graph-page-blocks (Some (fn [uuid] (Some (if (= uuid "projected-page") (list block) (list)))))
                                                   :graph-node-destination (Some (fn [_] nil))))]
    (rpc-session/call session "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")
    (run! (fn [[uuid zoomed]]
            (let [result (response-result (dispatch-json session "openNode" (str "{\"uuid\":\"" uuid "\"}")))
                  route (nth (json-items "nodeRoutes" result) 0)]
              (is (= (tag String uuid) (json-util/member "uuid" route)))
              (is (= (tag String "projected-page") (json-util/member "uuid" (json-util/member "page" route))))
              (is (= zoomed (json-items "zoomedBlockIds" (json-util/member "outlinerState" route))))
              (dispatch-json session "closeNode" "")))
          [(tuple "projected-page" []) (tuple "projected-block" [(tag String "projected-block")])])))

(deftest offline-node-navigation-uses-pending-projection-and-journal-title
  (let [block (assoc (model/local-block
                      "cached-block" "Cached offline block" "journal/2026-08-15" nil 1)
                     :parent-id (Some "journal/2026-08-15") :order (Some "a0")
                     :journal (Some (tuple "Aug 15th, 2026" 20260815)))
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-blocks (Some (fn [] (Some (list block))))
                                                   :graph-page-blocks (Some (fn [uuid] (Some (if (= uuid "journal/2026-08-15") (list block) (list)))))
                                                   :graph-node-destination (Some (fn [_] nil))))
        result (response-result (dispatch-json session "openNode" "{\"uuid\":\"cached-block\"}"))
        route (nth (json-items "nodeRoutes" result) 0)]
    (is (= (tag String "cached-block") (json-util/member "uuid" route)))
    (is (= (tag String "journal/2026-08-15") (json-util/member "uuid" (json-util/member "page" route))))
    (is (= (tag String "Aug 15th, 2026") (json-util/member "title" (json-util/member "page" route))))
    (is (= [(tag String "cached-block")] (json-items "zoomedBlockIds" (json-util/member "outlinerState" route))))
    (is (= (tag String "cached-block") (json-util/member "uuid" (nth (json-items "blocks" route) 0))))
    (is (= (tag String "unknown_node")
           (json-util/member "code" (json-util/member "error" (dispatch-json session "openNode" "{\"uuid\":\"missing-block\"}")))))))

(deftest loading-older-journals-expands-core-owned-window
  (let [window (atom 7)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-older-journals (Some (fn [] (swap! window + 7) (stdlib/ignore 0)))
                                                   :has-older-journals (Some (fn [] (< @window 14)))))
        initial (response-result (json/from-string (rpc-session/call session "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")))]
    (is (= (tag Bool true) (json-util/member "hasOlderJournals" initial)))
    (let [expanded (response-result (dispatch-json session "loadOlderJournals" ""))]
      (is (= (tag Bool false) (json-util/member "hasOlderJournals" expanded))))))

(deftest graph-import-forwards-payload-to-storage
  (let [imported (atom [])
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :import-snapshot (Some (fn [payload] (swap! imported conj payload) (Ok (stdlib/ignore 0))))))]
    (response-result (dispatch-json session "importSnapshot" "snapshot-payload"))
    (is (= ["snapshot-payload"] @imported))))

(deftest opening-graph-reads-authoritative-projections-once
  (let [blocks-read (atom 0)
        sidebar-read (atom 0)
        block (assoc (model/local-block
                      "restored-journal-block" "Restored from the graph snapshot" "journal-page" nil 1776000000000)
                     :parent-id (Some "journal-page") :order (Some "a0") :sync-status "synced"
                     :journal (Some (tuple "Aug 15th, 2026" 20260815)))
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :open-graph (Some (fn [_] (Ok (stdlib/ignore 0))))
                                                   :graph-blocks (Some (fn [] (swap! blocks-read inc) (Some (list block))))
                                                   :graph-sidebar-pages (Some (fn [] (swap! sidebar-read inc)
                                                                                (Some (record graph/sidebar-pages (favorites []) (recent-pages [])))))))
        result (response-result (dispatch-json session "openGraph" "{}"))
        blocks (json-items "blocks" result)]
    (is (= 1 @blocks-read))
    (is (= 1 @sidebar-read))
    (is (= 1 (count blocks)))
    (is (= (tag String "restored-journal-block") (json-util/member "uuid" (nth blocks 0))))
    (is (= (tag Int 20260815) (json-util/member "journalDay" (nth blocks 0))))))

(deftest graph-storage-errors-preserve-codes-and-payload-priority
  (let [missing (rpc-session/create-session rpc-session/default-options)
        calls (atom [])
        rejecting (rpc-session/create-session (assoc rpc-session/default-options
                                                     :import-snapshot (Some (fn [payload] (swap! calls conj payload) (Error "import rejected")))
                                                     :open-graph (Some (fn [payload] (swap! calls conj payload) (Error "open rejected")))))]
    (run! (fn [[action unavailable failed message]]
            (let [no-payload (str "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"" action "\"}}")
                  unavailable-error (json-util/member "error" (json/from-string (rpc-session/call missing no-payload)))
                  required-error (json-util/member "error" (json/from-string (rpc-session/call rejecting no-payload)))
                  service-error (json-util/member "error" (dispatch-json rejecting action "raw-payload"))]
              (is (= (tag String unavailable) (json-util/member "code" unavailable-error)))
              (is (= (tag String "invalid_params") (json-util/member "code" required-error)))
              (is (= (tag String (str action " requires a JSON payload")) (json-util/member "message" required-error)))
              (is (= (tag String failed) (json-util/member "code" service-error)))
              (is (= (tag String message) (json-util/member "message" service-error)))))
          [(tuple "importSnapshot" "snapshot_import_unavailable" "snapshot_import_failed" "import rejected")
           (tuple "openGraph" "graph_open_unavailable" "graph_open_failed" "open rejected")])
    (is (= ["raw-payload" "raw-payload"] @calls))))

(deftest graph-storage-success-can-fail-projection-validation
  (let [stored (atom [])
        projected (atom [])
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :import-snapshot (Some (fn [payload] (swap! stored conj payload) (Ok (stdlib/ignore 0))))
                                                   :open-graph (Some (fn [payload] (swap! stored conj payload) (Ok (stdlib/ignore 0))))
                                                   :model-for-graph (Some (fn [graph-id] (swap! projected conj graph-id)
                                                                            (model/create nil)))))]
    (run! (fn [action]
            (let [error (json-util/member "error" (dispatch-json session action "{}"))]
              (is (= (tag String "graph_projection_failed") (json-util/member "code" error)))
              (is (= (tag String "graph storage payload requires graphId") (json-util/member "message" error)))))
          ["importSnapshot" "openGraph"])
    (is (= ["{}" "{}"] @stored))
    (is (empty? @projected))))

(deftest websocket-lifecycle-applies-events-exactly-once
  (let [applied (atom [])
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :apply-sync-event (Some (fn [payload] (swap! applied conj payload) (Ok (stdlib/ignore 0))))))]
    (response-result (dispatch-json session "startWebSocket" ""))
    (response-result (dispatch-json session "applySyncEvent" "wire-event"))
    (response-result (dispatch-json session "stopWebSocket" ""))
    (is (= ["wire-event"] @applied))))

(deftest websocket-self-echo-clears-local-pending-capture
  (let [authoritative (atom [])
        block (assoc (model/local-block
                      "local-self-echo" "Synced capture" "journal/2026-08-15" nil 1776000000000)
                     :sync-status "synced")
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-blocks (Some (fn [] (Some (apply list @authoritative))))
                                                   :apply-sync-event (Some (fn [_] (reset! authoritative [block]) (Ok (stdlib/ignore 0))))))]
    (dispatch-json session "send" "{\"text\":\"Synced capture\",\"uuid\":\"local-self-echo\",\"now\":1776000000000}")
    (is (= 1 (count (model/pending-blocks (:model (rpc-session/state session))))))
    (response-result (dispatch-json session "applySyncEvent" "self-echo"))
    (is (empty? (model/pending-blocks (:model (rpc-session/state session)))))))

(deftest authoritative-assets-retain-cached-local-file-path
  (let [authoritative (atom [])
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-blocks (Some (fn [] (Some (apply list @authoritative))))))]
    (dispatch-json session "addAsset"
                   "{\"uuid\":\"synced-asset\",\"title\":\"photo.png\",\"now\":1776000000001,\"assetType\":\"png\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/photo.png\"}")
    (model/mark-block-synced (:model (rpc-session/state session)) "synced-asset")
    (reset! authoritative [(assoc (model/local-block
                                   "synced-asset" "photo.png" "journal/2026-08-15" nil 1776000000001)
                                  :sync-status "synced" :journal (Some (tuple "Aug 15th, 2026" 20260815)))])
    (let [blocks (json-items "blocks" (response-result (dispatch-json session "clearRelated" "")))]
      (is (= 1 (count blocks)))
      (is (= (tag String "/documents/photo.png") (json-util/member "localPath" (nth blocks 0)))))))

(deftest task-status-updates-preserve-custom-icon-color
  (let [session (rpc-session/create-session rpc-session/default-options)]
    (dispatch-json session "sendTask"
                   "{\"text\":\"Follow up\",\"uuid\":\"task-status-local\",\"now\":1776000000000,\"status\":{\"uuid\":\"todo\",\"ident\":\"logseq.property/status.todo\",\"title\":\"Todo\"}}")
    (let [result (response-result
                  (dispatch-json session "updateBlockStatus"
                                 "{\"uuid\":\"task-status-local\",\"status\":{\"uuid\":\"custom-waiting\",\"ident\":\"user.status/waiting\",\"title\":\"Waiting\",\"iconType\":\"tabler-icon\",\"iconId\":\"clock\",\"iconColor\":\"#7c3aed\"}}"))
          blocks (json-items "blocks" result)
          status (json-util/member "status" (nth blocks 0))]
      (is (= 1 (count blocks)))
      (is (= (tag String "custom-waiting") (json-util/member "uuid" status)))
      (is (= (tag String "#7c3aed") (json-util/member "color" (json-util/member "icon" status)))))))

(deftest authoritative-sync-preserves-editor-and-updates-visible-remote-block
  (let [editing (assoc (model/local-block
                        "editing-sync" "Local draft" "page" (Some "page") 1)
                       :order (Some "a0") :sync-status "synced")
        remote (assoc editing :uuid "remote-sync" :title "Before")
        authoritative (atom [editing remote])
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-blocks (Some (fn [] (Some (apply list @authoritative))))
                                                   :apply-sync-event (Some (fn [_]
                                                                             (reset! authoritative [editing (assoc remote :title "After")])
                                                                             (Ok (stdlib/ignore 0))))))]
    (dispatch-json session "outlinerEvent" "{\"type\":\"tapBlock\",\"uuid\":\"editing-sync\"}")
    (let [result (response-result (dispatch-json session "applySyncEvent" "remote-change"))
          active-editor (json-util/member "editing" (json-util/member "outlinerState" result))]
      (is (= (tag String "editing-sync") (json-util/member "uuid" active-editor)))
      (is (some (fn [row]
                  (let [block (json-util/member "block" row)]
                    (and (= (tag String "remote-sync") (json-util/member "uuid" block))
                         (= (tag String "After") (json-util/member "title" block)))))
                (json-items "outlinerRows" result))))))

(deftest journal-pagination-preserves-editor-selection-and-zoom
  (let [parent (assoc (model/local-block "parent-window" "Parent" "page" (Some "page") 1)
                      :order (Some "a0") :sync-status "synced")
        child (assoc parent :uuid "child-window" :title "Child" :parent-id (Some "parent-window"))]
    (run! (fn [event]
            (let [session (rpc-session/create-session (assoc rpc-session/default-options
                                                             :graph-blocks (Some (fn [] (Some (list parent child))))
                                                             :load-older-journals (Some (fn [] (stdlib/ignore 0)))
                                                             :has-older-journals (Some (fn [] true))))
                  before (response-result (dispatch-json session "outlinerEvent" event))
                  after (response-result (dispatch-json session "loadOlderJournals" ""))]
              (is (= (json-util/member "outlinerState" before) (json-util/member "outlinerState" after)))))
          ["{\"type\":\"tapBlock\",\"uuid\":\"child-window\"}"
           "{\"type\":\"longPressBlock\",\"uuid\":\"child-window\"}"
           "{\"type\":\"zoomIn\",\"uuid\":\"parent-window\"}"])))

(deftest outliner-editing-and-autocomplete-remain-owned-by-core
  (let [block (assoc (model/local-block "editable" "Hello" "page" (Some "page") 1)
                     :order (Some "a0") :sync-status "synced")
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-blocks (Some (fn [] (Some (list block))))))
        tapped (response-result (dispatch-json session "outlinerEvent" "{\"type\":\"tapBlock\",\"uuid\":\"editable\"}"))
        editing (json-util/member "editing" (json-util/member "outlinerState" tapped))]
    (is (= (tag String "editable") (json-util/member "uuid" editing)))
    (is (= (tag String "Hello") (json-util/member "title" editing)))
    (is (empty? (json-items "outlinerCommands" tapped)))
    (let [changed (response-result (dispatch-json session "outlinerEvent"
                                                  "{\"type\":\"textChanged\",\"title\":\"Hello [[Pro\",\"caretUTF16Offset\":11}"))
          state (json-util/member "outlinerState" changed)
          autocomplete (json-util/member "autocomplete" state)]
      (is (= (tag String "Hello [[Pro") (json-util/member "title" (json-util/member "editing" state))))
      (is (= (tag String "node") (json-util/member "kind" autocomplete)))
      (is (= (tag String "Pro") (json-util/member "query" autocomplete))))))

(deftest tag-autocomplete-candidates-use-canonical-graph-identity
  (let [tag-page (record model/entity-summary (uuid "tag-uuid") (title "Project"))
        block (assoc (model/local-block "tag-editable" "Hello" "page" (Some "page") 1)
                     :order (Some "a0") :sync-status "synced")
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-blocks (Some (fn [] (Some (list block))))
                                                   :graph-tag-pages (Some (fn [] (Some (list tag-page))))))]
    (response-result (dispatch-json session "outlinerEvent" "{\"type\":\"tapBlock\",\"uuid\":\"tag-editable\"}"))
    (let [result (response-result (dispatch-json session "outlinerEvent" "{\"type\":\"toolbar\",\"action\":\"tag\"}"))
          candidates (json-items "outlinerAutocompleteCandidates" result)]
      (is (= 1 (count candidates)))
      (is (= (tag String "Project") (json-util/member "label" (nth candidates 0))))
      (is (= (tag String "tag-uuid") (json-util/member "value" (nth candidates 0)))))))

(deftest websocket-errors-distinguish-snapshot-recovery-from-apply-failures
  (run! (fn [[message code]]
          (let [session (rpc-session/create-session (assoc rpc-session/default-options
                                                           :apply-sync-event (Some (fn [_] (Error message)))))
                error (json-util/member "error" (dispatch-json session "applySyncEvent" "remote-change"))]
            (is (= (tag String code) (json-util/member "code" error)))
            (is (= (tag String message) (json-util/member "message" error)))))
        [(tuple "sync schema mismatch" "snapshot_required")
         (tuple "snapshot required: stale cursor" "snapshot_required")
         (tuple "snapshot required:" "snapshot_required")
         (tuple "snapshot required" "websocket_apply_failed")
         (tuple " sync schema mismatch" "websocket_apply_failed")
         (tuple "offline" "websocket_apply_failed")])
  (let [wire "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"applySyncEvent\"}}"
        unavailable (rpc-session/create-session rpc-session/default-options)
        available (rpc-session/create-session (assoc rpc-session/default-options
                                                     :apply-sync-event (Some (fn [_] (Ok (stdlib/ignore 0))))))]
    (is (= (tag String "websocket_unavailable")
           (json-util/member "code" (json-util/member "error" (json/from-string (rpc-session/call unavailable wire))))))
    (is (= (tag String "invalid_params")
           (json-util/member "code" (json-util/member "error" (json/from-string (rpc-session/call available wire))))))))

(defn pending-request [response]
  (let [value (json-util/member "pendingSyncRequest" (json-util/member "result" response))]
    (match value (tag Null) nil _ (Some value))))

(def plain-graph-catalog
  "{\"graphs\":[{\"graph-id\":\"plain-1\",\"graph-name\":\"Plain\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true}]}")

(defn plain-session []
  (let [session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))))]
    (dispatch-json session "configure"
                   "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}")
    session))

(deftest pending-sync-rejects-stale-completions-and-preserves-failed-block
  (let [session (plain-session)]
    (dispatch-json session "send" "{\"text\":\"Retry later\",\"uuid\":\"failed-async\",\"now\":1776000000000}")
    (dispatch-json session "beginPendingSync" "")
    (is (not (json-util/to-bool
              (json-util/member "ok"
                                (dispatch-json session "completePendingSync"
                                               "{\"id\":99,\"status\":201,\"body\":\"{}\",\"error\":null}")))))
    (dispatch-json session "completePendingSync"
                   "{\"id\":1,\"status\":null,\"body\":null,\"error\":\"offline\"}")
    (if-some [block (model/read-block (:model (rpc-session/state session)) "failed-async")]
      (is (= "failed" (:sync-status block)))
      (is false))))

(deftest pending-sync-completions-after-cancellation-are-idempotent
  (let [session (plain-session)]
    (dispatch-json session "send" "{\"text\":\"Canceled request\",\"uuid\":\"canceled-pending\",\"now\":1776000000000}")
    (dispatch-json session "beginPendingSync" "")
    (dispatch-json session "cancelPendingSync" "")
    (is (json-util/to-bool
         (json-util/member "ok"
                           (dispatch-json session "completePendingSync"
                                          "{\"id\":1,\"status\":201,\"body\":\"{\\\"uuid\\\":\\\"canceled-pending\\\"}\",\"error\":null}"))))))

(deftest pending-sync-duplicate-completions-are-idempotent
  (let [session (plain-session)
        completion "{\"id\":1,\"status\":201,\"body\":\"{\\\"uuid\\\":\\\"duplicate-pending\\\"}\",\"error\":null}"]
    (dispatch-json session "send" "{\"text\":\"Duplicate completion\",\"uuid\":\"duplicate-pending\",\"now\":1776000000000}")
    (dispatch-json session "beginPendingSync" "")
    (dispatch-json session "completePendingSync" completion)
    (is (json-util/to-bool
         (json-util/member "ok" (dispatch-json session "completePendingSync" completion))))))

(deftest task-update-pump-submits-title-before-status
  (let [status (record model/status (uuid "todo") (title "Todo") (ident nil)
                       (icon-type nil) (icon-id nil) (icon-color nil))
        block (assoc (model/local-block "remote-task" "Old title" "journal-page" nil 1776000000000)
                     :sync-status "synced" :status (Some status))
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-graph-catalog (Some (fn [] (Some "{\"graphs\":[{\"graph-id\":\"plain-1\",\"graph-name\":\"Plain\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true}]}")))
                                                   :graph-blocks (Some (fn [] (Some (list block))))))]
    (dispatch-json session "configure" "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}")
    (model/upsert-blocks
     (:model (rpc-session/state session)) (list block) (:updated-at block))
    (dispatch-json session "updateBlock" "{\"uuid\":\"remote-task\",\"title\":\"New title\",\"status\":{\"uuid\":\"doing\",\"title\":\"Doing\"}}")
    (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (is (= "PATCH" (json-util/to-string (json-util/member "method" request))))
      (is false))
    (if-some [request (pending-request
                       (dispatch-json session "completePendingSync"
                                      "{\"id\":1,\"status\":200,\"body\":\"{}\",\"error\":null}"))]
      (do (is (= "PUT" (json-util/to-string (json-util/member "method" request))))
          (is (string/ends-with? (json-util/to-string (json-util/member "url" request)) "/properties/Status")))
      (is false))
    (is (nil? (pending-request
               (dispatch-json session "completePendingSync"
                              "{\"id\":2,\"status\":200,\"body\":\"{}\",\"error\":null}"))))
    (if-some [updated (model/read-block (:model (rpc-session/state session)) "remote-task")]
      (is (= "submitted" (:sync-status updated)))
      (is false))))

(deftest encrypted-graph-creation-provisions-uploads-and-cleans-up-in-order
  (let [created (atom false)
        provisioned (atom nil)
        events (atom [])
        uploaded-path (atom nil)
        session
        (rpc-session/create-session (assoc rpc-session/default-options
                                           :send (fn [request]
                                                   (cond
                                                     (and (= (:method_ request) "POST") (string/ends-with? (:url request) "/graphs"))
                                                     (do (swap! events conj "create")
                                                         (reset! created true)
                                                         (Ok (api/response 201 "{\"graph-id\":\"new-private\"}")))
                                                     (string/ends-with? (:url request) "/graphs")
                                                     (do (swap! events conj "discover")
                                                         (Ok (api/response 200
                                                                           (if @created
                                                                             "{\"graphs\":[{\"graph-id\":\"new-private\",\"graph-name\":\"Private notes\",\"schema-version\":\"65.33\",\"graph-e2ee?\":true,\"graph-ready-for-use?\":true}]}"
                                                                             "{\"graphs\":[]}"))))
                                                     :else (Error (str "unexpected request: " (:url request)))))
                                           :provision-graph-key (Some (fn [config]
                                                                        (swap! events conj "provision")
                                                                        (reset! provisioned (Some (:graph-id config)))
                                                                        (Ok (stdlib/ignore 0))))
                                           :encrypt-title (Some (fn [_graph-id value] (Ok (str "encrypted:" value))))
                                           :upload-file (fn [upload]
                                                          (swap! events conj "upload")
                                                          (reset! uploaded-path (Some (:file-path upload)))
                                                          (is (sys/file-exists (:file-path upload)))
                                                          (is (string/includes? (:url (:request upload)) "?"))
                                                          (is (string/ends-with? (:url (:request upload)) "checksum=0000000000000000"))
                                                          (is (= "application/transit+json" (:content-type upload)))
                                                          (Ok (api/response 200 "{\"ok\":true,\"count\":8}")))))]
    (dispatch-json session "configure" "{\"baseUrl\":\"https://api.example\",\"graphId\":\"\",\"token\":\"access\"}")
    (is (json-util/to-bool (json-util/member "ok"
                                             (dispatch-json session "createSyncGraph" "{\"name\":\"Private notes\",\"isEncrypted\":true}"))))
    (is (= (Some "new-private") @provisioned))
    (is (= ["create" "provision" "upload" "discover"] @events))
    (if-some [path @uploaded-path] (is (not (sys/file-exists path))) (is false))))

(deftest semantic-capture-pump-never-calls-blocking-transport
  (let [legacy-send-count (atom 0)
        staged (atom [])
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                   :sync-cursor (Some (fn [] (Some 91)))
                                                   :journal-page-id (Some (fn [_day] (Some "journal-page")))
                                                   :stage-operation (Some (fn [operation]
                                                                            (swap! staged
                                                                                   (fn [operations]
                                                                                     (into [operation]
                                                                                           (remove #(= (:operation-id %) (:operation-id operation)) operations))))
                                                                            (Ok (stdlib/ignore 0))))
                                                   :prepare-operation (Some (fn [operation]
                                                                              (Ok (tuple (ops/outliner-op (:intent operation)) "[]"))))
                                                   :pending-operations (Some (fn [] (apply list (reverse @staged))))
                                                   :send (fn [_request]
                                                           (swap! legacy-send-count inc)
                                                           (stdlib/failwith "asynchronous pending pump called the blocking transport"))))]
    (dispatch-json session "configure" "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}")
    (let [response (dispatch-json session "send" "{\"text\":\"First title\",\"uuid\":\"async-local\",\"now\":1776000000000}")]
      (is (json-util/to-bool (json-util/member "hasPendingSemanticOperations" (json-util/member "result" response)))))
    (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (do (is (= "POST" (json-util/to-string (json-util/member "method" request))))
          (is (= "http://127.0.0.1:8787/sync/plain-1/tx/batch"
                 (json-util/to-string (json-util/member "url" request))))
          (is (= 1 (json-util/to-int (json-util/member "id" request)))))
      (is false))
    (is (= 0 @legacy-send-count))
    (is (nil? (pending-request
               (dispatch-json session "completePendingSync"
                              "{\"id\":1,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":92}\",\"error\":null}"))))))

(deftest encrypted-task-stages-journal-before-status-and-drains-both-requests
  (let [staged (atom [])
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-graph-catalog (Some (fn [] (Some "{\"graphs\":[{\"graph-id\":\"encrypted-1\",\"graph-name\":\"Private\",\"graph-e2ee?\":true,\"graph-ready-for-use?\":true}]}")))
                                                   :graph-unlocked (Some (fn [_graph-id] true))
                                                   :sync-cursor (Some (fn [] (Some 91)))
                                                   :journal-page-id (Some (fn [_day] nil))
                                                   :stage-operation (Some (fn [operation] (swap! staged conj operation) (Ok (stdlib/ignore 0))))
                                                   :prepare-operation (Some (fn [operation]
                                                                              (Ok (tuple (ops/outliner-op (:intent operation)) "[]"))))))]
    (dispatch-json session "configure" "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"\",\"token\":\"access\"}")
    (dispatch-json session "selectGraph" "encrypted-1")
    (dispatch-json session "sendTask"
                   "{\"text\":\"Secret task\",\"uuid\":\"encrypted-async\",\"now\":1776000000000,\"status\":{\"uuid\":\"todo\",\"title\":\"Todo\"}}")
    (is (= 2 (count @staged)))
    (match (:intent (nth @staged 0))
      (ops/Create-journal journal)
      (do (is (= "encrypted-async" (:block-uuid journal)))
          (is (= "Secret task" (:title journal))))
      _ (is false))
    (match (:intent (nth @staged 1))
      (ops/Set-property property)
      (do (is (= "encrypted-async" (:uuid property)))
          (is (= "logseq.property/status" (:attr property))))
      _ (is false))
    (run! (fn [response]
            (if-some [request (pending-request response)]
              (is (= "http://127.0.0.1:8787/sync/encrypted-1/tx/batch"
                     (json-util/to-string (json-util/member "url" request))))
              (is false)))
          [(dispatch-json session "beginPendingSync" "")
           (dispatch-json session "completePendingSync"
                          "{\"id\":1,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":92}\",\"error\":null}")])
    (is (nil? (pending-request
               (dispatch-json session "completePendingSync"
                              "{\"id\":2,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":93}\",\"error\":null}"))))))

(deftest graph-creation-stops-after-initial-upload-failure
  (let [discovered (atom false)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :send (fn [request]
                                                           (cond
                                                             (and (= (:method_ request) "POST") (string/ends-with? (:url request) "/graphs"))
                                                             (Ok (api/response 201 "{\"graph-id\":\"upload-fails\"}"))
                                                             (string/ends-with? (:url request) "/graphs")
                                                             (do (reset! discovered true)
                                                                 (Ok (api/response 200 "{\"graphs\":[]}")))
                                                             :else (Error (str "unexpected request: " (:url request)))))
                                                   :upload-file (fn [_upload] (Error "offline during initial snapshot upload"))))]
    (rpc-session/call session
                      "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"configure\",\"payload\":\"{\\\"baseUrl\\\":\\\"https://api.example\\\",\\\"graphId\\\":\\\"\\\",\\\"token\\\":\\\"access\\\"}\"}}")
    (let [response (json/from-string
                    (rpc-session/call session
                                      "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"createSyncGraph\",\"payload\":\"{\\\"name\\\":\\\"Incomplete\\\",\\\"isEncrypted\\\":false}\"}}"))]
      (is (not (json-util/to-bool (json-util/member "ok" response))))
      (is (= "graph_initial_upload_failed"
             (json-util/to-string (json-util/member "code" (json-util/member "error" response))))))
    (is (not @discovered))))

(def encrypted-graph-catalog
  "{\"graphs\":[{\"graph-id\":\"encrypted-1\",\"graph-name\":\"Private\",\"graph-e2ee?\":true,\"graph-ready-for-use?\":true}]}")

(defn configure-encrypted-session [session]
  (dispatch-json session "configure"
                 "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"\",\"token\":\"access\"}"))

(defn response-error-code [response]
  (json-util/to-string (json-util/member "code" (json-util/member "error" response))))

(defn configure-plain-session [session]
  (dispatch-json session "configure"
                 "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}")
  session)

(defn synced-block [uuid title]
  (assoc (model/local-block uuid title "page" (Some "page") 1)
         :order (Some "a0") :sync-status "synced"))

(defn prepare-operation [operation]
  (Ok (tuple (ops/outliner-op (:intent operation)) "[]")))

(defn outliner-event [session payload]
  (response-result (dispatch-json session "outlinerEvent" payload)))

(deftest autosave-emits-bounded-patches-and-advances-expected-title
  (let [staged (atom [])
        projected (atom [(synced-block "bounded-save" "Before")])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 91)))
                                                    :graph-blocks (Some (fn [] (Some (apply list @projected))))
                                                    :stage-operation (Some (fn [operation]
                                                                             (swap! staged conj operation)
                                                                             (match (:intent operation)
                                                                               (ops/Save-title change)
                                                                               (swap! projected
                                                                                      (fn [blocks]
                                                                                        (mapv (fn [block]
                                                                                                (if (= (:uuid block) (:uuid change))
                                                                                                  (assoc block :title (:title change)) block)) blocks)))
                                                                               _ @projected)
                                                                             (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))]
    (outliner-event session "{\"type\":\"tapBlock\",\"uuid\":\"bounded-save\"}")
    (outliner-event session "{\"type\":\"textChanged\",\"title\":\"After\",\"caretUTF16Offset\":5}")
    (let [saved (outliner-event session "{\"type\":\"saveEditing\"}")
          blocks (json-items "blocks" saved)
          editing (json-util/member "editing" (json-util/member "outlinerState" saved))]
      (is (= (tag Bool true) (json-util/member "isOutlinerPatch" saved)))
      (is (= 1 (count blocks)))
      (is (= (tag String "After") (json-util/member "title" (nth blocks 0))))
      (is (empty? (json-items "outlinerRows" saved)))
      (is (empty? (json-items "outlinerRowSplices" saved)))
      (is (= (tag String "bounded-save") (json-util/member "uuid" editing))))
    (is (= 1 (count @staged)))
    (outliner-event session "{\"type\":\"saveEditing\"}")
    (is (= 1 (count @staged)))))

(deftest confirmed-delete-stages-one-operation-and-removes-only-selected-row
  (let [staged (atom [])
        orders (match (fractional/n-between (Some "a0") nil 100)
                 (Ok values) values
                 (Error message) (stdlib/failwith message))
        tail (mapv (fn [index order]
                     (assoc (synced-block (str "delete-tail-" index) "Unrelated") :order (Some order)))
                   (range 100) orders)
        projected (atom (into [(synced-block "selected" "Selected")] tail))
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 91)))
                                                    :graph-blocks (Some (fn [] (Some (apply list @projected))))
                                                    :stage-operation (Some (fn [operation]
                                                                             (swap! staged conj operation)
                                                                             (match (:intent operation)
                                                                               (ops/Delete-blocks change)
                                                                               (swap! projected (fn [blocks]
                                                                                                  (filterv (fn [block]
                                                                                                             (not (some #(= % (:uuid block)) (:uuids change)))) blocks)))
                                                                               _ @projected)
                                                                             (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))
        selected (outliner-event session "{\"type\":\"longPressBlock\",\"uuid\":\"selected\"}")]
    (is (= [(tag String "selected")]
           (json-items "selectedBlockIds" (json-util/member "outlinerState" selected))))
    (is (= (tag String "haptic") (json-util/member "type" (nth (json-items "outlinerCommands" selected) 0))))
    (outliner-event session "{\"type\":\"toolbar\",\"action\":\"delete\"}")
    (let [confirmed (outliner-event session "{\"type\":\"confirmDelete\"}")
          splices (json-items "outlinerRowSplices" confirmed)]
      (is (= 1 (count @staged)))
      (let [operation (nth @staged 0)]
        (is (= 91 (:base-t operation)))
        (match (:intent operation)
          (ops/Delete-blocks change) (is (= ["selected"] (:uuids change)))
          _ (is false)))
      (is (= (tag Bool true) (json-util/member "isOutlinerPatch" confirmed)))
      (is (empty? (json-items "blocks" confirmed)))
      (is (empty? (json-items "outlinerRows" confirmed)))
      (is (= [(tag String "selected")] (json-items "deletedBlockIds" confirmed)))
      (is (= 1 (count splices)))
      (is (= (tag Int 0) (json-util/member "start" (nth splices 0))))
      (is (= (tag Int 1) (json-util/member "deleteCount" (nth splices 0))))
      (is (empty? (json-items "rows" (nth splices 0))))
      (is (empty? (json-items "selectedBlockIds" (json-util/member "outlinerState" confirmed)))))))

(deftest task-status-stages-canonical-property-reference
  (let [staged (atom [])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 92)))
                                                    :graph-blocks (Some (fn [] (Some (list (synced-block "task" "Task")))))
                                                    :stage-operation (Some (fn [operation] (swap! staged conj operation) (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))]
    (outliner-event session "{\"type\":\"setTaskStatus\",\"uuid\":\"task\",\"statusIdent\":\"user.status/waiting\"}")
    (is (= 1 (count @staged)))
    (let [operation (nth @staged 0)]
      (is (= 92 (:base-t operation)))
      (match (:intent operation)
        (ops/Set-property change)
        (do (is (= "task" (:uuid change)))
            (is (= "logseq.property/status" (:attr change)))
            (is (nil? (:expected change)))
            (is (= (Some (ops/Ref-ident "user.status/waiting")) (:value change))))
        _ (is false)))))

(deftest collapse-and-zoom-replace-only-affected-row-ranges
  (let [parent (synced-block "parent" "Parent")
        child (assoc (synced-block "child" "Child") :parent-id (Some "parent"))
        sibling (assoc (synced-block "sibling" "Sibling") :order (Some "a1"))
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-blocks (Some (fn [] (Some (list child sibling parent))))))
        collapsed (outliner-event session "{\"type\":\"toggleCollapsed\",\"uuid\":\"parent\"}")
        splices (json-items "outlinerRowSplices" collapsed)]
    (is (empty? (json-items "outlinerRows" collapsed)))
    (is (= 1 (count splices)))
    (let [splice (nth splices 0)
          rows (json-items "rows" splice)]
      (is (= (tag Int 0) (json-util/member "start" splice)))
      (is (= (tag Int 2) (json-util/member "deleteCount" splice)))
      (is (= 1 (count rows)))
      (is (= (tag String "parent") (json-util/member "uuid" (json-util/member "block" (nth rows 0)))))
      (is (= (tag Bool true) (json-util/member "isCollapsed" (nth rows 0)))))
    (let [zoomed (outliner-event session "{\"type\":\"zoomIn\",\"uuid\":\"parent\"}")
          splices (json-items "outlinerRowSplices" zoomed)]
      (is (= [(tag String "parent")] (json-items "zoomedBlockIds" (json-util/member "outlinerState" zoomed))))
      (is (= 1 (count splices)))
      (is (= (tag Int 1) (json-util/member "start" (nth splices 0))))
      (is (= (tag Int 1) (json-util/member "deleteCount" (nth splices 0))))
      (is (empty? (json-items "rows" (nth splices 0)))))))

(defn queued-title-operation [operation-id title]
  (record ops/pending-operation
          (operation-id operation-id) (base-t 42) (state ops/Queued)
          (intent (ops/Save-title
                   (record ops/pending-title
                           (uuid "remote") (expected-title "Old") (title title))))))

(deftest projected-title-updates-stage-semantic-transactions
  (let [staged (atom [])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-blocks (Some (fn [] (Some (list (synced-block "remote" "Old")))))
                                                    :stage-operation (Some (fn [operation] (swap! staged conj operation) (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))]
    (response-result (dispatch-json session "updateBlock"
                                    "{\"uuid\":\"remote\",\"operationId\":\"op-title\",\"expectedTitle\":\"Old\",\"title\":\"Pending\",\"status\":null}"))
    (is (= 1 (count @staged)))
    (let [operation (nth @staged 0)]
      (is (= "op-title" (:operation-id operation)))
      (is (= 42 (:base-t operation)))
      (match (:intent operation)
        (ops/Save-title change)
        (do (is (= "remote" (:uuid change)))
            (is (= "Old" (:expected-title change)))
            (is (= "Pending" (:title change))))
        _ (is false)))
    (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (let [body (json-util/member "bodyObject" request)
            tx (nth (json-items "txs" body) 0)]
        (is (= (tag String "POST") (json-util/member "method" request)))
        (is (= (tag Int 42) (json-util/member "t-before" body)))
        (is (= (tag String "op-title") (json-util/member "tx-id" tx)))
        (is (= (tag String "save-block") (json-util/member "outliner-op" tx))))
      (is false))))

(deftest startup-restores-durable-operations-without-restaging-each-edit
  (let [stage-calls (atom 0)
        pending (mapv (fn [index]
                        (queued-title-operation (str "restored-" index) (str "Pending " index)))
                      (range 200))
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-blocks (Some (fn [] (Some (list (synced-block "remote" "Old")))))
                                                    :stage-operation (Some (fn [_] (swap! stage-calls inc) (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation)
                                                    :pending-operations (Some (fn [] (apply list pending))))))]
    (is (some? (pending-request (dispatch-json session "beginPendingSync" ""))))
    (is (= 0 @stage-calls))))

(deftest stale-queue-head-waits-for-reconciliation-before-advancing
  (let [stale (queued-title-operation "stale-head" "Stale")
        valid (queued-title-operation "valid-after-stale" "Valid")
        pending (atom [stale valid])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-blocks (Some (fn [] (Some (list (synced-block "remote" "Old")))))
                                                    :stage-operation (Some (fn [_] (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some (fn [operation]
                                                                               (if (= "stale-head" (:operation-id operation))
                                                                                 (Error "block no longer exists")
                                                                                 (prepare-operation operation))))
                                                    :pending-operations (Some (fn [] (apply list @pending))))))]
    (is (nil? (pending-request (dispatch-json session "beginPendingSync" ""))))
    (reset! pending [valid])
    (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (let [tx (nth (json-items "txs" (json-util/member "bodyObject" request)) 0)]
        (is (= (tag String "valid-after-stale") (json-util/member "tx-id" tx))))
      (is false))))

(deftest pending-sync-response-is-bounded-independently-of-page-size
  (let [pending (queued-title-operation "bounded-pending" "Pending")
        blocks (into [(synced-block "remote" "Old")]
                     (mapv (fn [index] (synced-block (str "tail-" index) (str "Tail " index)))
                           (range 500)))
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-blocks (Some (fn [] (Some (apply list blocks))))
                                                    :stage-operation (Some (fn [_] (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation)
                                                    :pending-operations (Some (fn [] (list pending))))))
        response (rpc-session/call session
                                   "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"beginPendingSync\"}}")
        result (response-result (json/from-string response))]
    (is (= (tag Bool true) (json-util/member "isPendingSyncPatch" result)))
    (is (empty? (json-items "blocks" result)))
    (is (< (count response) 5000))))

(deftest semantic-completion-persists-accepted-server-cursor
  (let [staged (atom [])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-blocks (Some (fn [] (Some (list (synced-block "remote" "Old")))))
                                                    :stage-operation (Some (fn [operation] (swap! staged conj operation) (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))]
    (dispatch-json session "updateBlock"
                   "{\"uuid\":\"remote\",\"operationId\":\"op-accepted\",\"expectedTitle\":\"Old\",\"title\":\"Pending\",\"status\":null}")
    (dispatch-json session "beginPendingSync" "")
    (dispatch-json session "completePendingSync"
                   "{\"id\":1,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":44}\",\"error\":null}")
    (let [operation (nth @staged (dec (count @staged)))]
      (is (= "op-accepted" (:operation-id operation)))
      (is (= (ops/Accepted 44) (:state operation))))))

(defn retryable-operation? [operation]
  (match (:state operation)
    ops/Queued true
    ops/Retryable true
    ops/Submitted true
    _ false))

(defn required-pending-request [session]
  (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
    request
    (stdlib/failwith "expected a pending sync request")))

(defn complete-request [session request body]
  (response-result
   (dispatch-json session "completePendingSync"
                  (json/to-string
                   (rpc/json-object [(tuple "id" (json-util/member "id" request))
                                     (tuple "status" (tag Int 200)) (tuple "body" (tag String body))
                                     (tuple "error" (tag Null))])))))

(deftest http-acceptance-advances-submission-but-not-applied-cursor
  (let [staged (atom [])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-blocks (Some (fn [] (Some (list (synced-block "remote" "Old")))))
                                                    :stage-operation (Some (fn [operation]
                                                                             (swap! staged (fn [pending]
                                                                                             (conj (filterv #(not= (:operation-id %) (:operation-id operation)) pending)
                                                                                                   operation)))
                                                                             (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation)
                                                    :pending-operations (Some (fn [] (apply list (filterv retryable-operation? @staged)))))))]
    (response-result (dispatch-json session "updateBlock"
                                    "{\"uuid\":\"remote\",\"operationId\":\"first-after-response\",\"expectedTitle\":\"Old\",\"title\":\"First\",\"status\":null}"))
    (let [completion (complete-request session (required-pending-request session)
                                       "{\"type\":\"tx/batch/ok\",\"t\":43}")]
      (is (= (tag Int 42) (json-util/member "appliedServerT" completion))))
    (response-result (dispatch-json session "updateBlock"
                                    "{\"uuid\":\"remote\",\"operationId\":\"second-after-response\",\"expectedTitle\":\"First\",\"title\":\"Second\",\"status\":null}"))
    (is (= (tag Int 43) (json-util/member "t-before" (json-util/member "bodyObject" (required-pending-request session)))))))

(deftest captures-after-acceptance-still-stage-against-authoritative-cursor
  (let [staged (atom [])
        source (synced-block "accepted-before-sse" "First")
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-blocks (Some (fn [] (Some (list source))))
                                                    :stage-operation (Some (fn [operation]
                                                                             (if (and (or (= ops/Queued (:state operation))
                                                                                          (= ops/Applied (:state operation)))
                                                                                      (not= 42 (:base-t operation)))
                                                                               (Error "operation was created against a stale server cursor")
                                                                               (do (swap! staged (fn [pending]
                                                                                                   (conj (filterv #(not= (:operation-id %) (:operation-id operation)) pending)
                                                                                                         operation)))
                                                                                   (Ok (stdlib/ignore 0))))))
                                                    :prepare-operation (Some prepare-operation)
                                                    :pending-operations (Some (fn [] (apply list (filterv retryable-operation? @staged)))))))]
    (response-result (dispatch-json session "updateBlock"
                                    "{\"uuid\":\"accepted-before-sse\",\"operationId\":\"accepted-first\",\"expectedTitle\":\"First\",\"title\":\"Updated\",\"status\":null}"))
    (complete-request session (required-pending-request session) "{\"type\":\"tx/batch/ok\",\"t\":43}")
    (run! (fn [[action payload]] (response-result (dispatch-json session action payload)))
          [(tuple "send" "{\"text\":\"After acceptance\",\"uuid\":\"capture-after-acceptance\",\"now\":1788000000000}")
           (tuple "sendTask" "{\"text\":\"Task after acceptance\",\"uuid\":\"task-after-acceptance\",\"now\":1788000000001,\"status\":{\"uuid\":\"todo\",\"ident\":\"logseq.property/status.todo\",\"title\":\"Todo\"}}")
           (tuple "addAsset" "{\"uuid\":\"2f659891-3fbc-492c-8943-9e08de2ed949\",\"title\":\"photo.jpg\",\"now\":1788000000002,\"assetType\":\"jpg\",\"assetSize\":4,\"assetChecksum\":\"abcd\",\"localPath\":\"Assets/photo.jpg\",\"targetBlockId\":\"accepted-before-sse\"}")])
    (outliner-event session "{\"type\":\"tapBlock\",\"uuid\":\"accepted-before-sse\"}")
    (outliner-event session "{\"type\":\"returnPressed\",\"uuid\":\"accepted-before-sse\"}")
    (let [operation (nth @staged (dec (count @staged)))]
      (is (= ops/Queued (:state operation)))
      (is (= 42 (:base-t operation))))))

(deftest rejected-and-offline-transactions-remain-retryable-with-stable-identity
  (run! (fn [offline?]
          (let [persisted (atom [])
                operation-id (if offline? "op-retry" "op-rejected")
                session (configure-plain-session
                         (rpc-session/create-session (assoc rpc-session/default-options
                                                            :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                            :sync-cursor (Some (fn [] (Some 42)))
                                                            :graph-blocks (Some (fn [] (Some (list (synced-block "remote" "Old")))))
                                                            :stage-operation (Some (fn [operation]
                                                                                     (swap! persisted (fn [pending]
                                                                                                        (conj (filterv #(not= (:operation-id %) (:operation-id operation)) pending)
                                                                                                              operation)))
                                                                                     (Ok (stdlib/ignore 0))))
                                                            :prepare-operation (Some prepare-operation)
                                                            :pending-operations (Some (fn [] (apply list (filterv retryable-operation? @persisted)))))))]
            (response-result (dispatch-json session "updateBlock"
                                            (str "{\"uuid\":\"remote\",\"operationId\":\"" operation-id
                                                 "\",\"expectedTitle\":\"Old\",\"title\":\"Pending\",\"status\":null}")))
            (let [request (required-pending-request session)]
              (if offline?
                (response-result
                 (dispatch-json session "completePendingSync"
                                (json/to-string (rpc/json-object
                                                 [(tuple "id" (json-util/member "id" request))
                                                  (tuple "status" (tag Null)) (tuple "body" (tag Null))
                                                  (tuple "error" (tag String "offline"))]))))
                (complete-request session request "{\"type\":\"tx/reject\",\"reason\":\"stale\",\"t\":43}")))
            (is (= 1 (count @persisted)))
            (let [operation (nth @persisted 0)]
              (is (= operation-id (:operation-id operation)))
              (is (= ops/Retryable (:state operation))))
            (let [tx (nth (json-items "txs" (json-util/member "bodyObject" (required-pending-request session))) 0)]
              (is (= (tag String operation-id) (json-util/member "tx-id" tx))))))
        [false true]))

(defn staging-session [cursor blocks staged]
  (configure-plain-session
   (rpc-session/create-session (assoc rpc-session/default-options
                                      :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                      :sync-cursor (Some (fn [] (Some cursor)))
                                      :graph-blocks (Some (fn [] (Some (apply list blocks))))
                                      :stage-operation (Some (fn [operation] (swap! staged conj operation) (Ok (stdlib/ignore 0))))
                                      :prepare-operation (Some prepare-operation)))))

(defn assert-semantic-request [session operation-id outliner-op cursor]
  (let [request (required-pending-request session)
        body (json-util/member "bodyObject" request)
        tx (nth (json-items "txs" body) 0)]
    (is (= (tag String "POST") (json-util/member "method" request)))
    (is (= (tag Int cursor) (json-util/member "t-before" body)))
    (is (= (tag String operation-id) (json-util/member "tx-id" tx)))
    (is (= (tag String outliner-op) (json-util/member "outliner-op" tx)))))

(deftest delete-block-stages-a-cursor-guarded-semantic-request
  (let [staged (atom [])
        session (staging-session 77 [(synced-block "delete-me" "Delete me")] staged)]
    (response-result (dispatch-json session "deleteBlock"
                                    "{\"uuid\":\"delete-me\",\"operationId\":\"op-delete\",\"expectedServerT\":77}"))
    (is (= 1 (count @staged)))
    (let [operation (nth @staged 0)]
      (is (= "op-delete" (:operation-id operation)))
      (is (= 77 (:base-t operation)))
      (match (:intent operation)
        (ops/Delete-blocks deletion) (is (= ["delete-me"] (:uuids deletion)))
        _ (is false)))
    (assert-semantic-request session "op-delete" "delete-blocks" 77)))

(deftest split-block-stages-one-atomic-semantic-intent
  (let [staged (atom [])
        session (staging-session 42 [(synced-block "source" "hello world")] staged)]
    (response-result (dispatch-json session "splitBlock"
                                    "{\"uuid\":\"source\",\"operationId\":\"op-split\",\"expectedServerT\":42,\"expectedTitle\":\"hello world\",\"before\":\"hello\",\"after\":\" world\",\"newUuid\":\"new\",\"newOrder\":\"a1\",\"createdAt\":100}"))
    (is (= 1 (count @staged)))
    (let [operation (nth @staged 0)]
      (is (= "op-split" (:operation-id operation)))
      (match (:intent operation)
        (ops/Split-block split)
        (do (is (= "source" (:uuid split)))
            (is (= "hello world" (:expected-title split)))
            (is (= "hello" (:before split)))
            (is (= " world" (:after split)))
            (is (= "new" (:new-uuid split)))
            (is (= "a1" (:new-order split)))
            (is (= 100 (:created-at split))))
        _ (is false)))
    (assert-semantic-request session "op-split" "split-block" 42)))

(deftest accepted-edit-immediately-releases-next-durable-operation
  (let [persisted (atom [])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-blocks (Some (fn [] (Some (list (synced-block "source" "Old")))))
                                                    :stage-operation (Some (fn [operation]
                                                                             (swap! persisted (fn [pending]
                                                                                                (conj (filterv #(not= (:operation-id %) (:operation-id operation)) pending)
                                                                                                      operation)))
                                                                             (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation)
                                                    :pending-operations (Some (fn [] (apply list (filterv retryable-operation? @persisted)))))))]
    (reset! persisted
            (mapv (fn [[operation-id expected-title title]]
                    (record ops/pending-operation
                            (operation-id operation-id) (base-t 42) (state ops/Queued)
                            (intent (ops/Save-title
                                     (record ops/pending-title
                                             (uuid "source") (expected-title expected-title) (title title))))))
                  [(tuple "first" "Old" "First") (tuple "second" "First" "Second")]))
    (let [completion (complete-request session (required-pending-request session) "{\"t\":43}")
          request (json-util/member "pendingSyncRequest" completion)
          tx (nth (json-items "txs" (json-util/member "bodyObject" request)) 0)]
      (is (= (tag String "second") (json-util/member "tx-id" tx))))))

(deftest merge-backward-stages-one-atomic-semantic-intent
  (let [staged (atom [])
        session (staging-session 43 [(synced-block "previous" "hello")
                                     (synced-block "source" " world")] staged)]
    (response-result (dispatch-json session "mergeBackward"
                                    "{\"uuid\":\"source\",\"operationId\":\"op-merge\",\"expectedServerT\":43,\"expectedTitle\":\" world\",\"title\":\" world\",\"previousUuid\":\"previous\",\"expectedPreviousTitle\":\"hello\"}"))
    (is (= 1 (count @staged)))
    (let [operation (nth @staged 0)]
      (is (= "op-merge" (:operation-id operation)))
      (match (:intent operation)
        (ops/Merge-backward merge)
        (do (is (= "source" (:uuid merge)))
            (is (= " world" (:expected-title merge)))
            (is (= " world" (:title merge)))
            (is (= "previous" (:previous-uuid merge)))
            (is (= "hello" (:expected-previous-title merge)))
            (is (nil? (:merged-title merge))))
        _ (is false)))))

(deftest move-blocks-stages-one-ordered-batch
  (let [staged (atom [])
        session (staging-session 50 [(synced-block "first" "First")
                                     (synced-block "second" "Second")] staged)]
    (response-result (dispatch-json session "moveBlocks"
                                    "{\"operationId\":\"op-move-batch\",\"expectedServerT\":50,\"moves\":[{\"uuid\":\"first\",\"pageUuid\":\"page\",\"parentUuid\":\"target\",\"order\":\"a0\"},{\"uuid\":\"second\",\"pageUuid\":\"page\",\"parentUuid\":\"target\",\"order\":\"a1\"}]}"))
    (is (= 1 (count @staged)))
    (match (:intent (nth @staged 0))
      (ops/Move-blocks batch)
      (is (= ["first" "second"] (mapv :uuid (:moves batch))))
      _ (is false))
    (assert-semantic-request session "op-move-batch" "move-blocks" 50)))

(deftest delete-blocks-stages-one-deduplicated-batch
  (let [staged (atom [])
        session (staging-session 51 [(synced-block "first" "First")
                                     (synced-block "second" "Second")] staged)]
    (response-result (dispatch-json session "deleteBlocks"
                                    "{\"operationId\":\"op-delete-batch\",\"expectedServerT\":51,\"uuids\":[\"second\",\"first\",\"first\"]}"))
    (is (= 1 (count @staged)))
    (match (:intent (nth @staged 0))
      (ops/Delete-blocks deletion) (is (= ["first" "second"] (:uuids deletion)))
      _ (is false))))

(deftest status-update-stages-a-typed-property-intent
  (let [staged (atom [])
        session (staging-session 88 [(synced-block "task" "Task")] staged)]
    (response-result (dispatch-json session "updateBlockStatus"
                                    "{\"uuid\":\"task\",\"operationId\":\"op-status\",\"expectedStatusUuid\":null,\"status\":{\"uuid\":\"doing\",\"title\":\"Doing\"}}"))
    (is (= 1 (count @staged)))
    (let [operation (nth @staged 0)]
      (is (= "op-status" (:operation-id operation)))
      (match (:intent operation)
        (ops/Set-property property)
        (do (is (= "task" (:uuid property)))
            (is (= "logseq.property/status" (:attr property)))
            (is (nil? (:expected property)))
            (is (= (Some (ops/Ref-uuid "doing")) (:value property))))
        _ (is false)))
    (assert-semantic-request session "op-status" "save-block" 88)))

(deftest delete-without-authoritative-cursor-does-not-stage
  (let [session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] nil))
                                                    :graph-blocks (Some (fn [] (Some (list (synced-block "delete-me" "Delete me")))))
                                                    :stage-operation (Some (fn [_] (stdlib/failwith "delete without cursor must not stage")))
                                                    :prepare-operation (Some prepare-operation))))
        response (dispatch-json session "deleteBlock"
                                "{\"uuid\":\"delete-me\",\"operationId\":\"op-delete\",\"expectedServerT\":77}")]
    (is (= (tag Bool false) (json-util/member "ok" response)))
    (is (= (tag String "stale_server_cursor") (json-util/member "code" (json-util/member "error" response))))))

(defn outliner-block-event [session event uuid]
  (outliner-event session
                  (json/to-string
                   (rpc/json-object
                    (cond-> [(tuple "type" (tag String event)) (tuple "uuid" (tag String uuid))]
                      (= event "backspacePressed") (conj (tuple "selectionLength" (tag Int 0))))))))

(defn editing-uuid [response]
  (json-util/to-string (json-util/member "uuid" (json-util/member "editing" (json-util/member "outlinerState" response)))))

(defn assert-bounded-structural-patch [response]
  (is (= (tag Bool true) (json-util/member "isOutlinerPatch" response)))
  (is (empty? (json-items "outlinerRows" response)))
  (is (<= (count (json-items "blocks" response)) 2))
  (let [splices (json-items "outlinerRowSplices" response)]
    (is (= 1 (count splices)))
    (is (<= (count (json-items "rows" (nth splices 0))) 2))))

(defn required-matching-item [pred items]
  (if-some [item (first (filterv pred items))]
    item
    (stdlib/failwith "missing projected item")))

(deftest offline-title-edits-remain-visible-over-authoritative-blocks
  (let [block (assoc (model/local-block
                      "offline-edit" "Server title" "journal/2026-08-15" nil 1776000000000)
                     :sync-status "synced")
        projected (atom [block])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 5)))
                                                    :graph-blocks (Some (fn [] (Some (apply list @projected))))
                                                    :stage-operation (Some (fn [operation]
                                                                             (match (:intent operation)
                                                                               (ops/Save-title change)
                                                                               (swap! projected (fn [blocks]
                                                                                                  (mapv (fn [block]
                                                                                                          (if (= (:uuid block) (:uuid change))
                                                                                                            (assoc block :title (:title change) :sync-status "pending") block)) blocks)))
                                                                               _ (stdlib/failwith "offline edit must stage Save_title"))
                                                                             (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))
        result (response-result (dispatch-json session "updateBlock"
                                               "{\"uuid\":\"offline-edit\",\"operationId\":\"offline-edit-op\",\"expectedTitle\":\"Server title\",\"title\":\"Edited offline\"}"))
        blocks (json-items "blocks" result)]
    (is (= 1 (count blocks)))
    (is (= (tag String "Edited offline") (json-util/member "title" (nth blocks 0))))
    (is (= (tag String "pending") (json-util/member "syncStatus" (nth blocks 0))))))

(deftest consecutive-structural-edits-stay-local-and-submit-in-dependency-order
  (let [orders (match (fractional/n-between (Some "a0") nil 100)
                 (Ok values) values
                 (Error message) (stdlib/failwith message))
        tail (mapv (fn [index order]
                     (assoc (synced-block (str "unrelated-" index) "Unrelated") :order (Some order)))
                   (range 100) orders)
        projected (atom (into [(synced-block "source" "Hello")] tail))
        server-t (atom 42)
        authoritative (atom #{"source"})
        prepare-calls (atom 0)
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some @server-t)))
                                                    :graph-blocks (Some (fn [] (Some (apply list @projected))))
                                                    :stage-operation (Some (fn [operation]
                                                                             (match (:intent operation)
                                                                               (ops/Split-block change)
                                                                               (swap! projected
                                                                                      (fn [blocks]
                                                                                        (let [original (required-matching-item #(= (:uuid %) (:uuid change)) blocks)]
                                                                                          (conj (mapv (fn [block]
                                                                                                        (if (= (:uuid block) (:uuid change))
                                                                                                          (assoc block :title (:before change)) block)) blocks)
                                                                                                (assoc original :uuid (:new-uuid change) :title (:after change)
                                                                                                       :order (Some (:new-order change))
                                                                                                       :created-at (:created-at change) :updated-at (:created-at change))))))
                                                                               (ops/Merge-backward change)
                                                                               (swap! projected
                                                                                      (fn [blocks]
                                                                                        (let [previous (required-matching-item #(= (:uuid %) (:previous-uuid change)) blocks)]
                                                                                          (filterv #(not= (:uuid %) (:uuid change))
                                                                                                   (mapv (fn [block]
                                                                                                           (if (= (:uuid block) (:previous-uuid change))
                                                                                                             (assoc block :title (str (:title previous) (:title change))) block)) blocks)))))
                                                                               _ @projected)
                                                                             (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some (fn [operation]
                                                                               (swap! prepare-calls inc)
                                                                               (let [ready? (match (:intent operation)
                                                                                              (ops/Split-block change) (contains? @authoritative (:uuid change))
                                                                                              (ops/Merge-backward change)
                                                                                              (and (contains? @authoritative (:uuid change))
                                                                                                   (contains? @authoritative (:previous-uuid change)))
                                                                                              _ true)]
                                                                                 (if ready? (prepare-operation operation) (Error "block no longer exists"))))))))]
    (outliner-block-event session "tapBlock" "source")
    (outliner-event session "{\"type\":\"textChanged\",\"title\":\"Hello\",\"caretUTF16Offset\":5}")
    (let [first-split (outliner-block-event session "returnPressed" "source")
          first-uuid (editing-uuid first-split)
          second-split (outliner-block-event session "returnPressed" first-uuid)
          second-uuid (editing-uuid second-split)
          merged (outliner-block-event session "backspacePressed" second-uuid)
          stale-repeat (outliner-block-event session "backspacePressed" second-uuid)
          merged-again (outliner-block-event session "backspacePressed" first-uuid)]
      (run! assert-bounded-structural-patch [first-split second-split merged merged-again])
      (is (= first-uuid (editing-uuid merged)))
      (is (= first-uuid (editing-uuid stale-repeat)))
      (is (= "source" (editing-uuid merged-again)))
      (is (= 0 @prepare-calls))
      (let [first-request (required-pending-request session)]
        (swap! authoritative conj first-uuid)
        (reset! server-t 43)
        (complete-request session first-request "{\"t\":43}"))
      (let [second-request (required-pending-request session)
            body (json-util/member "bodyObject" second-request)
            tx (nth (json-items "txs" body) 0)]
        (is (= (tag Int 43) (json-util/member "t-before" body)))
        (is (= (tag String "split-block") (json-util/member "outliner-op" tx)))
        (swap! authoritative conj second-uuid)
        (reset! server-t 44)
        (complete-request session second-request "{\"t\":44}"))
      (let [body (json-util/member "bodyObject" (required-pending-request session))
            tx (nth (json-items "txs" body) 0)]
        (is (= (tag Int 44) (json-util/member "t-before" body)))
        (is (= (tag String "merge-blocks") (json-util/member "outliner-op" tx)))))))

(deftest page-scoped-deletes-preserve-optimistic-blocks-with-a-lagging-reader
  (let [page (record model/entity-summary (uuid "page-lag") (title "Lagging page"))
        source (assoc (synced-block "page-source" "Hello") :page-id (:uuid page) :parent-id (Some (:uuid page)))
        reference (assoc (synced-block "other-page-reference" "Links lagging page")
                         :page-id "other-page" :parent-id (Some "other-page") :order (Some "a1"))
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-sidebar-pages (Some (fn [] (Some (record graph/sidebar-pages (favorites [page]) (recent-pages [])))))
                                                    :graph-page-blocks (Some (fn [uuid] (when (= uuid (:uuid page)) (Some (list source)))))
                                                    :graph-node-references (Some (fn [uuid] (when (= uuid (:uuid page)) (Some (list reference)))))
                                                    :stage-operation (Some (fn [_] (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))]
    (response-result (dispatch-json session "selectPage" "page-lag"))
    (outliner-block-event session "tapBlock" (:uuid source))
    (let [first-empty (editing-uuid (outliner-block-event session "returnPressed" (:uuid source)))
          second-empty (editing-uuid (outliner-block-event session "returnPressed" first-empty))]
      (swap! (:state session) assoc :semantic-queue [])
      (swap! (:state session) assoc :semantic-active nil)
      (let [previous (editing-uuid (outliner-block-event session "backspacePressed" second-empty))]
        (is (= first-empty previous))
        (is (= (:uuid source) (editing-uuid (outliner-block-event session "backspacePressed" previous))))))))

(defn first-node-route [response]
  (nth (json-items "nodeRoutes" response) 0))

(defn node-row-ids [response]
  (mapv (fn [row] (json-util/to-string (json-util/member "uuid" (json-util/member "block" row))))
        (json-items "outlinerRows" (first-node-route response))))

(deftest node-route-insertion-preserves-order-with-a-lagging-reader
  (let [page (record model/entity-summary (uuid "node-lag-page") (title "Node lag page"))
        source (assoc (synced-block "node-lag-source" "Hello") :page-id (:uuid page) :parent-id (Some (:uuid page)))
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-page-blocks (Some (fn [uuid] (when (= uuid (:uuid page)) (Some (list source)))))
                                                    :graph-node-destination (Some (fn [uuid] (when (= uuid (:uuid page)) (Some (tuple page false)))))
                                                    :stage-operation (Some (fn [_] (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))]
    (response-result (dispatch-json session "openNode" "{\"uuid\":\"node-lag-page\"}"))
    (outliner-block-event session "tapBlock" (:uuid source))
    (let [first-empty (editing-uuid (first-node-route (outliner-block-event session "returnPressed" (:uuid source))))
          second-empty (editing-uuid (first-node-route (outliner-block-event session "returnPressed" first-empty)))]
      (is (not= first-empty second-empty))
      (outliner-block-event session "tapBlock" (:uuid source))
      (let [inserted (editing-uuid (first-node-route (outliner-block-event session "returnPressed" (:uuid source))))
            expected (atom [(:uuid source) inserted first-empty second-empty])]
        (is (= @expected (node-row-ids (outliner-event session "{\"type\":\"caretMoved\",\"caretUTF16Offset\":0}"))))
        (run! (fn [_]
                (outliner-block-event session "tapBlock" (:uuid source))
                (let [inserted (editing-uuid (first-node-route (outliner-block-event session "returnPressed" (:uuid source))))]
                  (swap! expected (fn [ids] (into [(:uuid source) inserted] (rest ids))))
                  (is (= @expected (node-row-ids (outliner-event session "{\"type\":\"caretMoved\",\"caretUTF16Offset\":0}"))))))
              (range 20))))))

(deftest structural-patches-preserve-empty-boundaries-prefixes-and-suffixes
  (let [a (synced-block "a" "A")
        b (assoc (synced-block "b" "B") :order (Some "a1"))
        c (assoc (synced-block "c" "C") :order (Some "a2"))
        renamed (assoc b :title "Changed")]
    (run!
     (fn [[anchored before after position deleted inserted changed removed]]
       (let [session (rpc-session/create-session rpc-session/default-options)
             context (fn [blocks]
                       (record outliner/outliner-context
                               (blocks (apply list blocks)) (pages (list)) (tags (list))))
             result (response-result
                     (json/from-string
                      (rpc-session/structural-outliner-patch anchored session (context before) (:outliner-state (rpc-session/state session)) (context after))))
             splices (json-items "outlinerRowSplices" result)]
         (is (= changed (mapv #(json-util/to-string (json-util/member "uuid" %)) (json-items "blocks" result))))
         (is (= removed (mapv json-util/to-string (json-items "deletedBlockIds" result))))
         (if (and (= deleted 0) (empty? inserted))
           (is (empty? splices))
           (do
             (is (= 1 (count splices)))
             (let [splice (nth splices 0)]
               (is (= (tag Int deleted) (json-util/member "deleteCount" splice)))
               (is (= inserted (mapv #(json-util/to-string (json-util/member "uuid" (json-util/member "block" %)))
                                     (json-items "rows" splice))))
               (run! (fn [[key expected]] (is (= expected (json-util/member key splice)))) position))))))
     [(tuple true [] [] [] 0 [] [] [])
      (tuple true [] [a] [(tuple "start" (tag Int 0))] 0 ["a"] ["a"] [])
      (tuple true [a] [] [(tuple "beforeBlockId" (tag String "a"))] 1 [] [] ["a"])
      (tuple true [a c] [a b c] [(tuple "afterBlockId" (tag String "a")) (tuple "beforeBlockId" (tag String "c"))]
             0 ["b"] ["b"] [])
      (tuple true [a b c] [a c] [(tuple "afterBlockId" (tag String "a")) (tuple "beforeBlockId" (tag String "b"))]
             1 [] [] ["b"])
      (tuple false [a b c] [a renamed c] [(tuple "start" (tag Int 1))]
             1 ["b"] ["b"] [])
      (tuple true [a b] [a b c] [(tuple "afterBlockId" (tag String "b")) (tuple "beforeBlockId" (tag Null))]
             0 ["c"] ["c"] [])
      (tuple false [a] [a] [] 0 [] [] [])])))

(defn todo-status []
  (record model/status (uuid "status-todo") (title "Todo")
          (ident (Some "logseq.property/status.todo")) (icon-type nil) (icon-id nil) (icon-color nil)))

(deftest editing-status-uses-live-properties-instead-of-stale-overlay
  (let [page (record model/entity-summary (uuid "status-page") (title "Status page"))
        source (assoc (synced-block "status-source" "Task") :page-id (:uuid page) :parent-id (Some (:uuid page)))
        live-blocks (atom [source])
        staged (atom [])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-sidebar-pages (Some (fn [] (Some (record graph/sidebar-pages (favorites [page]) (recent-pages [])))))
                                                    :graph-page-blocks (Some (fn [uuid] (when (= uuid (:uuid page)) (Some (apply list @live-blocks)))))
                                                    :stage-operation (Some (fn [operation] (swap! staged conj operation) (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))]
    (response-result (dispatch-json session "selectPage" "status-page"))
    (outliner-block-event session "tapBlock" (:uuid source))
    (reset! live-blocks [(assoc source :status (Some (todo-status)))])
    (outliner-event session "{\"type\":\"setTaskStatus\",\"uuid\":\"status-source\",\"statusIdent\":\"logseq.property/status.doing\"}")
    (is (= 1 (count @staged)))
    (match (:intent (nth @staged 0))
      (ops/Set-property change)
      (is (= (Some (ops/Ref-ident "logseq.property/status.todo")) (:expected change)))
      _ (is false))))

(deftest split-block-does-not-inherit-task-or-asset-metadata
  (let [page (record model/entity-summary (uuid "task-page") (title "Task page"))
        source (assoc (synced-block "task-source" "Todo")
                      :page-id (:uuid page) :parent-id (Some (:uuid page)) :status (Some (todo-status))
                      :tags (list (record model/entity-summary (uuid "tag-card") (title "Card")))
                      :references (list (record model/entity-summary (uuid "reference") (title "Reference")))
                      :breadcrumbs (list (record model/entity-summary (uuid "ancestor") (title "Ancestor")))
                      :is-asset true :asset-type (Some "image/jpeg") :asset-size (Some 42)
                      :asset-checksum (Some "checksum") :local-path (Some "/tmp/source.jpg"))
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-sidebar-pages (Some (fn [] (Some (record graph/sidebar-pages (favorites [page]) (recent-pages [])))))
                                                    :graph-page-blocks (Some (fn [uuid] (when (= uuid (:uuid page)) (Some (list source)))))
                                                    :stage-operation (Some (fn [_] (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))]
    (response-result (dispatch-json session "selectPage" "task-page"))
    (outliner-block-event session "tapBlock" (:uuid source))
    (let [response (outliner-block-event session "returnPressed" (:uuid source))
          inserted (filterv #(not= (tag String (:uuid source)) (json-util/member "uuid" %)) (json-items "blocks" response))]
      (is (= 1 (count inserted)))
      (let [block (nth inserted 0)]
        (is (= (tag Null) (json-util/member "status" block)))
        (run! (fn [key] (is (empty? (json-items key block)))) ["tags" "references" "breadcrumbs"])
        (is (= (tag Bool false) (json-util/member "isAsset" block)))))))

(deftest journal-split-reads-one-page-and-inserts-after-source-subtree
  (let [page (record model/entity-summary (uuid "journal-today") (title "Today"))
        source (assoc (synced-block "journal-source" "Hello")
                      :page-id (:uuid page) :parent-id (Some (:uuid page)) :journal (Some (tuple "Today" 20260818)))
        child (assoc source :uuid "journal-child" :title "Child" :parent-id (Some (:uuid source)))
        orders (match (fractional/n-between (Some "a0") nil 20)
                 (Ok values) values
                 (Error message) (stdlib/failwith message))
        distant (into []
                      (mapcat (fn [journal-index]
                                (let [page-id (str "journal-" journal-index)]
                                  (mapv (fn [block-index order]
                                          (assoc (synced-block (str page-id "-block-" block-index) "Unrelated")
                                                 :page-id page-id :parent-id (Some page-id) :order (Some order)
                                                 :journal (Some (tuple page-id (+ 20260700 journal-index)))))
                                        (range 20) orders)))
                              (range 100)))
        today-blocks (atom [source child])
        full-graph-reads (atom 0)
        page-reads (atom 0)
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 42)))
                                                    :graph-blocks (Some (fn [] (swap! full-graph-reads inc) (Some (apply list (into distant @today-blocks)))))
                                                    :graph-page-blocks (Some (fn [uuid]
                                                                               (is (= (:uuid page) uuid))
                                                                               (swap! page-reads inc)
                                                                               (Some (apply list @today-blocks))))
                                                    :graph-node-destination (Some (fn [uuid] (when (= uuid (:uuid source)) (Some (tuple page true)))))
                                                    :stage-operation (Some (fn [operation]
                                                                             (match (:intent operation)
                                                                               (ops/Split-block change)
                                                                               (swap! today-blocks
                                                                                      (fn [blocks]
                                                                                        (let [original (required-matching-item #(= (:uuid %) (:uuid change)) blocks)]
                                                                                          (conj (mapv (fn [block]
                                                                                                        (if (= (:uuid block) (:uuid change))
                                                                                                          (assoc block :title (:before change)) block)) blocks)
                                                                                                (assoc original :uuid (:new-uuid change) :title (:after change)
                                                                                                       :order (Some (:new-order change))
                                                                                                       :created-at (:created-at change) :updated-at (:created-at change))))))
                                                                               _ @today-blocks)
                                                                             (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))]
    (outliner-block-event session "tapBlock" (:uuid source))
    (reset! full-graph-reads 0)
    (reset! page-reads 0)
    (let [split (outliner-event session "{\"type\":\"returnPressed\",\"uuid\":\"journal-source\",\"title\":\"Hello\",\"caretUTF16Offset\":5}")
          splices (json-items "outlinerRowSplices" split)]
      (is (= 0 @full-graph-reads))
      (is (= 1 @page-reads))
      (is (= 1 (count splices)))
      (let [splice (nth splices 0)]
        (is (= (tag String (:uuid child)) (json-util/member "afterBlockId" splice)))
        (is (= 1 (count (json-items "rows" splice))))))))

(deftest graph-switching-keeps-optimistic-models-isolated
  (let [graph-a (model/create nil)
        graph-b (model/create nil)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :open-graph (Some (fn [_] (Ok (stdlib/ignore 0))))
                                                   :model-for-graph (Some (fn [graph-id] (if (= graph-id "graph-a") graph-a graph-b)))))
        open-graph (fn [graph-id]
                     (response-result
                      (dispatch-json session "openGraph"
                                     (json/to-string
                                      (rpc/json-object
                                       [(tuple "graphId" (tag String graph-id))
                                        (tuple "activePath" (tag String (str "/graphs/" graph-id "/graph.sqlite")))
                                        (tuple "checkpointPath" (tag String (str "/graphs/" graph-id "/sync.checkpoint")))])))))]
    (open-graph "graph-a")
    (response-result
     (dispatch-json session "addAsset"
                    "{\"uuid\":\"graph-a-asset\",\"title\":\"photo.jpg\",\"now\":1,\"assetType\":\"jpg\",\"assetSize\":4,\"assetChecksum\":\"abcd\",\"localPath\":\"Assets/photo.jpg\"}"))
    (is (= 1 (count (model/pending-blocks (:model (rpc-session/state session))))))
    (open-graph "graph-b")
    (is (empty? (model/pending-blocks (:model (rpc-session/state session)))))
    (open-graph "graph-a")
    (is (= 1 (count (model/pending-blocks (:model (rpc-session/state session))))))))

(deftest collapse-finishes-editor-and-saves-title-exactly-once
  (let [staged (atom [])
        parent (synced-block "parent" "Parent")
        child (assoc (synced-block "child" "Child") :parent-id (Some "parent"))
        session (staging-session 92 [parent child] staged)]
    (outliner-block-event session "tapBlock" "parent")
    (outliner-event session "{\"type\":\"textChanged\",\"title\":\"Changed parent\",\"caretUTF16Offset\":14}")
    (let [result (outliner-block-event session "toggleCollapsed" "parent")]
      (is (= (tag Null) (json-util/member "editing" (json-util/member "outlinerState" result))))
      (is (not (empty? (json-items "outlinerRowSplices" result))))
      (is (= 1 (count @staged))))))

(deftest autocomplete-creates-page-without-saving-block-draft
  (let [staged (atom [])
        session (staging-session 92 [(synced-block "editing" "Original")] staged)]
    (outliner-block-event session "tapBlock" "editing")
    (outliner-event session "{\"type\":\"textChanged\",\"title\":\"Draft [[Novel]]\",\"caretUTF16Offset\":13}")
    (let [result (outliner-event session "{\"type\":\"chooseAutocomplete\",\"value\":\"Novel\"}")
          editing (json-util/member "editing" (json-util/member "outlinerState" result))]
      (is (= (tag String "Draft [[Novel]]") (json-util/member "title" editing)))
      (is (= 1 (count @staged)))
      (match (ops/intent-json (:intent (nth @staged 0)))
        (tag Assoc fields)
        (is (some (fn [[key value]] (and (= key "type") (= value (tag String "create-page")))) fields))
        _ (is false)))))

(defn contains-node-reference? [value]
  (match value
    (tag Assoc fields)
    (or (= (tag String "nodeReference") (json-util/member "type" value))
        (boolean (some (fn [[_ child]] (contains-node-reference? child)) fields)))
    (tag List values) (boolean (some contains-node-reference? values))
    _ false))

(deftest saved-title-immediately-renders-new-reference-metadata
  (let [live (atom (synced-block "source" "Original"))
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 92)))
                                                    :graph-blocks (Some (fn [] (Some (list @live))))
                                                    :stage-operation (Some (fn [operation]
                                                                             (match (:intent operation)
                                                                               (ops/Save-title fields)
                                                                               (reset! live (assoc @live :title (:title fields)
                                                                                                   :references (list (record model/entity-summary
                                                                                                                             (uuid "target") (title "New page")))))
                                                                               _ @live)
                                                                             (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some prepare-operation))))]
    (outliner-block-event session "tapBlock" "source")
    (outliner-event session "{\"type\":\"textChanged\",\"title\":\"See [[target]]\",\"caretUTF16Offset\":14}")
    (is (contains-node-reference? (outliner-event session "{\"type\":\"saveEditing\"}")))))

(deftest tag-completion-immediately-publishes-tag-metadata
  (run!
   (fn [selected-page?]
     (let [tag-page (record model/entity-summary (uuid "tag-uuid") (title "Project"))
           live (atom (synced-block "source" "Original"))
           session (configure-plain-session
                    (rpc-session/create-session
                     (assoc rpc-session/default-options
                            :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                            :sync-cursor (Some (fn [] (Some 92)))
                            :graph-blocks (Some (fn [] (Some (list @live))))
                            :graph-page-blocks (Some (fn [_] (Some (list @live))))
                            :graph-tag-pages (Some (fn [] (Some (list tag-page))))
                            :stage-operation
                            (Some (fn [operation]
                                    (match (:intent operation)
                                      (ops/Add-tag value)
                                      (do (is (= "tag-uuid" (:tag-uuid value)))
                                          (swap! live assoc :tags (list tag-page)))
                                      _ @live)
                                    (Ok (stdlib/ignore 0))))
                            :prepare-operation (Some prepare-operation))))]
       (when selected-page?
         (swap! (:state session) assoc :selected-sidebar-page
                (Some (record model/entity-summary (uuid (:page-id @live)) (title "Page")))))
       (outliner-block-event session "tapBlock" "source")
       (outliner-event session "{\"type\":\"textChanged\",\"title\":\"Original #Pro\",\"caretUTF16Offset\":13}")
       (let [result (outliner-event session "{\"type\":\"chooseAutocomplete\",\"value\":\"tag-uuid\"}")
             blocks (json-items "blocks" result)]
         (is (= 1 (count blocks)))
         (when (= 1 (count blocks))
           (let [tags (json-items "tags" (nth blocks 0))]
             (is (= 1 (count tags)))
             (when (= 1 (count tags))
               (is (= (tag String "tag-uuid") (json-util/member "uuid" (nth tags 0)))))))
         (is (= (tag String "Original")
                (json-util/member "title" (json-util/member "editing" (json-util/member "outlinerState" result))))))
       (outliner-event session "{\"type\":\"toolbar\",\"action\":\"hideKeyboard\"}")
       (is (= (list tag-page) (:tags (first (:blocks (rpc-session/outliner-context session))))))))
   [false true]))

(defn asset-replay-uuid [index]
  (str "00000000-0000-4000-8000-00000000000" index))

(defn asset-replay-change [before accepted]
  (record protocol/sync-change-set
          (format-version 1) (graph-id "plain-1") (schema-version "65.33")
          (t-before before) (t accepted)
          (upserts
           (apply list
                  (mapv (fn [index]
                          (let [uuid (asset-replay-uuid index)]
                            (record protocol/sync-entity
                                    (id (transit/Array (list (transit/Keyword "block/uuid") (transit/Uuid uuid))))
                                    (attrs (list (tuple (transit/Keyword "block/uuid") (transit/Uuid uuid))
                                                 (tuple (transit/Keyword "block/title") (transit/String "photo.jpg")))))))
                        (range (- before 41) (- accepted 41)))))
          (deleted (list)) (operation-ids (list))))

(defn replay-assets [session before accepted]
  (response-result
   (dispatch-json session "applySyncEvent"
                  (json/to-string (rpc/json-object [(tuple "before" (tag Int before))
                                                    (tuple "t" (tag Int accepted))])))))

(deftest asset-acknowledgements-preserve-applied-cursor-across-replay-timings
  (run!
   (fn [timing]
     (let [state (sync-session/create-state "plain-1" "65.33" 42)
           schema (assoc storage/default-schema-attr :value-type (Some (ds/UuidType))
                         :unique (Some (ds/Identity)) :indexed true)
           conn (ds/create-conn :schema (list (tuple "block/uuid" schema)))
           applied (atom 0)
           session (configure-plain-session
                    (rpc-session/create-session (assoc rpc-session/default-options
                                                       :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                       :sync-cursor (Some (fn [] (Some (sync-session/applied-server-t state))))
                                                       :graph-blocks (Some (fn [] (Some (list))))
                                                       :journal-page-id (Some (fn [_] (Some "journal-page")))
                                                       :stage-operation (Some (fn [_] (Ok (stdlib/ignore 0))))
                                                       :prepare-operation (Some prepare-operation)
                                                       :apply-sync-event (Some (fn [payload]
                                                                                 (let [input (json/from-string payload)
                                                                                       change (asset-replay-change
                                                                                               (json-util/to-int (json-util/member "before" input))
                                                                                               (json-util/to-int (json-util/member "t" input)))]
                                                                                   (match (sync-session/apply-validated-change-set
                                                                                           state change
                                                                                           (fn [change]
                                                                                             (match (entity-sync/apply-change-set #(Ok %) conn change)
                                                                                               (Error message) (Error message)
                                                                                               (Ok _) (do (swap! applied inc) (Ok (stdlib/ignore 0))))))
                                                                                     (Ok _) (Ok (stdlib/ignore 0))
                                                                                     (Error _) (Error "sync cursor mismatch"))))))))]
       (run! (fn [index]
               (response-result
                (dispatch-json session "addAsset"
                               (json/to-string
                                (rpc/json-object
                                 [(tuple "uuid" (tag String (asset-replay-uuid index)))
                                  (tuple "title" (tag String "photo.jpg")) (tuple "now" (tag Int (+ 1788000000000 index)))
                                  (tuple "assetType" (tag String "jpg")) (tuple "assetSize" (tag Int 4))
                                  (tuple "assetChecksum" (tag String "abcd"))
                                  (tuple "localPath" (tag String "Assets/photo.jpg"))])))))
             [1 2 3])
       (run! (fn [index]
               (let [upload (required-pending-request session)]
                 (is (= (tag String "PUT") (json-util/member "method" upload)))
                 (let [transaction (json-util/member "pendingSyncRequest"
                                                     (complete-request session upload "{\"ok\":true}"))
                       before (sync-session/applied-server-t state)
                       accepted (+ 42 index)]
                   (when (= timing :replay-first) (replay-assets session before accepted))
                   (let [completion (complete-request session transaction
                                                      (json/to-string
                                                       (rpc/json-object [(tuple "type" (tag String "tx/batch/ok"))
                                                                         (tuple "t" (tag Int accepted))])))
                         visible (json-util/to-int (json-util/member "appliedServerT" completion))
                         snapshot (response-result (dispatch-json session "startWebSocket" ""))
                         cursor (json-util/to-int (json-util/member "appliedServerT" snapshot))]
                     (is (= (sync-session/applied-server-t state) visible))
                     (is (= visible cursor))
                     (when (= timing :ack-first) (replay-assets session cursor accepted))))))
             [1 2 3])
       (when (= timing :deferred) (replay-assets session 42 45))
       (is (= (if (= timing :deferred) 1 3) @applied))
       (is (= 45 (sync-session/applied-server-t state)))
       (is (= 3 (count (db-api/datoms (ds/conn-db conn) (ds/Aevt) :a "block/uuid"))))))
   [:ack-first :replay-first :deferred]))

(deftest late-http-acknowledgement-cannot-rewind-transport-cursor
  (let [session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :sync-cursor (Some (fn [] (Some 60)))
                                                    :prepare-operation (Some prepare-operation))))
        operation (assoc (queued-title-operation "late-ack" "New") :base-t 60)]
    (swap! (:state session) assoc :semantic-queue [(record rpc-session/semantic-pending (operation operation))])
    (match (:config (rpc-session/state session))
      (Some config) (rpc-session/activate-semantic-request session config (Some 43))
      None (stdlib/failwith "expected configured session"))
    (match (:semantic-active (rpc-session/state session))
      (Some active)
      (match (:body (:request active))
        (Some body) (is (= (tag Int 60) (json-util/member "t-before" (json/from-string body))))
        None (is false))
      None (is false))))

(deftest targeted-assets-appear-immediately-in-selected-page-projection
  (let [page (record model/entity-summary (uuid "selected-page") (title "Selected page"))
        parent (assoc (model/local-block
                       "page-parent" "Parent" "selected-page" nil 1)
                      :parent-id (Some "selected-page") :order (Some "a0") :sync-status "synced")
        projected (atom [parent])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 5)))
                                                    :graph-sidebar-pages (Some (fn [] (Some (record graph/sidebar-pages
                                                                                                    (favorites [page]) (recent-pages [])))))
                                                    :graph-page-blocks (Some (fn [uuid] (Some (if (= uuid "selected-page") (apply list @projected) (list)))))
                                                    :stage-operation (Some (fn [operation]
                                                                             (match (:intent operation)
                                                                               (ops/Create-asset asset)
                                                                               (swap! projected conj
                                                                                      (assoc (model/local-block
                                                                                              (:uuid asset) (:title asset) (:page-uuid asset) (Some (:parent-uuid asset)) (:created-at asset))
                                                                                             :order (Some (:order asset)) :is-asset true
                                                                                             :asset-type (Some (:asset-type asset)) :asset-size (Some (:asset-size asset))
                                                                                             :asset-checksum (Some (:asset-checksum asset))))
                                                                               _ (stdlib/failwith "asset projection must stage Create_asset"))
                                                                             (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some (fn [operation]
                                                                               (Ok (tuple (ops/outliner-op (:intent operation)) "[]")))))))]
    (response-result (dispatch-json session "selectPage" "selected-page"))
    (let [result (response-result
                  (dispatch-json session "addAsset"
                                 "{\"uuid\":\"visible-asset\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"page-parent\"}"))]
      (is (some #(= (tag String "visible-asset") (json-util/member "uuid" (json-util/member "block" %)))
                (json-items "outlinerRows" result))))))

(deftest task-and-asset-capture-return-optimistic-blocks
  (run! (fn [[action payload uuid]]
          (let [result (response-result (dispatch-json (rpc-session/create-session rpc-session/default-options) action payload))
                blocks (json-items "blocks" result)]
            (is (= (tag String uuid) (json-util/member "uuid" (nth blocks 0))))))
        [(tuple "sendTask"
                "{\"text\":\"Follow up\",\"uuid\":\"task-local\",\"now\":1776000000000,\"status\":{\"uuid\":\"status-waiting\",\"ident\":\"user.status/waiting\",\"title\":\"Waiting\",\"iconType\":\"tabler-icon\",\"iconId\":\"clock\"}}"
                "task-local")
         (tuple "addAsset"
                "{\"uuid\":\"asset-local\",\"title\":\"photo.jpg\",\"now\":1776000000001,\"assetType\":\"jpg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/photo.jpg\"}"
                "asset-local")]))

(deftest targeted-assets-retain-parent-and-page-from-cached-block
  (let [session (rpc-session/create-session rpc-session/default-options)
        target (assoc (model/local-block
                       "editing-block" "Editing" "target-page" nil 1)
                      :parent-id (Some "target-page") :sync-status "synced")]
    (model/upsert-blocks (:model (rpc-session/state session)) (list target) 1)
    (dispatch-json session "addAsset"
                   "{\"uuid\":\"targeted-asset\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}")
    (if-some [asset (model/read-block (:model (rpc-session/state session)) "targeted-asset")]
      (do (is (= "target-page" (:page-id asset)))
          (is (= (Some "editing-block") (:parent-id asset))))
      (is false))))

(deftest targeted-asset-upload-uses-stable-block-uuid
  (let [target (assoc (model/local-block
                       "editing-block" "Editing" "local-page" nil 1)
                      :parent-id (Some "local-page") :sync-status "synced")
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :graph-blocks (Some (fn [] (Some (list target)))))))]
    (dispatch-json session "addAsset"
                   "{\"uuid\":\"targeted-upload\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}")
    (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (is (= (tag String "http://127.0.0.1:8787/assets/plain-1/targeted-upload.m4a") (json-util/member "url" request)))
      (is false))))

(deftest shared-images-insert-bounded-row-patches-and-normalize-upload-type
  (let [session (configure-plain-session (rpc-session/create-session (assoc rpc-session/default-options
                                                                            :load-graph-catalog (Some (fn [] (Some plain-graph-catalog))))))
        result (response-result
                (dispatch-json session "addAsset"
                               "{\"uuid\":\"shared-image\",\"title\":\"IMG_0002\",\"now\":2,\"assetType\":\"image/jpeg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"Assets/shared-IMG_0002.JPG\"}"))
        splices (json-items "outlinerRowSplices" result)
        rows (json-items "rows" (nth splices 0))]
    (is (= (tag Bool true) (json-util/member "isOutlinerPatch" result)))
    (is (= 1 (count splices)))
    (is (= 1 (count rows)))
    (is (= (tag String "shared-image") (json-util/member "uuid" (json-util/member "block" (nth rows 0)))))
    (if-some [asset (model/read-block (:model (rpc-session/state session)) "shared-image")]
      (is (= (Some "jpeg") (:asset-type asset)))
      (is false))
    (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (do (is (= (tag String "http://127.0.0.1:8787/assets/plain-1/shared-image.jpeg") (json-util/member "url" request)))
          (is (= (tag String "image/jpeg") (json-util/member "contentType" request))))
      (is false))))

(deftest pending-assets-wait-for-authentication-and-resume-after-configuration
  (let [session (rpc-session/create-session rpc-session/default-options)]
    (dispatch-json session "configure" "{\"baseUrl\":\"https://api.example\",\"graphId\":\"plain-1\",\"token\":\"\"}")
    (dispatch-json session "addAsset"
                   "{\"uuid\":\"offline-shared-image\",\"title\":\"IMG_0002.JPG\",\"now\":2,\"assetType\":\"image/jpeg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"Assets/shared-IMG_0002.JPG\"}")
    (is (nil? (pending-request (dispatch-json session "beginPendingSync" ""))))
    (configure-plain-session session)
    (is (some? (pending-request (dispatch-json session "beginPendingSync" ""))))))

(deftest asset-payload-errors-do-not-create-local-blocks
  (let [session (rpc-session/create-session rpc-session/default-options)]
    (run! (fn [payload]
            (let [error (json-util/member "error" (dispatch-json session "addAsset" payload))]
              (is (= (tag String "invalid_params") (json-util/member "code" error)))
              (is (= (tag String "addAsset requires complete file metadata") (json-util/member "message" error)))))
          ["{}"
           "{\"uuid\":\"bad\",\"title\":\"Photo\",\"assetType\":\"png\",\"assetChecksum\":\"hash\",\"localPath\":\"file\"}"
           "{\"uuid\":\"bad\",\"title\":\"Photo\",\"assetType\":\"png\",\"assetSize\":null,\"assetChecksum\":\"hash\",\"localPath\":\"file\"}"
           "{\"uuid\":\"bad\",\"title\":\"Photo\",\"assetType\":\"png\",\"assetSize\":\"12\",\"assetChecksum\":\"hash\",\"localPath\":\"file\"}"
           "{\"uuid\":\"bad\",\"title\":\"Photo\",\"assetType\":\"png\",\"assetSize\":12,\"assetChecksum\":\"hash\",\"localPath\":\"file\",\"now\":false}"
           "{\"uuid\":\"bad\",\"title\":\"Photo\",\"assetType\":\"png\",\"assetSize\":12,\"assetChecksum\":\"hash\",\"localPath\":\"file\",\"targetBlockId\":3}"])
    (is (nil? (model/read-block (:model (rpc-session/state session)) "bad")))
    (run! (fn [[payload code message]]
            (let [error (json-util/member "error" (dispatch-json session "addAsset" payload))]
              (is (= (tag String code) (json-util/member "code" error)))
              (is (= (tag String message) (json-util/member "message" error)))))
          [(tuple "[]" "invalid_params" "addAsset payload must be an object")
           (tuple "{" "invalid_json" "addAsset payload must be valid JSON")])
    (let [error (json-util/member "error" (json/from-string (rpc-session/call session
                                                                              "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"addAsset\"}}")))]
      (is (= (tag String "invalid_params") (json-util/member "code" error)))
      (is (= (tag String "addAsset requires a JSON payload") (json-util/member "message" error))))))

(deftest asset-staging-errors-preserve-cached-file-and-error-category
  (run! (fn [[cursor code message]]
          (let [staged (atom 0)
                session (configure-plain-session
                         (rpc-session/create-session (assoc rpc-session/default-options
                                                            :sync-cursor (Some (fn [] cursor))
                                                            :journal-page-id (Some (fn [_] (Some "journal")))
                                                            :stage-operation (Some (fn [_] (swap! staged inc) (Error "stage rejected"))))))
                error (json-util/member "error"
                                        (dispatch-json session "addAsset"
                                                       "{\"uuid\":\"staged-asset\",\"title\":\"Photo\",\"now\":1776000000000,\"assetType\":\"png\",\"assetSize\":12,\"assetChecksum\":\"hash\",\"localPath\":\"/local/photo.png\"}"))]
            (is (= (tag String code) (json-util/member "code" error)))
            (is (= (tag String message) (json-util/member "message" error)))
            (is (= (if (some? cursor) 1 0) @staged))
            (if-some [asset (model/read-block (:model (rpc-session/state session)) "staged-asset")]
              (is (= (Some "/local/photo.png") (:local-path asset)))
              (is false))))
        [(tuple nil "asset_projection_failed" "A current server cursor is required")
         (tuple (Some 7) "stage_operation_failed" "stage rejected")]))

(deftest asset-workflow-captures-view-before-caching-and-loads-stage-afterward
  (let [cache (model/create nil)
        events (atom [])
        parent (model/local-block "parent" "Parent" "page" nil 1)
        result (rpc/add-asset
                (Some "{\"uuid\":\"asset\",\"title\":\"Photo\",\"now\":2,\"assetType\":\"image/png\",\"assetSize\":12,\"assetChecksum\":\"hash\",\"localPath\":\"/photo.png\",\"targetBlockId\":\"parent\"}")
                cache (fn [] 2)
                (fn [uuid] (swap! events conj "target") (is (= "parent" uuid)) (Some parent))
                (fn []
                  (swap! events conj "view")
                  (is (nil? (model/read-block cache "asset")))
                  (fn [] (swap! events conj "complete") "done"))
                (fn [asset] (swap! events conj "prepare") (is (= "asset" (:uuid asset))) (Ok "operation"))
                (fn []
                  (swap! events conj "load-stage")
                  (is (some? (model/read-block cache "asset")))
                  (Some (fn [operation] (swap! events conj "stage")
                          (is (= "operation" operation)) (Ok (stdlib/ignore 0))))))]
    (is (= "done" result))
    (is (= ["view" "target" "load-stage" "prepare" "stage" "complete"] @events))
    (if-some [asset (model/read-block cache "asset")]
      (do (is (= "page" (:page-id asset)))
          (is (= (Some "parent") (:parent-id asset)))
          (is (= (Some "png") (:asset-type asset))))
      (is false))))

(deftest local-insertions-share-projection-with-journals-nodes-and-editor
  (run! (fn [[capture? page-id parent-id uuid]]
          (let [page (record model/entity-summary (uuid page-id) (title "Aug 23rd, 2026"))
                journal (if capture? (Some (tuple "Aug 23rd, 2026" 20260823)) nil)
                parent (assoc (model/local-block
                               parent-id "Parent" page-id (Some page-id) 1)
                              :sync-status "synced" :order (Some "a0") :journal journal)
                projected (atom [parent])
                staged (atom [])
                session (configure-plain-session
                         (rpc-session/create-session (assoc rpc-session/default-options
                                                            :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                            :sync-cursor (Some (fn [] (Some 5)))
                                                            :journal-page-id (Some (fn [_] (Some page-id)))
                                                            :graph-blocks (Some (fn [] (Some (apply list @projected))))
                                                            :graph-page-blocks (Some (fn [id] (Some (apply list (filter #(= (:page-id %) id) @projected)))))
                                                            :graph-node-destination (Some (fn [id] (when (= id page-id) (Some (tuple page false)))))
                                                            :stage-operation (Some (fn [operation]
                                                                                     (match (:intent operation)
                                                                                       (ops/Insert-block value)
                                                                                       (do
                                                                                         (swap! staged conj (tuple (:uuid value) (:page-uuid value) (:parent-uuid value)))
                                                                                         (swap! projected conj
                                                                                                (assoc (model/local-block
                                                                                                        (:uuid value) (:title value) (:page-uuid value)
                                                                                                        (Some (:parent-uuid value)) (:created-at value))
                                                                                                       :order (Some (:order value)) :journal journal)))
                                                                                       _ (stdlib/failwith "local insertion must stage Insert_block"))
                                                                                     (Ok (stdlib/ignore 0))))
                                                            :prepare-operation (Some (fn [operation]
                                                                                       (Ok (tuple (ops/outliner-op (:intent operation)) "[]")))))))
                result (response-result
                        (if capture?
                          (dispatch-json session "send" "{\"text\":\"hello\",\"uuid\":\"local-hello\",\"now\":1787469000000}")
                          (dispatch-json session "addChildBlock" "{\"uuid\":\"local-child\",\"title\":\"Child\",\"parentId\":\"child-parent\",\"now\":10}")))]
            (is (= [(tuple uuid page-id (if capture? page-id parent-id))] @staged))
            (is (some #(= (tag String uuid) (json-util/member "uuid" %)) (json-items "blocks" result)))
            (when capture?
              (let [opened (response-result (dispatch-json session "openNode" "{\"uuid\":\"journal-page\"}"))
                    route (nth (json-items "nodeRoutes" opened) 0)]
                (is (some #(= (tag String uuid) (json-util/member "uuid" %)) (json-items "blocks" route))))
              (let [tapped (response-result (dispatch-json session "outlinerEvent" "{\"type\":\"tapBlock\",\"uuid\":\"local-hello\"}"))
                    route (nth (json-items "nodeRoutes" tapped) 0)
                    editing (json-util/member "editing" (json-util/member "outlinerState" route))]
                (is (= (tag String uuid) (json-util/member "uuid" editing)))))))
        [(tuple true "journal-page" "world" "local-hello")
         (tuple false "child-page" "child-parent" "local-child")]))

(deftest graph-projection-does-not-leak-legacy-cache-blocks
  (let [projected (assoc (model/local-block
                          "projected-only" "Projected" "page" (Some "page") 1)
                         :sync-status "synced" :order (Some "a0"))
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                   :graph-blocks (Some (fn [] (Some (list projected))))))]
    (model/cache-local-message (:model (rpc-session/state session)) "legacy-only" "Must not leak" 10)
    (configure-plain-session session)
    (let [result (response-result (dispatch-json session "configure"
                                                 "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}"))]
      (is (not (some #(= (tag String "legacy-only") (json-util/member "uuid" %)) (json-items "blocks" result)))))))

(deftest child-insertion-validates-fields-before-loading-cursor
  (let [reads (atom 0)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :sync-cursor (Some (fn [] (swap! reads inc) nil))))]
    (reset! reads 0)
    (run! (fn [[payload message]]
            (let [error (json-util/member "error" (dispatch-json session "addChildBlock" payload))]
              (is (= (tag String "invalid_params") (json-util/member "code" error)))
              (is (= (tag String message) (json-util/member "message" error)))))
          [(tuple "{}" "missing field: uuid")
           (tuple "{\"uuid\":1}" "field must be a string: uuid")
           (tuple "{\"uuid\":\"child\"}" "missing field: title")
           (tuple "{\"uuid\":\"child\",\"title\":\"Child\"}" "missing field: parentId")
           (tuple "{\"uuid\":\"child\",\"title\":\"Child\",\"parentId\":false}" "field must be a string: parentId")
           (tuple "{\"uuid\":\"child\",\"title\":\"Child\",\"parentId\":\"parent\",\"now\":false}" "field must be an integer: now")
           (tuple "[]" "addChildBlock payload must be an object")])
    (is (= 0 @reads))
    (is (= "invalid_json" (response-error-code (dispatch-json session "addChildBlock" "{"))))))

(deftest child-insertion-without-graph-writes-through-local-parent
  (let [session (rpc-session/create-session rpc-session/default-options)
        parent (model/local-block "parent" "Parent" "local-page" nil 1)]
    (model/upsert-blocks (:model (rpc-session/state session)) (list parent) 1)
    (response-result (dispatch-json session "addChildBlock" "{\"uuid\":\"child\",\"title\":\"Child\",\"parentId\":\"parent\",\"now\":10}"))
    (if-some [child (model/read-block (:model (rpc-session/state session)) "child")]
      (do (is (= "local-page" (:page-id child)))
          (is (= (Some "parent") (:parent-id child)))
          (is (= 10 (:created-at child))))
      (is false))
    (let [error (json-util/member "error" (dispatch-json session "addChildBlock"
                                                         "{\"uuid\":\"orphan\",\"title\":\"Child\",\"parentId\":\"missing\",\"now\":10}"))]
      (is (= (tag String "invalid_params") (json-util/member "code" error)))
      (is (= (tag String "unknown parent block: missing") (json-util/member "message" error))))))

(deftest child-insertion-preserves-cursor-parent-and-staging-errors
  (run! (fn [[cursor parent? code message]]
          (let [parent (model/local-block "parent" "Parent" "page" nil 1)
                session (configure-plain-session
                         (rpc-session/create-session (assoc rpc-session/default-options
                                                            :sync-cursor (Some (fn [] cursor))
                                                            :graph-blocks (Some (fn [] (Some (if parent? (list parent) (list)))))
                                                            :stage-operation (Some (fn [_] (Error "stage rejected")))
                                                            :prepare-operation (Some (fn [_] (Ok (tuple "insert" "[]")))))))
                error (json-util/member "error" (dispatch-json session "addChildBlock"
                                                               "{\"uuid\":\"child\",\"title\":\"Child\",\"parentId\":\"parent\",\"now\":10}"))]
            (is (= (tag String code) (json-util/member "code" error)))
            (is (= (tag String message) (json-util/member "message" error)))))
        [(tuple nil true "invalid_params" "A current server cursor is required")
         (tuple (Some 7) false "invalid_params" "parent block is unavailable")
         (tuple (Some 7) true "stage_operation_failed" "stage rejected")]))

(deftest child-operation-orders-only-within-the-parent-page
  (let [parent (model/local-block "parent" "Parent" "page" nil 1)
        sibling (assoc parent :uuid "sibling" :parent-id (Some "parent") :order (Some "a2"))
        earlier (assoc sibling :uuid "earlier" :order (Some "a0"))
        other-page (assoc sibling :uuid "other-page" :page-id "elsewhere" :order (Some "zZ"))
        other-parent (assoc sibling :uuid "other-parent" :parent-id (Some "elsewhere") :order (Some "zZ"))
        unordered (assoc sibling :uuid "unordered" :order nil)
        context (record outliner/outliner-context
                        (blocks (list parent sibling earlier other-page other-parent unordered))
                        (pages (list)) (tags (list)))
        ids (atom 0)
        fresh-id (fn [] (swap! ids inc) "operation")]
    (match (rpc/child-operation 7 context "child" "Child" "parent" 10 fresh-id)
      (Ok operation)
      (do (is (= "operation" (:operation-id operation)))
          (is (= 7 (:base-t operation)))
          (is (= ops/Queued (:state operation)))
          (match (:intent operation)
            (ops/Insert-block child)
            (do (is (= "child" (:uuid child))) (is (= "Child" (:title child)))
                (is (= "page" (:page-uuid child))) (is (= "parent" (:parent-uuid child)))
                (is (= "a3" (:order child))) (is (= 10 (:created-at child))))
            _ (is false)))
      _ (is false))
    (is (= (Error "parent block is unavailable")
           (rpc/child-operation 7 context "child" "Child" "missing" 10 fresh-id)))
    (is (= 1 @ids))))

(deftest plain-assets-project-before-upload-and-queue-stable-datom-transactions
  (let [uuid "2f659891-3fbc-492c-8943-9e08de2ed949"
        staged (atom [])
        target (assoc (model/local-block
                       "editing-block" "Editing" "target-page" (Some "target-page") 1)
                      :order (Some "a0") :sync-status "synced")
        projected (atom [target])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 41)))
                                                    :graph-blocks (Some (fn [] (Some (apply list @projected))))
                                                    :authoritative-graph-blocks (Some (fn [] (Some (list target))))
                                                    :journal-page-id (Some (fn [_] (Some "journal-page")))
                                                    :stage-operation (Some (fn [operation]
                                                                             (swap! staged conj operation)
                                                                             (match (:intent operation)
                                                                               (ops/Create-asset asset)
                                                                               (reset! projected
                                                                                       [target (assoc (model/local-block
                                                                                                       (:uuid asset) (:title asset) "page" (Some "page") 1)
                                                                                                      :is-asset true :order (Some "a0") :sync-status "synced")])
                                                                               _ @projected)
                                                                             (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some (fn [operation]
                                                                               (Ok (tuple (ops/outliner-op (:intent operation)) "[]")))))))]
    (dispatch-json session "addAsset"
                   (str "{\"uuid\":\"" uuid "\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}"))
    (is (= 1 (count @staged)))
    (let [operation (nth @staged 0)]
      (match (:intent operation)
        (ops/Create-asset asset) (is (= uuid (:uuid asset)))
        _ (is false))
      (is (= ops/Applied (:state operation))))
    (if-some [upload (pending-request (dispatch-json session "beginPendingSync" ""))]
      (do (is (= (tag String "PUT") (json-util/member "method" upload)))
          (is (= (tag String (str "http://127.0.0.1:8787/assets/plain-1/" uuid ".m4a")) (json-util/member "url" upload))))
      (is false))
    (if-some [request (pending-request (dispatch-json session "completePendingSync"
                                                      "{\"id\":1,\"status\":200,\"body\":\"{\\\"ok\\\":true}\",\"error\":null}"))]
      (let [transactions (json-items "txs" (json-util/member "bodyObject" request))]
        (is (= (tag String "http://127.0.0.1:8787/sync/plain-1/tx/batch") (json-util/member "url" request)))
        (is (= 1 (count transactions)))
        (is (= (tag String uuid) (json-util/member "tx-id" (nth transactions 0)))))
      (is false))
    (is (= 2 (count @staged)))
    (let [operation (nth @staged 1)]
      (match (:intent operation)
        (ops/Create-asset asset)
        (do (is (= uuid (:uuid asset))) (is (= "target-page" (:page-uuid asset)))
            (is (= "editing-block" (:parent-uuid asset))) (is (not= "" (:order asset))))
        _ (is false))
      (is (= ops/Queued (:state operation))))))

(deftest failed-raw-uploads-retry-without-queuing-datoms
  (let [staged (atom [])
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :sync-cursor (Some (fn [] (Some 41)))
                                                    :journal-page-id (Some (fn [_] (Some "journal-page")))
                                                    :stage-operation (Some (fn [operation] (swap! staged conj operation) (Ok (stdlib/ignore 0))))
                                                    :prepare-operation (Some (fn [operation]
                                                                               (Ok (tuple (ops/outliner-op (:intent operation)) "[]")))))))]
    (dispatch-json session "addAsset"
                   "{\"uuid\":\"retry-asset\",\"title\":\"photo.png\",\"now\":2,\"assetType\":\"png\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/photo.png\"}")
    (if-some [first-request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (do
        (dispatch-json session "completePendingSync" "{\"id\":1,\"status\":null,\"body\":null,\"error\":\"offline\"}")
        (is (= 1 (count @staged)))
        (let [operation (nth @staged 0)]
          (match (:intent operation)
            (ops/Create-asset asset) (is (= "retry-asset" (:uuid asset)))
            _ (is false))
          (is (= ops/Applied (:state operation))))
        (if-some [retry (pending-request (dispatch-json session "beginPendingSync" ""))]
          (is (= (json-util/member "url" first-request) (json-util/member "url" retry)))
          (is false)))
      (is false))))

(deftest encrypted-capture-stages-persistent-insert-and-uses-datom-endpoint
  (let [staged (atom [])
        existing (assoc (model/local-block
                         "existing-journal-block" "Existing" "journal-page" (Some "journal-page") 1)
                        :order (Some "a0") :sync-status "synced")
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-graph-catalog (Some (fn [] (Some encrypted-graph-catalog)))
                                                   :graph-unlocked (Some (fn [_] true))
                                                   :sync-cursor (Some (fn [] (Some 91)))
                                                   :graph-blocks (Some (fn [] (Some (list existing))))
                                                   :journal-page-id (Some (fn [_] (Some "journal-page")))
                                                   :stage-operation (Some (fn [operation] (swap! staged conj operation) (Ok (stdlib/ignore 0))))
                                                   :prepare-operation (Some (fn [operation]
                                                                              (Ok (tuple (ops/outliner-op (:intent operation)) "[]"))))))]
    (configure-encrypted-session session)
    (dispatch-json session "selectGraph" "encrypted-1")
    (dispatch-json session "send" "{\"text\":\"Encrypted capture\",\"uuid\":\"encrypted-capture\",\"now\":1776000000000}")
    (is (= 1 (count @staged)))
    (match (:intent (nth @staged 0))
      (ops/Insert-block block)
      (do (is (= "encrypted-capture" (:uuid block))) (is (= "Encrypted capture" (:title block)))
          (is (= "journal-page" (:page-uuid block))) (is (= "journal-page" (:parent-uuid block)))
          (is (> (compare (:order block) "a0") 0)))
      _ (is false))
    (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (is (= (tag String "http://127.0.0.1:8787/sync/encrypted-1/tx/batch") (json-util/member "url" request)))
      (is false))))

(deftest page-favorite-updates-sidebar-and-preserves-operation-fields
  (let [favorite (atom false)
        calls (atom [])
        page (record model/entity-summary (uuid "page-favorite") (title "Favorite me"))
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :graph-sidebar-pages (Some (fn [] (Some (record graph/sidebar-pages
                                                                                                    (favorites (if @favorite [page] [])) (recent-pages [page])))))
                                                    :graph-set-page-favorite (Some (fn [page-uuid value operation-id now]
                                                                                     (swap! calls conj (tuple page-uuid value operation-id now))
                                                                                     (reset! favorite value)
                                                                                     (Ok (stdlib/ignore 0)))))))]
    (let [response (dispatch-json session "setPageFavorite"
                                  "{\"pageUuid\":\"page-favorite\",\"favorite\":true,\"operationId\":\"favorite-op\",\"now\":100}")]
      (is (json-util/to-bool (json-util/member "ok" response)))
      (is (= 1 (count (json-util/to-list (json-util/member "favorites" (json-util/member "result" response)))))))
    (dispatch-json session "setPageFavorite"
                   "{\"pageUuid\":\"page-favorite\",\"favorite\":false,\"operationId\":\"unfavorite-op\",\"now\":100}")
    (is (= [(tuple "page-favorite" true "favorite-op" 100)
            (tuple "page-favorite" false "unfavorite-op" 100)] @calls))))

(deftest page-deletion-updates-sidebar-and-preserves-operation-fields
  (let [deleted (atom [])
        page (record model/entity-summary (uuid "page-delete") (title "Delete me"))
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :graph-sidebar-pages (Some (fn [] (Some (record graph/sidebar-pages
                                                                                                    (favorites []) (recent-pages (if (empty? @deleted) [page] []))))))
                                                    :graph-delete-page (Some (fn [page-uuid operation-id now]
                                                                               (swap! deleted conj (tuple page-uuid operation-id now))
                                                                               (Ok (stdlib/ignore 0)))))))
        response (dispatch-json session "deletePage"
                                "{\"pageUuid\":\"page-delete\",\"operationId\":\"delete-page-op\",\"now\":100}")]
    (is (json-util/to-bool (json-util/member "ok" response)))
    (is (empty? (json-util/to-list (json-util/member "recentPages" (json-util/member "result" response)))))
    (is (= [(tuple "page-delete" "delete-page-op" 100)] @deleted))))

(deftest flashcard-review-removes-due-card-and-preserves-operation-fields
  (let [now 1776000000000
        reviewed (atom [])
        due-card (record flashcards/due-card
                         (block (model/local-block
                                 "flashcard" "Question {{cloze answer}}" "page" nil now))
                         (children (list)) (card (flashcards/new-card now)))
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                    :graph-due-flashcards (Some (fn [_] (if (empty? @reviewed) (list due-card) (list))))
                                                    :graph-review-flashcard (Some (fn [uuid rating at operation-id]
                                                                                    (swap! reviewed conj (tuple uuid rating at operation-id))
                                                                                    (Ok (stdlib/ignore 0)))))))]
    (dispatch-json session "loadFlashcards" "1776000000000")
    (let [response (dispatch-json session "reviewFlashcard"
                                  "{\"uuid\":\"flashcard\",\"rating\":\"good\",\"now\":1776000000000,\"operationId\":\"review-op\"}")]
      (is (json-util/to-bool (json-util/member "ok" response)))
      (is (empty? (json-util/to-list (json-util/member "flashcards" (json-util/member "result" response))))))
    (is (= [(tuple "flashcard" flashcards/Good now "review-op")] @reviewed))))

(deftest page-and-review-actions-validate-before-calling-services
  (let [calls (atom 0)
        session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :graph-set-page-favorite (Some (fn [_ _ _ _] (swap! calls inc) (Ok (stdlib/ignore 0))))
                                                    :graph-delete-page (Some (fn [_ _ _] (swap! calls inc) (Ok (stdlib/ignore 0))))
                                                    :graph-review-flashcard (Some (fn [_ _ _ _] (swap! calls inc) (Ok (stdlib/ignore 0)))))))]
    (run! (fn [[action wire message]]
            (let [response (dispatch-json session action wire)]
              (is (= "invalid_params" (response-error-code response)))
              (is (= message (json-util/to-string (json-util/member "message" (json-util/member "error" response)))))))
          [(tuple "setPageFavorite" "{}" "missing field: pageUuid")
           (tuple "setPageFavorite" "{\"pageUuid\":1,\"favorite\":1}" "field must be a string: pageUuid")
           (tuple "setPageFavorite" "{\"pageUuid\":\"p\"}" "missing field: favorite")
           (tuple "setPageFavorite" "{\"pageUuid\":\"p\",\"favorite\":null}" "field must be a boolean: favorite")
           (tuple "setPageFavorite" "{\"pageUuid\":\"p\",\"favorite\":true}" "missing field: operationId")
           (tuple "setPageFavorite" "{\"pageUuid\":\"p\",\"favorite\":true,\"operationId\":\"op\",\"now\":false}" "field must be an integer: now")
           (tuple "deletePage" "{}" "missing field: pageUuid")
           (tuple "deletePage" "{\"pageUuid\":\"p\"}" "missing field: operationId")
           (tuple "deletePage" "{\"pageUuid\":\"p\",\"operationId\":\"op\",\"now\":false}" "field must be an integer: now")
           (tuple "reviewFlashcard" "{}" "missing field: uuid")
           (tuple "reviewFlashcard" "{\"uuid\":\"c\"}" "missing field: rating")
           (tuple "reviewFlashcard" "{\"uuid\":\"c\",\"rating\":\"bad\",\"now\":false}" "field must be an integer: now")
           (tuple "reviewFlashcard" "{\"uuid\":\"c\",\"rating\":\"bad\"}" "missing field: operationId")
           (tuple "reviewFlashcard" "{\"uuid\":\"c\",\"rating\":\"bad\",\"operationId\":\"op\"}" "rating must be again, hard, good, or easy")])
    (run! (fn [action]
            (is (= "invalid_json" (response-error-code (dispatch-json session action "{"))))
            (is (= "invalid_params" (response-error-code (dispatch-json session action "[]")))))
          ["setPageFavorite" "deletePage" "reviewFlashcard"])
    (is (= 0 @calls))))

(deftest page-and-review-actions-preserve-service-errors
  (let [session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :graph-set-page-favorite (Some (fn [_ _ _ _] (Error "favorite rejected")))
                                                    :graph-delete-page (Some (fn [_ _ _] (Error "delete rejected")))
                                                    :graph-review-flashcard (Some (fn [_ _ _ _] (Error "review rejected"))))))]
    (run! (fn [[action wire code message]]
            (let [response (dispatch-json session action wire)]
              (is (= code (response-error-code response)))
              (is (= message (json-util/to-string (json-util/member "message" (json-util/member "error" response)))))))
          [(tuple "setPageFavorite" "{\"pageUuid\":\"p\",\"favorite\":true,\"operationId\":\"op\"}" "set_page_favorite_failed" "favorite rejected")
           (tuple "deletePage" "{\"pageUuid\":\"p\",\"operationId\":\"op\"}" "delete_page_failed" "delete rejected")
           (tuple "reviewFlashcard" "{\"uuid\":\"c\",\"rating\":\"good\",\"operationId\":\"op\"}" "flashcard_review_failed" "review rejected")]))
  (let [session (rpc-session/create-session rpc-session/default-options)]
    (run! (fn [[action code]]
            (is (= code (response-error-code (dispatch-json session action "{}")))))
          [(tuple "setPageFavorite" "set_page_favorite_unavailable")
           (tuple "deletePage" "delete_page_unavailable")
           (tuple "reviewFlashcard" "flashcards_unavailable")])))

(deftest page-and-review-actions-preserve-precondition-priority
  (let [calls (atom 0)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-set-page-favorite (Some (fn [_ _ _ _] (swap! calls inc) (Ok (stdlib/ignore 0))))
                                                   :graph-delete-page (Some (fn [_ _ _] (swap! calls inc) (Ok (stdlib/ignore 0))))))]
    (run! (fn [action]
            (is (= "graph_not_configured" (response-error-code (dispatch-json session action "{")))))
          ["setPageFavorite" "deletePage"])
    (run! (fn [action]
            (let [response (json/from-string
                            (rpc-session/call session
                                              (json/to-string
                                               (rpc/json-object
                                                [(tuple "apiVersion" (tag Int 1)) (tuple "method" (tag String "dispatch"))
                                                 (tuple "params" (rpc/json-object [(tuple "action" (tag String action))]))]))))]
              (is (= "invalid_params" (response-error-code response)))
              (is (= (str action " requires a payload")
                     (json-util/to-string (json-util/member "message" (json-util/member "error" response)))))))
          ["setPageFavorite" "deletePage" "reviewFlashcard"])
    (is (= 0 @calls))))

(deftest page-service-exceptions-are-not-reclassified-as-payload-json-errors
  (let [session (configure-plain-session
                 (rpc-session/create-session (assoc rpc-session/default-options
                                                    :graph-delete-page (Some (fn [_ _ _] (throw (Failure "service crashed")))))))
        response (dispatch-json session "deletePage" "{\"pageUuid\":\"p\",\"operationId\":\"op\"}")]
    (is (= "invalid_json" (response-error-code response)))
    (is (= "request must be valid JSON"
           (json-util/to-string (json-util/member "message" (json-util/member "error" response)))))))

(def remote-feed
  "{\"blocks\":[{\"uuid\":\"remote\",\"title\":\"Remote text\",\"page-id\":\"journal\",\"parent-id\":\"journal\",\"created-at\":10,\"updated-at\":20}],\"journals\":[{\"uuid\":\"journal\",\"title\":\"Today\",\"journal-day\":20260916}]}")

(defn refresh-session [send]
  (let [session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-graph-catalog (Some (fn [] (Some plain-graph-catalog)))
                                                   :send send))]
    (dispatch-json session "configure" "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}")
    session))

(deftest refresh-caches-blocks-journals-and-statuses-in-request-order
  (let [requests (atom [])
        session (refresh-session
                 (fn [request]
                   (swap! requests conj (:url request))
                   (is (= "GET" (:method_ request)))
                   (is (= "access" (:token request)))
                   (Ok (api/response 200
                                     (if (= 1 (count @requests)) remote-feed
                                         "{\"choices\":[{\"uuid\":\"todo\",\"title\":\"Todo\",\"ident\":\"logseq.property/status.todo\"}]}")))))
        response (dispatch-json session "refresh" "")]
    (is (json-util/to-bool (json-util/member "ok" response)))
    (is (= 2 (count @requests)))
    (is (string/includes? (nth @requests 0) "/blocks?journal-only=true&journal-day-at-most="))
    (is (string/ends-with? (nth @requests 1) "/search?q=Status&types=properties&limit=100"))
    (if-some [block (model/read-block (:model (rpc-session/state session)) "remote")]
      (do (is (= "Remote text" (:title block)))
          (is (= "synced" (:sync-status block)))
          (is (= 20 (:updated-at block))))
      (is false))
    (is (= (Some (tuple "Today" 20260916))
           (model/journal-metadata (:model (rpc-session/state session)) "journal")))
    (is (= ["todo"] (mapv :uuid (model/all-statuses (:model (rpc-session/state session))))))))

(deftest refresh-stops-before-status-request-when-blocks-request-fails
  (run! (fn [transport-failure?]
          (let [requests (atom 0)
                session (refresh-session
                         (fn [_]
                           (swap! requests inc)
                           (if transport-failure? (Error "offline")
                               (Ok (api/response 503 "bad gateway")))))
                response (dispatch-json session "refresh" "")]
            (is (= "remote_refresh_failed" (response-error-code response)))
            (is (= 1 @requests))
            (is (nil? (model/read-block (:model (rpc-session/state session)) "remote")))))
        [true false]))

(deftest refresh-status-failure-preserves-already-cached-blocks
  (run! (fn [transport-failure?]
          (let [requests (atom 0)
                session (refresh-session
                         (fn [_]
                           (if (= 1 (swap! requests inc))
                             (Ok (api/response 200 remote-feed))
                             (if transport-failure? (Error "offline")
                                 (Ok (api/response 503 "bad gateway"))))))
                response (dispatch-json session "refresh" "")]
            (is (= "remote_statuses_failed" (response-error-code response)))
            (is (= 2 @requests))
            (is (some? (model/read-block (:model (rpc-session/state session)) "remote")))))
        [true false]))

(deftest refresh-malformed-json-preserves-error-and-partial-cache-semantics
  (run! (fn [malformed-blocks?]
          (let [requests (atom 0)
                session (refresh-session
                         (fn [_]
                           (let [first? (= 1 (swap! requests inc))]
                             (Ok (api/response 200
                                               (if (and first? (not malformed-blocks?)) remote-feed "not json"))))))
                response (dispatch-json session "refresh" "")]
            (is (= "invalid_json" (response-error-code response)))
            (is (= (if malformed-blocks? 1 2) @requests))
            (is (= (not malformed-blocks?)
                   (some? (model/read-block (:model (rpc-session/state session)) "remote"))))))
        [true false]))

(deftest optimistic-capture-is-returned-before-sync
  (let [session (rpc-session/create-session rpc-session/default-options)
        response (dispatch-json session "send"
                                "{\"text\":\"Optimistic capture\",\"uuid\":\"local-swift\",\"now\":1776000000000}")
        blocks (json-util/to-list (json-util/member "blocks" (json-util/member "result" response)))
        block (nth blocks 0)]
    (is (= "local-swift" (json-util/to-string (json-util/member "uuid" block))))
    (is (= "Optimistic capture" (json-util/to-string (json-util/member "title" block))))
    (is (= "pending" (json-util/to-string (json-util/member "syncStatus" block))))
    (is (= 1776000000000 (json-util/to-int (json-util/member "createdAt" block))))))

(defn title-operation [wire]
  (record ops/pending-operation
          (operation-id "original") (base-t 42) (state ops/Retryable)
          (intent (ops/intent-of-json (json/from-string wire)))))

(def title-intent-wires
  ["{\"type\":\"save-title\",\"uuid\":\"b\",\"expectedTitle\":\"old\",\"title\":\"one\"}"
   "{\"type\":\"insert-block\",\"uuid\":\"b\",\"title\":\"one\",\"pageUuid\":\"p\",\"parentUuid\":\"p\",\"order\":\"a0\",\"createdAt\":1}"
   "{\"type\":\"split-block\",\"uuid\":\"b\",\"expectedTitle\":\"old\",\"before\":\"one\",\"after\":\"two\",\"newUuid\":\"new\",\"newOrder\":\"a1\",\"createdAt\":1}"
   "{\"type\":\"merge-backward\",\"uuid\":\"b\",\"expectedTitle\":\"old\",\"title\":\"one\",\"previousUuid\":\"prev\",\"expectedPreviousTitle\":\"previous\",\"mergedTitle\":\"combined\"}"])

(deftest title-normalization-preserves-operation-and-stages-tags-first
  (let [calls (atom 0)
        normalize (fn [uuid titles]
                    (is (= "b" uuid))
                    (swap! calls inc)
                    (tuple (mapv #(str "normalized:" %) titles)
                           [["tag-1" "First"] ["tag-2" "Second"]]))]
    (run! (fn [wire]
            (let [operation (title-operation wire)
                  result (rpc/normalize-operation-titles (Some normalize) (fn [] "new-id") (fn [] 100) operation)
                  changed (nth result 2)
                  expected (title-operation
                            (-> wire
                                (string/replace "\"one\"" "\"normalized:one\"")
                                (string/replace "\"two\"" "\"normalized:two\"")))]
              (is (= 3 (count result)))
              (is (= "original" (:operation-id changed)))
              (is (= 42 (:base-t changed)))
              (is (= ops/Retryable (:state changed)))
              (run! (fn [index]
                      (let [tag-op (nth result index)]
                        (is (= 42 (:base-t tag-op)))
                        (is (= ops/Queued (:state tag-op)))
                        (match (:intent tag-op)
                          (ops/Create-tag tag)
                          (do (is (= (nth ["tag-1" "tag-2"] index) (:uuid tag)))
                              (is (= (nth ["First" "Second"] index) (:title tag)))
                              (is (= 100 (:created-at tag))))
                          _ (is false))))
                    [0 1])
              (is (= expected changed))))
          title-intent-wires)
    (is (= 4 @calls))))

(deftest title-normalization-keeps-original-intent-on-wrong-arity
  (let [normalize (fn [_uuid _titles] (tuple [] [["tag" "Tag"]]))]
    (run! (fn [wire]
            (let [operation (title-operation wire)
                  result (rpc/normalize-operation-titles (Some normalize) (fn [] "new-id") (fn [] 100) operation)]
              (is (= 2 (count result)))
              (is (= operation (nth result 1)))))
          title-intent-wires)))

(deftest title-normalization-skips-unrelated-intents-and-absent-service
  (let [calls (atom 0)
        normalize (fn [_uuid titles] (swap! calls inc) (tuple titles []))
        operation (title-operation "{\"type\":\"delete-blocks\",\"uuids\":[\"b\"]}")]
    (is (= [operation] (rpc/normalize-operation-titles (Some normalize) (fn [] "new-id") (fn [] 100) operation)))
    (is (= 0 @calls))
    (run! (fn [wire]
            (let [operation (title-operation wire)]
              (is (= [operation] (rpc/normalize-operation-titles nil (fn [] "new-id") (fn [] 100) operation)))))
          title-intent-wires)))

(deftest capture-requires-projection-cursor-before-looking-up-journal
  (let [calls (atom 0)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :journal-page-id (Some (fn [_day] (swap! calls inc) nil))))]
    (is (= (Error "A current server cursor is required")
           (rpc-session/capture-operations session "b" "Text" 1776000000000 nil)))
    (is (= 0 @calls))))

(defn asset-block [uuid]
  (assoc (model/local-block uuid "photo.jpg" "local-page" nil 1776000000000)
         :is-asset true :asset-type (Some "jpg") :asset-size (Some 2048)
         :asset-checksum (Some "checksum") :local-path (Some "Assets/photo.jpg")))

(deftest asset-operation-rejects-missing-cursor-before-loading-destination
  (let [loads (atom 0)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :graph-blocks (Some (fn [] (swap! loads inc) (Some (list))))
                                                   :journal-page-id (Some (fn [_day] (swap! loads inc) (Some "journal")))))]
    (is (= (Error "A current server cursor is required")
           (rpc-session/asset-datoms-operation session (asset-block "a") ops/Queued)))
    (is (= 0 @loads))))

(deftest asset-operation-rejects-incomplete-metadata-before-loading-destination
  (let [loads (atom 0)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :sync-cursor (Some (fn [] (Some 7)))
                                                   :graph-blocks (Some (fn [] (swap! loads inc) (Some (list))))
                                                   :journal-page-id (Some (fn [_day] (swap! loads inc) (Some "journal")))))
        asset (asset-block "a")]
    (run! (fn [block]
            (is (= (Error "asset metadata is incomplete")
                   (rpc-session/asset-datoms-operation session block ops/Queued))))
          [(assoc asset :asset-type nil) (assoc asset :asset-size nil)
           (assoc asset :asset-checksum nil)])
    (is (= 0 @loads))))

(deftest asset-operation-does-not-fallback-from-missing-parent-to-journal
  (let [journal-lookups (atom 0)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :sync-cursor (Some (fn [] (Some 7)))
                                                   :journal-page-id (Some (fn [_day]
                                                                            (swap! journal-lookups inc)
                                                                            (Some "journal")))))]
    (is (= (Error "asset destination is not available")
           (rpc-session/asset-datoms-operation session (assoc (asset-block "a") :parent-id (Some "missing")) ops/Queued)))
    (is (= 0 @journal-lookups))))

(deftest asset-operation-uses-journal-date-and-preserves-durable-metadata
  (let [days (atom [])
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :sync-cursor (Some (fn [] (Some 7)))
                                                   :journal-page-id (Some (fn [day] (swap! days conj day) (Some "journal")))))
        asset (asset-block "a")]
    (match (rpc-session/asset-datoms-operation session asset ops/Applied)
      (Ok operation)
      (do (is (= "asset:a" (:operation-id operation)))
          (is (= 7 (:base-t operation)))
          (is (= ops/Applied (:state operation)))
          (match (:intent operation)
            (ops/Create-asset value)
            (do (is (= "a" (:uuid value)))
                (is (= "photo.jpg" (:title value)))
                (is (= "journal" (:page-uuid value)))
                (is (= "journal" (:parent-uuid value)))
                (is (= "a0" (:order value)))
                (is (= 1776000000000 (:created-at value)))
                (is (= "jpg" (:asset-type value)))
                (is (= 2048 (:asset-size value)))
                (is (= "checksum" (:asset-checksum value))))
            _ (is false)))
      _ (is false))
    (is (= [(model/journal-day-for-ms (:created-at asset))] @days))))

(deftest asset-operation-orders-after-siblings-without-counting-itself
  (let [parent (model/local-block "parent" "Parent" "page" nil 1)
        sibling (assoc parent :uuid "sibling" :parent-id (Some "parent") :order (Some "a2"))
        earlier (assoc sibling :uuid "earlier" :order (Some "a0"))
        other-page (assoc sibling :uuid "other-page" :page-id "elsewhere" :order (Some "zZ"))
        other-parent (assoc sibling :uuid "other-parent" :parent-id (Some "elsewhere") :order (Some "zZ"))
        unordered (assoc sibling :uuid "unordered" :order nil)
        asset (assoc (asset-block "a") :parent-id (Some "parent") :page-id "page" :order (Some "zZ"))
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :sync-cursor (Some (fn [] (Some 7)))
                                                   :graph-blocks (Some (fn [] (Some (list parent sibling earlier other-page other-parent unordered asset))))))]
    (match (rpc-session/asset-datoms-operation session asset ops/Queued)
      (Ok operation)
      (do (is (= ops/Queued (:state operation)))
          (match (:intent operation)
            (ops/Create-asset value)
            (do (is (= "page" (:page-uuid value)))
                (is (= "parent" (:parent-uuid value)))
                (is (= "a3" (:order value))))
            _ (is false)))
      _ (is false))))

(deftest encrypted-asset-upload-stages-datoms-and-cleans-temporary-payload
  (let [cleaned (atom [])
        staged (atom [])
        checksum "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-graph-catalog (Some (fn [] (Some encrypted-graph-catalog)))
                                                   :graph-unlocked (Some (fn [_graph-id] true))
                                                   :encrypt-title (Some (fn [_graph-id title] (Ok (str "cipher(" title ")"))))
                                                   :resolve-asset-path (fn [path]
                                                                         (is (= "Assets/photo.jpg" path))
                                                                         "/documents/Assets/photo.jpg")
                                                   :encrypt-asset-file (Some (fn [_graph-id path]
                                                                               (is (= "/documents/Assets/photo.jpg" path))
                                                                               (Ok (tuple "/tmp/photo.transit" 4096))))
                                                   :journal-page-id (Some (fn [_day] (Some "real-journal-page")))
                                                   :sync-cursor (Some (fn [] (Some 91)))
                                                   :stage-operation (Some (fn [operation]
                                                                            (match (:intent operation)
                                                                              (ops/Create-asset value)
                                                                              (do (is (= "asset-async" (:uuid value)))
                                                                                  (is (= "photo.jpg" (:title value)))
                                                                                  (is (= "real-journal-page" (:page-uuid value)))
                                                                                  (is (= "real-journal-page" (:parent-uuid value)))
                                                                                  (is (= "jpg" (:asset-type value)))
                                                                                  (is (= 2048 (:asset-size value)))
                                                                                  (is (= checksum (:asset-checksum value))))
                                                                              _ (is false))
                                                                            (swap! staged conj (ops/state-string (:state operation)))
                                                                            (Ok (stdlib/ignore 0))))
                                                   :prepare-operation (Some (fn [operation]
                                                                              (Ok (tuple (ops/outliner-op (:intent operation)) "[]"))))
                                                   :cleanup-file (fn [path] (swap! cleaned conj path) (stdlib/ignore 0))))]
    (configure-encrypted-session session)
    (dispatch-json session "selectGraph" "encrypted-1")
    (dispatch-json session "addAsset"
                   (str "{\"uuid\":\"asset-async\",\"title\":\"photo.jpg\",\"now\":1776000000000,\"assetType\":\"jpg\",\"assetSize\":2048,\"assetChecksum\":\""
                        checksum "\",\"localPath\":\"Assets/photo.jpg\"}"))
    (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (do (is (= "PUT" (json-util/to-string (json-util/member "method" request))))
          (is (= "/tmp/photo.transit" (json-util/to-string (json-util/member "filePath" request))))
          (is (= "text/plain" (json-util/to-string (json-util/member "contentType" request))))
          (is (= "http://127.0.0.1:8787/assets/encrypted-1/asset-async.jpg"
                 (json-util/to-string (json-util/member "url" request))))
          (let [headers (json-util/member "headers" request)]
            (is (= checksum (json-util/to-string (json-util/member "x-amz-meta-checksum" headers))))
            (is (= "jpg" (json-util/to-string (json-util/member "x-amz-meta-type" headers))))))
      (is false))
    (if-some [request (pending-request
                       (dispatch-json session "completePendingSync"
                                      "{\"id\":1,\"status\":200,\"body\":\"{\\\"ok\\\":true}\",\"error\":null}"))]
      (is (= "http://127.0.0.1:8787/sync/encrypted-1/tx/batch"
             (json-util/to-string (json-util/member "url" request))))
      (is false))
    (is (= ["applied" "queued"] @staged))
    (is (= ["/tmp/photo.transit"] @cleaned))))

(deftest graph-creation-validates-before-performing-io
  (let [calls (atom 0)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :send (fn [_request]
                                                           (swap! calls inc)
                                                           (Error "unexpected transport"))))]
    (is (= "graph_not_configured"
           (response-error-code (dispatch-json session "createSyncGraph" "{}"))))
    (configure-encrypted-session session)
    (run! (fn [[payload code]]
            (is (= code (response-error-code (dispatch-json session "createSyncGraph" payload)))))
          [(tuple "{" "invalid_json") (tuple "[]" "invalid_params")
           (tuple "{}" "invalid_params")
           (tuple "{\"name\":\"  \",\"isEncrypted\":false}" "invalid_params")
           (tuple "{\"name\":\"Graph\",\"isEncrypted\":\"false\"}" "invalid_params")])
    (is (= 0 @calls))
    (is (= "invalid_params"
           (response-error-code
            (json/from-string (rpc-session/call session
                                                "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"createSyncGraph\"}}")))))))

(deftest graph-creation-preserves-transport-and-response-errors
  (run! (fn [[reply code message]]
          (let [uploads (atom 0)
                session (rpc-session/create-session (assoc rpc-session/default-options
                                                           :send (fn [_request] reply)
                                                           :upload-file (fn [_upload]
                                                                          (swap! uploads inc)
                                                                          (Error "unexpected upload"))))]
            (configure-encrypted-session session)
            (let [response (dispatch-json session "createSyncGraph" "{\"name\":\"Graph\",\"isEncrypted\":false}")]
              (is (= code (response-error-code response)))
              (is (= message (json-util/to-string
                              (json-util/member "message" (json-util/member "error" response))))))
            (is (= 0 @uploads))))
        [(tuple (Error "offline") "graph_create_failed" "offline")
         (tuple (Ok (api/response 503 "")) "graph_create_failed" "Could not create graph")
         (tuple (Ok (api/response 403 "denied")) "graph_create_failed" "denied")
         (tuple (Ok (api/response 201 "{}")) "graph_create_failed" "Graph creation returned no graph id")
         (tuple (Ok (api/response 201 "[]")) "graph_create_failed" "Graph creation returned no graph id")
         (tuple (Ok (api/response 201 "{\"graph-id\":1}")) "graph_create_failed" "Graph creation returned no graph id")]))

(deftest encrypted-graph-creation-stops-when-key-provisioning-is-unavailable
  (let [uploads (atom 0)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :send (fn [_request] (Ok (api/response 201 "{\"graph-id\":\"new-private\"}")))
                                                   :upload-file (fn [_upload] (swap! uploads inc) (Error "unexpected upload"))))]
    (configure-encrypted-session session)
    (is (= "graph_key_provision_failed"
           (response-error-code (dispatch-json session "createSyncGraph" "{\"name\":\"Private\",\"isEncrypted\":true}"))))
    (is (= 0 @uploads))))

(deftest encrypted-graph-creation-stops-after-key-provisioning-failure
  (let [events (atom [])
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :send (fn [_request]
                                                           (swap! events conj "create")
                                                           (Ok (api/response 201 "{\"graph-id\":\"new-private\"}")))
                                                   :provision-graph-key (Some (fn [config]
                                                                                (is (= "new-private" (:graph-id config)))
                                                                                (is (= (Some "Private") (:graph-name config)))
                                                                                (swap! events conj "provision")
                                                                                (Error "key storage unavailable")))
                                                   :upload-file (fn [_upload] (swap! events conj "upload") (Error "unexpected upload"))))]
    (configure-encrypted-session session)
    (is (= "graph_key_provision_failed"
           (response-error-code (dispatch-json session "createSyncGraph" "{\"name\":\" Private \",\"isEncrypted\":true}"))))
    (is (= ["create" "provision"] @events))))

(deftest graph-creation-cleans-up-after-upload-http-failure
  (let [uploaded-path (atom nil)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :send (fn [_request] (Ok (api/response 201 "{\"graph-id\":\"new-plain\"}")))
                                                   :upload-file (fn [upload]
                                                                  (reset! uploaded-path (Some (:file-path upload)))
                                                                  (is (sys/file-exists (:file-path upload)))
                                                                  (Ok (api/response 500 "")))))]
    (configure-encrypted-session session)
    (let [response (dispatch-json session "createSyncGraph" "{\"name\":\"Plain\",\"isEncrypted\":false}")]
      (is (= "graph_initial_upload_failed" (response-error-code response)))
      (is (= "Initial snapshot upload failed with HTTP 500"
             (json-util/to-string (json-util/member "message" (json-util/member "error" response))))))
    (if-some [path @uploaded-path] (is (not (sys/file-exists path))) (is false))))

(deftest encrypted-graph-selection-attempts-offline-key-cache
  (let [loaded (atom [])
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-graph-catalog (Some (fn [] (Some encrypted-graph-catalog)))
                                                   :load-cached-graph-key (Some (fn [config]
                                                                                  (swap! loaded conj (:graph-id config))
                                                                                  (Error "not cached")))
                                                   :graph-unlocked (Some (fn [_graph-id] false))))]
    (configure-encrypted-session session)
    (let [response (dispatch-json session "selectGraph" "encrypted-1")
          result (json-util/member "result" response)]
      (is (json-util/to-bool (json-util/member "ok" response)))
      (is (json-util/to-bool (json-util/member "isGraphEncrypted" result)))
      (is (not (json-util/to-bool (json-util/member "isGraphUnlocked" result)))))
    (is (= ["encrypted-1"] @loaded))))

(deftest encrypted-graph-unlock-forwards-password-and-updates-state
  (let [unlocked (atom false)
        received (atom nil)
        session (rpc-session/create-session (assoc rpc-session/default-options
                                                   :load-graph-catalog (Some (fn [] (Some encrypted-graph-catalog)))
                                                   :unlock-graph (Some (fn [_config password]
                                                                         (reset! received (Some password))
                                                                         (reset! unlocked true)
                                                                         (Ok (stdlib/ignore 0))))
                                                   :graph-unlocked (Some (fn [_graph-id] @unlocked))))]
    (configure-encrypted-session session)
    (dispatch-json session "selectGraph" "encrypted-1")
    (let [response (dispatch-json session "unlockGraph" "correct horse")]
      (is (json-util/to-bool (json-util/member "ok" response)))
      (is (json-util/to-bool (json-util/member "isGraphUnlocked" (json-util/member "result" response)))))
    (is (= (Some "correct horse") @received))))

(deftest session-rejects-legacy-sync-action
  (let [response (json/from-string
                  (rpc-session/call (rpc-session/create-session rpc-session/default-options)
                                    "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"syncPending\"}}"))]
    (is (not (json-util/to-bool (json-util/member "ok" response))))
    (is (= "unknown_action"
           (json-util/to-string (json-util/member "code" (json-util/member "error" response)))))))

(deftest session-without-graph-has-no-due-flashcards
  (let [response (json/from-string
                  (rpc-session/call (rpc-session/create-session rpc-session/default-options)
                                    "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"loadFlashcards\",\"payload\":\"1776000000000\"}}"))]
    (is (json-util/to-bool (json-util/member "ok" response)))
    (is (= "[]" (json/to-string (json-util/member "flashcards" (json-util/member "result" response)))))))

(deftest session-restores-cached-graph-name-without-token
  (let [response (json/from-string
                  (rpc-session/call (rpc-session/create-session rpc-session/default-options)
                                    "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"configure\",\"payload\":\"{\\\"baseUrl\\\":\\\"http://127.0.0.1:8787\\\",\\\"graphId\\\":\\\"cached-graph\\\",\\\"graphName\\\":\\\"Sync 2\\\",\\\"token\\\":\\\"\\\"}\"}}"))
        result (json-util/member "result" response)]
    (is (= "cached-graph" (json-util/to-string (json-util/member "selectedGraphId" result))))
    (is (= "Sync 2" (json-util/to-string (json-util/member "graphName" result))))))

(deftest session-clear-related-exposes-related-blocks
  (let [response (json/from-string
                  (rpc-session/call (rpc-session/create-session rpc-session/default-options)
                                    "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"clearRelated\"}}"))]
    (is (= "[]" (json/to-string (json-util/member "relatedBlocks" (json-util/member "result" response)))))))

(deftest rpc-routing-validates-before-executing-actions
  (let [calls (atom [])
        snapshot (fn [] (swap! calls conj "snapshot") "snapshot-result")
        dispatch (fn [action payload]
                   (swap! calls conj action)
                   (match payload (Some value) value None "no-payload"))
        call (fn [request] (rpc/call snapshot dispatch request))]
    (run! (fn [[request code message]]
            (is (= (rpc/failure code message) (call request))))
          [(tuple "{" "invalid_json" "request must be valid JSON")
           (tuple "[]" "invalid_request" "request must be an object")
           (tuple "{}" "invalid_request" "missing field: apiVersion")
           (tuple "{\"apiVersion\":2}" "unsupported_version" "only API version 1 is supported")
           (tuple "{\"apiVersion\":null}" "invalid_request" "apiVersion must be an integer")
           (tuple "{\"apiVersion\":1}" "invalid_request" "missing field: method")
           (tuple "{\"apiVersion\":1,\"method\":1}" "invalid_request" "field must be a string: method")
           (tuple "{\"apiVersion\":1,\"method\":\"open\"}" "invalid_request" "missing field: params")
           (tuple "{\"apiVersion\":1,\"method\":\"open\",\"params\":null}" "invalid_request" "params must be an object")
           (tuple "{\"apiVersion\":1,\"method\":\"bad\",\"params\":{}}" "unknown_method" "unknown method: bad")
           (tuple "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{}}" "invalid_params" "missing field: action")
           (tuple "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"send\",\"payload\":1}}" "invalid_params" "field must be a string: payload")])
    (is (= [] @calls))
    (is (= "snapshot-result" (call "{\"apiVersion\":1,\"method\":\"open\",\"params\":{}}")))
    (is (= "snapshot-result" (call "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")))
    (is (= "hello" (call "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"send\",\"payload\":\"hello\"}}")))
    (is (= "no-payload" (call "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"sync\"}}")))
    (is (= ["snapshot" "snapshot" "send" "sync"] @calls))))

(deftest rpc-routing-keeps-first-fields-and-catches-handler-errors
  (let [snapshot (fn [] "snapshot")
        dispatch (fn [_action payload] (match payload (Some value) value None "nil"))]
    (is (= "first"
           (rpc/call snapshot dispatch
                     "{\"apiVersion\":1,\"apiVersion\":2,\"method\":\"dispatch\",\"params\":{\"action\":\"send\",\"payload\":\"first\",\"payload\":\"second\"}}")))
    (is (= "nil"
           (rpc/call snapshot dispatch
                     "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"sync\",\"payload\":null}}")))
    (is (= (rpc/failure "invalid_json" "request must be valid JSON")
           (rpc/call (fn [] (json/to-string (json/from-string "{"))) dispatch
                     "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")))))

(deftest capture-payload-supports-plain-text-and-validated-json
  (run! (fn [[payload expected]] (is (= (Ok expected) (rpc/send-payload payload))))
        [(tuple nil (tuple "" nil nil))
         (tuple (Some "  hello\n") (tuple "hello" nil nil))
         (tuple (Some " {broken ") (tuple "{broken" nil nil))
         (tuple (Some " [1] ") (tuple "[1]" nil nil))
         (tuple (Some "null") (tuple "null" nil nil))
         (tuple (Some "\"hello\"") (tuple "\"hello\"" nil nil))
         (tuple (Some "{\"text\":\" hi \",\"uuid\":\"u\",\"now\":42}") (tuple "hi" (Some "u") (Some 42)))
         (tuple (Some "{\"text\":\" hi \",\"uuid\":null,\"now\":null}") (tuple "hi" nil nil))
         (tuple (Some "{\"text\":\"first\",\"text\":\"second\"}") (tuple "first" nil nil))])
  (run! (fn [[payload message]] (is (= (Error message) (rpc/send-payload (Some payload)))))
        [(tuple "{}" "missing field: text")
         (tuple "{\"text\":7,\"uuid\":7,\"now\":false}" "field must be a string: text")
         (tuple "{\"text\":\"hi\",\"uuid\":7,\"now\":false}" "field must be a string: uuid")
         (tuple "{\"text\":\"hi\",\"now\":1.5}" "field must be an integer: now")]))

(deftest rpc-response-envelopes-preserve-version-and-error-contract
  (is (= "{\"apiVersion\":1,\"ok\":true,\"result\":{\"x\":[1,null]},\"error\":null}"
         (rpc/success (json/from-string "{\"x\":[1,null]}"))))
  (is (= "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":\"invalid\",\"message\":\"line\\nquoted \\\"text\\\"\"}}"
         (rpc/failure "invalid" "line\nquoted \"text\""))))

(deftest pending-request-preserves-body-and-upload-wire-fields
  (let [request (record api/api-request (method_ "POST") (url "https://example.test/api")
                        (body nil) (token "secret"))
        encode (fn [body path headers]
                 (rpc/request-json 7 (assoc request :body body) path "application/json" headers))]
    (is (= "{\"id\":7,\"method\":\"POST\",\"url\":\"https://example.test/api\",\"token\":\"secret\",\"contentType\":\"application/json\",\"headers\":{}}"
           (json/to-string (encode nil nil []))))
    (run! (fn [body]
            (let [encoded (encode (Some body) nil [])]
              (is (= body (json-util/to-string (json-util/member "body" encoded))))
              (is (= (json/to-string (json/from-string body))
                     (json/to-string (json-util/member "bodyObject" encoded))))))
          ["{\"x\":1}" "[]" "null" "false" "42" "\"hello\""])
    (run! (fn [body]
            (let [encoded (encode (Some body) nil [])]
              (is (= body (json-util/to-string (json-util/member "body" encoded))))
              (is (= "null" (json/to-string (json-util/member "bodyObject" encoded))))))
          ["" "{" "raw text"])
    (is (= "{\"id\":7,\"method\":\"POST\",\"url\":\"https://example.test/api\",\"token\":\"secret\",\"contentType\":\"application/octet-stream\",\"headers\":{\"X-Key\":\"one\",\"X-Key\":\"two\"},\"filePath\":\"/tmp/a b\"}"
           (json/to-string
            (rpc/request-json 7 request (Some "/tmp/a b") "application/octet-stream"
                              [(tuple "X-Key" "one") (tuple "X-Key" "two")]))))))

(deftest toolbar-wire-actions-preserve-all-public-mappings
  (run! (fn [[wire action]] (is (= (Ok action) (rpc/toolbar-action wire))))
        [(tuple "task" outliner/Task) (tuple "outdent" outliner/Outdent)
         (tuple "indent" outliner/Indent) (tuple "tag" outliner/Tag_action)
         (tuple "pageReference" outliner/Page_reference) (tuple "camera" outliner/Camera)
         (tuple "audio" outliner/Audio) (tuple "attachment" outliner/Attachment)
         (tuple "hideKeyboard" outliner/Hide_keyboard) (tuple "copy" outliner/Copy)
         (tuple "delete" outliner/Delete) (tuple "copyReference" outliner/Copy_reference)
         (tuple "copyURL" outliner/Copy_url) (tuple "unselect" outliner/Unselect)])
  (run! #(is (= (Error "unknown outliner toolbar action") (rpc/toolbar-action %)))
        ["unsupported" "" "Task" "copyUrl"]))

(deftest flashcard-wire-ratings-preserve-values-and-validation
  (run! (fn [[wire rating]] (is (= (Ok rating) (rpc/flashcard-rating wire))))
        [(tuple "again" flashcards/Again) (tuple "hard" flashcards/Hard)
         (tuple "good" flashcards/Good) (tuple "easy" flashcards/Easy)])
  (run! #(is (= (Error "rating must be again, hard, good, or easy") (rpc/flashcard-rating %)))
        ["" "Good" "unknown"]))

(deftest outliner-events-decode-navigation-and-editing-payloads
  (run! (fn [[wire expected]] (is (= (Ok expected) (rpc/outliner-message wire))))
        [(tuple "{\"type\":\"tapBlock\",\"uuid\":\"block\"}" (outliner/Tap_block "block"))
         (tuple "{\"type\":\"longPressBlock\",\"uuid\":\"block\"}" (outliner/Long_press_block "block"))
         (tuple "{\"type\":\"caretMoved\",\"caretUTF16Offset\":3}" (outliner/Caret_moved 3))
         (tuple "{\"type\":\"returnPressed\"}" outliner/Return_pressed)
         (tuple "{\"type\":\"returnPressed\",\"title\":\"Hello\",\"caretUTF16Offset\":2}"
                (outliner/Return_pressed_with_text (record outliner/outliner-text (title "Hello") (caret 2))))
         (tuple "{\"type\":\"textChanged\",\"title\":\"New\",\"caretUTF16Offset\":3}"
                (outliner/Text_changed (record outliner/outliner-text (title "New") (caret 3))))
         (tuple "{\"type\":\"backspacePressed\",\"selectionLength\":0}"
                (outliner/Backspace_pressed (record outliner/outliner-selection (selection-length 0))))
         (tuple "{\"type\":\"backspacePressed\",\"selectionLength\":2,\"title\":\"Text\"}"
                (outliner/Backspace_pressed_with_text (record outliner/outliner-backspace (title "Text") (selection-length 2))))
         (tuple "{\"type\":\"toolbar\",\"action\":\"task\"}" (outliner/Toolbar outliner/Task))
         (tuple "{\"type\":\"chooseAutocomplete\",\"value\":\"page\"}" (outliner/Choose_autocomplete "page"))
         (tuple "{\"type\":\"confirmDelete\"}" outliner/Confirm_delete)
         (tuple "{\"type\":\"saveEditing\"}" outliner/Save_editing)
         (tuple "{\"type\":\"cancelEditing\"}" outliner/Cancel_editing)
         (tuple "{\"type\":\"toggleCollapsed\",\"uuid\":\"block\"}" (outliner/Toggle_collapsed "block"))
         (tuple "{\"type\":\"zoomIn\",\"uuid\":\"block\"}" (outliner/Zoom_in "block"))
         (tuple "{\"type\":\"zoomOut\"}" outliner/Zoom_out)
         (tuple "{\"type\":\"addRootBlock\",\"uuid\":\"page\"}" (outliner/Add_root_block "page"))]))

(deftest outliner-event-errors-preserve-wire-validation
  (run! (fn [[wire message]] (is (= (Error message) (rpc/outliner-message wire))))
        [(tuple "{" "outliner event must be valid JSON")
         (tuple "[]" "outliner event must be an object")
         (tuple "{}" "missing field: type")
         (tuple "{\"type\":1}" "field must be a string: type")
         (tuple "{\"type\":\"unknown\"}" "unknown outliner event type")
         (tuple "{\"type\":\"tapBlock\"}" "missing field: uuid")
         (tuple "{\"type\":\"caretMoved\",\"caretUTF16Offset\":1.0}" "missing integer outliner event field: caretUTF16Offset")
         (tuple "{\"type\":\"returnPressed\",\"title\":\"x\"}" "returnPressed requires both title and caretUTF16Offset")
         (tuple "{\"type\":\"returnPressed\",\"caretUTF16Offset\":1}" "returnPressed requires both title and caretUTF16Offset")
         (tuple "{\"type\":\"returnPressed\",\"title\":null,\"caretUTF16Offset\":null}" "returnPressed requires both title and caretUTF16Offset")
         (tuple "{\"type\":\"backspacePressed\"}" "missing integer outliner event field: selectionLength")
         (tuple "{\"type\":\"backspacePressed\",\"selectionLength\":0,\"title\":null}" "backspacePressed title must be a string")
         (tuple "{\"type\":\"toolbar\",\"action\":\"bad\"}" "unknown outliner toolbar action")
         (tuple "{\"type\":\"dropBlocks\",\"targetUuid\":\"x\",\"placement\":\"bad\"}" "unknown outliner drop placement")
         (tuple "{\"type\":\"setTaskStatus\",\"uuid\":\"x\"}" "setTaskStatus requires a status reference")]))

(deftest outliner-drop-and-status-events-preserve-priority
  (run! (fn [[wire placement]]
          (is (= (Ok (outliner/Drop_blocks (record outliner/outliner-drop (target-uuid "x") (placement placement))))
                 (rpc/outliner-message (str "{\"type\":\"dropBlocks\",\"targetUuid\":\"x\",\"placement\":\"" wire "\"}")))))
        [(tuple "before" outliner/Before) (tuple "inside" outliner/Inside) (tuple "after" outliner/After)])
  (is (= (Ok (outliner/Set_task_status (record outliner/outliner-status (uuid "x") (status (ops/Ref-ident "todo")))))
         (rpc/outliner-message "{\"type\":\"setTaskStatus\",\"uuid\":\"x\",\"statusIdent\":\"todo\",\"statusUuid\":7}")))
  (is (= (Ok (outliner/Set_task_status (record outliner/outliner-status (uuid "x") (status (ops/Ref-uuid "status")))))
         (rpc/outliner-message "{\"type\":\"setTaskStatus\",\"uuid\":\"x\",\"statusIdent\":null,\"statusUuid\":\"status\"}")))
  (is (= (Error "field must be a string: statusIdent")
         (rpc/outliner-message "{\"type\":\"setTaskStatus\",\"uuid\":\"x\",\"statusIdent\":7,\"statusUuid\":\"status\"}")))
  (is (= (Ok (outliner/Tap_block "first"))
         (rpc/outliner-message "{\"type\":\"tapBlock\",\"uuid\":\"first\",\"uuid\":\"second\"}"))))

(defn video-block [uuid title] (model/local-block uuid title "page" nil 0))

(deftest optimistic-intents-preserve-unmodified-block-fields
  (let [source (assoc (video-block "source" "Before") :sync-status "synced")
        other (video-block "other" "Other")
        rename (ops/Save-title (record ops/pending-title
                                       (uuid "source") (expected-title "Before") (title "After")))
        insert (ops/Insert-block (record ops/pending-insert
                                         (uuid "new") (title "New") (page-uuid "page")
                                         (parent-uuid "source") (order "a1") (created-at 42)))]
    (is (= [(assoc source :title "After") other]
           (rpc/project-outliner-intent [source other] rename)))
    (is (= [] (rpc/project-outliner-intent [] rename)))
    (is (= [source (assoc (model/local-block "new" "New" "page" (Some "source") 42)
                          :order (Some "a1"))]
           (rpc/project-outliner-intent [source] insert)))))

(deftest optimistic-assets-replace-in-place-and-preserve-local-path
  (let [source (assoc (video-block "asset" "Draft") :local-path (Some "/local/image"))
        other (video-block "other" "Other")
        intent (ops/Create-asset (record ops/pending-asset
                                         (uuid "asset") (title "Image") (page-uuid "page")
                                         (parent-uuid "parent") (order "a2") (created-at 7)
                                         (asset-type "image/png") (asset-size 12) (asset-checksum "hash")))
        asset (assoc (model/local-block "asset" "Image" "page" (Some "parent") 7)
                     :order (Some "a2") :is-asset true :asset-type (Some "image/png")
                     :asset-size (Some 12) :asset-checksum (Some "hash"))]
    (is (= [(assoc asset :local-path (Some "/local/image")) other]
           (rpc/project-outliner-intent [source other] intent)))
    (is (= [other asset] (rpc/project-outliner-intent [other] intent)))))

(deftest optimistic-splits-preserve-source-location-and-ignore-missing-source
  (let [source (assoc (video-block "source" "BeforeAfter")
                      :parent-id (Some "parent") :order (Some "a0") :sync-status "synced")
        intent (ops/Split-block (record ops/pending-split
                                        (uuid "source") (expected-title "BeforeAfter")
                                        (before "Before") (after "After") (new-uuid "new")
                                        (new-order "a1") (created-at 10)))]
    (is (= [] (rpc/project-outliner-intent [] intent)))
    (is (= [(assoc source :title "Before")
            (assoc (model/local-block "new" "After" "page" (Some "parent") 10)
                   :order (Some "a1"))]
           (rpc/project-outliner-intent [source] intent)))))

(deftest optimistic-merges-use-explicit-title-or-concatenate-without-separator
  (let [previous (assoc (video-block "previous" "Before") :sync-status "synced")
        source (video-block "source" "After")
        payload (record ops/pending-merge
                        (uuid "source") (expected-title "After") (title "After")
                        (previous-uuid "previous") (expected-previous-title "Before") (merged-title nil))]
    (is (= [(assoc previous :title "BeforeAfter" :sync-status "pending")]
           (rpc/project-outliner-intent [previous source] (ops/Merge-backward payload))))
    (is (= [(assoc previous :title "" :sync-status "pending")]
           (rpc/project-outliner-intent [previous source]
                                        (ops/Merge-backward (assoc payload :merged-title (Some ""))))))
    (is (= [] (rpc/project-outliner-intent [source] (ops/Merge-backward payload))))))

(deftest optimistic-moves-apply-in-order-and-deletes-only-remove-specified-ids
  (let [source (video-block "source" "Source")
        child (assoc (video-block "child" "Child") :parent-id (Some "source"))
        move (record ops/pending-move (uuid "source") (page-uuid "new-page")
                     (parent-uuid "parent") (order "a1"))
        expected (assoc source :page-id "new-page" :parent-id (Some "parent")
                        :order (Some "a1") :sync-status "pending")]
    (is (= [expected child] (rpc/project-outliner-intent [source child] (ops/Move-block move))))
    (is (= [(assoc expected :order (Some "a2")) child]
           (rpc/project-outliner-intent [source child]
                                        (ops/Move-blocks (record ops/pending-moves (moves [move (assoc move :order "a2")]))))))
    (is (= [child] (rpc/project-outliner-intent [source child]
                                                (ops/Delete-blocks (record ops/pending-delete (uuids ["source" "missing"]))))))))

(deftest optimistic-status-projection-handles-builtins-custom-refs-and-clearing
  (let [source (assoc (video-block "source" "Task") :sync-status "synced")
        property (record ops/pending-property (uuid "source")
                         (attr "logseq.property/status") (expected nil) (value nil))]
    (run! (fn [[ident uuid title]]
            (let [status (record model/status (uuid uuid) (title title) (ident (Some ident))
                                 (icon-type nil) (icon-id nil) (icon-color nil))]
              (is (= [(assoc source :status (Some status) :sync-status "pending")]
                     (rpc/project-outliner-intent [source]
                                                  (ops/Set-property (assoc property :value (Some (ops/Ref-ident ident)))))))))
          [(tuple "logseq.property/status.backlog" "backlog" "Backlog")
           (tuple "logseq.property/status.todo" "todo" "Todo")
           (tuple "logseq.property/status.doing" "doing" "Doing")
           (tuple "logseq.property/status.in-review" "in-review" "In Review")
           (tuple "logseq.property/status.done" "done" "Done")
           (tuple "logseq.property/status.canceled" "canceled" "Canceled")
           (tuple "custom" "custom" "custom")])
    (let [status (record model/status (uuid "custom-id") (title "custom-id") (ident nil)
                         (icon-type nil) (icon-id nil) (icon-color nil))]
      (is (= [(assoc source :status (Some status) :sync-status "pending")]
             (rpc/project-outliner-intent [source]
                                          (ops/Set-property (assoc property :value (Some (ops/Ref-uuid "custom-id"))))))))
    (let [cleared [(assoc source :status nil :sync-status "pending")]]
      (is (= cleared (rpc/project-outliner-intent [source] (ops/Set-property property))))
      (is (= cleared
             (rpc/project-outliner-intent [source]
                                          (ops/Set-property (assoc property :value (Some (ops/String-value "not-a-reference"))))))))
    (is (= [source] (rpc/project-outliner-intent [source]
                                                 (ops/Set-property (assoc property :attr "other")))))
    (is (= [source] (rpc/project-outliner-intent [source]
                                                 (ops/Create-page (record ops/pending-create (uuid "page") (title "Page") (created-at 0))))))))

(deftest optimistic-overlay-preserves-draft-fields-and-refreshes-live-metadata
  (let [draft (assoc (video-block "a" "Draft") :parent-id (Some "draft-parent") :order (Some "a1") :created-at 1)
        summary (record model/entity-summary (uuid "ref") (title "Reference"))
        status (record model/status (uuid "done") (title "Done") (ident nil)
                       (icon-type nil) (icon-id nil) (icon-color nil))
        live (assoc (video-block "a" "Server") :parent-id (Some "server-parent") :order (Some "z9") :created-at 2
                    :updated-at 99 :sync-status "synced" :tags (list summary) :references (list summary)
                    :breadcrumbs (list summary) :status (Some status) :is-asset true :asset-type (Some "jpg")
                    :asset-size (Some 42) :asset-checksum (Some "checksum") :local-path (Some "/tmp/image")
                    :journal (Some (tuple "Today" 20260916)))
        expected (assoc live :title "Draft" :parent-id (Some "draft-parent") :order (Some "a1") :created-at 1)]
    (is (= expected (rpc/merge-live-block-metadata draft live)))
    (is (= [expected] (rpc/page-blocks-with-optimistic-overlay (Some [draft]) true "page" [live])))))

(deftest optimistic-overlay-only-applies-while-editing-and-keeps-cached-membership
  (let [draft (video-block "a" "Draft")
        missing (video-block "missing" "Offline")
        other (assoc (video-block "other" "Other") :page-id "other-page")
        live (video-block "a" "Server")
        newer (assoc live :updated-at 2)
        added (video-block "new" "New")
        cached (Some [missing other draft])]
    (is (= [missing (assoc draft :updated-at 2)]
           (rpc/page-blocks-with-optimistic-overlay cached true "page" [live newer added])))
    (is (= [live added] (rpc/page-blocks-with-optimistic-overlay cached false "page" [live added])))
    (is (= [live] (rpc/page-blocks-with-optimistic-overlay nil true "page" [live])))
    (is (= [] (rpc/page-blocks-with-optimistic-overlay (Some []) true "page" [live])))))

(deftest outliner-rows-preserve-hierarchy-video-targets-and-serializer
  (let [video (video-block "video" "{{youtube dQw4w9WgXcQ}}")
        child (assoc (video-block "child" "{{youtube-timestamp 00:10}}") :parent-id (Some "video"))
        context (record outliner/outliner-context (blocks (list video child)) (pages (list)) (tags (list)))
        seen (atom [])
        serialize (fn [block] (swap! seen conj (:uuid block)) (tag String (:uuid block)))
        encode (fn [state] (json/to-string (rpc/outliner-rows-json serialize context state)))]
    (is (= "[{\"block\":\"video\",\"depth\":0,\"hasChildren\":true,\"isCollapsed\":false},{\"block\":\"child\",\"depth\":1,\"hasChildren\":false,\"isCollapsed\":false,\"youtubeTargetURL\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}]"
           (encode outliner/empty)))
    (is (= ["video" "child"] @seen))
    (reset! seen [])
    (is (= "[{\"block\":\"video\",\"depth\":0,\"hasChildren\":true,\"isCollapsed\":true}]"
           (encode (assoc outliner/empty :collapsed #{"video"}))))
    (is (= ["video"] @seen))))

(deftest outliner-candidate-json-preserves-filtering-and-no-request
  (let [candidate (record outliner/outliner-candidate (label "Alpha") (value "page"))
        context (record outliner/outliner-context (blocks (list)) (pages (list candidate)) (tags (list)))
        state (assoc outliner/empty :autocomplete
                     (Some (record outliner/reducer-autocomplete (kind outliner/Node) (query "alp"))))]
    (is (= "[]" (json/to-string (rpc/outliner-candidates-json context outliner/empty))))
    (is (= "[{\"label\":\"Alpha\",\"value\":\"page\"}]"
           (json/to-string (rpc/outliner-candidates-json context state))))))

(defn json-field [value key] (json/to-string (json-util/member key value)))

(deftest graph-json-keeps-null-schema-and-readiness-flags
  (let [graph (record api/api-graph (id "graph") (name "Graph") (schema-version nil) (e2ee false) (ready true))]
    (is (= "{\"id\":\"graph\",\"name\":\"Graph\",\"schemaVersion\":null,\"isEncrypted\":false,\"isReady\":true}"
           (json/to-string (rpc/graph-json graph))))
    (is (= "{\"id\":\"graph\",\"name\":\"Graph\",\"schemaVersion\":\"v1\",\"isEncrypted\":true,\"isReady\":false}"
           (json/to-string (rpc/graph-json (assoc graph :schema-version (Some "v1") :e2ee true :ready false)))))))

(deftest search-json-keeps-page-and-breadcrumb-order
  (let [parent (record model/entity-summary (uuid "parent") (title "Parent"))
        page (record model/entity-summary (uuid "page") (title "Page"))
        hit (record search/indexed-search-hit (uuid "hit") (title "Hit") (is-page false) (page nil) (breadcrumbs []))]
    (is (= "{\"uuid\":\"hit\",\"title\":\"Hit\",\"isPage\":false,\"page\":null,\"breadcrumbs\":[]}"
           (json/to-string (rpc/search-hit-json hit))))
    (is (= "{\"uuid\":\"hit\",\"title\":\"Hit\",\"isPage\":true,\"page\":{\"uuid\":\"page\",\"title\":\"Page\"},\"breadcrumbs\":[{\"uuid\":\"parent\",\"title\":\"Parent\"},{\"uuid\":\"page\",\"title\":\"Page\"}]}"
           (json/to-string (rpc/search-hit-json (assoc hit :is-page true :page (Some page) :breadcrumbs [parent page])))))))

(deftest flashcard-json-keeps-counters-state-and-children
  (run! (fn [[state wire]]
          (let [card (assoc (flashcards/new-card 123) :reps 7 :lapses 2 :state state)
                due (record flashcards/due-card (block (video-block "card" "Question"))
                            (children (list (video-block "child" "Answer"))) (card card))
                encoded (rpc/flashcard-json due)]
            (is (= "123" (json-field encoded "due")))
            (is (= "7" (json-field encoded "repetitions")))
            (is (= "2" (json-field encoded "lapses")))
            (is (= (str "\"" wire "\"") (json-field encoded "state")))
            (is (= "\"card\"" (json-field (json-util/member "block" encoded) "uuid")))
            (let [child (json/to-string (rpc/block-json (video-block "child" "Answer")))]
              (is (= (str "[" child "]") (json-field encoded "children"))))))
        [(tuple flashcards/New "new") (tuple flashcards/Learning "learning")
         (tuple flashcards/Review "review") (tuple flashcards/Relearning "relearning")]))

(deftest block-json-publishes-resolved-markup-and-omits-absent-fields
  (let [block (assoc (video-block "source" "See [[target]]")
                     :references (list (record model/entity-summary (uuid "target") (title "Target block"))))
        result (rpc/block-json block)]
    (is (= "[{\"type\":\"text\",\"text\":\"See \"},{\"type\":\"nodeReference\",\"uuid\":\"target\",\"title\":\"Target block\"}]"
           (json-field result "markup")))
    (is (= ["uuid" "title" "pageId" "createdAt" "updatedAt" "syncStatus" "isAsset" "tags" "references" "breadcrumbs" "markup"]
           (vec (json-util/keys result))))))

(deftest block-json-preserves-asset-and-journal-fields
  (let [block (assoc (video-block "asset" "Photo") :order (Some "a1") :parent-id (Some "parent")
                     :is-asset true :asset-type (Some "png") :asset-size (Some 123)
                     :asset-checksum (Some "checksum") :local-path (Some "/tmp/photo.png")
                     :journal (Some (tuple "Journal" 20260816)))
        result (rpc/visible-block-json block)]
    (run! (fn [[key expected]] (is (= expected (json-field result key))))
          [(tuple "order" "\"a1\"") (tuple "parentId" "\"parent\"")
           (tuple "isAsset" "true") (tuple "assetType" "\"png\"") (tuple "assetSize" "123")
           (tuple "assetChecksum" "\"checksum\"") (tuple "localPath" "\"/tmp/photo.png\"")
           (tuple "journalTitle" "\"Journal\"") (tuple "journalDay" "20260816")])
    (is (= (json/to-string (rpc/block-json (video-block "plain" "Plain")))
           (json/to-string (rpc/visible-block-json (video-block "plain" "Plain")))))))

(deftest status-json-requires-both-icon-type-and-id
  (let [status (record model/status (uuid "todo") (title "Todo") (ident nil)
                       (icon-type nil) (icon-id nil) (icon-color nil))]
    (is (= "{\"uuid\":\"todo\",\"title\":\"Todo\"}" (json/to-string (rpc/status-response-json status))))
    (is (= "{\"uuid\":\"todo\",\"title\":\"Todo\"}"
           (json/to-string (rpc/status-response-json (assoc status :icon-type (Some "emoji") :icon-color (Some "red"))))))
    (let [rich (assoc status :ident (Some "status.todo") :icon-type (Some "emoji")
                      :icon-id (Some "check") :icon-color (Some "red"))]
      (is (= "{\"uuid\":\"todo\",\"title\":\"Todo\",\"ident\":\"status.todo\",\"icon\":{\"type\":\"emoji\",\"id\":\"check\",\"color\":\"red\"}}"
             (json/to-string (rpc/status-response-json rich)))))))

(deftest empty-outliner-state-keeps-null-and-empty-wire-fields
  (is (= "{\"editing\":null,\"selectedBlockIds\":[],\"collapsedBlockIds\":[],\"zoomedBlockIds\":[],\"autocomplete\":null}"
         (json/to-string (rpc/outliner-state-json outliner/empty)))))

(deftest outliner-state-serializes-drafts-and-orders-identifiers
  (run!
   (fn [[kind wire-kind]]
     (let [state (assoc outliner/empty
                        :editing (Some (record outliner/editor-draft (uuid "block") (expected-title "Old") (title "New") (caret 2)))
                        :selected #{"z" "a"} :collapsed #{"y" "b"} :zoomed (list "outer" "inner")
                        :autocomplete (Some (record outliner/reducer-autocomplete (kind kind) (query "query"))))]
       (is (= (str "{\"editing\":{\"uuid\":\"block\",\"title\":\"New\",\"caretUTF16Offset\":2},"
                   "\"selectedBlockIds\":[\"a\",\"z\"],\"collapsedBlockIds\":[\"b\",\"y\"],"
                   "\"zoomedBlockIds\":[\"outer\",\"inner\"],\"autocomplete\":{\"kind\":\"" wire-kind "\",\"query\":\"query\"}}")
              (json/to-string (rpc/outliner-state-json state))))))
   [(tuple outliner/Node "node") (tuple outliner/Tag "tag") (tuple outliner/Property "property")]))

(deftest platform-commands-preserve-their-json-wire-format
  (run! (fn [[command expected]]
          (is (= expected (json/to-string (rpc/outliner-command-json command)))))
        [(tuple (effects/Platform_haptic outliner/Selection) "{\"type\":\"haptic\",\"style\":\"selection\"}")
         (tuple (effects/Platform_haptic outliner/Impact) "{\"type\":\"haptic\",\"style\":\"impact\"}")
         (tuple (effects/Focus_block "block") "{\"type\":\"focusBlock\",\"uuid\":\"block\"}")
         (tuple (effects/Confirm_delete (list "first" "second")) "{\"type\":\"confirmDelete\",\"uuids\":[\"first\",\"second\"]}")
         (tuple (effects/Set_clipboard_text "a\nb") "{\"type\":\"setClipboardText\",\"text\":\"a\\nb\"}")
         (tuple (effects/Set_clipboard_references (list "x" "x")) "{\"type\":\"setClipboardReferences\",\"uuids\":[\"x\",\"x\"]}")
         (tuple (effects/Set_clipboard_urls (list)) "{\"type\":\"setClipboardURLs\",\"uuids\":[]}")
         (tuple (effects/Platform_pick_attachment "x") "{\"type\":\"pickAttachment\",\"uuid\":\"x\"}")
         (tuple (effects/Platform_take_photo "x") "{\"type\":\"takePhoto\",\"uuid\":\"x\"}")
         (tuple (effects/Platform_record_audio "x") "{\"type\":\"recordAudio\",\"uuid\":\"x\"}")]))

(deftest youtube-timestamps-follow-the-most-recent-video-across-blocks
  (is (= [(tuple "time" "https://www.youtube.com/watch?v=dQw4w9WgXcQ")]
         (rpc/youtube-target-urls [(video-block "video" "{{youtube dQw4w9WgXcQ}}")
                                   (video-block "time" "{{youtube-timestamp 01:23}}")])))
  (is (= [] (rpc/youtube-target-urls [(video-block "time" "{{youtube-timestamp 01:23}}")])))
  (is (= [] (rpc/youtube-target-urls [])))
  (is (= [(tuple "first" "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
          (tuple "second" "https://www.youtube.com/watch?v=abcdefghijk")]
         (rpc/youtube-target-urls [(video-block "video" "{{youtube dQw4w9WgXcQ}}")
                                   (video-block "first" "{{youtube-timestamp 00:10}}")
                                   (video-block "other" "{{youtube abcdefghijk}}")
                                   (video-block "second" "{{youtube-timestamp 00:20}}")]))))

(deftest youtube-targets-ignore-other-videos-and-preserve-original-url
  (is (= [(tuple "time" "https://YouTu.Be/abcdefghijk")]
         (rpc/youtube-target-urls
          [(video-block "video" "{{video https://YouTu.Be/abcdefghijk}}")
           (video-block "other" "{{vimeo 12345}}")
           (video-block "time" "{{youtube-timestamp 00:10}}")])))
  (is (= [] (rpc/youtube-target-urls
             [(video-block "other" "{{vimeo 12345}}")
              (video-block "time" "{{youtube-timestamp 00:10}}")]))))
