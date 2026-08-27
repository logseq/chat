(ns logseq-chat.view
  (:require [clojure.string :as string]
            [lui.elements :as elements]
            [lui.extension :as ext]
            [lui.macros :refer [defui reactive event]]
            [lui.protocol :as proto :refer [TextChanged]]
            [lui.ui :as ui]
            [logseq-chat.model :as model]
            [signal.core :as signal]))

(defn outliner-editor-schema []
  (ext/component
   "outliner-editor"
   [(proto/profile proto/MacOS proto/SwiftUIHost)
    (proto/profile proto/IOS proto/SwiftUIHost)
    (proto/profile proto/AndroidOS proto/SwiftUIHost)]
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
    (proto/profile proto/AndroidOS proto/SwiftUIHost)]
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
     "open-node"
     [(ext/event-field "uuid" ext/StringScalar true)])]))

(defn native-navigation-stack-schema []
  (ext/component
   "native-navigation-stack"
   [(proto/profile proto/MacOS proto/SwiftUIHost)
    (proto/profile proto/IOS proto/SwiftUIHost)
    (proto/profile proto/AndroidOS proto/SwiftUIHost)]
   true []
   [(ext/property "depth" ext/IntScalar true None)]
   [(ext/event "back" [(ext/event-field "count" ext/IntScalar true)])]))

(defn extension-registry []
  (let [registry (ext/registry)]
    (ext/register-component! registry (outliner-editor-schema))
    (ext/register-component! registry (outliner-block-content-schema))
    (ext/register-component! registry (native-navigation-stack-schema))
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

(defn send-navigation-back [search-count app-count requested send]
  (let [search-pops (min requested search-count)
        app-pops (min (- requested search-pops) app-count)]
    (loop [remaining search-pops]
      (if (> remaining 0)
        (do
          (send model/BackSearchNavigation)
          (recur (dec remaining)))
        true))
    (loop [remaining app-pops]
      (if (> remaining 0)
        (do
          (send model/BackAppNavigation)
          (recur (dec remaining)))
        true))))

(defn handle-native-navigation-event [input-event model-source send]
  (match input-event
    (proto/ExtensionEvent _node _identifier "back" values)
    (let [current (signal/sample model-source)]
      (send-navigation-back
       (navigation-path-depth (:search-navigation-path current))
       (navigation-path-depth (:app-navigation-path current))
       (extension-int values "count")
       send))
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
  (if (or (:has-pending-semantic-operations current)
          (:has-pending-sync-request current))
    "Syncing"
    (match (:sync-state current)
      OfflineState "Offline"
      SyncingState "Syncing"
      SyncedState "Up to date"
      (FailedState reason) (str "Sync failed: " reason))))

(defn sync-accessibility-identifier [current]
  (match (:sync-state current)
    (FailedState _reason) "sync.failed"
    OfflineState "sync.disconnected"
    _ "sync.connected"))

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

(defn favorites-empty? [current]
  (empty? (:favorites current)))

(defn recent-pages-empty? [current]
  (empty? (:recent-pages current)))

(defn sidebar-tab-visible? [current tab]
  (model/string-vector-contains? (:sidebar-tabs current) tab))

(defn flashcards-tab-visible? [current]
  (sidebar-tab-visible? current "flashcards"))

(defn graphs-tab-visible? [current]
  (sidebar-tab-visible? current "graphs"))

(defn sidebar-page-row [ui-context page-source send]
  (let [page (signal/sample page-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive sidebar-page-title page-source)
       :label (reactive sidebar-page-title page-source)
       :accessibility-identifier (sidebar-page-identifier page)
       :on-press
       (event [current-page page-source]
         (send (model/SelectSidebarPage (:uuid current-page))))}])))

(defui sidebar-view [model-source send]
  [:column
   {:accessibility-identifier "sidebar.navigation"}
   [:button
    {:label "Close sidebar"
     :accessibility-identifier "button.sidebar.dismiss"
     :on-press (fn [_event] (send model/CloseSidebar))}
    "Close"]
   [:button
    {:label "Switch graph"
     :accessibility-identifier "button.graph-switch"
     :on-press (fn [_event] (send model/ShowGraphs))}
    "Switch graph"]
   [:button
    {:label "Journals"
     :accessibility-identifier "link.sidebar.journals"
     :on-press (fn [_event] (send model/ShowJournals))}
    "Journals"]
   [:if {:test (reactive flashcards-tab-visible? model-source)}
    [:button
     {:label "Flashcards"
      :accessibility-identifier "link.sidebar.flashcards"
      :on-press (fn [_event] (send model/ShowFlashcards))}
     "Flashcards"]]
   [:if {:test (reactive graphs-tab-visible? model-source)}
    [:button
     {:label "Graphs"
      :accessibility-identifier "link.sidebar.graphs"
      :on-press (fn [_event] (send model/ShowGraphs))}
     "Graphs"]]
   [:column {:accessibility-identifier "section.sidebar.favorites"}
    [:text "Favorites"]
    [:if {:test (reactive favorites-empty? model-source)}
     [:text "No favorites yet"]]
    [:keyed
     {:source (reactive :favorites model-source)
      :key :uuid
      :compare compare
      :as page-source}
     [sidebar-page-row page-source send]]]
   [:column {:accessibility-identifier "section.sidebar.recent"}
    [:text "Recent"]
    [:if {:test (reactive recent-pages-empty? model-source)}
     [:text "No recent pages"]]
    [:keyed
     {:source (reactive :recent-pages model-source)
      :key :uuid
      :compare compare
      :as page-source}
     [sidebar-page-row page-source send]]]])

(defn composer-collapsed? [current]
  (not (:composer-expanded current)))

(defn composer-send-disabled? [current]
  (string/blank? (:composer-draft current)))

(defn task-status-identifier [status]
  (str "button.task-status.option." (:uuid status)))

(defn task-status-title [status]
  (:title status))

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
  (empty? (:search-results current)))

(defn search-empty-message [current]
  (if (string/blank? (:search-query current))
    "Search your graph"
    "No results"))

(defn search-result-row [ui-context hit-source send]
  (let [hit (signal/sample hit-source)]
    (elements/element
     ui-context nil
     [:list-item
      {:accessibility-identifier (search-result-identifier hit)
       :on-press
       (event [current-hit hit-source]
         (send (model/RequestSearchNode (:uuid current-hit))))}
      [:column
       [:text {:value (reactive search-result-title hit-source)}]
       [:text {:value (reactive search-result-breadcrumb hit-source)}]]])))

(defn outliner-row-identifier [row]
  (let [_depth (:depth row)]
    (str "outliner.block." (:uuid row))))

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

(defn outliner-row-collapse-label [row]
  (str (if (:is-collapsed row) "Expand " "Collapse ")
       (if (empty? (:title row)) "Untitled block" (:title row))))

(defn outliner-row-collapse-glyph [row]
  (if (:is-collapsed row) "›" "⌄"))

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
  (not (empty? (:node-routes current))))

(defn node-navigation-inactive? [current]
  (empty? (:node-routes current)))

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

(defn search-main-visible? [current]
  (and (journal-route-active? current) (:search-open current)))

(defn connection-control-visible? [current]
  (and (not (:search-open current))
       (not (= (:authentication-state current) "signedOut"))
       (not (= (:authentication-state current) "signingIn"))))

(defn search-query-present? [current]
  (not (empty? (:search-query current))))

(defn main-outliner-selection-active? [current]
  (and (journal-root-visible? current)
       (outliner-selection-active? current)))

(defn main-outliner-autocomplete-active? [current]
  (and (journal-root-visible? current)
       (outliner-autocomplete-active? current)))

(defn main-outliner-editor-active? [current]
  (and (journal-root-visible? current)
       (outliner-editor-active? current)))

(defn active-node-projection [current]
  (last (:node-routes current)))

(defn active-node-uuid [current]
  (match (active-node-projection current)
    (Some route) (:uuid route)
    None ""))

(defn active-node-title [current]
  (match (active-node-projection current)
    (Some route) (:title route)
    None "Untitled"))

(defn main-title [current]
  (match (:selected-page current)
    (Some page) (:title page)
    None "Logseq"))

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

(defn breadcrumb-button [ui-context breadcrumb-source send]
  (let [breadcrumb (signal/sample breadcrumb-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive breadcrumb-title breadcrumb-source)
       :accessibility-identifier (breadcrumb-identifier breadcrumb)
       :on-press
       (event [current-breadcrumb breadcrumb-source]
         (send (model/RequestAppNode (:uuid current-breadcrumb))))}])))

(defui related-row-breadcrumbs [row-source send]
  [:row {:accessibility-identifier "breadcrumb.related-blocks"}
   [:keyed
    {:source (reactive :breadcrumbs row-source)
     :key :uuid
     :compare compare
     :as breadcrumb-source}
    [breadcrumb-button breadcrumb-source send]]])

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

(defn outliner-row-has-tags? [row]
  (not (empty? (:tags row))))

(defn outliner-row-sync-failed? [row]
  (match (:sync-status row)
    (Some status) (= status "failed")
    None false))

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
       :accessibility-identifier (outliner-tag-identifier tag)
       :on-press
       (event [current-tag tag-source]
         (send (model/RequestAppNode (:uuid current-tag))))}])))

(defn outliner-row [ui-context model-source row-source send]
  (let [row (signal/sample row-source)
        search-open (:search-open (signal/sample model-source))
        block-id-source (reactive outliner-row-uuid row-source)
        title-source (reactive outliner-row-title row-source)
        markup-source (reactive :markup-json row-source)
        youtube-target-source
        (reactive outliner-row-youtube-target row-source)
        is-asset-source (reactive :is-asset row-source)
        asset-type-source (reactive outliner-row-asset-type row-source)
        local-path-source (reactive outliner-row-local-path row-source)
        editing-title-source (reactive editing-title model-source)
        editing-caret-source (reactive editing-caret model-source)
        indent-source (reactive outliner-row-indent row-source)
        editing-source (reactive row-editing? model-source row-source)
        selected-source (reactive row-selected? model-source row-source)
        not-editing-source
        (reactive row-not-editing? model-source row-source)
        has-children-source (reactive outliner-row-has-children row-source)
        has-status-source (reactive outliner-row-has-status? row-source)
        status-title-source (reactive outliner-row-status-title row-source)
        has-tags-source (reactive outliner-row-has-tags? row-source)
        sync-failed-source (reactive outliner-row-sync-failed? row-source)]
    (elements/element
     ui-context nil
     [:list-item
      {:accessibility-identifier (outliner-row-identifier row)
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
      [:column
       [:row {:gap 2 :padding-vertical 5}
        [outliner-indent-view indent-source]
        [:button
         {:label (reactive outliner-row-zoom-label row-source)
          :accessibility-identifier
          (str "button.outliner.zoom." (:uuid row))
          :on-press
          (event [current-row row-source]
            (if search-open
              (send (model/RequestSearchNode (:uuid current-row)))
              (send (model/RequestAppNode (:uuid current-row)))))}
         "•"]
        [:if {:test has-status-source}
         [:button
          {:text status-title-source
           :label "Task status"
           :accessibility-identifier "button.block-task-status"
           :on-press
           (event [current-row row-source]
             (send
              (model/OpenOutlinerTaskStatusPicker (:uuid current-row))))}]]
        [:if {:test editing-source}
         [outliner-editor-view block-id-source
          editing-title-source editing-caret-source send]]
        [:if {:test not-editing-source}
         [outliner-rich-block-view
          model-source title-source markup-source youtube-target-source
          is-asset-source row-source asset-type-source local-path-source send]]
        [:if {:test has-children-source}
         [:button
          {:text (reactive outliner-row-collapse-glyph row-source)
           :label (reactive outliner-row-collapse-label row-source)
           :accessibility-identifier
           (str "button.outliner.collapse." (:uuid row))
           :on-press
           (event [current-row row-source]
             (send (model/ToggleOutlinerCollapsed (:uuid current-row))))}]]]
       [:if {:test has-tags-source}
        [:row
         [:keyed
          {:source (reactive :tags row-source)
           :key :uuid
           :compare compare
           :as tag-source}
          [outliner-tag tag-source send]]]]
       [:if {:test sync-failed-source}
        [:text
         {:accessibility-identifier
          (str "outliner.sync-failed." (:uuid row))}
         "Sync failed"]]]])))

(defui outliner-entry [model-source row-source send]
  [:column
   [:if {:test
         (reactive outliner-journal-heading-visible?
                   model-source row-source)}
    [:column
     [:if {:test
           (reactive outliner-journal-divider-visible?
                     model-source row-source)}
      [:separator {:accessibility-identifier "journal.divider"}]]
     [:button
      {:text (reactive outliner-journal-title model-source row-source)
       :label (reactive outliner-journal-title model-source row-source)
       :accessibility-identifier-signal
       (reactive outliner-journal-button-identifier
                 model-source row-source)
       :on-press
       (event [current-row row-source]
         (send (model/RequestAppNode (:page-id current-row))))}]]]
   [outliner-row model-source row-source send]])

(defui outliner-selection-toolbar [send]
  [:toolbar
   {:orientation "horizontal"
    :label "Outliner selection"
    :accessibility-identifier "toolbar.outliner.selection"
    :class "scroll-leading"
    :gap 6}
   [:button
    {:label "Copy"
     :accessibility-identifier "button.outliner.selection.copy"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "copy")))}
    "Copy"]
   [:button
    {:label "Outdent"
     :accessibility-identifier "button.outliner.selection.outdent"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "outdent")))}
    "Outdent"]
   [:button
    {:label "Indent"
     :accessibility-identifier "button.outliner.selection.indent"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "indent")))}
    "Indent"]
   [:button
    {:label "Delete"
     :accessibility-identifier "button.outliner.selection.delete"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "delete")))}
    "Delete"]
   [:button
    {:label "Copy reference"
     :accessibility-identifier "button.outliner.selection.copyReference"
     :on-press
     (fn [_event]
       (send (model/PerformOutlinerToolbarAction "copyReference")))}
    "Copy reference"]
   [:button
    {:label "Copy URL"
     :accessibility-identifier "button.outliner.selection.copyURL"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "copyURL")))}
    "Copy URL"]
   [:button
    {:label "Unselect"
     :accessibility-identifier "button.outliner.selection.unselect"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "unselect")))}
    "Unselect"]])

(defn outliner-autocomplete-row [ui-context candidate-source send]
  (let [candidate (signal/sample candidate-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive outliner-autocomplete-label candidate-source)
       :label (reactive outliner-autocomplete-label candidate-source)
       :accessibility-identifier
       (outliner-autocomplete-identifier candidate)
       :on-press
       (event [current-candidate candidate-source]
         (send
          (model/ChooseOutlinerAutocomplete
           (:value current-candidate))))}])))

(defui outliner-autocomplete-bar [model-source send]
  [:toolbar
   {:orientation "vertical"
    :label "Outliner autocomplete"
    :accessibility-identifier "toolbar.outliner.autocomplete"
    :gap 2}
   [:keyed
    {:source (reactive :outliner-autocomplete-candidates model-source)
     :key :value
     :compare compare
     :as candidate-source}
    [outliner-autocomplete-row candidate-source send]]])

(defui outliner-editor-toolbar [send]
  [:toolbar
   {:orientation "horizontal"
    :label "Outliner editor"
    :accessibility-identifier "toolbar.outliner.editor"
    :class "scroll-leading"
    :gap 4}
   [:button
    {:label "Task"
     :accessibility-identifier "button.outliner.editor.task"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "task")))}
    "Task"]
   [:button
    {:label "Outdent"
     :accessibility-identifier "button.outliner.editor.outdent"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "outdent")))}
    "Outdent"]
   [:button
    {:label "Indent"
     :accessibility-identifier "button.outliner.editor.indent"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "indent")))}
    "Indent"]
   [:button
    {:label "Tag"
     :accessibility-identifier "button.outliner.editor.tag"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "tag")))}
    "Tag"]
   [:button
    {:label "Photo"
     :accessibility-identifier "button.outliner.editor.camera"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "camera")))}
    "Photo"]
   [:button
    {:label "Record audio"
     :accessibility-identifier "button.outliner.editor.audio"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "audio")))}
    "Audio"]
   [:button
    {:label "Upload asset"
     :accessibility-identifier "button.outliner.editor.attachment"
     :on-press
     (fn [_event] (send (model/PerformOutlinerToolbarAction "attachment")))}
    "Attach"]
   [:button
    {:label "Page reference"
     :accessibility-identifier "button.outliner.editor.pageReference"
     :on-press
     (fn [_event]
       (send (model/PerformOutlinerToolbarAction "pageReference")))}
    "[[]]"]
   [:button
    {:label "Hide keyboard"
     :accessibility-identifier "button.outliner.editor.hideKeyboard"
     :on-press
     (fn [_event]
       (send (model/PerformOutlinerToolbarAction "hideKeyboard")))}
    "Hide"]])

(defn node-related-row [ui-context model-source row-source send]
  (let [structured-breadcrumb-source
        (reactive outliner-row-structured-breadcrumb? row-source)
        fallback-breadcrumb-source
        (reactive outliner-row-fallback-breadcrumb? row-source)]
    (elements/element
     ui-context nil
     [:column
      [:if {:test structured-breadcrumb-source}
       [related-row-breadcrumbs row-source send]]
      [:if {:test fallback-breadcrumb-source}
       [:text {:value (reactive outliner-row-breadcrumb row-source)}]]
      [outliner-row model-source row-source send]])))

(defui node-related-section [model-source send]
  [:column
   {:accessibility-identifier "section.node.linked-references"}
   [:text "Linked references"]
   [:list {:accessibility-identifier "list.node.related"}
    [:keyed
     {:source (reactive active-node-related-rows model-source)
      :key :uuid
      :compare compare
      :as row-source}
     [node-related-row model-source row-source send]]]])

(defui node-tagged-section [model-source send]
  [:column
   {:accessibility-identifier "section.tag.tagged-nodes"}
   [:text "Tagged nodes"]
   [:if {:test (reactive node-tag-section-empty? model-source)}
    [:text "No tagged nodes"]]
   [:list {:accessibility-identifier "list.node.tagged"}
    [:keyed
     {:source (reactive active-node-related-rows model-source)
      :key :uuid
      :compare compare
      :as row-source}
     [node-related-row model-source row-source send]]]])

(defui node-linked-reference-section [model-source send]
  [:column
   {:accessibility-identifier "section.node.linked-references"}
   [:text "Linked references"]
   [:list {:accessibility-identifier "list.node.linked-references"}
    [:keyed
     {:source (reactive active-node-linked-reference-rows model-source)
      :key :uuid
      :compare compare
      :as row-source}
     [node-related-row model-source row-source send]]]])

(defui add-first-block-button [model-source send]
  [:button
   {:label "Add first block"
    :accessibility-identifier "button.outliner.add-first-block"
    :on-press
    (event [current model-source]
      (send (model/AddRootBlock (active-node-page-uuid current))))}
   "Add first block"])

(defui node-screen [model-source send]
  [:column
   {:accessibility-identifier "screen.node"}
   [:text
    {:value (reactive active-node-title model-source)
     :accessibility-identifier "title.node"}]
   [:scroll {:accessibility-identifier "scroll.outliner"}
    [:list {:accessibility-identifier "list.outliner"}
     [:keyed
      {:source (reactive :outliner-rows model-source)
       :key :uuid
       :compare compare
       :as row-source}
      [outliner-row model-source row-source send]]]]
   [:if {:test (reactive node-can-add-first-block? model-source)}
    [add-first-block-button model-source send]]
   [:if {:test (reactive node-related-section-visible? model-source)}
    [node-related-section model-source send]]
   [:if {:test (reactive node-tag-section-visible? model-source)}
    [node-tagged-section model-source send]]
   [:if {:test (reactive node-linked-reference-section-visible? model-source)}
    [node-linked-reference-section model-source send]]
   [:if {:test (reactive outliner-selection-active? model-source)}
    [outliner-selection-toolbar send]]
   [:if {:test (reactive outliner-autocomplete-active? model-source)}
    [outliner-autocomplete-bar model-source send]]
   [:if {:test (reactive outliner-editor-active? model-source)}
    [outliner-editor-toolbar send]]
   (composer-view model-source send)])

(defui composer-view [model-source send]
  [:column
   {:accessibility-identifier "surface.composer.root"
    :on-press (fn [_event] (send model/FocusComposer))}
   [:if {:test (reactive :composer-expanded model-source)}
    [:column
     [:textarea
      {:text (reactive :composer-draft model-source)
       :autofocus (reactive :composer-autofocus model-source)
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
     [:row
      [:button
       {:icon "plus"
        :label "Add attachment"
        :accessibility-identifier "button.attachment"
        :on-press (fn [_event] (send model/OpenAttachmentPicker))}]
      [:button
       {:icon "check"
        :label "Task status"
        :accessibility-identifier "button.task-status"
        :on-press (fn [_event] (send model/OpenTaskStatusPicker))}]
      [:button
       {:icon "send"
        :label "Send"
        :accessibility-identifier "button.send"
        :disabled (reactive composer-send-disabled? model-source)
        :on-press (fn [_event] (send model/SendComposer))}]]]]
   [:if {:test (reactive composer-collapsed? model-source)}
    [:button
     {:accessibility-identifier "button.composer.expand"
      :on-press (fn [_event] (send model/ExpandComposer))}
     "Capture"]]])

(defui attachment-picker-dialog [send]
  [:dialog
   {:text "Add attachment"
    :on-dismiss (fn [_event] (send model/CloseAttachmentPicker))}
   [:column
    [:button
     {:accessibility-identifier "button.attachment.files"
      :on-press (fn [_event] (send (model/ChooseAttachment "files")))}
     "Files"]
    [:button
     {:accessibility-identifier "button.attachment.camera"
      :on-press (fn [_event] (send (model/ChooseAttachment "camera")))}
     "Camera"]
    [:button
     {:accessibility-identifier "button.attachment.photos"
      :on-press (fn [_event] (send (model/ChooseAttachment "photos")))}
     "Photos"]
    [:button
     {:accessibility-identifier "button.attachment.audio"
      :on-press (fn [_event] (send (model/ChooseAttachment "audio")))}
     "Audio recording"]
    [:button
     {:on-press (fn [_event] (send model/CloseAttachmentPicker))}
     "Cancel"]]])

(defui composer-dismissal-surface [send]
  [:button
   {:label "Dismiss composer"
    :accessibility-identifier "surface.composer.dismiss"
    :grow 1.0
    :on-press (fn [_event] (send model/DismissComposer))}])

(defn task-status-row [ui-context status-source send]
  (let [status (signal/sample status-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive task-status-title status-source)
       :label (reactive task-status-title status-source)
       :accessibility-identifier (task-status-identifier status)
       :on-press
       (event [current-status status-source]
         (send (model/ChooseTaskStatus (:uuid current-status))))}])))

(defui task-status-picker-dialog [model-source send]
  [:dialog
   {:text "Task status"
    :on-dismiss (fn [_event] (send model/CloseTaskStatusPicker))}
   [:column
    [:keyed
     {:source (reactive :task-statuses model-source)
      :key :uuid
      :compare compare
      :as status-source}
     [task-status-row status-source send]]
    [:if {:test (reactive task-status-selected? model-source)}
     [:button
      {:accessibility-identifier "button.task-status.clear"
       :on-press (fn [_event] (send model/ClearTaskStatus))}
      "Clear task status"]]
    [:button
     {:on-press (fn [_event] (send model/CloseTaskStatusPicker))}
     "Cancel"]]])

(defn outliner-task-status-picker-open? [current]
  (match (:outliner-task-status-block-id current)
    (Some _block-id) true
    None false))

(defn outliner-task-status-option-identifier [status]
  (str
   "button.block-task-status-option."
   (match (:ident status)
     (Some ident) ident
     None (:uuid status))))

(defn outliner-task-status-row [ui-context status-source send]
  (let [status (signal/sample status-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive task-status-title status-source)
       :label (reactive task-status-title status-source)
       :accessibility-identifier
       (outliner-task-status-option-identifier status)
       :on-press
       (event [current-status status-source]
         (send (model/ChooseOutlinerTaskStatus (:uuid current-status))))}])))

(defui outliner-task-status-dialog [model-source send]
  [:dialog
   {:text "Task status"
    :on-dismiss
    (fn [_event] (send model/CloseOutlinerTaskStatusPicker))}
   [:column
    [:keyed
     {:source (reactive :task-statuses model-source)
      :key :uuid
      :compare compare
      :as status-source}
     [outliner-task-status-row status-source send]]
    [:button
     {:on-press
      (fn [_event] (send model/CloseOutlinerTaskStatusPicker))}
     "Cancel"]]])

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

(defui flashcard-screen [model-source send]
  [:column
   {:accessibility-identifier "screen.flashcards"
    :gap 18
    :padding-horizontal 20
    :padding-top 18
    :padding-bottom 24}
   [:if {:test (reactive flashcards-empty? model-source)}
    [:column {:accessibility-identifier "flashcards.empty" :gap 10 :padding 32}
     [:heading "No cards due"]
     [:text "Tag a block with #Card to add it to Flashcards."]]]
   [:if {:test (reactive flashcards-present? model-source)}
    [:text "Due now"]]
   [:if {:test (reactive flashcards-present? model-source)}
    [:text {:value (reactive flashcard-remaining-label model-source)}]]
   [:if {:test (reactive flashcards-present? model-source)}
    [:text
     {:value (reactive flashcard-question model-source)
      :accessibility-identifier "flashcard.question"}]]
   [:keyed
    {:source (reactive visible-flashcard-answer-rows model-source)
     :key :uuid
     :compare compare
     :as answer-source}
    [flashcard-answer-row answer-source]]
   [:if {:test (reactive flashcard-show-cloze? model-source)}
    [:button
     {:accessibility-identifier "button.flashcard.show-cloze"
      :on-press (fn [_event] (send model/RevealFlashcardCloze))}
     "Show cloze"]]
   [:if {:test (reactive flashcard-show-answer? model-source)}
    [:button
     {:accessibility-identifier "button.flashcard.show-answer"
      :on-press (fn [_event] (send model/RevealFlashcardAnswer))}
     "Show answer"]]
   [:if {:test (reactive flashcard-show-ratings? model-source)}
    [:button
     {:accessibility-identifier "button.flashcard.rating.again"
      :on-press (fn [_event] (send (model/ReviewFlashcard "again")))}
     "Again"]]
   [:if {:test (reactive flashcard-show-ratings? model-source)}
    [:button
     {:accessibility-identifier "button.flashcard.rating.hard"
      :on-press (fn [_event] (send (model/ReviewFlashcard "hard")))}
     "Hard"]]
   [:if {:test (reactive flashcard-show-ratings? model-source)}
    [:button
     {:accessibility-identifier "button.flashcard.rating.good"
      :on-press (fn [_event] (send (model/ReviewFlashcard "good")))}
     "Good"]]
   [:if {:test (reactive flashcard-show-ratings? model-source)}
    [:button
     {:accessibility-identifier "button.flashcard.rating.easy"
      :on-press (fn [_event] (send (model/ReviewFlashcard "easy")))}
     "Easy"]]])

(defn graph-identifier [graph]
  (str "graph." (:id graph)))

(defn graph-delete-identifier [graph]
  (str "button.graph.delete." (:id graph)))

(defn graph-title [graph]
  (:name graph))

(defn graph-status-identifier [graph]
  (str "graph.status." (:id graph)))

(defn graph-status-visible? [graph]
  (or (:is-encrypted graph) (not (:is-ready graph))))

(defn graph-status-title [graph]
  (if (:is-encrypted graph) "Encrypted" "Preparing"))

(defn graph-not-ready? [graph]
  (not (:is-ready graph)))

(defn graph-row-disabled? [current graph]
  (or (graph-not-ready? graph)
      (model/graph-delete-active? current (:id graph))))

(defn graph-delete-active? [current graph]
  (model/graph-delete-active? current (:id graph)))

(defn graph-row-local? [current graph]
  (model/graph-local? current (:id graph)))

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
       (not (= (:authentication-state current) "signingIn"))))

(defn graph-row [ui-context model-source graph-source send]
  (let [graph (signal/sample graph-source)
        graph-id (:id graph)]
    (elements/element
     ui-context nil
     [:list-item
      {:accessibility-identifier (graph-identifier graph)
       :disabled (reactive graph-row-disabled? model-source graph-source)
       :on-press
       (event [current-graph graph-source]
         (send (model/RequestOpenGraph (:id current-graph))))}
      [:row
       [:text {:value (reactive graph-title graph-source)}]
       [:if {:test (reactive graph-status-visible? graph-source)}
        [:text
         {:value (reactive graph-status-title graph-source)
          :accessibility-identifier (graph-status-identifier graph)}]]
       [:if {:test (reactive graph-row-local? model-source graph-source)}
        [:button
         {:label "Delete local graph"
          :accessibility-identifier (graph-delete-identifier graph)
          :disabled (reactive graph-delete-active? model-source graph-source)
          :on-press (fn [_event] (send (model/RequestDeleteGraph graph-id)))}
         "Delete local graph"]]]])))

(defui graph-create-sheet [model-source send]
  [:sheet
   {:text "Add sync graph"
    :on-dismiss (fn [_event] (send model/DismissCreateGraph))}
   [:column
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
    [:text "Encryption cannot be changed after the sync graph is created."]
    [:button
     {:on-press (fn [_event] (send model/DismissCreateGraph))}
     "Cancel"]
    [:button
     {:accessibility-identifier "button.graph-add.confirm"
      :disabled (reactive graph-create-disabled? model-source)
      :on-press (fn [_event] (send model/SubmitCreateGraph))}
     "Add"]]])

(defui graph-delete-dialog [model-source send]
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
     "Confirm"]]])

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
  [:column {:accessibility-identifier "screen.graphs"}
   [:button
    {:accessibility-identifier "button.graphs.refresh"
     :disabled (reactive model/graph-refresh-active? model-source)
     :on-press (fn [_event] (send model/RefreshGraphs))}
    "Refresh"]
   [:if {:test (reactive model/graph-refresh-active? model-source)}
    [:spinner {:accessibility-identifier "graphs.loading"}]]
   [:button
    {:accessibility-identifier "button.graph-add"
     :on-press (fn [_event] (send model/OpenCreateGraph))}
    "Add sync graph"]
   [:text "Local graphs:"]
   [:if {:test (reactive local-graphs-empty? model-source)}
    [:text "No local graphs"]]
   [:keyed
    {:source (reactive local-graphs model-source)
     :key :id
     :compare compare
     :as graph-source}
    [graph-row model-source graph-source send]]
   [:if {:test (reactive remote-graphs-present? model-source)}
    [:text "Remote graphs:"]]
   [:keyed
    {:source (reactive remote-graphs model-source)
     :key :id
     :compare compare
     :as graph-source}
    [graph-row model-source graph-source send]]
   [:if {:test (reactive :create-graph-open model-source)}
    [graph-create-sheet model-source send]]
   [:if {:test (reactive graph-deletion-pending? model-source)}
   [graph-delete-dialog model-source send]]])

(defui graph-picker-screen [model-source send]
  [:column {:accessibility-identifier "screen.graph-picker"}
   [:heading "Choose a graph"]
   [:text "Select a Logseq graph to download and sync on this device."]
   [:button
    {:accessibility-identifier "button.graph-add"
     :on-press (fn [_event] (send model/OpenCreateGraph))}
    "Add sync graph"]
   [:if {:test (reactive empty-graphs-loading? model-source)}
    [:spinner {:accessibility-identifier "graphs.loading"}]]
   [:if {:test (reactive empty-graphs-refreshable? model-source)}
    [:button
     {:accessibility-identifier "button.graphs.refresh"
      :on-press (fn [_event] (send model/RefreshGraphs))}
     "Refresh graphs"]]
   [:list
    [:keyed
     {:source (reactive :graphs model-source)
      :key :id
      :compare compare
      :as graph-source}
     [graph-row model-source graph-source send]]]
   [:if {:test (reactive :create-graph-open model-source)}
    [graph-create-sheet model-source send]]])

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

(defn settings-language-choice-title [choice]
  (:title choice))

(defn settings-language-choice-identifier [choice]
  (str "button.settings.language." (:id choice)))

(defn settings-language-choice-row [ui-context choice-source send]
  (let [choice (signal/sample choice-source)]
    (elements/element
     ui-context nil
     [:menu-item
      {:text (reactive settings-language-choice-title choice-source)
       :accessibility-identifier
       (settings-language-choice-identifier choice)
       :on-press
       (event [current-choice choice-source]
         (send (model/ChooseSettingsLanguage (:id current-choice))))}])))

(defn settings-community-link-title [link]
  (:title link))

(defn settings-community-link-identifier [link]
  (str "link.settings.community." (:id link)))

(defn settings-community-link-row [ui-context link-source send]
  (let [link (signal/sample link-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive settings-community-link-title link-source)
       :accessibility-identifier
       (settings-community-link-identifier link)
       :on-press
       (event [current-link link-source]
         (send (model/OpenExternalURL (:url current-link))))}])))

(defn settings-tabs-visible? [current]
  (:settings-tabs-open current))

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
   [:column
    [:row
     [:text {:value (reactive runtime-log-level record-source)}]
     [:text {:value (reactive runtime-log-timestamp record-source)}]]
    [:text {:value (reactive runtime-log-message record-source)}]
    [:separator]]))

(defui settings-tab-row [model-source tab title send]
  (let [label-source
        (reactive (fn [current] (tab-toggle-label current tab)) model-source)
        toggle-disabled-source
        (reactive (fn [_current] (model/required-sidebar-tab? tab)) model-source)
        movement-visible-source
        (reactive (fn [current] (tab-movement-visible? current tab)) model-source)
        up-disabled-source
        (reactive (fn [current] (tab-move-up-disabled? current tab)) model-source)
        down-disabled-source
        (reactive (fn [current] (tab-move-down-disabled? current tab)) model-source)]
    (elements/element
     ui-context nil
     [:row
      {:accessibility-identifier (str "row.settings.tab." tab)}
     [:button
      {:label label-source
       :disabled toggle-disabled-source
       :accessibility-identifier (tab-toggle-identifier tab)
       :on-press (fn [_event] (send (model/ToggleSidebarTab tab)))}
      title]
     [:if {:test movement-visible-source}
      [:button
       {:disabled up-disabled-source
        :accessibility-label (str "Move " title " up")
        :accessibility-identifier (tab-up-identifier tab)
        :on-press
        (fn [_event] (send (model/MoveSidebarTab tab -1)))}
       "↑"]]
     [:if {:test movement-visible-source}
      [:button
       {:disabled down-disabled-source
        :accessibility-label (str "Move " title " down")
        :accessibility-identifier (tab-down-identifier tab)
        :on-press
        (fn [_event] (send (model/MoveSidebarTab tab 1)))}
       "↓"]]])))

(defui settings-tabs-screen [model-source send]
  [:column {:accessibility-identifier "screen.settings.tabs"}
   [:row
    [:button {:on-press (fn [_event] (send model/BackSettings))} "Settings"]
    [:heading {:level 1} "Tabs"]]
   [:text "Visible tabs"]
   [settings-tab-row model-source "journals" "Journals" send]
   [:if {:test (reactive settings-flashcards-before-graphs? model-source)}
    [settings-tab-row model-source "flashcards" "Flashcards" send]]
   [settings-tab-row model-source "graphs" "Graphs" send]
   [:if {:test (reactive settings-flashcards-after-graphs? model-source)}
    [settings-tab-row model-source "flashcards" "Flashcards" send]]
   [:text "Journals and Graphs are always available. Use the arrows to reorder tabs."]
   [:if {:test (reactive settings-available-tabs-present? model-source)}
    [:text
     {:accessibility-identifier "text.settings.tabs.available"}
     "Available tabs"]]
   [:if {:test (reactive settings-available-tabs-present? model-source)}
    [settings-tab-row model-source "flashcards" "Flashcards" send]]])

(defui runtime-log-screen [model-source send]
  [:column {:accessibility-identifier "screen.runtime-log"}
   [:row
    [:button {:on-press (fn [_event] (send model/DismissRuntimeLog))} "Done"]
    [:heading {:level 1} "Log"]
    [:button
     {:accessibility-identifier "button.log-refresh"
      :on-press (fn [_event] (send model/RefreshRuntimeLog))}
     "Refresh"]]
   [:row
    [:button
     {:text (reactive runtime-log-errors-label model-source)
      :accessibility-identifier "button.log-errors"
      :on-press (fn [_event] (send model/ToggleRuntimeLogErrors))}]
    [:button
     {:text (reactive runtime-log-order-label model-source)
      :accessibility-identifier "button.log-order"
      :on-press (fn [_event] (send model/ToggleRuntimeLogOrder))}]
    [:button
     {:text (reactive runtime-log-source-label model-source)
      :accessibility-identifier "button.log-source"
      :on-press (fn [_event] (send model/ToggleRuntimeLogSource))}]
    [:button
     {:accessibility-identifier "button.log-copy"
      :on-press (fn [_event] (send model/CopyRuntimeLog))}
     "Copy"]]
   [:if {:test (reactive runtime-log-empty? model-source)}
    [:text "No log entries"]]
   [:keyed
    {:source (reactive runtime-log-records model-source)
     :key :id
     :compare compare
     :as record-source}
    [runtime-log-row record-source]]])

(defui settings-screen [model-source send]
  [:column {:accessibility-identifier "screen.settings"}
   [:heading {:level 1} "Settings"]
   [:heading {:level 2} "General"]
   [:text "Theme"]
   [:row
    [:button {:on-press (fn [_event] (send (model/ChangeAppearance "system")))}
     "System"]
    [:button {:on-press (fn [_event] (send (model/ChangeAppearance "light")))}
     "Light"]
    [:button {:on-press (fn [_event] (send (model/ChangeAppearance "dark")))}
     "Dark"]]
   [:button
    {:text (reactive settings-language-title model-source)
     :label "Language"
     :accessibility-identifier "picker.settings.language"
     :on-press (fn [_event] (send model/OpenSettingsLanguageMenu))}]
   [:if {:test (reactive :settings-language-menu-open model-source)}
    [:dropdown-menu
     {:accessibility-identifier "menu.settings.language"
      :on-dismiss (fn [_event] (send model/CloseSettingsLanguageMenu))}
     [:keyed
      {:source (reactive :language-choices model-source)
       :key :id
       :compare compare
       :as choice-source}
      [settings-language-choice-row choice-source send]]]]
   [:button
    {:accessibility-identifier "link.settings.tabs"
     :on-press (fn [_event] (send model/OpenSettingsTabs))}
    "Tabs"]
   [:heading {:level 2} "Editor"]
   [:toggle
    {:checked (reactive settings-spell-check model-source)
     :on-toggle
     (fn [input-event]
       (match input-event
         (proto/ToggleChanged _node enabled)
         (send (model/ToggleSpellCheck enabled))
         _ true))}
    "Spell check"]
   [:toggle
    {:checked (reactive settings-auto-correction model-source)
     :on-toggle
     (fn [input-event]
       (match input-event
         (proto/ToggleChanged _node enabled)
         (send (model/ToggleAutoCorrection enabled))
         _ true))}
    "Auto-correction"]
   [:heading {:level 2} "Sync server"]
   [:text "Connection"]
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
    [:text "Enter a valid HTTP or HTTPS URL."]]
   [:if {:test (reactive selected-graph-local? model-source)}
    [:column
     [:heading {:level 2} "Advanced"]
     [:button
      {:accessibility-identifier "button.export-graph-database"
       :on-press (fn [_event] (send model/ExportGraphDatabase))}
      "Export Graph SQLite DB"]]]
   [:heading {:level 2} "About"]
   [:row [:text "Version"] [:text {:value (reactive settings-version model-source)}]]
   [:row [:text "Revision"] [:text {:value (reactive settings-revision model-source)}]]
   [:button {:on-press (fn [_event] (send model/OpenRuntimeLog))} "Check log"]
   [:heading {:level 2} "Community"]
   [:keyed
    {:source (reactive :community-links model-source)
     :key :id
     :compare compare
     :as link-source}
    [settings-community-link-row link-source send]]
   [:button
    {:accessibility-identifier "button.sign-out"
     :on-press (fn [_event] (send model/SignOut))}
    "Sign Out"]
   [:row
    [:button
     {:accessibility-identifier "button.connection.cancel"
      :on-press (fn [_event] (send model/DismissSettings))}
     "Cancel"]
    [:button
     {:accessibility-identifier "button.connection.apply"
      :disabled (reactive settings-apply-disabled? model-source)
      :on-press (fn [_event] (send model/ApplySettings))}
     "Apply"]]])

(defui settings-sheet [model-source send]
  [:sheet
   {:text "Settings"
    :on-dismiss (fn [_event] (send model/DismissSettings))}
   [:if {:test (reactive settings-main-visible? model-source)}
    [settings-screen model-source send]]
   [:if {:test (reactive settings-tabs-visible? model-source)}
    [settings-tabs-screen model-source send]]
   [:if {:test (reactive runtime-log-visible? model-source)}
    [runtime-log-screen model-source send]]])

(defui page-delete-dialog [send]
  [:dialog
   {:text "Delete page?"
    :on-dismiss (fn [_event] (send model/CancelDeleteActivePage))}
   [:column
    [:text "The page will be moved to Recycle."]
    [:button
     {:on-press (fn [_event] (send model/CancelDeleteActivePage))}
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
    :on-dismiss (fn [_event] (send model/CloseSyncDetails))}
   [:column
    [:heading "Sync status"]
    [:row [:text "Status"] [:text {:value (reactive sync-label model-source)}]]
    [:row [:text "Graph"] [:text {:value (reactive graph-label model-source)}]]
    [:row
     [:text "Connection"]
     [:text {:value (reactive sync-connection-label model-source)}]]
    [:row
     [:text "Local changes"]
     [:text
      {:value (reactive sync-pending-label model-source)
       :accessibility-identifier "sync.pending"}]]
    [:row
     [:text "Server cursor"]
     [:text
      {:value (reactive sync-cursor-label model-source)
       :accessibility-identifier "sync.cursor"}]]
    [:if {:test (reactive sync-error-present? model-source)}
     [:column
      [:text "Last error"]
      [:text
       {:value (reactive sync-error-message model-source)
        :accessibility-identifier "sync.error"}]]]
    [:button
     {:accessibility-identifier "button.sync-now"
      :on-press (fn [_event] (send model/SyncNow))}
     "Sync now"]
    [:button
     {:on-press (fn [_event] (send model/CloseSyncDetails))}
     "Done"]]])

(defui chat-main-view [model-source send]
  [:column
   [:if {:test (reactive journal-root-visible? model-source)}
    [:text
     {:value (reactive main-title model-source)
      :accessibility-identifier "title.main"}]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [:text {:value (reactive graph-label model-source)}]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [:button
     {:text (reactive sync-label model-source)
      :label (reactive sync-label model-source)
      :accessibility-identifier-signal
      (reactive sync-accessibility-identifier model-source)
      :on-press (fn [_event] (send model/OpenSyncDetails))}]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [:button
     {:accessibility-identifier "button.search"
      :on-press (fn [_event] (send model/OpenSearch))}
     "Search"]]
   [:if {:test (reactive connection-control-visible? model-source)}
    [:button
     {:label "Connection"
      :accessibility-identifier "button.connection"
      :on-press (fn [_event] (send model/OpenConnectionMenu))}
     "Connection"]]
   [:if {:test (reactive global-effect-error-present? model-source)}
    [:text
     {:value (reactive effect-error-message model-source)
      :accessibility-identifier "error.banner"}]]
   [:if {:test (reactive :connection-menu-open model-source)}
    [:dropdown-menu {:on-dismiss (fn [_event] (send model/CloseConnectionMenu))}
     [:if {:test (reactive active-page-actions-visible? model-source)}
      [:menu-item
       {:text (reactive active-page-favorite-label model-source)
        :accessibility-identifier "button.page-favorite"
        :on-press (fn [_event] (send model/ToggleActivePageFavorite))}]]
     [:if {:test (reactive active-page-actions-visible? model-source)}
      [:menu-item
       {:accessibility-identifier "button.page-share"
        :on-press (fn [_event] (send model/ShareActivePage))}
       "Share"]]
     [:if {:test (reactive active-page-actions-visible? model-source)}
      [:menu-item
       {:accessibility-identifier "button.page-delete"
        :on-press (fn [_event] (send model/RequestDeleteActivePage))}
       "Delete"]]
     [:if {:test (reactive connection-settings-visible? model-source)}
      [:menu-item {:on-press (fn [_event] (send model/OpenSettings))}
       "Settings"]]]]
   [:if {:test (reactive graph-loading-visible? model-source)}
    [:column {:accessibility-identifier "journals.loading"}
     [:text "Loading journals"]]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [:text
     {:accessibility-label "Journal graph load status"
      :accessibility-identifier "journals.graph-loaded"}
     ""]]
   [:if {:test (reactive graph-picker-visible? model-source)}
    [graph-picker-screen model-source send]]
   [:if {:test (reactive search-main-visible? model-source)}
    [:column {:accessibility-identifier "screen.search"}
     [:search-field
     {:text (reactive :search-query model-source)
       :placeholder "Search pages and blocks"
       :label "Search pages and blocks"
       :accessibility-identifier "field.search"
       :on-input
       (fn [input-event]
         (match input-event
           (TextChanged _node text) (send (model/ChangeSearchQuery text))
           _ true))}]
     [:if {:test (reactive search-query-present? model-source)}
      [:button
       {:label "Clear search"
        :accessibility-identifier "button.search.clear"
        :on-press (fn [_event] (send (model/ChangeSearchQuery "")))}
       "Clear"]]
     [:button
     {:accessibility-identifier "button.search.close"
       :on-press (fn [_event] (send model/CloseSearch))}
      "Close"]
     [:if {:test (reactive search-empty-state-present? model-source)}
      [:text
       {:value (reactive search-empty-message model-source)
        :accessibility-identifier "search.empty"}]]
     [:if {:test (reactive page-search-results-present? model-source)}
      [:text {:accessibility-identifier "search.section.pages"} "Pages"]]
     [:list
      [:keyed
       {:source (reactive page-search-results model-source)
        :key :uuid
        :compare compare
        :as hit-source}
       [search-result-row hit-source send]]]
     [:if {:test (reactive block-search-results-present? model-source)}
      [:text {:accessibility-identifier "search.section.blocks"} "Blocks"]]
     [:list
      [:keyed
       {:source (reactive block-search-results model-source)
        :key :uuid
        :compare compare
        :as hit-source}
       [search-result-row hit-source send]]]]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [:scroll {:accessibility-identifier "scroll.outliner"}
     [:list {:accessibility-identifier "list.outliner"}
      [:keyed
       {:source (reactive :outliner-rows model-source)
        :key :uuid
        :compare compare
        :as row-source}
       [outliner-entry model-source row-source send]]]]]
   [:if {:test (reactive older-journals-visible? model-source)}
    [:button
     {:accessibility-identifier "button.outliner.load-older-journals"
      :on-press (fn [_event] (send model/LoadOlderJournals))}
     "Load older journals"]]
   [:if {:test (reactive main-can-add-first-block? model-source)}
    [add-first-block-button model-source send]]
   [:if {:test (reactive main-related-section-visible? model-source)}
    [node-related-section model-source send]]
   [:if {:test (reactive main-tag-section-visible? model-source)}
    [node-tagged-section model-source send]]
   [:if {:test (reactive main-linked-reference-section-visible? model-source)}
    [node-linked-reference-section model-source send]]
   [:if {:test (reactive main-outliner-selection-active? model-source)}
    [outliner-selection-toolbar send]]
   [:if {:test (reactive main-outliner-autocomplete-active? model-source)}
    [outliner-autocomplete-bar model-source send]]
   [:if {:test (reactive main-outliner-editor-active? model-source)}
    [outliner-editor-toolbar send]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [composer-view model-source send]]
   [:if {:test (reactive flashcards-destination? model-source)}
    [flashcard-screen model-source send]]
   [:if {:test (reactive graphs-destination? model-source)}
    [graphs-screen model-source send]]
   [:if {:test (reactive primary-sidebar-button-visible? model-source)}
    [:button
     {:label "Open sidebar"
      :accessibility-identifier "button.sidebar"
      :on-press (fn [_event] (send model/OpenSidebar))}
     "Menu"]]
   [:if {:test (reactive :settings-open model-source)}
    [settings-sheet model-source send]]
   [:if {:test (reactive :graph-password-open model-source)}
    [graph-password-sheet model-source send]]
   [:if {:test (reactive :attachment-picker-open model-source)}
    [attachment-picker-dialog send]]
   [:if {:test (reactive :task-status-picker-open model-source)}
    [task-status-picker-dialog model-source send]]
   [:if {:test (reactive outliner-task-status-picker-open? model-source)}
    [outliner-task-status-dialog model-source send]]
   [:if {:test (reactive page-deletion-pending? model-source)}
    [page-delete-dialog send]]
   [:if {:test (reactive :sync-details-open model-source)}
    [sync-status-sheet model-source send]]])

(defn journal-navigation-model [current]
  (let [rows (:journal-outliner-rows current)
        root
        (assoc current
               :node-routes []
               :app-navigation-path []
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

(defn native-navigation-depth [current]
  (count (:node-routes current)))

(defui native-node-screen [model-source route-source send]
  (let [route-model-source
        (reactive node-route-model model-source route-source)]
    (elements/element
     ui-context nil
     [node-screen route-model-source send])))

(defui native-navigation-view [model-source send]
  (let [node (ui/extension! ui-context "native-navigation-stack")
        depth-source (reactive native-navigation-depth model-source)
        depth-value-source (reactive int-wire-value depth-source)]
    (ui/extension-property-signal!
     ui-context node "depth" depth-value-source)
    (ui/on-event!
     ui-context node
     (fn [input-event]
       (handle-native-navigation-event input-event model-source send)))
    (elements/element
     ui-context node
     [chat-main-view (reactive journal-navigation-model model-source) send])
    (elements/element
     ui-context node
     [:keyed
      {:source (reactive :node-routes model-source)
       :key :uuid
       :compare compare
       :as route-source}
      [native-node-screen model-source route-source send]])
    node))

(defn authentication-screen-visible? [current]
  (or (= (:authentication-state current) "signedOut")
      (= (:authentication-state current) "signingIn")))

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

(defui authentication-screen [model-source send]
  [:column
   {:accessibility-identifier "screen.authentication"
    :gap 20
    :padding 32}
   [:heading {:level 1} "Logseq"]
   [:text "Sign in to connect your sync graphs."]
   [:button
    {:accessibility-identifier "button.hosted-sign-in"
     :disabled (reactive authentication-signing-in? model-source)
     :on-press (fn [_event] (send model/SignIn))}
    "Sign in"]
   [:if {:test (reactive authentication-error-present? model-source)}
    [:text
     {:value (reactive authentication-error-message model-source)
      :accessibility-identifier "text.authentication-error"}]]])

(defui chat-view [model-source send]
  [:drawer
   {:selected (reactive :sidebar-open model-source)
    :disabled (reactive sidebar-drag-disabled? model-source)
    :width 320
    :label "Navigation"
    :on-toggle
    (fn [input-event]
      (match input-event
        (proto/ToggleChanged _node open)
        (send (if open model/OpenSidebar model/CloseSidebar))
        _ true))}
   [:stack
    [:if {:test (reactive :composer-expanded model-source)}
     [composer-dismissal-surface send]]
    [native-navigation-view model-source send]
    [:if {:test (reactive authentication-screen-visible? model-source)}
     [authentication-screen model-source send]]]
   [sidebar-view model-source send]])
