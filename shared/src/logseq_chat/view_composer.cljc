(ns logseq-chat.view-composer
  (:require [logseq-chat.view-base :as base]
            [lui.elements :as elements]
            [lui.macros :refer [defui reactive event host?]]
            [lui.protocol :as proto :refer [TextChanged]]
            [lui.ui :as ui]
            [logseq-chat.model :as model]
            [signal.core :as signal]))


(defui composer-attachment-button [send]
  (if (= (ui/platform ui-context) proto/AndroidOS)
    (elements/element
     ui-context nil
     [:button
      {:icon "app:add"
       :variant "ghost"
       :label "Add attachment"
       :accessibility-identifier "button.attachment"
       :on-press (fn [_event] (send model/OpenAttachmentPicker))}
      "Attach"
      [:context-menu
       [:menu-item
        {:icon "app:toolbar-attachment"
         :accessibility-identifier "button.attachment.files"
         :on-press (fn [_event] (send (model/ChooseAttachment "files")))}
        "File"]
       [:menu-item
        {:icon "app:toolbar-camera"
         :accessibility-identifier "button.attachment.camera"
         :on-press (fn [_event] (send (model/ChooseAttachment "camera")))}
        "Camera"]
       [:menu-item
        {:icon "app:composer-photo"
         :accessibility-identifier "button.attachment.photos"
         :on-press (fn [_event] (send (model/ChooseAttachment "photos")))}
        "Photo"]
       [:menu-item
        {:icon "app:toolbar-audio"
         :accessibility-identifier "button.attachment.audio"
         :on-press (fn [_event] (send (model/ChooseAttachment "audio")))}
        "Audio recording"]]])
    (elements/element
     ui-context nil
     [:button
      {:icon "app:composer-add"
       :variant "ghost"
       :width 32
       :height 32
       :label "Add attachment"
       :accessibility-identifier "button.attachment"
       :on-press (fn [_event] (send model/OpenAttachmentPicker))}
      [:context-menu
       [:menu-item
        {:icon "app:toolbar-attachment"
         :accessibility-identifier "button.attachment.files"
         :on-press (fn [_event] (send (model/ChooseAttachment "files")))}
        "File"]
       [:menu-item
        {:icon "app:toolbar-camera"
         :accessibility-identifier "button.attachment.camera"
         :on-press (fn [_event] (send (model/ChooseAttachment "camera")))}
        "Camera"]
       [:menu-item
        {:icon "app:composer-photo"
         :accessibility-identifier "button.attachment.photos"
         :on-press (fn [_event] (send (model/ChooseAttachment "photos")))}
        "Photo"]
       [:menu-item
        {:icon "app:toolbar-audio"
         :accessibility-identifier "button.attachment.audio"
         :on-press (fn [_event] (send (model/ChooseAttachment "audio")))}
        "Audio recording"]]])))

(defui composer-task-status-button [send]
  (if (= (ui/platform ui-context) proto/AndroidOS)
    (elements/element
     ui-context nil
     [:button
      {:icon "app:task-todo"
       :variant "ghost"
       :foreground "border"
       :label "Task status"
       :accessibility-identifier "button.task-status"
       :on-press (fn [_event] (send model/OpenTaskStatusPicker))}
      "Task"])
    (elements/element
     ui-context nil
     [:button
      {:icon "app:task-todo"
       :variant "ghost"
       :size "icon"
       :width 32
       :height 32
       :foreground "border"
       :label "Task status"
       :accessibility-identifier "button.task-status"
       :on-press (fn [_event] (send model/OpenTaskStatusPicker))}])))

(defui android-composer-send-button [disabled-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:button
      {:icon "app:send"
       :variant "primary"
       :size "icon"
       :width 48
       :height 48
       :label "Send"
       :accessibility-identifier "button.send"
       :disabled disabled-source
       :on-press (fn [_event] (send model/SendComposer))}])
    (elements/element
     ui-context nil
     [:button
      {:icon "app:send"
       :variant "primary"
       :label "Send"
       :accessibility-identifier "button.send"
       :disabled disabled-source
       :on-press (fn [_event] (send model/SendComposer))}
      "Send"])))

(defui apple-composer-send-button [disabled-source send]
  [:button
   {:icon "app:arrow-up"
    :variant "ghost"
    :width 36
    :height 36
    :background "black"
    :foreground "white"
    :corner-radius 18
    :label "Send"
    :accessibility-identifier "button.send"
    :disabled disabled-source
    :on-press (fn [_event] (send model/SendComposer))}])

(defui composer-send-button [disabled-source send]
  (if (= (ui/platform ui-context) proto/AndroidOS)
    (android-composer-send-button ui-context disabled-source send)
    (apple-composer-send-button ui-context disabled-source send)))

(defui collapsed-composer-button [send]
  (if (= (ui/platform ui-context) proto/AndroidOS)
    (if (host? proto/FlutterHost)
      (elements/element
       ui-context nil
       [:button
        {:icon "app:add"
         :variant "secondary"
         :grow 1.0
         :height 58
         :padding-horizontal 20
         :label "Capture a thought"
         :accessibility-identifier "button.composer.expand"
         :on-press (fn [_event] (send model/ExpandComposer))}
        "Capture a thought"])
      (elements/element
       ui-context nil
       [:button
        {:variant "ghost"
         :height 58
         :padding-horizontal 30
         :foreground "muted-foreground"
         :accessibility-identifier "button.composer.expand"
         :on-press (fn [_event] (send model/ExpandComposer))}
        "Capture"]))
    (elements/element
     ui-context nil
     [:button
      {:variant "ghost"
       :ios [[:liquid-glass {:shape "capsule"}]]
       :grow 1.0
       :height 58
       :padding-horizontal 30
       :foreground "muted-foreground"
       :accessibility-identifier "button.composer.expand"
       :on-press (fn [_event] (send model/ExpandComposer))}
      "Capture"])))

(defn composer-asset-preview [^ui/ui-context ui-context ^:signal<model/composer-asset> asset-source]
  (let [node (ui/extension! ui-context "composer-asset")]
    (ui/extension-property-signal! ui-context node "title"
     (reactive base/string-wire-value (reactive base/composer-asset-title asset-source)))
    (ui/extension-property-signal! ui-context node "local-path"
     (reactive base/string-wire-value (reactive base/composer-asset-path asset-source)))
    node))

(defn composer-asset-view [^ui/ui-context ui-context ^:signal<model/composer-asset> asset-source send]
  (let [asset (signal/sample asset-source)]
    (elements/element ui-context nil
     [:stack {:width 128 :height 128
              :accessibility-identifier (base/composer-asset-identifier asset)}
      [composer-asset-preview asset-source]
      [:column {:width 128 :height 128 :padding 4 :main "start"}
       [:row {:main "end" :height 24}
        [:button {:icon "app:close" :variant "ghost" :size "sm"
                  :width 24 :height 24 :corner-radius 12
                  :background "muted-foreground" :foreground "white"
                  :label "Remove attachment"
                  :accessibility-identifier "composer.asset.remove"
                  :on-press (event [current-asset asset-source]
                             (send (model/RemoveComposerAsset (:uuid current-asset))))}]]
       [:spacer {:grow 1.0}]]])))

(defn task-status-row [^ui/ui-context ui-context ^:signal<model/task-status> status-source send]
  (let [status (signal/sample status-source)]
    (elements/element
     ui-context nil
     [:menu-item
      {:text (reactive base/task-status-title status-source)
       :icon (reactive base/task-status-icon-name status-source)
       :foreground-signal (reactive base/task-status-foreground status-source)
       :accessibility-identifier (base/task-status-identifier status)
       :on-press
       (event [current-status status-source]
              (send (model/ChooseTaskStatus (:uuid current-status))))}])))

(defui task-status-picker-dialog [^:signal<model/chat-model> model-source send]
  [:dropdown-menu
   {:anchor "above"
    :anchor-alignment "start"
    :min-width 220
    :on-dismiss (fn [_event] (send model/CloseTaskStatusPicker))}
   [:keyed
    {:source (reactive base/model-task-statuses model-source)
     :key base/task-status-identifier
     :compare compare
     :as status-source}
    [task-status-row status-source send]]
   [:if {:test (reactive base/task-status-selected? model-source)}
    [:menu-item
     {:accessibility-identifier "button.task-status.clear"
      :on-press (fn [_event] (send model/ClearTaskStatus))}
     "Clear task status"]]])

(defui composer-view [^:signal<model/chat-model> model-source send]
  [:box
   {:accessibility-identifier "surface.composer.root"
    :grow 1.0
    :min-height 58}
   [:if {:test (reactive base/composer-expanded? model-source)}
    [:column
     {:ios [[:liquid-glass {:shape "rounded-rectangle"}]]
      :grow 1.0
      :main "end"
      :gap 0
      :padding-horizontal (if (host? proto/FlutterHost) 12 16)
      :padding-vertical (if (host? proto/FlutterHost) 12 8)
      :background (if (host? proto/FlutterHost)
                    "surface-container-high"
                    "glass-fallback")
      :corner-radius 24
      :on-press (fn [_event] (send model/FocusComposer))}
     [:box
      {:height 6
       :accessibility-identifier "spacer.composer.top"}]
     [:if {:test (reactive base/composer-assets-present? model-source)}
      [:scroll {:orientation "horizontal" :height 140}
       [:row {:gap 8}
        [:keyed {:source (reactive base/model-composer-assets model-source)
                 :key base/composer-asset-identifier :compare compare :as asset-source}
         [composer-asset-view asset-source send]]]]]
     [:textarea
      {:text (reactive base/composer-draft model-source)
       :autofocus (reactive base/composer-autofocus? model-source)
       :min-height 36
       :class "composer-input"
       :placeholder "Capture"
       :label "Capture"
       :accessibility-identifier "field.composer"
       :on-input
       (fn [input-event]
         (match input-event
           (TextChanged _node text)
           (send (model/ChangeComposerDraft text))
           _ true))
       :on-submit (fn [_event] (send model/SendComposer))}]
     [:box
      {:height 8
       :accessibility-identifier "spacer.composer.field-controls"}]
     [:row
      {:gap 8
       :height 44
       :cross-alignment "center"
       :accessibility-identifier "row.composer.controls"}
      [composer-attachment-button send]
      [:stack
       [composer-task-status-button send]
       [:if {:test (reactive base/model-task-status-picker-open? model-source)}
        [task-status-picker-dialog model-source send]]]
      [:spacer
       {:grow 1.0
        :accessibility-identifier "spacer.composer.controls"}]
      [composer-send-button
       (reactive base/composer-send-disabled? model-source) send]]]]
   [:if {:test (reactive base/composer-collapsed? model-source)}
    [collapsed-composer-button send]]])

(defn outliner-task-status-row [^ui/ui-context ui-context block-id ^:signal<model/task-status> status-source send]
  (let [status (signal/sample status-source)]
    (elements/element
     ui-context nil
     [:menu-item
      {:text (reactive base/task-status-title status-source)
       :icon (reactive base/task-status-icon-name status-source)
       :foreground "secondary"
       :accessibility-identifier
       (base/outliner-task-status-option-identifier status)
       :on-press
       (event [current-status status-source]
              (send
               (model/SetOutlinerTaskStatus block-id
                                            (:uuid current-status))))}])))
