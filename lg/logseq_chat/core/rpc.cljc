(ns logseq-chat.rpc
  (:require [logseq-chat.outliner-state :as outliner]
            [clojure.string :as string]
            [logseq-chat.markup :as markup]
            [logseq-chat.outliner-effects :as effects]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.fractional-order :as order]
            [logseq-chat.api :as api]
            [logseq-chat.graph-bootstrap :as bootstrap]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Stdlib :as stdlib]
            [logseq-chat.flashcards :as flashcards]))

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

(defn same-status? [left right]
  (= (when-some [status left] (:uuid status))
     (when-some [status right] (:uuid status))))

(defn same-pending-version? [left right]
  (and (= (:uuid left) (:uuid right))
       (= (:title left) (:title right))
       (= (:updated-at left) (:updated-at right))
       (same-status? (:status left) (:status right))
       (= (:asset-size left) (:asset-size right))
       (= (:asset-checksum left) (:asset-checksum right))
       (= (:local-path left) (:local-path right))))

(defn reconcile-authoritative-blocks [cache blocks]
  (let [by-uuid (into {} (map (fn [block] (tuple (:uuid block) block)) blocks))]
    (run! (fn [block]
            (when-some [authoritative (get by-uuid (:uuid block))]
              (when (or (= "submitted" (:sync-status block))
                        (and (= (:title block) (:title authoritative))
                             (same-status? (:status block) (:status authoritative))))
                (model/mark-block-synced cache (:uuid block)))))
          (model/unsynced-blocks cache))))

(defn normalize-title-intent [normalize intent]
  (match intent
    (ops/Save-title value)
    (let [[titles tags] (normalize (:uuid value) [(:title value)])]
      (tuple (if (= 1 (count titles)) (ops/Save-title (assoc value :title (nth titles 0))) intent) tags))
    (ops/Insert-block value)
    (let [[titles tags] (normalize (:uuid value) [(:title value)])]
      (tuple (if (= 1 (count titles)) (ops/Insert-block (assoc value :title (nth titles 0))) intent) tags))
    (ops/Split-block value)
    (let [[titles tags] (normalize (:uuid value) [(:before value) (:after value)])]
      (tuple (if (= 2 (count titles))
               (ops/Split-block (assoc value :before (nth titles 0) :after (nth titles 1))) intent) tags))
    (ops/Merge-backward value)
    (let [[titles tags] (normalize (:uuid value) [(:title value)])]
      (tuple (if (= 1 (count titles)) (ops/Merge-backward (assoc value :title (nth titles 0))) intent) tags))
    _ (tuple intent [])))

(defn normalize-operation-titles [normalizer fresh-id clock operation]
  (if-some [normalize normalizer]
    (let [[intent tags] (normalize-title-intent normalize (:intent operation))
          created (mapv (fn [[uuid title]]
                          (record ops/pending-operation
                                  (operation-id (fresh-id)) (base-t (:base-t operation)) (state ops/Queued)
                                  (intent (ops/Create-tag
                                            (record ops/pending-create
                                                    (uuid uuid) (title title) (created-at (clock)))))))
                        tags)]
      (conj created (assoc operation :intent intent)))
    [operation]))

(defn capture-operation [base-t uuid title now load-context journal-page-id fresh-id]
  (let [journal-day (model/journal-day-for-ms now)
        page (when-some [find-page journal-page-id] (find-page journal-day))]
    (if-some [page-uuid page]
      (let [last-order (->> (effects/sorted-siblings (load-context) (Some page-uuid))
                            (filter #(= (:page-id %) page-uuid))
                            (keep :order)
                            last)]
        (let* [position (order/between last-order nil)]
          (Ok (effects/operation base-t fresh-id
                (ops/Insert-block (record ops/pending-insert
                                         (uuid uuid) (title title) (page-uuid page-uuid)
                                         (parent-uuid page-uuid) (order position) (created-at now)))))))
      (Ok (effects/operation base-t fresh-id
            (ops/Create-journal (record ops/pending-journal
                                       (page-uuid (journal-page-uuid journal-day)) (block-uuid uuid)
                                       (title title) (journal-day journal-day) (created-at now))))))))

(defn capture-operations [cursor uuid title now status load-context journal-page-id fresh-id normalize]
  (if-some [base-t cursor]
    (let* [operation (capture-operation base-t uuid title now load-context journal-page-id fresh-id)]
      (let [status-operations
            (if-some [value status]
              [(effects/operation base-t fresh-id
                 (ops/Set-property (record ops/pending-property
                                           (uuid uuid) (attr "logseq.property/status") (expected nil)
                                           (value (Some (if-some [ident (:ident value)]
                                                          (ops/Ref-ident ident)
                                                          (ops/Ref-uuid (:uuid value))))))))]
              [])]
        (Ok (into (vec (normalize operation)) status-operations))))
    (Error "A current server cursor is required")))

(defn asset-destination [context block journal-page-id]
  (if-some [parent-uuid (:parent-id block)]
    (when-some [parent (outliner/find-block context parent-uuid)]
      (tuple (:page-id parent) parent-uuid))
    (when-some [find-page journal-page-id]
      (when-some [page-uuid (find-page (model/journal-day-for-ms (:created-at block)))]
        (tuple page-uuid page-uuid)))))

(defn asset-datoms-operation [cursor state block load-context journal-page-id]
  (if-some [base-t cursor]
    (match (tuple (:asset-type block) (:asset-size block) (:asset-checksum block))
      (tuple (Some asset-type) (Some asset-size) (Some asset-checksum))
      (let [context (load-context)]
        (if-some [[page-uuid parent-uuid] (asset-destination context block journal-page-id)]
          (let [last-order (->> (:blocks context)
                                (filter (fn [candidate]
                                          (and (= (:page-id candidate) page-uuid)
                                               (= (:parent-id candidate) (Some parent-uuid))
                                               (not= (:uuid candidate) (:uuid block)))))
                                (keep :order)
                                sort
                                last)]
            (let* [position (order/between last-order nil)]
              (Ok (record ops/pending-operation
                          (operation-id (str "asset:" (:uuid block)))
                          (base-t base-t) (state state)
                          (intent (ops/Create-asset
                                    (record ops/pending-asset
                                            (uuid (:uuid block)) (title (:title block))
                                            (page-uuid page-uuid) (parent-uuid parent-uuid)
                                            (order position) (created-at (:created-at block))
                                            (asset-type asset-type) (asset-size asset-size)
                                            (asset-checksum asset-checksum))))))))
          (Error "asset destination is not available")))
      _ (Error "asset metadata is incomplete"))
    (Error "A current server cursor is required")))

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

(defn decode-move [input]
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

(defn projected-status [value]
  (match value
    (Some (ops/Ref-ident ident))
    (let [[uuid title] (case ident
                         "logseq.property/status.backlog" (tuple "backlog" "Backlog")
                         "logseq.property/status.todo" (tuple "todo" "Todo")
                         "logseq.property/status.doing" (tuple "doing" "Doing")
                         "logseq.property/status.in-review" (tuple "in-review" "In Review")
                         "logseq.property/status.done" (tuple "done" "Done")
                         "logseq.property/status.canceled" (tuple "canceled" "Canceled")
                         (tuple ident ident))]
      (Some (record model/status (uuid uuid) (title title) (ident (Some ident))
              (icon-type nil) (icon-id nil) (icon-color nil))))
    (Some (ops/Ref-uuid uuid))
    (Some (record model/status (uuid uuid) (title uuid) (ident nil)
            (icon-type nil) (icon-id nil) (icon-color nil)))
    _ nil))

(defn project-outliner-intent [blocks intent]
  (match intent
    (ops/Save-title value)
    (mapv #(if (= (:uuid %) (:uuid value)) (assoc % :title (:title value)) %) blocks)

    (ops/Insert-block value)
    (conj (vec blocks)
          (assoc (model/local-block (:uuid value) (:title value) (:page-uuid value)
                                    (Some (:parent-uuid value)) (:created-at value))
                 :order (Some (:order value))))

    (ops/Create-asset value)
    (let [asset (assoc (model/local-block (:uuid value) (:title value) (:page-uuid value)
                                          (Some (:parent-uuid value)) (:created-at value))
                       :order (Some (:order value)) :is-asset true
                       :asset-type (Some (:asset-type value)) :asset-size (Some (:asset-size value))
                       :asset-checksum (Some (:asset-checksum value)))]
      (if (some #(= (:uuid %) (:uuid value)) blocks)
        (mapv #(if (= (:uuid %) (:uuid value)) (assoc asset :local-path (:local-path %)) %) blocks)
        (conj (vec blocks) asset)))

    (ops/Split-block value)
    (if-some [source (first (filter #(= (:uuid %) (:uuid value)) blocks))]
      (conj (mapv #(if (= (:uuid %) (:uuid value)) (assoc % :title (:before value)) %) blocks)
            (assoc (model/local-block (:new-uuid value) (:after value) (:page-id source)
                                      (:parent-id source) (:created-at value))
                   :order (Some (:new-order value)) :journal (:journal source)))
      (vec blocks))

    (ops/Merge-backward value)
    (let [previous-title (if-some [previous (first (filter #(= (:uuid %) (:previous-uuid value)) blocks))]
                           (:title previous) "")
          title (if-some [merged (:merged-title value)] merged (str previous-title (:title value)))]
      (mapv #(if (= (:uuid %) (:previous-uuid value))
               (assoc % :title title :sync-status "pending") %)
            (remove #(= (:uuid %) (:uuid value)) blocks)))

    (ops/Move-block value)
    (mapv #(if (= (:uuid %) (:uuid value))
             (assoc % :page-id (:page-uuid value) :parent-id (Some (:parent-uuid value))
                      :order (Some (:order value)) :sync-status "pending") %)
          blocks)

    (ops/Move-blocks value)
    (reduce (fn [result move] (project-outliner-intent result (ops/Move-block move)))
            (vec blocks) (:moves value))

    (ops/Delete-blocks value)
    (let [deleted (set (:uuids value))]
      (filterv #(not (contains? deleted (:uuid %))) blocks))

    (ops/Set-property value)
    (if (= (:attr value) "logseq.property/status")
      (let [status (projected-status (:value value))]
        (mapv #(if (= (:uuid %) (:uuid value)) (assoc % :status status :sync-status "pending") %) blocks))
      (vec blocks))

    _ (vec blocks)))

(defn merge-live-block-metadata [optimistic live]
  (assoc optimistic
    :updated-at (:updated-at live) :sync-status (:sync-status live)
    :tags (:tags live) :references (:references live) :breadcrumbs (:breadcrumbs live)
    :status (:status live) :is-asset (:is-asset live) :asset-type (:asset-type live)
    :asset-size (:asset-size live) :asset-checksum (:asset-checksum live)
    :local-path (:local-path live) :journal (:journal live)))

(defn page-blocks-with-optimistic-overlay [cached editing? page-uuid live-blocks]
  (if editing?
    (if-some [blocks cached]
      (let [live-by-uuid (into {} (map (fn [block] (tuple (:uuid block) block)) live-blocks))]
        (mapv (fn [block]
                (if-some [live (get live-by-uuid (:uuid block))]
                  (merge-live-block-metadata block live)
                  block))
              (filter #(= (:page-id %) page-uuid) blocks)))
      (vec live-blocks))
    (vec live-blocks)))

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

(defn upload-initial-graph-snapshot [config e2ee encrypt-title upload-file cleanup-file]
  (let* [encrypt-text (if e2ee
                       (if-some [encrypt encrypt-title]
                         (Ok (fn [value] (encrypt (:graph-id config) value)))
                         (Error "E2EE title encryption is unavailable"))
                       (Ok (fn [value] (Ok value))))
         prepared (bootstrap/prepare (:graph-id config) e2ee encrypt-text)]
    (try
      (let* [response (upload-file
                       (api/initial-snapshot-upload-request config (:file-path prepared) (:checksum prepared)))]
        (if (<= 200 (:status response) 299)
          (do (stdlib/prerr-endline
                (format "LogseqChat core initial graph snapshot uploaded graph=%s rows=%d"
                        (:graph-id config) (:row-count prepared)))
              (Ok (stdlib/ignore 0)))
          (Error (if (= "" (:body response))
                   (format "Initial snapshot upload failed with HTTP %d" (:status response))
                   (:body response)))))
      (finally (cleanup-file (:file-path prepared))))))

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

(defn import-snapshot [payload importer project completed]
  (match (tuple importer payload)
    (tuple None _) (failure "snapshot_import_unavailable" "Snapshot import is unavailable")
    (tuple _ None) (failure "invalid_params" "importSnapshot requires a JSON payload")
    (tuple (Some importer) (Some payload))
    (action-response
      (let* [_ (graph-workflow-result "snapshot_import_failed" (importer payload))
             _ (graph-workflow-result "graph_projection_failed" (project payload))]
        (Ok (completed))))))

(defn open-graph [payload open-storage project completed]
  (match (tuple open-storage payload)
    (tuple None _) (failure "graph_open_unavailable" "Graph storage is unavailable")
    (tuple _ None) (failure "invalid_params" "openGraph requires a JSON payload")
    (tuple (Some open-storage) (Some payload))
    (action-response
      (let* [_ (graph-workflow-result "graph_open_failed" (open-storage payload))
             _ (graph-workflow-result "graph_projection_failed" (project payload))]
        (Ok (completed))))))

(defn apply-sync-event [payload apply-event completed]
  (match (tuple apply-event payload)
    (tuple None _) (failure "websocket_unavailable" "WebSocket sync is unavailable")
    (tuple _ None) (failure "invalid_params" "applySyncEvent requires a payload")
    (tuple (Some apply-event) (Some event))
    (match (apply-event event)
      (Ok _) (completed)
      (Error message)
      (failure (if (or (string/starts-with? message "snapshot required:")
                       (= message "sync schema mismatch"))
                 "snapshot_required"
                 "websocket_apply_failed")
               message))))

(defn asset-metadata [fields]
  (match (tuple (required-string fields "uuid") (required-string fields "title")
                (optional-int fields "now") (required-string fields "assetType")
                (optional-int fields "assetSize") (required-string fields "assetChecksum")
                (required-string fields "localPath") (optional-string fields "targetBlockId"))
    (tuple (Ok uuid) (Ok title) (Ok now) (Ok asset-type) (Ok (Some asset-size))
           (Ok checksum) (Ok local-path) (Ok target))
    (Ok (tuple uuid title now asset-type asset-size checksum local-path target))
    _ (Error (tuple "invalid_params" "addAsset requires complete file metadata"))))

(defn add-asset [payload cache clock load-target prepare-view prepare-operation load-stage]
  (if-some [payload payload]
    (action-response
      (let* [fields (action-fields "addAsset" payload)
             metadata (asset-metadata fields)]
        (let [[uuid title requested-now asset-type asset-size checksum local-path target] metadata
              now (if-some [now requested-now] now (clock))
              asset-type (api/normalize-asset-type asset-type)
              completed (prepare-view)]
          (when-some [uuid target]
            (when (nil? (model/read-block cache uuid))
              (when-some [block (load-target uuid)]
                (model/upsert-blocks cache [block] now))))
          (model/cache-local-asset cache uuid title asset-type asset-size checksum local-path now target)
          (match (tuple (load-stage) (model/read-block cache uuid))
            (tuple (Some stage) (Some block))
            (let* [operation (graph-workflow-result "asset_projection_failed" (prepare-operation block))
                   _ (graph-workflow-result "stage_operation_failed" (stage operation))]
              (Ok (completed)))
            _ (Ok (completed))))))
    (failure "invalid_params" "addAsset requires a JSON payload")))

(defn required-bool [fields name]
  (match (field fields name)
    (Some (tag Bool value)) (Ok value)
    None (Error (str "missing field: " name))
    _ (Error (str "field must be a boolean: " name))))

(defn review-flashcard [payload review clock completed]
  (match (tuple payload review)
    (tuple None _) (failure "invalid_params" "reviewFlashcard requires a payload")
    (tuple _ None) (failure "flashcards_unavailable" "No graph is open")
    (tuple (Some payload) (Some review))
    (action-response
      (let* [fields (action-fields "reviewFlashcard" payload)
             uuid (graph-workflow-result "invalid_params" (required-string fields "uuid"))
             rating (graph-workflow-result "invalid_params" (required-string fields "rating"))
             requested-now (graph-workflow-result "invalid_params" (optional-int fields "now"))
             operation-id (graph-workflow-result "invalid_params" (required-string fields "operationId"))
             rating (graph-workflow-result "invalid_params" (flashcard-rating rating))]
        (let [now (match requested-now (Some now) now None (clock))]
          (let* [_ (graph-workflow-result "flashcard_review_failed" (review uuid rating now operation-id))]
            (Ok (completed now))))))))

(defn set-page-favorite [payload set-favorite configured? clock completed]
  (match (tuple payload set-favorite configured?)
    (tuple None _ _) (failure "invalid_params" "setPageFavorite requires a payload")
    (tuple _ None _) (failure "set_page_favorite_unavailable" "No graph is open")
    (tuple _ _ false) (failure "graph_not_configured" "Select a graph first")
    (tuple (Some payload) (Some set-favorite) true)
    (action-response
      (let* [fields (action-fields "setPageFavorite" payload)
             page-uuid (graph-workflow-result "invalid_params" (required-string fields "pageUuid"))
             favorite (graph-workflow-result "invalid_params" (required-bool fields "favorite"))
             operation-id (graph-workflow-result "invalid_params" (required-string fields "operationId"))
             requested-now (graph-workflow-result "invalid_params" (optional-int fields "now"))]
        (let [now (match requested-now (Some now) now None (clock))]
          (let* [_ (graph-workflow-result "set_page_favorite_failed" (set-favorite page-uuid favorite operation-id now))]
            (Ok (completed))))))))

(defn delete-page [payload delete configured? clock completed]
  (match (tuple payload delete configured?)
    (tuple None _ _) (failure "invalid_params" "deletePage requires a payload")
    (tuple _ None _) (failure "delete_page_unavailable" "No graph is open")
    (tuple _ _ false) (failure "graph_not_configured" "Select a graph first")
    (tuple (Some payload) (Some delete) true)
    (action-response
      (let* [fields (action-fields "deletePage" payload)
             page-uuid (graph-workflow-result "invalid_params" (required-string fields "pageUuid"))
             operation-id (graph-workflow-result "invalid_params" (required-string fields "operationId"))
             requested-now (graph-workflow-result "invalid_params" (optional-int fields "now"))]
        (let [now (match requested-now (Some now) now None (clock))]
          (let* [_ (graph-workflow-result "delete_page_failed" (delete page-uuid operation-id now))]
            (Ok (completed))))))))

(defn debug [message]
  (stdlib/prerr-endline (str "LogseqChat core " message)))

(defn cache-remote-blocks [cache response now]
  (if (<= 200 (:status response) 299)
    (let [[blocks journals]
          (try (api/feed-from-body (:body response))
               (catch error
                 (let [message (Printexc/to-string error)]
                   (debug (str "remote refresh parse failed: " message))
                   (throw (Failure (str "Could not parse Logseq search response: " message))))))]
      (run! (fn [journal]
              (model/upsert-journal-page cache (:uuid journal) (:journal-day journal) (:title journal)))
            journals)
      (debug (format "remote refresh parsed blocks=%d" (count blocks)))
      (model/upsert-blocks cache blocks now)
      (Ok (stdlib/ignore 0)))
    (do (debug (format "remote refresh HTTP failed status=%d" (:status response)))
        (Error (format "Logseq API returned HTTP %d" (:status response))))))

(defn cache-task-statuses [cache response]
  (if (<= 200 (:status response) 299)
    (let [statuses (api/statuses-from-property-body (:body response))]
      (debug (format "remote task statuses parsed count=%d" (count statuses)))
      (model/upsert-statuses cache statuses)
      (Ok (stdlib/ignore 0)))
    (Error (format "Logseq status property returned HTTP %d" (:status response)))))

(defn refresh-from-remote [cache config send now snapshot]
  (debug (str "remote refresh started graph=" (:graph-id config)))
  (let [result
        (let* [response (graph-workflow-result "remote_refresh_failed"
                          (match (send (api/recent-blocks-request config (model/journal-day-for-ms now)))
                            (Error message)
                            (do (debug (str "remote refresh request failed: " message)) (Error message))
                            (Ok response) (Ok response)))
               _ (graph-workflow-result "remote_refresh_failed" (cache-remote-blocks cache response now))
               statuses (graph-workflow-result "remote_statuses_failed" (send (api/task-statuses-request config)))
               _ (graph-workflow-result "remote_statuses_failed" (cache-task-statuses cache statuses))]
          (Ok (snapshot)))]
    (match result
      (Ok response) response
      (Error (tuple code message)) (failure code message))))

(defn create-sync-graph [config payload send provision initialize discover created]
  (match (tuple config payload)
    (tuple None _) (failure "graph_not_configured" "Configure Logseq before creating a graph")
    (tuple _ None) (failure "invalid_params" "createSyncGraph requires a payload")
    (tuple (Some config) (Some payload))
    (try
      (let [result
            (let* [[name encrypted] (graph-creation-payload payload)
                   response (graph-workflow-result "graph_create_failed"
                              (send (api/create-graph-request config name "65.33" encrypted)))
                   graph-id (graph-workflow-result "graph_create_failed" (graph-creation-response response))]
              (let [selected (assoc config :graph-id graph-id :graph-name (Some name))]
                (let* [_ (graph-workflow-result "graph_key_provision_failed"
                           (if encrypted
                             (if-some [provision provision]
                               (provision selected)
                               (Error "E2EE key provisioning is unavailable"))
                             (Ok (stdlib/ignore 0))))
                       _ (graph-workflow-result "graph_initial_upload_failed"
                           (initialize (assoc config :graph-id graph-id) encrypted))
                       _ (graph-workflow-result "graph_discovery_failed" (discover config))]
                  (Ok (created selected)))))]
        (match result
          (Ok response) response
          (Error (tuple code message)) (failure code message)))
      (catch error (failure "invalid_json" (Printexc/to-string error))))))

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
