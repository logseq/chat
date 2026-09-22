(ns logseq-chat.view-screens
  (:require [logseq-chat.view-base :as base]
            [logseq-chat.view-rows :as rows]
            [logseq-chat.view-sidebar :as sidebar]
            [logseq-chat.view-outliner :as outl]
            [logseq-chat.view-composer :as composer]
            [logseq-chat.view-flashcards :as cards]
            [logseq-chat.view-graphs :as graphsv]
            [logseq-chat.view-settings :as settings]
            [lui.elements :as elements]
            [lui.macros :refer [defui reactive event host?]]
            [lui.protocol :as proto :refer [TextChanged]]
            [lui.ui :as ui]
            [logseq-chat.model :as model]
            [signal.core :as signal]))

(defn search-result-row [^ui/ui-context ui-context ^:signal<model/search-hit> hit-source send]
  (let [hit (signal/sample hit-source)
        row (elements/element
     ui-context nil
     [:list-item
      {:accessibility-identifier (base/search-result-identifier hit)
       :on-press
       (event [current-hit hit-source]
              (send (model/RequestSearchNode (:uuid current-hit))))}
      [:column {:gap 4 :padding-vertical 6 :grow 1.0}
       [:text {:value (reactive base/search-result-title hit-source)
               :class "search-match line-clamp-3"
               :accessibility-identifier (str "search.result.title." (:uuid hit))}]
       [:if {:test (reactive base/search-result-context-present? hit-source)}
        [:text {:value (reactive base/search-result-breadcrumb hit-source)
                :class "caption single-line"
                :foreground "muted-foreground"
                :accessibility-identifier (str "search.result.context." (:uuid hit))}]]]])]
    (if (:is-page hit)
      (ui/string-property! ui-context row proto/InlineIconName "app:document")
      false)
    row))

(defui search-screen [^:signal<model/chat-model> model-source send]
  [:column
   {:grow 1.0
    :accessibility-identifier "screen.search"}
   [:row {:height 24 :gap 6 :cross "center" :padding-horizontal 20}
    [:if {:test (reactive base/model-search-loading? model-source)}
     [:spinner {:width 12 :height 12 :accessibility-identifier "search.loading"}]]
    [:text {:value (reactive base/search-result-status model-source)
            :class "caption"
            :foreground "muted-foreground"
            :accessibility-identifier "search.status"}]]
   [:if {:test (reactive base/search-empty-state-present? model-source)}
    [:column {:grow 1.0
              :main "center"
              :cross "center"
              :gap 10
              :padding 32}
     [:icon {:name "app:search"
             :width 48
             :height 48
             :foreground "muted-foreground"
             :accessibility-identifier "search.empty.icon"}]
     [:text {:value (reactive base/search-empty-message model-source)
             :class "headline"
             :text-alignment "center"
             :accessibility-identifier "search.empty"}]
     [:text {:value (reactive base/search-empty-supporting-message
                              (reactive base/model-search-query model-source))
             :foreground "muted-foreground"
             :text-alignment "center"
             :accessibility-identifier "search.empty.supporting"}]]]
   [:if {:test (reactive base/search-results-present? model-source)}
    [:list {:grow 1.0
            :accessibility-identifier "screen.search.results"}
     [:if {:test (reactive base/page-search-results-present? model-source)}
      [:heading {:level 5
                 :accessibility-identifier "search.section.pages"}
       "Pages"]]
     [:keyed
      {:source (reactive base/page-search-results model-source)
       :key base/search-result-identifier
       :compare compare
       :as hit-source}
      [search-result-row hit-source send]]
     [:if {:test (reactive base/block-search-results-present? model-source)}
      [:heading {:level 5
                 :accessibility-identifier "search.section.blocks"}
       "Blocks"]]
     [:keyed
      {:source (reactive base/block-search-results model-source)
       :key base/search-result-identifier
       :compare compare
       :as hit-source}
      [search-result-row hit-source send]]]]])

(defui capture-and-search-row [^:signal<model/chat-model> model-source send]
  (if (= (ui/platform ui-context) proto/AndroidOS)
    (elements/element
     ui-context nil
     [:row
     {:gap 10
       :cross "center"
       :accessibility-identifier "row.bottom.capture"}
      [composer/composer-view model-source send]
      [:button
       {:icon "app:search"
        :variant "secondary"
        :size "icon"
        :width 58
        :height 58
        :label "Search"
        :accessibility-identifier "button.search"
        :on-press (fn [_event] (send model/OpenSearch))}]])
    (elements/element
     ui-context nil
     [:row
      {:grow 1.0
       :gap 10
       :cross "center"
       :accessibility-identifier "row.bottom.capture"}
      [composer/composer-view model-source send]
      [:button
       {:icon "app:search"
        :variant "ghost"
        :ios [[:liquid-glass {:shape "circle"}]]
        :size "icon"
        :width 58
        :height 58
        :label "Search"
        :accessibility-identifier "button.search"
        :on-press (fn [_event] (send model/OpenSearch))}]])))

(defui main-bottom-chrome [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:stack
      [:if {:test (reactive base/bottom-chrome-selection? model-source)}
       [:column {:gap 0 :padding-horizontal 16}
        [outl/outliner-selection-toolbar send]
        [:box {:height 21}]]]
      [:if {:test (reactive base/bottom-chrome-editor? model-source)}
       [:column
        {:gap 0
         :cross "stretch"
         :background "surface-container-low"
         :corner-radius 20
         :accessibility-identifier "container.outliner.editor-chrome"}
        [:if {:test (reactive base/outliner-autocomplete-active? model-source)}
         [outl/outliner-autocomplete-bar model-source send]]
        [outl/outliner-editor-toolbar model-source send]]]
      [:if {:test (reactive base/bottom-chrome-expanded-composer? model-source)}
       [:column
        {:gap 0 :padding-horizontal 16}
        [:box {:height 6}]
        [:row
         {:cross "center"
          :accessibility-identifier "row.composer.placement"}
         [composer/composer-view model-source send]]
        [:box {:height 21}]]]
      [:if {:test (reactive base/bottom-chrome-capture-and-search? model-source)}
       [:column
        {:gap 0 :padding-horizontal 16}
        [:box {:height 8}]
        [capture-and-search-row model-source send]
        [:box {:height 21}]]]])
    (elements/element
     ui-context nil
     [:stack
      [:if {:test (reactive base/bottom-chrome-selection? model-source)}
       [:column {:gap 0 :padding-horizontal 16}
        [outl/outliner-selection-toolbar send]
        [:box {:height 21}]]]
      [:if {:test (reactive base/bottom-chrome-editor? model-source)}
       [:box {:ios [[:liquid-glass {:shape "container"}]]}
        [:if {:test (reactive base/outliner-autocomplete-active? model-source)}
         [outl/outliner-autocomplete-bar model-source send]]
        [outl/outliner-editor-toolbar model-source send]]]
      [:if {:test (reactive base/bottom-chrome-expanded-composer? model-source)}
       [:column
        {:container-relative-frame "horizontal"
         :cross "stretch"
         :gap 0
         :padding-horizontal 16}
        [:box {:height 6}]
        [:row
         {:cross "center"
          :accessibility-identifier "row.composer.placement"}
         [composer/composer-view model-source send]]
        [:box {:height 21}]]]
      [:if {:test (reactive base/bottom-chrome-capture-and-search? model-source)}
       [:column
        {:container-relative-frame "horizontal"
         :cross "stretch"
         :gap 0
         :padding-horizontal 16}
        [:box {:height 8}]
        [capture-and-search-row model-source send]
        [:box {:height 21}]]]])))

(defui root-outliner-view [^:signal<model/chat-model> model-source visible-source send]
  [:box
   {:grow 1.0
    :accessibility-identifier "layout.outliner.horizontal-inset"}
   [:virtual-list
    {:grow 1.0
     :class "retained-pane scroll-section-titles"
     :selected visible-source
     :accessibility-identifier "list.outliner"}
    [:box
     {:height 16
      :accessibility-identifier "spacer.outliner.top"}]
    [:if {:test (reactive base/selected-page-content-title-visible? model-source)}
     [:column {:gap 0}
      [:box {:height 26}]
      [:box
       {:padding-horizontal 16
        :accessibility-identifier "layout.selected-page.title"}
       [:heading
        {:level 3
         :value (reactive base/selected-page-title model-source)
         :accessibility-identifier "title.selected-page"}]]
      [:box {:height 12}]]]
     [:if {:test (reactive rows/first-journal-section-visible? model-source)}
      [outl/outliner-first-journal-section model-source send]]
     [:keyed
      {:source (reactive rows/remaining-retained-outliner-rows model-source)
       :key rows/retained-row-identifier
       :compare compare
       :as retained-row-source}
      [outl/outliner-entry model-source retained-row-source
       (reactive rows/retained-row-value retained-row-source) send]]
     [:if {:test (reactive base/older-journals-visible? model-source)}
      [:box
       {:height 1
        :accessibility-identifier "outliner.load-older-sentinel"
        :on-appear
        (fn [_event] (send model/LoadOlderJournals))}]]
     [:if {:test (reactive base/main-can-add-first-block? model-source)}
      [:box {:padding-horizontal 8}
       [outl/add-first-block-button model-source send]]]
     [:if {:test (reactive base/main-related-section-visible? model-source)}
      [:box {:padding-horizontal 8}
       [outl/node-related-section model-source send]]]
     [:if {:test (reactive base/main-tag-section-visible? model-source)}
      [:box {:padding-horizontal 8}
       [outl/node-tagged-section model-source send]]]
     [:if {:test (reactive base/main-linked-reference-section-visible? model-source)}
      [:box {:padding-horizontal 8}
       [outl/node-linked-reference-section model-source send]]]
     [:box {:height 120}]]])

(defui retained-journal-pane [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:stack {:grow 1.0}
      [:if {:test (reactive base/journal-home-visible? model-source)}
       [:box {:grow 1.0 :accessibility-identifier "pane.journals"}
        [root-outliner-view
         (reactive base/journal-navigation-model model-source)
         (reactive base/journal-home-visible? model-source)
         send]]]])
    (elements/element
     ui-context nil
     [:box {:grow 1.0 :accessibility-identifier "pane.journals"}
      [root-outliner-view
       (reactive base/journal-navigation-model model-source)
       (reactive
        (fn [current]
          (base/journal-home-visible?
           (assoc current :node-routes [] :app-navigation-path []
                          :search-open false :search-navigation-path [])))
        model-source)
       send]])))

(defui journal-tree-panes [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:stack {:grow 1.0}
      [retained-journal-pane model-source send]
      [:keyed
       {:source (reactive base/selected-page-models model-source)
        :key base/selected-page-model-key
        :compare compare
        :as selected-model-source}
       [:box {:grow 1.0 :accessibility-identifier "pane.selected-page"}
        [root-outliner-view
         selected-model-source
         (reactive base/selected-page-visible? selected-model-source)
         send]]]])
    (elements/element
     ui-context nil
     [:stack {:grow 1.0}
      [:keyed
       {:source (reactive base/selected-page-models model-source)
        :key base/selected-page-model-key
        :compare compare
        :as selected-model-source}
       [:box {:grow 1.0 :accessibility-identifier "pane.selected-page"}
        [root-outliner-view
         selected-model-source
         (reactive base/selected-page-visible? selected-model-source)
         send]]]
      [retained-journal-pane model-source send]])))

(defui global-effect-error-feedback [^:signal<model/chat-model> model-source]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:alert
      {:variant "destructive"
       :padding 14
       :corner-radius 16
       :border-width 0
       :accessibility-identifier "layout.error.banner"}
      [:row {:gap 10 :cross "center"}
       [:icon
        {:name "app:warning"
         :width 22
         :height 22
         :foreground "destructive"
         :accessibility-label "Error"}]
       [:text
        {:value (reactive base/effect-error-message model-source)
         :grow 1.0
         :accessibility-identifier "error.banner"}]]])
    (elements/element
     ui-context nil
     [:text
      {:value (reactive base/effect-error-message model-source)
       :accessibility-identifier "error.banner"}])))

(defui graph-loading-feedback [^:signal<model/chat-model> model-source]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:column
      {:grow 1.0
       :main "center"
       :cross "center"
       :gap 12
       :background "background"
       :accessibility-identifier "journals.loading"}
      [:spinner
       {:accessibility-identifier "spinner.graph-loading"
        :accessibility-label "Loading"}]
      [:text
       {:value (reactive base/graph-loading-message model-source)
        :foreground "muted-foreground"}]])
    (elements/element
     ui-context nil
     [:column {:accessibility-identifier "journals.loading"}
      [:text {:value (reactive base/graph-loading-message model-source)}]])))

(defui chat-main-view [^:signal<model/chat-model> model-source send]
  [:stack {:grow 1.0}
   [:if {:test (reactive base/journal-tree-retained? model-source)}
    ;; Keep the journal home mounted while the drawer replaces the detail pane.
    [journal-tree-panes model-source send]]
   [:if {:test (reactive base/flashcards-destination? model-source)}
    [cards/flashcard-screen model-source send]]
   [:if {:test (reactive base/graphs-destination? model-source)}
    [graphsv/graphs-screen model-source send]]
   [:if {:test (reactive base/global-effect-error-present? model-source)}
    [global-effect-error-feedback model-source]]
   [:if {:test (reactive base/graph-loading-visible? model-source)}
    [graph-loading-feedback model-source]]
   [:if {:test (reactive base/journal-root-visible? model-source)}
    [:text
     {:accessibility-label "Journal graph load status"
      :accessibility-identifier "journals.graph-loaded"}
     ""]]])

(defui main-header-leading [^:signal<model/chat-model> model-source send]
  [:stack
   [:if {:test (reactive
                 (fn [current]
                   (and (host? proto/FlutterHost)
                        (base/node-screen-visible? current)))
                 model-source)}
    [:button
     {:icon "app:navigation-back"
      :variant "ghost"
      :size "icon"
      :label "Back"
      :accessibility-identifier "button.navigation.back"
      :on-press (fn [_event] (send (model/BackAppNavigation 1)))}]]
   [:if {:test (reactive base/primary-sidebar-button-visible? model-source)}
    [:button
     {:icon "app:sidebar-toggle"
      :variant "ghost"
      :size "icon"
      :label "Open sidebar"
      :accessibility-identifier "button.sidebar"
      :disabled (reactive base/sidebar-drag-disabled? model-source)
      :on-press (fn [_event] (send model/OpenSidebar))}]]])

(defui main-header-title [^:signal<model/chat-model> model-source]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:heading
      {:value (reactive base/main-title model-source)
       :level 3
       :accessibility-identifier "title.main"}])
    (elements/element
     ui-context nil
     [:text
      {:value (reactive base/main-title model-source)
       :class "headline"
       :accessibility-identifier "title.main"}])))

(defui main-header-sync [^:signal<model/chat-model> model-source send]
  [:stack
   [:if {:test (reactive base/connection-control-visible? model-source)}
    [:button
     {:icon (if (host? proto/FlutterHost)
              (reactive (fn [_current] "app:sync-status") model-source)
              (reactive (fn [_current] "app:status-dot") model-source))
      :variant "ghost"
      :size "icon"
      :foreground-signal (reactive base/sync-indicator-foreground model-source)
      :label (reactive base/sync-indicator-label model-source)
      :accessibility-identifier-signal
      (reactive base/sync-accessibility-identifier model-source)
      :on-press (fn [_event] (send model/OpenSyncDetails))}]]])

(defui active-overflow-menu [^:signal<model/chat-model> model-source send]
  (let [node (ui/extension! ui-context "native-overflow-menu")
        page-actions-source
        (reactive base/active-page-actions-visible? model-source)
        favorite-label-source
        (reactive base/active-page-favorite-label model-source)
        settings-source
        (reactive base/connection-settings-visible? model-source)
        page-actions-value-source
        (reactive base/bool-wire-value page-actions-source)
        favorite-label-value-source
        (reactive base/string-wire-value favorite-label-source)
        settings-value-source
        (reactive base/bool-wire-value settings-source)]
    (ui/extension-property-signal!
     ui-context node "page-actions-visible" page-actions-value-source)
    (ui/extension-property-signal!
     ui-context node "favorite-label" favorite-label-value-source)
    (ui/extension-property-signal!
     ui-context node "settings-visible" settings-value-source)
    (ui/on-event!
     ui-context node
     (fn [input-event]
       (base/handle-native-overflow-menu-event input-event send)))
    node))

(defui main-header-connection [^:signal<model/chat-model> model-source send]
  [:stack
   [:if {:test (reactive base/connection-control-visible? model-source)}
    [active-overflow-menu model-source send]]])

(defui native-node-screen [^:signal<model/chat-model> model-source ^:signal<model/node-projection> route-source send]
  (let [route-model-source
        (reactive base/node-route-model model-source route-source)]
    (if (host? proto/FlutterHost)
      (elements/element
       ui-context nil
       [:box {:grow 1.0 :background "background"}
        [outl/node-screen route-model-source send]])
      (elements/element
       ui-context nil
       [outl/node-screen route-model-source send]))))

(defui native-search-view [^:signal<model/chat-model> model-source send]
  (let [node (ui/extension! ui-context "native-search-presentation")
        presented-source (reactive base/model-search-open? model-source)
        depth-source (reactive base/search-navigation-depth model-source)
        query-source (reactive base/model-search-query model-source)
        presented-value-source (reactive base/bool-wire-value presented-source)
        depth-value-source (reactive base/int-wire-value depth-source)
        query-value-source (reactive base/string-wire-value query-source)]
    (ui/extension-property-signal!
     ui-context node "presented" presented-value-source)
    (ui/extension-property-signal!
     ui-context node "depth" depth-value-source)
    (ui/extension-property-signal!
     ui-context node "query" query-value-source)
    (ui/extension-property!
     ui-context node "title" (proto/StringValue "Search"))
    (ui/on-event!
     ui-context node
     (fn [input-event]
       (base/handle-native-search-event input-event send)))
    (if (host? proto/FlutterHost)
      (do
        (elements/element
         ui-context node
         [:stack {:grow 1.0}
          [:if {:test (reactive base/flutter-app-root-visible? model-source)}
           [chat-main-view model-source send]]
          [:keyed
           {:source (reactive base/active-app-node-routes model-source)
            :key base/node-projection-identifier
            :compare compare
            :as route-source}
           [native-node-screen model-source route-source send]]
          [:if {:test (reactive base/flutter-search-root-visible? model-source)}
           [:column {:grow 1.0 :background "background"}
            [search-screen model-source send]]]
          [:keyed
           {:source (reactive base/active-search-node-routes model-source)
            :key base/node-projection-identifier
            :compare compare
            :as route-source}
           [native-node-screen model-source route-source send]]])
        node)
      (do
        (elements/element
         ui-context node
         [chat-main-view model-source send])
        (elements/element
         ui-context node
         [:column {:grow 1.0}
          [search-screen model-source send]])
        (elements/element
         ui-context node
         [:keyed
          {:source (reactive base/search-node-routes model-source)
           :key base/node-projection-identifier
           :compare compare
           :as route-source}
          [native-node-screen model-source route-source send]])
        node))
    node))

(defui native-navigation-view [^:signal<model/chat-model> model-source send]
  (let [node (ui/extension! ui-context "native-navigation-stack")
        depth-source (reactive base/app-navigation-depth model-source)
        depth-value-source (reactive base/int-wire-value depth-source)
        bottom-occupies-source
        (reactive base/bottom-chrome-occupies-layout-space? model-source)
        bottom-occupies-value-source
        (reactive base/bool-wire-value bottom-occupies-source)
        composer-dismissal-source
        (reactive base/bottom-chrome-expanded-composer? model-source)
        composer-dismissal-value-source
        (reactive base/bool-wire-value composer-dismissal-source)
        title-source (reactive base/main-title model-source)
        title-value-source (reactive base/string-wire-value title-source)]
    (ui/extension-property-signal!
     ui-context node "depth" depth-value-source)
    (ui/extension-property-signal!
     ui-context node "bottom-occupies-layout-space" bottom-occupies-value-source)
    (ui/extension-property-signal!
     ui-context node "composer-dismissal-enabled" composer-dismissal-value-source)
    (ui/extension-property-signal!
     ui-context node "title" title-value-source)
    (ui/on-event!
     ui-context node
     (fn [input-event]
       (base/handle-native-navigation-event input-event send)))
    (if (host? proto/FlutterHost)
      (do
        (elements/element
         ui-context node
         [:column {:grow 1.0}
          [:row
           {:cross "center"
            :gap 4
            :height 64
            :padding-horizontal 8
            :accessibility-identifier "header.main"}
           [main-header-leading model-source send]
           [main-header-title model-source]
           [:spacer {:grow 1.0}]
           [main-header-sync model-source send]
           [main-header-connection model-source send]]
          [:stack {:grow 1.0}
           [native-search-view model-source send]]
          [main-bottom-chrome model-source send]])
        node)
      (do
        (elements/element
         ui-context node
         [:column
          [native-search-view model-source send]])
        (elements/element ui-context node [main-header-leading model-source send])
        (elements/element ui-context node [main-header-title model-source])
        (elements/element ui-context node [main-header-sync model-source send])
        (elements/element ui-context node [main-header-connection model-source send])
        (elements/element ui-context node [main-bottom-chrome model-source send])
        (elements/element
         ui-context node
         [:keyed
          {:source (reactive model/app-node-routes model-source)
           :key base/node-projection-identifier
           :compare compare
           :as route-source}
          [native-node-screen model-source route-source send]])
        node))
    node))

(defui authentication-content [^:signal<model/chat-model> model-source send]
  [:column
   {:cross "center"
    :gap 0}
   [:row {:width 96 :height 96 :corner-radius 22}
    [:icon {:name "app:logo" :width 96 :height 96}]]
   [:box {:height 28}]
   [:heading {:level 1} "Logseq Chat"]
   [:box {:height 10}]
   [:text {:foreground "muted-foreground" :text-alignment "center"}
    "Capture, sync, and review your notes anywhere."]
   [:box {:height 36}]
   [:button
    {:accessibility-identifier "button.hosted-sign-in"
     :variant "primary"
     :size "lg"
     :grow 1.0
     :text-alignment "center"
     :disabled (reactive base/authentication-signing-in? model-source)
     :on-press (fn [_event] (send model/SignIn))}
    "Sign in"]
   [:if {:test (reactive base/authentication-error-present? model-source)}
    [:column {:cross "center"}
     [:box {:height 16}]
     [:text
      {:value (reactive base/authentication-error-message model-source)
       :class "caption"
       :foreground "destructive"
       :text-alignment "center"
       :accessibility-identifier "text.authentication-error"}]]]])

(defui authentication-screen [^:signal<model/chat-model> model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:column
      {:accessibility-identifier "screen.authentication"
       :grow 1.0
       :main "center"
       :cross "stretch"
       :padding 32}
      [authentication-content model-source send]])
    (elements/element
     ui-context nil
     [:column
      {:accessibility-identifier "screen.authentication"
       :grow 1.0
       :container-relative-frame "vertical"
       :main "center"
       :cross "center"
       :padding 32}
      [authentication-content model-source send]])))

(defui application-main-content [^:signal<model/chat-model> model-source send]
  (if (= (ui/platform ui-context) proto/AndroidOS)
    (if (host? proto/FlutterHost)
      (elements/element
       ui-context nil
       [:stack
        {:grow 1.0}
        [:if {:test (reactive base/main-screen-visible? model-source)}
         [native-navigation-view model-source send]]
        [:if {:test (reactive base/graph-picker-screen-visible? model-source)}
         [graphsv/graph-picker-screen model-source send]]
        [:if {:test (reactive base/model-settings-open? model-source)}
         [settings/settings-sheet model-source send]]
        [:if {:test (reactive base/model-create-graph-open? model-source)}
         [graphsv/graph-create-sheet model-source send]]
        [:if {:test (reactive base/graph-deletion-pending? model-source)}
         [graphsv/graph-delete-dialog model-source send]]
        [:if {:test (reactive base/model-graph-password-open? model-source)}
         [graphsv/graph-password-sheet model-source send]]
        [:if {:test (reactive base/page-deletion-pending? model-source)}
         [settings/page-delete-dialog send]]
        [:if {:test (reactive base/model-sync-details-open? model-source)}
         [settings/sync-status-sheet model-source send]]])
      (elements/element
       ui-context nil
       [:stack
        {:grow 1.0
         :container-relative-frame "vertical"}
        [:if {:test (reactive base/main-screen-visible? model-source)}
         [native-navigation-view model-source send]]
        [:if {:test (reactive base/graph-picker-screen-visible? model-source)}
         [graphsv/graph-picker-screen model-source send]]
        [:if {:test (reactive base/model-settings-open? model-source)}
         [settings/settings-sheet model-source send]]
        [:if {:test (reactive base/model-create-graph-open? model-source)}
         [graphsv/graph-create-sheet model-source send]]
        [:if {:test (reactive base/graph-deletion-pending? model-source)}
         [graphsv/graph-delete-dialog model-source send]]
        [:if {:test (reactive base/model-graph-password-open? model-source)}
         [graphsv/graph-password-sheet model-source send]]
        [:if {:test (reactive base/page-deletion-pending? model-source)}
         [settings/page-delete-dialog send]]
        [:if {:test (reactive base/model-sync-details-open? model-source)}
         [settings/sync-status-sheet model-source send]]]))
    (elements/element
     ui-context nil
     [:stack
      [:if {:test (reactive base/main-screen-visible? model-source)}
       [native-navigation-view model-source send]]
      [:if {:test (reactive base/graph-picker-screen-visible? model-source)}
       [graphsv/graph-picker-screen model-source send]]
      [:if {:test (reactive base/authentication-screen-visible? model-source)}
       [authentication-screen model-source send]]
      [:if {:test (reactive base/model-settings-open? model-source)}
       [settings/settings-sheet model-source send]]
      [:if {:test (reactive base/model-create-graph-open? model-source)}
       [graphsv/graph-create-sheet model-source send]]
      [:if {:test (reactive base/graph-deletion-pending? model-source)}
       [graphsv/graph-delete-dialog model-source send]]
      [:if {:test (reactive base/model-graph-password-open? model-source)}
       [graphsv/graph-password-sheet model-source send]]
      [:if {:test (reactive base/page-deletion-pending? model-source)}
       [settings/page-delete-dialog send]]
      [:if {:test (reactive base/model-sync-details-open? model-source)}
       [settings/sync-status-sheet model-source send]]])))

(defui chat-view [^:signal<model/chat-model> model-source send]
  (if (= (ui/platform ui-context) proto/AndroidOS)
    (if (host? proto/FlutterHost)
      (elements/element
       ui-context nil
       [:stack
        {:grow 1.0}
        [:if {:test (reactive base/authentication-screen-visible? model-source)}
         [authentication-screen model-source send]]
        [:if {:test (reactive base/application-shell-visible? model-source)}
         [:drawer
          {:selected (reactive base/drawer-selected? model-source)
           :disabled (reactive base/drawer-disabled? model-source)
           :width 320
           :label "Navigation"
           :accessibility-identifier "application.shell"
           :on-toggle
           (fn [input-event]
             (match input-event
               (proto/ToggleChanged _node open)
               (send (if open model/OpenSidebar model/CloseSidebar))
               _ true))}
          [application-main-content model-source send]
          [sidebar/sidebar-view model-source send]]]])
      (elements/element
       ui-context nil
       [:stack
        {:grow 1.0
         :container-relative-frame "both"}
        [:if {:test (reactive base/authentication-screen-visible? model-source)}
         [authentication-screen model-source send]]
        [:if {:test (reactive base/application-shell-visible? model-source)}
         [:drawer
          {:selected (reactive base/drawer-selected? model-source)
           :disabled (reactive base/drawer-disabled? model-source)
           :width 360
           :label "Navigation"
           :accessibility-identifier "application.shell"
           :on-toggle
           (fn [input-event]
             (match input-event
               (proto/ToggleChanged _node open)
               (send (if open model/OpenSidebar model/CloseSidebar))
               _ true))}
          [application-main-content model-source send]
          [sidebar/sidebar-view model-source send]]]]))
    (elements/element
     ui-context nil
     [:drawer
      {:selected (reactive base/drawer-selected? model-source)
       :disabled (reactive base/drawer-disabled? model-source)
       :width 360
       :label "Navigation"
       :accessibility-identifier "application.shell"
       :on-toggle
       (fn [input-event]
         (match input-event
           (proto/ToggleChanged _node open)
           (send (if open model/OpenSidebar model/CloseSidebar))
           _ true))}
      [application-main-content model-source send]
      [sidebar/sidebar-view model-source send]])))
