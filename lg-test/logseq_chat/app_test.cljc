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
  (let [stack (nth (apple/children renderer (driver/root-node application)) 0)
        children (apple/children renderer stack)
        container (nth children (dec (count children)))
        extensions
        (deref (:runtime-extension-nodes (driver/runtime application)))]
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
      container)))

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
    (let [root (main-root renderer application)]
      (is (not (= -1 (descendant-with-identifier renderer root
                                                  "screen.settings")))
          "settings retain their baseline screen identifier")
      (is (not (= -1 (descendant-with-identifier renderer root
                                                  "link.settings.tabs")))
          "settings expose tabs navigation")
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
          sign-in (descendant-with-identifier
                   renderer root "button.hosted-sign-in")]
      (is (not (= -1 (descendant-with-identifier
                      renderer root "screen.authentication")))
          "signed-out authentication renders the LG entry screen")
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
                           "native-navigation-stack")]
    (assert-equal
     (Some
      "lui-extension-v1|23:native-navigation-stack|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:1|children:|properties:5:depth:int:required:none|events:4:back[5:count:int:required]")
     (match schema
       (Some current) (Some (ext/fingerprint current))
       None None)
     "native navigation must share one pinned LG and Swift wire contract")))

(deftest native-search-presentation-extension-contract-is-pinned
  (let [schema (ext/schema (view/extension-registry)
                           "native-search-presentation")]
    (assert-equal
     (Some
      "lui-extension-v1|26:native-search-presentation|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:1|children:|properties:5:depth:int:required:none,9:presented:bool:required:none|events:4:back[5:count:int:required],7:dismiss[]")
     (match schema
       (Some current) (Some (ext/fingerprint current))
       None None)
     "search must use a distinct native full-screen navigation contract")))

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
      (is (not (= -1 (child-with-identifier
                       renderer picker "button.graph-add")))
          "the launch picker can create a graph")
      (driver/send!
      application
      (model/ApplyCoreSnapshot
       (assoc (empty-core-projection) :graphs [remote])))
      (driver/flush! application)
      (let [updated-main (main-root renderer application)
            updated-picker
            (child-with-identifier renderer updated-main "screen.graph-picker")
            graph-row
            (descendant-with-identifier renderer updated-picker "graph.remote")]
        (is (not (= -1 graph-row))
            "catalog updates retain the launch picker")
        (driver/dispatch-event! application (proto/Press graph-row))
        (driver/flush! application)
        (assert-equal [(model/OpenGraphEffect 1 "remote")]
                      (:pending-effects (chat/model application))
                      "a launch graph uses the typed graph lifecycle")))))

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
    (let [children (apple/children renderer (main-root renderer application))
          graph-label (nth children 1)
          sync-label (nth children 2)]
      (driver/send! application model/BeginSync)
      (driver/flush! application)
      (assert-equal "Work"
                    (property-string renderer graph-label proto/TextValue)
                    "selecting a graph patches its title")
      (assert-equal "Syncing"
                    (property-string renderer sync-label proto/TextValue)
                    "begin sync exposes progress")
      (assert-equal sync-label
                    (nth (apple/children renderer (main-root renderer application)) 2)
                    "sync changes retain the native status node")

      (driver/send! application model/SyncSucceeded)
      (driver/flush! application)
      (assert-equal "Up to date"
                    (property-string renderer sync-label proto/TextValue)
                    "success is visible")

      (driver/send! application (model/SyncFailed "Network unavailable"))
      (driver/flush! application)
      (assert-equal "Sync failed: Network unavailable"
                    (property-string renderer sync-label proto/TextValue)
                    "failure retains its actionable reason"))))

(deftest sync-details-render-projected-cursor-and-trigger-the-existing-pump
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        projection (assoc (empty-core-projection)
                          :graph-name (Some "Work")
                          :sync-connected true
                          :applied-server-t (Some 42)
                          :has-pending-semantic-operations true
                          :has-pending-sync-request false)]
    (driver/start! application)
    (driver/send! application (model/ApplyCoreSnapshot projection))
    (driver/flush! application)
    (let [root (main-root renderer application)
          sync-button (descendant-with-identifier renderer root "sync.connected")]
      (driver/dispatch-event! application (proto/Press sync-button))
      (driver/flush! application)
      (is (:sync-details-open (chat/model application))
          "sync detail presentation is LG-owned")
      (let [root-children (apple/children renderer root)
            sheet (nth root-children (dec (count root-children)))
            cursor (descendant-with-identifier renderer sheet "sync.cursor")
            pending (descendant-with-identifier renderer sheet "sync.pending")
            sync-now (descendant-with-identifier renderer sheet "button.sync-now")]
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
                  (apply-core-snapshot None sidebar [] false "" [] []
                                           None None [] [] [] false []))
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
        (child-with-identifier
         renderer (main-root renderer application) "button.sidebar")))
      (driver/flush! application)
      (is (property-bool renderer root proto/Selected)
          "opening the sidebar patches the controlled drawer")
      (let [sidebar-view (child-with-identifier renderer root "sidebar.navigation")
            dismiss
            (child-with-identifier renderer sidebar-view "button.sidebar.dismiss")
            graph-switch
            (child-with-identifier renderer sidebar-view "button.graph-switch")
            favorites
            (child-with-identifier renderer sidebar-view "section.sidebar.favorites")
            recent
            (child-with-identifier renderer sidebar-view "section.sidebar.recent")
            favorite-link
            (child-with-identifier renderer favorites "link.sidebar.page.page-a")]
        (is (not (= dismiss -1)) "sidebar keeps its dismiss identifier")
        (is (not (= graph-switch -1)) "sidebar keeps the graph switch identifier")
        (is (not (= recent -1)) "sidebar keeps the recent section identifier")
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
          (child-with-identifier
           renderer (main-root renderer application) "button.sidebar")))
        (driver/flush! application)
        (let [reopened-sidebar
              (child-with-identifier renderer root "sidebar.navigation")
              switch-button
              (child-with-identifier
               renderer reopened-sidebar "button.graph-switch")]
          (driver/dispatch-event! application (proto/Press switch-button))
          (driver/flush! application)
          (assert-equal model/GraphsDestination
                        (:destination (chat/model application))
                        "switch graph opens the graph catalog")
          (is (not (property-bool renderer root proto/Selected))
              "switching graphs closes the controlled drawer"))))))

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
                                           None None [] [] [] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          title (child-with-identifier renderer root "title.main")
          related
          (child-with-identifier renderer root "section.node.linked-references")
          add-first
          (child-with-identifier renderer root "button.outliner.add-first-block")]
      (assert-equal "Project" (property-string renderer title proto/TextValue)
                    "selected pages own the main header title")
      (is (not (= related -1))
          "selected pages render their core-projected linked references")
      (is (not (= add-first -1))
          "empty selected pages preserve the add-first-block action"))))

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
          sidebar (child-with-identifier renderer root "sidebar.navigation")
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
          sidebar (child-with-identifier renderer root "sidebar.navigation")
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
    (let [root (main-root renderer application)
          search-button (nth (apple/children renderer root) 3)]
      (assert-equal "button.search"
                    (property-string renderer search-button
                                     proto/AccessibilityIdentifier)
                    "search keeps the main-branch accessibility identifier")
      (driver/dispatch-event! application (proto/Press search-button))
      (driver/flush! application)
      (is (:search-open (chat/model application))
          "search presentation is model-owned")
      (let [search-root (main-root renderer application)
            search-panel
            (child-with-identifier renderer search-root "screen.search")
            search-field (nth (apple/children renderer search-panel) 0)
            close-button (nth (apple/children renderer search-panel) 1)]
        (assert-equal "screen.search"
                      (property-string renderer search-panel
                                       proto/AccessibilityIdentifier)
                      "search presentation keeps its screen identifier")
        (assert-equal "field.search"
                      (property-string renderer search-field
                                       proto/AccessibilityIdentifier)
                      "search field keeps its automation identifier")
        (assert-equal "button.search.close"
                      (property-string renderer close-button
                                       proto/AccessibilityIdentifier)
                      "close keeps its automation identifier")
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
         application (proto/TextChanged search-field "project alpha"))
        (driver/flush! application)
        (assert-equal "project alpha" (:search-query (chat/model application))
                      "the query is stored in LG state")
        (driver/dispatch-event! application (proto/Press close-button))
        (driver/flush! application)
        (is (not (:search-open (chat/model application)))
            "close removes the search presentation")
        (assert-equal "" (:search-query (chat/model application))
                      "close clears transient search input")
        (assert-equal -1
                      (child-with-identifier
                       renderer (main-root renderer application) "screen.search")
                      "the retained search subtree is disposed")))))

(deftest composer-matches-the-main-branch-expand-draft-and-send-contract
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/flush! application)
    (let [root (main-root renderer application)
          composer (child-with-identifier renderer root "surface.composer.root")
          collapsed (nth (apple/children renderer composer) 0)]
      (assert-equal "button.composer.expand"
                    (property-string renderer collapsed
                                     proto/AccessibilityIdentifier)
                    "collapsed capture keeps its automation identifier")
      (driver/dispatch-event! application (proto/Press collapsed))
      (driver/flush! application)
      (is (:composer-expanded (chat/model application))
          "capture expands from LG-owned state")
      (let [expanded (nth (apple/children renderer composer) 0)
            field (nth (apple/children renderer expanded) 0)
            controls (nth (apple/children renderer expanded) 1)
            attachment (nth (apple/children renderer controls) 0)
            task-status (nth (apple/children renderer controls) 1)
            send-button (nth (apple/children renderer controls) 2)]
        (assert-equal "field.composer"
                      (property-string renderer field
                                       proto/AccessibilityIdentifier)
                      "expanded capture keeps its field identifier")
        (assert-equal "button.attachment"
                      (property-string renderer attachment
                                       proto/AccessibilityIdentifier)
                      "attachment keeps its automation identifier")
        (assert-equal "button.task-status"
                      (property-string renderer task-status
                                       proto/AccessibilityIdentifier)
                      "task status keeps its automation identifier")
        (assert-equal "button.send"
                      (property-string renderer send-button
                                       proto/AccessibilityIdentifier)
                      "send keeps its automation identifier")
        (driver/dispatch-event!
         application (proto/TextChanged field "  Project note  "))
        (driver/flush! application)
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
            "send keeps the composer expanded like main")))))

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

(deftest composer-renders-autofocus-and-an-outside-dismissal-surface
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application model/ExpandComposer)
    (driver/flush! application)
    (let [root (driver/root-node application)
          field (descendant-with-identifier renderer root "field.composer")
          dismissal
          (descendant-with-identifier renderer root "surface.composer.dismiss")]
      (is (property-bool renderer field proto/Autofocus)
          "the expanded field receives the native autofocus edge")
      (is (not (= -1 dismissal))
          "expanded capture renders the main-branch dismissal surface")
      (driver/dispatch-event! application (proto/Press dismissal))
      (driver/flush! application)
      (is (not (:composer-expanded (chat/model application)))
          "pressing outside collapses the composer"))))

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
    (driver/send! application model/ExpandComposer)
    (driver/send! application model/OpenAttachmentPicker)
    (driver/flush! application)
    (let [root (driver/root-node application)
          files (descendant-with-identifier renderer root "button.attachment.files")
          camera (descendant-with-identifier renderer root "button.attachment.camera")
          photos (descendant-with-identifier renderer root "button.attachment.photos")
          audio (descendant-with-identifier renderer root "button.attachment.audio")]
      (is (not (= -1 files)) "the attachment menu includes files")
      (is (not (= -1 camera)) "the attachment menu includes camera")
      (is (not (= -1 photos)) "the attachment menu includes photos")
      (is (not (= -1 audio)) "the attachment menu includes audio recording")
      (driver/dispatch-event! application (proto/Press photos))
      (driver/flush! application)
      (assert-equal [(model/PresentAttachmentEffect 1 "photos")]
                    (:pending-effects (chat/model application))
                    "the visible menu dispatches its selected service"))))

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
                   (assoc (empty-core-projection) :task-statuses [todo])))
    (driver/send! application model/ExpandComposer)
    (driver/send! application model/OpenTaskStatusPicker)
    (driver/flush! application)
    (let [root (driver/root-node application)
          option
          (descendant-with-identifier
           renderer root "button.task-status.option.todo")]
      (is (not (= -1 option)) "the task status menu renders Todo")
      (driver/dispatch-event! application (proto/Press option))
      (driver/flush! application)
      (assert-equal (Some todo)
                    (:selected-task-status (chat/model application))
                    "the visible task status action updates LG"))))

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
         (model/RequestOpenGraph "graph-a"))]
    (doseq [updated [node sidebar journals flashcards graphs graph-switch]]
      (assert-equal None (:outliner-editing updated)
                    "destination changes clear the retained editor immediately"))
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
          title (child-with-identifier renderer screen "title.node")
          related
          (child-with-identifier renderer screen "section.node.linked-references")
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
          screen (descendant-with-identifier renderer navigation "screen.node")]
      (assert-equal -1 (child-with-identifier renderer screen "BackButton")
                    "the retained node does not duplicate the system back button")
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
        (assert-equal 3 (count children)
                      "the root and both pushed routes remain retained")
        (is (not (= -1 (descendant-with-identifier
                        renderer (nth children 0) "outliner.block.journal")))
            "the navigation root retains the journal Outliner")
        (is (not (= -1 (descendant-with-identifier
                        renderer (nth children 1) "outliner.block.first-child")))
            "the first pushed route retains its own Outliner")
        (is (not (= -1 (descendant-with-identifier
                        renderer (nth children 2) "outliner.block.second-child")))
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
      (assert-equal 2 (count app-children)
                    "the app stack retains its root and app route")
      (assert-equal 3 (count search-children)
                    "search retains the app surface, search root, and search route")
      (is (not (= -1 (descendant-with-identifier
                      renderer (nth app-children 1) "outliner.block.app-child")))
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
          (child-with-identifier renderer screen "button.outliner.add-first-block")]
      (driver/dispatch-event! application (proto/Press add-button))
      (driver/flush! application)
      (assert-equal
       [(model/OpenAppNodeEffect 1 "page-a")
        (model/AddRootBlockEffect 2 "page-a")]
       (:pending-effects (chat/model application))
       "empty pages reuse the core addRootBlock outliner action"))))

(deftest older-journals-are-loaded-explicitly
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        projection (assoc (empty-core-projection)
                          :selected-graph-id (Some "test-graph")
                          :has-older-journals true)]
    (driver/start! application)
    (driver/send! application (model/ApplyCoreSnapshot projection))
    (driver/flush! application)
    (let [root (main-root renderer application)
          button (descendant-with-identifier
                  renderer root "button.outliner.load-older-journals")]
      (is (not (= button -1))
          "journals expose an explicit load-older control")
      (driver/dispatch-event! application (proto/Press button))
      (driver/flush! application)
      (assert-equal [(model/LoadOlderJournalsEffect 1)]
                    (:pending-effects (chat/model application))
                    "loading older journals remains a typed core effect"))))

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
          (assoc (empty-core-projection) :outliner-rows [day-a day-c])))
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
                  "inserted sections keep exactly one divider per boundary")))

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
          first-heading
          (descendant-with-identifier renderer root "button.journal.page-a")
          second-heading
          (descendant-with-identifier renderer root "button.journal.page-b")]
      (is (not (= first-heading -1))
          "the first journal heading is visible and navigable")
      (is (not (= second-heading -1))
          "the second journal heading is visible and navigable")
      (is (not (= -1
                  (descendant-with-identifier
                   renderer root "journals.graph-loaded")))
          "the loaded journal graph keeps main's readiness contract")
      (assert-equal 1
                    (descendant-count-with-identifier
                     renderer root "journal.divider")
                    "two journal sections render one divider")
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

(deftest non-empty-search-renders-an-explicit-clear-control
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/send! application model/OpenSearch)
    (driver/send! application (model/ChangeSearchQuery "project"))
    (driver/flush! application)
    (let [root (main-root renderer application)
          search-panel (child-with-identifier renderer root "screen.search")
          clear-button
          (child-with-identifier renderer search-panel "button.search.clear")]
      (is (not (= clear-button -1))
          "a non-empty search exposes main's explicit clear control")
      (driver/dispatch-event! application (proto/Press clear-button))
      (driver/flush! application)
      (assert-equal "" (:search-query (chat/model application))
                    "clearing search updates LG state"))))

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
      (let [column (nth (apple/children renderer rendered-row) 0)
            content (nth (apple/children renderer column) 0)
            editor (nth (apple/children renderer content) 2)]
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
         "native editor events return to the typed LG reducer")))))

(deftest outliner-rows-live-inside-a-native-scroll-container
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/send! application (model/SelectGraph "Work"))
    (driver/flush! application)
    (let [root (driver/root-node application)
          scroll (descendant-with-identifier renderer root "scroll.outliner")
          list-node (descendant-with-identifier renderer root "list.outliner")]
      (is (not (= -1 scroll))
          "journal blocks use LUI's retained native scroll region")
      (is (not (= -1 list-node))
          "the outliner keeps its vertical flow inside the scroll region"))))

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
          column (nth (apple/children renderer rendered-row) 0)
          content (nth (apple/children renderer column) 0)
          rich-content (nth (apple/children renderer content) 3)]
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
          column (nth (apple/children renderer rendered-row) 0)
          content (nth (apple/children renderer column) 0)
          rich-content (nth (apple/children renderer content) 2)]
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
        sidebar (assoc (empty-sidebar-projection) :selected-page (Some page))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None sidebar [] true "" [] []
                                       None None [] [] [] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          connection (descendant-with-identifier renderer root "button.connection")]
      (driver/dispatch-event! application (proto/Press connection))
      (driver/flush! application)
      (assert-equal false
                    (= -1 (descendant-with-identifier
                           renderer root "button.page-favorite"))
                    "active pages expose Favorite")
      (assert-equal false
                    (= -1 (descendant-with-identifier
                           renderer root "button.page-share"))
                    "active pages expose Share")
      (let [delete (descendant-with-identifier renderer root "button.page-delete")]
        (assert-equal false (= -1 delete) "active pages expose Delete")
        (driver/dispatch-event! application (proto/Press delete))
        (driver/flush! application)
        (assert-equal (Some page)
                      (:pending-page-deletion (chat/model application))
                      "Delete opens the LG-owned confirmation state")))))

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
      (is (not (= -1 (descendant-with-identifier
                       renderer rendered-row "button.block-task-status")))
          "task blocks expose their status control")
      (let [tag-button (descendant-with-identifier
                        renderer rendered-row "button.block-tag.tag-a")]
        (is (not (= -1 tag-button)) "trailing tags remain interactive")
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
          outliner (descendant-with-identifier renderer root "list.outliner")
          rendered-row
          (descendant-with-identifier renderer outliner "outliner.block.parent")
          toolbar (child-with-identifier
                   renderer root "toolbar.outliner.selection")
          copy-button (nth (apple/children renderer toolbar) 0)]
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
                          (index 0)
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
          autocomplete-bar
          (child-with-identifier renderer root "toolbar.outliner.autocomplete")
          candidate-button (nth (apple/children renderer autocomplete-bar) 0)
          editor-toolbar
          (child-with-identifier renderer root "toolbar.outliner.editor")
          task-button (nth (apple/children renderer editor-toolbar) 0)]
      (assert-equal "button.outliner.autocomplete.0"
                    (property-string renderer candidate-button
                                     proto/AccessibilityIdentifier)
                    "autocomplete keeps main's first candidate identifier")
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
      (driver/dispatch-event! application (proto/Press candidate-button))
      (driver/dispatch-event! application (proto/Press task-button))
      (driver/flush! application)
      (assert-equal
       [(model/ChooseOutlinerAutocompleteEffect 1 "page-a")
        (model/OutlinerToolbarEffect 2 "task")]
       (:pending-effects (chat/model application))
       "autocomplete and editor actions cross the typed core boundary"))))

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
      (assert-equal "button.outliner.collapse.parent"
                    (property-string renderer collapse
                                     proto/AccessibilityIdentifier)
                    "collapse keeps main's stable identifier")
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
