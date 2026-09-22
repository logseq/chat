(ns logseq-chat.view-base
  (:require [clojure.string :as string]
            [lui.protocol :as proto :refer [TextChanged]]
            [logseq-chat.model :as model]
            [signal.core :as signal]))

(defn string-wire-value [^:string value]
  (proto/StringValue value))

(defn int-wire-value [^:int value]
  (proto/IntValue value))

(defn bool-wire-value [value]
  (proto/BoolValue value))

(defn outliner-row-id-wire-value [^model/outline-row row]
  (proto/StringValue (outliner-row-uuid row)))

(defn outliner-row-completed-wire-value [^model/outline-row row]
  (proto/BoolValue (outliner-row-completed? row)))

(defn extension-string [values ^:string name]
  (match (clojure.core/get values name)
    (Some (proto/StringValue value)) value
    _ ""))

(defn extension-int [values ^:string name]
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

(defn handle-outliner-editor-event [input-event ^:signal<string> block-id-source send]
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

(defn optional-string [^:option<string> value]
  (match value
    (Some current) current
    None ""))

(defn outliner-row-youtube-target [^model/outline-row row]
  (optional-string (:youtube-target-url row)))

(defn outliner-row-asset-type [^model/outline-row row]
  (optional-string (:asset-type row)))

(defn outliner-row-local-path [^model/outline-row row]
  (optional-string (:local-path row)))

(defn outliner-row-completed? [^model/outline-row row]
  (match (:status row)
    (Some status)
    (match (:ident status)
      (Some ident)
      (or (string/ends-with? ident ".done")
          (string/ends-with? ident ".canceled"))
      None false)
    None false))

(defn outliner-row-uuid [^model/outline-row row]
  (let [_depth (:depth row)]
    (:uuid row)))

(defn request-node-action [^model/chat-model current ^:string uuid]
  (if (= (:search-open current) true)
    (model/RequestSearchNode uuid)
    (model/RequestAppNode uuid)))

(defn handle-outliner-block-content-event [input-event ^:signal<model/chat-model> model-source send]
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

(defn graph-label [^model/chat-model current]
  (match (:selected-graph current)
    (Some graph-name) graph-name
    None "No graph selected"))

(defn sync-label [^model/chat-model current]
  (match (:sync-state current)
    OfflineState "Offline"
    (FailedState reason) (str "Sync failed: " reason)
    _ (if (or (:has-pending-semantic-operations current)
              (:has-pending-sync-request current))
        "Syncing"
        (match (:sync-state current)
          SyncedState "Up to date"
          _ "Syncing"))))

(defn sync-indicator-label [^model/chat-model current]
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

(defn sync-accessibility-identifier [^model/chat-model current]
  (match (:sync-state current)
    (FailedState _reason) "sync.failed"
    OfflineState "sync.disconnected"
    _ "sync.connected"))

(defn sync-indicator-foreground [^model/chat-model current]
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

(defn sync-connection-label [^model/chat-model current]
  (match (:sync-state current)
    OfflineState "Disconnected"
    _ "Connected"))

(defn sync-pending-label [^model/chat-model current]
  (if (or (:has-pending-semantic-operations current)
          (:has-pending-sync-request current))
    "Waiting to save"
    "Saved"))

(defn sync-cursor-label [^model/chat-model current]
  (match (:applied-server-t current)
    (Some cursor) (str cursor)
    None "Unavailable"))

(defn active-page-actions-visible? [^model/chat-model current]
  (match (model/active-page current)
    (Some _page) true
    None false))

(defn connection-settings-visible? [^model/chat-model current]
  (not (active-page-actions-visible? current)))

(defn active-page-favorite-label [^model/chat-model current]
  (match (model/active-page current)
    (Some page)
    (if (model/page-is-favorite? current (:uuid page))
      "Unfavorite"
      "Favorite")
    None "Favorite"))

(defn page-deletion-pending? [^model/chat-model current]
  (match (:pending-page-deletion current)
    (Some _page) true
    None false))

(defn sidebar-page-identifier [^model/sidebar-page page]
  (str "link.sidebar.page." (:uuid page)))

(defn sidebar-page-title [^model/sidebar-page page]
  (:title page))

(defn sidebar-graph-identifier [^model/graph graph]
  (str "menu.graph." (:id graph)))

(defn graph-title [^model/graph graph]
  (:name graph))

(defn sidebar-graph-selected? [^model/chat-model current ^model/graph graph]
  (match (:selected-graph-id current)
    (Some graph-id) (= graph-id (:id graph))
    None false))

(defn sidebar-graph-disabled? [^model/graph graph]
  (not (:is-ready graph)))

(defn favorites-empty? [^model/chat-model current]
  (empty? (:favorites current)))

(defn recent-pages-empty? [^model/chat-model current]
  (empty? (:recent-pages current)))

(defn sidebar-favorites [^model/chat-model current]
  (:favorites current))

(defn sidebar-recent-pages [^model/chat-model current]
  (:recent-pages current))

(defn model-task-statuses [^model/chat-model current]
  (:task-statuses current))

(defn model-outliner-autocomplete-candidates [^model/chat-model current]
  (:outliner-autocomplete-candidates current))

(defn model-composer-assets [^model/chat-model current]
  (:composer-assets current))

(defn model-language-choices [^model/chat-model current]
  (:language-choices current))

(defn model-community-links [^model/chat-model current]
  (:community-links current))

(defn model-graph-menu-open? [^model/chat-model current]
  (:graph-menu-open current))

(defn model-task-status-picker-open? [^model/chat-model current]
  (:task-status-picker-open current))

(defn model-new-graph-name [^model/chat-model current]
  (:new-graph-name current))

(defn model-new-graph-encrypted? [^model/chat-model current]
  (:new-graph-encrypted current))

(defn model-graph-password [^model/chat-model current]
  (:graph-password current))

(defn model-graphs [^model/chat-model current]
  (:graphs current))

(defn model-settings-language-menu-open? [^model/chat-model current]
  (:settings-language-menu-open current))

(defn model-settings-appearance-menu-open? [^model/chat-model current]
  (:settings-appearance-menu-open current))

(defn model-search-loading? [^model/chat-model current]
  (:search-loading current))

(defn model-search-query [^model/chat-model current]
  (:search-query current))

(defn model-search-open? [^model/chat-model current]
  (:search-open current))

(defn model-settings-open? [^model/chat-model current]
  (:settings-open current))

(defn model-create-graph-open? [^model/chat-model current]
  (:create-graph-open current))

(defn model-graph-password-open? [^model/chat-model current]
  (:graph-password-open current))

(defn model-sync-details-open? [^model/chat-model current]
  (:sync-details-open current))

(defn journals-sidebar-selected? [^model/chat-model current]
  (and
   (= (:destination current) model/JournalsDestination)
   (match (:selected-page current)
     None true
     (Some _page) false)))

(defn flashcards-sidebar-selected? [^model/chat-model current]
  (= (:destination current) model/FlashcardsDestination))

(defn graphs-sidebar-selected? [^model/chat-model current]
  (= (:destination current) model/GraphsDestination))

(defn sidebar-page-selected? [^model/chat-model current ^model/sidebar-page page]
  (and (= (:destination current) model/JournalsDestination)
       (match (:selected-page current)
         (Some selected) (= (:uuid selected) (:uuid page))
         None false)))

(defn sidebar-tab-visible? [^model/chat-model current ^:string tab]
  (model/string-vector-contains? (:sidebar-tabs current) tab))

(defn flashcards-tab-visible? [^model/chat-model current]
  (sidebar-tab-visible? current "flashcards"))

(defn graphs-tab-visible? [^model/chat-model current]
  (sidebar-tab-visible? current "graphs"))

(defn composer-collapsed? [^model/chat-model current]
  (not (:composer-expanded current)))

(defn composer-send-disabled? [^model/chat-model current]
  (or (model/composer-assets-sending? current)
      (and (string/blank? (:composer-draft current))
           (empty? (:composer-assets current)))))

(defn task-status-identifier [^model/task-status status]
  (str "button.task-status.option." (:uuid status)))

(defn task-status-title [^model/task-status status]
  (:title status))

(defn task-status-style [^model/task-status status]
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

(defn task-status-icon-name [^model/task-status status]
  (case (task-status-style status)
    "backlog" "app:task-backlog"
    "doing" "app:task-doing"
    "in-review" "app:task-review"
    "done" "app:task-done"
    "canceled" "app:task-canceled"
    "app:task-todo"))

(defn task-status-foreground [^model/task-status status]
  (match (:icon-color status)
    (Some color) color
    None (str "task-" (task-status-style status))))

(defn task-status-selected? [^model/chat-model current]
  (match (:selected-task-status current)
    (Some _status) true
    None false))

(defn search-result-identifier [^model/search-hit hit]
  (let [_breadcrumb (:breadcrumb hit)]
    (str "search.result." (:uuid hit))))

(defn search-result-title [^model/search-hit hit]
  (let [_breadcrumb (:breadcrumb hit)]
    (:title hit)))

(defn search-result-breadcrumb [^model/search-hit hit]
  (:breadcrumb hit))

(defn page-search-results [^model/chat-model current]
  (filterv (fn [hit] (:is-page hit)) (:search-results current)))

(defn block-search-results [^model/chat-model current]
  (filterv (fn [hit] (not (:is-page hit))) (:search-results current)))

(defn page-search-results-present? [^model/chat-model current]
  (not (empty? (page-search-results current))))

(defn block-search-results-present? [^model/chat-model current]
  (not (empty? (block-search-results current))))

(defn search-empty-state-present? [^model/chat-model current]
  (and (not (:search-loading current)) (empty? (:search-results current))))

(defn search-results-present? [^model/chat-model current]
  (not (empty? (:search-results current))))

(defn search-result-status [^model/chat-model current]
  (if (:search-loading current)
    "Searching…"
    (if (string/blank? (:search-query current))
      ""
      (let [total (count (:search-results current))]
        (str total (if (= total 1) " result" " results"))))))

(defn search-result-context-present? [^model/search-hit hit]
  (not (string/blank? (:breadcrumb hit))))

(defn search-empty-message [^model/chat-model current]
  (if (string/blank? (:search-query current))
    "Search your graph"
    "No results"))

(defn search-empty-supporting-message [query]
  (if (string/blank? query)
    "Find pages and blocks by title or content."
    "Try a different keyword."))

(defn outliner-row-identifier [^model/outline-row row]
  (let [_depth (:depth row)]
    (str "outliner.block." (:uuid row))))

(defn outliner-row-breadcrumbs [^model/outline-row row]
  (:breadcrumbs row))

(defn outliner-row-tags [^model/outline-row row]
  (:tags row))

(defn outliner-row-action-identifier [^model/outline-row row]
  (let [_depth (:depth row)]
    (str "outliner.block-action." (:uuid row))))

(defn outliner-row-title [^model/outline-row row]
  (let [_depth (:depth row)]
    (:title row)))

(defn outliner-row-indent [^model/outline-row row]
  (* (:depth row) 22))

(defn outliner-row-has-children [^model/outline-row row]
  (:has-children row))

(defn outliner-row-zoom-label [^model/outline-row row]
  (str "Zoom into "
       (if (empty? (:title row)) "Untitled block" (:title row))))

(defn outliner-row-zoom-identifier [^model/outline-row row]
  (str "button.outliner.zoom."
       (:uuid row)
       "."
       (if (empty? (:title row)) "Untitled block" (:title row))))

(defn outliner-row-action-label [^model/chat-model current ^model/outline-row row]
  (str (if (empty? (:outliner-selected-block-ids current))
         "Edit block "
         "Select block ")
       (if (empty? (:title row)) "Untitled block" (:title row))))

(defn outliner-row-collapse-label [^model/outline-row row]
  (str (if (:is-collapsed row) "Expand " "Collapse ")
       (if (empty? (:title row)) "Untitled block" (:title row))))

(defn outliner-row-collapse-glyph [^model/outline-row row]
  (if (:is-collapsed row) "›" "⌄"))

(defn outliner-collapse-icon-name [^:bool collapsed?]
  (if collapsed? "app:chevron-right" "app:chevron-down"))

(defn outliner-collapse-identifier [^model/outline-row row]
  (str "button.outliner.collapse." (:uuid row)))

(defn row-editing? [^model/chat-model current ^model/outline-row row]
  (match (:outliner-editing current)
    (Some editing) (= (:uuid editing) (:uuid row))
    None false))

(defn row-not-editing? [^model/chat-model current ^model/outline-row row]
  (not (row-editing? current row)))

(defn string-vector-contains? [^:vector<string> values ^:string target]
  (loop [index 0]
    (if (= index (count values))
      false
      (if (= (nth values index) target)
        true
        (recur (inc index))))))

(defn row-selected? [^model/chat-model current ^model/outline-row row]
  (string-vector-contains?
   (:outliner-selected-block-ids current) (:uuid row)))

(defn outliner-selection-active? [^model/chat-model current]
  (not (empty? (:outliner-selected-block-ids current))))

(defn outliner-selection-inactive? [^model/chat-model current]
  (empty? (:outliner-selected-block-ids current)))

(defn outliner-editor-active? [^model/chat-model current]
  (and (outliner-selection-inactive? current)
       (match (:outliner-editing current)
         (Some _editing) true
         None false)))

(defn outliner-autocomplete-active? [^model/chat-model current]
  (and (outliner-editor-active? current)
       (match (:outliner-autocomplete current)
         (Some _autocomplete)
         (not (empty? (:outliner-autocomplete-candidates current)))
         None false)))

(defn outliner-autocomplete-identifier [^model/outliner-autocomplete-candidate candidate]
  (str "button.outliner.autocomplete." (:index candidate)))

(defn outliner-autocomplete-label [^model/outliner-autocomplete-candidate candidate]
  (:label candidate))

(defn node-navigation-active? [^model/chat-model current]
  (not (empty? (:app-navigation-path current))))

(defn node-navigation-inactive? [^model/chat-model current]
  (empty? (:app-navigation-path current)))

(defn journals-destination? [^model/chat-model current]
  (= (:destination current) model/JournalsDestination))

(defn flashcards-destination? [^model/chat-model current]
  (= (:destination current) model/FlashcardsDestination))

(defn graphs-destination? [^model/chat-model current]
  (= (:destination current) model/GraphsDestination))

(defn graph-selected? [^model/chat-model current]
  (or
   (match (:selected-graph-id current)
     (Some _graph-id) true
     None false)
   (match (:selected-graph current)
     (Some _graph-name) true
     None false)))

(defn graph-picker-visible? [^model/chat-model current]
  (and (journals-destination? current)
       (not (:graph-loading current))
       (not (graph-selected? current))))

(defn graph-loading-visible? [^model/chat-model current]
  (and (journals-destination? current)
       (:graph-loading current)
       (empty? (:outliner-rows current))))

(defn graph-loading-message [^model/chat-model current]
  (if (graph-selected? current) "Loading journals" "Loading graphs"))

(defn selected-graph-local? [^model/chat-model current]
  (match (:selected-graph-id current)
    (Some graph-id) (model/graph-local? current graph-id)
    None false))

(defn journal-route-active? [^model/chat-model current]
  (and (journals-destination? current)
       (graph-selected? current)
       (or (not (:graph-loading current))
           (not (empty? (:outliner-rows current))))
       (node-navigation-inactive? current)))

(defn journal-root-visible? [^model/chat-model current]
  (and (journal-route-active? current) (not (:search-open current))))

(defn journal-home-visible? [^model/chat-model current]
  (and (journal-root-visible? current) (selected-page-absent? current)))

(defn selected-page-visible? [^model/chat-model current]
  (and (journal-root-visible? current) (selected-page-present? current)))

(defn selected-page-models [^model/chat-model current]
  (if (selected-page-visible? current) [current] []))

(defn selected-page-model-key [^model/chat-model current]
  (match (:selected-page current)
    (Some page) (:uuid page)
    None ""))

(defn journal-tree-retained? [^model/chat-model current]
  (and (graph-selected? current)
       (or (not (:graph-loading current))
           (not (empty? (:outliner-rows current))))))

(defn older-journals-visible? [^model/chat-model current]
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

(defn outliner-journal-marker [^model/chat-model current ^model/outline-row row]
  (journal-section-marker-for
   (:outliner-section-markers current) (:uuid row)))

(defn outliner-journal-heading-visible? [^model/chat-model current ^model/outline-row row]
  (and
   (journal-root-visible? current)
   (match (:selected-page current)
     None
     (match (outliner-journal-marker current row)
       (Some _marker) true
       None false)
     (Some _page) false)))

(defn outliner-journal-divider-visible? [^model/chat-model current ^model/outline-row row]
  (match (outliner-journal-marker current row)
    (Some marker) (:has-divider marker)
    None false))

(defn outliner-journal-title [^model/chat-model current ^model/outline-row row]
  (match (outliner-journal-marker current row)
    (Some marker) (:title marker)
    None ""))

(defn outliner-journal-page-id [^model/chat-model current ^model/outline-row row]
  (match (outliner-journal-marker current row)
    (Some marker) (:page-id marker)
    None ""))

(defn outliner-journal-button-identifier [^model/chat-model current ^model/outline-row row]
  (str "button.journal." (outliner-journal-page-id current row)))

(defn outliner-journal-accessibility-label [^model/chat-model current ^model/outline-row row]
  (str "Open " (outliner-journal-title current row)))

(defn node-screen-visible? [^model/chat-model current]
  (and (journals-destination? current)
       (node-navigation-active? current)))

(defn primary-sidebar-button-visible? [^model/chat-model current]
  (and (not (node-screen-visible? current))
       (not (graph-loading-visible? current))
       (not (graph-picker-visible? current))
       (not (:search-open current))
       (not (= (:authentication-state current) "signedOut"))
       (not (= (:authentication-state current) "signingIn"))))

(defn sidebar-drag-disabled? [^model/chat-model current]
  (and (not (:sidebar-open current))
       (or (not (primary-sidebar-button-visible? current))
           (not (empty? (:app-navigation-path current)))
           (outliner-editor-active? current)
           (outliner-selection-active? current))))

(defn connection-control-visible? [^model/chat-model current]
  (and (not (:search-open current))
       (not (graph-picker-visible? current))
       (not (= (:authentication-state current) "signedOut"))
       (not (= (:authentication-state current) "signingIn"))))

(defn search-query-present? [^model/chat-model current]
  (not (empty? (:search-query current))))

(defn bottom-chrome-presentation [^model/chat-model current]
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

(defn bottom-chrome-selection? [^model/chat-model current]
  (= (bottom-chrome-presentation current) "outliner-selection"))

(defn bottom-chrome-editor? [^model/chat-model current]
  (= (bottom-chrome-presentation current) "outliner-editor"))

(defn bottom-chrome-expanded-composer? [^model/chat-model current]
  (= (bottom-chrome-presentation current) "expanded-composer"))

(defn bottom-chrome-capture-and-search? [^model/chat-model current]
  (= (bottom-chrome-presentation current) "capture-and-search"))

(defn bottom-chrome-occupies-layout-space? [^model/chat-model current]
  (bottom-chrome-editor? current))

(defn active-node-projection [^model/chat-model current]
  (last (:node-routes current)))

(defn node-projection-identifier [^model/node-projection route]
  (:uuid route))

(defn active-node-uuid [^model/chat-model current]
  (match (active-node-projection current)
    (Some route) (:uuid route)
    None ""))

(defn active-node-breadcrumbs [^model/chat-model current]
  (match (active-node-projection current)
    (Some route)
    (match (first (filterv (fn [row] (= (:uuid row) (:uuid route)))
                          (:outliner-rows route)))
      (Some row) (:breadcrumbs row)
      None [])
    None []))

(defn active-node-has-breadcrumbs? [^model/chat-model current]
  (not (empty? (active-node-breadcrumbs current))))

(defn active-node-title [^model/chat-model current]
  (match (active-node-projection current)
    (Some route) (:title route)
    None "Untitled"))

(defn main-title [^model/chat-model current]
  (if (= (:destination current) model/FlashcardsDestination)
    "Flashcards"
    (if (= (:destination current) model/GraphsDestination)
      "Graphs"
      (match (model/active-page current)
        (Some page) (:title page)
        None ""))))

(defn current-content-active? [^model/chat-model current]
  (match (active-node-projection current)
    (Some _route) true
    None
    (match (:selected-page current)
      (Some _page) true
      None false)))

(defn current-content-is-tag? [^model/chat-model current]
  (match (active-node-projection current)
    (Some route) (:is-tag route)
    None (:selected-page-is-tag current)))

(defn current-content-is-property? [^model/chat-model current]
  (match (active-node-projection current)
    (Some route) (:is-property route)
    None (:selected-page-is-property current)))

(defn active-node-page-uuid [^model/chat-model current]
  (match (active-node-projection current)
    (Some route) (:page-uuid route)
    None
    (match (:selected-page current)
      (Some page) (:uuid page)
      None "")))

(defn active-node-related-rows [^model/chat-model current]
  (match (active-node-projection current)
    (Some route) (:related-rows route)
    None (:related-rows current)))

(defn active-node-linked-reference-rows [^model/chat-model current]
  (match (active-node-projection current)
    (Some route) (:linked-reference-rows route)
    None (:linked-reference-rows current)))

(defn node-related-section-visible? [^model/chat-model current]
  (and (current-content-active? current)
       (not (current-content-is-tag? current))
       (not (empty? (active-node-related-rows current)))))

(defn node-tag-section-visible? [^model/chat-model current]
  (and (current-content-active? current)
       (current-content-is-tag? current)))

(defn node-tag-section-empty? [^model/chat-model current]
  (and (node-tag-section-visible? current)
       (empty? (active-node-related-rows current))))

(defn node-linked-reference-section-visible? [^model/chat-model current]
  (not (empty? (active-node-linked-reference-rows current))))

(defn node-can-add-first-block? [^model/chat-model current]
  (and (current-content-active? current)
       (empty? (:outliner-rows current))
       (not (current-content-is-tag? current))
       (not (current-content-is-property? current))))

(defn node-outliner-visible? [^model/chat-model current]
  (not (empty? (:outliner-rows current))))

(defn node-title-visible? [^model/chat-model current]
  (and (node-outliner-visible? current)
       (not (current-content-is-tag? current))
       (not (and (:search-open current)
                 (not (= (active-node-uuid current) (active-node-page-uuid current)))))))

(defn main-can-add-first-block? [^model/chat-model current]
  (and (journal-root-visible? current)
       (node-can-add-first-block? current)))

(defn main-related-section-visible? [^model/chat-model current]
  (and (journal-root-visible? current)
       (node-related-section-visible? current)))

(defn main-tag-section-visible? [^model/chat-model current]
  (and (journal-root-visible? current)
       (node-tag-section-visible? current)))

(defn main-linked-reference-section-visible? [^model/chat-model current]
  (and (journal-root-visible? current)
       (node-linked-reference-section-visible? current)))

(defn outliner-row-has-breadcrumb? [^model/outline-row row]
  (not (empty? (:breadcrumb row))))

(defn outliner-row-breadcrumb [^model/outline-row row]
  (:breadcrumb row))

(defn outliner-row-structured-breadcrumb? [^model/outline-row row]
  (not (empty? (:breadcrumbs row))))

(defn outliner-row-fallback-breadcrumb? [^model/outline-row row]
  (and (empty? (:breadcrumbs row))
       (outliner-row-has-breadcrumb? row)))

(defn breadcrumb-identifier [^model/sidebar-page breadcrumb]
  (str "button.breadcrumb." (:uuid breadcrumb)))

(defn breadcrumb-title [^model/sidebar-page breadcrumb]
  (:title breadcrumb))

(defn editing-title [^model/chat-model current]
  (match (:outliner-editing current)
    (Some editing) (:title editing)
    None ""))

(defn editing-caret [^model/chat-model current]
  (match (:outliner-editing current)
    (Some editing) (:caret-utf16-offset editing)
    None 0))

(defn outliner-row-has-status? [^model/outline-row row]
  (match (:status row)
    (Some _status) true
    None false))

(defn outliner-row-status-title [^model/outline-row row]
  (match (:status row)
    (Some status) (:title status)
    None ""))

(defn outliner-task-status-icon [^model/outline-row row]
  (match (:status row)
    (Some status) (task-status-icon-name status)
    None "app:task-todo"))

(defn outliner-task-status-style-is? [^model/outline-row row expected]
  (match (:status row)
    (Some status) (= (task-status-style status) expected)
    None (= expected "todo")))

(defn outliner-task-status-backlog? [^model/outline-row row]
  (outliner-task-status-style-is? row "backlog"))

(defn outliner-task-status-todo? [^model/outline-row row]
  (outliner-task-status-style-is? row "todo"))

(defn outliner-task-status-doing? [^model/outline-row row]
  (outliner-task-status-style-is? row "doing"))

(defn outliner-task-status-review? [^model/outline-row row]
  (outliner-task-status-style-is? row "in-review"))

(defn outliner-task-status-done? [^model/outline-row row]
  (outliner-task-status-style-is? row "done"))

(defn outliner-task-status-canceled? [^model/outline-row row]
  (outliner-task-status-style-is? row "canceled"))

(defn outliner-editor-task-label [^model/chat-model current]
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

(defn outliner-row-has-tags? [^model/outline-row row]
  (not (empty? (:tags row))))

(defn outliner-row-sync-failed? [^model/outline-row row]
  (match (:sync-status row)
    (Some status) (= status "failed")
    None false))

(defn outliner-row-list-item-press-enabled? [host ^model/outline-row row]
  (or (not (= host proto/FlutterHost))
      (= (:is-asset row) true)
      (= (:opens-as-page row) true)))

(defn outliner-tag-identifier [^model/sidebar-page tag]
  (str "button.block-tag." (:uuid tag)))

(defn outliner-tag-title [^model/sidebar-page tag]
  (str "#" (:title tag)))

(defn outliner-row-journal? [^model/chat-model current ^model/outline-row row]
  (and
   (journal-root-visible? current)
   (match (outliner-journal-marker current row)
     (Some _marker) true
     None false)))

(defn composer-asset-title [^model/composer-asset asset] (:title asset))

(defn composer-asset-path [^model/composer-asset asset] (:local-path asset))

(defn composer-asset-identifier [^model/composer-asset asset] (str "composer.asset." (:uuid asset)))

(defn composer-assets-present? [^model/chat-model current]
  (not (empty? (:composer-assets current))))

(defn composer-expanded? [^model/chat-model current]
  (:composer-expanded current))

(defn composer-draft [^model/chat-model current]
  (:composer-draft current))

(defn composer-autofocus? [^model/chat-model current]
  (:composer-autofocus current))

(defn outliner-task-status-option-identifier [^model/task-status status]
  (str
   "button.block-task-status-option."
   (match (:ident status)
     (Some ident) ident
     None (:uuid status))))

(defn first-flashcard [^model/chat-model current]
  (if (empty? (:flashcards current))
    None
    (Some (nth (:flashcards current) 0))))

(defn flashcards-empty? [^model/chat-model current]
  (empty? (:flashcards current)))

(defn flashcards-present? [^model/chat-model current]
  (not (flashcards-empty? current)))

(defn flashcard-question [^model/chat-model current]
  (match (first-flashcard current)
    (Some card)
    (if (:flashcard-cloze-revealed current)
      (:question-revealed card)
      (:question-hidden card))
    None ""))

(defn flashcard-remaining-label [^model/chat-model current]
  (str (count (:flashcards current)) " remaining"))

(defn flashcard-show-cloze? [^model/chat-model current]
  (match (first-flashcard current)
    (Some card)
    (and (:has-cloze card)
         (not (:flashcard-cloze-revealed current)))
    None false))

(defn flashcard-show-answer? [^model/chat-model current]
  (match (first-flashcard current)
    (Some card)
    (and (or (not (:has-cloze card))
             (:flashcard-cloze-revealed current))
         (not (:flashcard-answer-revealed current)))
    None false))

(defn flashcard-show-ratings? [^model/chat-model current]
  (and (flashcards-present? current)
       (:flashcard-answer-revealed current)))

(defn visible-flashcard-answer-rows [^model/chat-model current]
  (if (:flashcard-answer-revealed current)
    (match (first-flashcard current)
      (Some card) (:answer-rows card)
      None [])
    []))

(defn flashcard-answer-rows-visible? [^model/chat-model current]
  (not (empty? (visible-flashcard-answer-rows current))))

(defn flashcard-answer-identifier [^model/flashcard-answer-row answer]
  (str "flashcard.answer." (:index answer)))

(defn flashcard-answer-text [^model/flashcard-answer-row answer]
  (:text answer))

(defn graph-identifier [^model/graph graph]
  (str "graph." (:id graph)))

(defn graph-delete-identifier [^model/graph graph]
  (str "button.graph.delete." (:id graph)))

(defn graph-status-identifier [^model/graph graph]
  (str "graph.status." (:id graph)))

(defn graph-status-visible? [^model/graph graph]
  (or (:is-encrypted graph) (not (:is-ready graph))))

(defn graph-status-title [^model/graph graph]
  (if (:is-encrypted graph) "Encrypted" "Graph is not ready for sync."))

(defn graph-not-ready? [^model/graph graph]
  (not (:is-ready graph)))

(defn graph-row-disabled? [^model/chat-model current ^model/graph graph]
  (or (graph-not-ready? graph)
      (model/graph-delete-active? current (:id graph))))

(defn graph-delete-active? [^model/chat-model current ^model/graph graph]
  (model/graph-delete-active? current (:id graph)))

(defn graph-row-local? [^model/chat-model current ^model/graph graph]
  (model/graph-local? current (:id graph)))

(defn graph-icon-name [^:bool local? ^model/graph graph]
  (if local?
    "app:graph-local"
    "app:graph-remote"))

(defn local-graphs [^model/chat-model current]
  (filterv
   (fn [graph] (model/graph-local? current (:id graph)))
   (:graphs current)))

(defn remote-graphs [^model/chat-model current]
  (filterv
   (fn [graph] (not (model/graph-local? current (:id graph))))
   (:graphs current)))

(defn local-graphs-empty? [^model/chat-model current]
  (empty? (local-graphs current)))

(defn graphs-empty? [^model/chat-model current]
  (let [_destination (:destination current)]
    (empty? (:graphs current))))

(defn graphs-present? [^model/chat-model current]
  (not (graphs-empty? current)))

(defn remote-graphs-present? [^model/chat-model current]
  (not (empty? (remote-graphs current))))

(defn new-graph-name-empty? [^model/chat-model current]
  (string/blank? (:new-graph-name current)))

(defn graph-create-disabled? [^model/chat-model current]
  (or (new-graph-name-empty? current)
      (model/graph-create-active? current)))

(defn empty-graphs-loading? [^model/chat-model current]
  (and (graphs-empty? current) (model/graph-refresh-active? current)))

(defn empty-graphs-refreshable? [^model/chat-model current]
  (and (graphs-empty? current) (not (model/graph-refresh-active? current))))

(defn graph-deletion-pending? [^model/chat-model current]
  (match (:pending-graph-deletion current)
    (Some _graph) true
    None false))

(defn graph-deletion-message [^model/chat-model current]
  (match (:pending-graph-deletion current)
    (Some graph)
    (str "Are you sure you want to permanently delete the graph \""
         (:name graph)
         "\" from Logseq?")
    None ""))

(defn graph-password-empty? [^model/chat-model current]
  (string/blank? (:graph-password current)))

(defn graph-unlock-disabled? [^model/chat-model current]
  (or (graph-password-empty? current)
      (model/graph-unlock-active? current)))

(defn effect-error-present? [^model/chat-model current]
  (match (:effect-error current)
    (Some message) (not (empty? message))
    None false))

(defn effect-error-message [^model/chat-model current]
  (match (:effect-error current)
    (Some message) message
    None ""))

(defn graph-unlock-error-present? [^model/chat-model current]
  (effect-error-present? current))

(defn graph-unlock-error-message [^model/chat-model current]
  (effect-error-message current))

(defn global-effect-error-present? [^model/chat-model current]
  (and (effect-error-present? current)
       (not (:graph-password-open current))
       (not (= (:authentication-state current) "signedOut"))
       (not (= (:authentication-state current) "signingIn"))
       (match (:sync-state current)
         (FailedState _reason) false
         _ true)))

(defn graph-picker-error-reason [^model/chat-model current]
  (match (:effect-error current)
    (Some reason) (Some reason)
    None
    (match (:sync-state current)
      (FailedState reason) (Some reason)
      _ None)))

(defn graph-picker-error-present? [^model/chat-model current]
  (match (graph-picker-error-reason current)
    (Some _reason) true
    None false))

(defn error-separator [^:string reason]
  (string/index-of reason "\n"))

(defn graph-picker-error-code [^model/chat-model current]
  (match (graph-picker-error-reason current)
    (Some reason)
    (let [separator (error-separator reason)]
      (if (< separator 0) "sync_failed" (subs reason 0 separator)))
    None ""))

(defn graph-picker-error-title [^model/chat-model current]
  (match (graph-picker-error-code current)
    "graph_discovery_failed" "Couldn't load graphs"
    "graph_create_failed" "Couldn't create graph"
    "graph_open_failed" "Couldn't open graph"
    "graph_unlock_failed" "Couldn't unlock graph"
    "graph_initial_upload_failed" "Couldn't upload graph"
    "graph_key_provision_failed" "Couldn't prepare encryption"
    "sync_failed" "Sync failed"
    _ "Something went wrong"))

(defn graph-picker-error-message [^model/chat-model current]
  (match (graph-picker-error-reason current)
    (Some reason)
    (let [separator (error-separator reason)]
      (if (< separator 0) reason (subs reason (inc separator))))
    None ""))

(defn settings-main-visible? [^model/chat-model current]
  (and (not (:settings-tabs-open current))
       (not (:runtime-log-open current))))

(defn settings-spell-check [^model/chat-model current]
  (:spell-check current))

(defn settings-auto-correction [^model/chat-model current]
  (:auto-correction current))

(defn settings-base-url [^model/chat-model current]
  (:base-url current))

(defn settings-base-url-invalid? [^model/chat-model current]
  (and (not (empty? (string/trim (:base-url current))))
       (not (model/valid-base-url? (:base-url current)))))

(defn settings-apply-disabled? [^model/chat-model current]
  (not (model/valid-base-url? (:base-url current))))

(defn settings-version [^model/chat-model current]
  (:version current))

(defn settings-revision [^model/chat-model current]
  (:revision current))

(defn settings-language-title [^model/chat-model current]
  (match (model/settings-language-by-id
          (:language-choices current) (:language current))
    (Some choice) (:title choice)
    None "System"))

(defn settings-appearance-title [^model/chat-model current]
  (cond
    (= (:appearance current) "light") "Light"
    (= (:appearance current) "dark") "Dark"
    :else "System"))

(defn settings-language-choice-title [^model/settings-language-choice choice]
  (:title choice))

(defn settings-language-choice-identifier [^model/settings-language-choice choice]
  (str "button.settings.language." (:id choice)))

(defn settings-community-link-title [^model/settings-community-link link]
  (:title link))

(defn settings-community-link-identifier [^model/settings-community-link link]
  (str "link.settings.community." (:id link)))

(defn settings-community-link-needs-separator? [^model/chat-model current ^model/settings-community-link link]
  (match (last (:community-links current))
    (Some final-link) (not (= (:id link) (:id final-link)))
    None false))

(defn settings-tabs-visible? [^model/chat-model current]
  (:settings-tabs-open current))

(defn settings-tab-title [^:string tab]
  (cond
    (= tab "journals") "Journals"
    (= tab "flashcards") "Flashcards"
    :else "Graphs"))

(defn settings-tabs-summary [^model/chat-model current]
  (string/join " · " (map settings-tab-title (:sidebar-tabs current))))

(defn runtime-log-visible? [^model/chat-model current]
  (:runtime-log-open current))

(defn tab-enabled? [^model/chat-model current ^:string tab]
  (model/string-vector-contains? (:sidebar-tabs current) tab))

(defn tab-toggle-label [^model/chat-model current ^:string tab]
  (let [title
        (cond
          (= tab "journals") "Journals"
          (= tab "flashcards") "Flashcards"
          :else "Graphs")]
    (str title (if (tab-enabled? current tab) ", on" ", off"))))

(defn tab-selection-glyph [^model/chat-model current ^:string tab]
  (if (tab-enabled? current tab) "✓" "○"))

(defn tab-selection-icon-name [^model/chat-model current ^:string tab]
  (if (tab-enabled? current tab) "app:selected" "app:unselected"))

(defn tab-selection-foreground [^model/chat-model current ^:string tab]
  (if (tab-enabled? current tab) "accent" "secondary"))

(defn tab-disabled? [^model/chat-model current ^:string tab]
  (not (tab-enabled? current tab)))

(defn tab-index [^model/chat-model current ^:string tab]
  (let [tabs (:sidebar-tabs current)]
    (loop [index 0]
      (if (= index (count tabs))
        -1
        (if (= (nth tabs index) tab)
          index
          (recur (inc index)))))))

(defn tab-movement-visible? [^model/chat-model current ^:string tab]
  (and (not (= tab "journals"))
       (tab-enabled? current tab)))

(defn settings-flashcards-before-graphs? [^model/chat-model current]
  (and (tab-enabled? current "flashcards")
       (< (tab-index current "flashcards")
          (tab-index current "graphs"))))

(defn settings-flashcards-after-graphs? [^model/chat-model current]
  (and (tab-enabled? current "flashcards")
       (> (tab-index current "flashcards")
          (tab-index current "graphs"))))

(defn settings-available-tabs-present? [^model/chat-model current]
  (not (tab-enabled? current "flashcards")))

(defn tab-move-up-disabled? [^model/chat-model current ^:string tab]
  (<= (tab-index current tab) 1))

(defn tab-move-down-disabled? [^model/chat-model current ^:string tab]
  (let [index (tab-index current tab)]
    (or (< index 0)
        (>= index (dec (count (:sidebar-tabs current)))))))

(defn tab-toggle-identifier [^:string tab]
  (str "toggle.settings.tab." tab))

(defn tab-up-identifier [^:string tab]
  (str "button.settings.tab." tab ".up"))

(defn tab-down-identifier [^:string tab]
  (str "button.settings.tab." tab ".down"))

(defn runtime-log-level [^model/runtime-log-record record]
  (:level record))

(defn runtime-log-timestamp [^model/runtime-log-record record]
  (:timestamp record))

(defn runtime-log-message [^model/runtime-log-record record]
  (:message record))

(defn runtime-log-error? [^model/runtime-log-record record]
  (= (:level record) "ERROR"))

(defn runtime-log-empty? [^model/chat-model current]
  (empty? (:runtime-log-records current)))

(defn runtime-log-records [^model/chat-model current]
  (:runtime-log-records current))

(defn runtime-log-record-identifier [^model/runtime-log-record record]
  (:id record))

(defn runtime-log-errors-label [^model/chat-model current]
  (if (:runtime-log-errors-only current) "All" "Errors only"))

(defn runtime-log-order-label [^model/chat-model current]
  (if (:runtime-log-newest-first current) "Oldest first" "Newest first"))

(defn runtime-log-source-label [^model/chat-model current]
  (if (= (:runtime-log-source current) "ui") "Core log" "UI log"))

(defn sync-error-present? [^model/chat-model current]
  (match (:sync-state current)
    (FailedState _reason) true
    _ false))

(defn sync-error-message [^model/chat-model current]
  (match (:sync-state current)
    (FailedState reason) reason
    _ ""))

(defn selected-page-present? [^model/chat-model current]
  (match (:selected-page current)
    (Some _page) true
    None false))

(defn selected-page-absent? [^model/chat-model current]
  (not (selected-page-present? current)))

(defn selected-page-content-title-visible? [^model/chat-model current]
  (and (selected-page-present? current)
       (not (:selected-page-is-tag current))
       (node-outliner-visible? current)))

(defn selected-page-title [^model/chat-model current]
  (match (:selected-page current)
    (Some page) (:title page)
    None ""))

(defn journal-navigation-model [^model/chat-model current]
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

(defn node-route-model [^model/chat-model current ^model/node-projection route]
  (assoc current
         :node-routes [route]
         :outliner-rows (:outliner-rows route)
         :outliner-section-markers []
         :outliner-selected-block-ids (:outliner-selected-block-ids route)
         :outliner-editing (:outliner-editing route)
         :outliner-autocomplete (:outliner-autocomplete route)
         :outliner-autocomplete-candidates
         (:outliner-autocomplete-candidates route)))

(defn app-navigation-depth [^model/chat-model current]
  (navigation-path-depth (:app-navigation-path current)))

(defn search-navigation-depth [^model/chat-model current]
  (navigation-path-depth (:search-navigation-path current)))

(defn search-node-routes [^model/chat-model current]
  (if (= (:search-open current) false)
    []
    (let [routes (:node-routes current)
          start (min (app-navigation-depth current) (count routes))]
      (loop [index start
             result []]
        (if (= index (count routes))
          result
          (recur (inc index) (conj result (nth routes index))))))))

(defn active-route-only [^:vector<model/node-projection> routes]
  (if (empty? routes)
    []
    (match (last routes) (Some route) [route] None [])))

(defn active-app-node-routes [^model/chat-model current]
  (active-route-only (model/app-node-routes current)))

(defn active-search-node-routes [^model/chat-model current]
  (active-route-only (search-node-routes current)))

(defn flutter-app-root-visible? [^model/chat-model current]
  (and (= (:search-open current) false)
       (empty? (active-app-node-routes current))))

(defn flutter-search-root-visible? [^model/chat-model current]
  (and (:search-open current)
       (empty? (active-search-node-routes current))))

(defn authentication-screen-visible? [^model/chat-model current]
  (or (= (:authentication-state current) "signedOut")
      (= (:authentication-state current) "signingIn")))

(defn graph-picker-screen-visible? [^model/chat-model current]
  (and (graph-picker-visible? current)
       (not (authentication-screen-visible? current))))

(defn authentication-signing-in? [^model/chat-model current]
  (= (:authentication-state current) "signingIn"))

(defn authentication-error-present? [^model/chat-model current]
  (match (:authentication-error current)
    (Some message) (not (empty? message))
    None false))

(defn authentication-error-message [^model/chat-model current]
  (match (:authentication-error current)
    (Some message) message
    None ""))

(defn graph-picker-hidden? [^model/chat-model current]
  (not (graph-picker-visible? current)))

(defn main-screen-visible? [^model/chat-model current]
  (and (graph-picker-hidden? current)
       (not (authentication-screen-visible? current))))

(defn application-shell-visible? [^model/chat-model current]
  (not (authentication-screen-visible? current)))

(defn drawer-selected? [^model/chat-model current]
  (and (:sidebar-open current)
       (graph-picker-hidden? current)
       (not (authentication-screen-visible? current))))

(defn drawer-disabled? [^model/chat-model current]
  (or (graph-picker-visible? current)
      (authentication-screen-visible? current)
      (sidebar-drag-disabled? current)))
