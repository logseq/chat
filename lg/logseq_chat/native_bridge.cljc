(ns logseq-chat.native-bridge
  (:require [lui.app :as driver]
            [lui.backend.apple :as apple]
            [lui.protocol :as proto]
            [lui.wire :as wire]
            [logseq-chat.app :as chat]
            [logseq-chat.model :as model]
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
         (wire/quoted text) "}")))

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
  (let [renderer (apple/create-wire send-patch!)
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
(defn hold [node] (flush-event! (proto/Hold node)))
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

(defn dispose []
  (reset! latest-patch "")
  (driver/dispose! (app))
  (reset! current-app None)
  (deref latest-patch))

(defn root-node [] (driver/root-node (app)))

(callback/register "logseq_chat_lui_init" initialize)
(callback/register "logseq_chat_lui_press" press)
(callback/register "logseq_chat_lui_hold" hold)
(callback/register "logseq_chat_lui_text_changed" text-changed)
(callback/register "logseq_chat_lui_submit" submit)
(callback/register "logseq_chat_lui_toggle_changed" toggle-changed)
(callback/register "logseq_chat_lui_change" change)
(callback/register "logseq_chat_lui_value_changed" value-changed)
(callback/register "logseq_chat_lui_dismiss" dismiss)
(callback/register "logseq_chat_lui_double_press" double-press)
(callback/register "logseq_chat_lui_dispose" dispose)
(callback/register "logseq_chat_lui_root_node" root-node)
(callback/register "logseq_chat_lui_take_effect" take-effect)
(callback/register "logseq_chat_lui_resolve_effect" resolve-effect)
