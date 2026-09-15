(ns logseq-chat.rpc
  (:require [logseq-chat.outliner-state :as outliner]
            [clojure.string :as string]
            [logseq-chat.markup :as markup]
            [logseq-chat.outliner-effects :as effects]
            [logseq-chat.pending-ops :as ops]
            [ocaml.Yojson.Basic :as json]
            [logseq-chat.flashcards :as flashcards]))

(defn toolbar-action [wire]
  (case wire
    "task" (Ok outliner/Task)
    "outdent" (Ok outliner/Outdent)
    "indent" (Ok outliner/Indent)
    "tag" (Ok outliner/Tag_action)
    "pageReference" (Ok outliner/Page_reference)
    "camera" (Ok outliner/Camera)
    "audio" (Ok outliner/Audio)
    "attachment" (Ok outliner/Attachment)
    "hideKeyboard" (Ok outliner/Hide_keyboard)
    "copy" (Ok outliner/Copy)
    "delete" (Ok outliner/Delete)
    "copyReference" (Ok outliner/Copy_reference)
    "copyURL" (Ok outliner/Copy_url)
    "unselect" (Ok outliner/Unselect)
    (Error "unknown outliner toolbar action")))

(defn flashcard-rating [wire]
  (case wire
    "again" (Ok flashcards/Again)
    "hard" (Ok flashcards/Hard)
    "good" (Ok flashcards/Good)
    "easy" (Ok flashcards/Easy)
    (Error "rating must be again, hard, good, or easy")))

(defn field [^:map<string;Yojson.Basic.t> fields name] (get fields name))

(defn required-string [fields name]
  (match (field fields name)
    (Some (tag String value)) (Ok value)
    (Some _) (Error (str "field must be a string: " name))
    None (Error (str "missing field: " name))))

(defn optional-string [fields name]
  (match (field fields name)
    (Some (tag String value)) (Ok (Some value))
    (Some (tag Null)) (Ok nil)
    None (Ok nil)
    _ (Error (str "field must be a string: " name))))

(defn event-int [fields name]
  (match (field fields name)
    (Some (tag Int value)) (Ok value)
    _ (Error (str "missing integer outliner event field: " name))))

(defn drop-placement [wire]
  (case wire
    "before" (Ok outliner/Before)
    "inside" (Ok outliner/Inside)
    "after" (Ok outliner/After)
    (Error "unknown outliner drop placement")))

(defn decode-outliner-event [fields]
  (let* [kind (required-string fields "type")]
    (case kind
      "tapBlock" (let* [uuid (required-string fields "uuid")] (Ok (outliner/Tap_block uuid)))
      "longPressBlock" (let* [uuid (required-string fields "uuid")] (Ok (outliner/Long_press_block uuid)))
      "textChanged"
      (let* [title (required-string fields "title") caret (event-int fields "caretUTF16Offset")]
        (Ok (outliner/Text_changed (record outliner/outliner-text (title title) (caret caret)))))
      "caretMoved" (let* [caret (event-int fields "caretUTF16Offset")] (Ok (outliner/Caret_moved caret)))
      "returnPressed"
      (match [(field fields "title") (field fields "caretUTF16Offset")]
        [(Some (tag String title)) (Some (tag Int caret))]
        (Ok (outliner/Return_pressed_with_text (record outliner/outliner-text (title title) (caret caret))))
        [None None] (Ok outliner/Return_pressed)
        _ (Error "returnPressed requires both title and caretUTF16Offset"))
      "backspacePressed"
      (let* [length (event-int fields "selectionLength")]
        (match (field fields "title")
          (Some (tag String title))
          (Ok (outliner/Backspace_pressed_with_text (record outliner/outliner-backspace (title title) (selection-length length))))
          None (Ok (outliner/Backspace_pressed (record outliner/outliner-selection (selection-length length))))
          _ (Error "backspacePressed title must be a string")))
      "toolbar"
      (let* [wire (required-string fields "action") action (toolbar-action wire)]
        (Ok (outliner/Toolbar action)))
      "dropBlocks"
      (let* [uuid (required-string fields "targetUuid") wire (required-string fields "placement")
             placement (drop-placement wire)]
        (Ok (outliner/Drop_blocks (record outliner/outliner-drop (target-uuid uuid) (placement placement)))))
      "chooseAutocomplete" (let* [value (required-string fields "value")] (Ok (outliner/Choose_autocomplete value)))
      "confirmDelete" (Ok outliner/Confirm_delete)
      "saveEditing" (Ok outliner/Save_editing)
      "cancelEditing" (Ok outliner/Cancel_editing)
      "toggleCollapsed" (let* [uuid (required-string fields "uuid")] (Ok (outliner/Toggle_collapsed uuid)))
      "zoomIn" (let* [uuid (required-string fields "uuid")] (Ok (outliner/Zoom_in uuid)))
      "zoomOut" (Ok outliner/Zoom_out)
      "addRootBlock" (let* [uuid (required-string fields "uuid")] (Ok (outliner/Add_root_block uuid)))
      "setTaskStatus"
      (let* [uuid (required-string fields "uuid") ident (optional-string fields "statusIdent")]
        (if-some [ident ident]
          (Ok (outliner/Set_task_status (record outliner/outliner-status (uuid uuid) (status (ops/Ref-ident ident)))))
          (let* [status (optional-string fields "statusUuid")]
            (if-some [status status]
              (Ok (outliner/Set_task_status (record outliner/outliner-status (uuid uuid) (status (ops/Ref-uuid status)))))
              (Error "setTaskStatus requires a status reference")))))
      (Error "unknown outliner event type"))))

(defn outliner-message [payload]
  (try
    (match (json/from-string payload)
      (tag Assoc fields)
      ;; The wire protocol keeps the first occurrence of duplicate fields.
      (decode-outliner-event (into {} (reverse fields)))
      _ (Error "outliner event must be an object"))
    (catch _ (Error "outliner event must be valid JSON"))))

(defn youtube-url? [url]
  (let [lower (string/lower-case url)]
    (or (string/includes? lower "youtube.com") (string/includes? lower "youtu.be"))))

(defn youtube-target-urls [blocks]
  (let [[_ targets]
        (reduce
          (fn [[current targets] block]
            (let [[current target]
                  (reduce (fn [[current target] node]
                            (match node
                              (markup/Markup_video url)
                              (tuple (if (youtube-url? url) (Some url) current) target)
                              (markup/Markup_youtube_timestamp _ _)
                              (tuple current (if-some [url current] (Some url) target))
                              _ (tuple current target)))
                          (tuple current nil) (markup/parse (:references block) (:tags block) (:title block)))]
              (tuple current (if-some [url target] (conj targets (tuple (:uuid block) url)) targets))))
          (tuple nil []) blocks)]
    targets))

(defn json-strings [values] (tag List (apply list (map #(tag String %) values))))

(defn outliner-command-json [command]
  (let [[kind key value]
        (match command
          (effects/Platform_haptic haptic)
          (tuple "haptic" "style" (tag String (match haptic outliner/Selection "selection" outliner/Impact "impact")))
          (effects/Focus_block uuid) (tuple "focusBlock" "uuid" (tag String uuid))
          (effects/Confirm_delete uuids) (tuple "confirmDelete" "uuids" (json-strings uuids))
          (effects/Set_clipboard_text text) (tuple "setClipboardText" "text" (tag String text))
          (effects/Set_clipboard_references uuids) (tuple "setClipboardReferences" "uuids" (json-strings uuids))
          (effects/Set_clipboard_urls uuids) (tuple "setClipboardURLs" "uuids" (json-strings uuids))
          (effects/Platform_pick_attachment uuid) (tuple "pickAttachment" "uuid" (tag String uuid))
          (effects/Platform_take_photo uuid) (tuple "takePhoto" "uuid" (tag String uuid))
          (effects/Platform_record_audio uuid) (tuple "recordAudio" "uuid" (tag String uuid)))]
    (let [^:Yojson.Basic.t result (tag Assoc (list (tuple "type" (tag String kind)) (tuple key value)))]
      result)))
