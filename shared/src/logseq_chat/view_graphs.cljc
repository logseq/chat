(ns logseq-chat.view-graphs
  (:require [logseq-chat.view-base :as base]
            [lui.elements :as elements]
            [lui.macros :refer [defui reactive event host?]]
            [lui.protocol :as proto :refer [TextChanged]]
            [lui.ui :as ui]
            [logseq-chat.model :as model]
            [signal.core :as signal]))

(defn graph-row [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<model/graph> graph-source local? send]
  (let [graph (signal/sample graph-source)
        graph-id (:id graph)]
    (elements/element
     ui-context nil
     [:list-item
      {:accessibility-identifier (base/graph-identifier graph)
       :padding 16
       :corner-radius 16
       :background (if (= (ui/host ui-context) proto/FlutterHost)
                     "surface-container-low"
                     "surface")
       :disabled (reactive base/graph-row-disabled? model-source graph-source)
       :on-press
       (event [current-graph graph-source]
              (send (model/RequestOpenGraph (:id current-graph))))}
      [:column {:gap 4 :grow 1.0}
       [:text
        {:class "semibold"
         :value (reactive base/graph-title graph-source)}]
       [:if {:test (reactive base/graph-status-visible? graph-source)}
        [:text
         {:value (reactive base/graph-status-title graph-source)
          :class "caption"
          :foreground "muted-foreground"
          :accessibility-identifier (base/graph-status-identifier graph)}]]]
      [:context-menu
       {:accessibility-identifier (base/graph-delete-identifier graph)}
       [:if {:test (reactive base/graph-row-local? model-source graph-source)}
        [:menu-item
         {:icon "app:trash"
          :variant "destructive"
          :disabled (reactive base/graph-delete-active? model-source graph-source)
          :on-press (fn [_event] (send (model/RequestDeleteGraph graph-id)))}
         "Delete local graph"]]]])))

(defn graph-list-row [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<model/graph> graph-source local? send]
  (let [graph (signal/sample graph-source)
        graph-id (:id graph)]
    (elements/element
     ui-context nil
     [:list-item
      {:icon (reactive (fn [current-graph]
                         (if (and (not (= (ui/host ui-context) proto/FlutterHost))
                                  (not local?) (= (:is-encrypted current-graph) true))
                           "app:graph-locked"
                           (base/graph-icon-name local? current-graph)))
                       graph-source)
       :min-height (if (= (ui/host ui-context) proto/FlutterHost) 56 44)
       :accessibility-identifier (base/graph-identifier graph)
       :disabled (if local?
                   (reactive base/graph-delete-active? model-source graph-source)
                   (reactive base/graph-row-disabled? model-source graph-source))
       :on-press
       (event [current-graph graph-source]
              (send (model/RequestOpenGraph (:id current-graph))))}
      [:column {:gap 4}
       [:text {:value (reactive base/graph-title graph-source)}]
       [:if {:test (reactive base/graph-not-ready? graph-source)}
        [:text
         {:class "caption"
          :foreground "muted-foreground"
          :accessibility-identifier (base/graph-status-identifier graph)}
         "Preparing"]]
       [:if {:test (reactive
                    (fn [current-graph]
                      (and (= (ui/host ui-context) proto/FlutterHost)
                           (= (:is-encrypted current-graph) true)))
                    graph-source)}
        [:text
         {:class "caption"
          :foreground "muted-foreground"}
         "Encrypted"]]]
      [:context-menu
       {:accessibility-identifier (base/graph-delete-identifier graph)}
       [:if {:test (reactive base/graph-row-local? model-source graph-source)}
        [:menu-item
         {:variant "destructive"
          :disabled (reactive base/graph-delete-active? model-source graph-source)
          :on-press (fn [_event] (send (model/RequestDeleteGraph graph-id)))}
         "Delete local graph"]]]])))

(defui graph-create-sheet [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:sheet
      {:text "Add sync graph"
       :height 480
       :accessibility-identifier "sheet.graph-create"
       :on-dismiss (fn [_event] (send model/DismissCreateGraph))}
      [:column
       {:grow 1.0
        :gap 24
        :accessibility-identifier "layout.graph-create.sheet"}
       [:column
        {:gap 20
         :cross "stretch"
         :class "form"
         :accessibility-identifier "form.graph-create"}
        [:text-field
         {:text (reactive base/model-new-graph-name model-source)
          :placeholder "Graph name"
          :label "Graph name"
          :accessibility-identifier "field.graph-name"
          :on-input
          (fn [input-event]
            (match input-event
              (TextChanged _node text) (send (model/ChangeNewGraphName text))
              _ true))}]
        [:switch
         {:checked (reactive base/model-new-graph-encrypted? model-source)
          :label "End-to-end encryption"
          :accessibility-identifier "toggle.graph-encryption"
          :on-toggle
          (fn [input-event]
            (match input-event
              (proto/ToggleChanged _node enabled)
              (send (model/ToggleNewGraphEncrypted enabled))
              _ true))}
         "End-to-end encryption"]
        [:text
         {:class "footnote"
          :foreground "muted-foreground"}
         "Encryption cannot be changed after the sync graph is created."]
        [:if {:test (reactive base/effect-error-present? model-source)}
         [:text
          {:value (reactive base/effect-error-message model-source)
           :class "footnote"
           :foreground "destructive"
           :accessibility-identifier "text.graph-create.error"}]]]
       [:spacer {:grow 1.0}]
       [:row
        {:main "end" :cross "center"}
        [:toolbar
         {:orientation "horizontal"
          :gap 12
          :label "Graph creation actions"
          :accessibility-identifier "toolbar.graph-create"}
         [:button
          {:variant "ghost"
           :accessibility-identifier "button.graph-add.cancel"
           :on-press (fn [_event] (send model/DismissCreateGraph))}
          "Cancel"]
         [:button
          {:variant "primary"
           :accessibility-identifier "button.graph-add.confirm"
           :disabled (reactive base/graph-create-disabled? model-source)
           :on-press (fn [_event] (send model/SubmitCreateGraph))}
          "Add"]]]]])
    (elements/element
     ui-context nil
     [:sheet
      {:text "Add sync graph"
       :class "navigation-form"
       :accessibility-identifier "sheet.graph-create"
       :on-dismiss (fn [_event] (send model/DismissCreateGraph))}
      [:column
       {:class "form"
        :accessibility-identifier "form.graph-create"}
       [:text-field
        {:text (reactive base/model-new-graph-name model-source)
         :placeholder "Graph name"
         :label "Graph name"
         :accessibility-identifier "field.graph-name"
         :on-input
         (fn [input-event]
           (match input-event
             (TextChanged _node text) (send (model/ChangeNewGraphName text))
             _ true))}]
       [:toggle
        {:checked (reactive base/model-new-graph-encrypted? model-source)
         :label "End-to-end encryption"
         :accessibility-identifier "toggle.graph-encryption"
         :on-toggle
         (fn [input-event]
           (match input-event
             (proto/ToggleChanged _node enabled)
             (send (model/ToggleNewGraphEncrypted enabled))
             _ true))}
        "End-to-end encryption"]
       [:text
        {:class "footnote"
         :foreground "muted-foreground"}
        "Encryption cannot be changed after the sync graph is created."]
       [:if {:test (reactive base/effect-error-present? model-source)}
        [:text
         {:value (reactive base/effect-error-message model-source)
          :class "footnote"
          :foreground "destructive"
          :accessibility-identifier "text.graph-create.error"}]]]
      [:toolbar
       {:orientation "horizontal"
        :label "Graph creation actions"
        :class "navigation-actions"
        :accessibility-identifier "toolbar.graph-create"}
       [:button
        {:class "cancellation-action"
         :accessibility-identifier "button.graph-add.cancel"
         :on-press (fn [_event] (send model/DismissCreateGraph))}
        "Cancel"]
       [:button
        {:class "confirmation-action"
         :accessibility-identifier "button.graph-add.confirm"
         :disabled (reactive base/graph-create-disabled? model-source)
         :on-press (fn [_event] (send model/SubmitCreateGraph))}
        "Add"]]])))

(defui graph-delete-dialog [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:dialog
      {:text "Delete local graph"
       :height 320
       :accessibility-identifier "dialog.graph-delete"
       :on-dismiss (fn [_event] (send model/CancelDeleteGraph))}
      [:column {:gap 16 :cross "stretch"}
       [:row {:gap 12 :cross "center"}
        [:icon
         {:name "app:warning"
          :width 28
          :height 28
          :foreground "destructive"
          :accessibility-identifier "icon.graph-delete-warning"
          :accessibility-label "Warning"}]
        [:text
         {:value (reactive base/graph-deletion-message model-source)
          :grow 1.0
          :accessibility-identifier "text.graph-delete-warning"}]]
       [:text
        {:foreground "muted-foreground"}
        "This graph cannot be recovered after deletion. Make sure you have a backup."]
       [:spacer {:grow 1.0}]
       [:row {:main "end"}
        [:toolbar
         {:orientation "horizontal"
          :gap 12
          :label "Graph deletion actions"
          :accessibility-identifier "toolbar.graph-delete"}
         [:button
          {:variant "ghost"
           :accessibility-identifier "button.graph-delete.cancel"
           :on-press (fn [_event] (send model/CancelDeleteGraph))}
          "Cancel"]
         [:button
          {:variant "destructive"
           :accessibility-identifier "button.graph-delete.confirm"
           :on-press (fn [_event] (send model/ConfirmDeleteGraph))}
          "Delete"]]]]])
    (elements/element
     ui-context nil
     [:dialog
      {:text "Delete local graph"
       :on-dismiss (fn [_event] (send model/CancelDeleteGraph))}
      [:column
       [:text
        {:value (reactive base/graph-deletion-message model-source)
         :accessibility-identifier "text.graph-delete-warning"}]
       [:text "⚠️ Notice that we can't recover this graph after being deleted. Make sure you have backups before deleting it."]
       [:button
        {:on-press (fn [_event] (send model/CancelDeleteGraph))}
        "Cancel"]
       [:button
        {:on-press (fn [_event] (send model/ConfirmDeleteGraph))}
        "Confirm"]]])))

(defui graph-picker-overflow-menu [send]
  (let [node (ui/extension! ui-context "native-overflow-menu")]
    (ui/extension-property!
     ui-context node "page-actions-visible" (proto/BoolValue false))
    (ui/extension-property!
     ui-context node "favorite-label" (proto/StringValue "Favorite"))
    (ui/extension-property!
     ui-context node "settings-visible" (proto/BoolValue true))
    (ui/on-event!
     ui-context node
     (fn [input-event]
       (base/handle-native-overflow-menu-event input-event send)))
    node))

(defui graph-picker-error-banner [^:signal<model/chat-model> model-source]
  [:alert
   {:variant "destructive"
    :accessibility-identifier "error.banner"
    :padding 14
    :corner-radius 16
    :border-width 0}
   [:column {:gap 4}
    [:heading
     {:level 5
      :value (reactive base/graph-picker-error-title model-source)
      :accessibility-identifier "error.banner.code"}]
    [:text
     {:value (reactive base/graph-picker-error-message model-source)
      :accessibility-identifier "error.banner.message"}]]])

(defui graph-password-sheet [^:signal<model/chat-model> model-source send]
  [:sheet
   {:text "Unlock encrypted graphs"
    :on-dismiss (fn [_event] (send model/CancelGraphUnlock))}
   [:column
    [:text "Unlock encrypted graphs"]
    [:secure-field
     {:text (reactive base/model-graph-password model-source)
      :placeholder "E2EE password"
      :label "E2EE password"
      :accessibility-identifier "field.graph-password"
      :on-input
      (fn [input-event]
        (match input-event
          (TextChanged _node text) (send (model/ChangeGraphPassword text))
          _ true))}]
    [:if {:test (reactive base/graph-unlock-error-present? model-source)}
     [:text
      {:value (reactive base/graph-unlock-error-message model-source)
       :accessibility-identifier "text.graph-unlock-error"}]]
    [:button
     {:accessibility-identifier "button.graph-unlock.cancel"
      :on-press (fn [_event] (send model/CancelGraphUnlock))}
     "Cancel"]
    [:button
     {:accessibility-identifier "button.graph-unlock"
      :disabled (reactive base/graph-unlock-disabled? model-source)
      :on-press (fn [_event] (send model/SubmitGraphPassword))}
     "Unlock"]]])

(defui graphs-screen [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:list {:accessibility-identifier "screen.graphs"
             :gap 0}
      [:row
       {:gap 12
        :padding 16
        :accessibility-identifier "row.graphs.actions"}
       [:button
        {:icon "app:sync-status"
         :variant "secondary"
         :grow 1.0
         :accessibility-identifier "button.graphs.refresh"
         :disabled (reactive model/graph-refresh-active? model-source)
         :on-press (fn [_event] (send model/RefreshGraphs))}
        "Refresh"]
       [:button
        {:icon "app:add"
         :variant "primary"
         :grow 1.0
         :accessibility-identifier "button.graph-add"
         :on-press (fn [_event] (send model/OpenCreateGraph))}
        "Add graph"]]
      [:if {:test (reactive model/graph-refresh-active? model-source)}
       [:box {:padding 16}
        [:spinner {:accessibility-identifier "graphs.loading"}]]]
      [:box {:padding 16}
       [:heading {:level 5} "Local graphs"]]
      [:if {:test (reactive base/local-graphs-empty? model-source)}
       [:box {:padding 16}
        [:text {:foreground "muted-foreground"} "No local graphs"]]]
      [:keyed
       {:source (reactive base/local-graphs model-source)
        :key base/graph-identifier
        :compare compare
        :as graph-source}
       [graph-list-row model-source graph-source true send]]
      [:if {:test (reactive base/remote-graphs-present? model-source)}
       [:box {:padding 16}
        [:heading {:level 5} "Remote graphs"]]]
      [:keyed
       {:source (reactive base/remote-graphs model-source)
        :key base/graph-identifier
        :compare compare
        :as graph-source}
       [graph-list-row model-source graph-source false send]]])
    (elements/element
     ui-context nil
     [:list {:accessibility-identifier "screen.graphs"
             :gap 4}
      [:list-item
       {:icon "app:refresh"
        :min-height 44
        :accessibility-identifier "button.graphs.refresh"
        :disabled (reactive model/graph-refresh-active? model-source)
        :on-press (fn [_event] (send model/RefreshGraphs))}
       "Refresh"]
      [:if {:test (reactive model/graph-refresh-active? model-source)}
       [:spinner {:accessibility-identifier "graphs.loading"}]]
      [:list-item
       {:min-height 44
        :accessibility-identifier "button.graph-add"
        :on-press (fn [_event] (send model/OpenCreateGraph))}
       "Add sync graph"]
      [:heading {:level 5 :accessibility-identifier "heading.graphs.local"}
       "Local graphs:"]
      [:if {:test (reactive base/local-graphs-empty? model-source)}
       [:text {:foreground "secondary"} "No local graphs"]]
      [:keyed
       {:source (reactive base/local-graphs model-source)
        :key base/graph-identifier
        :compare compare
        :as graph-source}
       [graph-list-row model-source graph-source true send]]
      [:if {:test (reactive base/remote-graphs-present? model-source)}
       [:heading {:level 5 :accessibility-identifier "heading.graphs.remote"}
        "Remote graphs:"]]
      [:keyed
       {:source (reactive base/remote-graphs model-source)
        :key base/graph-identifier
        :compare compare
        :as graph-source}
       [graph-list-row model-source graph-source false send]]])))

(defui flutter-graph-picker-loading-state []
  [:column
   {:grow 1.0
    :main "center"
    :cross "center"
    :gap 12
    :accessibility-identifier "loading.graph-picker"}
   [:spinner {:accessibility-identifier "graphs.loading"}]
   [:text
    {:foreground "muted-foreground"}
    "Loading sync graphs…"]])

(defui flutter-graph-picker-empty-state [send]
  [:column
   {:grow 1.0
    :main "center"
    :cross "stretch"}
   [:column
    {:cross "center"
     :gap 16
     :accessibility-identifier "empty.graph-picker"}
    [:icon
     {:name "app:graph-remote"
      :width 48
      :height 48
      :foreground "primary"}]
    [:heading {:level 3} "No sync graphs yet"]
    [:text
     {:foreground "muted-foreground"
      :text-alignment "center"}
     "Create a graph to start capturing and syncing notes on this device."]
    [:button
     {:icon "app:add"
      :variant "primary"
      :accessibility-identifier "button.graph-add"
      :on-press (fn [_event] (send model/OpenCreateGraph))}
     "Add sync graph"]
    [:button
     {:icon "app:sync-status"
      :variant "ghost"
      :foreground "foreground"
      :accessibility-identifier "button.graphs.refresh"
      :on-press (fn [_event] (send model/RefreshGraphs))}
     "Refresh"]]])

(defui flutter-graph-picker-catalog [^:signal<model/chat-model> model-source send]
  [:column
   {:grow 1.0
    :gap 16}
   [:button
    {:icon "app:add"
     :variant "primary"
     :accessibility-identifier "button.graph-add"
     :on-press (fn [_event] (send model/OpenCreateGraph))}
    "Add sync graph"]
   [:scroll {:grow 1.0}
    [:column {:gap 12}
     [:keyed
      {:source (reactive base/model-graphs model-source)
       :key base/graph-identifier
       :compare compare
       :as graph-source}
      [graph-row model-source graph-source false send]]]]])

(defui graph-picker-screen [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:column
      {:accessibility-identifier "screen.graph-picker"
       :main "start"
       :cross "stretch"
       :grow 1.0
       :gap 16
       :padding 24}
      [:row {:main "space_between" :cross "center"}
       [:heading
        {:level 3
         :accessibility-identifier "title.graph-picker"}
        "Choose a graph"]
       [graph-picker-overflow-menu send]]
      [:text
       {:foreground "muted-foreground"}
       "Select a Logseq graph to download and sync on this device."]
      [:if {:test (reactive base/graph-picker-error-present? model-source)}
       [graph-picker-error-banner model-source]]
      [:if {:test (reactive base/empty-graphs-loading? model-source)}
       [flutter-graph-picker-loading-state]]
      [:if {:test (reactive base/empty-graphs-refreshable? model-source)}
       [flutter-graph-picker-empty-state send]]
      [:if {:test (reactive base/graphs-present? model-source)}
       [flutter-graph-picker-catalog model-source send]]])
    (elements/element
     ui-context nil
     [:column
      {:accessibility-identifier "screen.graph-picker"
       :main "start"
       :grow 1.0
       :container-relative-frame "vertical"
       :gap 20
       :padding 24}
      [:row {:main "space_between" :cross "center"}
       [:heading "Choose a graph"]
       [graph-picker-overflow-menu send]]
      [:text
       {:foreground "muted-foreground"}
       "Select a Logseq graph to download and sync on this device."]
      [:button
       {:variant "ghost"
        :foreground "foreground"
        :accessibility-identifier "button.graph-add"
        :on-press (fn [_event] (send model/OpenCreateGraph))}
       "Add sync graph"]
      [:if {:test (reactive base/graph-picker-error-present? model-source)}
       [graph-picker-error-banner model-source]]
      [:if {:test (reactive base/empty-graphs-loading? model-source)}
       [:spinner {:accessibility-identifier "graphs.loading"}]]
      [:if {:test (reactive base/empty-graphs-refreshable? model-source)}
       [:button
        {:variant "ghost"
         :foreground "foreground"
         :accessibility-identifier "button.graphs.refresh"
         :on-press (fn [_event] (send model/RefreshGraphs))}
        "Refresh graphs"]]
      [:scroll {:grow 1.0}
       [:column {:gap 12}
        [:keyed
         {:source (reactive base/model-graphs model-source)
          :key base/graph-identifier
          :compare compare
          :as graph-source}
         [graph-row model-source graph-source false send]]]]])))
