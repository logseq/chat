(ns logseq-chat.rpc-wire
  (:require [clojure.string :as string]
            [logseq-chat.flashcards :as flashcards]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.outliner-state :as outliner]
            [ocaml.package/yojson]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Stdlib :as stdlib]))

(defn journal-page-uuid [journal-day]
  (format "00000001-%04d-%04d-0000-000000000000"
          (quot journal-day 10000) (rem journal-day 10000)))

(defn journal-day-title [journal-day]
  (let [months ["Jan" "Feb" "Mar" "Apr" "May" "Jun"
                "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]
        year (quot journal-day 10000)
        month (rem (quot journal-day 100) 100)
        day (rem journal-day 100)
        suffix (if (<= 11 (rem day 100) 13)
                 "th"
                 (case (rem day 10) 1 "st" 2 "nd" 3 "rd" "th"))]
    (if (<= 1 month (count months))
      (format "%s %d%s, %04d" (nth months (dec month)) day suffix year)
      (stdlib/invalid-arg "invalid journal month"))))

(defn outliner-structure-source [payload]
  (match (json/from-string payload)
    (tag Assoc entries)
    (let [fields (into {} (reverse entries))]
      (match (get fields "type")
        (Some (tag String kind))
        (when (or (= kind "returnPressed") (= kind "backspacePressed"))
          (match (get fields "uuid") (Some (tag String uuid)) (Some uuid) _ nil))
        _ nil))
    _ nil))

(defn outliner-structure-source-matches? [state payload]
  (if-some [uuid (outliner-structure-source payload)]
    (= (outliner/editing-uuid state) (Some uuid))
    true))

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

(defn required-string-list [name input]
  (match (json-util/member name input)
    (tag List values)
    (reduce (fn [result value]
              (let* [items result]
                (match value
                  (tag String text)
                  (if (string/blank? text)
                    (Error (str "field must be a list of non-empty strings: " name))
                    (Ok (conj items text)))
                  _ (Error (str "field must be a list of non-empty strings: " name)))))
            (Ok []) values)
    _ (Error (str "field must be a list: " name))))

(defn decode-move [^:Yojson.Basic.t input]
  (match input
    (tag Assoc entries)
    (let [fields (into {} (reverse entries))]
      (let* [uuid (required-string fields "uuid")
             page-uuid (required-string fields "pageUuid")
             parent-uuid (required-string fields "parentUuid")
             order (required-string fields "order")]
        (Ok (record ops/pending-move (uuid uuid) (page-uuid page-uuid)
              (parent-uuid parent-uuid) (order order)))))
    _ (Error "moves must contain objects")))

(defn required-moves [input]
  (match (json-util/member "moves" input)
    (tag List values)
    (reduce (fn [result value]
              (let* [moves result move (decode-move value)] (Ok (conj moves move))))
            (Ok []) values)
    _ (Error "field must be a list: moves")))

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

(defn graph-creation-payload [payload]
  (match (json/from-string payload)
    (tag Assoc entries)
    (let [fields (into {} (reverse entries))]
      (match (tuple (required-string fields "name") (field fields "isEncrypted"))
        (tuple (Ok name) (Some (tag Bool encrypted)))
        (if (string/blank? name)
          (Error (tuple "invalid_params" "Graph name cannot be empty"))
          (Ok (tuple (string/trim name) encrypted)))
        _ (Error (tuple "invalid_params" "createSyncGraph requires a name and isEncrypted flag"))))
    _ (Error (tuple "invalid_params" "createSyncGraph payload must be an object"))))

(defn graph-creation-response [response]
  (if (<= 200 (:status response) 299)
    (match (json/from-string (:body response))
      (tag Assoc entries)
      (match (get (into {} (reverse entries)) "graph-id")
        (Some (tag String graph-id)) (Ok graph-id)
        _ (Error "Graph creation returned no graph id"))
      _ (Error "Graph creation returned no graph id"))
    (Error (if (= "" (:body response)) "Could not create graph" (:body response)))))

(defn graph-workflow-result [code result]
  (match result
    (Ok value) (Ok value)
    (Error message) (Error (tuple code message))))

(defn action-fields [action payload]
  (try
    (match (json/from-string payload)
      (tag Assoc entries) (Ok (into {} (reverse entries)))
      _ (Error (tuple "invalid_params" (str action " payload must be an object"))))
    (catch _ (Error (tuple "invalid_json" (str action " payload must be valid JSON"))))))

(defn action-response [result]
  (match result
    (Ok response) response
    (Error (tuple code message)) (failure code message)))

(defn required-bool [fields name]
  (match (field fields name)
    (Some (tag Bool value)) (Ok value)
    None (Error (str "missing field: " name))
    _ (Error (str "field must be a boolean: " name))))

(defn debug [message]
  (stdlib/prerr-endline (str "LogseqChat core " message)))

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
