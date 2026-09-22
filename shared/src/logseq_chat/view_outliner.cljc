(ns logseq-chat.view-outliner
  (:require [logseq-chat.view-base :as base]
            [logseq-chat.view-rows :as rows]
            [logseq-chat.view-composer :as composer]
            [lui.elements :as elements]
            [lui.macros :refer [defui reactive event host?]]
            [lui.protocol :as proto :refer [TextChanged]]
            [lui.ui :as ui]
            [logseq-chat.model :as model]
            [signal.core :as signal]))

(defn outliner-editor-view [^ui/ui-context ui-context block-id-source title-source caret-source send]
  (let [node (ui/extension! ui-context "outliner-editor")
        block-id-value (reactive base/string-wire-value block-id-source)
        title-value (reactive base/string-wire-value title-source)
        caret-value (reactive base/int-wire-value caret-source)]
    (ui/extension-property-signal!
     ui-context node "block-id" block-id-value)
    (ui/extension-property-signal!
     ui-context node "title" title-value)
    (ui/extension-property-signal!
     ui-context node "caret-utf16-offset" caret-value)
    (ui/on-event!
     ui-context node
     (fn [input-event]
       (base/handle-outliner-editor-event input-event block-id-source send)))
    node))

(defn outliner-rich-block-view [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<string> title-source ^:signal<string> markup-source ^:signal<string> youtube-target-source ^:signal<bool> is-asset-source ^:signal<model/outline-row> row-source ^:signal<string> asset-type-source ^:signal<string> local-path-source send]
  (let [node (ui/extension! ui-context "outliner-block-content")]
    (ui/extension-property-signal!
     ui-context node "block-id" (reactive base/outliner-row-id-wire-value row-source))
    (ui/extension-property-signal!
     ui-context node "title" (reactive base/string-wire-value title-source))
    (ui/extension-property-signal!
     ui-context node "markup-json" (reactive base/string-wire-value markup-source))
    (ui/extension-property-signal!
     ui-context node "youtube-target-url"
     (reactive base/string-wire-value youtube-target-source))
    (ui/extension-property-signal!
     ui-context node "is-asset" (reactive base/bool-wire-value is-asset-source))
    (ui/extension-property-signal!
     ui-context node "is-completed"
     (reactive base/outliner-row-completed-wire-value row-source))
    (ui/extension-property-signal!
     ui-context node "asset-type" (reactive base/string-wire-value asset-type-source))
    (ui/extension-property-signal!
     ui-context node "local-path" (reactive base/string-wire-value local-path-source))
    (ui/on-event!
     ui-context node
     (fn [input-event]
       (base/handle-outliner-block-content-event input-event model-source send)))
    node))

(defn outliner-collapse-button [^ui/ui-context ui-context ^:signal<model/outline-row> row-source send]
  (let [row (signal/sample row-source)]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:button
        {:icon
         (reactive
          (fn [current-row]
            (base/outliner-collapse-icon-name (:is-collapsed current-row)))
          row-source)
         :label (reactive base/outliner-row-collapse-label row-source)
         :variant "ghost"
         :width 28
         :height 28
         :accessibility-identifier
         (base/outliner-collapse-identifier row)
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
         :label (reactive base/outliner-row-collapse-label row-source)
         :variant "ghost"
         :width 28
         :height 24
         :accessibility-identifier
         (base/outliner-collapse-identifier row)
         :on-press
         (event [current-row row-source]
                (send (model/ToggleOutlinerCollapsed (:uuid current-row))))}]))))

(defn outliner-indent-view [^ui/ui-context ui-context ^:signal<int> width-source]
  (let [node (ui/text! ui-context "")]
    (ui/int-property-signal!
     ui-context node proto/WidthValue width-source)
    node))

(defn breadcrumb-button [^ui/ui-context ui-context ^:signal<model/sidebar-page> breadcrumb-source ^:bool search-open send]
  (let [breadcrumb (signal/sample breadcrumb-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive base/breadcrumb-title breadcrumb-source)
       :variant "ghost"
       :class "caption"
       :foreground "muted-foreground"
       :accessibility-identifier (base/breadcrumb-identifier breadcrumb)
       :on-press
       (event [current-breadcrumb breadcrumb-source]
              (send (if search-open
                      (model/RequestSearchNode (:uuid current-breadcrumb))
                      (model/RequestAppNode (:uuid current-breadcrumb)))))}])))

(defn node-breadcrumb-button [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<model/sidebar-page> breadcrumb-source send]
  (let [search-open (:search-open (signal/sample model-source))]
    (breadcrumb-button ui-context breadcrumb-source search-open send)))

(defui node-breadcrumbs [^:signal<model/chat-model> model-source send]
  [:breadcrumb {:gap 5 :main "start"
                :accessibility-identifier "breadcrumb.node"}
   [:keyed
    {:source (reactive base/active-node-breadcrumbs model-source)
     :key base/breadcrumb-identifier
     :compare compare
     :as breadcrumb-source}
    [node-breadcrumb-button model-source breadcrumb-source send]]])

(defui related-row-breadcrumbs [^:signal<model/outline-row> row-source send]
  [:breadcrumb {:gap 5 :main "start"
                :accessibility-identifier "breadcrumb.related-blocks"}
   [:keyed
    {:source (reactive base/outliner-row-breadcrumbs row-source)
     :key base/breadcrumb-identifier
     :compare compare
     :as breadcrumb-source}
    [breadcrumb-button breadcrumb-source false send]]])

(defn outliner-tag [^ui/ui-context ui-context ^:signal<model/sidebar-page> tag-source send]
  (let [tag (signal/sample tag-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive base/outliner-tag-title tag-source)
       :label (reactive base/outliner-tag-title tag-source)
       :class "caption"
       :variant "ghost"
       :foreground "accent"
       :accessibility-identifier (base/outliner-tag-identifier tag)
       :on-press
       (event [current-tag tag-source]
              (send (model/RequestAppNode (:uuid current-tag))))}])))

(defn outliner-zoom-control [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<model/outline-row> row-source send search-open]
  (let [current (signal/sample model-source)
        row (signal/sample row-source)]
    (if (and (not search-open)
             (base/outliner-row-journal? current row))
      (if (= (ui/host ui-context) proto/FlutterHost)
        (elements/element
         ui-context nil
         [:row {:width 24 :height 24 :main "center" :cross "center"}
          [:box {:width 7 :height 7 :corner-radius 4 :background "border"
                 :accessibility-identifier
                 (str "outliner.bullet-glyph." (base/outliner-row-uuid row))}]])
        (elements/element
         ui-context nil
         [:icon
          {:name "app:outliner-bullet"
           :class "body-line"
           :foreground "border"
           :width 24
           :height 24
           :accessibility-identifier-signal
           (reactive base/outliner-row-zoom-identifier row-source)}]))
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
             (str "outliner.bullet-glyph." (base/outliner-row-uuid row))}]]
          [:button
           {:label (reactive base/outliner-row-zoom-label row-source)
            :accessibility-label (reactive base/outliner-row-zoom-label row-source)
            :variant "ghost"
            :width 24
            :height 24
            :accessibility-identifier-signal
            (reactive base/outliner-row-zoom-identifier row-source)
            :on-press
            (event [current-row row-source]
                   (if search-open
                     (send (model/RequestSearchNode (:uuid current-row)))
                     (send (model/RequestAppNode (:uuid current-row)))))}]])
        (elements/element
         ui-context nil
         [:button
          {:label (reactive base/outliner-row-zoom-label row-source)
           :accessibility-label (reactive base/outliner-row-zoom-label row-source)
           :icon "app:outliner-bullet"
           :size "icon"
           :class "body-line"
           :variant "ghost"
           :foreground "border"
           :width 24
           :height 24
           :accessibility-identifier-signal
           (reactive base/outliner-row-zoom-identifier row-source)
           :on-press
           (event [current-row row-source]
                  (if search-open
                    (send (model/RequestSearchNode (:uuid current-row)))
                    (send (model/RequestAppNode (:uuid current-row)))))}])))))

(defn outliner-status-control [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<model/outline-row> row-source send]
  (let [row (signal/sample row-source)]
    (if (= (ui/host ui-context) proto/FlutterHost)
      (elements/element
       ui-context nil
       [:stack {:width 24 :height 24}
        [:row {:width 24 :height 24 :main "center" :cross "center"}
         [:stack {:width 22 :height 22}
          [:if {:test (reactive base/outliner-task-status-backlog? row-source)}
           [:icon
            {:name "app:task-backlog" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (base/outliner-row-uuid row))}]]
          [:if {:test (reactive base/outliner-task-status-todo? row-source)}
           [:icon
            {:name "app:task-todo" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (base/outliner-row-uuid row))}]]
          [:if {:test (reactive base/outliner-task-status-doing? row-source)}
           [:icon
            {:name "app:task-doing" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (base/outliner-row-uuid row))}]]
          [:if {:test (reactive base/outliner-task-status-review? row-source)}
           [:icon
            {:name "app:task-review" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (base/outliner-row-uuid row))}]]
          [:if {:test (reactive base/outliner-task-status-done? row-source)}
           [:icon
            {:name "app:task-done" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (base/outliner-row-uuid row))}]]
          [:if {:test (reactive base/outliner-task-status-canceled? row-source)}
           [:icon
            {:name "app:task-canceled" :size "lg" :width 22 :height 22
             :foreground "foreground"
             :accessibility-identifier
             (str "outliner.task-status-icon." (base/outliner-row-uuid row))}]]]]
        [:button
         {:label (reactive base/outliner-row-status-title row-source)
          :variant "ghost"
          :size "icon"
          :width 24
          :height 24
          :accessibility-identifier "button.block-task-status"}
         [:context-menu
          [:keyed
           {:source (reactive base/model-task-statuses model-source)
            :key base/task-status-identifier
            :compare compare
            :as status-source}
           [composer/outliner-task-status-row (base/outliner-row-uuid row) status-source send]]]]])
      (elements/element
       ui-context nil
       [:button
        {:icon (reactive base/outliner-task-status-icon row-source)
         :label (reactive base/outliner-row-status-title row-source)
         :variant "ghost"
         :class "body-line"
         :foreground "secondary"
         :size "icon"
         :width 22
         :height 24
         :accessibility-identifier "button.block-task-status"}
        [:context-menu
         [:keyed
          {:source (reactive base/model-task-statuses model-source)
           :key base/task-status-identifier
           :compare compare
           :as status-source}
          [composer/outliner-task-status-row (base/outliner-row-uuid row) status-source send]]]]))))

(defn outliner-row-main-content [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<rows/retained-row> retained-row-source ^:signal<model/outline-row> row-source send]
  (let [row (signal/sample row-source)
        block-id-source (reactive base/outliner-row-uuid row-source)
        title-source (reactive base/outliner-row-title row-source)
        markup-source (reactive :markup-json row-source)
        youtube-target-source
        (reactive base/outliner-row-youtube-target row-source)
        is-asset-source (reactive :is-asset row-source)
        asset-type-source (reactive base/outliner-row-asset-type row-source)
        local-path-source (reactive base/outliner-row-local-path row-source)
        editing-title-source
        (reactive rows/retained-row-editing-title retained-row-source)
        editing-caret-source
        (reactive rows/retained-row-editing-caret retained-row-source)
        editing-source (reactive rows/retained-row-editing? retained-row-source)
        not-editing-source
        (reactive base/row-not-editing? model-source row-source)
        has-children-source (reactive base/outliner-row-has-children row-source)
        has-status-source (reactive base/outliner-row-has-status? row-source)
        has-tags-source (reactive base/outliner-row-has-tags? row-source)
        sync-failed-source (reactive base/outliner-row-sync-failed? row-source)]
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
         model-source ^:signal<string> title-source ^:signal<string> markup-source ^:signal<string> youtube-target-source
         is-asset-source row-source ^:signal<string> asset-type-source ^:signal<string> local-path-source send]]
       [:if {:test has-tags-source}
        [:row {:gap 6}
         [:keyed
          {:source (reactive base/outliner-row-tags row-source)
           :key base/outliner-tag-identifier
           :compare compare
           :as tag-source}
          [outliner-tag tag-source send]]]]
       [:if {:test sync-failed-source}
        [:text
         {:accessibility-identifier
          (str "outliner.sync-failed." (base/outliner-row-uuid row))}
         "Sync failed"]]]
      [:if {:test has-children-source}
       [:column {:cross "start"}
        [outliner-collapse-button row-source send]]]])))

(defn outliner-row-content [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<rows/retained-row> retained-row-source ^:signal<model/outline-row> row-source send search-open]
  (let [indent-source (reactive base/outliner-row-indent row-source)]
    (elements/element
     ui-context nil
     [:row {:gap 0 :cross "start" :padding-vertical 5}
      [outliner-indent-view indent-source]
      [outliner-zoom-control model-source row-source send search-open]
      [:box {:width 2}]
      [outliner-row-main-content model-source retained-row-source
       row-source send]])))

(defn outliner-row [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<rows/retained-row> retained-row-source ^:signal<model/outline-row> row-source send]
  (let [row (signal/sample row-source)
        search-open (:search-open (signal/sample model-source))
        selected-source (reactive base/row-selected? model-source row-source)]
    (if (base/outliner-row-list-item-press-enabled? (ui/host ui-context) row)
      (elements/element
       ui-context nil
       [:box
        {:accessibility-identifier-signal (reactive base/outliner-row-identifier row-source)
         :padding 0
         :corner-radius 10
         :selected selected-source}
        [:row {:gap 0 :cross "start" :padding-vertical 5}
         [outliner-indent-view (reactive base/outliner-row-indent row-source)]
         [outliner-zoom-control model-source row-source send search-open]
         [:box {:width 2}]
         [:list-item
          {:accessibility-identifier-signal
           (reactive base/outliner-row-action-identifier row-source)
           :label (reactive base/outliner-row-action-label model-source row-source)
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
        {:accessibility-identifier-signal (reactive base/outliner-row-identifier row-source)
         :label (reactive base/outliner-row-action-label model-source row-source)
         :padding 0
         :corner-radius 10
         :selected selected-source}
        [outliner-row-content model-source retained-row-source row-source
         send search-open]]))))

(defn outliner-entry [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<rows/retained-row> retained-row-source ^:signal<model/outline-row> row-source send]
  (elements/element
   ui-context nil
   [:column {:padding-horizontal 8}
    [:if {:test
          (reactive base/outliner-journal-divider-visible?
                    model-source row-source)}
     [:separator {:accessibility-identifier "journal.divider"}]]
    [:if {:test
          (reactive base/outliner-journal-heading-visible?
                    model-source row-source)}
     [:box
      {:padding 0
       :accessibility-identifier-signal
       (reactive base/outliner-journal-button-identifier
                 model-source row-source)}
      [:box {:padding-horizontal 8 :padding-vertical 12}
       [:box {:height 14}]
       [:heading
        {:level 3
         :class "scroll-section-title"
         :value (reactive base/outliner-journal-title
                          model-source row-source)}]]]]
    [outliner-row model-source retained-row-source row-source send]]))

(defn outliner-first-journal-section [^ui/ui-context ui-context ^:signal<model/chat-model> model-source send]
  (if (= (ui/host ui-context) proto/FlutterHost)
    (elements/element
     ui-context nil
     [:column
      {:accessibility-identifier
       (rows/first-journal-section-identifier (signal/sample model-source))}
      [:keyed
       {:source (reactive rows/first-journal-retained-rows model-source)
        :key rows/retained-row-identifier
        :compare compare
        :as retained-row-source}
       [outliner-entry model-source retained-row-source
        (reactive rows/retained-row-value retained-row-source) send]]])
    (elements/element
     ui-context nil
     [:column
      {:container-relative-frame "min-vertical"
       :container-relative-frame-inset 136
       :accessibility-identifier
       (rows/first-journal-section-identifier (signal/sample model-source))}
      [:keyed
       {:source (reactive rows/first-journal-retained-rows model-source)
        :key rows/retained-row-identifier
        :compare compare
        :as retained-row-source}
       [outliner-entry model-source retained-row-source
        (reactive rows/retained-row-value retained-row-source) send]]])))

(defn outliner-selection-toolbar [^ui/ui-context ui-context send]
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

(defn outliner-autocomplete-row [^ui/ui-context ui-context ^:signal<model/outliner-autocomplete-candidate> candidate-source send]
  (let [candidate (signal/sample candidate-source)]
    (elements/element
     ui-context nil
     [:button
      {:text (reactive base/outliner-autocomplete-label candidate-source)
       :label (reactive base/outliner-autocomplete-label candidate-source)
       :variant "ghost"
       :grow (if (host? proto/FlutterHost) 0.0 1.0)
       :height 44
       :padding-horizontal 10
       :background "autocomplete-row-background"
       :foreground "foreground"
       :corner-radius 8
       :text-alignment "start"
       :accessibility-identifier
       (base/outliner-autocomplete-identifier candidate)
       :on-press
       (event [current-candidate candidate-source]
              (send
               (model/ChooseOutlinerAutocomplete
                (:value current-candidate))))}])))

(defui outliner-autocomplete-bar [^:signal<model/chat-model> model-source send]
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
     {:source (reactive base/model-outliner-autocomplete-candidates model-source)
      :key base/outliner-autocomplete-identifier
      :compare compare
      :as candidate-source}
     [outliner-autocomplete-row candidate-source send]]]])

(defn outliner-editor-toolbar [^ui/ui-context ui-context ^:signal<model/chat-model> model-source send]
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
     :label (reactive base/outliner-editor-task-label model-source)
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
       :class "scroll-leading leading-inset-8"
       :height 50
       :gap 4}
      [:button
       {:icon "app:toolbar-task"
        :variant "ghost"
        :width 38
        :height 42
        :label (reactive base/outliner-editor-task-label model-source)
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

(defn node-related-row [^ui/ui-context ui-context ^:signal<model/chat-model> model-source ^:signal<model/outline-row> row-source send]
  (let [structured-breadcrumb-source
        (reactive base/outliner-row-structured-breadcrumb? row-source)
        fallback-breadcrumb-source
        (reactive base/outliner-row-fallback-breadcrumb? row-source)
        retained-row-source
        (reactive rows/make-retained-outline-row model-source row-source)]
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
        [:text {:value (reactive base/outliner-row-breadcrumb row-source)
                :class "caption"
                :foreground "muted-foreground"}]]]
      [outliner-row model-source retained-row-source row-source send]])))

(defui related-section-heading [title]
  [:box {:padding-horizontal 8}
   [:text {:class "subheadline"
           :foreground "muted-foreground"
           :accessibility-identifier "title.related-section"}
    title]])

(defui node-related-section [^:signal<model/chat-model> model-source send]
  [:column
   {:gap 0
    :accessibility-identifier "section.node.linked-references"}
   [:box {:height 26}]
   [related-section-heading "Linked references"]
   [:box {:height 8}]
   [:column {:accessibility-identifier "list.node.related"}
    [:keyed
     {:source (reactive base/active-node-related-rows model-source)
      :key base/outliner-row-identifier
      :compare compare
      :as row-source}
     [node-related-row model-source row-source send]]]])

(defui node-tagged-section [^:signal<model/chat-model> model-source send]
  [:column
   {:gap 0
    :accessibility-identifier "section.tag.tagged-nodes"}
   [:box {:height 26}]
   [related-section-heading "Tagged nodes"]
   [:box {:height 8}]
   [:if {:test (reactive base/node-tag-section-empty? model-source)}
    [:box {:padding-horizontal 8}
     [:text {:foreground "muted-foreground"} "No tagged nodes"]]]
   [:column {:accessibility-identifier "list.node.tagged"}
    [:keyed
     {:source (reactive base/active-node-related-rows model-source)
      :key base/outliner-row-identifier
      :compare compare
      :as row-source}
     [node-related-row model-source row-source send]]]])

(defui node-linked-reference-section [^:signal<model/chat-model> model-source send]
  [:column
   {:gap 0
    :accessibility-identifier "section.node.linked-references"}
   [:box {:height 26}]
   [related-section-heading "Linked references"]
   [:box {:height 8}]
   [:column {:accessibility-identifier "list.node.linked-references"}
    [:keyed
     {:source (reactive base/active-node-linked-reference-rows model-source)
      :key base/outliner-row-identifier
      :compare compare
      :as row-source}
     [node-related-row model-source row-source send]]]])

(defui add-first-block-button [^:signal<model/chat-model> model-source send]
  [:box {:padding-horizontal 8}
   [:button
    {:label "Add first block"
     :accessibility-identifier "button.outliner.add-first-block"
     :on-press
     (event [current model-source]
            (send (model/AddRootBlock (base/active-node-page-uuid current))))}
    "Add first block"]])

(defui node-screen [^:signal<model/chat-model> model-source send]
  [:column
   {:accessibility-identifier "screen.node"
    :grow (if (host? proto/FlutterHost) 1.0 0.0)}
   [:scroll {:grow 1.0 :accessibility-identifier "scroll.outliner"}
    [:column {:gap 0 :padding-horizontal 8}
     [:box {:height 16}]
     [:if {:test (reactive base/active-node-has-breadcrumbs? model-source)}
      [:box {:padding-horizontal 8}
       [node-breadcrumbs model-source send]]]
     [:if {:test (reactive base/node-title-visible? model-source)}
      [:column {:gap 0}
       [:box {:height 26}]
       [:box
        {:padding-horizontal 8
         :accessibility-identifier "layout.node.title"}
        [:heading
         {:level 3
          :value (reactive base/active-node-title model-source)
          :accessibility-identifier "title.node"}]]
       [:box {:height 12}]]]
     [:if {:test (reactive base/node-outliner-visible? model-source)}
      [:column {:accessibility-identifier "list.outliner"}
       [:keyed
        {:source (reactive rows/retained-outliner-rows model-source)
         :key rows/retained-row-identifier
         :compare compare
         :as retained-row-source}
        [outliner-row model-source retained-row-source
         (reactive rows/retained-row-value retained-row-source) send]]]]
     [:if {:test (reactive base/node-can-add-first-block? model-source)}
      [add-first-block-button model-source send]]
     [:if {:test (reactive base/node-related-section-visible? model-source)}
      [node-related-section model-source send]]
     [:if {:test (reactive base/node-tag-section-visible? model-source)}
      [node-tagged-section model-source send]]
     [:if {:test (reactive base/node-linked-reference-section-visible? model-source)}
      [node-linked-reference-section model-source send]]
     [:box {:height 120}]]]])
