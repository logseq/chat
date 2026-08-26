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

(defn extension-registry []
  (let [registry (ext/registry)]
    (ext/register-component! registry (outliner-editor-schema))
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
       [:text {:value (reactive :breadcrumb hit-source)}]]])))

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

(defn search-main-visible? [current]
  (and (node-navigation-inactive? current) (:search-open current)))

(defn main-outliner-selection-active? [current]
  (and (node-navigation-inactive? current)
       (outliner-selection-active? current)))

(defn main-outliner-autocomplete-active? [current]
  (and (node-navigation-inactive? current)
       (outliner-autocomplete-active? current)))

(defn main-outliner-editor-active? [current]
  (and (node-navigation-inactive? current)
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
        block-id-source (reactive outliner-row-uuid row-source)
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
         (send (model/BeginOutlinerEdit (:uuid current-row))))
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
        [:text {:value (reactive outliner-row-title row-source)}]]
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
   [:list {:accessibility-identifier "outliner.list"}
    [:keyed
     {:source (reactive :outliner-rows model-source)
      :key :uuid
      :compare compare
      :as row-source}
     [outliner-row model-source row-source send]]]
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

(defui chat-view [model-source send]
  [:column
   [:if {:test (reactive node-navigation-inactive? model-source)}
    [:heading {:level 1} "Logseq"]]
   [:if {:test (reactive node-navigation-inactive? model-source)}
    [:text {:value (reactive graph-label model-source)}]]
   [:if {:test (reactive node-navigation-inactive? model-source)}
    [:text {:value (reactive sync-label model-source)}]]
   [:if {:test (reactive node-navigation-inactive? model-source)}
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
   [:if {:test (reactive node-navigation-inactive? model-source)}
    [:list {:accessibility-identifier "outliner.list"}
     [:keyed
      {:source (reactive :outliner-rows model-source)
       :key :uuid
       :compare compare
       :as row-source}
      [outliner-row model-source row-source send]]]]
   [:if {:test (reactive main-outliner-selection-active? model-source)}
    [outliner-selection-toolbar send]]
   [:if {:test (reactive main-outliner-autocomplete-active? model-source)}
    [outliner-autocomplete-bar model-source send]]
   [:if {:test (reactive main-outliner-editor-active? model-source)}
    [outliner-editor-toolbar send]]
   [:if {:test (reactive node-navigation-inactive? model-source)}
    [composer-view model-source send]]
   [:if {:test (reactive node-navigation-active? model-source)}
    [node-screen model-source send]]])
