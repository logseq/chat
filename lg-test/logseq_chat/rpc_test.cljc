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
