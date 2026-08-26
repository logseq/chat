(ns logseq-chat.native-bridge
  (:require [lui.app :as driver]
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

(defn encode-effect [effect]
  (match effect
    (model/SendCaptureEffect id text)
    (str "{\"id\":" id
         ",\"kind\":\"send-capture\",\"text\":"
         (wire/quoted text) "}")
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
         (wire/quoted action) "}")))

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

(defn outliner-editor-event [node name text value]
  (let [values
        (cond
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
     (proto/ExtensionEvent node "outliner-editor" name values))))

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
(callback/register
 "logseq_chat_lui_outliner_editor_event" outliner-editor-event)
(callback/register "logseq_chat_lui_dispose" dispose)
(callback/register "logseq_chat_lui_root_node" root-node)
(callback/register "logseq_chat_lui_take_effect" take-effect)
(callback/register "logseq_chat_lui_resolve_effect" resolve-effect)
