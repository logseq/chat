(ns logseq-chat.rpc-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.rpc :as rpc]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.cache-model :as model]
            [logseq-chat.api :as api]
            [logseq-chat.search-index :as search]
            [logseq-chat.outliner-effects :as effects]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [logseq-chat.outliner-state :as outliner]
            [logseq-chat.flashcards :as flashcards]))

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
