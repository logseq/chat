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
    (ext/property "markup-json" ext/StringScalar true None)
    (ext/property "youtube-target-url" ext/StringScalar true None)]
   [(ext/event
     "open-node"
     [(ext/event-field "uuid" ext/StringScalar true)])]))

(defn extension-registry []
  (let [registry (ext/registry)]
    (ext/register-component! registry (outliner-editor-schema))
    (ext/register-component! registry (outliner-block-content-schema))
    registry))

(defn string-wire-value [value]
  (proto/StringValue value))

(defn int-wire-value [value]
  (proto/IntValue value))

(defn extension-string [values name]
  (match (clojure.core/get values name)
    (Some (proto/StringValue value)) value
    _ ""))

(defn extension-int [values name]
  (match (clojure.core/get values name)
    (Some (proto/IntValue value)) value
    _ 0))

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

(defn request-node-action [current uuid]
  (if (= (:search-open current) true)
    (model/RequestSearchNode uuid)
    (model/RequestAppNode uuid)))

(defn handle-outliner-block-content-event [input-event model-source send]
  (match input-event
    (proto/ExtensionEvent _node _identifier name values)
    (if (= name "open-node")
      (let [uuid (extension-string values "uuid")
            current (signal/sample model-source)]
        (send (request-node-action current uuid)))
      true)
    _ true))

(defn outliner-block-content-view
  [ui-context model-source title-source markup-source youtube-target-source send]
  (let [node (ui/extension! ui-context "outliner-block-content")]
    (ui/extension-property-signal!
     ui-context node "title" (reactive string-wire-value title-source))
    (ui/extension-property-signal!
     ui-context node "markup-json" (reactive string-wire-value markup-source))
    (ui/extension-property-signal!
     ui-context node "youtube-target-url"
     (reactive string-wire-value youtube-target-source))
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
    SyncingState "Syncing"
    SyncedState "Up to date"
    (FailedState reason) (str "Sync failed: " reason)))

(defn sidebar-page-identifier [page]
  (str "link.sidebar.page." (:uuid page)))

(defn sidebar-page-title [page]
  (:title page))

(defn favorites-empty? [current]
  (empty? (:favorites current)))

(defn recent-pages-empty? [current]
  (empty? (:recent-pages current)))

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
     :accessibility-identifier "button.graph-switch"}
    "Switch graph"]
   [:button
    {:label "Journals"
     :accessibility-identifier "link.sidebar.journals"
     :on-press (fn [_event] (send model/ShowJournals))}
    "Journals"]
   [:button
    {:label "Flashcards"
     :accessibility-identifier "link.sidebar.flashcards"
     :on-press (fn [_event] (send model/ShowFlashcards))}
    "Flashcards"]
   [:button
    {:label "Graphs"
     :accessibility-identifier "link.sidebar.graphs"}
    "Graphs"]
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

(defn search-result-identifier [hit]
  (let [_breadcrumb (:breadcrumb hit)]
    (str "search.result." (:uuid hit))))

(defn search-result-title [hit]
  (let [_breadcrumb (:breadcrumb hit)]
    (:title hit)))

(defn search-result-breadcrumb [hit]
  (:breadcrumb hit))

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

(defn outliner-row-uuid [row]
  (let [_depth (:depth row)]
    (:uuid row)))

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

(defn journal-root-visible? [current]
  (and (journals-destination? current)
       (node-navigation-inactive? current)))

(defn node-screen-visible? [current]
  (and (journals-destination? current)
       (node-navigation-active? current)))

(defn primary-sidebar-button-visible? [current]
  (not (node-screen-visible? current)))

(defn search-main-visible? [current]
  (and (journal-root-visible? current) (:search-open current)))

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

(defn back-from-node [current send]
  (if (empty? (:search-navigation-path current))
    (send model/BackAppNavigation)
    (send model/BackSearchNavigation)))

(defn editing-title [current]
  (match (:outliner-editing current)
    (Some editing) (:title editing)
    None ""))

(defn editing-caret [current]
  (match (:outliner-editing current)
    (Some editing) (:caret-utf16-offset editing)
    None 0))

(defn outliner-row [ui-context model-source row-source send]
  (let [row (signal/sample row-source)
        search-open (:search-open (signal/sample model-source))
        block-id-source (reactive outliner-row-uuid row-source)
        title-source (reactive outliner-row-title row-source)
        markup-source (reactive :markup-json row-source)
        youtube-target-source
        (reactive outliner-row-youtube-target row-source)
        editing-title-source (reactive editing-title model-source)
        editing-caret-source (reactive editing-caret model-source)
        indent-source (reactive outliner-row-indent row-source)
        editing-source (reactive row-editing? model-source row-source)
        selected-source (reactive row-selected? model-source row-source)
        not-editing-source
        (reactive row-not-editing? model-source row-source)
        has-children-source (reactive outliner-row-has-children row-source)]
    (elements/element
     ui-context nil
     [:list-item
      {:accessibility-identifier (outliner-row-identifier row)
       :selected selected-source
       :on-press
       (event [current-row row-source]
         (if (= (:opens-as-page current-row) true)
           (if search-open
             (send (model/RequestSearchNode (:uuid current-row)))
             (send (model/RequestAppNode (:uuid current-row))))
           (send (model/BeginOutlinerEdit (:uuid current-row)))))
       :on-long-press
       (event [current-row row-source]
         (send (model/LongPressOutlinerBlock (:uuid current-row))))}
      [:row {:gap 2 :padding-vertical 5}
       [outliner-indent-view indent-source]
       [:button
        {:label (reactive outliner-row-zoom-label row-source)
         :accessibility-identifier
         (str "button.outliner.zoom." (:uuid row))
         :on-press
         (event [current-row row-source]
           (send (model/ZoomOutlinerBlock (:uuid current-row))))}
        "•"]
       [:if {:test editing-source}
       [outliner-editor-view block-id-source
         editing-title-source editing-caret-source send]]
       [:if {:test not-editing-source}
        [outliner-block-content-view
         model-source title-source markup-source youtube-target-source send]]
       [:if {:test has-children-source}
        [:button
         {:text (reactive outliner-row-collapse-glyph row-source)
          :label (reactive outliner-row-collapse-label row-source)
          :accessibility-identifier
          (str "button.outliner.collapse." (:uuid row))
          :on-press
          (event [current-row row-source]
            (send (model/ToggleOutlinerCollapsed (:uuid current-row))))}]]]])))

(defui outliner-selection-toolbar [send]
  [:toolbar
   {:orientation "horizontal"
    :label "Outliner selection"
    :accessibility-identifier "toolbar.outliner.selection"
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
  (let [has-breadcrumb-source
        (reactive outliner-row-has-breadcrumb? row-source)]
    (elements/element
     ui-context nil
     [:column
      [:if {:test has-breadcrumb-source}
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
   [:button
    {:label "Back"
     :accessibility-identifier "button.outliner.zoom-out"
     :on-press
     (event [current model-source]
       (back-from-node current send))}
    "Back"]
   [:text
    {:value (reactive active-node-title model-source)
     :accessibility-identifier "title.node"}]
   [:list {:accessibility-identifier "list.outliner"}
    [:keyed
     {:source (reactive :outliner-rows model-source)
      :key :uuid
      :compare compare
      :as row-source}
     [outliner-row model-source row-source send]]]
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
   [:if {:test (reactive :composer-expanded model-source)}
    [:column
     [:textarea
      {:text (reactive :composer-draft model-source)
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

(defui chat-main-view [model-source send]
  [:column
   [:if {:test (reactive journal-root-visible? model-source)}
    [:text
     {:value (reactive main-title model-source)
      :accessibility-identifier "title.main"}]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [:text {:value (reactive graph-label model-source)}]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [:text {:value (reactive sync-label model-source)}]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [:button
     {:accessibility-identifier "button.search"
      :on-press (fn [_event] (send model/OpenSearch))}
     "Search"]]
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
     [:button
     {:accessibility-identifier "button.search.close"
       :on-press (fn [_event] (send model/CloseSearch))}
      "Close"]
     [:list
      [:keyed
       {:source (reactive :search-results model-source)
        :key :uuid
        :compare compare
        :as hit-source}
       [search-result-row hit-source send]]]]]
   [:if {:test (reactive journal-root-visible? model-source)}
    [:list {:accessibility-identifier "list.outliner"}
     [:keyed
      {:source (reactive :outliner-rows model-source)
       :key :uuid
       :compare compare
       :as row-source}
      [outliner-row model-source row-source send]]]]
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
   [:if {:test (reactive node-screen-visible? model-source)}
    [node-screen model-source send]]
   [:if {:test (reactive flashcards-destination? model-source)}
    [flashcard-screen model-source send]]
   [:if {:test (reactive primary-sidebar-button-visible? model-source)}
    [:button
     {:label "Open sidebar"
      :accessibility-identifier "button.sidebar"
      :on-press (fn [_event] (send model/OpenSidebar))}
     "Menu"]]])

(defui chat-view [model-source send]
  [:drawer
   {:selected (reactive :sidebar-open model-source)
    :width 320
    :label "Navigation"
    :on-toggle
    (fn [input-event]
      (match input-event
        (proto/ToggleChanged _node open)
        (send (if open model/OpenSidebar model/CloseSidebar))
        _ true))}
   [chat-main-view model-source send]
   [sidebar-view model-source send]])
