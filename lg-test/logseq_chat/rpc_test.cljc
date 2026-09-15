(ns logseq-chat.rpc-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.rpc :as rpc]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.cache-model :as model]
            [logseq-chat.outliner-effects :as effects]
            [ocaml.Yojson.Basic :as json]
            [logseq-chat.outliner-state :as outliner]
            [logseq-chat.flashcards :as flashcards]))

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
