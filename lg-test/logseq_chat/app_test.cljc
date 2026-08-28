(ns logseq-chat.app-test
  (:require [clojure.string :as string]
            [clojure.test :refer [deftest is testing]]
            [lui.app :as driver]
            [lui.backend.apple :as apple]
            [lui.extension :as ext]
            [lui.protocol :as proto :refer [StringValue]]
            [logseq-chat.app :as chat]
            [logseq-chat.native-bridge :as bridge]
            [logseq-chat.model :as model]
            [logseq-chat.view :as view]))

(defmacro assert-equal [expected actual message]
  `(is (= ~expected ~actual) ~message))

(defn property-string [renderer node property]
  (match (apple/property renderer node property)
    (Some (StringValue value)) value
    _ "<missing>"))

(defn property-int [renderer node property]
  (match (apple/property renderer node property)
    (Some (proto/IntValue value)) value
    _ -1))

(defn property-bool [renderer node property]
  (match (apple/property renderer node property)
    (Some (proto/BoolValue value)) value
    _ false))

(defn property-float [renderer node property]
  (match (apple/property renderer node property)
    (Some (proto/FloatValue value)) value
    _ -1.0))

(defn extension-property [application node property]
  (match (clojure.core/get
          (deref
           (:runtime-extension-properties (driver/runtime application))) node)
    (Some properties) (clojure.core/get properties property)
    None None))

(defn extension-node [application identifier]
  (let [runtime (driver/runtime application)
        nodes (deref (:runtime-extension-nodes runtime))
        limit (deref (:next-node-id runtime))]
    (loop [node 1]
      (if (> node limit)
        -1
        (if (= (clojure.core/get nodes node) (Some identifier))
          node
          (recur (inc node)))))))

(defn descendant-with-node-kind [renderer parent kind]
  (if (= (apple/node renderer parent) (Some kind))
    parent
    (let [children (apple/children renderer parent)]
      (loop [index 0]
        (if (= index (count children))
          -1
          (let [match (descendant-with-node-kind
                       renderer (nth children index) kind)]
            (if (= match -1)
              (recur (inc index))
              match)))))))

(defn descendant-count-with-node-kind [renderer parent kind]
  (let [children (apple/children renderer parent)
        own (if (= (apple/node renderer parent) (Some kind)) 1 0)]
    (loop [index 0
           total own]
      (if (= index (count children))
        total
        (recur
         (inc index)
         (+ total
            (descendant-count-with-node-kind
             renderer (nth children index) kind)))))))

(defn descendant-count-with-property-string
  [renderer parent property expected]
  (let [children (apple/children renderer parent)
        own (if (= expected (property-string renderer parent property)) 1 0)]
    (loop [index 0
           total own]
      (if (= index (count children))
        total
        (recur
         (inc index)
         (+ total
            (descendant-count-with-property-string
             renderer (nth children index) property expected)))))))

(defn descendant-with-extension
  [renderer application parent identifier]
  (let [extensions
        (deref (:runtime-extension-nodes (driver/runtime application)))]
    (if (= (clojure.core/get extensions parent) (Some identifier))
      parent
      (let [children (apple/children renderer parent)]
        (loop [index 0]
          (if (= index (count children))
            -1
            (let [found
                  (descendant-with-extension
                   renderer application (nth children index) identifier)]
              (if (= found -1)
                (recur (inc index))
                found))))))))

(defn child-with-identifier [renderer parent identifier]
  (let [children (apple/children renderer parent)]
    (loop [index 0]
      (if (= index (count children))
        -1
        (let [child (nth children index)]
          (if (= identifier
                 (property-string renderer child proto/AccessibilityIdentifier))
            child
            (recur (inc index))))))))

(defn child-index-with-identifier [renderer parent identifier]
  (let [children (apple/children renderer parent)]
    (loop [index 0]
      (if (= index (count children))
        -1
        (if (= identifier
               (property-string
                renderer (nth children index) proto/AccessibilityIdentifier))
          index
          (recur (inc index)))))))

(defn descendant-with-identifier [renderer parent identifier]
  (let [direct (child-with-identifier renderer parent identifier)]
    (if (not (= direct -1))
      direct
      (let [children (apple/children renderer parent)]
        (loop [index 0]
          (if (= index (count children))
            -1
            (let [found
                  (descendant-with-identifier renderer (nth children index)
                                              identifier)]
              (if (= found -1)
                (recur (inc index))
                found))))))))

(defn parent-with-child-identifier [renderer parent identifier]
  (if (not (= -1 (child-with-identifier renderer parent identifier)))
    parent
    (let [children (apple/children renderer parent)]
      (loop [index 0]
        (if (= index (count children))
          -1
          (let [found
                (parent-with-child-identifier
                 renderer (nth children index) identifier)]
            (if (= found -1)
              (recur (inc index))
              found)))))))

(defn descendant-count-with-identifier [renderer parent identifier]
  (let [own (if (= identifier
                   (property-string renderer parent
                                    proto/AccessibilityIdentifier))
              1
              0)
        children (apple/children renderer parent)]
    (loop [index 0
           total own]
      (if (= index (count children))
        total
        (recur
         (inc index)
         (+ total
            (descendant-count-with-identifier
             renderer (nth children index) identifier)))))))

(defn descendant-enabled [renderer parent identifier]
  (let [node (descendant-with-identifier renderer parent identifier)]
    (if (= node -1)
      None
      (match (apple/property renderer node proto/Enabled)
        (Some (proto/BoolValue enabled)) (Some enabled)
        _ None))))

(defn main-root [renderer application]
  (let [runtime-root (driver/root-node application)
        picker-parent
        (parent-with-child-identifier renderer runtime-root "screen.graph-picker")
        stack (nth (apple/children renderer runtime-root) 0)
        children (apple/children renderer stack)
        container (nth children (dec (count children)))
        extensions
        (deref (:runtime-extension-nodes (driver/runtime application)))]
    (if (not (= picker-parent -1))
      picker-parent
      (if (= (clojure.core/get extensions container)
             (Some "native-navigation-stack"))
        (let [wrapper (nth (apple/children renderer container) 0)
              search (nth (apple/children renderer wrapper) 0)]
          (if (= (clojure.core/get extensions search)
                 (Some "native-search-presentation"))
            (let [presented
                  (= (extension-property application search "presented")
                     (Some (proto/BoolValue true)))]
              (nth (apple/children renderer search) (if presented 1 0)))
            wrapper))
        runtime-root))))

(defn native-bottom-chrome [renderer application]
  (let [navigation (extension-node application "native-navigation-stack")]
    (nth (apple/children renderer navigation) 5)))

(defn empty-sidebar-projection []
  (record model/sidebar-projection
    (favorites [])
    (recent-pages [])
    (selected-page None)
    (selected-page-is-tag false)
    (selected-page-is-property false)
    (related-rows [])
    (linked-reference-rows [])))

(defn node-projection [uuid page-uuid title related-rows linked-reference-rows]
  (record model/node-projection
    (uuid uuid)
    (page-uuid page-uuid)
    (title title)
    (is-tag false)
    (is-property false)
    (outliner-rows [])
    (related-rows related-rows)
    (linked-reference-rows linked-reference-rows)
    (outliner-editing None)
    (outliner-autocomplete None)
    (outliner-autocomplete-candidates [])
    (outliner-selected-block-ids [])))

(defn empty-core-projection []
  (record model/core-projection
    (graph-name None)
    (selected-graph-id None)
    (graphs [])
    (is-graph-encrypted false)
    (is-graph-unlocked false)
    (sidebar (empty-sidebar-projection))
    (task-statuses [])
    (flashcards [])
    (sync-connected false)
    (applied-server-t None)
    (has-pending-semantic-operations false)
    (has-pending-sync-request false)
    (is-pending-sync-patch false)
    (search-query "")
    (search-results [])
    (node-routes [])
    (journal-outliner-rows [])
    (outliner-editing None)
    (outliner-autocomplete None)
    (outliner-autocomplete-candidates [])
    (outliner-selected-block-ids [])
    (outliner-rows [])
    (has-older-journals false)
    (is-outliner-patch false)
    (outliner-row-splices [])))

(defn apply-core-snapshot
  [graph-name sidebar flashcards sync-connected search-query search-results
   node-routes outliner-editing outliner-autocomplete
   outliner-autocomplete-candidates outliner-selected-block-ids outliner-rows
   is-outliner-patch outliner-row-splices]
  (model/ApplyCoreSnapshot
   (assoc
    (empty-core-projection)
    :graph-name graph-name
    :selected-graph-id (Some "test-graph")
    :sidebar sidebar
    :flashcards flashcards
    :sync-connected sync-connected
    :search-query search-query
    :search-results search-results
    :node-routes node-routes
    :outliner-editing outliner-editing
    :outliner-autocomplete outliner-autocomplete
    :outliner-autocomplete-candidates outliner-autocomplete-candidates
    :outliner-selected-block-ids outliner-selected-block-ids
    :outliner-rows outliner-rows
    :is-outliner-patch is-outliner-patch
    :outliner-row-splices outliner-row-splices)))

(defn flashcard-answer [uuid index text]
  (record model/flashcard-answer-row
    (uuid uuid)
    (index index)
    (text text)))

(defn flashcard
  [uuid question-hidden question-revealed answer-rows has-cloze]
  (record model/flashcard
    (uuid uuid)
    (question-hidden question-hidden)
    (question-revealed question-revealed)
    (answer-rows answer-rows)
    (has-cloze has-cloze)))

(defn graph [id name encrypted ready]
  (record model/graph
    (id id)
    (name name)
    (is-encrypted encrypted)
    (is-ready ready)))

(defn journal-outline-row [uuid page-id title journal-title journal-day depth]
  (record model/outline-row
    (uuid uuid)
    (title title)
    (markup-json "[]")
    (youtube-target-url None)
    (breadcrumb "")
    (breadcrumbs [])
    (opens-as-page false)
    (depth depth)
    (has-children false)
    (is-collapsed false)
    (is-asset false)
    (asset-type None)
    (local-path None)
    (status None)
    (tags [])
    (sync-status None)
    (page-id page-id)
    (journal-title (Some journal-title))
    (journal-day (Some journal-day))))

(defn task-status [uuid ident title icon-type icon-id icon-color]
  (record model/task-status
    (uuid uuid)
    (ident ident)
    (title title)
    (icon-type icon-type)
    (icon-id icon-id)
    (icon-color icon-color)))

(defn settings [tabs]
  (record model/settings-projection
    (appearance "system")
    (language "system")
    (spell-check true)
    (auto-correction true)
    (sidebar-tabs tabs)
    (base-url "https://api.logseq.com")
    (version "1.0")
    (revision "abc123")))

(defn runtime-record [id level source message]
  (record model/runtime-log-record
    (id id)
    (level level)
    (source source)
    (timestamp "12:00")
    (message message)))

(deftest empty-outliner-rows-use-the-main-untitled-accessibility-title
  (let [row (journal-outline-row
             "empty" "journal" "" "Aug 28th, 2026" 20260828 0)]
    (assert-equal
     "Edit block Untitled block"
     (view/outliner-row-action-label (model/initial) row)
     "empty blocks retain main's editable Untitled accessibility label")))

(deftest synced-header-control-uses-the-main-accessibility-label
  (let [current (assoc (model/initial) :sync-state model/SyncedState)]
    (assert-equal "Synced" (view/sync-indicator-label current)
                  "the compact header control matches main's spoken status")
    (assert-equal "Up to date" (view/sync-label current)
                  "the detailed status sheet keeps its descriptive summary")))

(deftest settings-navigation-tabs-and-diagnostics-are-lg-owned
  (let [initial (model/update (model/initial)
                              (model/ApplySettingsSnapshot
                               (settings ["journals" "flashcards" "graphs"])))
        menu (model/update initial model/OpenConnectionMenu)
        opened (model/update menu model/OpenSettings)
        tabs (model/update opened model/OpenSettingsTabs)
        hidden (model/update tabs (model/ToggleSidebarTab "flashcards"))
        logs (model/update (model/update hidden model/BackSettings)
                           model/OpenRuntimeLog)
        filtered (model/update logs model/ToggleRuntimeLogErrors)
        refreshed filtered]
    (is (:connection-menu-open menu) "the connection menu is model-owned")
    (is (:settings-open opened) "settings presentation is model-owned")
    (is (not (:connection-menu-open opened))
        "opening settings dismisses its source menu")
    (is (:settings-tabs-open tabs) "tabs navigation is model-owned")
    (assert-equal ["journals" "graphs"] (:sidebar-tabs hidden)
                  "optional sidebar tabs can be hidden")
    (is (:runtime-log-open logs) "runtime diagnostics are model-owned")
    (is (:runtime-log-errors-only filtered) "log filtering is model-owned")
    (assert-equal
     [(model/SaveSettingsEffect 1 (model/current-settings hidden))
      (model/RefreshRuntimeLogEffect 2 "ui" true false)]
     (:pending-effects refreshed)
     "tabs persist immediately before diagnostics refresh")))

(deftest settings-preferences-persist-without-dismissing-the-sheet
  (let [opened
        (model/update
         (model/update
          (model/initial)
          (model/ApplySettingsSnapshot
           (settings ["journals" "flashcards" "graphs"])))
         model/OpenSettings)
        themed (model/update opened (model/ChangeAppearance "dark"))
        theme-saved
        (model/update
         (model/update themed (model/DequeueEffect 1))
         (model/ResolveEffect 1 true ""))
        language-opened
        (model/update theme-saved model/OpenSettingsLanguageMenu)
        localized
        (model/update language-opened
                      (model/ChooseSettingsLanguage "zh-CN"))
        language-saved
        (model/update
         (model/update localized (model/DequeueEffect 2))
         (model/ResolveEffect 2 true ""))
        spell-check-disabled
        (model/update language-saved (model/ToggleSpellCheck false))
        spell-check-saved
        (model/update
         (model/update spell-check-disabled (model/DequeueEffect 3))
         (model/ResolveEffect 3 true ""))
        auto-correction-disabled
        (model/update spell-check-saved
                      (model/ToggleAutoCorrection false))]
    (assert-equal
     [(model/SaveSettingsEffect 1 (model/current-settings themed))]
     (:pending-effects themed)
     "theme changes persist immediately like main's AppStorage picker")
    (is (:settings-open themed)
        "persisting a preference does not dismiss settings")
    (assert-equal
     [(model/SaveSettingsEffect 2 (model/current-settings localized))]
     (:pending-effects localized)
     "language changes persist immediately like main's AppStorage picker")
    (is (:settings-open localized)
        "language persistence keeps settings visible")
    (assert-equal
     [(model/SaveSettingsEffect
       3 (model/current-settings spell-check-disabled))]
     (:pending-effects spell-check-disabled)
     "spell check changes persist immediately")
    (assert-equal
     [(model/SaveSettingsEffect
       4 (model/current-settings auto-correction-disabled))]
     (:pending-effects auto-correction-disabled)
     "auto-correction changes persist immediately")))

(deftest settings-reject-invalid-connections-and-preserve-required-tabs
  (let [opened (assoc (model/initial)
                      :settings-open true
                      :base-url "not a server")
        invalid (model/update opened model/ApplySettings)
        required-toggled
        (model/update opened (model/ToggleSidebarTab "journals"))
        required-moved
        (model/update opened (model/MoveSidebarTab "journals" 2))]
    (assert-equal [] (:pending-effects invalid)
                  "invalid connection URLs do not leave LG")
    (is (:settings-open invalid)
        "invalid connection URLs keep settings open for correction")
    (is (not (model/valid-base-url? "https:///missing-host"))
        "HTTPS URLs require a host")
    (is (not (model/valid-base-url? "http://?query-only"))
        "HTTP URLs cannot substitute a query for the host")
    (is (not (model/valid-base-url? "https://bad host.example"))
        "connection hosts cannot contain whitespace")
    (is (model/valid-base-url? " http://127.0.0.1:8787/path ")
        "local development servers remain valid after trimming")
    (assert-equal ["journals" "flashcards" "graphs"]
                  (:sidebar-tabs required-toggled)
                  "journals cannot be hidden")
    (assert-equal ["journals" "flashcards" "graphs"]
                  (:sidebar-tabs required-moved)
                  "journals remains the first required tab")
    (assert-equal [] (:pending-effects required-toggled)
                  "required tab no-ops do not persist settings")
    (assert-equal [] (:pending-effects required-moved)
                  "required tab moves do not persist settings")))

(deftest settings-snapshot-normalizes-sidebar-tabs-at-the-lg-boundary
  (let [defaulted
        (model/update
         (model/initial)
         (model/ApplySettingsSnapshot (settings [])))
        sanitized
        (model/update
         (model/initial)
         (model/ApplySettingsSnapshot
          (settings ["graphs" "graphs" "unknown" "flashcards"])))
        required
        (model/update
         (model/initial)
         (model/ApplySettingsSnapshot (settings ["journals"])))]
    (assert-equal ["journals" "flashcards" "graphs"]
                  (:sidebar-tabs defaulted)
                  "missing persisted tabs use the complete default")
    (assert-equal ["journals" "graphs" "flashcards"]
                  (:sidebar-tabs sanitized)
                  "LG discards unknown and duplicate persisted tabs")
    (assert-equal ["journals" "graphs"]
                  (:sidebar-tabs required)
                  "LG restores the required graphs tab without re-enabling flashcards")))

(deftest runtime-log-filters-refresh-and-successful-results-enter-lg-state
  (let [filtered (model/update (model/initial) model/ToggleRuntimeLogErrors)
        in-flight (model/update filtered (model/DequeueEffect 1))
        resolved (model/update in-flight (model/ResolveEffect 1 true ""))
        expected [(runtime-record "1" "INFO" "ui" "Started")]
        applied (model/update resolved (model/ApplyRuntimeLog expected))]
    (assert-equal
     [(model/RefreshRuntimeLogEffect 1 "ui" true false)]
     (:pending-effects filtered)
     "changing a log filter refreshes the visible result immediately")
    (assert-equal expected (:runtime-log-records applied)
                  "typed host log updates enter retained LG state")))

(deftest graph-effect-success-owns-selection-and-selected-deletion-cleanup
  (let [local (graph "local" "Local" false true)
        projected
        (model/update
         (model/initial)
         (model/ApplyCoreSnapshot
          (assoc (empty-core-projection)
                 :graphs [local]
                 :selected-graph-id None)))
        known-local (model/update projected (model/ApplyLocalGraphIds ["local"]))
        requested (model/update known-local (model/RequestOpenGraph "local"))
        opened
        (model/update
         (model/update requested (model/DequeueEffect 1))
         (model/ResolveEffect 1 true "ok"))
        deletion-requested
        (model/update opened (model/RequestDeleteGraph "local"))
        deleting
        (model/update
         (model/update deletion-requested model/ConfirmDeleteGraph)
         (model/DequeueEffect 2))
        deleted (model/update deleting (model/ResolveEffect 2 true "ok"))]
    (assert-equal (Some "local") (:selected-graph-id opened)
                  "opening a graph updates LG selection after platform success")
    (assert-equal (Some "Local") (:selected-graph opened)
                  "opening a graph projects its title without waiting for a refresh")
    (is (:graph-loading requested)
        "opening a graph enters the retained loading state")
    (is (not (:graph-loading opened))
        "platform completion exits the retained loading state")
    (assert-equal None (:selected-graph-id deleted)
                  "deleting the selected local graph clears its identifier")
    (assert-equal None (:selected-graph deleted)
                  "deleting the selected local graph clears its title")
    (assert-equal [] (:local-graph-ids deleted)
                  "deleting a local graph removes it from local storage state")))

(deftest graph-refresh-failure-enters-the-picker-error-state
  (let [requested (model/update (model/initial) model/RefreshGraphs)
        in-flight (model/update requested (model/DequeueEffect 1))
        failed
        (model/update
         in-flight
         (model/ResolveEffect
          1 false "graph_discovery_failed\nConnection refused"))]
    (assert-equal
     (model/FailedState "graph_discovery_failed\nConnection refused")
     (:sync-state failed)
     "a failed catalog refresh renders the picker-specific error state")
    (is (not (view/global-effect-error-present? failed))
        "the picker error does not also render the global effect error")))

(deftest encrypted-graph-unlock-is-owned-by-lg
  (let [encrypted (graph "encrypted" "Encrypted" true true)
        catalog-projection
        (assoc (empty-core-projection) :graphs [encrypted])
        locked-projection
        (assoc (empty-core-projection)
               :graphs [encrypted]
               :selected-graph-id (Some "encrypted")
               :graph-name (Some "Encrypted")
               :is-graph-encrypted true
               :is-graph-unlocked false)
        requested
        (model/update
         (model/update (model/initial)
                       (model/ApplyCoreSnapshot catalog-projection))
         (model/RequestOpenGraph "encrypted"))
        opened
        (model/update
         (model/update
          (model/update requested (model/DequeueEffect 1))
          (model/ApplyCoreSnapshot locked-projection))
         (model/ResolveEffect 1 true ""))
        blank (model/update opened model/SubmitGraphPassword)
        wrong
        (model/update
         (model/update opened (model/ChangeGraphPassword "wrong"))
         model/SubmitGraphPassword)
        failed
        (model/update
         (model/update wrong (model/DequeueEffect 2))
         (model/ResolveEffect 2 false "Wrong password"))
        correct
        (model/update
         (model/update failed (model/ChangeGraphPassword "correct"))
         model/SubmitGraphPassword)
        unlocked-projection (assoc locked-projection :is-graph-unlocked true)
        succeeded
        (model/update
         (model/update
          (model/update correct (model/DequeueEffect 3))
          (model/ApplyCoreSnapshot unlocked-projection))
         (model/ResolveEffect 3 true ""))
        cancelled
        (model/update
         (model/update opened (model/ChangeGraphPassword "cancel me"))
         model/CancelGraphUnlock)]
    (is (:graph-password-open opened)
        "opening a locked encrypted graph presents the password sheet")
    (assert-equal [] (:pending-effects blank)
                  "an empty password never crosses the platform boundary")
    (assert-equal [(model/UnlockGraphEffect 2 "wrong")]
                  (:pending-effects wrong)
                  "unlock publishes one typed platform effect")
    (is (:graph-password-open failed)
        "an unlock failure keeps the password sheet visible")
    (assert-equal "wrong" (:graph-password failed)
                  "an unlock failure preserves the entered password")
    (assert-equal (Some "Wrong password") (:effect-error failed)
                  "an unlock failure remains visible in LG state")
    (is (not (:graph-password-open succeeded))
        "a successful unlock dismisses the password sheet")
    (assert-equal "" (:graph-password succeeded)
                  "a successful unlock clears the password")
    (is (not (:graph-password-open cancelled))
        "cancelling unlock dismisses the password sheet")
    (assert-equal "" (:graph-password cancelled)
                  "cancelling unlock clears the password")))

(deftest encrypted-graph-snapshot-prompts-once-per-selection
  (let [encrypted (graph "encrypted" "Encrypted" true true)
        catalog (assoc (empty-core-projection) :graphs [encrypted])
        locked
        (assoc catalog
               :selected-graph-id (Some "encrypted")
               :graph-name (Some "Encrypted")
               :is-graph-encrypted true
               :is-graph-unlocked false)
        selected
        (model/update (model/initial) (model/ApplyCoreSnapshot locked))
        cancelled (model/update selected model/CancelGraphUnlock)
        refreshed (model/update cancelled (model/ApplyCoreSnapshot locked))
        catalogued
        (model/update refreshed (model/ApplyCoreSnapshot catalog))
        selected-again
        (model/update catalogued (model/ApplyCoreSnapshot locked))]
    (is (:graph-password-open selected)
        "cold-start restoration prompts for a locked selected graph")
    (is (not (:graph-password-open refreshed))
        "refreshing the same graph does not reopen a cancelled prompt")
    (is (:graph-password-open selected-again)
        "selecting the locked graph again presents a fresh prompt")))

(deftest encrypted-graph-unlock-renders-the-secure-field-contract
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        encrypted (graph "encrypted" "Encrypted" true true)
        catalog-projection
        (assoc (empty-core-projection) :graphs [encrypted])
        locked-projection
        (assoc (empty-core-projection)
               :graphs [encrypted]
               :selected-graph-id (Some "encrypted")
               :graph-name (Some "Encrypted")
               :is-graph-encrypted true
               :is-graph-unlocked false)]
    (driver/start! application)
    (driver/send! application (model/ApplyCoreSnapshot catalog-projection))
    (driver/send! application (model/RequestOpenGraph "encrypted"))
    (driver/send! application (model/DequeueEffect 1))
    (driver/send! application (model/ApplyCoreSnapshot locked-projection))
    (driver/send! application (model/ResolveEffect 1 true ""))
    (driver/flush! application)
    (let [root (driver/root-node application)
          field (descendant-with-identifier renderer root "field.graph-password")
          unlock (descendant-with-identifier renderer root "button.graph-unlock")
          cancel (descendant-with-identifier renderer root "button.graph-unlock.cancel")]
      (is (not (= -1 field)) "the unlock sheet renders a secure password field")
      (is (not (= -1 unlock)) "the unlock sheet renders its confirm action")
      (is (not (= -1 cancel)) "the unlock sheet renders its cancel action")
      (assert-equal "E2EE password"
                    (property-string renderer field proto/PlaceholderValue)
                    "the secure field preserves the existing placeholder")
      (driver/dispatch-event! application
                              (proto/TextChanged field "secret"))
      (driver/flush! application)
      (assert-equal "secret" (:graph-password (chat/model application))
                    "secure-field input is retained by LG")
      (driver/dispatch-event! application (proto/Press unlock))
      (driver/flush! application)
      (assert-equal [(model/UnlockGraphEffect 2 "secret")]
                    (:pending-effects (chat/model application))
                    "the unlock button submits the retained password")
      (driver/send! application (model/DequeueEffect 2))
      (driver/send! application
                    (model/ResolveEffect 2 false "Wrong password"))
      (driver/flush! application)
      (let [error
            (descendant-with-identifier
             renderer root "text.graph-unlock-error")]
        (is (not (= -1 error)) "an unlock failure stays inside the sheet")
        (assert-equal "Wrong password"
                      (property-string renderer error proto/TextValue)
                      "the unlock failure explains why the graph stayed locked")
        (assert-equal
         0
         (descendant-count-with-identifier renderer root "error.banner")
         "the password sheet does not duplicate its error globally")))))

(deftest encrypted-graph-unlock-has-a-stable-native-effect-payload
  (assert-equal
   "{\"id\":9,\"kind\":\"unlock-graph\",\"text\":\"secret \\\"phrase\\\"\"}"
   (bridge/encode-effect (model/UnlockGraphEffect 9 "secret \"phrase\""))
   "the native bridge escapes passwords in a typed unlock effect"))

(deftest graph-database-export-has-a-stable-native-effect-payload
  (assert-equal
   "{\"id\":9,\"kind\":\"export-graph-database\",\"text\":\"\"}"
   (bridge/encode-effect (model/ExportGraphDatabaseEffect 9))
   "database export leaves file resolution at the platform boundary"))

(deftest cancel-outliner-editing-has-a-stable-native-effect-payload
  (assert-equal
   "{\"id\":9,\"kind\":\"cancel-outliner-editing\",\"text\":\"\"}"
   (bridge/encode-effect (model/CancelOutlinerEditingEffect 9))
   "destination changes preserve the typed cancel-editing boundary"))

(deftest settings-render-the-main-branch-navigation-contract
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send!
     application
     (model/ApplyCoreSnapshot
      (assoc (empty-core-projection)
             :selected-graph-id (Some "local")
             :graph-name (Some "Local graph"))))
    (driver/send! application (model/ApplyLocalGraphIds ["local"]))
    (driver/send! application
                  (model/ApplySettingsSnapshot
                   (settings ["journals" "flashcards" "graphs"])))
    (driver/send! application model/OpenConnectionMenu)
    (driver/send! application model/OpenSettings)
    (driver/flush! application)
    (let [root (main-root renderer application)
          settings-screen (descendant-with-identifier renderer root
                                                      "screen.settings")]
      (is (not (= -1 settings-screen))
          "settings retain their baseline screen identifier")
      (assert-equal
       "background"
       (property-string renderer settings-screen proto/BackgroundValue)
       "settings paint the app background inside the native sheet")
      (assert-equal
       7
       (descendant-count-with-property-string
        renderer settings-screen proto/BackgroundValue "surface")
       "settings cards use the same themed surface as main")
      (is (not (= -1 (descendant-with-identifier renderer root
                                                  "link.settings.tabs")))
          "settings expose tabs navigation")
      (is (not (= -1 (descendant-with-identifier
                      renderer root "toolbar.settings.actions")))
          "settings use the native navigation-form toolbar contract")
      (is (not (= -1 (descendant-with-identifier
                      renderer root "button.connection.cancel")))
          "settings expose the native cancellation action")
      (doseq [identifier ["label.settings.general"
                          "label.settings.editor"
                          "label.settings.sync-server"
                          "label.settings.advanced"
                          "label.settings.about"
                          "label.settings.community"]]
        (assert-equal
         "muted-foreground"
         (property-string
          renderer
          (descendant-with-identifier renderer root identifier)
          proto/ForegroundValue)
         "settings group labels use main's readable secondary text color"))
      (let [export
            (descendant-with-identifier
             renderer root "button.export-graph-database")]
        (is (not (= -1 export))
            "settings expose database export for a downloaded graph")
        (driver/dispatch-event! application (proto/Press export))
        (driver/flush! application)
        (assert-equal [(model/ExportGraphDatabaseEffect 1)]
                      (:pending-effects (chat/model application))
                      "database export stays on the typed platform boundary"))
      (driver/send! application model/OpenSettingsTabs)
      (driver/flush! application)
      (is (not (= -1 (descendant-with-identifier renderer root
                                                  "screen.settings.tabs")))
          "tabs retain their baseline screen identifier")
      (is (not (= -1 (descendant-with-identifier
                      renderer root "toggle.settings.tab.flashcards")))
          "configurable tabs retain their stable identifiers")
      (driver/send! application model/BackSettings)
      (driver/send! application model/OpenRuntimeLog)
      (driver/send! application
                    (model/ApplyRuntimeLog
                     [(runtime-record "1" "INFO" "ui" "Started")]))
      (driver/flush! application)
      (is (not (= -1 (descendant-with-identifier renderer root
                                                  "screen.runtime-log")))
          "runtime log retains its baseline screen identifier")
      (is (not (= -1 (descendant-with-identifier renderer root
                                                  "button.log-copy")))
          "runtime diagnostics retain their actions"))))

(deftest settings-tabs-match-main-visibility-and-movement-boundaries
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send!
     application
     (model/ApplySettingsSnapshot
      (settings ["journals" "flashcards" "graphs"])))
    (driver/send! application model/OpenSettings)
    (driver/send! application model/OpenSettingsTabs)
    (driver/flush! application)
    (let [root (driver/root-node application)]
      (assert-equal 360 (property-int renderer root proto/WidthValue)
                    "the drawer leaves the same visible main edge as main")
      (assert-equal (Some false)
                    (descendant-enabled
                     renderer root "toggle.settings.tab.journals")
                    "journals remains visibly required")
      (assert-equal -1
                    (descendant-with-identifier
                     renderer root "button.settings.tab.journals.up")
                    "journals does not render movement controls")
      (assert-equal (Some true)
                    (descendant-enabled
                     renderer root "toggle.settings.tab.flashcards")
                    "flashcards remains configurable")
      (assert-equal (Some false)
                    (descendant-enabled
                     renderer root "button.settings.tab.flashcards.up")
                    "the first configurable tab cannot move above journals")
      (assert-equal (Some true)
                    (descendant-enabled
                     renderer root "button.settings.tab.flashcards.down")
                    "the first configurable tab can move down")
      (assert-equal (Some false)
                    (descendant-enabled
                     renderer root "toggle.settings.tab.graphs")
                    "graphs remains visibly required")
      (assert-equal (Some true)
                    (descendant-enabled
                     renderer root "button.settings.tab.graphs.up")
                    "the last required tab can move within visible tabs")
      (assert-equal (Some false)
                    (descendant-enabled
                     renderer root "button.settings.tab.graphs.down")
                    "the last tab cannot move beyond the visible list")
      (driver/dispatch-event!
       application
       (proto/Press
        (descendant-with-identifier
         renderer root "toggle.settings.tab.flashcards")))
      (driver/flush! application)
      (let [updated-root (driver/root-node application)]
        (assert-equal -1
                      (descendant-with-identifier
                       renderer updated-root
                       "button.settings.tab.flashcards.up")
                      "hidden tabs do not retain movement controls")
        (assert-equal -1
                      (descendant-with-identifier
                       renderer updated-root
                       "button.settings.tab.flashcards.down")
                      "hidden tabs do not expose invalid downward movement")
        (assert-equal (Some false)
                      (descendant-enabled
                       renderer updated-root "button.settings.tab.graphs.up")
                      "a lone configurable position cannot move up")
        (assert-equal (Some false)
                      (descendant-enabled
                       renderer updated-root "button.settings.tab.graphs.down")
                      "a lone configurable position cannot move down")))))

(deftest settings-tabs-render-saved-order-and-separate-available-tabs
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send!
     application
     (model/ApplySettingsSnapshot
      (settings ["journals" "graphs" "flashcards"])))
    (driver/send! application model/OpenSettings)
    (driver/send! application model/OpenSettingsTabs)
    (driver/flush! application)
    (let [screen
          (descendant-with-identifier
           renderer (driver/root-node application) "screen.settings.tabs")
          journals
          (child-index-with-identifier
           renderer screen "row.settings.tab.journals")
          graphs
          (child-index-with-identifier renderer screen "row.settings.tab.graphs")
          flashcards
          (child-index-with-identifier
           renderer screen "row.settings.tab.flashcards")]
      (is (and (< journals graphs) (< graphs flashcards))
          "visible tab rows follow the persisted order")
      (assert-equal
       -1
       (child-index-with-identifier
        renderer screen "text.settings.tabs.available")
       "the available section is absent while every tab is visible")
      (driver/dispatch-event!
       application
       (proto/Press
        (descendant-with-identifier
         renderer screen "toggle.settings.tab.flashcards")))
      (driver/flush! application)
      (let [available
            (child-index-with-identifier
             renderer screen "text.settings.tabs.available")
            available-flashcards
            (child-index-with-identifier
             renderer screen "row.settings.tab.flashcards")]
        (is (not (= -1 available))
            "hiding a configurable tab creates the available section")
        (is (< available available-flashcards)
            "hidden tabs render under the available section")))))

(deftest settings-language-picker-exposes-and-validates-all-main-choices
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application model/OpenSettings)
    (driver/flush! application)
    (let [root (driver/root-node application)
          picker
          (descendant-with-identifier
           renderer root "picker.settings.language")]
      (assert-equal "System"
                    (property-string renderer picker proto/TextValue)
                    "the language picker renders the selected language")
      (driver/dispatch-event! application (proto/Press picker))
      (driver/flush! application)
      (let [menu
            (descendant-with-identifier
             renderer root "menu.settings.language")
            simplified-chinese
            (descendant-with-identifier
             renderer menu "button.settings.language.zh-CN")
            arabic
            (descendant-with-identifier
             renderer menu "button.settings.language.ar")]
        (is (not (= -1 menu)) "the language picker opens a controlled menu")
        (is (not (= -1 simplified-chinese))
            "the picker retains the Simplified Chinese choice")
        (is (not (= -1 arabic))
            "the picker retains the final main-branch language choice")
        (driver/dispatch-event!
         application (proto/Press simplified-chinese))
        (driver/flush! application)
        (assert-equal "zh-CN" (:language (chat/model application))
                      "selecting a language updates LG settings state")
        (is (not (:settings-language-menu-open (chat/model application)))
            "selecting a language dismisses its menu")))
    (driver/send! application model/OpenSettingsLanguageMenu)
    (driver/send! application (model/ChooseSettingsLanguage "unknown"))
    (driver/flush! application)
    (assert-equal "zh-CN" (:language (chat/model application))
                  "unknown language identifiers cannot enter LG state")
    (is (not (:settings-language-menu-open (chat/model application)))
        "rejecting an unknown language still dismisses the menu")))

(deftest settings-community-links-use-a-typed-platform-boundary
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application model/OpenSettings)
    (driver/flush! application)
    (let [root (driver/root-node application)
          report-bug
          (descendant-with-identifier
           renderer root "link.settings.community.report-bug")
          github
          (descendant-with-identifier
           renderer root "link.settings.community.github")]
      (is (not (= -1 report-bug)) "settings retain the issue tracker link")
      (is (not (= -1 github)) "settings retain the GitHub community link")
      (driver/dispatch-event! application (proto/Press github))
      (driver/flush! application)
      (assert-equal
       [(model/OpenExternalURLEffect 1 "https://github.com/logseq/logseq")]
       (:pending-effects (chat/model application))
       "community navigation stays on the typed platform boundary")
      (assert-equal
       "{\"id\":1,\"kind\":\"open-external-url\",\"text\":\"https://github.com/logseq/logseq\"}"
       (bridge/encode-effect
        (model/OpenExternalURLEffect 1 "https://github.com/logseq/logseq"))
       "the native bridge preserves the trusted community URL"))))

(deftest authentication-entry-is-lg-owned-and-idempotent
  (let [signed-out
        (model/update (model/initial)
                      (model/ApplyAuthentication "signedOut" None))
        signing-in (model/update signed-out model/SignIn)
        duplicate (model/update signing-in model/SignIn)
        in-flight (model/update signing-in (model/DequeueEffect 1))
        premature-host-failure
        (model/update
         in-flight
         (model/ApplyAuthentication
          "signedOut" (Some "Authorization was cancelled")))
        failed
        (model/update in-flight
                      (model/ResolveEffect 1 false "Hosted sign-in was cancelled"))
        signed-in
        (model/update failed (model/ApplyAuthentication "signedIn" None))
        invalid
        (model/update signed-in
                      (model/ApplyAuthentication "unexpected" (Some "bad")))]
    (assert-equal "signedOut" (:authentication-state signed-out)
                  "the platform can publish signed-out authentication")
    (assert-equal [(model/SignInEffect 1)] (:pending-effects signing-in)
                  "sign-in crosses one typed platform boundary")
    (assert-equal "signingIn" (:authentication-state signing-in)
                  "LG disables repeated sign-in while Hosted UI is active")
    (assert-equal signing-in duplicate
                  "repeated sign-in requests are ignored")
    (assert-equal "signingIn" (:authentication-state premature-host-failure)
                  "host callbacks cannot re-enable sign-in before effect resolution")
    (assert-equal "signedOut" (:authentication-state failed)
                  "failed Hosted UI returns to the signed-out screen")
    (assert-equal (Some "Hosted sign-in was cancelled")
                  (:authentication-error failed)
                  "authentication failures remain visible in LG state")
    (assert-equal "signedIn" (:authentication-state signed-in)
                  "successful authentication restores the application")
    (assert-equal signed-in invalid
                  "unknown platform authentication states are rejected")
    (assert-equal "{\"id\":9,\"kind\":\"sign-in\",\"text\":\"\"}"
                  (bridge/encode-effect (model/SignInEffect 9))
                  "Hosted UI uses a stable typed effect payload")))

(deftest authentication-screen-renders-from-lg-state
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application
                  (model/ApplyAuthentication "signedOut" None))
    (driver/flush! application)
    (let [root (driver/root-node application)
          screen (descendant-with-identifier
                  renderer root "screen.authentication")
          sign-in (descendant-with-identifier
                   renderer root "button.hosted-sign-in")]
      (is (not (= -1 screen))
          "signed-out authentication renders the LG entry screen")
      (assert-equal 1.0 (property-float renderer screen proto/GrowValue)
                    "authentication fills the available root height")
      (assert-equal "vertical"
                    (property-string
                     renderer screen proto/ContainerRelativeFrameValue)
                    "authentication owns the full vertical container")
      (assert-equal "center"
                    (property-string renderer screen proto/MainAlignment)
                    "authentication content is vertically centered")
      (assert-equal "center"
                    (property-string renderer screen proto/CrossAlignment)
                    "authentication content is horizontally centered")
      (assert-equal "<missing>"
                    (property-string renderer screen proto/BackgroundValue)
                    "authentication inherits the app theme background")
      (assert-equal "primary"
                    (property-string renderer sign-in proto/VariantValue)
                    "authentication uses main's prominent sign-in action")
      (assert-equal (Some true)
                    (descendant-enabled
                     renderer root "button.hosted-sign-in")
                    "the signed-out action is enabled")
      (driver/dispatch-event! application (proto/Press sign-in))
      (driver/flush! application)
      (assert-equal (Some false)
                    (descendant-enabled
                     renderer root "button.hosted-sign-in")
                    "the button disables while Hosted UI is active")
      (driver/send! application (model/DequeueEffect 1))
      (driver/send!
       application
       (model/ResolveEffect 1 false "Authorization was cancelled"))
      (driver/flush! application)
      (let [error
            (descendant-with-identifier
             renderer root "text.authentication-error")]
        (assert-equal "Authorization was cancelled"
                      (property-string renderer error proto/TextValue)
                      "authentication errors render inside the LG screen"))
      (driver/send! application
                    (model/ApplyAuthentication "signedIn" None))
      (driver/flush! application)
      (assert-equal -1
                    (descendant-with-identifier
                     renderer root "screen.authentication")
                    "signed-in authentication dismisses the LG entry screen"))))

(deftest outliner-editor-extension-contract-is-pinned
  (assert-equal
   "lui-extension-v1|15:outliner-editor|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:0|children:|properties:18:caret-utf16-offset:int:required:none,5:title:string:required:none,8:block-id:string:required:none|events:11:text-change[18:caret-utf16-offset:int:required,5:title:string:required],12:caret-change[18:caret-utf16-offset:int:required],6:return[18:caret-utf16-offset:int:required,5:title:string:required],9:backspace[16:selection-length:int:required,5:title:string:required]"
   (ext/fingerprint (view/outliner-editor-schema))
   "the native editor registry must match the LG wire schema"))

(deftest outliner-block-content-extension-contract-is-pinned
  (assert-equal
   "lui-extension-v1|22:outliner-block-content|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:0|children:|properties:10:asset-type:string:required:none,10:local-path:string:required:none,11:markup-json:string:required:none,12:is-completed:bool:required:none,18:youtube-target-url:string:required:none,5:title:string:required:none,8:block-id:string:required:none,8:is-asset:bool:required:none|events:10:drag-start[4:uuid:string:required],4:drop[4:uuid:string:required,9:placement:string:required],9:open-node[4:uuid:string:required]"
   (ext/fingerprint (view/outliner-block-content-schema))
   "the rich block renderer must match the LG wire schema"))

(deftest native-navigation-stack-extension-contract-is-pinned
  (let [schema (ext/schema (view/extension-registry)
                           "native-navigation-stack")
        fingerprint
        (match schema
          (Some current) (Some (ext/fingerprint current))
          None None)]
    (assert-equal
     (Some
      "lui-extension-v1|23:native-navigation-stack|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:1|children:|properties:26:composer-dismissal-enabled:bool:required:none,28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none|events:16:dismiss-composer[],4:back[5:count:int:required]")
     fingerprint
     (str "native navigation must share one pinned LG and Swift wire contract: "
          fingerprint))))

(deftest native-search-presentation-extension-contract-is-pinned
  (let [schema (ext/schema (view/extension-registry)
                           "native-search-presentation")]
    (assert-equal
     (Some
      "lui-extension-v1|26:native-search-presentation|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:1|children:|properties:5:depth:int:required:none,5:query:string:required:none,9:presented:bool:required:none|events:13:query-changed[5:query:string:required],4:back[5:count:int:required],7:dismiss[]")
     (match schema
       (Some current) (Some (ext/fingerprint current))
       None None)
     "search must use a distinct native full-screen navigation contract")))

(deftest liquid-glass-remains-an-ios-local-tweak
  (let [registry (view/extension-registry)
        schema (ext/schema registry "liquid-glass")]
    (is (ext/tweak? registry "liquid-glass")
        "app-specific appearance does not expand the standard LUI protocol")
    (assert-equal
     (Some
      "lui-tweak-v1|12:liquid-glass|profiles:ios/swiftui|properties:13:leading-inset:int:required:none,5:shape:string:required:none")
     (match schema
       (Some current) (Some (ext/tweak-fingerprint current))
       None None)
     "the native tweak registry must match the LG wire schema")))

(deftest outliner-drag-selects-once-and-drop-keeps-placement
  (let [unselected
        (chat/create
         (apple/backend
          (apple/create-with-extensions (view/extension-registry))))
        selected
        (chat/create
         (apple/backend
          (apple/create-with-extensions (view/extension-registry))))]
    (driver/start! unselected)
    (driver/send! unselected (model/BeginOutlinerDrag "source"))
    (driver/flush! unselected)
    (assert-equal
     [(model/LongPressOutlinerBlockEffect 1 "source")]
     (:pending-effects (chat/model unselected))
     "dragging an unselected block first selects it through the core")
    (driver/start! selected)
    (driver/send!
     selected
     (apply-core-snapshot None (empty-sidebar-projection) [] false "" [] []
                          None None [] ["source"] [] false []))
    (driver/flush! selected)
    (driver/send! selected (model/BeginOutlinerDrag "source"))
    (driver/flush! selected)
    (assert-equal [] (:pending-effects (chat/model selected))
                  "dragging an already selected block does not toggle selection")
    (driver/send! selected (model/DropOutlinerBlocks "target" "inside"))
    (driver/flush! selected)
    (assert-equal
     [(model/DropOutlinerBlocksEffect 1 "target" "inside")]
     (:pending-effects (chat/model selected))
     "drop placement crosses the typed LG boundary unchanged")
    (assert-equal
     "{\"id\":9,\"kind\":\"drop-outliner-blocks\",\"text\":\"target\",\"metadata\":\"after\"}"
     (bridge/encode-effect
      (model/DropOutlinerBlocksEffect 9 "target" "after"))
     "the native bridge preserves the drop target and placement")))

(deftest initial-shell-renders-the-graph-picker-without-a-selected-graph
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        remote (graph "remote" "Remote graph" false true)]
    (driver/start! application)
    (driver/flush! application)
    (let [main (main-root renderer application)
          picker (child-with-identifier renderer main "screen.graph-picker")]
      (assert-equal None (:selected-graph (chat/model application))
                    "the shell starts without an invented graph")
      (is (not (= -1 picker))
          "an empty launch matches main's graph picker")
      (assert-equal -1
                    (extension-node application "native-navigation-stack")
                    "the launch picker bypasses journal navigation chrome")
      (is (not (= -1 (child-with-identifier
                       renderer picker "button.graph-add")))
          "the launch picker can create a graph")
      (driver/send! application model/OpenSidebar)
      (driver/flush! application)
      (let [drawer (descendant-with-node-kind
                    renderer (driver/root-node application) apple/AppleDrawer)]
        (assert-equal false
                      (property-bool renderer drawer proto/Enabled)
                      "the graph picker keeps sidebar content non-interactive")
        (assert-equal false
                      (property-bool renderer drawer proto/Selected)
                      "the graph picker cannot reveal a retained open drawer"))
      (driver/send! application model/CloseSidebar)
      (driver/flush! application)
      (driver/send!
      application
      (model/ApplyCoreSnapshot
       (assoc (empty-core-projection) :graphs [remote])))
      (driver/flush! application)
      (let [updated-main (main-root renderer application)
            updated-picker
            (child-with-identifier renderer updated-main "screen.graph-picker")
            graph-row
            (descendant-with-identifier renderer updated-picker "graph.remote")
            graph-scroll
            (descendant-with-node-kind
             renderer updated-picker apple/AppleScrollView)]
        (is (not (= -1 graph-row))
            "catalog updates retain the launch picker")
        (is (not (= -1 graph-scroll))
            "the graph catalog uses main's plain scrolling card stack")
        (assert-equal (Some apple/AppleListItem)
                      (apple/node renderer graph-row)
                      "a graph card keeps native list-item interaction")
        (assert-equal 0
                      (descendant-count-with-node-kind
                       renderer graph-row apple/AppleIcon)
                      "main's graph cards do not add graph-type icons")
        (assert-equal 16
                      (property-int renderer graph-row proto/PaddingValue)
                      "graph cards preserve main's content inset")
        (assert-equal 16
                      (property-int renderer graph-row proto/CornerRadius)
                      "graph cards preserve main's corner radius")
        (assert-equal "surface"
                      (property-string renderer graph-row proto/BackgroundValue)
                      "graph cards use the app theme surface")
        (driver/dispatch-event! application (proto/Press graph-row))
        (driver/flush! application)
        (assert-equal [(model/OpenGraphEffect 1 "remote")]
                      (:pending-effects (chat/model application))
                      "a launch graph uses the typed graph lifecycle")))))

(deftest graph-picker-not-ready-status-matches-main-copy
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        preparing (graph "preparing" "Preparing graph" false false)]
    (driver/start! application)
    (driver/send!
     application
     (model/ApplyCoreSnapshot
      (assoc (empty-core-projection) :graphs [preparing])))
    (driver/flush! application)
    (let [picker (child-with-identifier
                  renderer (main-root renderer application)
                  "screen.graph-picker")
          status (descendant-with-identifier
                  renderer picker "graph.status.preparing")]
      (assert-equal "Graph is not ready for sync."
                    (property-string renderer status proto/TextValue)
                    "the unavailable graph explanation matches main"))))

(deftest graph-picker-matches-main-layout-actions-errors-and-overflow-menu
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/flush! application)
    (let [main (main-root renderer application)
          picker (child-with-identifier renderer main "screen.graph-picker")
          add (child-with-identifier renderer picker "button.graph-add")
          refresh (child-with-identifier renderer picker "button.graphs.refresh")
          overflow (extension-node application "native-overflow-menu")]
      (assert-equal 20 (property-int renderer picker proto/Gap)
                    "the picker preserves main's vertical spacing")
      (assert-equal 24 (property-int renderer picker proto/PaddingValue)
                    "the picker preserves main's page inset")
      (assert-equal "start" (property-string renderer picker proto/MainAlignment)
                    "a long graph catalog remains pinned below the safe area")
      (assert-equal "vertical"
                    (property-string renderer picker proto/ContainerRelativeFrameValue)
                    "the picker is constrained to the navigation viewport")
      (assert-equal 1.0 (property-float renderer picker proto/GrowValue)
                    "the picker fills the available navigation height")
      (assert-equal "ghost" (property-string renderer add proto/VariantValue)
                    "the add action is a plain text button")
      (assert-equal "ghost" (property-string renderer refresh proto/VariantValue)
                    "the refresh action is a plain text button")
      (is (not (= -1 overflow))
          "the picker renders the native overflow menu in its header")
      (assert-equal -1
                    (child-with-identifier renderer main "button.connection")
                    "the picker does not render a second connection control")
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent overflow "native-overflow-menu" "settings" {}))
      (driver/flush! application)
      (is (:settings-open (chat/model application))
          "the native overflow menu routes settings through LG"))
    (driver/send!
     application
     (model/SyncFailed "graph_discovery_failed\nConnection refused"))
    (driver/flush! application)
    (let [main (main-root renderer application)
          picker (child-with-identifier renderer main "screen.graph-picker")
          banner (child-with-identifier renderer picker "error.banner")]
      (is (not (= -1 banner)) "the picker displays core failures")
      (assert-equal
       "graph_discovery_failed"
       (property-string
        renderer
        (descendant-with-identifier renderer banner "error.banner.code")
        proto/TextValue)
       "the failure code remains visible")
      (assert-equal
       "Connection refused"
       (property-string
        renderer
        (descendant-with-identifier renderer banner "error.banner.message")
        proto/TextValue)
       "the failure message remains visible"))))

(deftest persisted-graph-loading-hides-the-launch-picker
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/ApplyGraphLoading true))
    (driver/flush! application)
    (let [main (main-root renderer application)]
      (is (not (= -1 (child-with-identifier
                       renderer main "journals.loading")))
          "a persisted graph renders the main loading state")
      (assert-equal -1
                    (child-with-identifier renderer main "screen.graph-picker")
                    "the launch picker does not flash while a graph loads"))
    (driver/send! application (model/ApplyGraphLoading false))
    (driver/flush! application)
    (is (not (= -1
                (child-with-identifier
                 renderer (main-root renderer application)
                 "screen.graph-picker")))
        "the empty catalog picker appears after loading completes")
    (driver/send! application (model/ApplyGraphLoading true))
    (driver/flush! application)
    (let [main (main-root renderer application)
          loading (child-with-identifier renderer main "journals.loading")]
      (assert-equal
       "Loading graphs"
       (property-string
        renderer (nth (apple/children renderer loading) 0) proto/TextValue)
       "an unselected catalog has a graph-specific loading label")
      (assert-equal -1
                    (child-with-identifier renderer main "screen.graph-picker")
                    "the picker stays hidden until the catalog is ready"))
    (let [cached
          (assoc (model/initial)
                 :selected-graph-id (Some "local")
                 :graph-loading true
                 :outliner-rows
                 [(journal-outline-row
                   "cached" "journal" "Cached" "Today" 20260827 0)])]
      (is (view/journal-root-visible? cached)
          "cached journals remain visible during a background reload"))))

(deftest graph-and-sync-actions-update-retained-status-in-place
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/flush! application)
    (let [navigation (extension-node application "native-navigation-stack")
          chrome (apple/children renderer navigation)
          title (nth chrome 2)
          sidebar-control (nth (apple/children renderer (nth chrome 1)) 0)
          sync-control (nth (apple/children renderer (nth chrome 3)) 0)
          connection-control (nth (apple/children renderer (nth chrome 4)) 0)]
      (driver/send! application model/BeginSync)
      (driver/flush! application)
      (doseq [control [sidebar-control sync-control]]
        (assert-equal "ghost"
                      (property-string renderer control proto/VariantValue)
                      "journal header actions keep semantic ghost styling"))
      (assert-equal (Some (apple/AppleExtension "native-overflow-menu"))
                    (apple/node renderer connection-control)
                    "the trailing action uses the platform-native menu")
      (assert-equal "Journal"
                    (property-string renderer title proto/TextValue)
                    "the journal root keeps the main navigation title")
      (assert-equal "Syncing"
                    (property-string renderer sync-control proto/AccessibilityLabel)
                    "begin sync exposes progress")
      (assert-equal sync-control
                    (nth (apple/children renderer (nth chrome 3)) 0)
                    "sync changes retain the native status node")

      (driver/send! application model/SyncSucceeded)
      (driver/flush! application)
      (assert-equal "Synced"
                    (property-string renderer sync-control proto/AccessibilityLabel)
                    "success is visible")

      (driver/send! application (model/SyncFailed "Network unavailable"))
      (driver/flush! application)
      (assert-equal "Sync failed"
                    (property-string renderer sync-control proto/AccessibilityLabel)
                    "the compact control matches main's failure label"))))

(deftest sync-details-render-projected-cursor-and-trigger-the-existing-pump
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        projection (assoc (empty-core-projection)
                          :selected-graph-id (Some "work")
                          :graph-name (Some "Work")
                          :sync-connected true
                          :applied-server-t (Some 42)
                          :has-pending-semantic-operations true
                          :has-pending-sync-request false)]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application (model/ApplyCoreSnapshot projection))
    (driver/flush! application)
    (assert-equal model/SyncingState (:sync-state (chat/model application))
                  "projected pending work keeps the compact status syncing")
    (let [application-root (driver/root-node application)
          sync-button
          (descendant-with-identifier renderer application-root "sync.connected")]
      (driver/dispatch-event! application (proto/Press sync-button))
      (driver/flush! application)
      (is (:sync-details-open (chat/model application))
          "sync detail presentation is LG-owned")
      (let [cursor (descendant-with-identifier
                    renderer application-root "sync.cursor")
            pending (descendant-with-identifier
                     renderer application-root "sync.pending")
            sync-now (descendant-with-identifier
                      renderer application-root "button.sync-now")]
        (assert-equal "42" (property-string renderer cursor proto/TextValue)
                      "the authoritative server cursor is visible")
        (assert-equal "Waiting to save"
                      (property-string renderer pending proto/TextValue)
                      "pending semantic work is visible")
        (driver/dispatch-event! application (proto/Press sync-now))
        (driver/flush! application)
        (assert-equal [(model/SyncNowEffect 1)]
                      (:pending-effects (chat/model application))
                      "Sync now reuses the existing platform sync pump")))))

(deftest sync-details-show-the-last-sync-failure
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application (model/SyncFailed "Network unavailable"))
    (driver/send! application model/OpenSyncDetails)
    (driver/flush! application)
    (let [error
          (descendant-with-identifier
           renderer (driver/root-node application) "sync.error")]
      (is (not (= -1 error))
          "the sync failure has a stable status-sheet identifier")
      (assert-equal "Network unavailable"
                    (property-string renderer error proto/TextValue)
                    "the status sheet preserves the actionable failure reason"))))

(deftest pending-sync-patches-preserve-the-current-screen-and-cursor
  (let [full (assoc (empty-core-projection)
                    :graph-name (Some "Work")
                    :sync-connected true
                    :applied-server-t (Some 42)
                    :has-pending-semantic-operations true)
        current (model/update (model/initial) (model/ApplyCoreSnapshot full))
        patch (assoc (empty-core-projection)
                     :is-pending-sync-patch true
                     :has-pending-semantic-operations false
                     :has-pending-sync-request false)
        updated (model/update current (model/ApplyCoreSnapshot patch))]
    (assert-equal (Some "Work") (:selected-graph updated)
                  "pending transport patches do not clear graph state")
    (assert-equal (Some 42) (:applied-server-t updated)
                  "pending transport patches preserve the server cursor")
    (is (not (:has-pending-semantic-operations updated))
        "pending transport patches update their owned sync flags")))

(deftest sidebar-state-and-page-selection-are-owned-by-lg
  (let [favorite (record model/sidebar-page (uuid "page-a") (title "Favorite"))
        recent (record model/sidebar-page (uuid "page-b") (title "Recent"))
        opened (model/update (model/initial) model/OpenSidebar)
        projected
        (model/update
         opened
         (apply-core-snapshot
          None
          (record model/sidebar-projection
            (favorites [favorite])
            (recent-pages [recent])
            (selected-page None)
            (selected-page-is-tag false)
            (selected-page-is-property false)
            (related-rows [])
            (linked-reference-rows []))
          [] false "" [] [] None None [] [] [] false []))
        selected (model/update projected (model/SelectSidebarPage "page-a"))
        journals (model/update selected model/ShowJournals)]
    (is (:sidebar-open opened) "sidebar presentation is LG-owned")
    (assert-equal [favorite] (:favorites projected)
                  "favorites come from the core projection")
    (assert-equal [recent] (:recent-pages projected)
                  "recent pages come from the core projection")
    (is (not (:sidebar-open selected))
        "selecting a page dismisses the sidebar")
    (assert-equal [(model/SelectSidebarPageEffect 1 "page-a")]
                  (:pending-effects selected)
                  "page selection crosses the typed core boundary")
    (assert-equal
     [(model/SelectSidebarPageEffect 1 "page-a")
      (model/ClearSelectedPageEffect 2)]
     (:pending-effects journals)
     "journals clears the selected core page")))

(deftest sidebar-renders-main-branch-navigation-identifiers
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        favorite (record model/sidebar-page (uuid "page-a") (title "Favorite"))
        current-graph (graph "current" "sync 2" false true)
        remote-graph (graph "remote" "Remote graph" false true)
        preparing-graph (graph "preparing" "Preparing graph" false false)
        sidebar
        (record model/sidebar-projection
          (favorites [favorite])
          (recent-pages [])
          (selected-page None)
          (selected-page-is-tag false)
          (selected-page-is-property false)
          (related-rows [])
          (linked-reference-rows []))]
    (driver/start! application)
    (driver/send! application
                  (model/ApplyCoreSnapshot
                   (assoc
                    (empty-core-projection)
                    :graph-name (Some "sync 2")
                    :selected-graph-id (Some "current")
                    :graphs [current-graph remote-graph preparing-graph]
                    :sidebar sidebar)))
    (driver/flush! application)
    (let [root (driver/root-node application)]
      (is (not (property-bool renderer root proto/Selected))
          "the native drawer starts from LG's closed state")
      (is (property-bool renderer root proto/Enabled)
          "the journal surface accepts horizontal sidebar gestures")
      (driver/send! application model/OpenSearch)
      (driver/flush! application)
      (is (not (property-bool renderer root proto/Enabled))
          "full-screen search owns the horizontal gesture")
      (driver/send! application model/CloseSearch)
      (driver/flush! application)
      (is (property-bool renderer root proto/Enabled)
          "closing search restores sidebar gestures")
      (driver/dispatch-event!
       application
       (proto/Press
        (descendant-with-identifier renderer root "button.sidebar")))
      (driver/flush! application)
      (is (property-bool renderer root proto/Selected)
          "opening the sidebar patches the controlled drawer")
      (let [sidebar-view (descendant-with-identifier renderer root "sidebar.navigation")
            sidebar-children (apple/children renderer sidebar-view)
            top-safe-area (if (empty? sidebar-children)
                            -1
                            (nth sidebar-children 0))
            dismiss
            (child-with-identifier renderer sidebar-view "button.sidebar.dismiss")
            graph-switch
            (descendant-with-identifier renderer sidebar-view
                                        "button.graph-switch")
            journals
            (child-with-identifier renderer sidebar-view "link.sidebar.journals")
            flashcards
            (child-with-identifier renderer sidebar-view "link.sidebar.flashcards")
            graphs
            (child-with-identifier renderer sidebar-view "link.sidebar.graphs")
            favorites
            (child-with-identifier renderer sidebar-view "section.sidebar.favorites")
            recent
            (child-with-identifier renderer sidebar-view "section.sidebar.recent")
            favorite-link
            (child-with-identifier renderer favorites "link.sidebar.page.page-a")]
        (assert-equal 12 (property-int renderer sidebar-view proto/PaddingValue)
                      "sidebar keeps the main branch content inset")
        (assert-equal (Some apple/AppleBox)
                      (if (= top-safe-area -1)
                        None
                        (apple/node renderer top-safe-area))
                      "the full-height drawer reserves sidebar status-bar space in LG")
        (assert-equal 52
                      (property-int renderer top-safe-area proto/HeightValue)
                      "the sidebar spacer plus outer inset matches main's 64-point top padding")
        (assert-equal graph-switch
                      (descendant-with-identifier
                       renderer
                       (nth sidebar-children 1)
                       "button.graph-switch")
                      "the graph switch follows the explicit full-screen safe-area spacer")
        (assert-equal 4 (property-int renderer sidebar-view proto/Gap)
                      "sidebar keeps the main branch row spacing")
        (assert-equal -1 dismiss
                      "the main surface owns dismissal instead of rendering a close row")
        (is (not (= graph-switch -1)) "sidebar keeps the graph switch identifier")
        (assert-equal "sync 2"
                      (property-string renderer graph-switch proto/TextValue)
                      "the graph switch displays the selected graph name")
        (assert-equal "navigation-heading"
                      (property-string renderer graph-switch proto/RoleValue)
                      "the graph switch uses the reusable navigation heading role")
        (assert-equal "app:chevron-down"
                      (property-string renderer graph-switch proto/InlineIconName)
                      "the graph switch keeps the disclosure affordance")
        (assert-equal "trailing"
                      (property-string renderer graph-switch proto/IconPlacementValue)
                      "the graph switch places its disclosure icon after the title")
        (assert-equal "navigation"
                      (property-string renderer journals proto/RoleValue)
                      "sidebar destinations use native navigation rows")
        (assert-equal "app:calendar"
                      (property-string renderer journals proto/InlineIconName)
                      "journals keeps its navigation icon")
        (is (property-bool renderer journals proto/Selected)
            "the current journal destination keeps its selected row")
        (assert-equal "app:flashcards"
                      (property-string renderer flashcards proto/InlineIconName)
                      "flashcards keeps its navigation icon")
        (assert-equal "app:folder"
                      (property-string renderer graphs proto/InlineIconName)
                      "graphs keeps its navigation icon")
        (is (not (= recent -1)) "sidebar keeps the recent section identifier")
        (assert-equal "app:document"
                      (property-string renderer favorite-link proto/InlineIconName)
                      "sidebar pages keep their document icon")
        (driver/dispatch-event! application (proto/Press favorite-link))
        (driver/flush! application)
        (is (not (property-bool renderer root proto/Selected))
            "page selection closes the controlled drawer")
        (assert-equal [(model/SelectSidebarPageEffect 1 "page-a")]
                      (:pending-effects (chat/model application))
                      "sidebar page presses reuse the typed selection effect")
        (driver/dispatch-event!
         application
         (proto/Press
          (descendant-with-identifier renderer root "button.sidebar")))
        (driver/flush! application)
        (let [reopened-sidebar
              (descendant-with-identifier renderer root "sidebar.navigation")
              switch-button
              (descendant-with-identifier
               renderer reopened-sidebar "button.graph-switch")]
          (driver/dispatch-event! application (proto/Press switch-button))
          (driver/flush! application)
          (let [menu
                (descendant-with-identifier renderer reopened-sidebar
                                            "menu.graph-switch")]
            (is (not (= menu -1)) "the graph heading opens a native menu")
            (when (not (= menu -1))
              (let [current-item
                    (child-with-identifier renderer menu "menu.graph.current")
                    preparing-item
                    (child-with-identifier renderer menu "menu.graph.preparing")]
                (is (property-bool renderer current-item proto/Selected)
                    "the current graph is selected in the native menu")
                (is (not (property-bool renderer preparing-item proto/Enabled))
                    "graphs that are not ready stay disabled"))
              (assert-equal model/JournalsDestination
                            (:destination (chat/model application))
                            "opening the graph menu keeps the current destination")
              (is (property-bool renderer root proto/Selected)
                  "opening the graph menu keeps the drawer visible")
              (driver/dispatch-event! application (proto/Dismiss menu))
              (driver/flush! application)
              (assert-equal
               -1
               (descendant-with-identifier renderer reopened-sidebar
                                           "menu.graph-switch")
               "native menu dismissal removes the retained menu")
              (driver/dispatch-event! application (proto/Press switch-button))
              (driver/flush! application)
              (let [reopened-menu
                    (descendant-with-identifier renderer reopened-sidebar
                                                "menu.graph-switch")]
                (when (not (= reopened-menu -1))
                  (let [remote-item
                        (child-with-identifier renderer reopened-menu
                                               "menu.graph.remote")]
                    (driver/dispatch-event! application (proto/Press remote-item))
                    (driver/flush! application)
                    (assert-equal
                     [(model/SelectSidebarPageEffect 1 "page-a")
                      (model/OpenGraphEffect 2 "remote")]
                     (:pending-effects (chat/model application))
                     "choosing another graph reuses the typed open-graph effect")
                    (is (not (property-bool renderer root proto/Selected))
                        "choosing a graph closes the controlled drawer")))))))))))

(deftest sidebar-drag-reserves-app-navigation
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        sidebar
        (record model/sidebar-projection
          (favorites [])
          (recent-pages [])
          (selected-page None)
          (selected-page-is-tag false)
          (selected-page-is-property false)
          (related-rows [])
          (linked-reference-rows []))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None sidebar [] false "" [] []
                                       None None [] [] [] false []))
    (driver/flush! application)
    (let [root (driver/root-node application)]
      (is (property-bool renderer root proto/Enabled)
          "the journal surface accepts horizontal sidebar gestures")
      (driver/send! application (model/RequestAppNode "node-a"))
      (driver/flush! application)
      (is (not (property-bool renderer root proto/Enabled))
          "node navigation reserves the leading-edge back gesture"))))

(deftest selected-sidebar-pages-render-their-outliner-and-related-content
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        page (record model/sidebar-page (uuid "page-a") (title "Project"))
        related-row
        (record model/outline-row
          (uuid "reference")
          (title "Linked from journal")
          (markup-json "[]")
          (youtube-target-url None)
          (breadcrumb "Journal")
          (breadcrumbs [])
          (opens-as-page false)
          (depth 0)
          (has-children false)
          (is-collapsed false)
          (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))
        content-row
        (assoc related-row :uuid "content" :title "Page content")
        sidebar
        (record model/sidebar-projection
          (favorites [page])
          (recent-pages [page])
          (selected-page (Some page))
          (selected-page-is-tag false)
          (selected-page-is-property false)
          (related-rows [related-row])
          (linked-reference-rows []))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None sidebar [] false "" [] []
                                           None None [] [] [content-row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          title (descendant-with-identifier
                 renderer (driver/root-node application) "title.main")
          related
          (descendant-with-identifier
           renderer outliner "section.node.linked-references")
          add-first
          (descendant-with-identifier
           renderer outliner "button.outliner.add-first-block")
          content
          (descendant-with-identifier renderer outliner "outliner.block.content")
          page-title
          (descendant-with-identifier renderer outliner "title.selected-page")]
      (assert-equal "Project" (property-string renderer title proto/TextValue)
                    "selected pages own the main header title")
      (is (not (= related -1))
          "selected pages render their core-projected linked references")
      (is (not (= content -1))
          "selected pages render their own projected outliner rows")
      (is (not (= page-title -1))
          "selected non-tag pages repeat their title in the content surface")
      (is (= add-first -1)
          "non-empty selected pages hide the add-first-block action"))))

(deftest flashcard-presentation-and-review-state-are-owned-by-lg
  (let [card (flashcard "card-a" "Remember […]" "Remember this"
                        [(flashcard-answer "answer-a" 0 "Child answer")]
                        true)
        projected
        (model/update
         (model/initial)
         (apply-core-snapshot None (empty-sidebar-projection) [card]
                                  false "" [] [] None None [] [] [] false []))
        shown (model/update projected model/ShowFlashcards)
        cloze (model/update shown model/RevealFlashcardCloze)
        answer (model/update cloze model/RevealFlashcardAnswer)
        reviewed (model/update answer (model/ReviewFlashcard "good"))]
    (assert-equal model/FlashcardsDestination (:destination shown)
                  "the primary destination is LG-owned")
    (is (not (:sidebar-open shown))
        "opening flashcards closes the sidebar")
    (assert-equal
     [(model/ClearSelectedPageEffect 1)
      (model/LoadFlashcardsEffect 2)]
     (:pending-effects shown)
     "entering flashcards clears page context before loading due cards")
    (is (:flashcard-cloze-revealed cloze)
        "cloze reveal is retained in LG state")
    (is (:flashcard-answer-revealed answer)
        "answer reveal is retained in LG state")
    (assert-equal
     [(model/ClearSelectedPageEffect 1)
      (model/LoadFlashcardsEffect 2)
      (model/ReviewFlashcardEffect 3 "card-a" "good")]
     (:pending-effects reviewed)
     "ratings use the current projected card identity")))

(deftest flashcard-reveal-state-resets-only-when-the-current-card-changes
  (let [first-card (flashcard "card-a" "First […]" "First answer" [] true)
        same-card (flashcard "card-a" "Updated […]" "Updated answer" [] true)
        next-card (flashcard "card-b" "Second […]" "Second answer" [] true)
        projected
        (model/update
         (model/initial)
         (apply-core-snapshot None (empty-sidebar-projection) [first-card]
                                  false "" [] [] None None [] [] [] false []))
        revealed
        (model/update
         (model/update projected model/RevealFlashcardCloze)
         model/RevealFlashcardAnswer)
        refreshed
        (model/update
         revealed
         (apply-core-snapshot None (empty-sidebar-projection) [same-card]
                                  false "" [] [] None None [] [] [] false []))
        advanced
        (model/update
         refreshed
         (apply-core-snapshot None (empty-sidebar-projection) [next-card]
                                  false "" [] [] None None [] [] [] false []))]
    (is (:flashcard-cloze-revealed refreshed)
        "a refresh of the same card retains its reveal state")
    (is (:flashcard-answer-revealed refreshed)
        "a refresh of the same card retains its answer state")
    (is (not (:flashcard-cloze-revealed advanced))
        "advancing cards hides the next cloze")
    (is (not (:flashcard-answer-revealed advanced))
        "advancing cards hides the next answer")
    (assert-equal []
                  (:pending-effects
                   (model/update (model/initial)
                                 (model/ReviewFlashcard "again")))
                  "reviewing an empty queue is a no-op")))

(deftest flashcards-render-the-main-branch-reveal-and-rating-contract
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        card (flashcard "card-a" "Remember […]" "Remember this"
                        [(flashcard-answer "answer-a" 0 "Child answer")]
                        true)]
    (driver/start! application)
    (driver/send!
     application
     (apply-core-snapshot None (empty-sidebar-projection) [card]
                              false "" [] [] None None [] [] [] false []))
    (driver/send! application model/ShowFlashcards)
    (driver/flush! application)
    (let [main (main-root renderer application)
          screen (child-with-identifier renderer main "screen.flashcards")
          question (child-with-identifier renderer screen "flashcard.question")
          show-cloze
          (child-with-identifier renderer screen "button.flashcard.show-cloze")]
      (assert-equal "Remember […]"
                    (property-string renderer question proto/TextValue)
                    "clozes start hidden")
      (driver/dispatch-event! application (proto/Press show-cloze))
      (driver/flush! application)
      (assert-equal "Remember this"
                    (property-string renderer question proto/TextValue)
                    "cloze reveal patches the retained question")
      (let [show-answer
            (child-with-identifier renderer screen "button.flashcard.show-answer")]
        (driver/dispatch-event! application (proto/Press show-answer))
        (driver/flush! application)
        (let [answer-row
              (child-with-identifier renderer screen "flashcard.answer.0")
              good
              (child-with-identifier renderer screen "button.flashcard.rating.good")]
          (assert-equal "Child answer"
                        (property-string renderer answer-row proto/TextValue)
                        "answer children appear after reveal")
          (driver/dispatch-event! application (proto/Press good))
          (driver/flush! application)
          (assert-equal
           [(model/ClearSelectedPageEffect 1)
            (model/LoadFlashcardsEffect 2)
            (model/ReviewFlashcardEffect 3 "card-a" "good")]
           (:pending-effects (chat/model application))
           "rating controls publish the typed review effect"))))))

(deftest flashcards-render-empty-and-non-cloze-control-states
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application model/ShowFlashcards)
    (driver/flush! application)
    (let [main (main-root renderer application)
          screen (child-with-identifier renderer main "screen.flashcards")]
      (is (not (= -1 (child-with-identifier renderer screen "flashcards.empty")))
          "an empty due queue preserves the existing empty state"))
    (driver/send!
     application
     (apply-core-snapshot
      None (empty-sidebar-projection)
      [(flashcard "card-a" "Plain question" "Plain question" [] false)]
      false "" [] [] None None [] [] [] false []))
    (driver/flush! application)
    (let [main (main-root renderer application)
          screen (child-with-identifier renderer main "screen.flashcards")]
      (is (= -1
             (child-with-identifier renderer screen
                                    "button.flashcard.show-cloze"))
          "cards without a cloze skip the cloze control")
      (is (not (= -1
                  (child-with-identifier renderer screen
                                         "button.flashcard.show-answer")))
          "cards without a cloze can reveal their answer immediately"))))

(deftest sidebar-flashcards-link-selects-the-flashcard-destination
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application model/OpenSidebar)
    (driver/flush! application)
    (let [root (driver/root-node application)
          sidebar (descendant-with-identifier renderer root "sidebar.navigation")
          link (child-with-identifier renderer sidebar "link.sidebar.flashcards")]
      (driver/dispatch-event! application (proto/Press link))
      (driver/flush! application)
      (assert-equal model/FlashcardsDestination
                    (:destination (chat/model application))
                    "the existing sidebar link enters the LG destination")
      (is (not (property-bool renderer root proto/Selected))
          "selecting flashcards closes the controlled drawer"))))

(deftest graph-catalog-and-lifecycle-state-are-owned-by-lg
  (let [local (graph "local" "Local graph" false true)
        remote (graph "remote" "Remote graph" true true)
        preparing (graph "preparing" "Preparing graph" false false)
        projection
        (assoc (empty-core-projection)
               :graph-name (Some "Local graph")
               :selected-graph-id (Some "local")
               :graphs [local remote preparing]
               :is-graph-encrypted false
               :is-graph-unlocked true)
        projected
        (model/update (model/initial) (model/ApplyCoreSnapshot projection))
        with-local
        (model/update projected (model/ApplyLocalGraphIds ["local"]))
        shown
        (model/update (model/update with-local model/OpenSidebar) model/ShowGraphs)
        refreshed (model/update shown model/RefreshGraphs)
        rejected (model/update refreshed (model/RequestOpenGraph "preparing"))
        opened (model/update refreshed (model/RequestOpenGraph "remote"))
        create-open (model/update shown model/OpenCreateGraph)
        named (model/update create-open (model/ChangeNewGraphName " New graph "))
        encrypted (model/update named (model/ToggleNewGraphEncrypted true))
        submitted (model/update encrypted model/SubmitCreateGraph)
        remote-delete (model/update shown (model/RequestDeleteGraph "remote"))
        delete-requested (model/update shown (model/RequestDeleteGraph "local"))
        delete-confirmed (model/update delete-requested model/ConfirmDeleteGraph)]
    (assert-equal [local remote preparing] (:graphs projected)
                  "the catalog is projected into LG state")
    (assert-equal ["local"] (:local-graph-ids with-local)
                  "downloaded graph identity comes from the platform boundary")
    (assert-equal model/GraphsDestination (:destination shown)
                  "graphs is a primary LG destination")
    (is (not (:sidebar-open shown)) "opening graphs closes the drawer")
    (assert-equal [(model/RefreshGraphsEffect 1)] (:pending-effects refreshed)
                  "refresh crosses the typed effect boundary")
    (assert-equal (:pending-effects refreshed) (:pending-effects rejected)
                  "preparing graphs cannot be opened")
    (assert-equal
     [(model/RefreshGraphsEffect 1) (model/OpenGraphEffect 2 "remote")]
     (:pending-effects opened)
     "ready graphs publish their stable id")
    (is (:create-graph-open create-open) "the add sheet is LG-owned")
    (is (:new-graph-encrypted create-open)
        "new graphs preserve main's encrypted-by-default behavior")
    (assert-equal
     [(model/CreateGraphEffect 1 "New graph" true)]
     (:pending-effects submitted)
     "graph creation trims its name and preserves encryption")
    (assert-equal (Some local) (:pending-graph-deletion delete-requested)
                  "deletion confirmation retains the selected graph")
    (assert-equal None (:pending-graph-deletion remote-delete)
                  "remote-only graphs cannot enter local deletion")
    (assert-equal [(model/DeleteLocalGraphEffect 1 "local")]
                  (:pending-effects delete-confirmed)
                  "confirming deletion publishes a platform effect")))

(deftest graphs-render-the-existing-catalog-and-modal-contract
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        local (graph "local" "Local graph" false true)
        remote (graph "remote" "Remote graph" true true)
        projection
        (assoc (empty-core-projection)
               :selected-graph-id (Some "local")
               :graphs [local remote])]
    (driver/start! application)
    (driver/send! application (model/ApplyCoreSnapshot projection))
    (driver/send! application (model/ApplyLocalGraphIds ["local"]))
    (driver/send! application model/OpenSidebar)
    (driver/flush! application)
    (let [root (driver/root-node application)
          sidebar (descendant-with-identifier renderer root "sidebar.navigation")
          link (child-with-identifier renderer sidebar "link.sidebar.graphs")]
      (driver/dispatch-event! application (proto/Press link))
      (driver/flush! application)
      (let [main (main-root renderer application)
            screen (child-with-identifier renderer main "screen.graphs")
            refresh (child-with-identifier renderer screen "button.graphs.refresh")
            add (child-with-identifier renderer screen "button.graph-add")
            local-row (child-with-identifier renderer screen "graph.local")
            remote-row (child-with-identifier renderer screen "graph.remote")
            delete
            (descendant-with-identifier renderer screen "button.graph.delete.local")]
        (assert-equal (Some apple/AppleList)
                      (apple/node renderer screen)
                      "graphs use the platform-native List container")
        (assert-equal (Some apple/AppleListItem)
                      (apple/node renderer local-row)
                      "downloaded graphs use native list rows")
        (assert-equal (Some apple/AppleListItem)
                      (apple/node renderer remote-row)
                      "remote graphs use native list rows")
        (is (not (= -1 refresh)) "graphs keeps its refresh identifier")
        (is (not (= -1 local-row)) "local graphs remain addressable")
        (is (not (= -1 remote-row)) "remote graphs remain addressable")
        (is (not (= -1 delete)) "local graphs expose deletion")
        (driver/dispatch-event! application (proto/Press add))
        (driver/flush! application)
        (let [form
              (descendant-with-identifier renderer screen "form.graph-create")
              toolbar
              (descendant-with-identifier renderer screen "toolbar.graph-create")]
          (is (not (= -1 form)) "graph fields use one native form group")
          (is (not (= -1 toolbar)) "graph actions use the navigation toolbar")
          (when (and (not (= -1 form)) (not (= -1 toolbar)))
            (assert-equal "form"
                          (property-string renderer form proto/StyleClass)
                          "graph fields retain their form presentation")
            (assert-equal "navigation-actions"
                          (property-string renderer toolbar proto/StyleClass)
                          "modal actions retain their navigation placement")
            (is (not (= -1
                        (descendant-with-identifier renderer form "field.graph-name")))
                "add graph exposes the existing graph-name field")
            (assert-equal
             "cancellation-action"
             (property-string
              renderer
              (descendant-with-identifier renderer toolbar "button.graph-add.cancel")
              proto/StyleClass)
             "Cancel uses the platform cancellation placement")
            (assert-equal
             "confirmation-action"
             (property-string
              renderer
              (descendant-with-identifier renderer toolbar "button.graph-add.confirm")
              proto/StyleClass)
             "Add uses the platform confirmation placement")
            (assert-equal
             (Some false)
             (descendant-enabled renderer toolbar "button.graph-add.confirm")
             "Add remains disabled while the graph name is blank")))))))

(deftest graph-lifecycle-effects-disable-duplicate-actions
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        local (graph "local" "Local graph" false true)
        remote (graph "remote" "Remote graph" true true)
        projection
        (assoc (empty-core-projection)
               :graphs [local remote]
               :selected-graph-id None)]
    (driver/start! application)
    (driver/send! application (model/ApplyCoreSnapshot projection))
    (driver/send! application (model/ApplyLocalGraphIds ["local"]))
    (driver/send! application model/ShowGraphs)
    (driver/send! application model/RefreshGraphs)
    (driver/send! application (model/DequeueEffect 1))
    (driver/flush! application)
    (let [screen (child-with-identifier
                  renderer (main-root renderer application) "screen.graphs")
          refresh (child-with-identifier renderer screen "button.graphs.refresh")
          loading (child-with-identifier renderer screen "graphs.loading")]
      (assert-equal (Some false)
                    (descendant-enabled renderer screen "button.graphs.refresh")
                    "an in-flight refresh cannot be requested twice")
      (is (not (= -1 loading)) "refresh renders native progress feedback")
      (assert-equal "Encrypted"
                    (property-string
                     renderer
                     (descendant-with-identifier
                      renderer screen "graph.status.remote")
                     proto/TextValue)
                    "encrypted remote graphs keep main's visible status")
      (driver/dispatch-event! application (proto/Press refresh))
      (driver/flush! application)
      (assert-equal [] (:pending-effects (chat/model application))
                    "disabled refresh does not enqueue duplicate work"))
    (driver/send! application (model/RequestDeleteGraph "local"))
    (driver/send! application model/ConfirmDeleteGraph)
    (driver/send! application (model/DequeueEffect 2))
    (driver/flush! application)
    (assert-equal
     (Some false)
     (descendant-enabled
      renderer (main-root renderer application) "button.graph.delete.local")
     "a graph cannot be deleted again while deletion is in flight")))

(deftest empty-graph-picker-replaces-refresh-with-progress-while-loading
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application model/RefreshGraphs)
    (driver/send! application (model/DequeueEffect 1))
    (driver/flush! application)
    (let [picker (child-with-identifier
                  renderer (main-root renderer application)
                  "screen.graph-picker")]
      (is (not (= -1 (child-with-identifier renderer picker "graphs.loading")))
          "an empty refreshing catalog shows progress")
      (assert-equal -1
                    (child-with-identifier
                     renderer picker "button.graphs.refresh")
                    "the empty picker hides refresh while it is running"))))

(deftest graph-deletion-confirmation-names-the-local-graph
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        local (graph "local" "Local graph" false true)
        projection
        (assoc (empty-core-projection)
               :graphs [local]
               :selected-graph-id None)]
    (driver/start! application)
    (driver/send! application (model/ApplyCoreSnapshot projection))
    (driver/send! application (model/ApplyLocalGraphIds ["local"]))
    (driver/send! application model/ShowGraphs)
    (driver/send! application (model/RequestDeleteGraph "local"))
    (driver/flush! application)
    (let [warning
          (descendant-with-identifier
           renderer
           (driver/root-node application)
           "text.graph-delete-warning")]
      (is (not (= -1 warning))
          "the graph deletion warning has a stable identifier")
      (assert-equal
       "Are you sure you want to permanently delete the graph \"Local graph\" from Logseq?"
       (property-string renderer warning proto/TextValue)
       "the confirmation identifies the graph being deleted")
      (driver/send! application model/ConfirmDeleteGraph)
      (driver/send! application (model/DequeueEffect 1))
      (driver/send! application
                    (model/ResolveEffect 1 false "Could not delete graph"))
      (driver/flush! application)
      (let [error
            (descendant-with-identifier
             renderer (driver/root-node application) "error.banner")]
        (is (not (= -1 error))
            "a platform failure remains visible after the confirmation closes")
        (assert-equal "Could not delete graph"
                      (property-string renderer error proto/TextValue)
                      "the visible error preserves the platform reason")))))

(deftest search-lifecycle-keeps-query-owned-by-the-lg-model
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/flush! application)
    (let [chrome (native-bottom-chrome renderer application)
          search-button
          (descendant-with-identifier renderer chrome "button.search")]
      (assert-equal "button.search"
                    (property-string renderer search-button
                                     proto/AccessibilityIdentifier)
                    "search keeps the main-branch accessibility identifier")
      (driver/dispatch-event! application (proto/Press search-button))
      (driver/flush! application)
      (is (:search-open (chat/model application))
          "search presentation is model-owned")
      (let [search-root (main-root renderer application)
            search-extension
            (extension-node application "native-search-presentation")
            search-panel
            (child-with-identifier renderer search-root "screen.search")]
        (assert-equal "screen.search"
                      (property-string renderer search-panel
                                       proto/AccessibilityIdentifier)
                      "search presentation keeps its screen identifier")
        (assert-equal -1
                      (descendant-with-identifier renderer search-panel
                                                  "field.search")
                      "LG does not duplicate the platform search field")
        (assert-equal -1
                      (descendant-with-identifier renderer search-root
                                                  "list.outliner")
                      "full-screen search replaces the journal list")
        (assert-equal -1
                      (child-with-identifier renderer search-root "button.sidebar")
                      "full-screen search hides the journal header controls")
        (assert-equal -1
                      (child-with-identifier renderer search-root
                                             "button.connection")
                      "full-screen search owns the complete visible surface")
        (driver/dispatch-event!
         application
         (proto/ExtensionEvent search-extension "native-search-presentation"
                               "query-changed"
                               {"query" (proto/StringValue "project alpha")}))
        (driver/flush! application)
        (assert-equal "project alpha" (:search-query (chat/model application))
                      "the query is stored in LG state")
        (driver/dispatch-event!
         application
         (proto/ExtensionEvent search-extension "native-search-presentation"
                               "dismiss" {}))
        (driver/flush! application)
        (is (not (:search-open (chat/model application)))
            "close removes the search presentation")
        (assert-equal "" (:search-query (chat/model application))
                      "close clears transient search input")
        (assert-equal -1
                      (child-with-identifier
                       renderer (main-root renderer application) "screen.search")
                      "the retained search subtree is disposed")))))

(deftest bottom-chrome-presentation-is-mutually-exclusive
  (let [journal
        (assoc (model/initial)
               :selected-graph (Some "Work")
               :selected-graph-id (Some "graph-a"))
        expanded (assoc journal :composer-expanded true)
        editing (record model/outliner-editing
                        (uuid "block-a")
                        (title "Draft")
                        (caret-utf16-offset 5))]
    (assert-equal "capture-and-search"
                  (view/bottom-chrome-presentation journal)
                  "the journal root defaults to Capture and Search")
    (assert-equal "expanded-composer"
                  (view/bottom-chrome-presentation expanded)
                  "expanded Capture replaces Search")
    (assert-equal "outliner-editor"
                  (view/bottom-chrome-presentation
                   (assoc expanded :outliner-editing (Some editing)))
                  "the editor replaces an expanded composer")
    (assert-equal "outliner-selection"
                  (view/bottom-chrome-presentation
                   (assoc expanded
                          :outliner-editing (Some editing)
                          :outliner-selected-block-ids ["block-a"]))
                  "selection has highest priority")
    (assert-equal "hidden"
                  (view/bottom-chrome-presentation
                   (assoc journal
                          :app-navigation-path [(model/NodeRoute "node-a")]))
                  "node pages do not duplicate Capture")))

(deftest composer-matches-the-main-branch-expand-draft-and-send-contract
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/flush! application)
    (let [navigation (extension-node application "native-navigation-stack")
          chrome (native-bottom-chrome renderer application)
          composer
          (descendant-with-identifier renderer chrome "surface.composer.root")
          search (descendant-with-identifier renderer chrome "button.search")
          collapsed (nth (apple/children renderer composer) 0)]
      (assert-equal (Some apple/AppleBox)
                    (apple/node renderer composer)
                    "the composer keeps intrinsic height inside a bottom overlay")
      (assert-equal (Some (proto/BoolValue false))
                    (extension-property application navigation
                                        "bottom-occupies-layout-space")
                    "Capture floats above the Outliner like main")
      (assert-equal "search"
                    (property-string renderer search proto/InlineIconName)
                    "collapsed search uses the main branch icon control")
      (assert-equal "ghost"
                    (property-string renderer search proto/VariantValue)
                    "search keeps semantic ghost styling")
      (assert-equal "button.composer.expand"
                    (property-string renderer collapsed
                                     proto/AccessibilityIdentifier)
                    "collapsed capture keeps its automation identifier")
      (assert-equal "ghost"
                    (property-string renderer collapsed proto/VariantValue)
                    "collapsed capture keeps semantic ghost styling")
      (driver/dispatch-event! application (proto/Press collapsed))
      (driver/flush! application)
      (is (:composer-expanded (chat/model application))
          "capture expands from LG-owned state")
      (assert-equal -1
                    (descendant-with-identifier renderer chrome "button.search")
                    "expanded Capture replaces Search")
      (let [expanded-row
            (descendant-with-identifier renderer chrome "row.composer.placement")
            expanded-composer
            (descendant-with-identifier renderer chrome "surface.composer.root")
            expanded (nth (apple/children renderer expanded-composer) 0)
            field (descendant-with-identifier renderer expanded "field.composer")
            controls
            (descendant-with-identifier renderer expanded "row.composer.controls")
            top-spacer
            (descendant-with-identifier renderer expanded "spacer.composer.top")
            field-controls-spacer
            (descendant-with-identifier
             renderer expanded "spacer.composer.field-controls")
            control-children (apple/children renderer controls)
            attachment
            (descendant-with-identifier renderer controls "button.attachment")
            task-status
            (descendant-with-identifier renderer controls "button.task-status")
            control-spacer
            (descendant-with-identifier
             renderer controls "spacer.composer.controls")
            send-button
            (descendant-with-identifier renderer controls "button.send")]
        (assert-equal "center"
                      (property-string renderer expanded-row
                                       proto/CrossAlignment)
                      "expanded Capture keeps intrinsic bottom-overlay height")
        (assert-equal "field.composer"
                      (property-string renderer field
                                       proto/AccessibilityIdentifier)
                      "expanded capture keeps its field identifier")
        (assert-equal 10
                      (property-int renderer expanded proto/CornerRadius)
                      "expanded capture uses main's low-radius rectangle")
        (assert-equal 16
                      (property-int renderer expanded proto/PaddingHorizontal)
                      "expanded capture keeps main's horizontal inset")
        (assert-equal 8
                      (property-int renderer expanded proto/PaddingVertical)
                      "expanded capture keeps compact vertical padding")
        (assert-equal 0
                      (property-int renderer expanded proto/Gap)
                      "explicit spacers preserve asymmetric main padding")
        (assert-equal 6
                      (property-int renderer top-spacer proto/HeightValue)
                      "the composer adds main's six-point top inset delta")
        (assert-equal 8
                      (property-int renderer field-controls-spacer
                                    proto/HeightValue)
                      "the field and controls retain main's separation")
        (assert-equal "button.attachment"
                      (property-string renderer attachment
                                       proto/AccessibilityIdentifier)
                      "attachment keeps its automation identifier")
        (assert-equal "button.task-status"
                      (property-string renderer task-status
                                       proto/AccessibilityIdentifier)
                      "task status keeps its automation identifier")
        (assert-equal 4 (count control-children)
                      "main's controls include a flexible trailing spacer")
        (assert-equal "spacer.composer.controls"
                      (property-string renderer control-spacer
                                       proto/AccessibilityIdentifier)
                      "the composer spacer remains directly testable")
        (assert-equal "app:task-todo"
                      (property-string renderer task-status proto/InlineIconName)
                      "the unset task status uses main's circular outline")
        (assert-equal 1.0
                      (property-float renderer control-spacer proto/GrowValue)
                      "a flexible spacer keeps Send at the trailing edge")
        (assert-equal "button.send"
                      (property-string renderer send-button
                                       proto/AccessibilityIdentifier)
                      "send keeps its automation identifier")
        (assert-equal "arrow-up"
                      (property-string renderer send-button proto/InlineIconName)
                      "send uses main's upward arrow")
        (assert-equal "border"
                      (property-string renderer send-button proto/BackgroundValue)
                      "an empty draft uses main's disabled gray fill")
        (assert-equal "white"
                      (property-string renderer send-button proto/ForegroundValue)
                      "send arrow contrasts with the filled surface")
        (assert-equal 40
                      (property-int renderer send-button proto/WidthValue)
                      "send keeps main's 40-point hit target")
        (assert-equal 40
                      (property-int renderer send-button proto/HeightValue)
                      "send keeps main's 40-point hit target")
        (assert-equal 20
                      (property-int renderer send-button proto/CornerRadius)
                      "send remains circular")
        (driver/dispatch-event!
         application (proto/TextChanged field "  Project note  "))
        (driver/flush! application)
        (assert-equal "black"
                      (property-string renderer send-button proto/BackgroundValue)
                      "a nonempty draft enables main's black send fill")
        (assert-equal "  Project note  "
                      (:composer-draft (chat/model application))
                      "draft text is model-owned without eager trimming")
        (driver/dispatch-event! application (proto/Press send-button))
        (driver/flush! application)
        (assert-equal "" (:composer-draft (chat/model application))
                      "successful send clears the draft")
        (assert-equal [(model/PersistComposerDraftEffect 2 "")
                       (model/SendCaptureEffect 3 "Project note")]
                      (:pending-effects (chat/model application))
                      "send clears persisted text before publishing capture")
        (assert-equal 4
                      (:next-effect-id (chat/model application))
                      "draft persistence and capture receive stable identifiers")
        (is (:composer-expanded (chat/model application))
            "send keeps the composer expanded like main")
        (assert-equal (Some (proto/BoolValue true))
                      (extension-property application navigation
                                          "composer-dismissal-enabled")
                      "the native host owns the outside-tap dismissal layer")
        (driver/dispatch-event!
         application
         (proto/ExtensionEvent navigation "native-navigation-stack"
                               "dismiss-composer" {}))
        (driver/flush! application)
        (is (not (:composer-expanded (chat/model application)))
            "the native outside-tap layer dismisses through LG state")))))

(deftest composer-dismissal-preserves-an-unsent-draft
  (let [expanded (model/update (model/initial) model/ExpandComposer)
        drafted (model/update expanded (model/ChangeComposerDraft "Later"))
        dismissed (model/update drafted model/DismissComposer)
        empty-send (model/update dismissed model/SendComposer)]
    (is (not (:composer-expanded dismissed))
        "dismiss collapses composer state")
    (assert-equal "Later" (:composer-draft dismissed)
                  "dismiss preserves the persisted draft")
    (assert-equal [(model/PersistComposerDraftEffect 2 "")
                   (model/SendCaptureEffect 3 "Later")]
                  (:pending-effects empty-send)
                  "a preserved non-empty draft can still be submitted")))

(deftest pending-outliner-text-keeps-the-latest-optimistic-edit
  (let [latest
        (record model/outliner-editing
          (uuid "block-a")
          (title "Latest local text")
          (caret-utf16-offset 17))
        stale
        (record model/outliner-editing
          (uuid "block-a")
          (title "Stale core text")
          (caret-utf16-offset 15))
        projection
        (assoc (empty-core-projection) :outliner-editing (Some stale))
        pending
        (assoc (model/initial)
               :outliner-editing (Some latest)
               :pending-effects
               [(model/ChangeOutlinerTextEffect
                 1 "block-a" "Latest local text" 17)])
        preserved
        (model/update pending (model/ApplyCoreSnapshot projection))
        settled
        (model/update
         (assoc pending :pending-effects [])
         (model/ApplyCoreSnapshot projection))]
    (assert-equal (Some latest) (:outliner-editing preserved)
                  "an older core response cannot overwrite queued typing")
    (assert-equal (Some stale) (:outliner-editing settled)
                  "the authoritative value applies after local typing settles")))

(deftest hide-keyboard-optimistically-finishes-outliner-editing
  (let [editing
        (record model/outliner-editing
          (uuid "block-a")
          (title "Latest local text")
          (caret-utf16-offset 17))
        autocomplete
        (record model/outliner-autocomplete
          (kind model/NodeAutocomplete)
          (query "Latest"))
        current
        (assoc (model/initial)
               :outliner-editing (Some editing)
               :outliner-autocomplete (Some autocomplete)
               :outliner-autocomplete-candidates [])
        updated
        (model/update current
                      (model/PerformOutlinerToolbarAction "hideKeyboard"))]
    (assert-equal None (:outliner-editing updated)
                  "hide keyboard removes the inline editor immediately")
    (assert-equal None (:outliner-autocomplete updated)
                  "hide keyboard removes autocomplete with the editor")
    (assert-equal [(model/OutlinerToolbarEffect 1 "hideKeyboard")]
                  (:pending-effects updated)
                  "core still owns committing the final editor value")))

(deftest outliner-return-handoff-retains-one-native-editor-node
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        first-row
        (journal-outline-row "block-a" "journal" "First" "Aug 28th, 2026"
                             20260828 0)
        second-row
        (journal-outline-row "block-b" "journal" "" "Aug 28th, 2026"
                             20260828 0)
        first-editing
        (record model/outliner-editing
          (uuid "block-a") (title "First") (caret-utf16-offset 5))
        second-editing
        (record model/outliner-editing
          (uuid "block-b") (title "") (caret-utf16-offset 0))]
    (driver/start! application)
    (driver/send!
     application
     (apply-core-snapshot None (empty-sidebar-projection) [] false "" [] []
                          (Some first-editing) None [] [] [first-row] false []))
    (driver/flush! application)
    (let [first-editor (extension-node application "outliner-editor")]
      (driver/send!
       application
       (apply-core-snapshot None (empty-sidebar-projection) [] false "" [] []
                            (Some second-editing) None [] []
                            [first-row second-row] false []))
      (driver/flush! application)
      (assert-equal first-editor
                    (extension-node application "outliner-editor")
                    "Return moves one retained editor between keyed rows"))))

(deftest composer-draft-restore-focus-and-dismissal-are-owned-by-lg
  (let [restored
        (model/update (model/initial)
                      (model/ApplyComposerDraft "稍后处理\nsecond line"))
        expanded (model/update restored model/ExpandComposer)
        drafted (model/update expanded (model/ChangeComposerDraft "Later"))
        dismissed (model/update drafted model/DismissComposer)]
    (assert-equal "稍后处理\nsecond line" (:composer-draft restored)
                  "the persisted draft is restored through a typed host update")
    (is (:composer-autofocus expanded)
        "expanding requests native focus on the mounted composer field")
    (is (not (:composer-autofocus drafted))
        "typing consumes the edge-triggered autofocus request")
    (assert-equal [(model/PersistComposerDraftEffect 1 "Later")]
                  (:pending-effects drafted)
                  "draft persistence crosses one coalescible platform boundary")
    (is (not (:composer-autofocus dismissed))
        "dismissal releases composer focus")
    (assert-equal "Later" (:composer-draft dismissed)
                  "dismissal keeps the persisted capture text")))

(deftest composer-renders-autofocus-and-native-outside-dismissal
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application model/ExpandComposer)
    (driver/flush! application)
    (let [root (driver/root-node application)
          navigation (extension-node application "native-navigation-stack")
          field (descendant-with-identifier renderer root "field.composer")
          dismissal-enabled
          (extension-property application navigation
                              "composer-dismissal-enabled")]
      (is (property-bool renderer field proto/Autofocus)
          "the expanded field receives the native autofocus edge")
      (assert-equal (Some (proto/BoolValue true)) dismissal-enabled
                    "expanded capture enables the native dismissal layer")
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent navigation "native-navigation-stack"
                             "dismiss-composer" {}))
      (driver/flush! application)
      (is (not (:composer-expanded (chat/model application)))
          "the native outside tap collapses the composer"))))

(deftest composer-attachment-selection-is-owned-by-lg
  (let [opened (model/update (model/initial) model/OpenAttachmentPicker)
        selected (model/update opened (model/ChooseAttachment "photos"))]
    (is (:attachment-picker-open opened)
        "the composer attachment menu is model-owned")
    (is (not (:attachment-picker-open selected))
        "choosing an attachment closes the menu")
    (assert-equal [(model/PresentAttachmentEffect 1 "photos")]
                  (:pending-effects selected)
                  "the chosen system service crosses one typed boundary")
    (assert-equal
     "{\"id\":7,\"kind\":\"present-attachment\",\"text\":\"files\"}"
     (bridge/encode-effect (model/PresentAttachmentEffect 7 "files"))
     "the native bridge preserves the attachment service kind")))

(deftest composer-attachment-menu-preserves-main-actions
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application model/ExpandComposer)
    (driver/send! application model/OpenAttachmentPicker)
    (driver/flush! application)
    (let [navigation (extension-node application "native-navigation-stack")
          files (descendant-with-identifier renderer navigation "button.attachment.files")
          camera (descendant-with-identifier renderer navigation "button.attachment.camera")
          photos (descendant-with-identifier renderer navigation "button.attachment.photos")
          audio (descendant-with-identifier renderer navigation "button.attachment.audio")]
      (doseq [action [files camera photos audio]]
        (assert-equal (Some apple/AppleMenuItem)
                      (apple/node renderer action)
                      "attachment actions are native menu items"))
      (assert-equal "File"
                    (property-string renderer files proto/TextValue)
                    "main uses the singular File action")
      (assert-equal "Photo"
                    (property-string renderer photos proto/TextValue)
                    "main uses the singular Photo action")
      (assert-equal "app:toolbar-attachment"
                    (property-string renderer files proto/InlineIconName)
                    "File keeps main's menu icon")
      (assert-equal "app:toolbar-camera"
                    (property-string renderer camera proto/InlineIconName)
                    "Camera keeps main's menu icon")
      (assert-equal "app:composer-photo"
                    (property-string renderer photos proto/InlineIconName)
                    "Photo keeps main's menu icon")
      (assert-equal "app:toolbar-audio"
                    (property-string renderer audio proto/InlineIconName)
                    "Audio recording keeps main's menu icon")
      (is (not (= -1 files)) "the attachment menu includes files")
      (is (not (= -1 camera)) "the attachment menu includes camera")
      (is (not (= -1 photos)) "the attachment menu includes photos")
      (is (not (= -1 audio)) "the attachment menu includes audio recording"))))

(deftest composer-task-status-selection-and-send-are-owned-by-lg
  (let [todo
        (task-status
         "todo" (Some "logseq.property/status.todo") "Todo"
         (Some "tabler-icon") (Some "Todo") None)
        projected
        (model/update
         (model/initial)
         (model/ApplyCoreSnapshot
          (assoc (empty-core-projection) :task-statuses [todo])))
        opened (model/update projected model/OpenTaskStatusPicker)
        selected (model/update opened (model/ChooseTaskStatus "todo"))
        drafted (model/update selected (model/ChangeComposerDraft " Follow up "))
        sent (model/update drafted model/SendComposer)
        cleared (model/update selected model/ClearTaskStatus)]
    (assert-equal todo (nth (:task-statuses projected) 0)
                  "core task statuses enter LG state before fallbacks")
    (is (:task-status-picker-open opened)
        "the task status menu is model-owned")
    (assert-equal (Some todo) (:selected-task-status selected)
                  "the chosen status remains selected for subsequent captures")
    (is (not (:task-status-picker-open selected))
        "choosing a status closes the menu")
    (assert-equal [(model/PersistComposerDraftEffect 2 "")
                   (model/SendTaskEffect 3 "Follow up" todo)]
                  (:pending-effects sent)
                  "task capture preserves its full semantic status")
    (assert-equal (Some todo) (:selected-task-status sent)
                  "sending a task preserves the selected status like main")
    (assert-equal None (:selected-task-status cleared)
                  "the status can be cleared without changing the draft")))

(deftest composer-task-status-menu-preserves-main-actions
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        todo
        (task-status
         "todo" (Some "logseq.property/status.todo") "Todo"
         (Some "tabler-icon") (Some "Todo") None)]
    (driver/start! application)
    (driver/send! application
                  (model/ApplyCoreSnapshot
                   (assoc (empty-core-projection)
                          :selected-graph-id (Some "test-graph")
                          :task-statuses [todo])))
    (driver/send! application model/ExpandComposer)
    (driver/send! application model/OpenTaskStatusPicker)
    (driver/flush! application)
    (let [navigation (extension-node application "native-navigation-stack")
          option
          (descendant-with-identifier
           renderer navigation "button.task-status.option.todo")]
      (is (not (= -1 option)) "the task status menu renders Todo")
      (assert-equal "Todo"
                    (property-string renderer option proto/TextValue)
                    "the native task status action preserves its label"))))

(deftest task-capture-has-a-stable-native-effect-payload
  (let [todo
        (task-status
         "todo" (Some "logseq.property/status.todo") "Todo"
         (Some "tabler-icon") (Some "Todo") None)]
    (assert-equal
     "{\"id\":8,\"kind\":\"send-task\",\"text\":\"Follow up\",\"metadata\":\"{\\\"uuid\\\":\\\"todo\\\",\\\"ident\\\":\\\"logseq.property/status.todo\\\",\\\"title\\\":\\\"Todo\\\",\\\"iconType\\\":\\\"tabler-icon\\\",\\\"iconId\\\":\\\"Todo\\\",\\\"iconColor\\\":null}\"}"
     (bridge/encode-effect (model/SendTaskEffect 8 "Follow up" todo))
     "the native task payload preserves semantic status metadata")))

(deftest task-status-choices-preserve-main-built-in-fallbacks
  (let [custom
        (task-status
         "waiting" (Some "user.status/waiting") "Waiting"
         (Some "tabler-icon") (Some "clock") None)
        projected
        (model/update
         (model/initial)
         (model/ApplyCoreSnapshot
          (assoc (empty-core-projection) :task-statuses [custom])))]
    (assert-equal
     ["Backlog" "Todo" "Doing" "In Review" "Done" "Canceled"]
     (mapv :title (:task-statuses (model/initial)))
     "the composer offers main's built-in choices before remote refresh")
    (assert-equal custom (nth (:task-statuses projected) 0)
                  "graph-specific statuses remain first")
    (assert-equal 7 (count (:task-statuses projected))
                  "built-in fallbacks are appended after custom statuses")))

(deftest native-bridge-drains-and-resolves-typed-effects-once
  (bridge/initialize 2 1)
  (let [application (bridge/app)]
    (driver/send! application model/ExpandComposer)
    (driver/send! application (model/ChangeComposerDraft "Project \"alpha\"\nNext"))
    (driver/send! application model/SendComposer)
    (driver/flush! application)
    (let [persist-dispatch (bridge/take-effect)
          capture-dispatch (bridge/take-effect)]
      (is (string/includes?
           persist-dispatch
           "\"effect\":{\"id\":2,\"kind\":\"persist-composer-draft\",\"text\":\"\"}")
          "the bridge clears persisted text before capture")
      (is (string/includes?
           capture-dispatch
           "\"effect\":{\"id\":3,\"kind\":\"send-capture\",\"text\":\"Project \\\"alpha\\\"\\nNext\"}")
          "the bridge emits escaped capture JSON for the host executor")
      (is (and
           (string/includes? persist-dispatch
                             "\"patch\":\"{\\\"generation\\\":")
           (string/includes? capture-dispatch
                             "\"patch\":\"{\\\"generation\\\":"))
          "each dispatch carries the dequeue patch needed for contiguous generations"))
    (assert-equal "" (bridge/take-effect)
                  "an effect is never dispatched to the host twice")
    (assert-equal [(model/PersistComposerDraftEffect 2 "")
                   (model/SendCaptureEffect 3 "Project \"alpha\"\nNext")]
                  (:in-flight-effects (chat/model application))
                  "dequeued effects remain tracked until resolution")
    (bridge/resolve-effect 2 true "")
    (bridge/resolve-effect 3 false "Network unavailable")
    (assert-equal [] (:in-flight-effects (chat/model application))
                  "resolution retires the matching in-flight effect")
    (assert-equal (Some "Network unavailable")
                  (:effect-error (chat/model application))
                  "effect failures return to LG-owned application state")
    (bridge/dispose)))

(deftest successful-effect-resolution-preserves-the-core-response-for-projection
  (let [drafted (model/update (model/initial)
                              (model/ChangeComposerDraft "Project note"))
        queued (model/update drafted model/SendComposer)
        dequeued (model/update queued (model/DequeueEffect 3))
        resolved (model/update dequeued
                               (model/ResolveEffect 3 true "{\"ok\":true}"))]
    (assert-equal [] (:in-flight-effects resolved)
                  "success retires the in-flight effect")
    (assert-equal None (:effect-error resolved)
                  "success clears the visible effect failure")
    (assert-equal (Some "{\"ok\":true}") (:last-core-response resolved)
                  "the LG projection boundary receives the core response")))

(deftest app-navigation-matches-the-main-branch-path-contract
  (let [initial (model/initial)
        first-request (model/update initial (model/RequestAppNode "page-a"))
        duplicate-request
        (model/update first-request (model/RequestAppNode "page-a"))
        nested-request
        (model/update duplicate-request (model/RequestAppNode "page-b"))]
    (assert-equal [(model/NodeRoute "page-a")]
                  (:app-navigation-path first-request)
                  "the first node request pushes one route")
    (assert-equal (:app-navigation-path first-request)
                  (:app-navigation-path duplicate-request)
                  "a consecutive duplicate route is not pushed")
    (assert-equal [(model/NodeRoute "page-a") (model/NodeRoute "page-b")]
                  (:app-navigation-path nested-request)
                  "a distinct nested route is appended")
    (assert-equal (:app-navigation-path nested-request)
                  (:app-navigation-path
                   (model/update nested-request
                                 (model/ResolveAppNode "page-b" true)))
                  "a resolved route remains presented")
    (assert-equal [(model/NodeRoute "page-a")]
                  (:app-navigation-path
                   (model/update nested-request
                                 (model/ResolveAppNode "page-b" false)))
                  "an unresolved route is removed")
    (assert-equal [(model/NodeRoute "page-a")]
                  (:app-navigation-path
                   (model/update nested-request (model/BackAppNavigation 1)))
                  "the back action removes exactly one route")))

(deftest native-header-title-follows-the-active-destination
  (let [initial (model/initial)
        page (record model/sidebar-page (uuid "page-a") (title "Project"))
        route (node-projection "node-a" "page-a" "Nested" [] [])]
    (assert-equal "Journal" (view/main-title initial)
                  "journals use the root application title")
    (assert-equal "Project"
                  (view/main-title (assoc initial :selected-page (Some page)))
                  "selected pages use their projected title")
    (assert-equal "Nested"
                  (view/main-title (assoc initial :node-routes [route]))
                  "native routes use their projected title")
    (assert-equal "Flashcards"
                  (view/main-title
                   (assoc initial :destination model/FlashcardsDestination))
                  "flashcards use their destination title")
    (assert-equal "Journal"
                  (view/main-title
                   (assoc initial :destination model/GraphsDestination))
                  "graphs preserve main's root header title")))

(deftest native-back-count-is-reduced-as-one-navigation-transition
  (let [requested-a
        (model/update (model/initial) (model/RequestAppNode "page-a"))
        requested-b
        (model/update requested-a (model/RequestAppNode "page-b"))
        returned (model/update requested-b (model/BackAppNavigation 2))]
    (assert-equal [] (:app-navigation-path returned)
                  "one native callback removes its complete returned path")
    (assert-equal
     [(model/OpenAppNodeEffect 1 "page-a")
      (model/OpenAppNodeEffect 2 "page-b")
      (model/CloseAppNodeEffect 3 "page-b")
      (model/CloseAppNodeEffect 4 "page-a")]
     (:pending-effects returned)
     "the one transition retains top-to-root core close ordering")))

(deftest navigation-requests-and-back-cross-the-core-effect-boundary
  (let [requested
        (model/update (model/initial) (model/RequestSearchNode "node-a"))
        returned (model/update requested (model/BackSearchNavigation 1))]
    (assert-equal [(model/NodeRoute "node-a")]
                  (:search-navigation-path requested)
                  "search navigation remains optimistic")
    (assert-equal [(model/OpenSearchNodeEffect 1 "node-a")]
                  (:pending-effects requested)
                  "opening a search node calls the core")
    (assert-equal [] (:search-navigation-path returned)
                  "back pops the visible search route")
    (assert-equal
     [(model/OpenSearchNodeEffect 1 "node-a")
      (model/CloseSearchNodeEffect 2 "node-a")]
     (:pending-effects returned)
     "back closes the matching core projection")))

(deftest native-search-back-and-dismiss-own-the-full-screen-search-path
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application (model/RequestAppNode "app-node"))
    (driver/send! application (model/RequestSearchNode "search-node"))
    (driver/flush! application)
    (let [navigation
          (extension-node application "native-search-presentation")]
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent navigation "native-search-presentation" "back"
                             {"count" (proto/IntValue 1)}))
      (driver/flush! application)
      (assert-equal [(model/NodeRoute "app-node")]
                    (:app-navigation-path (chat/model application))
                    "native back leaves the underlying app route intact")
      (assert-equal []
                    (:search-navigation-path (chat/model application))
                    "native back first pops the full-screen search route")
      (assert-equal
       [(model/OpenAppNodeEffect 1 "app-node")
        (model/OpenSearchNodeEffect 2 "search-node")
        (model/CloseSearchNodeEffect 3 "search-node")]
       (:pending-effects (chat/model application))
       "native search back closes the matching core projection")
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent navigation "native-search-presentation" "dismiss"
                             {}))
      (driver/flush! application)
      (is (not (:search-open (chat/model application)))
          "system dismissal closes the LG-owned search presentation"))))

(deftest native-search-query-event-updates-the-lg-search-model
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application model/OpenSearch)
    (driver/flush! application)
    (let [navigation
          (extension-node application "native-search-presentation")]
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent navigation "native-search-presentation"
                             "query-changed"
                             {"query" (proto/StringValue "project alpha")}))
      (driver/flush! application)
      (assert-equal "project alpha"
                    (:search-query (chat/model application))
                    "native searchable text must remain LG-owned state"))))

(deftest destination-navigation-ends-active-outliner-editing
  (let [editing
        (record model/outliner-editing
                (uuid "block-a")
                (title "Draft")
                (caret-utf16-offset 5))
        current (assoc (model/initial) :outliner-editing (Some editing))
        node (model/update current (model/RequestAppNode "page-a"))
        sidebar (model/update current (model/SelectSidebarPage "page-a"))
        journals (model/update current model/ShowJournals)
        flashcards (model/update current model/ShowFlashcards)
        graphs (model/update current model/ShowGraphs)
        graph-switch
        (model/update
         (assoc current :graphs [(graph "graph-a" "Work" false true)])
         (model/RequestOpenGraph "graph-a"))
        nested (assoc current
                      :app-navigation-path [(model/NodeRoute "page-a")])
        nested-sidebar (model/update nested (model/SelectSidebarPage "page-b"))
        nested-journals (model/update nested model/ShowJournals)
        nested-flashcards (model/update nested model/ShowFlashcards)
        nested-graphs (model/update nested model/ShowGraphs)]
    (doseq [updated [node sidebar journals flashcards graphs graph-switch]]
      (assert-equal None (:outliner-editing updated)
                    "destination changes clear the retained editor immediately"))
    (doseq [updated [nested-sidebar nested-journals nested-flashcards nested-graphs]]
      (assert-equal [] (:app-navigation-path updated)
                    "sidebar destinations return the native stack to its root"))
    (assert-equal 2 (count (:pending-effects node))
                  "node navigation cancels editing before opening the route")
    (assert-equal 2 (count (:pending-effects sidebar))
                  "sidebar navigation cancels editing before selecting the page")
    (assert-equal 1 (count (:pending-effects graphs))
                  "a local-only destination still cancels core editing")
    (assert-equal 2 (count (:pending-effects graph-switch))
                  "graph switches cancel editing before opening the graph")))

(deftest failed-navigation-effects-restore-the-optimistic-path
  (let [requested
        (model/update (model/initial) (model/RequestAppNode "node-a"))
        opening (model/update requested (model/DequeueEffect 1))
        open-failed
        (model/update opening (model/ResolveEffect 1 false "Open failed"))
        opened-again
        (model/update open-failed (model/RequestAppNode "node-a"))
        opened
        (model/update
         (model/update opened-again (model/DequeueEffect 2))
         (model/ResolveEffect 2 true "{\"ok\":true}"))
        returned (model/update opened (model/BackAppNavigation 1))
        closing (model/update returned (model/DequeueEffect 3))
        close-failed
        (model/update closing (model/ResolveEffect 3 false "Close failed"))]
    (assert-equal [] (:app-navigation-path open-failed)
                  "a failed open removes its optimistic route")
    (assert-equal [(model/NodeRoute "node-a")]
                  (:app-navigation-path close-failed)
                  "a failed close restores the optimistically popped route")))

(deftest active-node-route-renders-a-core-backed-navigation-screen
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        route
        (node-projection
         "node-a" "page-a" "Project"
         [(record model/outline-row
            (uuid "reference")
            (title "Linked from journal")
            (markup-json "[]")
            (youtube-target-url None)
            (breadcrumb "Journal")
            (breadcrumbs
             [(record model/sidebar-page
                (uuid "journal") (title "Journal"))])
            (opens-as-page false)
            (depth 0)
            (has-children false)
            (is-collapsed false)
            (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))]
         [])
        row (record model/outline-row
              (uuid "child") (title "Child")
              (markup-json "[]") (youtube-target-url None)
              (breadcrumb "") (breadcrumbs []) (opens-as-page false) (depth 1)
              (has-children false) (is-collapsed false)
              (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))]
    (driver/start! application)
    (driver/send! application (model/RequestAppNode "node-a"))
    (driver/send!
     application
     (apply-core-snapshot None (empty-sidebar-projection) [] false "" [] [route]
                              None None [] [] [row] false []))
    (driver/flush! application)
    (let [navigation (extension-node application "native-navigation-stack")
          screen (descendant-with-identifier renderer navigation "screen.node")
          title (descendant-with-identifier renderer screen "title.node")
          outliner (descendant-with-identifier renderer screen "scroll.outliner")
          related
          (descendant-with-identifier
           renderer outliner "section.node.linked-references")
          breadcrumb
          (descendant-with-identifier renderer related "breadcrumb.related-blocks")
          journal
          (descendant-with-identifier renderer related "button.breadcrumb.journal")]
      (assert-equal "Project"
                    (property-string renderer title proto/TextValue)
                    "the route title comes from the core projection")
      (is (not (= related -1))
          "node routes render their linked references section")
      (is (not (= breadcrumb -1))
          "related rows retain the main breadcrumb container")
      (is (not (= journal -1))
          "each structured breadcrumb remains independently navigable")
      (driver/dispatch-event! application (proto/Press journal))
      (driver/flush! application)
      (assert-equal [(model/NodeRoute "node-a") (model/NodeRoute "journal")]
                    (:app-navigation-path (chat/model application))
                    "pressing a breadcrumb opens its retained node identity")
      (driver/send! application (model/BackAppNavigation 1))
      (driver/flush! application)
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent navigation "native-navigation-stack" "back"
                             {"count" (proto/IntValue 1)}))
      (driver/flush! application)
      (assert-equal [] (:app-navigation-path (chat/model application))
                    "native back removes the presented route"))))

(deftest ios-node-navigation-is-owned-by-the-native-stack
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application
        (chat/create (apple/backend-for renderer proto/IOS proto/SwiftUIHost))
        route (node-projection "node-a" "page-a" "Project" [] [])]
    (driver/start! application)
    (driver/send! application (model/RequestAppNode "node-a"))
    (driver/send!
     application
     (apply-core-snapshot None (empty-sidebar-projection) [] false "" [] [route]
                          None None [] [] [] false []))
    (driver/flush! application)
    (let [navigation (extension-node application "native-navigation-stack")
          screen (descendant-with-identifier renderer navigation "screen.node")
          chrome (native-bottom-chrome renderer application)]
      (assert-equal -1 (child-with-identifier renderer screen "BackButton")
                    "the retained node does not duplicate the system back button")
      (assert-equal -1
                    (descendant-with-identifier renderer screen
                                                "surface.composer.root")
                    "node content does not contain a duplicate composer")
      (assert-equal -1
                    (descendant-with-identifier renderer chrome
                                                "surface.composer.root")
                    "the global bottom slot hides Capture on node pages")
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent navigation "native-navigation-stack" "back"
                             {"count" (proto/IntValue 1)}))
      (driver/flush! application)
      (assert-equal [] (:app-navigation-path (chat/model application))
                    "the native iOS back action pops the LG route"))))

(deftest native-navigation-retains-the-journal-and-every-node-route
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application
        (chat/create (apple/backend-for renderer proto/IOS proto/SwiftUIHost))
        journal-row
        (journal-outline-row "journal" "journal-page" "Journal"
                             "Aug 27th, 2026" 20260827 0)
        first-row
        (journal-outline-row "first-child" "first-page" "First child"
                             "" 0 0)
        second-row
        (journal-outline-row "second-child" "second-page" "Second child"
                             "" 0 0)
        first-route
        (assoc (node-projection "node-a" "page-a" "First" [] [])
               :outliner-rows [first-row])
        second-route
        (assoc (node-projection "node-b" "page-b" "Second" [] [])
               :outliner-rows [second-row])
        projection
        (assoc (empty-core-projection)
               :graph-name (Some "Work")
               :selected-graph-id (Some "test-graph")
               :node-routes [first-route second-route]
               :journal-outliner-rows [journal-row]
               :outliner-rows [second-row])]
    (driver/start! application)
    (driver/send! application (model/RequestAppNode "node-a"))
    (driver/send! application (model/RequestAppNode "node-b"))
    (driver/send! application (model/ApplyCoreSnapshot projection))
    (driver/flush! application)
    (let [navigation (extension-node application "native-navigation-stack")]
      (is (not (= navigation -1))
          "the Outliner is hosted by the native navigation extension")
      (assert-equal (Some (proto/IntValue 2))
                    (extension-property application navigation "depth")
                    "the native path depth follows LG state")
      (let [children (apple/children renderer navigation)]
        (assert-equal 8 (count children)
                      "native chrome slots remain separate from retained routes")
        (is (not (= -1 (descendant-with-identifier
                        renderer (nth children 0) "outliner.block.journal")))
            "the navigation root retains the journal Outliner")
        (assert-equal 0
                      (count (apple/children renderer (nth children 1)))
                      "the system back action replaces the root sidebar control")
        (assert-equal "title.main"
                      (property-string renderer (nth children 2)
                                       proto/AccessibilityIdentifier)
                      "LG supplies the native title")
        (assert-equal "app:status-dot"
                      (property-string
                       renderer
                       (descendant-with-identifier
                        renderer (nth children 3) "sync.disconnected")
                       proto/InlineIconName)
                      "LG supplies the native sync control")
        (assert-equal
         (Some (apple/AppleExtension "native-overflow-menu"))
         (apple/node renderer (nth (apple/children renderer (nth children 4)) 0))
         "LG supplies the native trailing menu")
        (assert-equal "<missing>"
                      (property-string renderer (nth children 5)
                                       proto/AccessibilityIdentifier)
                      "the internal bottom chrome slot does not override its active control identifier")
        (is (not (= -1 (descendant-with-identifier
                        renderer (nth children 6) "outliner.block.first-child")))
            "the first pushed route retains its own Outliner")
        (is (not (= -1 (descendant-with-identifier
                        renderer (nth children 7) "outliner.block.second-child")))
            "the active route renders the deepest Outliner"))
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent navigation "native-navigation-stack" "back"
                             {"count" (proto/IntValue -1)}))
      (driver/flush! application)
      (assert-equal [(model/NodeRoute "node-a") (model/NodeRoute "node-b")]
                    (:app-navigation-path (chat/model application))
                    "an invalid native back count does not mutate the path")
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent navigation "native-navigation-stack" "back"
                             {"count" (proto/IntValue 5)}))
      (driver/flush! application)
      (assert-equal [] (:app-navigation-path (chat/model application))
                    "a native multi-pop is safely clamped to the LG path"))))

(deftest app-and-search-routes-are-retained-by-distinct-native-stacks
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        app-row
        (journal-outline-row "app-child" "app-page" "App child" "" 0 0)
        search-row
        (journal-outline-row "search-child" "search-page" "Search child" "" 0 0)
        app-route
        (assoc (node-projection "app-node" "app-page" "App" [] [])
               :outliner-rows [app-row])
        search-route
        (assoc (node-projection "search-node" "search-page" "Search" [] [])
               :outliner-rows [search-row])]
    (driver/start! application)
    (driver/send! application (model/RequestAppNode "app-node"))
    (driver/send! application model/OpenSearch)
    (driver/send! application (model/RequestSearchNode "search-node"))
    (driver/send!
     application
     (model/ApplyCoreSnapshot
      (assoc (empty-core-projection)
             :graph-name (Some "Work")
             :selected-graph-id (Some "test-graph")
             :node-routes [app-route search-route]
             :outliner-rows [search-row])))
    (driver/flush! application)
    (let [app-navigation (extension-node application "native-navigation-stack")
          search-navigation
          (extension-node application "native-search-presentation")
          app-children (apple/children renderer app-navigation)
          search-children (apple/children renderer search-navigation)]
      (assert-equal (Some (proto/IntValue 1))
                    (extension-property application app-navigation "depth")
                    "the app stack owns only the app route depth")
      (assert-equal (Some (proto/IntValue 1))
                    (extension-property application search-navigation "depth")
                    "the full-screen search stack owns only its route depth")
      (assert-equal 7 (count app-children)
                    "the app stack retains chrome, its root, and app route")
      (assert-equal 3 (count search-children)
                    "search retains the app surface, search root, and search route")
      (is (not (= -1 (descendant-with-identifier
                      renderer (nth app-children 6) "outliner.block.app-child")))
          "the app route remains behind the search presentation")
      (is (not (= -1 (descendant-with-identifier
                      renderer (nth search-children 2)
                      "outliner.block.search-child")))
          "the search route is retained only by the search stack"))))

(deftest empty-node-routes-add-the-first-block-through-the-core
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        route (node-projection "page-a" "page-a" "Empty page" [] [])]
    (driver/start! application)
    (driver/send! application (model/RequestAppNode "page-a"))
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                           false "" [] [route]
                                           None None [] [] [] false []))
    (driver/flush! application)
    (let [navigation (extension-node application "native-navigation-stack")
          screen (descendant-with-identifier renderer navigation "screen.node")
          add-button
          (descendant-with-identifier
           renderer screen "button.outliner.add-first-block")]
      (driver/dispatch-event! application (proto/Press add-button))
      (driver/flush! application)
      (assert-equal
       [(model/OpenAppNodeEffect 1 "page-a")
        (model/AddRootBlockEffect 2 "page-a")]
       (:pending-effects (chat/model application))
       "empty pages reuse the core addRootBlock outliner action"))))

(deftest older-journals-use-an-invisible-scroll-sentinel
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        projection (assoc (empty-core-projection)
                          :selected-graph-id (Some "test-graph")
                          :has-older-journals true)]
    (driver/start! application)
    (driver/send! application (model/ApplyCoreSnapshot projection))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          sentinel (descendant-with-identifier
                    renderer root "outliner.load-older-sentinel")]
      (assert-equal -1
                    (descendant-with-identifier
                     renderer root "button.outliner.load-older-journals")
                    "main does not expose load-more as a visible button")
      (is (not (= sentinel -1))
          "journals expose an invisible end-of-scroll sentinel")
      (assert-equal sentinel
                    (descendant-with-identifier
                     renderer outliner "outliner.load-older-sentinel")
                    "the sentinel remains inside the virtualized Outliner")
      (assert-equal 1 (property-int renderer sentinel proto/HeightValue)
                    "the sentinel matches main's one-point marker")
      (assert-equal [] (:pending-effects (chat/model application))
                    "retained rendering alone does not eagerly load journals")
      (driver/send!
       application
       (model/ApplyCoreSnapshot (assoc projection :has-older-journals false)))
      (driver/flush! application)
      (assert-equal -1
                    (descendant-with-identifier
                     renderer (main-root renderer application)
                     "outliner.load-older-sentinel")
                    "the sentinel disappears when the core reaches the oldest journal"))))

(deftest older-journals-only-appear-at-the-journal-root
  (let [available (assoc (model/initial)
                         :selected-graph (Some "Work")
                         :has-older-journals true)
        selected-page
        (assoc available
               :selected-page
               (Some (record model/sidebar-page
                       (uuid "page-a") (title "Page"))))
        nested (assoc available
                      :node-routes
                      [(node-projection
                        "node-a" "page-a" "Node" [] [])])]
    (is (view/older-journals-visible? available))
    (is (not (view/older-journals-visible? selected-page)))
    (is (not (view/older-journals-visible? nested)))))

(deftest journal-section-markers-preserve-boundaries-and-stable-pages
  (let [unsectioned
        (assoc (journal-outline-row "draft" "" "Draft" "" 0 0)
               :journal-title None
               :journal-day None)
        first-root
        (journal-outline-row "day-a-root" "page-a" "First" "August 27th" 20260827 0)
        first-child
        (journal-outline-row "day-a-child" "page-a" "Child" "August 27th" 20260827 1)
        second-root
        (journal-outline-row "day-b-root" "page-b" "Second" "August 28th" 20260828 0)
        markers
        (model/journal-section-markers
         [unsectioned first-root first-child second-root])]
    (assert-equal ["day-a-root" "day-b-root"]
                  (mapv :block-id markers)
                  "only the first row of each journal starts a section")
    (assert-equal ["page-a" "page-b"]
                  (mapv :page-id markers)
                  "journal navigation keeps the page identity")
    (assert-equal [false true]
                  (mapv :has-divider markers)
                  "only later journal sections receive a divider")))

(deftest journal-section-markers-recompute-after-row-splices
  (let [day-a
        (journal-outline-row "day-a" "page-a" "A" "August 27th" 20260827 0)
        day-b
        (journal-outline-row "day-b" "page-b" "B" "August 28th" 20260828 0)
        day-c
        (journal-outline-row "day-c" "page-c" "C" "August 29th" 20260829 0)
        initial
        (model/update
         (model/initial)
         (model/ApplyCoreSnapshot
          (assoc (empty-core-projection)
                 :graph-name (Some "Work")
                 :selected-graph-id (Some "graph-a")
                 :has-older-journals true
                 :outliner-rows [day-a day-c])))
        splice
        (record model/outline-row-splice
          (start (Some 1))
          (after-block-id None)
          (before-block-id None)
          (delete-count 0)
          (rows [day-b]))
        updated
        (model/update
         initial
         (model/ApplyCoreSnapshot
          (assoc (empty-core-projection)
                 :is-outliner-patch true
                 :outliner-row-splices [splice])))]
    (assert-equal ["page-a" "page-b" "page-c"]
                  (mapv :page-id (:outliner-section-markers updated))
                  "splice application recomputes all journal boundaries")
    (assert-equal [false true true]
                  (mapv :has-divider (:outliner-section-markers updated))
                  "inserted sections keep exactly one divider per boundary")
    (assert-equal (Some "graph-a") (:selected-graph-id updated)
                  "outliner patches preserve the selected graph")
    (assert-equal (Some "Work") (:selected-graph updated)
                  "outliner patches preserve the graph title")
    (is (:has-older-journals updated)
        "outliner patches preserve journal pagination state")))

(deftest journal-home-renders-navigable-section-headings-and-dividers
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        day-a
        (journal-outline-row "day-a" "page-a" "A" "August 27th" 20260827 0)
        day-b
        (journal-outline-row "day-b" "page-b" "B" "August 28th" 20260828 0)]
    (driver/start! application)
    (driver/send!
     application
     (model/ApplyCoreSnapshot
      (assoc (empty-core-projection)
             :selected-graph-id (Some "test-graph")
             :outliner-rows [day-a day-b])))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner
          (descendant-with-identifier renderer root "list.outliner")
          first-heading
          (descendant-with-identifier renderer root "button.journal.page-a")
          second-heading
          (descendant-with-identifier renderer root "button.journal.page-b")
          heading-children (apple/children renderer first-heading)
          heading-surface
          (if (empty? heading-children) -1 (nth heading-children 0))
          heading-surface-children
          (if (= heading-surface -1)
            []
            (apple/children renderer heading-surface))
          heading-top-space
          (if (empty? heading-surface-children)
            -1
            (nth heading-surface-children 0))
          heading-content
          (if (< (count heading-surface-children) 2)
            -1
            (nth heading-surface-children 1))]
      (assert-equal 16
                    (property-int renderer outliner proto/PaddingValue)
                    "journal content keeps main's outer horizontal inset")
      (is (not (= first-heading -1))
          "the first journal heading is visible and navigable")
      (is (not (= second-heading -1))
          "the second journal heading is visible and navigable")
      (assert-equal "Open August 27th"
                    (property-string renderer first-heading
                                     proto/AccessibilityLabel)
                    "journal headings expose their native open action")
      (is (not (= -1 (descendant-with-identifier
                      renderer outliner "outliner.block.day-a")))
          "the first day's row stays inside the virtualized collection")
      (is (not (= -1 (descendant-with-identifier
                      renderer outliner "outliner.block.day-b")))
          "the second day's row stays inside the virtualized collection")
      (assert-equal -1
                    (descendant-with-identifier
                     renderer outliner "journal.section.page-a")
                    "journal entries do not create nested section lists")
      (assert-equal (Some apple/AppleListItem)
                    (apple/node renderer first-heading)
                    "journal headings use a plain interactive content row")
      (assert-equal 0
                    (property-int renderer first-heading proto/PaddingValue)
                    "the interactive heading row does not add a native inset")
      (assert-equal (Some apple/AppleBox)
                    (if (= heading-surface -1)
                      None
                      (apple/node renderer heading-surface))
                    "journal heading spacing is owned by one intrinsic surface")
      (assert-equal 8
                    (property-int renderer heading-surface
                                  proto/PaddingHorizontal)
                    "journal titles keep main's inner horizontal inset")
      (assert-equal 12
                    (property-int renderer heading-surface
                                  proto/PaddingVertical)
                    "journal titles keep main's bottom inset")
      (assert-equal (Some apple/AppleBox)
                    (if (= heading-top-space -1)
                      None
                      (apple/node renderer heading-top-space))
                    "journal titles express their extra top inset as layout")
      (assert-equal 14
                    (property-int renderer heading-top-space proto/HeightValue)
                    "journal title top spacing completes main's 26-point inset")
      (assert-equal (Some apple/AppleHeading)
                    (if (= heading-content -1)
                      None
                      (apple/node renderer heading-content))
                    "journal titles retain semantic heading typography")
      (assert-equal 3
                    (property-int renderer heading-content proto/HeadingLevel)
                    "journal titles map main's title2 scale")
      (is (not (= -1
                  (descendant-with-identifier
                   renderer root "journals.graph-loaded")))
          "the loaded journal graph keeps main's readiness contract")
      (assert-equal 0
                    (descendant-count-with-identifier
                     renderer root "journal.divider")
                    "journal sections do not render divider lines")
      (driver/dispatch-event! application (proto/Press second-heading))
      (driver/flush! application)
      (assert-equal [(model/OpenAppNodeEffect 1 "page-b")]
                    (:pending-effects (chat/model application))
                    "journal headings use the existing page navigation effect"))))

(deftest selected-pages-do-not-render-journal-home-headings
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        row
        (journal-outline-row "day-a" "page-a" "A" "August 27th" 20260827 0)
        selected-sidebar
        (assoc (empty-sidebar-projection)
               :selected-page
               (Some (record model/sidebar-page
                       (uuid "page-a") (title "August 27th"))))]
    (driver/start! application)
    (driver/send!
     application
     (model/ApplyCoreSnapshot
      (assoc (empty-core-projection)
             :sidebar selected-sidebar
             :outliner-rows [row])))
    (driver/flush! application)
    (let [root (main-root renderer application)]
      (assert-equal -1
                    (descendant-with-identifier
                     renderer root "button.journal.page-a")
                    "journal navigation headings stay specific to journal home"))))

(deftest search-navigation-is-isolated-and-cleared-with-the-presentation
  (let [open-model (model/update (model/initial) model/OpenSearch)
        app-model (model/update open-model (model/RequestAppNode "journal"))
        search-model
        (model/update app-model (model/RequestSearchNode "search-result"))
        failed-model
        (model/update search-model
                      (model/ResolveSearchNode "search-result" false))
        reopened-model
        (model/update
         (model/update failed-model (model/RequestSearchNode "search-result"))
         (model/ChangeSearchQuery "project alpha"))
        closed-model (model/update reopened-model model/CloseSearch)]
    (assert-equal [(model/NodeRoute "journal")]
                  (:app-navigation-path search-model)
                  "search navigation does not mutate the app path")
    (assert-equal [(model/NodeRoute "search-result")]
                  (:search-navigation-path search-model)
                  "search owns a separate navigation path")
    (assert-equal [] (:search-navigation-path failed-model)
                  "a failed search route is removed")
    (assert-equal [] (:search-navigation-path closed-model)
                  "closing search clears its navigation history")
    (assert-equal
     [(model/OpenAppNodeEffect 1 "journal")
      (model/OpenSearchNodeEffect 2 "search-result")
      (model/OpenSearchNodeEffect 3 "search-result")
      (model/CloseSearchNodeEffect 5 "search-result")]
     (:pending-effects closed-model)
     "closing search closes every core-backed search route from the top")
    (assert-equal [(model/NodeRoute "journal")]
                  (:app-navigation-path closed-model)
                  "closing search preserves the app navigation history")
    (assert-equal "" (:search-query closed-model)
                  "closing search clears its transient query")))

(deftest search-query-publishes-a-core-effect-and-rejects-stale-results
  (let [queried (model/update (model/initial)
                              (model/ChangeSearchQuery "project alpha"))
        hit (record model/search-hit
                    (uuid "page-a")
                    (title "Project Alpha")
                    (breadcrumb "")
                    (breadcrumbs [])
                    (is-page true))
        stale (model/update queried
                            (model/ApplySearchResults "older" [hit]))
        current (model/update queried
                              (model/ApplySearchResults "project alpha" [hit]))]
    (assert-equal [(model/SearchNodesEffect 1 "project alpha")]
                  (:pending-effects queried)
                  "typing publishes one typed search request")
    (is (:search-loading queried)
        "the query visibly remains in progress")
    (assert-equal [] (:search-results stale)
                  "a response for an older query is ignored")
    (assert-equal [hit] (:search-results current)
                  "the current query accepts its projected hits")
    (is (not (:search-loading current))
        "the current result ends the loading state")))

(deftest search-results-render-as-keyed-native-rows
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        hit (record model/search-hit
                    (uuid "block-a")
                    (title "Project note")
                    (breadcrumb "Journal › Parent")
                    (breadcrumbs [])
                    (is-page false))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application model/OpenSearch)
    (driver/send! application (model/ChangeSearchQuery "project"))
    (driver/send! application
                  (model/ApplySearchResults "project" [hit]))
    (driver/flush! application)
    (let [root (main-root renderer application)
          search-panel (child-with-identifier renderer root "screen.search")
          row
          (descendant-with-identifier
           renderer search-panel "search.result.block-a")]
      (assert-equal "search.result.block-a"
                    (property-string renderer row
                                     proto/AccessibilityIdentifier)
                    "the row keeps main's stable search result identifier")
      (driver/dispatch-event! application (proto/Press row))
      (driver/flush! application)
      (assert-equal [(model/NodeRoute "block-a")]
                    (:search-navigation-path (chat/model application))
                    "pressing a result requests navigation in LG state"))))

(deftest search-renders-main-empty-states-and-result-sections
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        page (record model/search-hit
                     (uuid "page-a")
                     (title "Project")
                     (breadcrumb "")
                     (breadcrumbs [])
                     (is-page true))
        block (record model/search-hit
                      (uuid "block-a")
                      (title "Project note")
                      (breadcrumb "Journal")
                      (breadcrumbs [])
                      (is-page false))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application model/OpenSearch)
    (driver/flush! application)
    (let [panel
          (child-with-identifier
           renderer (main-root renderer application) "screen.search")
          empty-state
          (descendant-with-identifier renderer panel "search.empty")]
      (assert-equal 1.0 (property-float renderer panel proto/GrowValue)
                    "native search content fills the presentation viewport")
      (assert-equal "Search your graph"
                    (property-string renderer empty-state proto/TextValue)
                    "an empty query explains the search entry state")
      (driver/send! application (model/ChangeSearchQuery "missing"))
      (driver/send! application (model/ApplySearchResults "missing" []))
      (driver/flush! application)
      (assert-equal
       "No results"
       (property-string
        renderer
        (descendant-with-identifier renderer panel "search.empty")
        proto/TextValue)
       "an empty result set is distinguished from an empty query")
      (driver/send! application (model/ChangeSearchQuery "project"))
      (driver/send! application
                    (model/ApplySearchResults "project" [block page]))
      (driver/flush! application)
      (is (not (= -1
                  (descendant-with-identifier
                   renderer panel "search.section.pages")))
          "page results have the main section label")
      (is (not (= -1
                  (descendant-with-identifier
                   renderer panel "search.section.blocks")))
          "block results have the main section label")
      (is (not (= -1
                  (descendant-with-identifier
                   renderer panel "search.result.page-a")))
          "page results remain addressable")
      (is (not (= -1
                  (descendant-with-identifier
                   renderer panel "search.result.block-a")))
          "block results remain addressable"))))

(deftest native-search-clear-updates-lg-owned-query
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application model/OpenSearch)
    (driver/send! application (model/ChangeSearchQuery "project"))
    (driver/flush! application)
    (let [search-extension
          (extension-node application "native-search-presentation")]
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent search-extension "native-search-presentation"
                             "query-changed"
                             {"query" (proto/StringValue "")}))
      (driver/flush! application)
      (assert-equal "" (:search-query (chat/model application))
                    "the platform clear affordance updates LG state"))))

(deftest core-snapshot-renders-keyed-outliner-rows
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        row (record model/outline-row
                    (uuid "block-a")
                    (title "Project note")
                    (markup-json "[]")
              (youtube-target-url None)
              (breadcrumb "")
              (breadcrumbs [])
              (opens-as-page false)
                    (depth 2)
                    (has-children true)
                    (is-collapsed false)
                    (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))
        editing (record model/outliner-editing
                        (uuid "block-a")
                        (title "Project note")
                        (caret-utf16-offset 4))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                           false "" [] []
                                           (Some editing) None [] []
                                           [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          rendered-row
          (descendant-with-identifier renderer outliner "outliner.block.block-a")]
      (assert-equal "outliner.block.block-a"
                    (property-string renderer rendered-row
                                     proto/AccessibilityIdentifier)
                    "the LG row keeps main's stable block identifier")
      (assert-equal "Edit block Project note"
                    (property-string renderer rendered-row
                                     proto/AccessibilityLabel)
                    "the LG row keeps main's edit accessibility action")
      (let [editor
            (descendant-with-extension
             renderer application rendered-row "outliner-editor")]
        (assert-equal (Some (apple/AppleExtension "outliner-editor"))
                      (apple/node renderer editor)
                      "editing uses the registered native editor service")
        (driver/dispatch-event!
         application
         (proto/ExtensionEvent
          editor "outliner-editor" "text-change"
          {"title" (proto/StringValue "Updated")
           "caret-utf16-offset" (proto/IntValue 7)}))
        (driver/flush! application)
        (assert-equal
         [(model/ChangeOutlinerTextEffect 1 "block-a" "Updated" 7)]
         (:pending-effects (chat/model application))
         "native editor events return to the typed LG reducer")
        (assert-equal model/SyncingState (:sync-state (chat/model application))
                      "typing hides stale synced state immediately")))))

(deftest outliner-rows-live-inside-a-native-virtual-list
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/flush! application)
    (let [root (driver/root-node application)
          list-node (descendant-with-identifier renderer root "list.outliner")]
      (assert-equal (Some apple/AppleVirtualList)
                    (apple/node renderer list-node)
                    "journal blocks use one native lazy scrolling collection")
      (assert-equal 1.0 (property-float renderer list-node proto/GrowValue)
                    "the journal collection owns the remaining viewport")
      (assert-equal -1
                    (descendant-with-identifier renderer root "scroll.outliner")
                    "the virtual list does not retain a redundant scroll wrapper"))))

(deftest projected-markup-renders-through-the-native-rich-block-extension
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        row (record model/outline-row
                    (uuid "block-a")
                    (title "See [[Project]]")
                    (markup-json
                     "[{\"type\":\"nodeReference\",\"uuid\":\"page-a\",\"title\":\"Project\"}]")
                    (youtube-target-url None)
                    (breadcrumb "")
                    (breadcrumbs [])
                    (opens-as-page false)
                    (depth 0)
                    (has-children false)
                    (is-collapsed false)
                    (is-asset false) (asset-type None) (local-path None)
                    (status
                     (Some (record model/task-status
                             (uuid "done")
                             (ident (Some "logseq.property/status.done"))
                             (title "Done")
                             (icon-type None) (icon-id None) (icon-color None))))
                    (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                           false "" [] [] None None [] []
                                           [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          rendered-row
          (descendant-with-identifier renderer outliner "outliner.block.block-a")
          rich-content
          (descendant-with-extension
           renderer application rendered-row "outliner-block-content")]
      (assert-equal
       (Some (apple/AppleExtension "outliner-block-content"))
       (apple/node renderer rich-content)
       "non-editing markup uses the registered native rich renderer")
      (assert-equal (Some (proto/BoolValue true))
                    (extension-property application rich-content "is-completed")
                    "completed task styling reaches the native rich renderer")
      (assert-equal (Some (proto/StringValue "block-a"))
                    (extension-property application rich-content "block-id")
                    "the native rich renderer receives its draggable block id")
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent
        rich-content "outliner-block-content" "drag-start"
        {"uuid" (proto/StringValue "block-a")}))
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent
        rich-content "outliner-block-content" "drop"
        {"uuid" (proto/StringValue "target-a")
         "placement" (proto/StringValue "before")}))
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent
        rich-content "outliner-block-content" "open-node"
        {"uuid" (proto/StringValue "page-a")}))
      (driver/flush! application)
      (assert-equal [(model/NodeRoute "page-a")]
                    (:app-navigation-path (chat/model application))
                    "rich node references return to LG-owned navigation")
      (assert-equal
       [(model/LongPressOutlinerBlockEffect 1 "block-a")
        (model/DropOutlinerBlocksEffect 2 "target-a" "before")
        (model/OpenAppNodeEffect 3 "page-a")]
       (:pending-effects (chat/model application))
       "native drag events return to the typed LG reducer"))))

(deftest projected-assets-render-and-open-through-the-native-extension
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        row (record model/outline-row
                    (uuid "asset-a")
                    (title "Photo.jpg")
                    (markup-json "[]")
                    (youtube-target-url None)
                    (breadcrumb "")
                    (breadcrumbs [])
                    (opens-as-page false)
                    (depth 0)
                    (has-children false)
                    (is-collapsed false)
                    (is-asset true)
                    (asset-type (Some "image/jpeg"))
                    (local-path (Some "Assets/Photo.jpg")) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                       false "" [] [] None None [] []
                                       [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          rendered-row
          (descendant-with-identifier renderer outliner "outliner.block.asset-a")
          rich-content
          (descendant-with-extension
           renderer application rendered-row "outliner-block-content")]
      (assert-equal (Some (proto/BoolValue true))
                    (extension-property application rich-content "is-asset")
                    "asset identity reaches the native extension")
      (assert-equal (Some (proto/StringValue "image/jpeg"))
                    (extension-property application rich-content "asset-type")
                    "asset content type reaches the native extension")
      (assert-equal (Some (proto/StringValue "Assets/Photo.jpg"))
                    (extension-property application rich-content "local-path")
                    "local path reaches the native extension")
      (driver/dispatch-event! application (proto/Press rendered-row))
      (driver/flush! application)
      (assert-equal
       [(model/PresentAssetEffect
         1 "Photo.jpg" "image/jpeg" "Assets/Photo.jpg")]
       (:pending-effects (chat/model application))
       "opening an asset crosses the typed platform-effect boundary"))))

(deftest outliner-row-press-publishes-a-typed-core-effect
  (let [current (model/initial)
        editing (model/update current (model/BeginOutlinerEdit "block-a"))]
    (assert-equal [(model/TapOutlinerBlockEffect 1 "block-a")]
                  (:pending-effects editing)
                  "tapBlock crosses the LG effect boundary")
    (assert-equal 2 (:next-effect-id editing)
                  "outliner effects share the monotonic effect sequence")))

(deftest active-page-actions-use-typed-core-and-platform-effects
  (let [page (record model/sidebar-page (uuid "page-a") (title "Project"))
        asset (record model/outline-row
                      (uuid "asset-a") (title "Photo.jpg")
                      (markup-json "[]") (youtube-target-url None)
                      (breadcrumb "") (breadcrumbs []) (opens-as-page false) (depth 0)
                      (has-children false) (is-collapsed false)
                      (is-asset true) (asset-type (Some "image/jpeg"))
                      (local-path (Some "Assets/Photo.jpg")) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))
        current (assoc (model/initial)
                       :selected-page (Some page)
                       :outliner-rows [asset])
        favorited (model/update current model/ToggleActivePageFavorite)
        shared (model/update favorited model/ShareActivePage)
        requested (model/update shared model/RequestDeleteActivePage)
        deleted (model/update requested model/ConfirmDeleteActivePage)]
    (assert-equal [(model/SetPageFavoriteEffect 1 "page-a" true)]
                  (:pending-effects favorited)
                  "favorite changes cross the semantic core boundary")
    (assert-equal
     [(model/SetPageFavoriteEffect 1 "page-a" true)
      (model/PresentPageShareEffect
       2 "Project\n- Photo.jpg" ["Assets/Photo.jpg"])]
     (:pending-effects shared)
     "sharing carries rendered text and unique local assets to the platform")
    (assert-equal (Some page) (:pending-page-deletion requested)
                  "page deletion requires explicit confirmation")
    (assert-equal
     [(model/SetPageFavoriteEffect 1 "page-a" true)
      (model/PresentPageShareEffect
       2 "Project\n- Photo.jpg" ["Assets/Photo.jpg"])
      (model/DeletePageEffect 3 "page-a")
      (model/ClearSelectedPageEffect 4)]
     (:pending-effects deleted)
     "confirmed deletion recycles the page and leaves its selected route")))

(deftest connection-menu-matches-active-page-actions
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        page (record model/sidebar-page (uuid "page-a") (title "Project"))
        sidebar (assoc (empty-sidebar-projection)
                       :favorites [page]
                       :selected-page (Some page))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None sidebar [] true "" [] []
                                       None None [] [] [] false []))
    (driver/flush! application)
    (let [connection (extension-node application "native-overflow-menu")]
      (assert-equal (Some (proto/BoolValue true))
                    (extension-property application connection
                                        "page-actions-visible")
                    "active pages expose native page actions")
      (assert-equal (Some (proto/StringValue "Unfavorite"))
                    (extension-property application connection
                                        "favorite-label")
                    "the native action label reflects favorite state")
      (assert-equal (Some (proto/BoolValue false))
                    (extension-property application connection
                                        "settings-visible")
                    "page overflow excludes graph settings")
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent connection "native-overflow-menu" "favorite" {}))
      (driver/flush! application)
      (assert-equal [(model/SetPageFavoriteEffect 1 "page-a" false)]
                    (:pending-effects (chat/model application))
                    "the native favorite action keeps its typed LG event"))))

(deftest outliner-structure-controls-use-native-navigation-and-core-effects
  (let [collapsed
        (model/update (model/initial)
                      (model/ToggleOutlinerCollapsed "parent"))
        zoomed
        (model/update collapsed (model/RequestAppNode "parent"))]
    (assert-equal
     [(model/ToggleOutlinerCollapsedEffect 1 "parent")]
     (:pending-effects collapsed)
     "collapse crosses the LG effect boundary")
    (assert-equal
     [(model/ToggleOutlinerCollapsedEffect 1 "parent")
      (model/OpenAppNodeEffect 2 "parent")]
     (:pending-effects zoomed)
     "zoom enters the native route through the ordered core effect queue")
    (assert-equal [(model/NodeRoute "parent")]
                  (:app-navigation-path zoomed)
                  "zoom is represented in the native navigation path")
    (assert-equal 3 (:next-effect-id zoomed)
                  "both structure controls advance stable effect IDs")))

(deftest outliner-task-status-selection-uses-the-core-event-boundary
  (let [todo (model/task-status "todo" "logseq.property/status.todo" "Todo" "Todo")
        done (model/task-status "done" "logseq.property/status.done" "Done" "Done")
        current (assoc (model/initial) :task-statuses [todo done])
        opened (model/update current (model/OpenOutlinerTaskStatusPicker "block-a"))
        chosen (model/update opened (model/ChooseOutlinerTaskStatus "done"))]
    (assert-equal (Some "block-a") (:outliner-task-status-block-id opened)
                  "the task-status picker keeps its target block")
    (assert-equal [(model/SetOutlinerTaskStatusEffect 1 "block-a" done)]
                  (:pending-effects chosen)
                  "status changes reuse the typed outliner core boundary")
    (assert-equal None (:outliner-task-status-block-id chosen)
                  "choosing a status dismisses the picker")))

(deftest outliner-rows-render-status-tags-and-sync-failures
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        todo (model/task-status "todo" "logseq.property/status.todo" "Todo" "Todo")
        tag (record model/sidebar-page (uuid "tag-a") (title "Project"))
        row (record model/outline-row
                    (uuid "block-a") (title "Ship it")
                    (markup-json "[]") (youtube-target-url None)
                    (breadcrumb "") (breadcrumbs []) (opens-as-page false) (depth 0)
                    (has-children false) (is-collapsed false)
                    (is-asset false) (asset-type None) (local-path None)
                    (status (Some todo)) (tags [tag])
                    (sync-status (Some "failed"))
                    (page-id "") (journal-title None) (journal-day None))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                       true "" [] [] None None [] []
                                       [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          rendered-row (descendant-with-identifier
                        renderer root "outliner.block.block-a")]
      (let [status-button (descendant-with-identifier
                           renderer rendered-row "button.block-task-status")
            tag-button (descendant-with-identifier
                        renderer rendered-row "button.block-tag.tag-a")]
        (is (not (= -1 status-button))
            "task blocks expose their status control")
        (is (not (= -1 tag-button)) "trailing tags remain interactive")
        (assert-equal "ghost"
                      (property-string renderer status-button proto/VariantValue)
                      "task status uses a plain inline-control style")
        (assert-equal "app:task-todo"
                      (property-string renderer status-button proto/InlineIconName)
                      "task status renders main's icon instead of a text caption")
        (assert-equal "<missing>"
                      (property-string renderer status-button proto/TextValue)
                      "task status does not prefix the block title with visible text")
        (assert-equal "Todo"
                      (property-string renderer status-button proto/AccessibilityLabel)
                      "the icon still announces the task status")
        (assert-equal "ghost"
                      (property-string renderer tag-button proto/VariantValue)
                      "block tags use a plain inline-control style")
        (driver/dispatch-event! application (proto/Press tag-button))
        (driver/flush! application)
        (assert-equal [(model/NodeRoute "tag-a")]
                      (:app-navigation-path (chat/model application))
                      "tag presses use LG-owned node navigation"))
      (is (not (= -1 (descendant-with-identifier
                       renderer rendered-row "outliner.sync-failed.block-a")))
          "failed block sync remains visible"))))

(deftest outliner-long-press-selection-and-toolbar-use-typed-effects
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        row (record model/outline-row
              (uuid "parent") (title "Parent")
              (markup-json "[]") (youtube-target-url None)
              (breadcrumb "") (breadcrumbs []) (opens-as-page false) (depth 0)
              (has-children false) (is-collapsed false)
              (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                           false "" [] [] None None []
                                           ["parent"] [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          chrome (native-bottom-chrome renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          rendered-row
          (descendant-with-identifier renderer outliner "outliner.block.parent")
          toolbar (descendant-with-identifier
                   renderer chrome "toolbar.outliner.selection")
          selection-buttons (apple/children renderer toolbar)
          copy-button (nth selection-buttons 0)]
      (is (property-bool renderer rendered-row proto/Selected)
          "the selected block is projected into retained row state")
      (assert-equal "toolbar.outliner.selection"
                    (property-string renderer toolbar
                                     proto/AccessibilityIdentifier)
                    "selection exposes main's stable toolbar identifier")
      (assert-equal "scroll-leading"
                    (property-string renderer toolbar proto/StyleClass)
                    "selection keeps its trailing action visible on narrow screens")
      (assert-equal "button.outliner.selection.copy"
                    (property-string renderer copy-button
                                     proto/AccessibilityIdentifier)
                    "selection actions keep main's automation identifiers")
      (doseq [button-contract
              [(tuple 0 "app:toolbar-copy" "Copy")
               (tuple 1 "app:toolbar-outdent" "Outdent")
               (tuple 2 "app:toolbar-indent" "Indent")
               (tuple 3 "app:toolbar-delete" "Delete")
               (tuple 4 "app:toolbar-copy-reference" "Copy reference")
               (tuple 5 "app:toolbar-copy-url" "Copy URL")
               (tuple 6 "app:toolbar-unselect" "Unselect")]]
        (match button-contract
          (tuple index icon caption)
          (let [button (nth selection-buttons index)]
            (assert-equal icon
                          (property-string renderer button proto/InlineIconName)
                          "selection actions retain main's iconography")
            (assert-equal caption
                          (property-string renderer button proto/TextValue)
                          "selection actions retain main's captions"))))
      (assert-equal -1
                    (descendant-with-identifier renderer chrome
                                                "surface.composer.root")
                    "selection replaces Capture")
      (assert-equal -1
                    (descendant-with-identifier renderer chrome
                                                "toolbar.outliner.editor")
                    "selection replaces the editor toolbar")
      (driver/dispatch-event! application (proto/LongPress rendered-row))
      (driver/dispatch-event! application (proto/Press copy-button))
      (driver/flush! application)
      (assert-equal
       [(model/LongPressOutlinerBlockEffect 1 "parent")
        (model/OutlinerToolbarEffect 2 "copy")]
       (:pending-effects (chat/model application))
       "selection gestures and toolbar actions cross one typed boundary"))))

(deftest outliner-editor-toolbar-and-autocomplete-use-core-owned-state
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        row (record model/outline-row
              (uuid "block-a") (title "Project [[Pro")
              (markup-json "[]") (youtube-target-url None)
              (breadcrumb "") (breadcrumbs []) (opens-as-page false) (depth 0)
              (has-children false) (is-collapsed false)
              (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))
        editing (record model/outliner-editing
                        (uuid "block-a")
                        (title "Project [[Pro")
                        (caret-utf16-offset 13))
        autocomplete (record model/outliner-autocomplete
                             (kind model/NodeAutocomplete)
                             (query "Pro"))
        candidate (record model/outliner-autocomplete-candidate
                          (index 10)
                          (label "Project Alpha")
                          (value "page-a"))]
    (driver/start! application)
    (driver/send!
     application
     (apply-core-snapshot None (empty-sidebar-projection) [] false "" [] []
                              (Some editing) (Some autocomplete) [candidate]
                              [] [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          sidebar-button
          (descendant-with-identifier renderer root "button.sidebar")
          navigation (extension-node application "native-navigation-stack")
          chrome (native-bottom-chrome renderer application)
          autocomplete-bar
          (descendant-with-identifier renderer chrome
                                      "toolbar.outliner.autocomplete")
          candidate-button (nth (apple/children renderer autocomplete-bar) 0)
          editor-toolbar
          (descendant-with-identifier renderer chrome "toolbar.outliner.editor")
          editor-buttons (apple/children renderer editor-toolbar)
          task-button (nth editor-buttons 0)]
      (is (not (property-bool renderer sidebar-button proto/Enabled))
          "editing disables both the sidebar button and drawer gesture")
      (assert-equal (Some (proto/BoolValue true))
                    (extension-property application navigation
                                        "bottom-occupies-layout-space")
                    "the editor reserves safe-area layout space like main")
      (assert-equal "button.outliner.autocomplete.0"
                    (property-string renderer candidate-button
                                     proto/AccessibilityIdentifier)
                    "autocomplete numbers the first visible candidate from zero")
      (assert-equal "vertical"
                    (property-string renderer autocomplete-bar
                                     proto/OrientationValue)
                    "autocomplete candidates retain their vertical layout")
      (assert-equal "scroll-leading"
                    (property-string renderer editor-toolbar proto/StyleClass)
                    "the editor keeps hide-keyboard visible on narrow screens")
      (assert-equal "button.outliner.editor.task"
                    (property-string renderer task-button
                                     proto/AccessibilityIdentifier)
                    "the editor toolbar keeps main's task identifier")
      (assert-equal "Task: None"
                    (property-string renderer task-button
                                     proto/AccessibilityLabel)
                    "the task action announces the active block status like main")
      (doseq [button-contract
              [(tuple 0 "app:toolbar-task")
               (tuple 1 "app:toolbar-outdent")
               (tuple 2 "app:toolbar-indent")
               (tuple 3 "app:toolbar-tag")
               (tuple 4 "app:toolbar-camera")
               (tuple 5 "app:toolbar-audio")
               (tuple 6 "app:toolbar-attachment")
               (tuple 8 "app:toolbar-hide-keyboard")]]
        (match button-contract
          (tuple index icon)
          (let [button (nth editor-buttons index)]
            (assert-equal icon
                          (property-string renderer button proto/InlineIconName)
                          "editor actions retain main's iconography")
            (assert-equal "<missing>"
                          (property-string renderer button proto/TextValue)
                          "editor icon buttons do not render text labels"))))
      (let [page-reference-button (nth editor-buttons 7)]
        (assert-equal "[[]]"
                      (property-string renderer page-reference-button
                                       proto/TextValue)
                      "page reference retains main's compact symbolic label")
        (assert-equal "<missing>"
                      (property-string renderer page-reference-button
                                       proto/InlineIconName)
                      "page reference does not replace its main-branch symbol"))
      (assert-equal -1
                    (descendant-with-identifier renderer chrome
                                                "surface.composer.root")
                    "the editor replaces Capture")
      (assert-equal -1
                    (descendant-with-identifier renderer chrome
                                                "toolbar.outliner.selection")
                    "the editor excludes the selection toolbar")
      (driver/dispatch-event! application (proto/Press candidate-button))
      (driver/dispatch-event! application (proto/Press task-button))
      (driver/flush! application)
      (assert-equal
       [(model/ChooseOutlinerAutocompleteEffect 1 "page-a")
        (model/OutlinerToolbarEffect 2 "task")]
       (:pending-effects (chat/model application))
       "autocomplete and editor actions cross the typed core boundary")
      (assert-equal model/SyncingState (:sync-state (chat/model application))
                    "a task mutation hides stale synced state immediately"))))

(deftest outliner-rows-preserve-depth-zoom-and-collapse-controls
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        row (record model/outline-row
                    (uuid "parent")
                    (title "Parent")
                    (markup-json "[]")
              (youtube-target-url None)
              (breadcrumb "")
              (breadcrumbs [])
              (opens-as-page false)
                    (depth 2)
                    (has-children true)
                    (is-collapsed false)
                    (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                           false "" [] [] None None [] []
                                           [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          rendered-row
          (descendant-with-identifier renderer outliner "outliner.block.parent")
          column (nth (apple/children renderer rendered-row) 0)
          content (nth (apple/children renderer column) 0)
          content-children (apple/children renderer content)
          indent (nth content-children 0)
          zoom (nth content-children 1)
          collapse (nth content-children 3)]
      (assert-equal 44 (property-int renderer indent proto/WidthValue)
                    "depth uses main's 22-point indentation")
      (assert-equal "button.outliner.zoom.parent"
                    (property-string renderer zoom
                                     proto/AccessibilityIdentifier)
                    "zoom keeps main's stable identifier")
      (assert-equal 24 (property-int renderer zoom proto/WidthValue)
                    "zoom uses main's 24-point bullet hit width")
      (assert-equal 24 (property-int renderer zoom proto/HeightValue)
                    "zoom uses main's 24-point bullet hit height")
      (assert-equal "app:status-dot"
                    (property-string renderer zoom proto/InlineIconName)
                    "zoom renders main's circular bullet instead of a text glyph")
      (assert-equal "border"
                    (property-string renderer zoom proto/ForegroundValue)
                    "the bullet uses main's translucent secondary color")
      (assert-equal 0 (count (apple/children renderer zoom))
                    "the graphical bullet has no baseline-dependent text child")
      (assert-equal "ghost"
                    (property-string renderer zoom proto/VariantValue)
                    "zoom uses main's plain bullet control style")
      (assert-equal "button.outliner.collapse.parent"
                    (property-string renderer collapse
                                     proto/AccessibilityIdentifier)
                    "collapse keeps main's stable identifier")
      (assert-equal 28 (property-int renderer collapse proto/WidthValue)
                    "collapse keeps main's 28-point disclosure width")
      (assert-equal 28 (property-int renderer collapse proto/HeightValue)
                    "collapse keeps main's 28-point disclosure height")
      (assert-equal "ghost"
                    (property-string renderer collapse proto/VariantValue)
                    "collapse uses main's plain disclosure control style")
      (driver/dispatch-event! application (proto/Press zoom))
      (driver/dispatch-event! application (proto/Press collapse))
      (driver/flush! application)
      (assert-equal
       [(model/OpenAppNodeEffect 1 "parent")
        (model/ToggleOutlinerCollapsedEffect 2 "parent")]
       (:pending-effects (chat/model application))
       "both controls route through LG without triggering row editing")
      (assert-equal [(model/NodeRoute "parent")]
                    (:app-navigation-path (chat/model application))
                    "zoom participates in native Back navigation"))))

(deftest outliner-row-splices-update-the-existing-keyed-projection
  (let [parent (record model/outline-row
                 (uuid "parent") (title "Parent")
                 (markup-json "[]") (youtube-target-url None)
                 (breadcrumb "") (breadcrumbs []) (opens-as-page false) (depth 0)
                 (has-children true) (is-collapsed false)
                 (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))
        child (record model/outline-row
                (uuid "child") (title "Child")
                (markup-json "[]") (youtube-target-url None)
                (breadcrumb "") (breadcrumbs []) (opens-as-page false) (depth 1)
                (has-children false) (is-collapsed false)
                (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))
        sibling (record model/outline-row
                  (uuid "sibling") (title "Sibling")
                  (markup-json "[]") (youtube-target-url None)
                  (breadcrumb "") (breadcrumbs []) (opens-as-page false) (depth 0)
                  (has-children false) (is-collapsed false)
                  (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))
        collapsed-parent (record model/outline-row
                           (uuid "parent") (title "Parent")
                           (markup-json "[]") (youtube-target-url None)
                           (breadcrumb "") (breadcrumbs []) (opens-as-page false) (depth 0)
                           (has-children true) (is-collapsed true)
                           (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None) (page-id "") (journal-title None) (journal-day None))
        initial
        (model/update
         (model/initial)
         (apply-core-snapshot None (empty-sidebar-projection) []
                                  false "" [] [] None None [] []
                                  [parent child sibling] false []))
        splice (record model/outline-row-splice
                       (start (Some 0))
                       (after-block-id None)
                       (before-block-id None)
                       (delete-count 2)
                       (rows [collapsed-parent]))
        collapsed
        (model/update
         initial
         (apply-core-snapshot None (empty-sidebar-projection) []
                                  false "" [] [] None None [] [] []
                                  true [splice]))]
    (assert-equal [collapsed-parent sibling]
                  (:outliner-rows collapsed)
                  "a bounded core splice preserves unaffected keyed rows")))

(deftest native-bridge-returns-initial-and-disposal-patch-batches
  (let [initial-patch (bridge/initialize 2 1)]
    (is (not (= "" initial-patch)))
    (is (> (bridge/root-node) 0))
    (is (not (= "" (bridge/dispose))))))

(deftest native-bridge-preserves-native-search-query-values
  (bridge/initialize 2 1)
  (let [application (bridge/app)]
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application model/OpenSearch)
    (driver/flush! application)
    (let [search (extension-node application "native-search-presentation")]
      (bridge/extension-event search "native-search-presentation"
                              "query-changed" "project alpha" 0)
      (assert-equal "project alpha" (:search-query (chat/model application))
                    "the native bridge preserves the declared query field"))
    (bridge/dispose)))

(deftest native-bridge-preserves-native-navigation-back-counts
  (bridge/initialize 2 1)
  (let [application (bridge/app)]
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application (model/RequestAppNode "page-a"))
    (driver/flush! application)
    (let [navigation (extension-node application "native-navigation-stack")]
      (bridge/extension-event navigation "native-navigation-stack" "back" "" 1)
      (assert-equal [] (:app-navigation-path (chat/model application))
                    "the native bridge preserves the declared back count"))
    (bridge/dispose)))
