(ns logseq-chat.rpc-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
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
