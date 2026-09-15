(ns logseq-chat.rpc
  (:require [logseq-chat.outliner-state :as outliner]
            [clojure.string :as string]
            [logseq-chat.markup :as markup]
            [logseq-chat.outliner-effects :as effects]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
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

(defn status-payload [input]
  (match (json-util/member "status" input)
    (tag Assoc entries)
    (let [fields (into {} (reverse entries))]
      (let* [uuid (required-string fields "uuid")
             title (required-string fields "title")
             ident (optional-string fields "ident")
             icon-type (optional-string fields "iconType")
             icon-id (optional-string fields "iconId")
             icon-color (optional-string fields "iconColor")]
        (Ok (record model/status (uuid uuid) (title title) (ident ident)
              (icon-type icon-type) (icon-id icon-id) (icon-color icon-color)))))
    _ (Error "missing field: status")))

(defn optional-status-payload [input]
  (match (json-util/member "status" input)
    (tag Null) (Ok nil)
    _ (let* [status (status-payload input)] (Ok (Some status)))))

(defn status-semantic-ref [status]
  (if-some [ident (:ident status)]
    (if (string/blank? ident) (ops/Ref-uuid (:uuid status)) (ops/Ref-ident ident))
    (ops/Ref-uuid (:uuid status))))

(defn optional-int [fields name]
  (match (field fields name)
    (Some (tag Int value)) (Ok (Some value))
    (Some (tag Null)) (Ok nil)
    None (Ok nil)
    _ (Error (str "field must be an integer: " name))))

(defn send-payload [payload]
  (let [raw (match payload (Some text) text None "")
        parsed (try (Some (json/from-string raw)) (catch _ nil))]
    (match parsed
      (Some (tag Assoc entries))
      (let [fields (into {} (reverse entries))]
        (let* [text (required-string fields "text")
               uuid (optional-string fields "uuid")
               now (optional-int fields "now")]
          (Ok (tuple (string/trim text) uuid now))))
      _ (Ok (tuple (string/trim raw) nil nil)))))

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

(defn json-object [fields]
  (let [^:Yojson.Basic.t result (tag Assoc (apply list fields))] result))

(defn json-list [values]
  (let [^:Yojson.Basic.t result (tag List (apply list values))] result))

(defn success [result]
  (json/to-string
    (json-object [(tuple "apiVersion" (tag Int 1)) (tuple "ok" (tag Bool true))
                  (tuple "result" result) (tuple "error" (tag Null))])))

(defn failure [code message]
  (json/to-string
    (json-object [(tuple "apiVersion" (tag Int 1)) (tuple "ok" (tag Bool false))
                  (tuple "result" (tag Null))
                  (tuple "error" (json-object [(tuple "code" (tag String code))
                                                (tuple "message" (tag String message))]))])))

(defn route [snapshot dispatch input]
  (match input
    (tag Assoc entries)
    (let [fields (into {} (reverse entries))]
      (match (field fields "apiVersion")
        (Some (tag Int 1))
        (match (required-string fields "method")
          (Error message) (failure "invalid_request" message)
          (Ok method)
          (match (field fields "params")
            (Some (tag Assoc entries))
            (case method
              "snapshot" (snapshot)
              "open" (snapshot)
              "dispatch"
              (let [params (into {} (reverse entries))
                    decoded (let* [action (required-string params "action")
                                   payload (optional-string params "payload")]
                              (Ok (tuple action payload)))]
                (match decoded
                  (Ok (tuple action payload)) (dispatch action payload)
                  (Error message) (failure "invalid_params" message)))
              (failure "unknown_method" (str "unknown method: " method)))
            None (failure "invalid_request" "missing field: params")
            _ (failure "invalid_request" "params must be an object")))
        (Some (tag Int _)) (failure "unsupported_version" "only API version 1 is supported")
        None (failure "invalid_request" "missing field: apiVersion")
        _ (failure "invalid_request" "apiVersion must be an integer")))
    _ (failure "invalid_request" "request must be an object")))

(defn call [snapshot dispatch request]
  (try (route snapshot dispatch (json/from-string request))
       (catch _ (failure "invalid_json" "request must be valid JSON"))))

(defn request-json [id request file-path content-type headers]
  (json-object
    (concat [(tuple "id" (tag Int id))
             (tuple "method" (tag String (:method_ request)))
             (tuple "url" (tag String (:url request)))
             (tuple "token" (tag String (:token request)))
             (tuple "contentType" (tag String content-type))
             (tuple "headers" (json-object (map (fn [entry]
                                                 (match entry (tuple key value) (tuple key (tag String value))))
                                               headers)))]
            (if-some [body (:body request)]
              (let [fields [(tuple "body" (tag String body))]]
                (try (conj fields (tuple "bodyObject" (json/from-string body)))
                     (catch _ fields)))
              [])
            (if-some [path file-path] [(tuple "filePath" (tag String path))] []))))

(defn summary-json [^:model/entity-summary summary]
  (json-object [(tuple "uuid" (tag String (:uuid summary))) (tuple "title" (tag String (:title summary)))]))

(defn status-response-json [^:model/status status]
  (json-object
    (concat [(tuple "uuid" (tag String (:uuid status))) (tuple "title" (tag String (:title status)))]
            (if-some [ident (:ident status)] [(tuple "ident" (tag String ident))] [])
            (match [(:icon-type status) (:icon-id status)]
              [(Some kind) (Some id)]
              [(tuple "icon" (json-object
                (concat [(tuple "type" (tag String kind)) (tuple "id" (tag String id))]
                        (if-some [color (:icon-color status)] [(tuple "color" (tag String color))] []))))]
              _ []))))

(defn block-json [block]
  (json-object
    (concat
      [(tuple "uuid" (tag String (:uuid block))) (tuple "title" (tag String (:title block)))
       (tuple "pageId" (tag String (:page-id block))) (tuple "createdAt" (tag Int (:created-at block)))
       (tuple "updatedAt" (tag Int (:updated-at block))) (tuple "syncStatus" (tag String (:sync-status block)))
       (tuple "isAsset" (tag Bool (:is-asset block)))
       (tuple "tags" (tag List (apply list (map summary-json (:tags block)))))
       (tuple "references" (tag List (apply list (map summary-json (:references block)))))
       (tuple "breadcrumbs" (tag List (apply list (map summary-json (:breadcrumbs block)))))
       (tuple "markup" (markup/to-yojson (markup/parse (:references block) (:tags block) (:title block))))]
      (if-some [order (:order block)] [(tuple "order" (tag String order))] [])
      (if-some [status (:status block)] [(tuple "status" (status-response-json status))] [])
      (if-some [kind (:asset-type block)] [(tuple "assetType" (tag String kind))] [])
      (if-some [size (:asset-size block)] [(tuple "assetSize" (tag Int size))] [])
      (if-some [checksum (:asset-checksum block)] [(tuple "assetChecksum" (tag String checksum))] [])
      (if-some [path (:local-path block)] [(tuple "localPath" (tag String path))] [])
      (if-some [parent (:parent-id block)] [(tuple "parentId" (tag String parent))] []))))

(defn visible-block-json [block]
  (let [encoded (block-json block)]
    (if-some [[title day] (:journal block)]
      (match encoded
        (tag Assoc fields)
        (json-object (concat [(tuple "journalTitle" (tag String title)) (tuple "journalDay" (tag Int day))] fields))
        _ encoded)
      encoded)))

(defn flashcard-json [due-card]
  (let [card (:card due-card)]
    (json-object [(tuple "block" (block-json (:block due-card)))
                  (tuple "children" (tag List (apply list (map block-json (:children due-card)))))
                  (tuple "due" (tag Int (:due card))) (tuple "repetitions" (tag Int (:reps card)))
                  (tuple "lapses" (tag Int (:lapses card)))
                  (tuple "state" (tag String (flashcards/state-name (:state card))))])))

(defn graph-json [graph]
  (json-object [(tuple "id" (tag String (:id graph))) (tuple "name" (tag String (:name graph)))
                (tuple "schemaVersion" (if-some [version (:schema-version graph)] (tag String version) (tag Null)))
                (tuple "isEncrypted" (tag Bool (:e2ee graph))) (tuple "isReady" (tag Bool (:ready graph)))]))

(defn search-hit-json [hit]
  (json-object [(tuple "uuid" (tag String (:uuid hit))) (tuple "title" (tag String (:title hit)))
                (tuple "isPage" (tag Bool (:is-page hit)))
                (tuple "page" (if-some [page (:page hit)] (summary-json page) (tag Null)))
                (tuple "breadcrumbs" (tag List (apply list (map summary-json (:breadcrumbs hit)))))]))

(defn outliner-row-json [youtube-target-url serialize-block row]
  (json-object
    (concat [(tuple "block" (serialize-block (:block row)))
             (tuple "depth" (tag Int (:depth row)))
             (tuple "hasChildren" (tag Bool (:has-children row)))
             (tuple "isCollapsed" (tag Bool (:is-collapsed row)))]
            (if-some [url youtube-target-url] [(tuple "youtubeTargetURL" (tag String url))] []))))

(defn outliner-rows-json [serialize-block context state]
  (let [rows (outliner/visible-rows context state)
        targets (into {} (reverse (youtube-target-urls (map :block rows))))]
    (json-list (map (fn [row]
                     (outliner-row-json (get targets (:uuid (:block row))) serialize-block row)) rows))))

(defn outliner-candidates-json [context state]
  (json-list
      (if-some [request (outliner/autocomplete state)]
        (mapv (fn [candidate]
                (json-object [(tuple "label" (tag String (:label candidate)))
                              (tuple "value" (tag String (:value candidate)))]))
              (outliner/autocomplete-candidates context request))
        [])))

(defn autocomplete-kind-json [kind]
  (match kind outliner/Node "node" outliner/Tag "tag" outliner/Property "property"))

(defn outliner-state-json [state]
  (json-object
    [(tuple "editing"
       (if-some [editing (:editing state)]
         (json-object [(tuple "uuid" (tag String (:uuid editing)))
                       (tuple "title" (tag String (:title editing)))
                       (tuple "caretUTF16Offset" (tag Int (:caret editing)))])
         (tag Null)))
     (tuple "selectedBlockIds" (json-strings (outliner/selected-uuids state)))
     (tuple "collapsedBlockIds" (json-strings (outliner/collapsed-uuids state)))
     (tuple "zoomedBlockIds" (json-strings (:zoomed state)))
     (tuple "autocomplete"
       (if-some [request (:autocomplete state)]
         (json-object [(tuple "kind" (tag String (autocomplete-kind-json (:kind request))))
                       (tuple "query" (tag String (:query request)))])
         (tag Null)))]))

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
    (json-object [(tuple "type" (tag String kind)) (tuple key value)])))
