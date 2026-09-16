(ns logseq-chat.rpc-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [ocaml.List :as native-list]
            [ocaml.Sys :as sys]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Logseq_chat_lg_core_native :as native-core]
            [logseq-chat.rpc :as rpc]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.cache-model :as model]
            [logseq-chat.api :as api]
            [logseq-chat.search-index :as search]
            [logseq-chat.outliner-effects :as effects]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Logseq_chat_rpc :as native-rpc]
            [logseq-chat.outliner-state :as outliner]
            [logseq-chat.flashcards :as flashcards]))

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
   (native-rpc/call session
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
  (let [page (record native-core/entity-summary (uuid "page-1") (title "Page one"))
        block (assoc (native-core/logseq-chat-cache-model-local-block
                      "block-1" "Referenced block" "page-1" nil 1)
                     :parent-id (Some "page-1") :order (Some "a0")
                     :sync-status "synced" :breadcrumbs (list page))
        session (native-rpc/create
                 :graph_node_destination
                 (fn [uuid] (cond (= uuid "block-1") (Some (tuple page true))
                                  (or (= uuid "page-1") (= uuid "tag-1")) (Some (tuple page false))
                                  :else nil))
                 :graph_page_blocks (fn [uuid] (when (= uuid "page-1") (Some (list block))))
                 :graph_tag_pages (fn [] (Some (list (record native-core/entity-summary
                                                             (uuid "tag-1") (title "Tag one")))))
                 :graph_node_is_tag #(= % "tag-1")
                 :graph_node_references (fn [uuid] (when (= uuid "block-1") (Some (list block))))
                 :graph_tag_objects (fn [uuid] (when (= uuid "tag-1") (Some (list block)))))]
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
  (let [page (record native-core/entity-summary (uuid "tag-1") (title "Task"))
        tagged (assoc (native-core/logseq-chat-cache-model-local-block
                       "task-1" "Do the thing" "page-1" nil 1)
                      :parent-id (Some "page-1") :order (Some "a0") :sync-status "synced")
        linked (assoc tagged :uuid "reference-1" :title "Links Task")
        session (native-rpc/create
                 :graph_sidebar_pages (fn [] (Some (record native-core/sidebar-pages
                                                           (favorites [page]) (recent-pages []))))
                 :graph_page_blocks (fn [_] (Some (list)))
                 :graph_node_is_tag #(= % "tag-1")
                 :graph_tag_objects (fn [uuid] (when (= uuid "tag-1") (Some (list tagged))))
                 :graph_node_references (fn [uuid] (when (= uuid "tag-1") (Some (list linked)))))
        result (response-result (dispatch-json session "selectPage" "tag-1"))]
    (is (= (tag Bool true) (json-util/member "selectedPageIsTag" result)))
    (is (= (tag String "task-1") (json-util/member "uuid" (nth (json-items "relatedBlocks" result) 0))))
    (is (= (tag String "reference-1") (json-util/member "uuid" (nth (json-items "linkedReferenceBlocks" result) 0))))))

(deftest sidebar-page-selection-projects-references-without-node-routes
  (let [page (record native-core/entity-summary (uuid "page-1") (title "Page one"))
        reference (assoc (native-core/logseq-chat-cache-model-local-block
                          "reference-1" "Links Page one" "journal-1" nil 1)
                         :parent-id (Some "journal-1") :order (Some "a0") :sync-status "synced")
        session (native-rpc/create
                 :graph_sidebar_pages (fn [] (Some (record native-core/sidebar-pages
                                                           (favorites [page]) (recent-pages []))))
                 :graph_page_blocks (fn [_] (Some (list)))
                 :graph_node_references (fn [uuid] (when (= uuid "page-1") (Some (list reference)))))
        result (response-result (dispatch-json session "selectPage" "page-1"))]
    (is (= (tag Bool false) (json-util/member "selectedPageIsTag" result)))
    (is (= (tag String "reference-1") (json-util/member "uuid" (nth (json-items "relatedBlocks" result) 0))))
    (is (empty? (json-items "nodeRoutes" result)))))

(deftest search-projects-page-context-and-clears-blank-queries
  (let [page (record native-core/entity-summary (uuid "page-1") (title "Page one"))
        hit (record native-core/indexed-search-hit (uuid "block-1") (title "Search me")
                    (is-page false) (page (Some page)) (breadcrumbs [page]))
        session (native-rpc/create :graph_search (fn [query] (if (= query "search") (list hit) (list))))
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
  (let [page (record native-core/entity-summary (uuid "projected-page") (title "Projected page"))
        block (assoc (native-core/logseq-chat-cache-model-local-block
                      "projected-block" "Projected block" "projected-page" nil 1)
                     :parent-id (Some "projected-page") :order (Some "a0") :breadcrumbs (list page))
        session (native-rpc/create
                 :graph_blocks (fn [] (Some (list block)))
                 :graph_page_blocks (fn [uuid] (Some (if (= uuid "projected-page") (list block) (list))))
                 :graph_node_destination (fn [_] nil))]
    (native-rpc/call session "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")
    (run! (fn [[uuid zoomed]]
            (let [result (response-result (dispatch-json session "openNode" (str "{\"uuid\":\"" uuid "\"}")))
                  route (nth (json-items "nodeRoutes" result) 0)]
              (is (= (tag String uuid) (json-util/member "uuid" route)))
              (is (= (tag String "projected-page") (json-util/member "uuid" (json-util/member "page" route))))
              (is (= zoomed (json-items "zoomedBlockIds" (json-util/member "outlinerState" route))))
              (dispatch-json session "closeNode" "")))
          [(tuple "projected-page" []) (tuple "projected-block" [(tag String "projected-block")])])))

(deftest offline-node-navigation-uses-pending-projection-and-journal-title
  (let [block (assoc (native-core/logseq-chat-cache-model-local-block
                      "cached-block" "Cached offline block" "journal/2026-08-15" nil 1)
                     :parent-id (Some "journal/2026-08-15") :order (Some "a0")
                     :journal (Some (tuple "Aug 15th, 2026" 20260815)))
        session (native-rpc/create
                 :graph_blocks (fn [] (Some (list block)))
                 :graph_page_blocks (fn [uuid] (Some (if (= uuid "journal/2026-08-15") (list block) (list))))
                 :graph_node_destination (fn [_] nil))
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
        session (native-rpc/create :load_older_journals (fn [] (swap! window + 7) (stdlib/ignore 0))
                                   :has_older_journals (fn [] (< @window 14)))
        initial (response-result (json/from-string (native-rpc/call session "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")))]
    (is (= (tag Bool true) (json-util/member "hasOlderJournals" initial)))
    (let [expanded (response-result (dispatch-json session "loadOlderJournals" ""))]
      (is (= (tag Bool false) (json-util/member "hasOlderJournals" expanded))))))

(deftest graph-import-forwards-payload-to-storage
  (let [imported (atom [])
        session (native-rpc/create :import_snapshot
                                   (fn [payload] (swap! imported conj payload) (Ok (stdlib/ignore 0))))]
    (response-result (dispatch-json session "importSnapshot" "snapshot-payload"))
    (is (= ["snapshot-payload"] @imported))))

(deftest opening-graph-reads-authoritative-projections-once
  (let [blocks-read (atom 0)
        sidebar-read (atom 0)
        block (assoc (native-core/logseq-chat-cache-model-local-block
                      "restored-journal-block" "Restored from the graph snapshot" "journal-page" nil 1776000000000)
                     :parent-id (Some "journal-page") :order (Some "a0") :sync-status "synced"
                     :journal (Some (tuple "Aug 15th, 2026" 20260815)))
        session (native-rpc/create
                 :open_graph (fn [_] (Ok (stdlib/ignore 0)))
                 :graph_blocks (fn [] (swap! blocks-read inc) (Some (list block)))
                 :graph_sidebar_pages (fn [] (swap! sidebar-read inc)
                                        (Some (record native-core/sidebar-pages (favorites []) (recent-pages [])))))
        result (response-result (dispatch-json session "openGraph" "{}"))
        blocks (json-items "blocks" result)]
    (is (= 1 @blocks-read))
    (is (= 1 @sidebar-read))
    (is (= 1 (count blocks)))
    (is (= (tag String "restored-journal-block") (json-util/member "uuid" (nth blocks 0))))
    (is (= (tag Int 20260815) (json-util/member "journalDay" (nth blocks 0))))))

(deftest graph-storage-errors-preserve-codes-and-payload-priority
  (let [missing (native-rpc/create)
        calls (atom [])
        rejecting (native-rpc/create
                   :import_snapshot (fn [payload] (swap! calls conj payload) (Error "import rejected"))
                   :open_graph (fn [payload] (swap! calls conj payload) (Error "open rejected")))]
    (run! (fn [[action unavailable failed message]]
            (let [no-payload (str "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"" action "\"}}")
                  unavailable-error (json-util/member "error" (json/from-string (native-rpc/call missing no-payload)))
                  required-error (json-util/member "error" (json/from-string (native-rpc/call rejecting no-payload)))
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
        session (native-rpc/create
                 :import_snapshot (fn [payload] (swap! stored conj payload) (Ok (stdlib/ignore 0)))
                 :open_graph (fn [payload] (swap! stored conj payload) (Ok (stdlib/ignore 0)))
                 :model_for_graph (fn [graph-id] (swap! projected conj graph-id)
                                    (native-core/logseq-chat-cache-model-create nil)))]
    (run! (fn [action]
            (let [error (json-util/member "error" (dispatch-json session action "{}"))]
              (is (= (tag String "graph_projection_failed") (json-util/member "code" error)))
              (is (= (tag String "graph storage payload requires graphId") (json-util/member "message" error)))))
          ["importSnapshot" "openGraph"])
    (is (= ["{}" "{}"] @stored))
    (is (empty? @projected))))

(deftest websocket-lifecycle-applies-events-exactly-once
  (let [applied (atom [])
        session (native-rpc/create :apply_sync_event
                                   (fn [payload] (swap! applied conj payload) (Ok (stdlib/ignore 0))))]
    (response-result (dispatch-json session "startWebSocket" ""))
    (response-result (dispatch-json session "applySyncEvent" "wire-event"))
    (response-result (dispatch-json session "stopWebSocket" ""))
    (is (= ["wire-event"] @applied))))

(deftest websocket-self-echo-clears-local-pending-capture
  (let [authoritative (atom [])
        block (assoc (native-core/logseq-chat-cache-model-local-block
                      "local-self-echo" "Synced capture" "journal/2026-08-15" nil 1776000000000)
                     :sync-status "synced")
        session (native-rpc/create
                 :graph_blocks (fn [] (Some (apply list @authoritative)))
                 :apply_sync_event (fn [_] (reset! authoritative [block]) (Ok (stdlib/ignore 0))))]
    (dispatch-json session "send" "{\"text\":\"Synced capture\",\"uuid\":\"local-self-echo\",\"now\":1776000000000}")
    (is (= 1 (count (native-core/logseq-chat-cache-model-pending-blocks (:model session)))))
    (response-result (dispatch-json session "applySyncEvent" "self-echo"))
    (is (empty? (native-core/logseq-chat-cache-model-pending-blocks (:model session))))))

(deftest authoritative-assets-retain-cached-local-file-path
  (let [authoritative (atom [])
        session (native-rpc/create :graph_blocks (fn [] (Some (apply list @authoritative))))]
    (dispatch-json session "addAsset"
                   "{\"uuid\":\"synced-asset\",\"title\":\"photo.png\",\"now\":1776000000001,\"assetType\":\"png\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/photo.png\"}")
    (native-core/logseq-chat-cache-model-mark-block-synced (:model session) "synced-asset")
    (reset! authoritative [(assoc (native-core/logseq-chat-cache-model-local-block
                                  "synced-asset" "photo.png" "journal/2026-08-15" nil 1776000000001)
                                 :sync-status "synced" :journal (Some (tuple "Aug 15th, 2026" 20260815)))])
    (let [blocks (json-items "blocks" (response-result (dispatch-json session "clearRelated" "")))]
      (is (= 1 (count blocks)))
      (is (= (tag String "/documents/photo.png") (json-util/member "localPath" (nth blocks 0)))))))

(deftest task-status-updates-preserve-custom-icon-color
  (let [session (native-rpc/create)]
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
  (let [editing (assoc (native-core/logseq-chat-cache-model-local-block
                        "editing-sync" "Local draft" "page" (Some "page") 1)
                       :order (Some "a0") :sync-status "synced")
        remote (assoc editing :uuid "remote-sync" :title "Before")
        authoritative (atom [editing remote])
        session (native-rpc/create
                 :graph_blocks (fn [] (Some (apply list @authoritative)))
                 :apply_sync_event (fn [_]
                                     (reset! authoritative [editing (assoc remote :title "After")])
                                     (Ok (stdlib/ignore 0))))]
    (dispatch-json session "outlinerEvent" "{\"type\":\"tapBlock\",\"uuid\":\"editing-sync\"}")
    (let [result (response-result (dispatch-json session "applySyncEvent" "remote-change"))
          active-editor (json-util/member "editing" (json-util/member "outlinerState" result))]
      (is (= (tag String "editing-sync") (json-util/member "uuid" active-editor)))
      (is (some (fn [row]
                  (let [block (json-util/member "block" row)]
                    (and (= (tag String "remote-sync") (json-util/member "uuid" block))
                         (= (tag String "After") (json-util/member "title" block)))))
                (json-items "outlinerRows" result))))))

(deftest websocket-errors-distinguish-snapshot-recovery-from-apply-failures
  (run! (fn [[message code]]
          (let [session (native-rpc/create :apply_sync_event (fn [_] (Error message)))
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
        unavailable (native-rpc/create)
        available (native-rpc/create :apply_sync_event (fn [_] (Ok (stdlib/ignore 0))))]
    (is (= (tag String "websocket_unavailable")
           (json-util/member "code" (json-util/member "error" (json/from-string (native-rpc/call unavailable wire))))))
    (is (= (tag String "invalid_params")
           (json-util/member "code" (json-util/member "error" (json/from-string (native-rpc/call available wire))))))))

(defn pending-request [response]
  (let [value (json-util/member "pendingSyncRequest" (json-util/member "result" response))]
    (match value (tag Null) nil _ (Some value))))

(def plain-graph-catalog
  "{\"graphs\":[{\"graph-id\":\"plain-1\",\"graph-name\":\"Plain\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true}]}")

(defn plain-session []
  (let [session (native-rpc/create :load_graph_catalog (fn [] (Some plain-graph-catalog)))]
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
    (if-some [block (native-core/logseq-chat-cache-model-read-block (:model session) "failed-async")]
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
  (let [status (record native-core/status (uuid "todo") (title "Todo") (ident nil)
                       (icon-type nil) (icon-id nil) (icon-color nil))
        block (assoc (native-core/logseq-chat-cache-model-local-block "remote-task" "Old title" "journal-page" nil 1776000000000)
                     :sync-status "synced" :status (Some status))
        session (native-rpc/create
                 :load_graph_catalog (fn [] (Some "{\"graphs\":[{\"graph-id\":\"plain-1\",\"graph-name\":\"Plain\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true}]}"))
                 :graph_blocks (fn [] (Some (list block))))]
    (dispatch-json session "configure" "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}")
    (native-core/logseq-chat-cache-model-upsert-blocks
      (:model session) (tuple native-list/to-seq (list block)) (:updated-at block))
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
    (if-some [updated (native-core/logseq-chat-cache-model-read-block (:model session) "remote-task")]
      (is (= "submitted" (:sync-status updated)))
      (is false))))

(deftest encrypted-graph-creation-provisions-uploads-and-cleans-up-in-order
  (let [created (atom false)
        provisioned (atom nil)
        events (atom [])
        uploaded-path (atom nil)
        session
        (native-rpc/create
          :send (fn [request]
                  (cond
                    (and (= (:method_ request) "POST") (string/ends-with? (:url request) "/graphs"))
                    (do (swap! events conj "create")
                        (reset! created true)
                        (Ok (native-core/logseq-chat-api-response 201 "{\"graph-id\":\"new-private\"}")))
                    (string/ends-with? (:url request) "/graphs")
                    (do (swap! events conj "discover")
                        (Ok (native-core/logseq-chat-api-response 200
                              (if @created
                                "{\"graphs\":[{\"graph-id\":\"new-private\",\"graph-name\":\"Private notes\",\"schema-version\":\"65.33\",\"graph-e2ee?\":true,\"graph-ready-for-use?\":true}]}"
                                "{\"graphs\":[]}"))))
                    :else (Error (str "unexpected request: " (:url request)))))
          :provision_graph_key (fn [config]
                                 (swap! events conj "provision")
                                 (reset! provisioned (Some (:graph_id config)))
                                 (Ok (stdlib/ignore 0)))
          :encrypt_title (fn [_graph-id value] (Ok (str "encrypted:" value)))
          :upload_file (fn [upload]
                         (swap! events conj "upload")
                         (reset! uploaded-path (Some (:file_path upload)))
                         (is (sys/file-exists (:file_path upload)))
                         (is (string/includes? (:url (:request upload)) "?"))
                         (is (string/ends-with? (:url (:request upload)) "checksum=0000000000000000"))
                         (is (= "application/transit+json" (:content_type upload)))
                         (Ok (native-core/logseq-chat-api-response 200 "{\"ok\":true,\"count\":8}"))))]
    (dispatch-json session "configure" "{\"baseUrl\":\"https://api.example\",\"graphId\":\"\",\"token\":\"access\"}")
    (is (json-util/to-bool (json-util/member "ok"
                           (dispatch-json session "createSyncGraph" "{\"name\":\"Private notes\",\"isEncrypted\":true}"))))
    (is (= (Some "new-private") @provisioned))
    (is (= ["create" "provision" "upload" "discover"] @events))
    (if-some [path @uploaded-path] (is (not (sys/file-exists path))) (is false))))

(deftest semantic-capture-pump-never-calls-blocking-transport
  (let [legacy-send-count (atom 0)
        staged (atom [])
        session (native-rpc/create
                  :load_graph_catalog (fn [] (Some plain-graph-catalog))
                  :sync_cursor (fn [] (Some 91))
                  :journal_page_id (fn [_day] (Some "journal-page"))
                  :stage_operation (fn [operation]
                                     (swap! staged
                                       (fn [operations]
                                         (into [operation]
                                           (remove #(= (:operation_id %) (:operation_id operation)) operations))))
                                     (Ok (stdlib/ignore 0)))
                  :prepare_operation (fn [operation]
                                       (Ok (tuple (native-core/logseq-chat-pending-ops-outliner-op (:intent operation)) "[]")))
                  :pending_operations (fn [] (apply list (reverse @staged)))
                  :send (fn [_request]
                          (swap! legacy-send-count inc)
                          (stdlib/failwith "asynchronous pending pump called the blocking transport")))]
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
        session (native-rpc/create
                  :load_graph_catalog (fn [] (Some "{\"graphs\":[{\"graph-id\":\"encrypted-1\",\"graph-name\":\"Private\",\"graph-e2ee?\":true,\"graph-ready-for-use?\":true}]}"))
                  :graph_unlocked (fn [_graph-id] true)
                  :sync_cursor (fn [] (Some 91))
                  :journal_page_id (fn [_day] nil)
                  :stage_operation (fn [operation] (swap! staged conj operation) (Ok (stdlib/ignore 0)))
                  :prepare_operation (fn [operation]
                                       (Ok (tuple (native-core/logseq-chat-pending-ops-outliner-op (:intent operation)) "[]"))))]
    (dispatch-json session "configure" "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"\",\"token\":\"access\"}")
    (dispatch-json session "selectGraph" "encrypted-1")
    (dispatch-json session "sendTask"
      "{\"text\":\"Secret task\",\"uuid\":\"encrypted-async\",\"now\":1776000000000,\"status\":{\"uuid\":\"todo\",\"title\":\"Todo\"}}")
    (is (= 2 (count @staged)))
    (match (:intent (nth @staged 0))
      (native-core/Create_journal journal)
      (do (is (= "encrypted-async" (:block_uuid journal)))
          (is (= "Secret task" (:title journal))))
      _ (is false))
    (match (:intent (nth @staged 1))
      (native-core/Set_property property)
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
        session (native-rpc/create
                 :send (fn [request]
                         (cond
                           (and (= (:method_ request) "POST") (string/ends-with? (:url request) "/graphs"))
                           (Ok (native-core/logseq-chat-api-response 201 "{\"graph-id\":\"upload-fails\"}"))
                           (string/ends-with? (:url request) "/graphs")
                           (do (reset! discovered true)
                               (Ok (native-core/logseq-chat-api-response 200 "{\"graphs\":[]}")))
                           :else (Error (str "unexpected request: " (:url request)))))
                 :upload_file (fn [_upload] (Error "offline during initial snapshot upload")))]
    (native-rpc/call session
                     "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"configure\",\"payload\":\"{\\\"baseUrl\\\":\\\"https://api.example\\\",\\\"graphId\\\":\\\"\\\",\\\"token\\\":\\\"access\\\"}\"}}")
    (let [response (json/from-string
                    (native-rpc/call session
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

(deftest targeted-assets-appear-immediately-in-selected-page-projection
  (let [page (record native-core/entity-summary (uuid "selected-page") (title "Selected page"))
        parent (assoc (native-core/logseq-chat-cache-model-local-block
                       "page-parent" "Parent" "selected-page" nil 1)
                      :parent-id (Some "selected-page") :order (Some "a0") :sync-status "synced")
        projected (atom [parent])
        session (configure-plain-session
                 (native-rpc/create
                  :load_graph_catalog (fn [] (Some plain-graph-catalog))
                  :sync_cursor (fn [] (Some 5))
                  :graph_sidebar_pages (fn [] (Some (record native-core/sidebar-pages
                                                           (favorites [page]) (recent-pages []))))
                  :graph_page_blocks (fn [uuid] (Some (if (= uuid "selected-page") (apply list @projected) (list))))
                  :stage_operation
                  (fn [operation]
                    (match (:intent operation)
                      (native-core/Create_asset asset)
                      (swap! projected conj
                             (assoc (native-core/logseq-chat-cache-model-local-block
                                     (:uuid asset) (:title asset) (:page-uuid asset) (Some (:parent-uuid asset)) (:created-at asset))
                                    :order (Some (:order asset)) :is-asset true
                                    :asset-type (Some (:asset-type asset)) :asset-size (Some (:asset-size asset))
                                    :asset-checksum (Some (:asset-checksum asset))))
                      _ (stdlib/failwith "asset projection must stage Create_asset"))
                    (Ok (stdlib/ignore 0)))
                  :prepare_operation (fn [operation]
                                       (Ok (tuple (native-core/logseq-chat-pending-ops-outliner-op (:intent operation)) "[]")))))]
    (response-result (dispatch-json session "selectPage" "selected-page"))
    (let [result (response-result
                  (dispatch-json session "addAsset"
                                 "{\"uuid\":\"visible-asset\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"page-parent\"}"))]
      (is (some #(= (tag String "visible-asset") (json-util/member "uuid" (json-util/member "block" %)))
                (json-items "outlinerRows" result))))))

(deftest task-and-asset-capture-return-optimistic-blocks
  (run! (fn [[action payload uuid]]
          (let [result (response-result (dispatch-json (native-rpc/create) action payload))
                blocks (json-items "blocks" result)]
            (is (= (tag String uuid) (json-util/member "uuid" (nth blocks 0))))))
        [(tuple "sendTask"
                "{\"text\":\"Follow up\",\"uuid\":\"task-local\",\"now\":1776000000000,\"status\":{\"uuid\":\"status-waiting\",\"ident\":\"user.status/waiting\",\"title\":\"Waiting\",\"iconType\":\"tabler-icon\",\"iconId\":\"clock\"}}"
                "task-local")
         (tuple "addAsset"
                "{\"uuid\":\"asset-local\",\"title\":\"photo.jpg\",\"now\":1776000000001,\"assetType\":\"jpg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/photo.jpg\"}"
                "asset-local")]))

(deftest targeted-assets-retain-parent-and-page-from-cached-block
  (let [session (native-rpc/create)
        target (assoc (native-core/logseq-chat-cache-model-local-block
                       "editing-block" "Editing" "target-page" nil 1)
                      :parent-id (Some "target-page") :sync-status "synced")]
    (native-core/logseq-chat-cache-model-upsert-blocks (:model session) (tuple native-list/to-seq (list target)) 1)
    (dispatch-json session "addAsset"
                   "{\"uuid\":\"targeted-asset\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}")
    (if-some [asset (native-core/logseq-chat-cache-model-read-block (:model session) "targeted-asset")]
      (do (is (= "target-page" (:page-id asset)))
          (is (= (Some "editing-block") (:parent-id asset))))
      (is false))))

(deftest targeted-asset-upload-uses-stable-block-uuid
  (let [target (assoc (native-core/logseq-chat-cache-model-local-block
                       "editing-block" "Editing" "local-page" nil 1)
                      :parent-id (Some "local-page") :sync-status "synced")
        session (configure-plain-session
                 (native-rpc/create :load_graph_catalog (fn [] (Some plain-graph-catalog))
                                    :graph_blocks (fn [] (Some (list target)))))]
    (dispatch-json session "addAsset"
                   "{\"uuid\":\"targeted-upload\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}")
    (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (is (= (tag String "http://127.0.0.1:8787/assets/plain-1/targeted-upload.m4a") (json-util/member "url" request)))
      (is false))))

(deftest shared-images-insert-bounded-row-patches-and-normalize-upload-type
  (let [session (configure-plain-session (native-rpc/create :load_graph_catalog (fn [] (Some plain-graph-catalog))))
        result (response-result
                (dispatch-json session "addAsset"
                               "{\"uuid\":\"shared-image\",\"title\":\"IMG_0002\",\"now\":2,\"assetType\":\"image/jpeg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"Assets/shared-IMG_0002.JPG\"}"))
        splices (json-items "outlinerRowSplices" result)
        rows (json-items "rows" (nth splices 0))]
    (is (= (tag Bool true) (json-util/member "isOutlinerPatch" result)))
    (is (= 1 (count splices)))
    (is (= 1 (count rows)))
    (is (= (tag String "shared-image") (json-util/member "uuid" (json-util/member "block" (nth rows 0)))))
    (if-some [asset (native-core/logseq-chat-cache-model-read-block (:model session) "shared-image")]
      (is (= (Some "jpeg") (:asset-type asset)))
      (is false))
    (if-some [request (pending-request (dispatch-json session "beginPendingSync" ""))]
      (do (is (= (tag String "http://127.0.0.1:8787/assets/plain-1/shared-image.jpeg") (json-util/member "url" request)))
          (is (= (tag String "image/jpeg") (json-util/member "contentType" request))))
      (is false))))

(deftest pending-assets-wait-for-authentication-and-resume-after-configuration
  (let [session (native-rpc/create)]
    (dispatch-json session "configure" "{\"baseUrl\":\"https://api.example\",\"graphId\":\"plain-1\",\"token\":\"\"}")
    (dispatch-json session "addAsset"
                   "{\"uuid\":\"offline-shared-image\",\"title\":\"IMG_0002.JPG\",\"now\":2,\"assetType\":\"image/jpeg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"Assets/shared-IMG_0002.JPG\"}")
    (is (nil? (pending-request (dispatch-json session "beginPendingSync" ""))))
    (configure-plain-session session)
    (is (some? (pending-request (dispatch-json session "beginPendingSync" ""))))))

(deftest asset-payload-errors-do-not-create-local-blocks
  (let [session (native-rpc/create)]
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
    (is (nil? (native-core/logseq-chat-cache-model-read-block (:model session) "bad")))
    (run! (fn [[payload code message]]
            (let [error (json-util/member "error" (dispatch-json session "addAsset" payload))]
              (is (= (tag String code) (json-util/member "code" error)))
              (is (= (tag String message) (json-util/member "message" error)))))
          [(tuple "[]" "invalid_params" "addAsset payload must be an object")
           (tuple "{" "invalid_json" "addAsset payload must be valid JSON")])
    (let [error (json-util/member "error" (json/from-string (native-rpc/call session
                         "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"addAsset\"}}")))]
      (is (= (tag String "invalid_params") (json-util/member "code" error)))
      (is (= (tag String "addAsset requires a JSON payload") (json-util/member "message" error))))))

(deftest asset-staging-errors-preserve-cached-file-and-error-category
  (run! (fn [[cursor code message]]
          (let [staged (atom 0)
                session (configure-plain-session
                         (native-rpc/create
                          :sync_cursor (fn [] cursor)
                          :journal_page_id (fn [_] (Some "journal"))
                          :stage_operation (fn [_] (swap! staged inc) (Error "stage rejected"))))
                error (json-util/member "error"
                        (dispatch-json session "addAsset"
                          "{\"uuid\":\"staged-asset\",\"title\":\"Photo\",\"now\":1776000000000,\"assetType\":\"png\",\"assetSize\":12,\"assetChecksum\":\"hash\",\"localPath\":\"/local/photo.png\"}"))]
            (is (= (tag String code) (json-util/member "code" error)))
            (is (= (tag String message) (json-util/member "message" error)))
            (is (= (if (some? cursor) 1 0) @staged))
            (if-some [asset (native-core/logseq-chat-cache-model-read-block (:model session) "staged-asset")]
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
          (let [page (record native-core/entity-summary (uuid page-id) (title "Aug 23rd, 2026"))
                journal (if capture? (Some (tuple "Aug 23rd, 2026" 20260823)) nil)
                parent (assoc (native-core/logseq-chat-cache-model-local-block
                               parent-id "Parent" page-id (Some page-id) 1)
                              :sync-status "synced" :order (Some "a0") :journal journal)
                projected (atom [parent])
                staged (atom [])
                session (configure-plain-session
                         (native-rpc/create
                          :load_graph_catalog (fn [] (Some plain-graph-catalog))
                          :sync_cursor (fn [] (Some 5))
                          :journal_page_id (fn [_] (Some page-id))
                          :graph_blocks (fn [] (Some (apply list @projected)))
                          :graph_page_blocks (fn [id] (Some (apply list (filter #(= (:page-id %) id) @projected))))
                          :graph_node_destination (fn [id] (when (= id page-id) (Some (tuple page false))))
                          :stage_operation
                          (fn [operation]
                            (match (:intent operation)
                              (native-core/Insert_block value)
                              (do
                                (swap! staged conj (tuple (:uuid value) (:page-uuid value) (:parent-uuid value)))
                                (swap! projected conj
                                       (assoc (native-core/logseq-chat-cache-model-local-block
                                               (:uuid value) (:title value) (:page-uuid value)
                                               (Some (:parent-uuid value)) (:created-at value))
                                              :order (Some (:order value)) :journal journal)))
                              _ (stdlib/failwith "local insertion must stage Insert_block"))
                            (Ok (stdlib/ignore 0)))
                          :prepare_operation (fn [operation]
                                               (Ok (tuple (native-core/logseq-chat-pending-ops-outliner-op (:intent operation)) "[]")))))
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
  (let [projected (assoc (native-core/logseq-chat-cache-model-local-block
                         "projected-only" "Projected" "page" (Some "page") 1)
                        :sync-status "synced" :order (Some "a0"))
        session (native-rpc/create :load_graph_catalog (fn [] (Some plain-graph-catalog))
                                   :graph_blocks (fn [] (Some (list projected))))]
    (native-core/logseq-chat-cache-model-cache-local-message (:model session) "legacy-only" "Must not leak" 10)
    (configure-plain-session session)
    (let [result (response-result (dispatch-json session "configure"
                                   "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}"))]
      (is (not (some #(= (tag String "legacy-only") (json-util/member "uuid" %)) (json-items "blocks" result)))))))

(deftest page-favorite-updates-sidebar-and-preserves-operation-fields
  (let [favorite (atom false)
        calls (atom [])
        page (record native-core/entity-summary (uuid "page-favorite") (title "Favorite me"))
        session (configure-plain-session
                 (native-rpc/create
                  :load_graph_catalog (fn [] (Some plain-graph-catalog))
                  :graph_sidebar_pages
                  (fn [] (Some (record native-core/sidebar-pages
                                       (favorites (if @favorite [page] [])) (recent-pages [page]))))
                  :graph_set_page_favorite
                  (fn [page-uuid value operation-id now]
                    (swap! calls conj (tuple page-uuid value operation-id now))
                    (reset! favorite value)
                    (Ok (stdlib/ignore 0)))))]
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
        page (record native-core/entity-summary (uuid "page-delete") (title "Delete me"))
        session (configure-plain-session
                 (native-rpc/create
                  :load_graph_catalog (fn [] (Some plain-graph-catalog))
                  :graph_sidebar_pages
                  (fn [] (Some (record native-core/sidebar-pages
                                  (favorites []) (recent-pages (if (empty? @deleted) [page] [])))))
                  :graph_delete_page
                  (fn [page-uuid operation-id now]
                     (swap! deleted conj (tuple page-uuid operation-id now))
                    (Ok (stdlib/ignore 0)))))
        response (dispatch-json session "deletePage"
                                "{\"pageUuid\":\"page-delete\",\"operationId\":\"delete-page-op\",\"now\":100}")]
    (is (json-util/to-bool (json-util/member "ok" response)))
    (is (empty? (json-util/to-list (json-util/member "recentPages" (json-util/member "result" response)))))
    (is (= [(tuple "page-delete" "delete-page-op" 100)] @deleted))))

(deftest flashcard-review-removes-due-card-and-preserves-operation-fields
  (let [now 1776000000000
        reviewed (atom [])
        due-card (record native-core/due-card
                         (block (native-core/logseq-chat-cache-model-local-block
                                 "flashcard" "Question {{cloze answer}}" "page" nil now))
                   (children (list)) (card (native-core/logseq-chat-flashcards-new-card now)))
        session (configure-plain-session
                 (native-rpc/create
                  :load_graph_catalog (fn [] (Some plain-graph-catalog))
                   :graph_due_flashcards (fn [_] (if (empty? @reviewed) (list due-card) (list)))
                  :graph_review_flashcard
                  (fn [uuid rating at operation-id]
                     (swap! reviewed conj (tuple uuid rating at operation-id))
                    (Ok (stdlib/ignore 0)))))]
    (dispatch-json session "loadFlashcards" "1776000000000")
    (let [response (dispatch-json session "reviewFlashcard"
                                  "{\"uuid\":\"flashcard\",\"rating\":\"good\",\"now\":1776000000000,\"operationId\":\"review-op\"}")]
      (is (json-util/to-bool (json-util/member "ok" response)))
      (is (empty? (json-util/to-list (json-util/member "flashcards" (json-util/member "result" response))))))
    (is (= [(tuple "flashcard" (native-core/Good) now "review-op")] @reviewed))))

(deftest page-and-review-actions-validate-before-calling-services
  (let [calls (atom 0)
        session (configure-plain-session
                 (native-rpc/create
                  :graph_set_page_favorite (fn [_ _ _ _] (swap! calls inc) (Ok (stdlib/ignore 0)))
                  :graph_delete_page (fn [_ _ _] (swap! calls inc) (Ok (stdlib/ignore 0)))
                  :graph_review_flashcard (fn [_ _ _ _] (swap! calls inc) (Ok (stdlib/ignore 0)))))]
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
                 (native-rpc/create
                  :graph_set_page_favorite (fn [_ _ _ _] (Error "favorite rejected"))
                  :graph_delete_page (fn [_ _ _] (Error "delete rejected"))
                  :graph_review_flashcard (fn [_ _ _ _] (Error "review rejected"))))]
    (run! (fn [[action wire code message]]
            (let [response (dispatch-json session action wire)]
              (is (= code (response-error-code response)))
              (is (= message (json-util/to-string (json-util/member "message" (json-util/member "error" response)))))))
          [(tuple "setPageFavorite" "{\"pageUuid\":\"p\",\"favorite\":true,\"operationId\":\"op\"}" "set_page_favorite_failed" "favorite rejected")
           (tuple "deletePage" "{\"pageUuid\":\"p\",\"operationId\":\"op\"}" "delete_page_failed" "delete rejected")
           (tuple "reviewFlashcard" "{\"uuid\":\"c\",\"rating\":\"good\",\"operationId\":\"op\"}" "flashcard_review_failed" "review rejected")]))
  (let [session (native-rpc/create)]
    (run! (fn [[action code]]
            (is (= code (response-error-code (dispatch-json session action "{}")))))
          [(tuple "setPageFavorite" "set_page_favorite_unavailable")
           (tuple "deletePage" "delete_page_unavailable")
           (tuple "reviewFlashcard" "flashcards_unavailable")])))

(deftest page-and-review-actions-preserve-precondition-priority
  (let [calls (atom 0)
        session (native-rpc/create
                 :graph_set_page_favorite (fn [_ _ _ _] (swap! calls inc) (Ok (stdlib/ignore 0)))
                 :graph_delete_page (fn [_ _ _] (swap! calls inc) (Ok (stdlib/ignore 0))))]
    (run! (fn [action]
            (is (= "graph_not_configured" (response-error-code (dispatch-json session action "{")))))
          ["setPageFavorite" "deletePage"])
    (run! (fn [action]
            (let [response (json/from-string
                            (native-rpc/call session
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
                 (native-rpc/create
                  :graph_delete_page (fn [_ _ _] (throw (Failure "service crashed")))))
        response (dispatch-json session "deletePage" "{\"pageUuid\":\"p\",\"operationId\":\"op\"}")]
    (is (= "invalid_json" (response-error-code response)))
    (is (= "request must be valid JSON"
           (json-util/to-string (json-util/member "message" (json-util/member "error" response)))))))

(def remote-feed
  "{\"blocks\":[{\"uuid\":\"remote\",\"title\":\"Remote text\",\"page-id\":\"journal\",\"parent-id\":\"journal\",\"created-at\":10,\"updated-at\":20}],\"journals\":[{\"uuid\":\"journal\",\"title\":\"Today\",\"journal-day\":20260916}]}")

(defn refresh-session [send]
  (let [session (native-rpc/create :load_graph_catalog (fn [] (Some plain-graph-catalog)) :send send)]
    (dispatch-json session "configure" "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}")
    session))

(deftest refresh-caches-blocks-journals-and-statuses-in-request-order
  (let [requests (atom [])
        session (refresh-session
                  (fn [request]
                    (swap! requests conj (:url request))
                    (is (= "GET" (:method_ request)))
                    (is (= "access" (:token request)))
                    (Ok (native-core/logseq-chat-api-response 200
                          (if (= 1 (count @requests)) remote-feed
                            "{\"choices\":[{\"uuid\":\"todo\",\"title\":\"Todo\",\"ident\":\"logseq.property/status.todo\"}]}")))))
        response (dispatch-json session "refresh" "")]
    (is (json-util/to-bool (json-util/member "ok" response)))
    (is (= 2 (count @requests)))
    (is (string/includes? (nth @requests 0) "/blocks?journal-only=true&journal-day-at-most="))
    (is (string/ends-with? (nth @requests 1) "/search?q=Status&types=properties&limit=100"))
    (if-some [block (native-core/logseq-chat-cache-model-read-block (:model session) "remote")]
      (do (is (= "Remote text" (:title block)))
          (is (= "synced" (:sync-status block)))
          (is (= 20 (:updated-at block))))
      (is false))
    (is (= (Some (tuple "Today" 20260916))
           (native-core/logseq-chat-cache-model-journal-metadata (:model session) "journal")))
    (is (= ["todo"] (mapv :uuid (native-core/logseq-chat-cache-model-all-statuses (:model session)))))))

(deftest refresh-stops-before-status-request-when-blocks-request-fails
  (run! (fn [transport-failure?]
          (let [requests (atom 0)
                session (refresh-session
                          (fn [_]
                            (swap! requests inc)
                            (if transport-failure? (Error "offline")
                              (Ok (native-core/logseq-chat-api-response 503 "bad gateway")))))
                response (dispatch-json session "refresh" "")]
            (is (= "remote_refresh_failed" (response-error-code response)))
            (is (= 1 @requests))
            (is (nil? (native-core/logseq-chat-cache-model-read-block (:model session) "remote")))))
        [true false]))

(deftest refresh-status-failure-preserves-already-cached-blocks
  (run! (fn [transport-failure?]
          (let [requests (atom 0)
                session (refresh-session
                          (fn [_]
                            (if (= 1 (swap! requests inc))
                              (Ok (native-core/logseq-chat-api-response 200 remote-feed))
                              (if transport-failure? (Error "offline")
                                (Ok (native-core/logseq-chat-api-response 503 "bad gateway"))))))
                response (dispatch-json session "refresh" "")]
            (is (= "remote_statuses_failed" (response-error-code response)))
            (is (= 2 @requests))
            (is (some? (native-core/logseq-chat-cache-model-read-block (:model session) "remote")))))
        [true false]))

(deftest refresh-malformed-json-preserves-error-and-partial-cache-semantics
  (run! (fn [malformed-blocks?]
          (let [requests (atom 0)
                session (refresh-session
                          (fn [_]
                            (let [first? (= 1 (swap! requests inc))]
                              (Ok (native-core/logseq-chat-api-response 200
                                    (if (and first? (not malformed-blocks?)) remote-feed "not json"))))))
                response (dispatch-json session "refresh" "")]
            (is (= "invalid_json" (response-error-code response)))
            (is (= (if malformed-blocks? 1 2) @requests))
            (is (= (not malformed-blocks?)
                   (some? (native-core/logseq-chat-cache-model-read-block (:model session) "remote"))))))
        [true false]))

(deftest optimistic-capture-is-returned-before-sync
  (let [session (native-rpc/create)
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
        session (native-rpc/create
                  :journal_page_id (fn [_day] (swap! calls inc) nil))]
    (is (= (Error "A current server cursor is required")
           (native-rpc/capture-operations session :uuid "b" :title "Text" :now 1776000000000)))
    (is (= 0 @calls))))

(defn native-asset [uuid]
  (assoc (native-core/logseq-chat-cache-model-local-block uuid "photo.jpg" "local-page" nil 1776000000000)
         :is-asset true :asset-type (Some "jpg") :asset-size (Some 2048)
         :asset-checksum (Some "checksum") :local-path (Some "Assets/photo.jpg")))

(deftest asset-operation-rejects-missing-cursor-before-loading-destination
  (let [loads (atom 0)
        session (native-rpc/create
                  :graph_blocks (fn [] (swap! loads inc) (Some (list)))
                  :journal_page_id (fn [_day] (swap! loads inc) (Some "journal")))]
    (is (= (Error "A current server cursor is required")
           (native-rpc/asset-datoms-operation session (native-asset "a"))))
    (is (= 0 @loads))))

(deftest asset-operation-rejects-incomplete-metadata-before-loading-destination
  (let [loads (atom 0)
        session (native-rpc/create
                  :sync_cursor (fn [] (Some 7))
                  :graph_blocks (fn [] (swap! loads inc) (Some (list)))
                  :journal_page_id (fn [_day] (swap! loads inc) (Some "journal")))
        asset (native-asset "a")]
    (run! (fn [block]
            (is (= (Error "asset metadata is incomplete")
                   (native-rpc/asset-datoms-operation session block))))
          [(assoc asset :asset-type nil) (assoc asset :asset-size nil)
           (assoc asset :asset-checksum nil)])
    (is (= 0 @loads))))

(deftest asset-operation-does-not-fallback-from-missing-parent-to-journal
  (let [journal-lookups (atom 0)
        session (native-rpc/create
                  :sync_cursor (fn [] (Some 7))
                  :journal_page_id (fn [_day]
                                     (swap! journal-lookups inc)
                                     (Some "journal")))]
    (is (= (Error "asset destination is not available")
           (native-rpc/asset-datoms-operation session
             (assoc (native-asset "a") :parent-id (Some "missing")))))
    (is (= 0 @journal-lookups))))

(deftest asset-operation-uses-journal-date-and-preserves-durable-metadata
  (let [days (atom [])
        session (native-rpc/create
                  :sync_cursor (fn [] (Some 7))
                  :journal_page_id (fn [day] (swap! days conj day) (Some "journal")))
        asset (native-asset "a")]
    (match (native-rpc/asset-datoms-operation :state (native-core/Applied) session asset)
      (Ok operation)
      (do (is (= "asset:a" (:operation-id operation)))
          (is (= 7 (:base-t operation)))
          (is (= (native-core/Applied) (:state operation)))
          (match (:intent operation)
            (native-core/Create_asset value)
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
    (is (= [(native-core/logseq-chat-cache-model-journal-day-for-ms (:created-at asset))] @days))))

(deftest asset-operation-orders-after-siblings-without-counting-itself
  (let [parent (native-core/logseq-chat-cache-model-local-block "parent" "Parent" "page" nil 1)
        sibling (assoc parent :uuid "sibling" :parent-id (Some "parent") :order (Some "a2"))
        earlier (assoc sibling :uuid "earlier" :order (Some "a0"))
        other-page (assoc sibling :uuid "other-page" :page-id "elsewhere" :order (Some "zZ"))
        other-parent (assoc sibling :uuid "other-parent" :parent-id (Some "elsewhere") :order (Some "zZ"))
        unordered (assoc sibling :uuid "unordered" :order nil)
        asset (assoc (native-asset "a") :parent-id (Some "parent") :page-id "page" :order (Some "zZ"))
        session (native-rpc/create
                  :sync_cursor (fn [] (Some 7))
                  :graph_blocks (fn [] (Some (list parent sibling earlier other-page other-parent unordered asset))))]
    (match (native-rpc/asset-datoms-operation session asset)
      (Ok operation)
      (do (is (= (native-core/Queued) (:state operation)))
          (match (:intent operation)
            (native-core/Create_asset value)
            (do (is (= "page" (:page-uuid value)))
                (is (= "parent" (:parent-uuid value)))
                (is (= "a3" (:order value))))
            _ (is false)))
      _ (is false))))

(deftest encrypted-asset-upload-stages-datoms-and-cleans-temporary-payload
  (let [cleaned (atom [])
        staged (atom [])
        checksum "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        session (native-rpc/create
                  :load_graph_catalog (fn [] (Some encrypted-graph-catalog))
                  :graph_unlocked (fn [_graph-id] true)
                  :encrypt_title (fn [_graph-id title] (Ok (str "cipher(" title ")")))
                  :resolve_asset_path (fn [path]
                                        (is (= "Assets/photo.jpg" path))
                                        "/documents/Assets/photo.jpg")
                  :encrypt_asset_file (fn [_graph-id path]
                                        (is (= "/documents/Assets/photo.jpg" path))
                                        (Ok (tuple "/tmp/photo.transit" 4096)))
                  :journal_page_id (fn [_day] (Some "real-journal-page"))
                  :sync_cursor (fn [] (Some 91))
                  :stage_operation (fn [operation]
                                     (match (:intent operation)
                                       (native-core/Create_asset value)
                                       (do (is (= "asset-async" (:uuid value)))
                                           (is (= "photo.jpg" (:title value)))
                                           (is (= "real-journal-page" (:page-uuid value)))
                                           (is (= "real-journal-page" (:parent-uuid value)))
                                           (is (= "jpg" (:asset-type value)))
                                           (is (= 2048 (:asset-size value)))
                                           (is (= checksum (:asset-checksum value))))
                                       _ (is false))
                                     (swap! staged conj (native-core/logseq-chat-pending-ops-state-string (:state operation)))
                                     (Ok (stdlib/ignore 0)))
                  :prepare_operation (fn [operation]
                                       (Ok (tuple (native-core/logseq-chat-pending-ops-outliner-op (:intent operation)) "[]")))
                  :cleanup_file (fn [path] (swap! cleaned conj path) (stdlib/ignore 0)))]
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
        session (native-rpc/create :send (fn [_request]
                                          (swap! calls inc)
                                          (Error "unexpected transport")))]
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
             (json/from-string (native-rpc/call session
               "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"createSyncGraph\"}}")))))))

(deftest graph-creation-preserves-transport-and-response-errors
  (run! (fn [[reply code message]]
          (let [uploads (atom 0)
                session (native-rpc/create
                          :send (fn [_request] reply)
                          :upload_file (fn [_upload]
                                         (swap! uploads inc)
                                         (Error "unexpected upload")))]
            (configure-encrypted-session session)
            (let [response (dispatch-json session "createSyncGraph" "{\"name\":\"Graph\",\"isEncrypted\":false}")]
              (is (= code (response-error-code response)))
              (is (= message (json-util/to-string
                               (json-util/member "message" (json-util/member "error" response))))))
            (is (= 0 @uploads))))
        [(tuple (Error "offline") "graph_create_failed" "offline")
         (tuple (Ok (native-core/logseq-chat-api-response 503 "")) "graph_create_failed" "Could not create graph")
         (tuple (Ok (native-core/logseq-chat-api-response 403 "denied")) "graph_create_failed" "denied")
         (tuple (Ok (native-core/logseq-chat-api-response 201 "{}")) "graph_create_failed" "Graph creation returned no graph id")
         (tuple (Ok (native-core/logseq-chat-api-response 201 "[]")) "graph_create_failed" "Graph creation returned no graph id")
         (tuple (Ok (native-core/logseq-chat-api-response 201 "{\"graph-id\":1}")) "graph_create_failed" "Graph creation returned no graph id")]))

(deftest encrypted-graph-creation-stops-when-key-provisioning-is-unavailable
  (let [uploads (atom 0)
        session (native-rpc/create
                  :send (fn [_request] (Ok (native-core/logseq-chat-api-response 201 "{\"graph-id\":\"new-private\"}")))
                  :upload_file (fn [_upload] (swap! uploads inc) (Error "unexpected upload")))]
    (configure-encrypted-session session)
    (is (= "graph_key_provision_failed"
           (response-error-code (dispatch-json session "createSyncGraph" "{\"name\":\"Private\",\"isEncrypted\":true}"))))
    (is (= 0 @uploads))))

(deftest encrypted-graph-creation-stops-after-key-provisioning-failure
  (let [events (atom [])
        session (native-rpc/create
                  :send (fn [_request]
                          (swap! events conj "create")
                          (Ok (native-core/logseq-chat-api-response 201 "{\"graph-id\":\"new-private\"}")))
                  :provision_graph_key (fn [config]
                                         (is (= "new-private" (:graph_id config)))
                                         (is (= (Some "Private") (:graph_name config)))
                                         (swap! events conj "provision")
                                         (Error "key storage unavailable"))
                  :upload_file (fn [_upload] (swap! events conj "upload") (Error "unexpected upload")))]
    (configure-encrypted-session session)
    (is (= "graph_key_provision_failed"
           (response-error-code (dispatch-json session "createSyncGraph" "{\"name\":\" Private \",\"isEncrypted\":true}"))))
    (is (= ["create" "provision"] @events))))

(deftest graph-creation-cleans-up-after-upload-http-failure
  (let [uploaded-path (atom nil)
        session (native-rpc/create
                  :send (fn [_request] (Ok (native-core/logseq-chat-api-response 201 "{\"graph-id\":\"new-plain\"}")))
                  :upload_file (fn [upload]
                                 (reset! uploaded-path (Some (:file_path upload)))
                                 (is (sys/file-exists (:file_path upload)))
                                 (Ok (native-core/logseq-chat-api-response 500 ""))))]
    (configure-encrypted-session session)
    (let [response (dispatch-json session "createSyncGraph" "{\"name\":\"Plain\",\"isEncrypted\":false}")]
      (is (= "graph_initial_upload_failed" (response-error-code response)))
      (is (= "Initial snapshot upload failed with HTTP 500"
             (json-util/to-string (json-util/member "message" (json-util/member "error" response))))))
    (if-some [path @uploaded-path] (is (not (sys/file-exists path))) (is false))))

(deftest encrypted-graph-selection-attempts-offline-key-cache
  (let [loaded (atom [])
        session (native-rpc/create
                  :load_graph_catalog (fn [] (Some encrypted-graph-catalog))
                  :load_cached_graph_key (fn [config]
                                           (swap! loaded conj (:graph_id config))
                                           (Error "not cached"))
                  :graph_unlocked (fn [_graph-id] false))]
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
        session (native-rpc/create
                  :load_graph_catalog (fn [] (Some encrypted-graph-catalog))
                  :unlock_graph (fn [_config password]
                                  (reset! received (Some password))
                                  (reset! unlocked true)
                                  (Ok (stdlib/ignore 0)))
                  :graph_unlocked (fn [_graph-id] @unlocked))]
    (configure-encrypted-session session)
    (dispatch-json session "selectGraph" "encrypted-1")
    (let [response (dispatch-json session "unlockGraph" "correct horse")]
      (is (json-util/to-bool (json-util/member "ok" response)))
      (is (json-util/to-bool (json-util/member "isGraphUnlocked" (json-util/member "result" response)))))
    (is (= (Some "correct horse") @received))))

(deftest session-rejects-legacy-sync-action
  (let [response (json/from-string
                  (native-rpc/call (native-rpc/create)
                                   "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"syncPending\"}}"))]
    (is (not (json-util/to-bool (json-util/member "ok" response))))
    (is (= "unknown_action"
           (json-util/to-string (json-util/member "code" (json-util/member "error" response)))))))

(deftest session-without-graph-has-no-due-flashcards
  (let [response (json/from-string
                  (native-rpc/call (native-rpc/create)
                                   "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"loadFlashcards\",\"payload\":\"1776000000000\"}}"))]
    (is (json-util/to-bool (json-util/member "ok" response)))
    (is (= "[]" (json/to-string (json-util/member "flashcards" (json-util/member "result" response)))))))

(deftest session-restores-cached-graph-name-without-token
  (let [response (json/from-string
                  (native-rpc/call (native-rpc/create)
                                   "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"configure\",\"payload\":\"{\\\"baseUrl\\\":\\\"http://127.0.0.1:8787\\\",\\\"graphId\\\":\\\"cached-graph\\\",\\\"graphName\\\":\\\"Sync 2\\\",\\\"token\\\":\\\"\\\"}\"}}"))
        result (json-util/member "result" response)]
    (is (= "cached-graph" (json-util/to-string (json-util/member "selectedGraphId" result))))
    (is (= "Sync 2" (json-util/to-string (json-util/member "graphName" result))))))

(deftest session-clear-related-exposes-related-blocks
  (let [response (json/from-string
                  (native-rpc/call (native-rpc/create)
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
