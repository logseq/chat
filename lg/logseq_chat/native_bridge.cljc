(ns logseq-chat.native-bridge
  (:require [clojure.string :as string]
            [lui.app :as driver]
            [lui.backend.apple :as apple]
            [lui.protocol :as proto]
            [lui.wire :as wire]
            [logseq-chat.app :as chat]
            [logseq-chat.model :as model]
            [logseq-chat.view :as view]
            [ocaml.Callback :as callback]))

(def latest-patch (atom ""))
(def current-app (atom None))

(defn send-patch! [json]
  (reset! latest-patch json)
  true)

(defn operating-system [platform-code]
  (match platform-code
    1 proto/MacOS
    2 proto/IOS
    3 proto/AndroidOS
    _ proto/GenericOS))

(defn app []
  (match (deref current-app)
    (Some value) value
    None (raise (Invalid_argument "Logseq Chat LG runtime is not started"))))

(defn flush-event! [event]
  (reset! latest-patch "")
  (driver/dispatch-event! (app) event)
  (driver/flush! (app))
  (deref latest-patch))

(defn flush-action! [action]
  (reset! latest-patch "")
  (driver/send! (app) action)
  (driver/flush! (app))
  (deref latest-patch))

(defn encode-string-vector [values]
  (str "["
       (string/join "," (mapv wire/quoted values))
       "]"))

(defn encode-settings [settings]
  (str "{\"appearance\":" (wire/quoted (:appearance settings))
       ",\"language\":" (wire/quoted (:language settings))
       ",\"spellCheck\":" (:spell-check settings)
       ",\"autoCorrection\":" (:auto-correction settings)
       ",\"sidebarTabs\":" (encode-string-vector (:sidebar-tabs settings))
       ",\"baseURL\":" (wire/quoted (:base-url settings))
       "}"))

(defn encode-runtime-log-record [record]
  (str "{\"id\":" (wire/quoted (:id record))
       ",\"level\":" (wire/quoted (:level record))
       ",\"source\":" (wire/quoted (:source record))
       ",\"timestamp\":" (wire/quoted (:timestamp record))
       ",\"message\":" (wire/quoted (:message record)) "}"))

(defn encode-runtime-log-records [records]
  (str "["
       (string/join "," (mapv encode-runtime-log-record records))
       "]"))

(defn encode-effect [effect]
  (match effect
    (model/SendCaptureEffect id text)
    (str "{\"id\":" id
         ",\"kind\":\"send-capture\",\"text\":"
         (wire/quoted text) "}")
    (model/PresentAttachmentEffect id kind)
    (str "{\"id\":" id
         ",\"kind\":\"present-attachment\",\"text\":"
         (wire/quoted kind) "}")
    (model/SearchNodesEffect id query)
    (str "{\"id\":" id
         ",\"kind\":\"search-nodes\",\"text\":"
         (wire/quoted query) "}")
    (model/TapOutlinerBlockEffect id uuid)
    (str "{\"id\":" id
         ",\"kind\":\"tap-outliner-block\",\"text\":"
         (wire/quoted uuid) "}")
    (model/ChangeOutlinerTextEffect id uuid title caret)
    (str "{\"id\":" id
         ",\"kind\":\"change-outliner-text\",\"text\":"
         (wire/quoted title) ",\"uuid\":" (wire/quoted uuid)
         ",\"value\":" caret "}")
    (model/ReturnOutlinerEditorEffect id uuid title caret)
    (str "{\"id\":" id
         ",\"kind\":\"return-outliner-editor\",\"text\":"
         (wire/quoted title) ",\"uuid\":" (wire/quoted uuid)
         ",\"value\":" caret "}")
    (model/BackspaceOutlinerEditorEffect id uuid title selection-length)
    (str "{\"id\":" id
         ",\"kind\":\"backspace-outliner-editor\",\"text\":"
         (wire/quoted title) ",\"uuid\":" (wire/quoted uuid)
         ",\"value\":" selection-length "}")
    (model/MoveOutlinerCaretEffect id uuid caret)
    (str "{\"id\":" id
         ",\"kind\":\"move-outliner-caret\",\"text\":\"\",\"uuid\":"
         (wire/quoted uuid) ",\"value\":" caret "}")
    (model/ToggleOutlinerCollapsedEffect id uuid)
    (str "{\"id\":" id
         ",\"kind\":\"toggle-outliner-collapsed\",\"text\":"
         (wire/quoted uuid) "}")
    (model/ZoomOutlinerBlockEffect id uuid)
    (str "{\"id\":" id
         ",\"kind\":\"zoom-outliner-block\",\"text\":"
         (wire/quoted uuid) "}")
    (model/LongPressOutlinerBlockEffect id uuid)
    (str "{\"id\":" id
         ",\"kind\":\"long-press-outliner-block\",\"text\":"
         (wire/quoted uuid) "}")
    (model/OutlinerToolbarEffect id action)
    (str "{\"id\":" id
         ",\"kind\":\"outliner-toolbar\",\"text\":"
         (wire/quoted action) "}")
    (model/ChooseOutlinerAutocompleteEffect id value)
    (str "{\"id\":" id
         ",\"kind\":\"choose-outliner-autocomplete\",\"text\":"
         (wire/quoted value) "}")
    (model/OpenAppNodeEffect id uuid)
    (str "{\"id\":" id ",\"kind\":\"open-node\",\"text\":"
         (wire/quoted uuid) "}")
    (model/OpenSearchNodeEffect id uuid)
    (str "{\"id\":" id ",\"kind\":\"open-node\",\"text\":"
         (wire/quoted uuid) "}")
    (model/CloseAppNodeEffect id uuid)
    (str "{\"id\":" id ",\"kind\":\"close-node\",\"text\":"
         (wire/quoted uuid) "}")
    (model/CloseSearchNodeEffect id uuid)
    (str "{\"id\":" id ",\"kind\":\"close-node\",\"text\":"
         (wire/quoted uuid) "}")
    (model/AddRootBlockEffect id uuid)
    (str "{\"id\":" id ",\"kind\":\"add-root-block\",\"text\":"
         (wire/quoted uuid) "}")
    (model/SelectSidebarPageEffect id uuid)
    (str "{\"id\":" id ",\"kind\":\"select-sidebar-page\",\"text\":"
         (wire/quoted uuid) "}")
    (model/ClearSelectedPageEffect id)
    (str "{\"id\":" id ",\"kind\":\"clear-selected-page\",\"text\":\"\"}")
    (model/LoadFlashcardsEffect id)
    (str "{\"id\":" id ",\"kind\":\"load-flashcards\",\"text\":\"\"}")
    (model/ReviewFlashcardEffect id uuid rating)
    (str "{\"id\":" id ",\"kind\":\"review-flashcard\",\"text\":"
         (wire/quoted rating) ",\"uuid\":" (wire/quoted uuid) "}")
    (model/RefreshGraphsEffect id)
    (str "{\"id\":" id ",\"kind\":\"refresh-graphs\",\"text\":\"\"}")
    (model/OpenGraphEffect id graph-id)
    (str "{\"id\":" id ",\"kind\":\"open-graph\",\"text\":"
         (wire/quoted graph-id) "}")
    (model/UnlockGraphEffect id password)
    (str "{\"id\":" id ",\"kind\":\"unlock-graph\",\"text\":"
         (wire/quoted password) "}")
    (model/CreateGraphEffect id name is-encrypted)
    (str "{\"id\":" id ",\"kind\":\"create-graph\",\"text\":"
         (wire/quoted name) ",\"value\":" (if is-encrypted 1 0) "}")
    (model/DeleteLocalGraphEffect id graph-id)
    (str "{\"id\":" id ",\"kind\":\"delete-local-graph\",\"text\":"
         (wire/quoted graph-id) "}")
    (model/SaveSettingsEffect id settings)
    (str "{\"id\":" id ",\"kind\":\"save-settings\",\"text\":"
         (wire/quoted (encode-settings settings)) "}")
    (model/RefreshRuntimeLogEffect id source errors-only newest-first)
    (str "{\"id\":" id ",\"kind\":\"refresh-runtime-log\",\"text\":"
         (wire/quoted source) ",\"value\":"
         (+ (if errors-only 1 0) (if newest-first 2 0)) "}")
    (model/CopyRuntimeLogEffect id records)
    (str "{\"id\":" id ",\"kind\":\"copy-runtime-log\",\"text\":"
         (wire/quoted (encode-runtime-log-records records)) "}")
    (model/SignOutEffect id)
    (str "{\"id\":" id ",\"kind\":\"sign-out\",\"text\":\"\"}")))

(defn take-effect []
  (let [effects (:pending-effects (chat/model (app)))]
    (if (empty? effects)
      ""
      (let [effect (nth effects 0)]
        (flush-action! (model/DequeueEffect (model/effect-id effect)))
        (encode-effect effect)))))

(defn resolve-effect [id succeeded message]
  (flush-action! (model/ResolveEffect id succeeded message)))

(defn initialize [platform-code _host-code]
  (reset! latest-patch "")
  (let [renderer
        (apple/create-wire-with-extensions
         send-patch! (view/extension-registry))
        application
        (chat/create
         (apple/backend-for renderer
                            (operating-system platform-code)
                            proto/SwiftUIHost))]
    (reset! current-app (Some application))
    (driver/start! application)
    (driver/flush! application)
    (deref latest-patch)))

(defn press [node] (flush-event! (proto/Press node)))
(defn long-press [node] (flush-event! (proto/LongPress node)))
(defn text-changed [node text]
  (flush-event! (proto/TextChanged node text)))
(defn submit [node] (flush-event! (proto/Submit node)))
(defn toggle-changed [node checked]
  (flush-event! (proto/ToggleChanged node checked)))
(defn change [node] (flush-event! (proto/Change node)))
(defn value-changed [node value]
  (flush-event! (proto/ValueChanged node value)))
(defn dismiss [node] (flush-event! (proto/Dismiss node)))
(defn double-press [node] (flush-event! (proto/DoublePress node)))

(defn extension-event [node identifier name text value]
  (let [values
        (cond
          (and (= identifier "outliner-block-content") (= name "open-node"))
          {"uuid" (proto/StringValue text)}

          (= name "text-change")
          {"title" (proto/StringValue text)
           "caret-utf16-offset" (proto/IntValue value)}
          (= name "return")
          {"title" (proto/StringValue text)
           "caret-utf16-offset" (proto/IntValue value)}
          (= name "backspace")
          {"title" (proto/StringValue text)
           "selection-length" (proto/IntValue value)}
          (= name "caret-change")
          {"caret-utf16-offset" (proto/IntValue value)}
          :else {})]
    (flush-event!
     (proto/ExtensionEvent node identifier name values))))

(defn dispose []
  (reset! latest-patch "")
  (driver/dispose! (app))
  (reset! current-app None)
  (deref latest-patch))

(defn root-node [] (driver/root-node (app)))

(callback/register "logseq_chat_lui_init" initialize)
(callback/register "logseq_chat_lui_press" press)
(callback/register "logseq_chat_lui_long_press" long-press)
(callback/register "logseq_chat_lui_text_changed" text-changed)
(callback/register "logseq_chat_lui_submit" submit)
(callback/register "logseq_chat_lui_toggle_changed" toggle-changed)
(callback/register "logseq_chat_lui_change" change)
(callback/register "logseq_chat_lui_value_changed" value-changed)
(callback/register "logseq_chat_lui_dismiss" dismiss)
(callback/register "logseq_chat_lui_double_press" double-press)
(callback/register "logseq_chat_lui_extension_event" extension-event)
(callback/register "logseq_chat_lui_dispose" dispose)
(callback/register "logseq_chat_lui_root_node" root-node)
(callback/register "logseq_chat_lui_take_effect" take-effect)
(callback/register "logseq_chat_lui_resolve_effect" resolve-effect)
