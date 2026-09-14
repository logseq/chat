(ns logseq-chat.view
  (:require [clojure.string :as string]
            [lui.elements :as elements]
            [lui.extension :as ext]
            [lui.macros :refer [defui reactive event host?]]
            [lui.protocol :as proto :refer [TextChanged]]
            [lui.ui :as ui]
            [logseq-chat.model :as model]
            [signal.core :as signal]))

(defn composer-asset-schema []
  (ext/component "composer-asset"
   [(proto/profile proto/MacOS proto/SwiftUIHost)
    (proto/profile proto/IOS proto/SwiftUIHost)]
   false []
   [(ext/property "title" ext/StringScalar true None)
    (ext/property "local-path" ext/StringScalar true None)] []))

(defn outliner-editor-schema []
  (ext/component
   "outliner-editor"
   [(proto/profile proto/MacOS proto/SwiftUIHost)
    (proto/profile proto/IOS proto/SwiftUIHost)
    (proto/profile proto/AndroidOS proto/FlutterHost)]
   false []
   [(ext/property "block-id" ext/StringScalar true None)
    (ext/property "title" ext/StringScalar true None)
    (ext/property "caret-utf16-offset" ext/IntScalar true None)]
   [(ext/event
     "text-change"
     [(ext/event-field "title" ext/StringScalar true)
      (ext/event-field "caret-utf16-offset" ext/IntScalar true)])
    (ext/event
     "return"
     [(ext/event-field "title" ext/StringScalar true)
      (ext/event-field "caret-utf16-offset" ext/IntScalar true)])
    (ext/event
     "backspace"
     [(ext/event-field "title" ext/StringScalar true)
      (ext/event-field "selection-length" ext/IntScalar true)])
    (ext/event
     "caret-change"
     [(ext/event-field "caret-utf16-offset" ext/IntScalar true)])]))

(defn outliner-block-content-schema []
  (ext/component
   "outliner-block-content"
   [(proto/profile proto/MacOS proto/SwiftUIHost)
    (proto/profile proto/IOS proto/SwiftUIHost)
    (proto/profile proto/AndroidOS proto/FlutterHost)]
   false []
   [(ext/property "title" ext/StringScalar true None)
    (ext/property "block-id" ext/StringScalar true None)
    (ext/property "markup-json" ext/StringScalar true None)
    (ext/property "youtube-target-url" ext/StringScalar true None)
    (ext/property "is-asset" ext/BoolScalar true None)
    (ext/property "is-completed" ext/BoolScalar true None)
    (ext/property "asset-type" ext/StringScalar true None)
    (ext/property "local-path" ext/StringScalar true None)]
   [(ext/event
     "drag-start"
     [(ext/event-field "uuid" ext/StringScalar true)])
    (ext/event
     "drop"
     [(ext/event-field "uuid" ext/StringScalar true)
      (ext/event-field "placement" ext/StringScalar true)])
    (ext/event
     "edit"
     [(ext/event-field "uuid" ext/StringScalar true)])
    (ext/event
     "open-node"
     [(ext/event-field "uuid" ext/StringScalar true)])]))

(defn native-navigation-stack-schema []
  (ext/component
   "native-navigation-stack"
   [(proto/profile proto/MacOS proto/SwiftUIHost)
    (proto/profile proto/IOS proto/SwiftUIHost)
    (proto/profile proto/AndroidOS proto/FlutterHost)]
   true []
   [(ext/property "depth" ext/IntScalar true None)
    (ext/property "bottom-occupies-layout-space" ext/BoolScalar true None)
    (ext/property "composer-dismissal-enabled" ext/BoolScalar true None)
    (ext/property "title" ext/StringScalar true None)]
   [(ext/event "back" [(ext/event-field "count" ext/IntScalar true)])
    (ext/event "dismiss-composer" [])]))

(defn native-search-presentation-schema []
  (ext/component
   "native-search-presentation"
   [(proto/profile proto/MacOS proto/SwiftUIHost)
    (proto/profile proto/IOS proto/SwiftUIHost)
    (proto/profile proto/AndroidOS proto/FlutterHost)]
   true []
   [(ext/property "presented" ext/BoolScalar true None)
    (ext/property "depth" ext/IntScalar true None)
    (ext/property "query" ext/StringScalar true None)
    (ext/property "title" ext/StringScalar true None)]
   [(ext/event "back" [(ext/event-field "count" ext/IntScalar true)])
    (ext/event "dismiss" [])
    (ext/event
     "query-changed"
     [(ext/event-field "query" ext/StringScalar true)])]))

(defn native-overflow-menu-schema []
  (ext/component
   "native-overflow-menu"
   [(proto/profile proto/MacOS proto/SwiftUIHost)
    (proto/profile proto/IOS proto/SwiftUIHost)
    (proto/profile proto/AndroidOS proto/FlutterHost)]
   false []
   [(ext/property "page-actions-visible" ext/BoolScalar true None)
    (ext/property "favorite-label" ext/StringScalar true None)
    (ext/property "settings-visible" ext/BoolScalar true None)]
   [(ext/event "favorite" [])
    (ext/event "share" [])
    (ext/event "delete" [])
    (ext/event "settings" [])]))

(defn liquid-glass-schema []
  (ext/tweak
   "liquid-glass"
   [(proto/profile proto/IOS proto/SwiftUIHost)]
   [(ext/property "shape" ext/StringScalar true None)]))

(defn extension-registry []
  (let [registry (ext/registry)]
    (ext/register-component! registry (outliner-editor-schema))
    (ext/register-component! registry (outliner-block-content-schema))
    (ext/register-component! registry (composer-asset-schema))
    (ext/register-component! registry (native-navigation-stack-schema))
    (ext/register-component! registry (native-search-presentation-schema))
    (ext/register-component! registry (native-overflow-menu-schema))
    (ext/register-tweak! registry (liquid-glass-schema))
    registry))

(defn string-wire-value [value]
  (proto/StringValue value))

(defn int-wire-value [value]
  (proto/IntValue value))

(defn bool-wire-value [value]
  (proto/BoolValue value))

(defn outliner-row-id-wire-value [row]
  (proto/StringValue (outliner-row-uuid row)))

(defn outliner-row-completed-wire-value [row]
  (proto/BoolValue (outliner-row-completed? row)))

(defn extension-string [values name]
  (match (clojure.core/get values name)
    (Some (proto/StringValue value)) value
    _ ""))

(defn extension-int [values name]
  (match (clojure.core/get values name)
    (Some (proto/IntValue value)) value
    _ 0))

(defn navigation-path-depth [path]
  (count path))

(defn handle-native-navigation-event [input-event send]
  (match input-event
    (proto/ExtensionEvent _node _identifier "back" values)
    (send (model/BackAppNavigation (extension-int values "count")))
    (proto/ExtensionEvent _node _identifier "dismiss-composer" _values)
    (send model/DismissComposer)
    _ true))

(defn handle-native-search-event [input-event send]
  (match input-event
    (proto/ExtensionEvent _node _identifier "back" values)
    (send (model/BackSearchNavigation (extension-int values "count")))
    (proto/ExtensionEvent _node _identifier "dismiss" _values)
    (send model/CloseSearch)
    (proto/ExtensionEvent _node _identifier "query-changed" values)
    (send (model/ChangeSearchQuery (extension-string values "query")))
    _ true))

(defn handle-native-overflow-menu-event [input-event send]
  (match input-event
    (proto/ExtensionEvent _node _identifier name _values)
    (cond
      (= name "favorite") (send model/ToggleActivePageFavorite)
      (= name "share") (send model/ShareActivePage)
      (= name "delete") (send model/RequestDeleteActivePage)
      (= name "settings") (send model/OpenSettings)
      :else true)
    _ true))

(defn handle-outliner-editor-event [input-event block-id-source send]
  (match input-event
    (proto/ExtensionEvent _node _identifier name values)
    (let [uuid (signal/sample block-id-source)]
      (cond
        (= name "text-change")
        (send
         (model/ChangeOutlinerText
          uuid
          (extension-string values "title")
          (extension-int values "caret-utf16-offset")))

        (= name "return")
        (send
         (model/ReturnOutlinerEditor
          uuid
          (extension-string values "title")
          (extension-int values "caret-utf16-offset")))

        (= name "backspace")
        (send
         (model/BackspaceOutlinerEditor
          uuid
          (extension-string values "title")
          (extension-int values "selection-length")))

        (= name "caret-change")
        (send
         (model/MoveOutlinerCaret
          uuid
          (extension-int values "caret-utf16-offset")))

        :else true))
    _ true))

(defn outliner-editor-view
  [ui-context block-id-source title-source caret-source send]
  (let [node (ui/extension! ui-context "outliner-editor")
        block-id-value (reactive string-wire-value block-id-source)
        title-value (reactive string-wire-value title-source)
        caret-value (reactive int-wire-value caret-source)]
    (ui/extension-property-signal!
     ui-context node "block-id" block-id-value)
    (ui/extension-property-signal!
     ui-context node "title" title-value)
    (ui/extension-property-signal!
     ui-context node "caret-utf16-offset" caret-value)
    (ui/on-event!
     ui-context node
     (fn [input-event]
       (handle-outliner-editor-event input-event block-id-source send)))
    node))

(defn optional-string [value]
  (match value
    (Some current) current
    None ""))

(defn outliner-row-youtube-target [row]
  (optional-string (:youtube-target-url row)))

(defn outliner-row-asset-type [row]
  (optional-string (:asset-type row)))

(defn outliner-row-local-path [row]
  (optional-string (:local-path row)))

(defn outliner-row-completed? [row]
  (match (:status row)
    (Some status)
    (match (:ident status)
      (Some ident)
      (or (string/ends-with? ident ".done")
          (string/ends-with? ident ".canceled"))
      None false)
    None false))

(defn outliner-row-uuid [row]
  (let [_depth (:depth row)]
    (:uuid row)))

(defn request-node-action [current uuid]
  (if (= (:search-open current) true)
    (model/RequestSearchNode uuid)
    (model/RequestAppNode uuid)))

(defn handle-outliner-block-content-event [input-event model-source send]
  (match input-event
    (proto/ExtensionEvent _node _identifier name values)
    (cond
      (= name "open-node")
      (let [uuid (extension-string values "uuid")
            current (signal/sample model-source)]
        (send (request-node-action current uuid)))

      (= name "drag-start")
      (send (model/BeginOutlinerDrag (extension-string values "uuid")))

      (= name "drop")
      (send
       (model/DropOutlinerBlocks
        (extension-string values "uuid")
        (extension-string values "placement")))

      (= name "edit")
      (send (model/BeginOutlinerEdit (extension-string values "uuid")))

      :else true)
    _ true))

(defn outliner-rich-block-view
  [ui-context model-source title-source markup-source youtube-target-source
   is-asset-source row-source asset-type-source local-path-source send]
  (let [node (ui/extension! ui-context "outliner-block-content")]
    (ui/extension-property-signal!
     ui-context node "block-id" (reactive outliner-row-id-wire-value row-source))
    (ui/extension-property-signal!
     ui-context node "title" (reactive string-wire-value title-source))
    (ui/extension-property-signal!
     ui-context node "markup-json" (reactive string-wire-value markup-source))
    (ui/extension-property-signal!
     ui-context node "youtube-target-url"
     (reactive string-wire-value youtube-target-source))
    (ui/extension-property-signal!
     ui-context node "is-asset" (reactive bool-wire-value is-asset-source))
    (ui/extension-property-signal!
     ui-context node "is-completed"
     (reactive outliner-row-completed-wire-value row-source))
    (ui/extension-property-signal!
     ui-context node "asset-type" (reactive string-wire-value asset-type-source))
    (ui/extension-property-signal!
     ui-context node "local-path" (reactive string-wire-value local-path-source))
    (ui/on-event!
     ui-context node
     (fn [input-event]
       (handle-outliner-block-content-event input-event model-source send)))
    node))

(defn graph-label [current]
  (match (:selected-graph current)
    (Some graph-name) graph-name
    None "No graph selected"))

(defn sync-label [current]
  (match (:sync-state current)
    OfflineState "Offline"
    (FailedState reason) (str "Sync failed: " reason)
    _ (if (or (:has-pending-semantic-operations current)
              (:has-pending-sync-request current))
        "Syncing"
        (match (:sync-state current)
          SyncedState "Up to date"
          _ "Syncing"))))

(defn sync-indicator-label [current]
  (match (:sync-state current)
    OfflineState "Not connected"
    (FailedState _reason) "Sync failed"
    _ (if (or (:has-pending-semantic-operations current)
              (:has-pending-sync-request current))
        "Syncing"
        (match (:sync-state current)
          SyncedState "Synced"
          SyncingState "Syncing"
          _ "Not connected"))))

(defn sync-accessibility-identifier [current]
  (match (:sync-state current)
    (FailedState _reason) "sync.failed"
    OfflineState "sync.disconnected"
    _ "sync.connected"))

(defn sync-indicator-foreground [current]
  (match (:sync-state current)
    OfflineState "error-foreground"
    (FailedState _reason) "error-foreground"
    _ (if (or (:has-pending-semantic-operations current)
              (:has-pending-sync-request current))
        "warning-foreground"
        (match (:sync-state current)
          SyncedState "success-foreground"
          SyncingState "warning-foreground"
          _ "error-foreground"))))

(defn sync-connection-label [current]
  (match (:sync-state current)
    OfflineState "Disconnected"
    _ "Connected"))

(defn sync-pending-label [current]
  (if (or (:has-pending-semantic-operations current)
          (:has-pending-sync-request current))
    "Waiting to save"
    "Saved"))

(defn sync-cursor-label [current]
  (match (:applied-server-t current)
    (Some cursor) (str cursor)
    None "Unavailable"))

(defn active-page-actions-visible? [current]
  (match (model/active-page current)
    (Some _page) true
    None false))

(defn connection-settings-visible? [current]
  (not (active-page-actions-visible? current)))

(defn active-page-favorite-label [current]
  (match (model/active-page current)
    (Some page)
    (if (model/page-is-favorite? current (:uuid page))
      "Unfavorite"
      "Favorite")
    None "Favorite"))

(defn page-deletion-pending? [current]
  (match (:pending-page-deletion current)
    (Some _page) true
    None false))

(defn sidebar-page-identifier [page]
  (str "link.sidebar.page." (:uuid page)))

(defn sidebar-page-title [page]
  (:title page))

(defn sidebar-graph-identifier [graph]
  (str "menu.graph." (:id graph)))

(defn graph-title [graph]
  (:name graph))

(defn sidebar-graph-selected? [current graph]
  (match (:selected-graph-id current)
    (Some graph-id) (= graph-id (:id graph))
    None false))

(defn sidebar-graph-disabled? [graph]
  (not (:is-ready graph)))

(defn favorites-empty? [current]
  (empty? (:favorites current)))

(defn recent-pages-empty? [current]
  (empty? (:recent-pages current)))

(defn journals-sidebar-selected? [current]
  (and
   (= (:destination current) model/JournalsDestination)
   (match (:selected-page current)
     None true
     (Some _page) false)))

(defn flashcards-sidebar-selected? [current]
  (= (:destination current) model/FlashcardsDestination))

(defn graphs-sidebar-selected? [current]
  (= (:destination current) model/GraphsDestination))

(defn sidebar-page-selected? [current page]
  (and (= (:destination current) model/JournalsDestination)
       (match (:selected-page current)
         (Some selected) (= (:uuid selected) (:uuid page))
         None false)))

(defn sidebar-tab-visible? [current tab]
  (model/string-vector-contains? (:sidebar-tabs current) tab))

(defn flashcards-tab-visible? [current]
  (sidebar-tab-visible? current "flashcards"))

(defn graphs-tab-visible? [current]
  (sidebar-tab-visible? current "graphs"))

(defn sidebar-page-row [ui-context model-source page-source send]
  (let [page (signal/sample page-source)]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:list-item
        {:text (reactive sidebar-page-title page-source)
         :label (reactive sidebar-page-title page-source)
         :icon "app:document"
         :selected (reactive sidebar-page-selected? model-source page-source)
         :accessibility-identifier (sidebar-page-identifier page)
         :on-press
         (event [current-page page-source]
                (send (model/SelectSidebarPage (:uuid current-page))))}])
      (elements/element
       ui-context nil
       [:list-item
        {:text (reactive sidebar-page-title page-source)
         :label (reactive sidebar-page-title page-source)
         :role "navigation"
         :icon "app:document"
         :selected (reactive sidebar-page-selected? model-source page-source)
         :accessibility-identifier (sidebar-page-identifier page)
         :on-press
         (event [current-page page-source]
                (send (model/SelectSidebarPage (:uuid current-page))))}]))))

(defn sidebar-graph-menu-item [ui-context model-source graph-source send]
  (let [graph (signal/sample graph-source)]
    (elements/element
     ui-context nil
     [:menu-item
      {:text (reactive graph-title graph-source)
       :selected (reactive sidebar-graph-selected? model-source graph-source)
       :disabled (reactive sidebar-graph-disabled? graph-source)
       :accessibility-identifier (sidebar-graph-identifier graph)
       :on-press
       (event [current-graph graph-source]
              (send (model/SelectSidebarGraph (:id current-graph))))}])))

(defui sidebar-section-heading [title icon]
  [:column {:gap 0}
   [:box {:height 16}]
   [:row {:gap 6
          :cross "center"
          :padding-horizontal 12}
    [:icon {:name icon :width 14 :height 14 :foreground "muted-foreground"}]
    [:text {:class "caption semibold" :foreground "muted-foreground"} title]]
   [:box {:height 6}]])

(defui sidebar-empty-section-label [title]
  [:column {:gap 0}
   [:row {:padding-horizontal 12}
    [:text {:class "caption" :foreground "muted-foreground"} title]]
   [:box {:height 6}]])

(defui sidebar-graph-switch-content [model-source]
  [:row {:grow 1.0 :main "space_between" :cross "center"}
   [:text {:value (reactive graph-label model-source)}]
   [:icon {:name "app:chevron-down"
           :width 18
           :height 18
           :foreground "muted-foreground"}]])

(defn sidebar-graph-switch [ui-context model-source send]
  (let [_label (graph-label (signal/sample model-source))]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:list-item
        {:label "Switch graph"
         :accessibility-identifier "button.graph-switch"
         :on-press (fn [_event] (send model/OpenGraphMenu))}
        [sidebar-graph-switch-content model-source]])
      (elements/element
       ui-context nil
       [:list-item
        {:text (reactive graph-label model-source)
         :label "Switch graph"
         :role "navigation-heading"
         :icon "app:chevron-down"
         :icon-placement "trailing"
         :accessibility-identifier "button.graph-switch"
         :on-press (fn [_event] (send model/OpenGraphMenu))}]))))

(defn sidebar-journals-row [ui-context model-source send]
  (let [_selected (journals-sidebar-selected? (signal/sample model-source))]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:list-item
        {:label "Journals"
         :icon "app:calendar"
         :selected (reactive journals-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.journals"
         :on-press (fn [_event] (send model/ShowJournals))}
        "Journals"])
      (elements/element
       ui-context nil
       [:list-item
        {:label "Journals"
         :role "navigation"
         :icon "app:calendar"
         :selected (reactive journals-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.journals"
         :on-press (fn [_event] (send model/ShowJournals))}
        "Journals"]))))

(defn sidebar-flashcards-row [ui-context model-source send]
  (let [_selected (flashcards-sidebar-selected? (signal/sample model-source))]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:list-item
        {:label "Flashcards"
         :icon "app:flashcards"
         :selected (reactive flashcards-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.flashcards"
         :on-press (fn [_event] (send model/ShowFlashcards))}
        "Flashcards"])
      (elements/element
       ui-context nil
       [:list-item
        {:label "Flashcards"
         :role "navigation"
         :icon "app:flashcards"
         :selected (reactive flashcards-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.flashcards"
         :on-press (fn [_event] (send model/ShowFlashcards))}
        "Flashcards"]))))

(defn sidebar-graphs-row [ui-context model-source send]
  (let [_selected (graphs-sidebar-selected? (signal/sample model-source))]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:list-item
        {:label "Graphs"
         :icon "app:folder"
         :selected (reactive graphs-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.graphs"
         :on-press (fn [_event] (send model/ShowGraphs))}
        "Graphs"])
      (elements/element
       ui-context nil
       [:list-item
        {:label "Graphs"
         :role "navigation"
         :icon "app:folder"
         :selected (reactive graphs-sidebar-selected? model-source)
         :accessibility-identifier "link.sidebar.graphs"
         :on-press (fn [_event] (send model/ShowGraphs))}
        "Graphs"]))))

(defui sidebar-view [model-source send]
  [:column
   {:accessibility-identifier "sidebar.navigation"
    :grow 1.0
    :gap 4
    :padding 12}
   [:box {:height (if (host? proto/FlutterHost) 8 48)}]
   [:stack
    [sidebar-graph-switch model-source send]
    [:if {:test (reactive :graph-menu-open model-source)}
     [:dropdown-menu
      {:anchor "below"
       :anchor-alignment "start"
       :min-width 240
       :accessibility-identifier "menu.graph-switch"
       :on-dismiss (fn [_event] (send model/DismissGraphMenu))}
      [:keyed
       {:source (reactive :graphs model-source)
        :key :id
        :compare compare
        :as graph-source}
       [sidebar-graph-menu-item model-source graph-source send]]]]]
   [:box {:height 12}]
   [sidebar-journals-row model-source send]
   [:if {:test (reactive flashcards-tab-visible? model-source)}
    [sidebar-flashcards-row model-source send]]
   [:if {:test (reactive graphs-tab-visible? model-source)}
    [sidebar-graphs-row model-source send]]
   [:scroll {:grow 1.0 :accessibility-identifier "scroll.sidebar.pages"}
    [:column {:gap 4}
     [:column {:accessibility-identifier "section.sidebar.favorites" :gap 2}
      [sidebar-section-heading "Favorites" "app:star"]
      [:if {:test (reactive favorites-empty? model-source)}
       [sidebar-empty-section-label "No favorites yet"]]
      [:keyed
       {:source (reactive :favorites model-source)
        :key :uuid
        :compare compare
        :as page-source}
       [sidebar-page-row model-source page-source send]]]
     [:column {:accessibility-identifier "section.sidebar.recent" :gap 2}
      [sidebar-section-heading "Recent" "app:history"]
      [:if {:test (reactive recent-pages-empty? model-source)}
       [sidebar-empty-section-label "No recent pages"]]
      [:keyed
       {:source (reactive :recent-pages model-source)
        :key :uuid
        :compare compare
        :as page-source}
       [sidebar-page-row model-source page-source send]]]]]])

(defn composer-collapsed? [current]
  (not (:composer-expanded current)))

(defn composer-send-disabled? [current]
  (or (model/composer-assets-sending? current)
      (and (string/blank? (:composer-draft current))
           (empty? (:composer-assets current)))))

(defn task-status-identifier [status]
  (str "button.task-status.option." (:uuid status)))

(defn task-status-title [status]
  (:title status))

(defn task-status-style [status]
  (let [value
        (string/lower-case
         (match (:ident status)
           (Some ident) ident
           None
           (match (:icon-id status)
             (Some icon-id) icon-id
             None (:title status))))]
    (cond
      (string/includes? value "backlog") "backlog"
      (or (string/includes? value "in-review")
          (string/includes? value "inreview")) "in-review"
      (or (string/includes? value "doing")
          (string/includes? value "inprogress")
          (string/includes? value "progress")) "doing"
      (or (string/includes? value "done")
          (string/includes? value "circle-check")) "done"
      (or (string/includes? value "cancel")
          (string/includes? value "circle-x")) "canceled"
      :else "todo")))

(defn task-status-icon-name [status]
  (case (task-status-style status)
    "backlog" "app:task-backlog"
    "doing" "app:task-doing"
    "in-review" "app:task-review"
    "done" "app:task-done"
    "canceled" "app:task-canceled"
    "app:task-todo"))

(defn task-status-foreground [status]
  (match (:icon-color status)
    (Some color) color
    None (str "task-" (task-status-style status))))

(defn task-status-selected? [current]
  (match (:selected-task-status current)
    (Some _status) true
    None false))

(defn search-result-identifier [hit]
  (let [_breadcrumb (:breadcrumb hit)]
    (str "search.result." (:uuid hit))))

(defn search-result-title [hit]
  (let [_breadcrumb (:breadcrumb hit)]
    (:title hit)))

(defn search-result-breadcrumb [hit]
  (:breadcrumb hit))

(defn page-search-results [current]
  (filterv (fn [hit] (:is-page hit)) (:search-results current)))

(defn block-search-results [current]
  (filterv (fn [hit] (not (:is-page hit))) (:search-results current)))

(defn page-search-results-present? [current]
  (not (empty? (page-search-results current))))

(defn block-search-results-present? [current]
  (not (empty? (block-search-results current))))

(defn search-empty-state-present? [current]
  (and (not (:search-loading current)) (empty? (:search-results current))))

(defn search-results-present? [current]
  (not (empty? (:search-results current))))

(defn search-result-status [current]
  (if (:search-loading current)
    "Searching…"
    (if (string/blank? (:search-query current))
      ""
      (let [total (count (:search-results current))]
        (str total (if (= total 1) " result" " results"))))))

(defn search-result-context-present? [hit]
  (not (string/blank? (:breadcrumb hit))))

(defn search-empty-message [current]
  (if (string/blank? (:search-query current))
    "Search your graph"
    "No results"))

(defn search-empty-supporting-message [query]
  (if (string/blank? query)
    "Find pages and blocks by title or content."
    "Try a different keyword."))

(defn search-result-row [ui-context hit-source send]
  (let [hit (signal/sample hit-source)
        row (elements/element
     ui-context nil
     [:list-item
      {:accessibility-identifier (search-result-identifier hit)
       :on-press
       (event [current-hit hit-source]
              (send (model/RequestSearchNode (:uuid current-hit))))}
      [:column {:gap 4 :padding-vertical 6 :grow 1.0}
       [:text {:value (reactive search-result-title hit-source)
               :class "search-match line-clamp-3"
               :accessibility-identifier (str "search.result.title." (:uuid hit))}]
       [:if {:test (reactive search-result-context-present? hit-source)}
        [:text {:value (reactive search-result-breadcrumb hit-source)
                :class "caption single-line"
                :foreground "muted-foreground"
                :accessibility-identifier (str "search.result.context." (:uuid hit))}]]]])]
    (if (:is-page hit)
      (ui/string-property! ui-context row proto/InlineIconName "app:document")
      false)
    row))

(defn outliner-row-identifier [row]
  (let [_depth (:depth row)]
    (str "outliner.block." (:uuid row))))

(defn outliner-row-action-identifier [row]
  (let [_depth (:depth row)]
    (str "outliner.block-action." (:uuid row))))

(defn outliner-row-title [row]
  (let [_depth (:depth row)]
    (:title row)))

(defn outliner-row-indent [row]
  (* (:depth row) 22))

(defn outliner-row-has-children [row]
  (:has-children row))

(defn outliner-row-zoom-label [row]
  (str "Zoom into "
       (if (empty? (:title row)) "Untitled block" (:title row))))

(defn outliner-row-zoom-identifier [row]
  (str "button.outliner.zoom."
       (:uuid row)
       "."
       (if (empty? (:title row)) "Untitled block" (:title row))))

(defn outliner-row-action-label [current row]
  (str (if (empty? (:outliner-selected-block-ids current))
         "Edit block "
         "Select block ")
       (if (empty? (:title row)) "Untitled block" (:title row))))

(defn outliner-row-collapse-label [row]
  (str (if (:is-collapsed row) "Expand " "Collapse ")
       (if (empty? (:title row)) "Untitled block" (:title row))))

(defn outliner-row-collapse-glyph [row]
  (if (:is-collapsed row) "›" "⌄"))

(defn outliner-collapse-icon-name [collapsed?]
  (if collapsed? "app:chevron-right" "app:chevron-down"))

(defn outliner-collapse-identifier [row]
  (str "button.outliner.collapse." (:uuid row)))

(defn outliner-collapse-button [ui-context row-source send]
  (let [row (signal/sample row-source)]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:button
        {:icon
         (reactive
          (fn [current-row]
            (outliner-collapse-icon-name (:is-collapsed current-row)))
          row-source)
         :label (reactive outliner-row-collapse-label row-source)
         :variant "ghost"
         :width 28
         :height 28
         :accessibility-identifier
         (outliner-collapse-identifier row)
         :on-press
         (event [current-row row-source]
                (send (model/ToggleOutlinerCollapsed (:uuid current-row))))}])
      (elements/element
       ui-context nil
       [:button
        {:icon (reactive
                (fn [current-row]
                  (if (= (:is-collapsed current-row) true)
                    "app:disclosure-right"
                    "app:disclosure-down"))
                row-source)
         :size "icon"
         :class "body-line"
         :foreground "secondary"
         :label (reactive outliner-row-collapse-label row-source)
         :variant "ghost"
         :width 28
         :height 24
         :accessibility-identifier
         (outliner-collapse-identifier row)
         :on-press
         (event [current-row row-source]
                (send (model/ToggleOutlinerCollapsed (:uuid current-row))))}]))))

(defn outliner-indent-view [ui-context width-source]
  (let [node (ui/text! ui-context "")]
    (ui/int-property-signal!
     ui-context node proto/WidthValue width-source)
    node))

(defn row-editing? [current row]
  (match (:outliner-editing current)
    (Some editing) (= (:uuid editing) (:uuid row))
    None false))

(defn row-not-editing? [current row]
  (not (row-editing? current row)))

(defn string-vector-contains? [values target]
  (loop [index 0]
    (if (= index (count values))
      false
      (if (= (nth values index) target)
        true
        (recur (inc index))))))

(defn row-selected? [current row]
  (string-vector-contains?
   (:outliner-selected-block-ids current) (:uuid row)))

(defn outliner-selection-active? [current]
  (not (empty? (:outliner-selected-block-ids current))))

(defn outliner-selection-inactive? [current]
  (empty? (:outliner-selected-block-ids current)))

(defn outliner-editor-active? [current]
  (and (outliner-selection-inactive? current)
       (match (:outliner-editing current)
         (Some _editing) true
         None false)))

(defn outliner-autocomplete-active? [current]
  (and (outliner-editor-active? current)
       (match (:outliner-autocomplete current)
         (Some _autocomplete)
         (not (empty? (:outliner-autocomplete-candidates current)))
         None false)))

(defn outliner-autocomplete-identifier [candidate]
  (str "button.outliner.autocomplete." (:index candidate)))

(defn outliner-autocomplete-label [candidate]
  (:label candidate))

(defn node-navigation-active? [current]
  (not (empty? (:app-navigation-path current))))

(defn node-navigation-inactive? [current]
  (empty? (:app-navigation-path current)))

(defn journals-destination? [current]
  (= (:destination current) model/JournalsDestination))

(defn flashcards-destination? [current]
  (= (:destination current) model/FlashcardsDestination))

(defn graphs-destination? [current]
  (= (:destination current) model/GraphsDestination))

(defn graph-selected? [current]
  (or
   (match (:selected-graph-id current)
     (Some _graph-id) true
     None false)
   (match (:selected-graph current)
     (Some _graph-name) true
     None false)))

(defn graph-picker-visible? [current]
  (and (journals-destination? current)
       (not (:graph-loading current))
       (not (graph-selected? current))))

(defn graph-loading-visible? [current]
  (and (journals-destination? current)
       (:graph-loading current)
       (empty? (:outliner-rows current))))

(defn graph-loading-message [current]
  (if (graph-selected? current) "Loading journals" "Loading graphs"))

(defn selected-graph-local? [current]
  (match (:selected-graph-id current)
    (Some graph-id) (model/graph-local? current graph-id)
    None false))

(defn journal-route-active? [current]
  (and (journals-destination? current)
       (graph-selected? current)
       (or (not (:graph-loading current))
           (not (empty? (:outliner-rows current))))
       (node-navigation-inactive? current)))

(defn journal-root-visible? [current]
  (and (journal-route-active? current) (not (:search-open current))))

(defn journal-home-visible? [current]
  (and (journal-root-visible? current) (selected-page-absent? current)))

(defn selected-page-visible? [current]
  (and (journal-root-visible? current) (selected-page-present? current)))

(defn selected-page-models [current]
  (if (selected-page-visible? current) [current] []))

(defn selected-page-model-key [current]
  (match (:selected-page current)
    (Some page) (:uuid page)
    None ""))

(defn journal-tree-retained? [current]
  (and (graph-selected? current)
       (or (not (:graph-loading current))
           (not (empty? (:outliner-rows current))))))

(defn older-journals-visible? [current]
  (and (journal-root-visible? current)
       (:has-older-journals current)
       (match (:selected-page current)
         None true
         (Some _page) false)))

(defn journal-section-marker-for [markers block-id]
  (loop [index 0]
    (if (= index (count markers))
      None
      (let [marker (nth markers index)]
        (if (= (:block-id marker) block-id)
          (Some marker)
          (recur (inc index)))))))

(defn outliner-journal-marker [current row]
  (journal-section-marker-for
   (:outliner-section-markers current) (:uuid row)))

(defn outliner-journal-heading-visible? [current row]
  (and
   (journal-root-visible? current)
   (match (:selected-page current)
     None
     (match (outliner-journal-marker current row)
       (Some _marker) true
       None false)
     (Some _page) false)))

(defn outliner-journal-divider-visible? [current row]
  (match (outliner-journal-marker current row)
    (Some marker) (:has-divider marker)
    None false))

(defn outliner-journal-title [current row]
  (match (outliner-journal-marker current row)
    (Some marker) (:title marker)
    None ""))

(defn outliner-journal-page-id [current row]
  (match (outliner-journal-marker current row)
    (Some marker) (:page-id marker)
    None ""))

(defn outliner-journal-button-identifier [current row]
  (str "button.journal." (outliner-journal-page-id current row)))

(defn outliner-journal-accessibility-label [current row]
  (str "Open " (outliner-journal-title current row)))

(defn node-screen-visible? [current]
  (and (journals-destination? current)
       (node-navigation-active? current)))

(defn primary-sidebar-button-visible? [current]
  (and (not (node-screen-visible? current))
       (not (graph-loading-visible? current))
       (not (graph-picker-visible? current))
       (not (:search-open current))
       (not (= (:authentication-state current) "signedOut"))
       (not (= (:authentication-state current) "signingIn"))))

(defn sidebar-drag-disabled? [current]
  (and (not (:sidebar-open current))
       (or (not (primary-sidebar-button-visible? current))
           (not (empty? (:app-navigation-path current)))
           (outliner-editor-active? current)
           (outliner-selection-active? current))))

(defn connection-control-visible? [current]
  (and (not (:search-open current))
       (not (graph-picker-visible? current))
       (not (= (:authentication-state current) "signedOut"))
       (not (= (:authentication-state current) "signingIn"))))

(defn search-query-present? [current]
  (not (empty? (:search-query current))))

(defn bottom-chrome-presentation [current]
  (if (outliner-selection-active? current)
    "outliner-selection"
    (if (outliner-editor-active? current)
      "outliner-editor"
      (if (and (journals-destination? current)
               (not (:search-open current))
               (not (graph-loading-visible? current))
               (not (graph-picker-visible? current)))
        (if (:composer-expanded current)
          "expanded-composer"
          "capture-and-search")
        "hidden"))))

(defn bottom-chrome-selection? [current]
  (= (bottom-chrome-presentation current) "outliner-selection"))

(defn bottom-chrome-editor? [current]
  (= (bottom-chrome-presentation current) "outliner-editor"))

(defn bottom-chrome-expanded-composer? [current]
  (= (bottom-chrome-presentation current) "expanded-composer"))

(defn bottom-chrome-capture-and-search? [current]
  (= (bottom-chrome-presentation current) "capture-and-search"))

(defn bottom-chrome-occupies-layout-space? [current]
  (bottom-chrome-editor? current))

(defn active-node-projection [current]
  (last (:node-routes current)))

(defn active-node-uuid [current]
  (match (active-node-projection current)
    (Some route) (:uuid route)
    None ""))

(defn active-node-breadcrumbs [current]
  (match (active-node-projection current)
    (Some route)
    (match (first (filterv (fn [row] (= (:uuid row) (:uuid route)))
                          (:outliner-rows route)))
      (Some row) (:breadcrumbs row)
      None [])
    None []))

(defn active-node-has-breadcrumbs? [current]
  (not (empty? (active-node-breadcrumbs current))))

(defn active-node-title [current]
  (match (active-node-projection current)
    (Some route) (:title route)
    None "Untitled"))

(defn main-title [current]
  (if (= (:destination current) model/FlashcardsDestination)
    "Flashcards"
    (if (= (:destination current) model/GraphsDestination)
      "Graphs"
      (match (model/active-page current)
        (Some page) (:title page)
        None ""))))

(defn current-content-active? [current]
  (match (active-node-projection current)
    (Some _route) true
    None
    (match (:selected-page current)
      (Some _page) true
      None false)))

(defn current-content-is-tag? [current]
  (match (active-node-projection current)
    (Some route) (:is-tag route)
    None (:selected-page-is-tag current)))

(defn current-content-is-property? [current]
  (match (active-node-projection current)
    (Some route) (:is-property route)
    None (:selected-page-is-property current)))

(defn active-node-page-uuid [current]
  (match (active-node-projection current)
    (Some route) (:page-uuid route)
    None
    (match (:selected-page current)
      (Some page) (:uuid page)
      None "")))

(defn active-node-related-rows [current]
  (match (active-node-projection current)
    (Some route) (:related-rows route)
    None (:related-rows current)))

(defn active-node-linked-reference-rows [current]
  (match (active-node-projection current)
    (Some route) (:linked-reference-rows route)
    None (:linked-reference-rows current)))

(defn node-related-section-visible? [current]
  (and (current-content-active? current)
       (not (current-content-is-tag? current))
       (not (empty? (active-node-related-rows current)))))

(defn node-tag-section-visible? [current]
  (and (current-content-active? current)
       (current-content-is-tag? current)))

(defn node-tag-section-empty? [current]
  (and (node-tag-section-visible? current)
       (empty? (active-node-related-rows current))))

(defn node-linked-reference-section-visible? [current]
  (not (empty? (active-node-linked-reference-rows current))))

(defn node-can-add-first-block? [current]
  (and (current-content-active? current)
       (empty? (:outliner-rows current))
       (not (current-content-is-tag? current))
       (not (current-content-is-property? current))))

(defn node-outliner-visible? [current]
  (not (empty? (:outliner-rows current))))

(defn node-title-visible? [current]
  (and (node-outliner-visible? current)
       (not (current-content-is-tag? current))
       (not (and (:search-open current)
                 (not (= (active-node-uuid current) (active-node-page-uuid current)))))))

(defn main-can-add-first-block? [current]
  (and (journal-root-visible? current)
       (node-can-add-first-block? current)))

(defn main-related-section-visible? [current]
  (and (journal-root-visible? current)
       (node-related-section-visible? current)))

(defn main-tag-section-visible? [current]
  (and (journal-root-visible? current)
       (node-tag-section-visible? current)))

(defn main-linked-reference-section-visible? [current]
  (and (journal-root-visible? current)
       (node-linked-reference-section-visible? current)))

(defn outliner-row-has-breadcrumb? [row]
  (not (empty? (:breadcrumb row))))

(defn outliner-row-breadcrumb [row]
  (:breadcrumb row))

(defn outliner-row-structured-breadcrumb? [row]
  (not (empty? (:breadcrumbs row))))

(defn outliner-row-fallback-breadcrumb? [row]
  (and (empty? (:breadcrumbs row))
       (outliner-row-has-breadcrumb? row)))

(defn breadcrumb-identifier [breadcrumb]
  (str "button.breadcrumb." (:uuid breadcrumb)))

(defn breadcrumb-title [breadcrumb]
  (:title breadcrumb))

(defn breadcrumb-button [ui-context breadcrumb-source search-open send]
  (let [breadcrumb (signal/sample breadcrumb-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive breadcrumb-title breadcrumb-source)
       :variant "ghost"
       :class "caption"
       :foreground "muted-foreground"
       :accessibility-identifier (breadcrumb-identifier breadcrumb)
       :on-press
       (event [current-breadcrumb breadcrumb-source]
              (send (if search-open
                      (model/RequestSearchNode (:uuid current-breadcrumb))
                      (model/RequestAppNode (:uuid current-breadcrumb)))))}])))

(defn node-breadcrumb-button [ui-context model-source breadcrumb-source send]
  (let [search-open (:search-open (signal/sample model-source))]
    (breadcrumb-button ui-context breadcrumb-source search-open send)))

(defui node-breadcrumbs [model-source send]
  [:breadcrumb {:gap 5 :main "start"
                :accessibility-identifier "breadcrumb.node"}
   [:keyed
    {:source (reactive active-node-breadcrumbs model-source)
     :key :uuid
     :compare compare
     :as breadcrumb-source}
    [node-breadcrumb-button model-source breadcrumb-source send]]])

(defui related-row-breadcrumbs [row-source send]
  [:breadcrumb {:gap 5 :main "start"
                :accessibility-identifier "breadcrumb.related-blocks"}
   [:keyed
    {:source (reactive :breadcrumbs row-source)
     :key :uuid
     :compare compare
     :as breadcrumb-source}
    [breadcrumb-button breadcrumb-source false send]]])

(defn editing-title [current]
  (match (:outliner-editing current)
    (Some editing) (:title editing)
    None ""))

(defn editing-caret [current]
  (match (:outliner-editing current)
    (Some editing) (:caret-utf16-offset editing)
    None 0))

(defn outliner-row-has-status? [row]
  (match (:status row)
    (Some _status) true
    None false))

(defn outliner-row-status-title [row]
  (match (:status row)
    (Some status) (:title status)
    None ""))

(defn outliner-task-status-icon [row]
  (match (:status row)
    (Some status) (task-status-icon-name status)
    None "app:task-todo"))

(defn outliner-task-status-style-is? [row expected]
  (match (:status row)
    (Some status) (= (task-status-style status) expected)
    None (= expected "todo")))

(defn outliner-task-status-backlog? [row]
  (outliner-task-status-style-is? row "backlog"))

(defn outliner-task-status-todo? [row]
  (outliner-task-status-style-is? row "todo"))

(defn outliner-task-status-doing? [row]
  (outliner-task-status-style-is? row "doing"))

(defn outliner-task-status-review? [row]
  (outliner-task-status-style-is? row "in-review"))

(defn outliner-task-status-done? [row]
  (outliner-task-status-style-is? row "done"))

(defn outliner-task-status-canceled? [row]
  (outliner-task-status-style-is? row "canceled"))

(defn outliner-editor-task-label [current]
  (match (:outliner-editing current)
    (Some editing)
    (match (model/row-index (:outliner-rows current) (:uuid editing))
      (Some index)
      (str "Task: "
           (match (:status (nth (:outliner-rows current) index))
             (Some status) (:title status)
             None "None"))
      None "Task: None")
    None "Task: None"))

(defn outliner-row-has-tags? [row]
  (not (empty? (:tags row))))

(defn outliner-row-sync-failed? [row]
  (match (:sync-status row)
    (Some status) (= status "failed")
    None false))

(defn outliner-row-list-item-press-enabled? [host row]
  (or (not (= host proto/FlutterHost))
      (= (:is-asset row) true)
      (= (:opens-as-page row) true)))

(defn make-retained-outline-row [current row]
  (match (:outliner-editing current)
    (Some editing)
    (if (= (:uuid editing) (:uuid row))
      (record retained-outline-row
              (render-key "active-outliner-editor")
              (value row)
              (is-editing true)
              (editing-title (:title editing))
              (editing-caret (:caret-utf16-offset editing)))
      (record retained-outline-row
              (render-key (:uuid row))
              (value row)
              (is-editing false)
              (editing-title "")
              (editing-caret 0)))
    None
    (record retained-outline-row
            (render-key (:uuid row))
            (value row)
            (is-editing false)
            (editing-title "")
            (editing-caret 0))))

(defn retained-outliner-rows [current]
  (mapv
   (fn [row] (make-retained-outline-row current row))
   (:outliner-rows current)))

(defn first-journal-section-visible? [current]
  (and
   (journal-root-visible? current)
   (match (:selected-page current)
     None true
     (Some _page) false)
   (not (empty? (:outliner-section-markers current)))
   (= 0 (:start-index (nth (:outliner-section-markers current) 0)))))

(defn first-journal-section-identifier [current]
  (if (first-journal-section-visible? current)
    (str "journal.section."
         (:page-id (nth (:outliner-section-markers current) 0)))
    "journal.section"))

(defn first-journal-retained-rows [current]
  (if (first-journal-section-visible? current)
    (let [section (nth (:outliner-section-markers current) 0)]
      (mapv
       (fn [row] (make-retained-outline-row current row))
       (subvec (:outliner-rows current)
               (:start-index section)
               (:end-index section))))
    []))

(defn remaining-retained-outliner-rows [current]
  (if (first-journal-section-visible? current)
    (let [section (nth (:outliner-section-markers current) 0)]
      (mapv
       (fn [row] (make-retained-outline-row current row))
       (subvec (:outliner-rows current) (:end-index section))))
    (retained-outliner-rows current)))

(defn retained-row-value [retained] (:value retained))
(defn retained-row-editing? [retained] (:is-editing retained))
(defn retained-row-editing-title [retained] (:editing-title retained))
(defn retained-row-editing-caret [retained] (:editing-caret retained))

(defn outliner-tag-identifier [tag]
  (str "button.block-tag." (:uuid tag)))

(defn outliner-tag-title [tag]
  (str "#" (:title tag)))

(defn outliner-tag [ui-context tag-source send]
  (let [tag (signal/sample tag-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive outliner-tag-title tag-source)
       :label (reactive outliner-tag-title tag-source)
       :class "caption"
       :variant "ghost"
       :foreground "accent"
       :accessibility-identifier (outliner-tag-identifier tag)
       :on-press
       (event [current-tag tag-source]
              (send (model/RequestAppNode (:uuid current-tag))))}])))

(defn outliner-row-journal? [current row]
  (and
   (journal-root-visible? current)
   (match (outliner-journal-marker current row)
     (Some _marker) true
     None false)))

(defn outliner-zoom-control [ui-context model-source row-source send search-open]
  (let [current (signal/sample model-source)
        row (signal/sample row-source)]
    (if (and (not search-open)
             (outliner-row-journal? current row))
      (if (= (ui/host ui-context) proto/FlutterHost)
        (elements/element
         ui-context nil
         [:row {:width 24 :height 24 :main "center" :cross "center"}
          [:box {:width 7 :height 7 :corner-radius 4 :background "border"
                 :accessibility-identifier
                 (str "outliner.bullet-glyph." (outliner-row-uuid row))}]])
        (elements/element
         ui-context nil
         [:icon
          {:name "app:outliner-bullet"
           :class "body-line"
           :foreground "border"
           :width 24
           :height 24
           :accessibility-identifier-signal
           (reactive outliner-row-zoom-identifier row-source)}]))
      (if (= (ui/host ui-context) proto/FlutterHost)
        (elements/element
         ui-context nil
         [:stack {:width 24 :height 24}
          [:row {:width 24 :height 24 :main "center" :cross "center"}
           [:box
            {:width 7
             :height 7
             :corner-radius 4
             :background "border"
             :accessibility-identifier
             (str "outliner.bullet-glyph." (outliner-row-uuid row))}]]
          [:button
           {:label (reactive outliner-row-zoom-label row-source)
            :accessibility-label (reactive outliner-row-zoom-label row-source)
            :variant "ghost"
            :width 24
            :height 24
            :accessibility-identifier-signal
            (reactive outliner-row-zoom-identifier row-source)
            :on-press
            (event [current-row row-source]
                   (if search-open
                     (send (model/RequestSearchNode (:uuid current-row)))
                     (send (model/RequestAppNode (:uuid current-row)))))}]])
        (elements/element
         ui-context nil
         [:button
          {:label (reactive outliner-row-zoom-label row-source)
           :accessibility-label (reactive outliner-row-zoom-label row-source)
           :icon "app:outliner-bullet"
           :size "icon"
           :class "body-line"
           :variant "ghost"
           :foreground "border"
           :width 24
           :height 24
           :accessibility-identifier-signal
           (reactive outliner-row-zoom-identifier row-source)
           :on-press
           (event [current-row row-source]
                  (if search-open
                    (send (model/RequestSearchNode (:uuid current-row)))
                    (send (model/RequestAppNode (:uuid current-row)))))}])))))

(defn outliner-status-control
  [ui-context model-source row-source send]
  (let [row (signal/sample row-source)]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:stack {:width 24 :height 24}
        [:row {:width 24 :height 24 :main "center" :cross "center"}
         [:stack {:width 22 :height 22}
          [:if {:test (reactive outliner-task-status-backlog? row-source)}
           [:icon
            {:name "app:task-backlog" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (outliner-row-uuid row))}]]
          [:if {:test (reactive outliner-task-status-todo? row-source)}
           [:icon
            {:name "app:task-todo" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (outliner-row-uuid row))}]]
          [:if {:test (reactive outliner-task-status-doing? row-source)}
           [:icon
            {:name "app:task-doing" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (outliner-row-uuid row))}]]
          [:if {:test (reactive outliner-task-status-review? row-source)}
           [:icon
            {:name "app:task-review" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (outliner-row-uuid row))}]]
          [:if {:test (reactive outliner-task-status-done? row-source)}
           [:icon
            {:name "app:task-done" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (outliner-row-uuid row))}]]
          [:if {:test (reactive outliner-task-status-canceled? row-source)}
           [:icon
            {:name "app:task-canceled" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (outliner-row-uuid row))}]]]]
        [:button
         {:label (reactive outliner-row-status-title row-source)
          :variant "ghost"
          :size "icon"
          :width 24
          :height 24
          :accessibility-identifier "button.block-task-status"}
         [:context-menu
          [:keyed
           {:source (reactive :task-statuses model-source)
            :key :uuid
            :compare compare
            :as status-source}
           [outliner-task-status-row (outliner-row-uuid row) status-source send]]]]])
      (elements/element
       ui-context nil
       [:button
        {:icon (reactive outliner-task-status-icon row-source)
         :label (reactive outliner-row-status-title row-source)
         :variant "ghost"
         :class "body-line"
         :foreground "secondary"
         :size "icon"
         :width 22
         :height 24
         :accessibility-identifier "button.block-task-status"}
        [:context-menu
         [:keyed
          {:source (reactive :task-statuses model-source)
           :key :uuid
           :compare compare
           :as status-source}
          [outliner-task-status-row (outliner-row-uuid row) status-source send]]]]))))

(defn outliner-row-main-content
  [ui-context model-source retained-row-source row-source send]
  (let [row (signal/sample row-source)
        block-id-source (reactive outliner-row-uuid row-source)
        title-source (reactive outliner-row-title row-source)
        markup-source (reactive :markup-json row-source)
        youtube-target-source
        (reactive outliner-row-youtube-target row-source)
        is-asset-source (reactive :is-asset row-source)
        asset-type-source (reactive outliner-row-asset-type row-source)
        local-path-source (reactive outliner-row-local-path row-source)
        editing-title-source
        (reactive retained-row-editing-title retained-row-source)
        editing-caret-source
        (reactive retained-row-editing-caret retained-row-source)
        editing-source (reactive retained-row-editing? retained-row-source)
        not-editing-source
        (reactive row-not-editing? model-source row-source)
        has-children-source (reactive outliner-row-has-children row-source)
        has-status-source (reactive outliner-row-has-status? row-source)
        has-tags-source (reactive outliner-row-has-tags? row-source)
        sync-failed-source (reactive outliner-row-sync-failed? row-source)]
    (elements/element
     ui-context nil
     [:row {:gap 7 :cross "start" :grow 1.0}
      [:if {:test has-status-source}
       [:column {:cross "start"}
        [outliner-status-control model-source row-source send]]]
      [:column {:grow 1.0 :cross "start"}
       [:if {:test editing-source}
        [outliner-editor-view block-id-source
         editing-title-source editing-caret-source send]]
       [:if {:test not-editing-source}
        [outliner-rich-block-view
         model-source title-source markup-source youtube-target-source
         is-asset-source row-source asset-type-source local-path-source send]]
       [:if {:test has-tags-source}
        [:row {:gap 6}
         [:keyed
          {:source (reactive :tags row-source)
           :key :uuid
           :compare compare
           :as tag-source}
          [outliner-tag tag-source send]]]]
       [:if {:test sync-failed-source}
        [:text
         {:accessibility-identifier
          (str "outliner.sync-failed." (outliner-row-uuid row))}
         "Sync failed"]]]
      [:if {:test has-children-source}
       [:column {:cross "start"}
        [outliner-collapse-button row-source send]]]])))

(defn outliner-row-content
  [ui-context model-source retained-row-source row-source send search-open]
  (let [indent-source (reactive outliner-row-indent row-source)]
    (elements/element
     ui-context nil
     [:row {:gap 0 :cross "start" :padding-vertical 5}
      [outliner-indent-view indent-source]
      [outliner-zoom-control model-source row-source send search-open]
      [:box {:width 2}]
      [outliner-row-main-content model-source retained-row-source
       row-source send]])))

(defn outliner-row
  [ui-context model-source retained-row-source row-source send]
  (let [row (signal/sample row-source)
        search-open (:search-open (signal/sample model-source))
        selected-source (reactive row-selected? model-source row-source)]
    (if (outliner-row-list-item-press-enabled? (ui/host ui-context) row)
      (elements/element
       ui-context nil
       [:box
        {:accessibility-identifier-signal (reactive outliner-row-identifier row-source)
         :padding 0
         :corner-radius 10
         :selected selected-source}
        [:row {:gap 0 :cross "start" :padding-vertical 5}
         [outliner-indent-view (reactive outliner-row-indent row-source)]
         [outliner-zoom-control model-source row-source send search-open]
         [:box {:width 2}]
         [:list-item
          {:accessibility-identifier-signal
           (reactive outliner-row-action-identifier row-source)
           :label (reactive outliner-row-action-label model-source row-source)
           :padding 0
           :grow 1.0
           :selected selected-source
           :on-press
           (event [current-row row-source]
                  (if (= (:is-asset current-row) true)
                    (send (model/OpenOutlinerAsset (:uuid current-row)))
                    (if (= (:opens-as-page current-row) true)
                      (if search-open
                        (send (model/RequestSearchNode (:uuid current-row)))
                        (send (model/RequestAppNode (:uuid current-row))))
                      (send (model/BeginOutlinerEdit (:uuid current-row))))))
           :on-long-press
           (event [current-row row-source]
                  (send (model/LongPressOutlinerBlock (:uuid current-row))))}
          [outliner-row-main-content model-source retained-row-source
           row-source send]]]])
      (elements/element
       ui-context nil
       [:box
        {:accessibility-identifier-signal (reactive outliner-row-identifier row-source)
         :label (reactive outliner-row-action-label model-source row-source)
         :padding 0
         :corner-radius 10
         :selected selected-source}
        [outliner-row-content model-source retained-row-source row-source
         send search-open]]))))

(defn outliner-entry
  [ui-context model-source retained-row-source row-source send]
  (elements/element
   ui-context nil
   [:column {:padding-horizontal 8}
    [:if {:test
          (reactive outliner-journal-divider-visible?
                    model-source row-source)}
     [:separator {:accessibility-identifier "journal.divider"}]]
    [:if {:test
          (reactive outliner-journal-heading-visible?
                    model-source row-source)}
     [:box
      {:padding 0
       :accessibility-identifier-signal
       (reactive outliner-journal-button-identifier
                 model-source row-source)}
      [:box {:padding-horizontal 8 :padding-vertical 12}
       [:box {:height 14}]
       [:heading
        {:level 3
         :class "scroll-section-title"
         :value (reactive outliner-journal-title
                          model-source row-source)}]]]]
    [outliner-row model-source retained-row-source row-source send]]))

(defn outliner-first-journal-section [ui-context model-source send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:column
      {:accessibility-identifier
       (first-journal-section-identifier (signal/sample model-source))}
      [:keyed
       {:source (reactive first-journal-retained-rows model-source)
        :key :render-key
        :compare compare
        :as retained-row-source}
       [outliner-entry model-source retained-row-source
        (reactive retained-row-value retained-row-source) send]]])
    (elements/element
     ui-context nil
     [:column
      {:container-relative-frame "min-vertical"
       :container-relative-frame-inset 136
       :accessibility-identifier
       (first-journal-section-identifier (signal/sample model-source))}
      [:keyed
       {:source (reactive first-journal-retained-rows model-source)
        :key :render-key
        :compare compare
        :as retained-row-source}
       [outliner-entry model-source retained-row-source
        (reactive retained-row-value retained-row-source) send]]])))

(defn outliner-selection-toolbar [ui-context send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:box
      {:height 56
       :padding-horizontal 8
       :padding-vertical 4
       :background "surface-container-high"
       :corner-radius 20
       :accessibility-identifier "surface.outliner.selection-toolbar"}
      [:toolbar
       {:orientation "horizontal"
        :label "Outliner selection"
        :accessibility-identifier "toolbar.outliner.selection"
        :class "scroll-leading"
        :gap 4}
      [:button
       {:icon "app:toolbar-copy" :variant "ghost" :size "icon"
        :width 48 :height 48 :foreground "muted-foreground"
        :label "Copy"
        :accessibility-identifier "button.outliner.selection.copy"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "copy")))}]
      [:button
       {:icon "app:toolbar-outdent" :variant "ghost" :size "icon"
        :width 48 :height 48 :foreground "muted-foreground"
        :label "Outdent"
        :accessibility-identifier "button.outliner.selection.outdent"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "outdent")))}]
      [:button
       {:icon "app:toolbar-indent" :variant "ghost" :size "icon"
        :width 48 :height 48 :foreground "muted-foreground"
        :label "Indent"
        :accessibility-identifier "button.outliner.selection.indent"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "indent")))}]
      [:button
       {:icon "app:toolbar-delete" :variant "ghost" :size "icon"
        :width 48 :height 48 :foreground "muted-foreground"
        :label "Delete"
        :accessibility-identifier "button.outliner.selection.delete"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "delete")))}]
      [:button
       {:icon "app:toolbar-copy-reference" :variant "ghost"
        :size "icon" :width 48 :height 48
        :foreground "muted-foreground" :label "Copy reference"
        :accessibility-identifier "button.outliner.selection.copyReference"
        :on-press
        (fn [_event]
          (send (model/PerformOutlinerToolbarAction "copyReference")))}]
      [:button
       {:icon "app:toolbar-copy-url" :variant "ghost" :size "icon"
        :width 48 :height 48 :foreground "muted-foreground"
        :label "Copy URL"
        :accessibility-identifier "button.outliner.selection.copyURL"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "copyURL")))}]
      [:button
       {:icon "app:toolbar-unselect" :variant "ghost" :size "icon"
        :width 48 :height 48 :foreground "muted-foreground"
        :label "Unselect"
        :accessibility-identifier "button.outliner.selection.unselect"
        :on-press
        (fn [_event]
          (send (model/PerformOutlinerToolbarAction "unselect")))}]]])
    (elements/element
     ui-context nil
     [:toolbar
      {:orientation "horizontal"
       :ios [[:liquid-glass {:shape "capsule"}]]
       :label "Outliner selection"
       :accessibility-identifier "toolbar.outliner.selection"
       :class "scroll-leading leading-inset-12"
       :height 54
       :gap 6}
      [:button
       {:icon "app:toolbar-copy" :variant "ghost" :width 58 :height 46
        :icon-placement "top" :label "Copy"
        :accessibility-identifier "button.outliner.selection.copy"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "copy")))}
       "Copy"]
      [:button
       {:icon "app:toolbar-outdent" :variant "ghost" :width 58 :height 46
        :icon-placement "top" :label "Outdent"
        :accessibility-identifier "button.outliner.selection.outdent"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "outdent")))}
       "Outdent"]
      [:button
       {:icon "app:toolbar-indent" :variant "ghost" :width 58 :height 46
        :icon-placement "top" :label "Indent"
        :accessibility-identifier "button.outliner.selection.indent"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "indent")))}
       "Indent"]
      [:button
       {:icon "app:toolbar-delete" :variant "ghost" :width 58 :height 46
        :icon-placement "top" :label "Delete"
        :accessibility-identifier "button.outliner.selection.delete"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "delete")))}
       "Delete"]
      [:button
       {:icon "app:toolbar-copy-reference" :variant "ghost"
        :width 58 :height 46 :icon-placement "top" :label "Copy reference"
        :accessibility-identifier "button.outliner.selection.copyReference"
        :on-press
        (fn [_event]
          (send (model/PerformOutlinerToolbarAction "copyReference")))}
       "Copy reference"]
      [:button
       {:icon "app:toolbar-copy-url" :variant "ghost" :width 58 :height 46
        :icon-placement "top" :label "Copy URL"
        :accessibility-identifier "button.outliner.selection.copyURL"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "copyURL")))}
       "Copy URL"]
      [:button
       {:icon "app:toolbar-unselect" :variant "ghost" :width 70 :height 46
        :icon-placement "top" :label "Unselect"
        :accessibility-identifier "button.outliner.selection.unselect"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "unselect")))}
       "Unselect"]])))

(defn outliner-autocomplete-row [ui-context candidate-source send]
  (let [candidate (signal/sample candidate-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive outliner-autocomplete-label candidate-source)
       :label (reactive outliner-autocomplete-label candidate-source)
       :variant "ghost"
       :grow (if (host? proto/FlutterHost) 0.0 1.0)
       :height 44
       :padding-horizontal 10
       :background "autocomplete-row-background"
       :foreground "foreground"
       :corner-radius 8
       :text-alignment "start"
       :accessibility-identifier
       (outliner-autocomplete-identifier candidate)
       :on-press
       (event [current-candidate candidate-source]
              (send
               (model/ChooseOutlinerAutocomplete
                (:value current-candidate))))}])))

(defui outliner-autocomplete-bar [model-source send]
  [:scroll
   {:max-height 220
    :accessibility-identifier "toolbar.outliner.autocomplete"
    :class "outliner-autocomplete"}
   [:column
    {:gap 2
     :padding 8
     :cross (if (host? proto/FlutterHost) "stretch" "center")
     :grow (if (host? proto/FlutterHost) 0.0 1.0)}
    [:keyed
     {:source (reactive :outliner-autocomplete-candidates model-source)
      :key :index
      :compare compare
      :as candidate-source}
     [outliner-autocomplete-row candidate-source send]]]])

(defn outliner-editor-toolbar [ui-context model-source send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:box
      {:height 56
       :padding-horizontal 8
       :padding-vertical 4
       :accessibility-identifier "surface.outliner.editor-toolbar"}
      [:toolbar
       {:orientation "horizontal"
        :label "Outliner editor"
        :accessibility-identifier "toolbar.outliner.editor"
        :class "scroll-leading"
        :gap 4}
   [:button
    {:icon "app:toolbar-task"
     :variant "ghost"
     :size "icon"
     :width 48
     :height 48
     :foreground "muted-foreground"
     :label (reactive outliner-editor-task-label model-source)
     :accessibility-identifier "button.outliner.editor.task"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "task")))}]
   [:button
    {:icon "app:toolbar-outdent"
     :variant "ghost"
     :size "icon"
     :width 48
     :height 48
     :foreground "muted-foreground"
     :label "Outdent"
     :accessibility-identifier "button.outliner.editor.outdent"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "outdent")))}]
   [:button
    {:icon "app:toolbar-indent"
     :variant "ghost"
     :size "icon"
     :width 48
     :height 48
     :foreground "muted-foreground"
     :label "Indent"
     :accessibility-identifier "button.outliner.editor.indent"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "indent")))}]
   [:button
    {:icon "app:toolbar-tag"
     :variant "ghost"
     :size "icon"
     :width 48
     :height 48
     :foreground "muted-foreground"
     :label "Tag"
     :accessibility-identifier "button.outliner.editor.tag"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "tag")))}]
   [:button
    {:icon "app:toolbar-camera"
     :variant "ghost"
     :size "icon"
     :width 48
     :height 48
     :foreground "muted-foreground"
     :label "Photo"
     :accessibility-identifier "button.outliner.editor.camera"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "camera")))}]
   [:button
    {:icon "app:toolbar-audio"
     :variant "ghost"
     :size "icon"
     :width 48
     :height 48
     :foreground "muted-foreground"
     :label "Record audio"
     :accessibility-identifier "button.outliner.editor.audio"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "audio")))}]
   [:button
    {:icon "app:toolbar-attachment"
     :variant "ghost"
     :size "icon"
     :width 48
     :height 48
     :foreground "muted-foreground"
     :label "Upload asset"
     :accessibility-identifier "button.outliner.editor.attachment"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "attachment")))}]
   [:button
    {:variant "ghost"
     :size "icon"
     :width 48
     :height 48
     :foreground "muted-foreground"
     :label "Page reference"
     :accessibility-identifier "button.outliner.editor.pageReference"
     :on-press
     (fn [_event]
       (send (model/PerformOutlinerToolbarAction "pageReference")))}
    "[[]]"]
   [:button
    {:icon "app:toolbar-hide-keyboard"
     :variant "ghost"
     :size "icon"
     :width 48
     :height 48
     :foreground "muted-foreground"
     :label "Hide keyboard"
     :accessibility-identifier "button.outliner.editor.hideKeyboard"
     :on-press
     (fn [_event]
       (send (model/PerformOutlinerToolbarAction "hideKeyboard")))}]]])
    (elements/element
     ui-context nil
     [:toolbar
      {:orientation "horizontal"
       :label "Outliner editor"
       :accessibility-identifier "toolbar.outliner.editor"
       :class "scroll leading-inset-8"
       :height 50
       :gap 4}
      [:button
       {:icon "app:toolbar-task"
        :variant "ghost"
        :width 38
        :height 42
        :label (reactive outliner-editor-task-label model-source)
        :accessibility-identifier "button.outliner.editor.task"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "task")))}]
      [:button
       {:icon "app:toolbar-outdent"
        :variant "ghost"
        :width 38
        :height 42
        :label "Outdent"
        :accessibility-identifier "button.outliner.editor.outdent"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "outdent")))}]
      [:button
       {:icon "app:toolbar-indent"
        :variant "ghost"
        :width 38
        :height 42
        :label "Indent"
        :accessibility-identifier "button.outliner.editor.indent"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "indent")))}]
      [:button
       {:icon "app:toolbar-tag"
        :variant "ghost"
        :width 38
        :height 42
        :label "Tag"
        :accessibility-identifier "button.outliner.editor.tag"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "tag")))}]
      [:button
       {:icon "app:toolbar-camera"
        :variant "ghost"
        :width 38
        :height 42
        :label "Photo"
        :accessibility-identifier "button.outliner.editor.camera"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "camera")))}]
      [:button
       {:icon "app:toolbar-audio"
        :variant "ghost"
        :width 38
        :height 42
        :label "Record audio"
        :accessibility-identifier "button.outliner.editor.audio"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "audio")))}]
      [:button
       {:icon "app:toolbar-attachment"
        :variant "ghost"
        :width 38
        :height 42
        :label "Upload asset"
        :accessibility-identifier "button.outliner.editor.attachment"
        :on-press
        (fn [_event] (send (model/PerformOutlinerToolbarAction "attachment")))}]
      [:button
       {:variant "ghost"
        :width 38
        :height 42
        :label "Page reference"
        :accessibility-identifier "button.outliner.editor.pageReference"
        :on-press
        (fn [_event]
          (send (model/PerformOutlinerToolbarAction "pageReference")))}
       "[[]]"]
      [:button
       {:icon "app:toolbar-hide-keyboard"
        :variant "ghost"
        :width 42
        :height 42
        :label "Hide keyboard"
        :accessibility-identifier "button.outliner.editor.hideKeyboard"
        :on-press
        (fn [_event]
          (send (model/PerformOutlinerToolbarAction "hideKeyboard")))}]])))

(defn node-related-row [ui-context model-source row-source send]
  (let [structured-breadcrumb-source
        (reactive outliner-row-structured-breadcrumb? row-source)
        fallback-breadcrumb-source
        (reactive outliner-row-fallback-breadcrumb? row-source)
        retained-row-source
        (reactive make-retained-outline-row model-source row-source)]
    (elements/element
     ui-context nil
     [:column
      {:gap 0}
      [:if {:test structured-breadcrumb-source}
       [:box {:padding-horizontal 8}
        [:box {:height 10}]
        [related-row-breadcrumbs row-source send]]]
      [:if {:test fallback-breadcrumb-source}
       [:box {:padding-horizontal 8}
        [:box {:height 10}]
        [:text {:value (reactive outliner-row-breadcrumb row-source)
                :class "caption"
                :foreground "muted-foreground"}]]]
      [outliner-row model-source retained-row-source row-source send]])))

(defui related-section-heading [title]
  [:box {:padding-horizontal 8}
   [:text {:class "subheadline"
           :foreground "muted-foreground"
           :accessibility-identifier "title.related-section"}
    title]])

(defui node-related-section [model-source send]
  [:column
   {:gap 0
    :accessibility-identifier "section.node.linked-references"}
   [:box {:height 26}]
   [related-section-heading "Linked references"]
   [:box {:height 8}]
   [:column {:accessibility-identifier "list.node.related"}
    [:keyed
     {:source (reactive active-node-related-rows model-source)
      :key :uuid
      :compare compare
      :as row-source}
     [node-related-row model-source row-source send]]]])

(defui node-tagged-section [model-source send]
  [:column
   {:gap 0
    :accessibility-identifier "section.tag.tagged-nodes"}
   [:box {:height 26}]
   [related-section-heading "Tagged nodes"]
   [:box {:height 8}]
   [:if {:test (reactive node-tag-section-empty? model-source)}
    [:box {:padding-horizontal 8}
     [:text {:foreground "muted-foreground"} "No tagged nodes"]]]
   [:column {:accessibility-identifier "list.node.tagged"}
    [:keyed
     {:source (reactive active-node-related-rows model-source)
      :key :uuid
      :compare compare
      :as row-source}
     [node-related-row model-source row-source send]]]])

(defui node-linked-reference-section [model-source send]
  [:column
   {:gap 0
    :accessibility-identifier "section.node.linked-references"}
   [:box {:height 26}]
   [related-section-heading "Linked references"]
   [:box {:height 8}]
   [:column {:accessibility-identifier "list.node.linked-references"}
    [:keyed
     {:source (reactive active-node-linked-reference-rows model-source)
      :key :uuid
      :compare compare
      :as row-source}
     [node-related-row model-source row-source send]]]])

(defui add-first-block-button [model-source send]
  [:box {:padding-horizontal 8}
   [:button
    {:label "Add first block"
     :accessibility-identifier "button.outliner.add-first-block"
     :on-press
     (event [current model-source]
            (send (model/AddRootBlock (active-node-page-uuid current))))}
    "Add first block"]])

(defui node-screen [model-source send]
  [:column
   {:accessibility-identifier "screen.node"
    :grow (if (host? proto/FlutterHost) 1.0 0.0)}
   [:scroll {:grow 1.0 :accessibility-identifier "scroll.outliner"}
    [:column {:gap 0 :padding-horizontal 8}
     [:box {:height 16}]
     [:if {:test (reactive active-node-has-breadcrumbs? model-source)}
      [:box {:padding-horizontal 8}
       [node-breadcrumbs model-source send]]]
     [:if {:test (reactive node-title-visible? model-source)}
      [:column {:gap 0}
       [:box {:height 26}]
       [:box
        {:padding-horizontal 8
         :accessibility-identifier "layout.node.title"}
        [:heading
         {:level 3
          :value (reactive active-node-title model-source)
          :accessibility-identifier "title.node"}]]
       [:box {:height 12}]]]
     [:if {:test (reactive node-outliner-visible? model-source)}
      [:column {:accessibility-identifier "list.outliner"}
       [:keyed
        {:source (reactive retained-outliner-rows model-source)
         :key :render-key
         :compare compare
         :as retained-row-source}
        [outliner-row model-source retained-row-source
         (reactive retained-row-value retained-row-source) send]]]]
     [:if {:test (reactive node-can-add-first-block? model-source)}
      [add-first-block-button model-source send]]
     [:if {:test (reactive node-related-section-visible? model-source)}
      [node-related-section model-source send]]
     [:if {:test (reactive node-tag-section-visible? model-source)}
      [node-tagged-section model-source send]]
     [:if {:test (reactive node-linked-reference-section-visible? model-source)}
      [node-linked-reference-section model-source send]]
     [:box {:height 120}]]]])

(declare task-status-picker-dialog)

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

(defn composer-asset-title [asset] (:title asset))
(defn composer-asset-path [asset] (:local-path asset))
(defn composer-asset-identifier [asset] (str "composer.asset." (:uuid asset)))

(defn composer-asset-preview [ui-context asset-source]
  (let [node (ui/extension! ui-context "composer-asset")]
    (ui/extension-property-signal! ui-context node "title"
     (reactive string-wire-value (reactive composer-asset-title asset-source)))
    (ui/extension-property-signal! ui-context node "local-path"
     (reactive string-wire-value (reactive composer-asset-path asset-source)))
    node))

(defn composer-asset-view [ui-context asset-source send]
  (let [asset (signal/sample asset-source)]
    (elements/element ui-context nil
     [:stack {:width 128 :height 128
              :accessibility-identifier (composer-asset-identifier asset)}
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

(defn composer-assets-present? [current]
  (not (empty? (:composer-assets current))))

(defui composer-view [model-source send]
  [:box
   {:accessibility-identifier "surface.composer.root"
    :grow 1.0
    :min-height 58}
   [:if {:test (reactive :composer-expanded model-source)}
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
     [:if {:test (reactive composer-assets-present? model-source)}
      [:scroll {:orientation "horizontal" :height 140}
       [:row {:gap 8}
        [:keyed {:source (reactive :composer-assets model-source)
                 :key :uuid :compare compare :as asset-source}
         [composer-asset-view asset-source send]]]]]
     [:textarea
      {:text (reactive :composer-draft model-source)
       :autofocus (reactive :composer-autofocus model-source)
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
       [:if {:test (reactive :task-status-picker-open model-source)}
        [task-status-picker-dialog model-source send]]]
      [:spacer
       {:grow 1.0
        :accessibility-identifier "spacer.composer.controls"}]
      [composer-send-button
       (reactive composer-send-disabled? model-source) send]]]]
   [:if {:test (reactive composer-collapsed? model-source)}
    [collapsed-composer-button send]]])

(defn task-status-row [ui-context status-source send]
  (let [status (signal/sample status-source)]
    (elements/element
     ui-context nil
     [:menu-item
      {:text (reactive task-status-title status-source)
       :icon (reactive task-status-icon-name status-source)
       :foreground-signal (reactive task-status-foreground status-source)
       :accessibility-identifier (task-status-identifier status)
       :on-press
       (event [current-status status-source]
              (send (model/ChooseTaskStatus (:uuid current-status))))}])))

(defui task-status-picker-dialog [model-source send]
  [:dropdown-menu
   {:anchor "above"
    :anchor-alignment "start"
    :min-width 220
    :on-dismiss (fn [_event] (send model/CloseTaskStatusPicker))}
   [:keyed
    {:source (reactive :task-statuses model-source)
     :key :uuid
     :compare compare
     :as status-source}
    [task-status-row status-source send]]
   [:if {:test (reactive task-status-selected? model-source)}
    [:menu-item
     {:accessibility-identifier "button.task-status.clear"
      :on-press (fn [_event] (send model/ClearTaskStatus))}
     "Clear task status"]]])

(defn outliner-task-status-option-identifier [status]
  (str
   "button.block-task-status-option."
   (match (:ident status)
     (Some ident) ident
     None (:uuid status))))

(defn outliner-task-status-row [ui-context block-id status-source send]
  (let [status (signal/sample status-source)]
    (elements/element
     ui-context nil
     [:menu-item
      {:text (reactive task-status-title status-source)
       :icon (reactive task-status-icon-name status-source)
       :foreground "secondary"
       :accessibility-identifier
       (outliner-task-status-option-identifier status)
       :on-press
       (event [current-status status-source]
              (send
               (model/SetOutlinerTaskStatus block-id
                                            (:uuid current-status))))}])))

(defn first-flashcard [current]
  (if (empty? (:flashcards current))
    None
    (Some (nth (:flashcards current) 0))))

(defn flashcards-empty? [current]
  (empty? (:flashcards current)))

(defn flashcards-present? [current]
  (not (flashcards-empty? current)))

(defn flashcard-question [current]
  (match (first-flashcard current)
    (Some card)
    (if (:flashcard-cloze-revealed current)
      (:question-revealed card)
      (:question-hidden card))
    None ""))

(defn flashcard-remaining-label [current]
  (str (count (:flashcards current)) " remaining"))

(defn flashcard-show-cloze? [current]
  (match (first-flashcard current)
    (Some card)
    (and (:has-cloze card)
         (not (:flashcard-cloze-revealed current)))
    None false))

(defn flashcard-show-answer? [current]
  (match (first-flashcard current)
    (Some card)
    (and (or (not (:has-cloze card))
             (:flashcard-cloze-revealed current))
         (not (:flashcard-answer-revealed current)))
    None false))

(defn flashcard-show-ratings? [current]
  (and (flashcards-present? current)
       (:flashcard-answer-revealed current)))

(defn visible-flashcard-answer-rows [current]
  (if (:flashcard-answer-revealed current)
    (match (first-flashcard current)
      (Some card) (:answer-rows card)
      None [])
    []))

(defn flashcard-answer-rows-visible? [current]
  (not (empty? (visible-flashcard-answer-rows current))))

(defn flashcard-answer-identifier [answer]
  (str "flashcard.answer." (:index answer)))

(defn flashcard-answer-text [answer]
  (:text answer))

(defn flashcard-answer-row [ui-context answer-source]
  (let [answer (signal/sample answer-source)]
    (elements/element
     ui-context nil
     [:text
      {:value (reactive flashcard-answer-text answer-source)
       :accessibility-identifier (flashcard-answer-identifier answer)}])))

;; Flashcard controls use shared button typography and alignment semantics.
(defui flashcard-rating-button
  [rating title foreground background send]
  [:button
   {:variant "ghost"
    :class "semibold"
    :grow 1.0
    :min-height 50
    :text-alignment "center"
    :foreground foreground
    :background background
    :corner-radius 14
    :accessibility-identifier (str "button.flashcard.rating." rating)
    :on-press (fn [_event] (send (model/ReviewFlashcard rating)))}
   title])

(defui flashcard-review-content [model-source send]
  [:column
   {:accessibility-identifier "layout.flashcards.review"
    :grow 1.0
    :gap 0
    :padding-horizontal 20}
   [:box
    {:height 18
     :accessibility-identifier "spacer.flashcards.top"}]
   [:column
    {:accessibility-identifier "layout.flashcards.review-content"
     :grow 1.0
     :gap 18}
    [:row
     {:accessibility-identifier "row.flashcards.status"}
     [:text {:class "footnote" :foreground "muted-foreground"} "Due now"]
     [:spacer {:grow 1.0}]
     [:text
      {:class "footnote"
       :foreground "muted-foreground"
       :value (reactive flashcard-remaining-label model-source)}]]
   [:scroll
    {:grow 1.0}
    [:column
     {:accessibility-identifier "card.flashcard.question"
      :gap 18
      :padding 22
      :background "surface"
      :corner-radius 18}
     [:text
      {:class "title2 semibold"
       :value (reactive flashcard-question model-source)
       :accessibility-identifier "flashcard.question"}]
     [:if {:test (reactive flashcard-answer-rows-visible? model-source)}
      [:column
       {:gap 18}
       [:separator {:accessibility-identifier "flashcard.answer-divider"}]
       [:column
        {:gap 12}
        [:keyed
         {:source (reactive visible-flashcard-answer-rows model-source)
          :key :uuid
          :compare compare
          :as answer-source}
         [flashcard-answer-row answer-source]]]]]]]
    [:if {:test (reactive flashcard-show-cloze? model-source)}
    [:row
     [:button
      {:variant "ghost"
       :class "semibold"
       :grow 1.0
       :min-height 50
       :text-alignment "center"
       :foreground "white"
       :background "primary"
       :corner-radius 14
       :accessibility-identifier "button.flashcard.show-cloze"
       :on-press (fn [_event] (send model/RevealFlashcardCloze))}
      "Show cloze"]]]
    [:if {:test (reactive flashcard-show-answer? model-source)}
    [:row
     [:button
      {:variant "ghost"
       :class "semibold"
       :grow 1.0
       :min-height 50
       :text-alignment "center"
       :foreground "white"
       :background "primary"
       :corner-radius 14
       :accessibility-identifier "button.flashcard.show-answer"
       :on-press (fn [_event] (send model/RevealFlashcardAnswer))}
      "Show answer"]]]
    [:if {:test (reactive flashcard-show-ratings? model-source)}
     [:column
      {:gap 10}
      [:row
       {:gap 10}
       [flashcard-rating-button
        "again" "Again" "red" "flashcard-again-background" send]
       [flashcard-rating-button
        "hard" "Hard" "warning-foreground" "flashcard-hard-background" send]]
      [:row
       {:gap 10}
       [flashcard-rating-button
        "good" "Good" "blue" "flashcard-good-background" send]
       [flashcard-rating-button
        "easy" "Easy" "green" "flashcard-easy-background" send]]]]]
   [:box
    {:height 24
     :accessibility-identifier "spacer.flashcards.bottom"}]])

(defui flashcard-screen [model-source send]
  [:column
   {:accessibility-identifier "screen.flashcards"
    :grow 1.0
    :gap 0
    :background "background"}
   [:if {:test (reactive flashcards-empty? model-source)}
    [:column
     {:accessibility-identifier "layout.flashcards.empty"
      :grow 1.0
      :main "center"
      :cross "center"
      :gap 10
      :padding 32}
     [:icon
      {:name "app:flashcards"
       :width 48
       :height 48
       :foreground "muted-foreground"}]
     [:heading
      {:level 3
       :accessibility-identifier "flashcards.empty"}
      "No cards due"]
     [:text
      {:text-alignment "center"
       :foreground "muted-foreground"}
      "Tag any block with #Card to review it here."]]]
   [:if {:test (reactive flashcards-present? model-source)}
    [flashcard-review-content model-source send]]])

(defn graph-identifier [graph]
  (str "graph." (:id graph)))

(defn graph-delete-identifier [graph]
  (str "button.graph.delete." (:id graph)))

(defn graph-status-identifier [graph]
  (str "graph.status." (:id graph)))

(defn graph-status-visible? [graph]
  (or (:is-encrypted graph) (not (:is-ready graph))))

(defn graph-status-title [graph]
  (if (:is-encrypted graph) "Encrypted" "Graph is not ready for sync."))

(defn graph-not-ready? [graph]
  (not (:is-ready graph)))

(defn graph-row-disabled? [current graph]
  (or (graph-not-ready? graph)
      (model/graph-delete-active? current (:id graph))))

(defn graph-delete-active? [current graph]
  (model/graph-delete-active? current (:id graph)))

(defn graph-row-local? [current graph]
  (model/graph-local? current (:id graph)))

(defn graph-icon-name [local? graph]
  (if local?
    "app:graph-local"
    "app:graph-remote"))

(defn local-graphs [current]
  (filterv
   (fn [graph] (model/graph-local? current (:id graph)))
   (:graphs current)))

(defn remote-graphs [current]
  (filterv
   (fn [graph] (not (model/graph-local? current (:id graph))))
   (:graphs current)))

(defn local-graphs-empty? [current]
  (empty? (local-graphs current)))

(defn graphs-empty? [current]
  (let [_destination (:destination current)]
    (empty? (:graphs current))))

(defn graphs-present? [current]
  (not (graphs-empty? current)))

(defn remote-graphs-present? [current]
  (not (empty? (remote-graphs current))))

(defn new-graph-name-empty? [current]
  (string/blank? (:new-graph-name current)))

(defn graph-create-disabled? [current]
  (or (new-graph-name-empty? current)
      (model/graph-create-active? current)))

(defn empty-graphs-loading? [current]
  (and (graphs-empty? current) (model/graph-refresh-active? current)))

(defn empty-graphs-refreshable? [current]
  (and (graphs-empty? current) (not (model/graph-refresh-active? current))))

(defn graph-deletion-pending? [current]
  (match (:pending-graph-deletion current)
    (Some _graph) true
    None false))

(defn graph-deletion-message [current]
  (match (:pending-graph-deletion current)
    (Some graph)
    (str "Are you sure you want to permanently delete the graph \""
         (:name graph)
         "\" from Logseq?")
    None ""))

(defn graph-password-empty? [current]
  (string/blank? (:graph-password current)))

(defn graph-unlock-disabled? [current]
  (or (graph-password-empty? current)
      (model/graph-unlock-active? current)))

(defn effect-error-present? [current]
  (match (:effect-error current)
    (Some message) (not (empty? message))
    None false))

(defn effect-error-message [current]
  (match (:effect-error current)
    (Some message) message
    None ""))

(defn graph-unlock-error-present? [current]
  (effect-error-present? current))

(defn graph-unlock-error-message [current]
  (effect-error-message current))

(defn global-effect-error-present? [current]
  (and (effect-error-present? current)
       (not (:graph-password-open current))
       (not (= (:authentication-state current) "signedOut"))
       (not (= (:authentication-state current) "signingIn"))
       (match (:sync-state current)
         (FailedState _reason) false
         _ true)))

(defn graph-row [ui-context model-source graph-source local? send]
  (let [graph (signal/sample graph-source)
        graph-id (:id graph)]
    (elements/element
     ui-context nil
     [:list-item
      {:accessibility-identifier (graph-identifier graph)
       :padding 16
       :corner-radius 16
       :background (if (= (ui/host ui-context) proto/FlutterHost)
                     "surface-container-low"
                     "surface")
       :disabled (reactive graph-row-disabled? model-source graph-source)
       :on-press
       (event [current-graph graph-source]
              (send (model/RequestOpenGraph (:id current-graph))))}
      [:column {:gap 4 :grow 1.0}
       [:text
        {:class "semibold"
         :value (reactive graph-title graph-source)}]
       [:if {:test (reactive graph-status-visible? graph-source)}
        [:text
         {:value (reactive graph-status-title graph-source)
          :class "caption"
          :foreground "muted-foreground"
          :accessibility-identifier (graph-status-identifier graph)}]]]
      [:context-menu
       {:accessibility-identifier (graph-delete-identifier graph)}
       [:if {:test (reactive graph-row-local? model-source graph-source)}
        [:menu-item
         {:icon "app:trash"
          :variant "destructive"
          :disabled (reactive graph-delete-active? model-source graph-source)
          :on-press (fn [_event] (send (model/RequestDeleteGraph graph-id)))}
         "Delete local graph"]]]])))

(defn graph-list-row [ui-context model-source graph-source local? send]
  (let [graph (signal/sample graph-source)
        graph-id (:id graph)]
    (elements/element
     ui-context nil
     [:list-item
      {:icon (reactive (fn [current-graph]
                         (if (and (not (= (ui/host ui-context) proto/FlutterHost))
                                  (not local?) (= (:is-encrypted current-graph) true))
                           "app:graph-locked"
                           (graph-icon-name local? current-graph)))
                       graph-source)
       :min-height (if (= (ui/host ui-context) proto/FlutterHost) 56 44)
       :accessibility-identifier (graph-identifier graph)
       :disabled (if local?
                   (reactive graph-delete-active? model-source graph-source)
                   (reactive graph-row-disabled? model-source graph-source))
       :on-press
       (event [current-graph graph-source]
              (send (model/RequestOpenGraph (:id current-graph))))}
      [:column {:gap 4}
       [:text {:value (reactive graph-title graph-source)}]
       [:if {:test (reactive graph-not-ready? graph-source)}
        [:text
         {:class "caption"
          :foreground "muted-foreground"
          :accessibility-identifier (graph-status-identifier graph)}
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
       {:accessibility-identifier (graph-delete-identifier graph)}
       [:if {:test (reactive graph-row-local? model-source graph-source)}
        [:menu-item
         {:variant "destructive"
          :disabled (reactive graph-delete-active? model-source graph-source)
          :on-press (fn [_event] (send (model/RequestDeleteGraph graph-id)))}
         "Delete local graph"]]]])))

(defui graph-create-sheet [model-source send]
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
         {:text (reactive :new-graph-name model-source)
          :placeholder "Graph name"
          :label "Graph name"
          :accessibility-identifier "field.graph-name"
          :on-input
          (fn [input-event]
            (match input-event
              (TextChanged _node text) (send (model/ChangeNewGraphName text))
              _ true))}]
        [:switch
         {:checked (reactive :new-graph-encrypted model-source)
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
        [:if {:test (reactive effect-error-present? model-source)}
         [:text
          {:value (reactive effect-error-message model-source)
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
           :disabled (reactive graph-create-disabled? model-source)
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
        {:text (reactive :new-graph-name model-source)
         :placeholder "Graph name"
         :label "Graph name"
         :accessibility-identifier "field.graph-name"
         :on-input
         (fn [input-event]
           (match input-event
             (TextChanged _node text) (send (model/ChangeNewGraphName text))
             _ true))}]
       [:toggle
        {:checked (reactive :new-graph-encrypted model-source)
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
       [:if {:test (reactive effect-error-present? model-source)}
        [:text
         {:value (reactive effect-error-message model-source)
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
         :disabled (reactive graph-create-disabled? model-source)
         :on-press (fn [_event] (send model/SubmitCreateGraph))}
        "Add"]]])))

(defui graph-delete-dialog [model-source send]
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
         {:value (reactive graph-deletion-message model-source)
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
        {:value (reactive graph-deletion-message model-source)
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
       (handle-native-overflow-menu-event input-event send)))
    node))

(defn graph-picker-error-reason [current]
  (match (:effect-error current)
    (Some reason) (Some reason)
    None
    (match (:sync-state current)
      (FailedState reason) (Some reason)
      _ None)))

(defn graph-picker-error-present? [current]
  (match (graph-picker-error-reason current)
    (Some _reason) true
    None false))

(defn error-separator [reason]
  (string/index-of reason "\n"))

(defn graph-picker-error-code [current]
  (match (graph-picker-error-reason current)
    (Some reason)
    (let [separator (error-separator reason)]
      (if (< separator 0) "sync_failed" (subs reason 0 separator)))
    None ""))

(defn graph-picker-error-title [current]
  (match (graph-picker-error-code current)
    "graph_discovery_failed" "Couldn't load graphs"
    "graph_create_failed" "Couldn't create graph"
    "graph_open_failed" "Couldn't open graph"
    "graph_unlock_failed" "Couldn't unlock graph"
    "graph_initial_upload_failed" "Couldn't upload graph"
    "graph_key_provision_failed" "Couldn't prepare encryption"
    "sync_failed" "Sync failed"
    _ "Something went wrong"))

(defn graph-picker-error-message [current]
  (match (graph-picker-error-reason current)
    (Some reason)
    (let [separator (error-separator reason)]
      (if (< separator 0) reason (subs reason (inc separator))))
    None ""))

(defui graph-picker-error-banner [model-source]
  [:alert
   {:variant "destructive"
    :accessibility-identifier "error.banner"
    :padding 14
    :corner-radius 16
    :border-width 0}
   [:column {:gap 4}
    [:heading
     {:level 5
      :value (reactive graph-picker-error-title model-source)
      :accessibility-identifier "error.banner.code"}]
    [:text
     {:value (reactive graph-picker-error-message model-source)
      :accessibility-identifier "error.banner.message"}]]])

(defui graph-password-sheet [model-source send]
  [:sheet
   {:text "Unlock encrypted graphs"
    :on-dismiss (fn [_event] (send model/CancelGraphUnlock))}
   [:column
    [:text "Unlock encrypted graphs"]
    [:secure-field
     {:text (reactive :graph-password model-source)
      :placeholder "E2EE password"
      :label "E2EE password"
      :accessibility-identifier "field.graph-password"
      :on-input
      (fn [input-event]
        (match input-event
          (TextChanged _node text) (send (model/ChangeGraphPassword text))
          _ true))}]
    [:if {:test (reactive graph-unlock-error-present? model-source)}
     [:text
      {:value (reactive graph-unlock-error-message model-source)
       :accessibility-identifier "text.graph-unlock-error"}]]
    [:button
     {:accessibility-identifier "button.graph-unlock.cancel"
      :on-press (fn [_event] (send model/CancelGraphUnlock))}
     "Cancel"]
    [:button
     {:accessibility-identifier "button.graph-unlock"
      :disabled (reactive graph-unlock-disabled? model-source)
      :on-press (fn [_event] (send model/SubmitGraphPassword))}
     "Unlock"]]])

(defui graphs-screen [model-source send]
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
      [:if {:test (reactive local-graphs-empty? model-source)}
       [:box {:padding 16}
        [:text {:foreground "muted-foreground"} "No local graphs"]]]
      [:keyed
       {:source (reactive local-graphs model-source)
        :key :id
        :compare compare
        :as graph-source}
       [graph-list-row model-source graph-source true send]]
      [:if {:test (reactive remote-graphs-present? model-source)}
       [:box {:padding 16}
        [:heading {:level 5} "Remote graphs"]]]
      [:keyed
       {:source (reactive remote-graphs model-source)
        :key :id
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
      [:if {:test (reactive local-graphs-empty? model-source)}
       [:text {:foreground "secondary"} "No local graphs"]]
      [:keyed
       {:source (reactive local-graphs model-source)
        :key :id
        :compare compare
        :as graph-source}
       [graph-list-row model-source graph-source true send]]
      [:if {:test (reactive remote-graphs-present? model-source)}
       [:heading {:level 5 :accessibility-identifier "heading.graphs.remote"}
        "Remote graphs:"]]
      [:keyed
       {:source (reactive remote-graphs model-source)
        :key :id
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

(defui flutter-graph-picker-catalog [model-source send]
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
      {:source (reactive :graphs model-source)
       :key :id
       :compare compare
       :as graph-source}
      [graph-row model-source graph-source false send]]]]])

(defui graph-picker-screen [model-source send]
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
      [:if {:test (reactive graph-picker-error-present? model-source)}
       [graph-picker-error-banner model-source]]
      [:if {:test (reactive empty-graphs-loading? model-source)}
       [flutter-graph-picker-loading-state]]
      [:if {:test (reactive empty-graphs-refreshable? model-source)}
       [flutter-graph-picker-empty-state send]]
      [:if {:test (reactive graphs-present? model-source)}
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
      [:if {:test (reactive graph-picker-error-present? model-source)}
       [graph-picker-error-banner model-source]]
      [:if {:test (reactive empty-graphs-loading? model-source)}
       [:spinner {:accessibility-identifier "graphs.loading"}]]
      [:if {:test (reactive empty-graphs-refreshable? model-source)}
       [:button
        {:variant "ghost"
         :foreground "foreground"
         :accessibility-identifier "button.graphs.refresh"
         :on-press (fn [_event] (send model/RefreshGraphs))}
        "Refresh graphs"]]
      [:scroll {:grow 1.0}
       [:column {:gap 12}
        [:keyed
         {:source (reactive :graphs model-source)
          :key :id
          :compare compare
          :as graph-source}
         [graph-row model-source graph-source false send]]]]])))

(defn settings-main-visible? [current]
  (and (not (:settings-tabs-open current))
       (not (:runtime-log-open current))))

(defn settings-spell-check [current]
  (:spell-check current))

(defn settings-auto-correction [current]
  (:auto-correction current))

(defn settings-base-url [current]
  (:base-url current))

(defn settings-base-url-invalid? [current]
  (and (not (empty? (string/trim (:base-url current))))
       (not (model/valid-base-url? (:base-url current)))))

(defn settings-apply-disabled? [current]
  (not (model/valid-base-url? (:base-url current))))

(defn settings-version [current]
  (:version current))

(defn settings-revision [current]
  (:revision current))

(defn settings-language-title [current]
  (match (model/settings-language-by-id
          (:language-choices current) (:language current))
    (Some choice) (:title choice)
    None "System"))

(defn settings-appearance-title [current]
  (cond
    (= (:appearance current) "light") "Light"
    (= (:appearance current) "dark") "Dark"
    :else "System"))

(defn settings-language-choice-title [choice]
  (:title choice))

(defn settings-language-choice-identifier [choice]
  (str "button.settings.language." (:id choice)))

(defn settings-language-choice-radio
  [ui-context model-source choice-source send]
  (let [choice (signal/sample choice-source)]
    (elements/element
     ui-context nil
     [:radio
      {:checked (reactive model/settings-language-choice-selected?
                          model-source choice-source)
       :accessibility-identifier (settings-language-choice-identifier choice)
       :on-change
       (fn [_event] (send (model/ChooseSettingsLanguage (:id choice))))}
      (settings-language-choice-title choice)])))

(defn settings-language-choice-menu-item [ui-context choice-source send]
  (let [choice (signal/sample choice-source)]
    (elements/element
     ui-context nil
     [:menu-item
      {:text (reactive settings-language-choice-title choice-source)
       :accessibility-identifier (settings-language-choice-identifier choice)
       :on-press
       (fn [_event] (send (model/ChooseSettingsLanguage (:id choice))))}])))

(defui settings-language-control [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:stack
      {:accessibility-identifier "layout.settings.language-control"}
      [:select
       {:text (reactive settings-language-title model-source)
        :label "Language"
        :accessibility-identifier "picker.settings.language"
        :on-press (fn [_event] (send model/OpenSettingsLanguageMenu))}]
      [:if {:test (reactive :settings-language-menu-open model-source)}
       [:dropdown-menu
        {:anchor "below"
         :anchor-alignment "end"
         :min-width 220
         :on-dismiss (fn [_event] (send model/CloseSettingsLanguageMenu))}
        [:keyed
         {:source (reactive :language-choices model-source)
          :key :id
          :compare compare
          :as choice-source}
         [settings-language-choice-menu-item choice-source send]]]]])
    (elements/element
     ui-context nil
     [:radio-group
      {:label "Language"
       :class "menu"
       :accessibility-identifier "picker.settings.language"}
      [:keyed
       {:source (reactive :language-choices model-source)
        :key :id
        :compare compare
        :as choice-source}
       [settings-language-choice-radio model-source choice-source send]]])))

(defui settings-appearance-control [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:stack
      {:accessibility-identifier "layout.settings.appearance-control"}
      [:select
       {:text (reactive settings-appearance-title model-source)
        :label "Theme"
        :accessibility-identifier "picker.settings.appearance"
        :on-press (fn [_event] (send model/OpenSettingsAppearanceMenu))}]
      [:if {:test (reactive :settings-appearance-menu-open model-source)}
       [:dropdown-menu
        {:anchor "below"
         :anchor-alignment "end"
         :min-width 160
         :on-dismiss (fn [_event] (send model/CloseSettingsAppearanceMenu))}
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "system")))}
         "System"]
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "light")))}
         "Light"]
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "dark")))}
         "Dark"]]]])
    (elements/element
     ui-context nil
     [:stack
      [:select
       {:text (reactive settings-appearance-title model-source)
        :label "Theme"
        :on-press (fn [_event] (send model/OpenSettingsAppearanceMenu))}]
      [:if {:test (reactive :settings-appearance-menu-open model-source)}
       [:dropdown-menu
        {:anchor "below"
         :anchor-alignment "end"
         :min-width 160
         :on-dismiss (fn [_event] (send model/CloseSettingsAppearanceMenu))}
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "system")))}
         "System"]
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "light")))}
         "Light"]
        [:menu-item
         {:on-press (fn [_event] (send (model/ChangeAppearance "dark")))}
         "Dark"]]]])))

(defn settings-community-link-title [link]
  (:title link))

(defn settings-community-link-identifier [link]
  (str "link.settings.community." (:id link)))

(defn settings-community-link-needs-separator? [current link]
  (match (last (:community-links current))
    (Some final-link) (not (= (:id link) (:id final-link)))
    None false))

(defn settings-community-link-row [ui-context model-source link-source send]
  (let [link (signal/sample link-source)]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:column {:gap 12}
        [:list-item
         {:text (reactive settings-community-link-title link-source)
          :icon "app:open-external"
          :padding 0
          :accessibility-identifier
          (settings-community-link-identifier link)
          :on-press
          (event [current-link link-source]
                 (send (model/OpenExternalURL (:url current-link))))}]
        [:if
         {:test
          (reactive settings-community-link-needs-separator?
                    model-source link-source)}
         [:separator]]])
      (elements/element
       ui-context nil
       [:column {:gap 12}
        [:list-item
         {:text (reactive settings-community-link-title link-source)
          :padding 0
          :accessibility-identifier
          (settings-community-link-identifier link)
          :on-press
          (event [current-link link-source]
                 (send (model/OpenExternalURL (:url current-link))))}]
        [:if
         {:test
          (reactive settings-community-link-needs-separator?
                    model-source link-source)}
         [:separator]]]))))

(defn settings-tabs-visible? [current]
  (:settings-tabs-open current))

(defn settings-tab-title [tab]
  (cond
    (= tab "journals") "Journals"
    (= tab "flashcards") "Flashcards"
    :else "Graphs"))

(defn settings-tabs-summary [current]
  (string/join " · " (map settings-tab-title (:sidebar-tabs current))))

(defn runtime-log-visible? [current]
  (:runtime-log-open current))

(defn tab-enabled? [current tab]
  (model/string-vector-contains? (:sidebar-tabs current) tab))

(defn tab-toggle-label [current tab]
  (let [title
        (cond
          (= tab "journals") "Journals"
          (= tab "flashcards") "Flashcards"
          :else "Graphs")]
    (str title (if (tab-enabled? current tab) ", on" ", off"))))

(defn tab-selection-glyph [current tab]
  (if (tab-enabled? current tab) "✓" "○"))

(defn tab-selection-icon-name [current tab]
  (if (tab-enabled? current tab) "app:selected" "app:unselected"))

(defn tab-selection-foreground [current tab]
  (if (tab-enabled? current tab) "accent" "secondary"))

(defn tab-disabled? [current tab]
  (not (tab-enabled? current tab)))

(defn tab-index [current tab]
  (let [tabs (:sidebar-tabs current)]
    (loop [index 0]
      (if (= index (count tabs))
        -1
        (if (= (nth tabs index) tab)
          index
          (recur (inc index)))))))

(defn tab-movement-visible? [current tab]
  (and (not (= tab "journals"))
       (tab-enabled? current tab)))

(defn settings-flashcards-before-graphs? [current]
  (and (tab-enabled? current "flashcards")
       (< (tab-index current "flashcards")
          (tab-index current "graphs"))))

(defn settings-flashcards-after-graphs? [current]
  (and (tab-enabled? current "flashcards")
       (> (tab-index current "flashcards")
          (tab-index current "graphs"))))

(defn settings-available-tabs-present? [current]
  (not (tab-enabled? current "flashcards")))

(defn tab-move-up-disabled? [current tab]
  (<= (tab-index current tab) 1))

(defn tab-move-down-disabled? [current tab]
  (let [index (tab-index current tab)]
    (or (< index 0)
        (>= index (dec (count (:sidebar-tabs current)))))))

(defn tab-toggle-identifier [tab]
  (str "toggle.settings.tab." tab))

(defn tab-up-identifier [tab]
  (str "button.settings.tab." tab ".up"))

(defn tab-down-identifier [tab]
  (str "button.settings.tab." tab ".down"))

(defn runtime-log-level [record]
  (:level record))

(defn runtime-log-timestamp [record]
  (:timestamp record))

(defn runtime-log-message [record]
  (:message record))

(defn runtime-log-error? [record]
  (= (:level record) "ERROR"))

(defn runtime-log-empty? [current]
  (empty? (:runtime-log-records current)))

(defn runtime-log-records [current]
  (:runtime-log-records current))

(defn runtime-log-errors-label [current]
  (if (:runtime-log-errors-only current) "All" "Errors only"))

(defn runtime-log-order-label [current]
  (if (:runtime-log-newest-first current) "Oldest first" "Newest first"))

(defn runtime-log-source-label [current]
  (if (= (:runtime-log-source current) "ui") "Core log" "UI log"))

(defn runtime-log-row [ui-context record-source]
  (elements/element
   ui-context nil
   [:column {:gap 3}
    [:row {:gap 6}
     [:if {:test (reactive runtime-log-error? record-source)}
      [:text {:value (reactive runtime-log-level record-source)
              :class "caption semibold"
              :foreground "red"}]]
     [:if {:test (reactive (fn [record] (not (runtime-log-error? record)))
                           record-source)}
      [:text {:value (reactive runtime-log-level record-source)
              :class "caption semibold"
              :foreground "secondary"}]]
     [:text {:value (reactive runtime-log-timestamp record-source)
             :class "caption"
             :foreground "secondary"}]]
    [:text {:value (reactive runtime-log-message record-source)
            :class "caption"}]
    [:separator]]))

(defn settings-tab-row [ui-context model-source tab title send]
  (let [label-source
        (reactive (fn [current] (tab-toggle-label current tab)) model-source)
        toggle-disabled-source
        (reactive (fn [_current] (model/required-sidebar-tab? tab)) model-source)
        movement-visible-source
        (reactive (fn [current] (tab-movement-visible? current tab)) model-source)
        up-disabled-source
        (reactive (fn [current] (tab-move-up-disabled? current tab)) model-source)
        down-disabled-source
        (reactive (fn [current] (tab-move-down-disabled? current tab)) model-source)
        selection-glyph-source
        (reactive (fn [current] (tab-selection-glyph current tab)) model-source)
        selection-icon-source
        (reactive (fn [current] (tab-selection-icon-name current tab)) model-source)]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:row
        {:cross "center"
         :padding 8
         :background "surface-container-low"
         :corner-radius 12
         :accessibility-identifier (str "row.settings.tab." tab)}
        [:row {:grow 1.0 :cross "center" :gap 8}
         [:button
          {:label label-source
           :icon selection-icon-source
           :icon-placement "trailing"
           :accessibility-label label-source
           :variant "ghost"
           :disabled toggle-disabled-source
           :accessibility-identifier (tab-toggle-identifier tab)
           :on-press (fn [_event] (send (model/ToggleSidebarTab tab)))}
          title]
         [:spacer]
         [:if {:test movement-visible-source}
          [:button
           {:icon "app:arrow-up"
            :size "icon"
            :disabled up-disabled-source
            :variant "ghost"
            :label "Move tab up"
            :accessibility-identifier (tab-up-identifier tab)
            :on-press
            (fn [_event] (send (model/MoveSidebarTab tab -1)))}]]
         [:if {:test movement-visible-source}
          [:button
           {:icon "app:arrow-down"
            :size "icon"
            :disabled down-disabled-source
            :variant "ghost"
            :label "Move tab down"
            :accessibility-identifier (tab-down-identifier tab)
            :on-press
            (fn [_event] (send (model/MoveSidebarTab tab 1)))}]]]])
      (elements/element
       ui-context nil
       [:list-item
        {:accessibility-identifier (str "row.settings.tab." tab)}
        [:row {:grow 1.0 :cross "center" :gap 8}
         [:button
          {:label label-source
           :grow 1.0
           :variant "ghost"
           :disabled toggle-disabled-source
           :accessibility-identifier (tab-toggle-identifier tab)
           :on-press (fn [_event] (send (model/ToggleSidebarTab tab)))}
          title]
         [:text {:value selection-glyph-source :foreground "accent"}]
         [:if {:test movement-visible-source}
          [:button
           {:disabled up-disabled-source
            :variant "ghost"
            :label "Move tab up"
            :accessibility-identifier (tab-up-identifier tab)
            :on-press
            (fn [_event] (send (model/MoveSidebarTab tab -1)))}
           "↑"]]
         [:if {:test movement-visible-source}
          [:button
           {:disabled down-disabled-source
            :variant "ghost"
            :label "Move tab down"
            :accessibility-identifier (tab-down-identifier tab)
            :on-press
            (fn [_event] (send (model/MoveSidebarTab tab 1)))}
           "↓"]]]]))))

(defui settings-tabs-screen [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:column
      {:grow 1.0
       :cross "stretch"
       :gap 10
       :padding 16
       :accessibility-identifier "screen.settings.tabs"}
      [:text {:class "headline" :foreground "muted-foreground"}
       "Visible tabs"]
      [:list
       {:grow 1.0
        :gap 8
        :accessibility-identifier "list.settings.tabs"}
       [settings-tab-row model-source "journals" "Journals" send]
       [:if {:test (reactive settings-flashcards-before-graphs? model-source)}
        [settings-tab-row model-source "flashcards" "Flashcards" send]]
       [settings-tab-row model-source "graphs" "Graphs" send]
       [:if {:test (reactive settings-flashcards-after-graphs? model-source)}
        [settings-tab-row model-source "flashcards" "Flashcards" send]]
       [:text
        {:class "footnote" :foreground "muted-foreground"}
        "Journals and Graphs are always available. Use the arrows to reorder tabs."]
       [:if {:test (reactive settings-available-tabs-present? model-source)}
        [:text
         {:class "headline"
          :foreground "muted-foreground"
          :accessibility-identifier "text.settings.tabs.available"}
         "Available tabs"]]
       [:if {:test (reactive settings-available-tabs-present? model-source)}
        [settings-tab-row model-source "flashcards" "Flashcards" send]]]])
    (elements/element
     ui-context nil
     [:list {:accessibility-identifier "screen.settings.tabs"}
      [:heading "Visible tabs"]
      [settings-tab-row model-source "journals" "Journals" send]
      [:if {:test (reactive settings-flashcards-before-graphs? model-source)}
       [settings-tab-row model-source "flashcards" "Flashcards" send]]
      [settings-tab-row model-source "graphs" "Graphs" send]
      [:if {:test (reactive settings-flashcards-after-graphs? model-source)}
       [settings-tab-row model-source "flashcards" "Flashcards" send]]
      [:text
       {:class "footnote" :foreground "muted-foreground"}
       "Journals and Graphs are always available. Use the arrows to reorder tabs."]
      [:if {:test (reactive settings-available-tabs-present? model-source)}
       [:heading
        {:accessibility-identifier "text.settings.tabs.available"}
        "Available tabs"]]
      [:if {:test (reactive settings-available-tabs-present? model-source)}
       [settings-tab-row model-source "flashcards" "Flashcards" send]]])))

(defui runtime-log-toolbar [model-source send]
  (if (host? proto/FlutterHost)
     (elements/element
      ui-context nil
      [:column {:gap 8 :cross "stretch"}
       [:toolbar
        {:orientation "horizontal"
         :gap 8
         :label "Log filters"
         :accessibility-identifier "toolbar.log-filters.primary"}
        [:button
         {:text (reactive runtime-log-errors-label model-source)
          :label "Toggle error filtering"
          :variant "secondary"
          :accessibility-identifier "button.log-errors"
          :on-press (fn [_event] (send model/ToggleRuntimeLogErrors))}
         "Errors only"]
        [:button
         {:text (reactive runtime-log-order-label model-source)
          :label "Toggle log ordering"
          :variant "secondary"
          :accessibility-identifier "button.log-order"
          :on-press (fn [_event] (send model/ToggleRuntimeLogOrder))}
         "Newest first"]]
       [:toolbar
        {:orientation "horizontal"
         :gap 8
         :label "Log actions"
         :accessibility-identifier "toolbar.log-filters.secondary"}
        [:button
         {:text (reactive runtime-log-source-label model-source)
          :label "Toggle log source"
          :variant "secondary"
          :accessibility-identifier "button.log-source"
          :on-press (fn [_event] (send model/ToggleRuntimeLogSource))}
         "Core log"]
        [:button
         {:variant "secondary"
          :accessibility-identifier "button.log-copy"
          :on-press (fn [_event] (send model/CopyRuntimeLog))}
         "Copy"]]])
     (elements/element
      ui-context nil
      [:toolbar
       {:orientation "horizontal"
        :class "scroll"
        :gap 8
        :label "Log filters"}
       [:button
        {:text (reactive runtime-log-errors-label model-source)
         :label "Toggle error filtering"
         :variant "secondary"
         :accessibility-identifier "button.log-errors"
         :on-press (fn [_event] (send model/ToggleRuntimeLogErrors))}
        "Errors only"]
       [:button
        {:text (reactive runtime-log-order-label model-source)
         :label "Toggle log ordering"
         :variant "secondary"
         :accessibility-identifier "button.log-order"
         :on-press (fn [_event] (send model/ToggleRuntimeLogOrder))}
        "Newest first"]
       [:button
        {:text (reactive runtime-log-source-label model-source)
         :label "Toggle log source"
         :variant "secondary"
         :accessibility-identifier "button.log-source"
         :on-press (fn [_event] (send model/ToggleRuntimeLogSource))}
        "Core log"]
       [:button
        {:variant "secondary"
         :accessibility-identifier "button.log-copy"
         :on-press (fn [_event] (send model/CopyRuntimeLog))}
        "Copy"]])))

(defui runtime-log-screen [model-source send]
  [:column {:gap 12
            :padding 16
            :grow 1.0
            :accessibility-identifier "screen.runtime-log"
            :background "background"}
   [runtime-log-toolbar model-source send]
   [:scroll {:grow 1.0}
    [:column {:gap 10}
     [:if {:test (reactive runtime-log-empty? model-source)}
      [:text {:foreground "secondary"} "No log entries"]]
     [:keyed
      {:source (reactive runtime-log-records model-source)
       :key :id
       :compare compare
       :as record-source}
      [runtime-log-row record-source]]]]])

(defn settings-toggle-spell-check [send input-event]
  (match input-event
    (proto/ToggleChanged _node enabled)
    (send (model/ToggleSpellCheck enabled))
    _ true))

(defn settings-toggle-auto-correction [send input-event]
  (match input-event
    (proto/ToggleChanged _node enabled)
    (send (model/ToggleAutoCorrection enabled))
    _ true))

(defui settings-general-card [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:column
      {:gap 12
       :cross "stretch"
       :padding 16
       :background "surface-container-low"
       :corner-radius 14
       :accessibility-identifier "layout.settings.general-card"}
      [settings-appearance-control model-source send]
      [:separator]
      [settings-language-control model-source send]
      [:separator]
      [:list-item
       {:padding 0
        :accessibility-identifier "link.settings.tabs"
        :on-press (fn [_event] (send model/OpenSettingsTabs))}
       [:row {:grow 1.0 :cross "center" :gap 12}
        [:column
         {:grow 1.0
          :gap 2
          :accessibility-identifier "layout.settings.tabs-copy"}
         [:text "Tabs"]
         [:text
          {:value (reactive settings-tabs-summary model-source)
           :class "footnote"
           :foreground "muted-foreground"
           :accessibility-identifier "text.settings.tabs.selection"}]]
        [:icon
         {:name "app:chevron-right"
          :width 20
          :height 20
          :foreground "muted-foreground"
          :accessibility-identifier "icon.settings.tabs"
          :accessibility-label "Open Tabs"}]]]])
    (elements/element
     ui-context nil
     [:column
      {:gap 12
       :padding 16
       :background "surface"
       :corner-radius 14
       :accessibility-identifier "layout.settings.general-card"}
      [:row {:cross "center"}
       [:text "Theme"]
       [:spacer]
       [settings-appearance-control model-source send]]
      [:separator]
      [:row {:cross "center"}
       [:text "Language"]
       [:spacer]
       [settings-language-control model-source send]]
      [:separator]
      [:list-item
       {:padding 0
        :accessibility-identifier "link.settings.tabs"
        :on-press (fn [_event] (send model/OpenSettingsTabs))}
       [:row {:grow 1.0 :cross "center"}
        [:text "Tabs"]
        [:spacer]
        [:text
         {:value (reactive settings-tabs-summary model-source)
          :class "single-line"
          :foreground "secondary"
          :accessibility-identifier "text.settings.tabs.selection"}]]]])))

(defn settings-editor-card
  [ui-context spell-check-source auto-correction-source send]
  (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:column
        {:gap 0
         :cross "stretch"
         :padding 16
         :background "surface-container-low"
         :corner-radius 14}
        [:switch
         {:checked spell-check-source
          :accessibility-identifier "switch.settings.spell-check"
          :on-toggle (fn [input-event]
                       (settings-toggle-spell-check send input-event))}
         "Spell check"]
        [:separator]
        [:switch
         {:checked auto-correction-source
          :accessibility-identifier "switch.settings.auto-correction"
          :on-toggle (fn [input-event]
                       (settings-toggle-auto-correction send input-event))}
         "Auto-correction"]])
    (elements/element
     ui-context nil
     [:column
      {:gap 12 :padding 16 :background "surface" :corner-radius 14}
      [:toggle
       {:checked spell-check-source
        :on-toggle (fn [input-event]
                     (settings-toggle-spell-check send input-event))}
       "Spell check"]
      [:separator]
      [:toggle
       {:checked auto-correction-source
        :on-toggle (fn [input-event]
                     (settings-toggle-auto-correction send input-event))}
      "Auto-correction"]])))

(defn settings-export-row [ui-context send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:list-item
      {:icon "app:download"
       :padding 0
       :accessibility-identifier "button.export-graph-database"
       :on-press (fn [_event] (send model/ExportGraphDatabase))}
      "Export Graph SQLite DB"])
    (elements/element
     ui-context nil
     [:list-item
      {:padding 0
       :accessibility-identifier "button.export-graph-database"
       :on-press (fn [_event] (send model/ExportGraphDatabase))}
      "Export Graph SQLite DB"])))

(defn settings-runtime-log-row [ui-context send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:list-item
      {:icon "app:terminal"
       :padding 0
       :accessibility-identifier "button.runtime-log"
       :on-press (fn [_event] (send model/OpenRuntimeLog))}
      "Check log"])
    (elements/element
     ui-context nil
     [:list-item
      {:padding 0
       :accessibility-identifier "button.runtime-log"
       :on-press (fn [_event] (send model/OpenRuntimeLog))}
      "Check log"])))

(defn settings-sign-out-row [ui-context send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:list-item
      {:icon "app:sign-out"
       :padding 0
       :accessibility-identifier "button.sign-out"
       :on-press (fn [_event] (send model/SignOut))}
      "Sign Out"])
    (elements/element
     ui-context nil
     [:list-item
      {:padding 0
       :accessibility-identifier "button.sign-out"
       :on-press (fn [_event] (send model/SignOut))}
      "Sign Out"])))

(defui settings-screen [model-source send]
  [:column
   {:gap 18
    :padding 20
    :background "background"
    :accessibility-identifier "screen.settings"}
   [:column {:gap 8}
    [:text
     {:class "headline"
      :foreground "muted-foreground"
      :accessibility-identifier "label.settings.general"}
     "General"]
    [settings-general-card model-source send]]
   [:column {:gap 8}
    [:text
     {:class "headline"
      :foreground "muted-foreground"
      :accessibility-identifier "label.settings.editor"}
     "Editor"]
    [settings-editor-card
     (reactive settings-spell-check model-source)
     (reactive settings-auto-correction model-source)
     send]]
   [:column {:gap 8}
    [:text
     {:class "headline"
      :foreground "muted-foreground"
      :accessibility-identifier "label.settings.sync-server"}
     "Sync server"]
    [:column
     {:gap 8
      :padding 16
      :background (if (host? proto/FlutterHost)
                    "surface-container-low"
                    "surface")
      :corner-radius 14}
     [:text-field
      {:text (reactive settings-base-url model-source)
       :placeholder "Server URL"
       :label "Server URL"
       :accessibility-identifier "field.base-url"
       :on-input
       (fn [input-event]
         (match input-event
           (TextChanged _node text) (send (model/ChangeBaseURL text))
           _ true))}]
     [:if {:test (reactive settings-base-url-invalid? model-source)}
      [:text {:foreground "destructive"}
       "Enter a valid HTTP or HTTPS URL."]]]]
   [:if {:test (reactive selected-graph-local? model-source)}
    [:column {:gap 8}
     [:text
      {:class "headline"
       :foreground "muted-foreground"
       :accessibility-identifier "label.settings.advanced"}
     "Advanced"]
     [:column
      {:padding 16
       :background (if (host? proto/FlutterHost)
                     "surface-container-low"
                     "surface")
       :corner-radius 14}
      [settings-export-row send]]]]
   [:column {:gap 8}
    [:text
     {:class "headline"
      :foreground "muted-foreground"
      :accessibility-identifier "label.settings.about"}
     "About"]
    [:column
     {:gap 12
      :padding 16
      :background (if (host? proto/FlutterHost)
                    "surface-container-low"
                    "surface")
      :corner-radius 14}
     [:row
      [:text "Version"]
      [:spacer]
      [:text {:value (reactive settings-version model-source)
              :foreground "secondary"}]]
     [:separator]
     [:row
      [:text "Revision"]
      [:spacer]
     [:text {:value (reactive settings-revision model-source)
              :foreground "secondary"}]]
     [:separator]
     [settings-runtime-log-row send]]]
   [:column {:gap 8}
    [:text
     {:class "headline"
      :foreground "muted-foreground"
      :accessibility-identifier "label.settings.community"}
     "Community"]
    [:column
     {:gap 12
      :background (if (host? proto/FlutterHost)
                    "surface-container-low"
                    "surface")
      :corner-radius 14
      :padding 16}
     [:keyed
      {:source (reactive :community-links model-source)
       :key :id
       :compare compare
       :as link-source}
      [settings-community-link-row model-source link-source send]]]]
   [:column
    {:padding 16
     :background (if (host? proto/FlutterHost)
                   "surface-container-low"
                   "surface")
     :corner-radius 14}
    [settings-sign-out-row send]]])

(defui settings-main-sheet [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:sheet
      {:text "Settings"
       :height 640
       :accessibility-identifier "sheet.settings"
       :on-dismiss (fn [_event] (send model/DismissSettings))}
      [:column
       {:grow 1.0
        :gap 12
        :accessibility-identifier "layout.settings.sheet"}
       [:scroll {:grow 1.0}
        [settings-screen model-source send]]
       [:row
        {:gap 12
         :padding-horizontal 20
         :padding-vertical 12
         :background "surface-container-low"
         :accessibility-identifier "toolbar.settings.actions"}
        [:button
         {:variant "secondary"
          :grow 1.0
          :accessibility-identifier "button.connection.cancel"
          :on-press (fn [_event] (send model/DismissSettings))}
         "Cancel"]
        [:button
         {:variant "primary"
          :grow 1.0
          :accessibility-identifier "button.connection.apply"
          :disabled (reactive settings-apply-disabled? model-source)
          :on-press (fn [_event] (send model/ApplySettings))}
         "Apply"]]]])
    (elements/element
     ui-context nil
     [:sheet
      {:text "Settings"
       :class "navigation-scroll"
       :accessibility-identifier "sheet.settings"
       :on-dismiss (fn [_event] (send model/DismissSettings))}
      [settings-screen model-source send]
      [:if {:test (reactive settings-tabs-visible? model-source)}
       [settings-tabs-sheet model-source send]]
      [:if {:test (reactive runtime-log-visible? model-source)}
       [runtime-log-sheet model-source send]]
      [:toolbar
       {:orientation "horizontal"
        :label "Settings actions"
        :class "navigation-actions"
        :accessibility-identifier "toolbar.settings.actions"}
       [:button
        {:class "cancellation-action"
         :accessibility-identifier "button.connection.cancel"
         :on-press (fn [_event] (send model/DismissSettings))}
        "Cancel"]
       [:button
        {:class "confirmation-action"
         :accessibility-identifier "button.connection.apply"
         :disabled (reactive settings-apply-disabled? model-source)
         :on-press (fn [_event] (send model/ApplySettings))}
        "Apply"]]])))

(defui settings-tabs-sheet [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:sheet
      {:text "Tabs"
       :class "navigation-content"
       :accessibility-identifier "sheet.settings"
       :on-dismiss (fn [_event] (send model/BackSettings))}
      [:column
       {:grow 1.0
        :accessibility-identifier "layout.settings.tabs-sheet"}
       [settings-tabs-screen model-source send]
       [:row
        {:padding-horizontal 16
         :padding-vertical 12
         :background "surface-container-low"
         :accessibility-identifier "toolbar.settings.actions"}
        [:button
         {:variant "secondary"
          :grow 1.0
          :accessibility-identifier "button.connection.cancel"
          :on-press (fn [_event] (send model/BackSettings))}
         "Back to Settings"]]]])
    (elements/element
     ui-context nil
     [:sheet
      {:text "Tabs"
       :class "navigation-list"
       :accessibility-identifier "sheet.settings.tabs"
       :on-dismiss (fn [_event] (send model/BackSettings))}
      [settings-tabs-screen model-source send]
      [:toolbar
       {:orientation "horizontal"
        :label "Tabs actions"
        :class "navigation-actions"
        :accessibility-identifier "toolbar.settings.actions"}
       [:button
        {:class "cancellation-action navigation-back-action"
         :accessibility-identifier "button.connection.cancel"
         :on-press (fn [_event] (send model/BackSettings))}
        "Settings"]]])))

(defn runtime-log-actions [ui-context send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:row
      {:gap 12
       :padding-horizontal 16
       :padding-vertical 12
       :background "surface-container-low"
       :accessibility-identifier "toolbar.settings.actions"}
      [:button
       {:variant "secondary"
        :grow 1.0
        :accessibility-identifier "button.log-refresh"
        :on-press (fn [_event] (send model/RefreshRuntimeLog))}
       "Refresh"]
      [:button
       {:variant "primary"
        :grow 1.0
        :accessibility-identifier "button.connection.apply"
        :on-press (fn [_event] (send model/DismissRuntimeLog))}
       "Done"]])
    (elements/element
     ui-context nil
     [:toolbar
      {:orientation "horizontal"
       :label "Log actions"
       :class "navigation-actions"
       :accessibility-identifier "toolbar.settings.actions"}
      [:button
       {:class "cancellation-action"
        :accessibility-identifier "button.log-refresh"
        :on-press (fn [_event] (send model/RefreshRuntimeLog))}
       "Refresh"]
      [:button
       {:class "confirmation-action"
        :accessibility-identifier "button.connection.apply"
        :on-press (fn [_event] (send model/DismissRuntimeLog))}
       "Done"]])))

(defui runtime-log-sheet [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:sheet
      {:text "Log"
       :class "navigation-content"
       :accessibility-identifier "sheet.settings"
       :on-dismiss (fn [_event] (send model/DismissRuntimeLog))}
      [:column
       {:grow 1.0
       :gap 12
        :accessibility-identifier "layout.runtime-log.sheet"}
       [runtime-log-screen model-source send]
       [runtime-log-actions send]]])
    (elements/element
     ui-context nil
     [:sheet
      {:text "Log"
       :class "navigation-content"
       :accessibility-identifier "sheet.settings.log"
       :on-dismiss (fn [_event] (send model/DismissRuntimeLog))}
      [runtime-log-screen model-source send]
      [runtime-log-actions send]])))

(defui settings-sheet [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element ui-context nil
     [:stack
      [:if {:test (reactive settings-main-visible? model-source)}
       [settings-main-sheet model-source send]]
      [:if {:test (reactive settings-tabs-visible? model-source)}
       [settings-tabs-sheet model-source send]]
      [:if {:test (reactive runtime-log-visible? model-source)}
       [runtime-log-sheet model-source send]]])
    (settings-main-sheet ui-context model-source send)))

(defui page-delete-dialog [send]
  [:dialog
   {:text "Delete page?"
    :class "alert"
    :accessibility-identifier "dialog.page-delete"
    :on-dismiss (fn [_event] (send model/CancelDeleteActivePage))}
   [:column
    [:text "The page will be moved to Recycle."]
    [:button
     {:accessibility-identifier "button.page-delete.cancel"
      :on-press (fn [_event] (send model/CancelDeleteActivePage))}
     "Cancel"]
    [:button
     {:accessibility-identifier "button.page-delete.confirm"
      :on-press (fn [_event] (send model/ConfirmDeleteActivePage))}
     "Delete"]]])

(defn sync-error-present? [current]
  (match (:sync-state current)
    (FailedState _reason) true
    _ false))

(defn sync-error-message [current]
  (match (:sync-state current)
    (FailedState reason) reason
    _ ""))

(defui sync-status-sheet [model-source send]
  [:sheet
   {:text "Sync status"
    :class "navigation-form"
    :accessibility-identifier "sheet.sync-status"
    :on-dismiss (fn [_event] (send model/CloseSyncDetails))}
   [:column
    {:class "form"
     :accessibility-identifier "form.sync-status"}
    [:list-item {:accessibility-identifier "row.sync.status"}
     [:row {:grow 1.0 :cross "center" :main "space_between"}
      [:text "Status"]
      [:text {:value (reactive sync-label model-source)
              :foreground "secondary"
              :text-alignment "end"}]]]
    [:list-item {:accessibility-identifier "row.sync.graph"}
     [:row {:grow 1.0 :cross "center" :main "space_between"}
      [:text "Graph"]
      [:text {:value (reactive graph-label model-source)
              :foreground "secondary"
              :text-alignment "end"}]]]
    [:list-item {:accessibility-identifier "row.sync.connection"}
     [:row {:grow 1.0 :cross "center" :main "space_between"}
      [:text "Connection"]
      [:text {:value (reactive sync-connection-label model-source)
              :foreground "secondary"
              :text-alignment "end"}]]]
    [:list-item {:accessibility-identifier "row.sync.pending"}
     [:row {:grow 1.0 :cross "center" :main "space_between"}
      [:text "Local changes"]
      [:text
       {:value (reactive sync-pending-label model-source)
        :foreground "secondary"
        :text-alignment "end"
        :accessibility-identifier "sync.pending"}]]]
    [:list-item {:accessibility-identifier "row.sync.cursor"}
     [:row {:grow 1.0 :cross "center" :main "space_between"}
      [:text "Server cursor"]
      [:text
       {:value (reactive sync-cursor-label model-source)
        :foreground "secondary"
        :text-alignment "end"
        :accessibility-identifier "sync.cursor"}]]]
    [:if {:test (reactive sync-error-present? model-source)}
     [:heading {:level 5} "Last error"]]
    [:if {:test (reactive sync-error-present? model-source)}
     [:list-item
      [:text
       {:value (reactive sync-error-message model-source)
        :foreground "red"
        :accessibility-identifier "sync.error"}]]]
    [:button
     {:accessibility-identifier "button.sync-now"
      :on-press (fn [_event] (send model/SyncNow))}
     "Sync now"]]
   [:toolbar
    {:orientation "horizontal"
     :label "Sync status actions"
     :class "navigation-actions"
     :accessibility-identifier "toolbar.sync.actions"}
    [:button
     {:class "confirmation-action"
      :accessibility-identifier "button.sync.done"
      :on-press (fn [_event] (send model/CloseSyncDetails))}
     "Done"]]])

(defui search-screen [model-source send]
  [:column
   {:grow 1.0
    :accessibility-identifier "screen.search"}
   [:row {:height 24 :gap 6 :cross "center" :padding-horizontal 20}
    [:if {:test (reactive :search-loading model-source)}
     [:spinner {:width 12 :height 12 :accessibility-identifier "search.loading"}]]
    [:text {:value (reactive search-result-status model-source)
            :class "caption"
            :foreground "muted-foreground"
            :accessibility-identifier "search.status"}]]
   [:if {:test (reactive search-empty-state-present? model-source)}
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
     [:text {:value (reactive search-empty-message model-source)
             :class "headline"
             :text-alignment "center"
             :accessibility-identifier "search.empty"}]
     [:text {:value (reactive search-empty-supporting-message
                              (reactive :search-query model-source))
             :foreground "muted-foreground"
             :text-alignment "center"
             :accessibility-identifier "search.empty.supporting"}]]]
   [:if {:test (reactive search-results-present? model-source)}
    [:list {:grow 1.0
            :accessibility-identifier "screen.search.results"}
     [:if {:test (reactive page-search-results-present? model-source)}
      [:heading {:level 5
                 :accessibility-identifier "search.section.pages"}
       "Pages"]]
     [:keyed
      {:source (reactive page-search-results model-source)
       :key :uuid
       :compare compare
       :as hit-source}
      [search-result-row hit-source send]]
     [:if {:test (reactive block-search-results-present? model-source)}
      [:heading {:level 5
                 :accessibility-identifier "search.section.blocks"}
       "Blocks"]]
     [:keyed
      {:source (reactive block-search-results model-source)
       :key :uuid
       :compare compare
       :as hit-source}
      [search-result-row hit-source send]]]]])

(defui capture-and-search-row [model-source send]
  (if (= (ui/platform ui-context) proto/AndroidOS)
    (elements/element
     ui-context nil
     [:row
     {:gap 10
       :cross "center"
       :accessibility-identifier "row.bottom.capture"}
      [composer-view model-source send]
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
      [composer-view model-source send]
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

(defui main-bottom-chrome [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:stack
      [:if {:test (reactive bottom-chrome-selection? model-source)}
       [:column {:gap 0 :padding-horizontal 16}
        [outliner-selection-toolbar send]
        [:box {:height 21}]]]
      [:if {:test (reactive bottom-chrome-editor? model-source)}
       [:column
        {:gap 0
         :cross "stretch"
         :background "surface-container-low"
         :corner-radius 20
         :accessibility-identifier "container.outliner.editor-chrome"}
        [:if {:test (reactive outliner-autocomplete-active? model-source)}
         [outliner-autocomplete-bar model-source send]]
        [outliner-editor-toolbar model-source send]]]
      [:if {:test (reactive bottom-chrome-expanded-composer? model-source)}
       [:column
        {:gap 0 :padding-horizontal 16}
        [:box {:height 6}]
        [:row
         {:cross "center"
          :accessibility-identifier "row.composer.placement"}
         [composer-view model-source send]]
        [:box {:height 21}]]]
      [:if {:test (reactive bottom-chrome-capture-and-search? model-source)}
       [:column
        {:gap 0 :padding-horizontal 16}
        [:box {:height 8}]
        [capture-and-search-row model-source send]
        [:box {:height 21}]]]])
    (elements/element
     ui-context nil
     [:stack
      [:if {:test (reactive bottom-chrome-selection? model-source)}
       [:column {:gap 0 :padding-horizontal 16}
        [outliner-selection-toolbar send]
        [:box {:height 21}]]]
      [:if {:test (reactive bottom-chrome-editor? model-source)}
       [:box {:ios [[:liquid-glass {:shape "container"}]]}
        [:if {:test (reactive outliner-autocomplete-active? model-source)}
         [outliner-autocomplete-bar model-source send]]
        [outliner-editor-toolbar model-source send]]]
      [:if {:test (reactive bottom-chrome-expanded-composer? model-source)}
       [:column
        {:container-relative-frame "horizontal"
         :cross "stretch"
         :gap 0
         :padding-horizontal 16}
        [:box {:height 6}]
        [:row
         {:cross "center"
          :accessibility-identifier "row.composer.placement"}
         [composer-view model-source send]]
        [:box {:height 21}]]]
      [:if {:test (reactive bottom-chrome-capture-and-search? model-source)}
       [:column
        {:container-relative-frame "horizontal"
         :cross "stretch"
         :gap 0
         :padding-horizontal 16}
        [:box {:height 8}]
        [capture-and-search-row model-source send]
        [:box {:height 21}]]]])))

(defn selected-page-present? [current]
  (match (:selected-page current)
    (Some _page) true
    None false))

(defn selected-page-absent? [current]
  (not (selected-page-present? current)))

(defn selected-page-content-title-visible? [current]
  (and (selected-page-present? current)
       (not (:selected-page-is-tag current))
       (node-outliner-visible? current)))

(defn selected-page-title [current]
  (match (:selected-page current)
    (Some page) (:title page)
    None ""))

(defui root-outliner-view [model-source visible-source send]
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
    [:if {:test (reactive selected-page-content-title-visible? model-source)}
     [:column {:gap 0}
      [:box {:height 26}]
      [:box
       {:padding-horizontal 16
        :accessibility-identifier "layout.selected-page.title"}
       [:heading
        {:level 3
         :value (reactive selected-page-title model-source)
         :accessibility-identifier "title.selected-page"}]]
      [:box {:height 12}]]]
     [:if {:test (reactive first-journal-section-visible? model-source)}
      [outliner-first-journal-section model-source send]]
     [:keyed
      {:source (reactive remaining-retained-outliner-rows model-source)
       :key :render-key
       :compare compare
       :as retained-row-source}
      [outliner-entry model-source retained-row-source
       (reactive retained-row-value retained-row-source) send]]
     [:if {:test (reactive older-journals-visible? model-source)}
      [:box
       {:height 1
        :accessibility-identifier "outliner.load-older-sentinel"
        :on-appear
        (fn [_event] (send model/LoadOlderJournals))}]]
     [:if {:test (reactive main-can-add-first-block? model-source)}
      [:box {:padding-horizontal 8}
       [add-first-block-button model-source send]]]
     [:if {:test (reactive main-related-section-visible? model-source)}
      [:box {:padding-horizontal 8}
       [node-related-section model-source send]]]
     [:if {:test (reactive main-tag-section-visible? model-source)}
      [:box {:padding-horizontal 8}
       [node-tagged-section model-source send]]]
     [:if {:test (reactive main-linked-reference-section-visible? model-source)}
      [:box {:padding-horizontal 8}
       [node-linked-reference-section model-source send]]]
     [:box {:height 120}]]])

(defui retained-journal-pane [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:stack {:grow 1.0}
      [:if {:test (reactive journal-home-visible? model-source)}
       [:box {:grow 1.0 :accessibility-identifier "pane.journals"}
        [root-outliner-view
         (reactive journal-navigation-model model-source)
         (reactive journal-home-visible? model-source)
         send]]]])
    (elements/element
     ui-context nil
     [:box {:grow 1.0 :accessibility-identifier "pane.journals"}
      [root-outliner-view
       (reactive journal-navigation-model model-source)
       (reactive
        (fn [current]
          (journal-home-visible?
           (assoc current :node-routes [] :app-navigation-path []
                          :search-open false :search-navigation-path [])))
        model-source)
       send]])))

(defui journal-tree-panes [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:stack {:grow 1.0}
      [retained-journal-pane model-source send]
      [:keyed
       {:source (reactive selected-page-models model-source)
        :key selected-page-model-key
        :compare compare
        :as selected-model-source}
       [:box {:grow 1.0 :accessibility-identifier "pane.selected-page"}
        [root-outliner-view
         selected-model-source
         (reactive selected-page-visible? selected-model-source)
         send]]]])
    (elements/element
     ui-context nil
     [:stack {:grow 1.0}
      [:keyed
       {:source (reactive selected-page-models model-source)
        :key selected-page-model-key
        :compare compare
        :as selected-model-source}
       [:box {:grow 1.0 :accessibility-identifier "pane.selected-page"}
        [root-outliner-view
         selected-model-source
         (reactive selected-page-visible? selected-model-source)
         send]]]
      [retained-journal-pane model-source send]])))

(defui global-effect-error-feedback [model-source]
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
        {:value (reactive effect-error-message model-source)
         :grow 1.0
         :accessibility-identifier "error.banner"}]]])
    (elements/element
     ui-context nil
     [:text
      {:value (reactive effect-error-message model-source)
       :accessibility-identifier "error.banner"}])))

(defui graph-loading-feedback [model-source]
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
       {:value (reactive graph-loading-message model-source)
        :foreground "muted-foreground"}]])
    (elements/element
     ui-context nil
     [:column {:accessibility-identifier "journals.loading"}
      [:text {:value (reactive graph-loading-message model-source)}]])))

(defui chat-main-view [model-source send]
  [:stack {:grow 1.0}
   [:if {:test (reactive journal-tree-retained? model-source)}
    ;; Keep the journal home mounted while the drawer replaces the detail pane.
    [journal-tree-panes model-source send]]
   [:if {:test (reactive flashcards-destination? model-source)}
    [flashcard-screen model-source send]]
   [:if {:test (reactive graphs-destination? model-source)}
    [graphs-screen model-source send]]
   [:if {:test (reactive global-effect-error-present? model-source)}
    [global-effect-error-feedback model-source]]
   [:if {:test (reactive graph-loading-visible? model-source)}
    [graph-loading-feedback model-source]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [:text
     {:accessibility-label "Journal graph load status"
      :accessibility-identifier "journals.graph-loaded"}
     ""]]])

(defui main-header-leading [model-source send]
  [:stack
   [:if {:test (reactive
                 (fn [current]
                   (and (host? proto/FlutterHost)
                        (node-screen-visible? current)))
                 model-source)}
    [:button
     {:icon "app:navigation-back"
      :variant "ghost"
      :size "icon"
      :label "Back"
      :accessibility-identifier "button.navigation.back"
      :on-press (fn [_event] (send (model/BackAppNavigation 1)))}]]
   [:if {:test (reactive primary-sidebar-button-visible? model-source)}
    [:button
     {:icon "app:sidebar-toggle"
      :variant "ghost"
      :size "icon"
      :label "Open sidebar"
      :accessibility-identifier "button.sidebar"
      :disabled (reactive sidebar-drag-disabled? model-source)
      :on-press (fn [_event] (send model/OpenSidebar))}]]])

(defui main-header-title [model-source]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:heading
      {:value (reactive main-title model-source)
       :level 3
       :accessibility-identifier "title.main"}])
    (elements/element
     ui-context nil
     [:text
      {:value (reactive main-title model-source)
       :class "headline"
       :accessibility-identifier "title.main"}])))

(defui main-header-sync [model-source send]
  [:stack
   [:if {:test (reactive connection-control-visible? model-source)}
    [:button
     {:icon (if (host? proto/FlutterHost)
              (reactive (fn [_current] "app:sync-status") model-source)
              (reactive (fn [_current] "app:status-dot") model-source))
      :variant "ghost"
      :size "icon"
      :foreground-signal (reactive sync-indicator-foreground model-source)
      :label (reactive sync-indicator-label model-source)
      :accessibility-identifier-signal
      (reactive sync-accessibility-identifier model-source)
      :on-press (fn [_event] (send model/OpenSyncDetails))}]]])

(defui active-overflow-menu [model-source send]
  (let [node (ui/extension! ui-context "native-overflow-menu")
        page-actions-source
        (reactive active-page-actions-visible? model-source)
        favorite-label-source
        (reactive active-page-favorite-label model-source)
        settings-source
        (reactive connection-settings-visible? model-source)
        page-actions-value-source
        (reactive bool-wire-value page-actions-source)
        favorite-label-value-source
        (reactive string-wire-value favorite-label-source)
        settings-value-source
        (reactive bool-wire-value settings-source)]
    (ui/extension-property-signal!
     ui-context node "page-actions-visible" page-actions-value-source)
    (ui/extension-property-signal!
     ui-context node "favorite-label" favorite-label-value-source)
    (ui/extension-property-signal!
     ui-context node "settings-visible" settings-value-source)
    (ui/on-event!
     ui-context node
     (fn [input-event]
       (handle-native-overflow-menu-event input-event send)))
    node))

(defui main-header-connection [model-source send]
  [:stack
   [:if {:test (reactive connection-control-visible? model-source)}
    [active-overflow-menu model-source send]]])

(defn journal-navigation-model [current]
  (let [rows (:journal-outliner-rows current)
        root
        (assoc current
               :destination model/JournalsDestination
               :selected-page None
               :selected-page-is-tag false
               :selected-page-is-property false
               :related-rows []
               :linked-reference-rows []
               :node-routes []
               :app-navigation-path []
               :search-open false
               :search-navigation-path []
               :outliner-rows rows
               :outliner-section-markers (model/journal-section-markers rows))]
    (if (empty? (:node-routes current))
      root
      (assoc root
             :outliner-selected-block-ids []
             :outliner-editing None
             :outliner-autocomplete None
             :outliner-autocomplete-candidates []))))

(defn node-route-model [current route]
  (assoc current
         :node-routes [route]
         :outliner-rows (:outliner-rows route)
         :outliner-section-markers []
         :outliner-selected-block-ids (:outliner-selected-block-ids route)
         :outliner-editing (:outliner-editing route)
         :outliner-autocomplete (:outliner-autocomplete route)
         :outliner-autocomplete-candidates
         (:outliner-autocomplete-candidates route)))

(defn app-navigation-depth [current]
  (navigation-path-depth (:app-navigation-path current)))

(defn search-navigation-depth [current]
  (navigation-path-depth (:search-navigation-path current)))

(defn search-node-routes [current]
  (if (= (:search-open current) false)
    []
    (let [routes (:node-routes current)
          start (min (app-navigation-depth current) (count routes))]
      (loop [index start
             result []]
        (if (= index (count routes))
          result
          (recur (inc index) (conj result (nth routes index))))))))

(defn active-route-only [routes]
  (if (empty? routes) [] [(last routes)]))

(defn active-app-node-routes [current]
  (active-route-only (model/app-node-routes current)))

(defn active-search-node-routes [current]
  (active-route-only (search-node-routes current)))

(defn flutter-app-root-visible? [current]
  (and (= (:search-open current) false)
       (empty? (active-app-node-routes current))))

(defn flutter-search-root-visible? [current]
  (and (:search-open current)
       (empty? (active-search-node-routes current))))

(defui native-node-screen [model-source route-source send]
  (let [route-model-source
        (reactive node-route-model model-source route-source)]
    (if (host? proto/FlutterHost)
      (elements/element
       ui-context nil
       [:box {:grow 1.0 :background "background"}
        [node-screen route-model-source send]])
      (elements/element
       ui-context nil
       [node-screen route-model-source send]))))

(defui native-search-view [model-source send]
  (let [node (ui/extension! ui-context "native-search-presentation")
        presented-source (reactive :search-open model-source)
        depth-source (reactive search-navigation-depth model-source)
        query-source (reactive :search-query model-source)
        presented-value-source (reactive bool-wire-value presented-source)
        depth-value-source (reactive int-wire-value depth-source)
        query-value-source (reactive string-wire-value query-source)]
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
       (handle-native-search-event input-event send)))
    (if (host? proto/FlutterHost)
      (do
        (elements/element
         ui-context node
         [:stack {:grow 1.0}
          [:if {:test (reactive flutter-app-root-visible? model-source)}
           [chat-main-view model-source send]]
          [:keyed
           {:source (reactive active-app-node-routes model-source)
            :key :uuid
            :compare compare
            :as route-source}
           [native-node-screen model-source route-source send]]
          [:if {:test (reactive flutter-search-root-visible? model-source)}
           [:column {:grow 1.0 :background "background"}
            [search-screen model-source send]]]
          [:keyed
           {:source (reactive active-search-node-routes model-source)
            :key :uuid
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
          {:source (reactive search-node-routes model-source)
           :key :uuid
           :compare compare
           :as route-source}
          [native-node-screen model-source route-source send]])
        node))
    node))

(defui native-navigation-view [model-source send]
  (let [node (ui/extension! ui-context "native-navigation-stack")
        depth-source (reactive app-navigation-depth model-source)
        depth-value-source (reactive int-wire-value depth-source)
        bottom-occupies-source
        (reactive bottom-chrome-occupies-layout-space? model-source)
        bottom-occupies-value-source
        (reactive bool-wire-value bottom-occupies-source)
        composer-dismissal-source
        (reactive bottom-chrome-expanded-composer? model-source)
        composer-dismissal-value-source
        (reactive bool-wire-value composer-dismissal-source)
        title-source (reactive main-title model-source)
        title-value-source (reactive string-wire-value title-source)]
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
       (handle-native-navigation-event input-event send)))
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
           :key :uuid
           :compare compare
           :as route-source}
          [native-node-screen model-source route-source send]])
        node))
    node))

(defn authentication-screen-visible? [current]
  (or (= (:authentication-state current) "signedOut")
      (= (:authentication-state current) "signingIn")))

(defn graph-picker-screen-visible? [current]
  (and (graph-picker-visible? current)
       (not (authentication-screen-visible? current))))

(defn authentication-signing-in? [current]
  (= (:authentication-state current) "signingIn"))

(defn authentication-error-present? [current]
  (match (:authentication-error current)
    (Some message) (not (empty? message))
    None false))

(defn authentication-error-message [current]
  (match (:authentication-error current)
    (Some message) message
    None ""))

(defn graph-picker-hidden? [current]
  (not (graph-picker-visible? current)))

(defn main-screen-visible? [current]
  (and (graph-picker-hidden? current)
       (not (authentication-screen-visible? current))))

(defn application-shell-visible? [current]
  (not (authentication-screen-visible? current)))

(defn drawer-selected? [current]
  (and (:sidebar-open current)
       (graph-picker-hidden? current)
       (not (authentication-screen-visible? current))))

(defn drawer-disabled? [current]
  (or (graph-picker-visible? current)
      (authentication-screen-visible? current)
      (sidebar-drag-disabled? current)))

(defui authentication-screen [model-source send]
  (if (host? proto/FlutterHost)
    (elements/element
     ui-context nil
     [:column
      {:accessibility-identifier "screen.authentication"
       :grow 1.0
       :main "center"
       :cross "stretch"
       :padding 32}
      [:column
       {:cross "center"
        :gap 20}
       [:heading {:level 1} "Logseq Chat"]
       [:text "Sign in to connect your sync graphs."]
       [:button
        {:accessibility-identifier "button.hosted-sign-in"
         :variant "primary"
         :disabled (reactive authentication-signing-in? model-source)
         :on-press (fn [_event] (send model/SignIn))}
        "Sign in"]
       [:if {:test (reactive authentication-error-present? model-source)}
        [:text
         {:value (reactive authentication-error-message model-source)
          :accessibility-identifier "text.authentication-error"}]]]])
    (elements/element
     ui-context nil
     [:column
      {:accessibility-identifier "screen.authentication"
       :grow 1.0
       :container-relative-frame "vertical"
       :main "center"
       :cross "center"
       :gap 20
       :padding 32}
      [:heading {:level 1} "Logseq Chat"]
      [:text "Sign in to connect your sync graphs."]
      [:button
       {:accessibility-identifier "button.hosted-sign-in"
        :variant "primary"
        :disabled (reactive authentication-signing-in? model-source)
        :on-press (fn [_event] (send model/SignIn))}
       "Sign in"]
      [:if {:test (reactive authentication-error-present? model-source)}
       [:text
        {:value (reactive authentication-error-message model-source)
         :accessibility-identifier "text.authentication-error"}]]])))

(defui application-main-content [model-source send]
  (if (= (ui/platform ui-context) proto/AndroidOS)
    (if (host? proto/FlutterHost)
      (elements/element
       ui-context nil
       [:stack
        {:grow 1.0}
        [:if {:test (reactive main-screen-visible? model-source)}
         [native-navigation-view model-source send]]
        [:if {:test (reactive graph-picker-screen-visible? model-source)}
         [graph-picker-screen model-source send]]
        [:if {:test (reactive :settings-open model-source)}
         [settings-sheet model-source send]]
        [:if {:test (reactive :create-graph-open model-source)}
         [graph-create-sheet model-source send]]
        [:if {:test (reactive graph-deletion-pending? model-source)}
         [graph-delete-dialog model-source send]]
        [:if {:test (reactive :graph-password-open model-source)}
         [graph-password-sheet model-source send]]
        [:if {:test (reactive page-deletion-pending? model-source)}
         [page-delete-dialog send]]
        [:if {:test (reactive :sync-details-open model-source)}
         [sync-status-sheet model-source send]]])
      (elements/element
       ui-context nil
       [:stack
        {:grow 1.0
         :container-relative-frame "vertical"}
        [:if {:test (reactive main-screen-visible? model-source)}
         [native-navigation-view model-source send]]
        [:if {:test (reactive graph-picker-screen-visible? model-source)}
         [graph-picker-screen model-source send]]
        [:if {:test (reactive :settings-open model-source)}
         [settings-sheet model-source send]]
        [:if {:test (reactive :create-graph-open model-source)}
         [graph-create-sheet model-source send]]
        [:if {:test (reactive graph-deletion-pending? model-source)}
         [graph-delete-dialog model-source send]]
        [:if {:test (reactive :graph-password-open model-source)}
         [graph-password-sheet model-source send]]
        [:if {:test (reactive page-deletion-pending? model-source)}
         [page-delete-dialog send]]
        [:if {:test (reactive :sync-details-open model-source)}
         [sync-status-sheet model-source send]]]))
    (elements/element
     ui-context nil
     [:stack
      [:if {:test (reactive main-screen-visible? model-source)}
       [native-navigation-view model-source send]]
      [:if {:test (reactive graph-picker-screen-visible? model-source)}
       [graph-picker-screen model-source send]]
      [:if {:test (reactive authentication-screen-visible? model-source)}
       [authentication-screen model-source send]]
      [:if {:test (reactive :settings-open model-source)}
       [settings-sheet model-source send]]
      [:if {:test (reactive :create-graph-open model-source)}
       [graph-create-sheet model-source send]]
      [:if {:test (reactive graph-deletion-pending? model-source)}
       [graph-delete-dialog model-source send]]
      [:if {:test (reactive :graph-password-open model-source)}
       [graph-password-sheet model-source send]]
      [:if {:test (reactive page-deletion-pending? model-source)}
       [page-delete-dialog send]]
      [:if {:test (reactive :sync-details-open model-source)}
       [sync-status-sheet model-source send]]])))

(defui chat-view [model-source send]
  (if (= (ui/platform ui-context) proto/AndroidOS)
    (if (host? proto/FlutterHost)
      (elements/element
       ui-context nil
       [:stack
        {:grow 1.0}
        [:if {:test (reactive authentication-screen-visible? model-source)}
         [authentication-screen model-source send]]
        [:if {:test (reactive application-shell-visible? model-source)}
         [:drawer
          {:selected (reactive drawer-selected? model-source)
           :disabled (reactive drawer-disabled? model-source)
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
          [sidebar-view model-source send]]]])
      (elements/element
       ui-context nil
       [:stack
        {:grow 1.0
         :container-relative-frame "both"}
        [:if {:test (reactive authentication-screen-visible? model-source)}
         [authentication-screen model-source send]]
        [:if {:test (reactive application-shell-visible? model-source)}
         [:drawer
          {:selected (reactive drawer-selected? model-source)
           :disabled (reactive drawer-disabled? model-source)
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
          [sidebar-view model-source send]]]]))
    (elements/element
     ui-context nil
     [:drawer
      {:selected (reactive drawer-selected? model-source)
       :disabled (reactive drawer-disabled? model-source)
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
      [sidebar-view model-source send]])))
