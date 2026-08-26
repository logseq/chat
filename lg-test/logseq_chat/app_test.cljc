(ns logseq-chat.app-test
  (:require [clojure.test :refer [deftest is testing]]
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

(defn main-root [renderer application]
  (let [stack (nth (apple/children renderer (driver/root-node application)) 0)
        children (apple/children renderer stack)]
    (nth children (dec (count children)))))

(defn empty-sidebar-projection []
  (record model/sidebar-projection
    (favorites [])
    (recent-pages [])
    (selected-page None)
    (selected-page-is-tag false)
    (selected-page-is-property false)
    (related-rows [])
    (linked-reference-rows [])))

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
    (outliner-editing None)
    (outliner-autocomplete None)
    (outliner-autocomplete-candidates [])
    (outliner-selected-block-ids [])
    (outliner-rows [])
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
     [(model/RefreshRuntimeLogEffect 1 "ui" true false)]
     (:pending-effects refreshed)
     "refreshing diagnostics crosses one typed platform boundary")))

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
    (assert-equal ["journals" "flashcards" "graphs"]
                  (:sidebar-tabs required-toggled)
                  "journals cannot be hidden")
    (assert-equal ["journals" "flashcards" "graphs"]
                  (:sidebar-tabs required-moved)
                  "journals remains the first required tab")))

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
    (assert-equal None (:selected-graph-id deleted)
                  "deleting the selected local graph clears its identifier")
    (assert-equal None (:selected-graph deleted)
                  "deleting the selected local graph clears its title")
    (assert-equal [] (:local-graph-ids deleted)
                  "deleting a local graph removes it from local storage state")))

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
                      "the unlock failure explains why the graph stayed locked")))))

(deftest encrypted-graph-unlock-has-a-stable-native-effect-payload
  (assert-equal
   "{\"id\":9,\"kind\":\"unlock-graph\",\"text\":\"secret \\\"phrase\\\"\"}"
   (bridge/encode-effect (model/UnlockGraphEffect 9 "secret \"phrase\""))
   "the native bridge escapes passwords in a typed unlock effect"))

(deftest settings-render-the-main-branch-navigation-contract
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
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

(deftest outliner-editor-extension-contract-is-pinned
  (assert-equal
   "lui-extension-v1|15:outliner-editor|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:0|children:|properties:18:caret-utf16-offset:int:required:none,5:title:string:required:none,8:block-id:string:required:none|events:11:text-change[18:caret-utf16-offset:int:required,5:title:string:required],12:caret-change[18:caret-utf16-offset:int:required],6:return[18:caret-utf16-offset:int:required,5:title:string:required],9:backspace[16:selection-length:int:required,5:title:string:required]"
   (ext/fingerprint (view/outliner-editor-schema))
   "the native editor registry must match the LG wire schema"))

(deftest outliner-block-content-extension-contract-is-pinned
  (assert-equal
   "lui-extension-v1|22:outliner-block-content|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:0|children:|properties:10:asset-type:string:required:none,10:local-path:string:required:none,11:markup-json:string:required:none,18:youtube-target-url:string:required:none,5:title:string:required:none,8:is-asset:bool:required:none|events:9:open-node[4:uuid:string:required]"
   (ext/fingerprint (view/outliner-block-content-schema))
   "the rich block renderer must match the LG wire schema"))

(deftest initial-shell-renders-offline-without-a-selected-graph
  (let [renderer (apple/create)
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/flush! application)
    (let [children (apple/children renderer (main-root renderer application))
          graph-label (nth children 1)
          sync-label (nth children 2)]
      (assert-equal None (:selected-graph (chat/model application))
                    "the shell starts without an invented graph")
      (assert-equal "No graph selected"
                    (property-string renderer graph-label proto/TextValue)
                    "the empty graph state is visible")
      (assert-equal "Offline"
                    (property-string renderer sync-label proto/TextValue)
                    "the initial sync state is explicit"))))

(deftest graph-and-sync-actions-update-retained-status-in-place
  (let [renderer (apple/create)
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/flush! application)
    (let [children (apple/children renderer (main-root renderer application))
          graph-label (nth children 1)
          sync-label (nth children 2)]
      (driver/send! application (model/SelectGraph "Work"))
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
    (let [root (driver/root-node application)
          main (main-root renderer application)
          open-button (child-with-identifier renderer main "button.sidebar")]
      (is (not (property-bool renderer root proto/Selected))
          "the native drawer starts from LG's closed state")
      (driver/dispatch-event! application (proto/Press open-button))
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
                      "sidebar page presses reuse the typed selection effect")))))

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
          (opens-as-page false)
          (depth 0)
          (has-children false)
          (is-collapsed false)
          (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))
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
        (is (not (= -1
                    (descendant-with-identifier renderer screen "field.graph-name")))
            "add graph exposes the existing graph-name field in its modal")))))

(deftest search-lifecycle-keeps-query-owned-by-the-lg-model
  (let [renderer (apple/create)
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
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
      (let [search-panel (child-with-identifier renderer root "screen.search")
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
        (assert-equal -1 (child-with-identifier renderer root "screen.search")
                      "the retained search subtree is disposed")))))

(deftest composer-matches-the-main-branch-expand-draft-and-send-contract
  (let [renderer (apple/create)
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
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
    (assert-equal
     "{\"id\":2,\"kind\":\"persist-composer-draft\",\"text\":\"\"}"
     (bridge/take-effect)
     "the bridge clears persisted text before capture")
    (assert-equal
     "{\"id\":3,\"kind\":\"send-capture\",\"text\":\"Project \\\"alpha\\\"\\nNext\"}"
     (bridge/take-effect)
     "the bridge emits escaped capture JSON for the host executor")
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
                   (model/update nested-request model/BackAppNavigation))
                  "the back action removes exactly one route")))

(deftest navigation-requests-and-back-cross-the-core-effect-boundary
  (let [requested
        (model/update (model/initial) (model/RequestSearchNode "node-a"))
        returned (model/update requested model/BackSearchNavigation)]
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
        returned (model/update opened model/BackAppNavigation)
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
        route (record model/node-projection
                      (uuid "node-a")
                (page-uuid "page-a")
                (title "Project")
                (is-tag false)
                (is-property false)
                (related-rows
                 [(record model/outline-row
                    (uuid "reference")
                    (title "Linked from journal")
                    (markup-json "[]")
                    (youtube-target-url None)
                    (breadcrumb "Journal")
                    (opens-as-page false)
                    (depth 0)
                    (has-children false)
                    (is-collapsed false)
                    (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))])
                (linked-reference-rows []))
        row (record model/outline-row
              (uuid "child") (title "Child")
              (markup-json "[]") (youtube-target-url None)
              (breadcrumb "") (opens-as-page false) (depth 1)
              (has-children false) (is-collapsed false)
              (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))]
    (driver/start! application)
    (driver/send! application (model/RequestAppNode "node-a"))
    (driver/send!
     application
     (apply-core-snapshot None (empty-sidebar-projection) [] false "" [] [route]
                              None None [] [] [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          screen (child-with-identifier renderer root "screen.node")
          back (child-with-identifier renderer screen "button.outliner.zoom-out")
          title (child-with-identifier renderer screen "title.node")
          related
          (child-with-identifier renderer screen "section.node.linked-references")]
      (assert-equal "Project"
                    (property-string renderer title proto/TextValue)
                    "the route title comes from the core projection")
      (is (not (= related -1))
          "node routes render their linked references section")
      (driver/dispatch-event! application (proto/Press back))
      (driver/flush! application)
      (assert-equal [] (:app-navigation-path (chat/model application))
                    "back removes the presented route"))))

(deftest empty-node-routes-add-the-first-block-through-the-core
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        route (record model/node-projection
                (uuid "page-a")
                (page-uuid "page-a")
                (title "Empty page")
                (is-tag false)
                (is-property false)
                (related-rows [])
                (linked-reference-rows []))]
    (driver/start! application)
    (driver/send! application (model/RequestAppNode "page-a"))
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                           false "" [] [route]
                                           None None [] [] [] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          screen (child-with-identifier renderer root "screen.node")
          add-button
          (child-with-identifier renderer screen "button.outliner.add-first-block")]
      (driver/dispatch-event! application (proto/Press add-button))
      (driver/flush! application)
      (assert-equal
       [(model/OpenAppNodeEffect 1 "page-a")
        (model/AddRootBlockEffect 2 "page-a")]
       (:pending-effects (chat/model application))
       "empty pages reuse the core addRootBlock outliner action"))))

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
  (let [renderer (apple/create)
        application (chat/create (apple/backend renderer))
        hit (record model/search-hit
                    (uuid "block-a")
                    (title "Project note")
                    (breadcrumb "Journal › Parent")
                    (is-page false))]
    (driver/start! application)
    (driver/send! application model/OpenSearch)
    (driver/send! application (model/ChangeSearchQuery "project"))
    (driver/send! application
                  (model/ApplySearchResults "project" [hit]))
    (driver/flush! application)
    (let [root (main-root renderer application)
          search-panel (child-with-identifier renderer root "screen.search")
          results (nth (apple/children renderer search-panel) 2)
          row (nth (apple/children renderer results) 0)]
      (assert-equal "search.result.block-a"
                    (property-string renderer row
                                     proto/AccessibilityIdentifier)
                    "the row keeps main's stable search result identifier")
      (driver/dispatch-event! application (proto/Press row))
      (driver/flush! application)
      (assert-equal [(model/NodeRoute "block-a")]
                    (:search-navigation-path (chat/model application))
                    "pressing a result requests navigation in LG state"))))

(deftest core-snapshot-renders-keyed-outliner-rows
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        row (record model/outline-row
                    (uuid "block-a")
                    (title "Project note")
                    (markup-json "[]")
              (youtube-target-url None)
              (breadcrumb "")
              (opens-as-page false)
                    (depth 2)
                    (has-children true)
                    (is-collapsed false)
                    (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))
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
          rendered-row (nth (apple/children renderer outliner) 0)]
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
                    (opens-as-page false)
                    (depth 0)
                    (has-children false)
                    (is-collapsed false)
                    (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                           false "" [] [] None None [] []
                                           [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          rendered-row (nth (apple/children renderer outliner) 0)
          column (nth (apple/children renderer rendered-row) 0)
          content (nth (apple/children renderer column) 0)
          rich-content (nth (apple/children renderer content) 2)]
      (assert-equal
       (Some (apple/AppleExtension "outliner-block-content"))
       (apple/node renderer rich-content)
       "non-editing markup uses the registered native rich renderer")
      (driver/dispatch-event!
       application
       (proto/ExtensionEvent
        rich-content "outliner-block-content" "open-node"
        {"uuid" (proto/StringValue "page-a")}))
      (driver/flush! application)
      (assert-equal [(model/NodeRoute "page-a")]
                    (:app-navigation-path (chat/model application))
                    "rich node references return to LG-owned navigation"))))

(deftest projected-assets-render-and-open-through-the-native-extension
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        row (record model/outline-row
                    (uuid "asset-a")
                    (title "Photo.jpg")
                    (markup-json "[]")
                    (youtube-target-url None)
                    (breadcrumb "")
                    (opens-as-page false)
                    (depth 0)
                    (has-children false)
                    (is-collapsed false)
                    (is-asset true)
                    (asset-type (Some "image/jpeg"))
                    (local-path (Some "Assets/Photo.jpg")) (status None) (tags []) (sync-status None))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                       false "" [] [] None None [] []
                                       [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          rendered-row (nth (apple/children renderer outliner) 0)
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
                      (breadcrumb "") (opens-as-page false) (depth 0)
                      (has-children false) (is-collapsed false)
                      (is-asset true) (asset-type (Some "image/jpeg"))
                      (local-path (Some "Assets/Photo.jpg")) (status None) (tags []) (sync-status None))
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

(deftest outliner-structure-controls-publish-typed-core-effects
  (let [collapsed
        (model/update (model/initial)
                      (model/ToggleOutlinerCollapsed "parent"))
        zoomed
        (model/update collapsed (model/ZoomOutlinerBlock "parent"))]
    (assert-equal
     [(model/ToggleOutlinerCollapsedEffect 1 "parent")]
     (:pending-effects collapsed)
     "collapse crosses the LG effect boundary")
    (assert-equal
     [(model/ToggleOutlinerCollapsedEffect 1 "parent")
      (model/ZoomOutlinerBlockEffect 2 "parent")]
     (:pending-effects zoomed)
     "zoom shares the ordered typed effect queue")
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
                    (breadcrumb "") (opens-as-page false) (depth 0)
                    (has-children false) (is-collapsed false)
                    (is-asset false) (asset-type None) (local-path None)
                    (status (Some todo)) (tags [tag])
                    (sync-status (Some "failed")))]
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
              (breadcrumb "") (opens-as-page false) (depth 0)
              (has-children false) (is-collapsed false)
              (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                           false "" [] [] None None []
                                           ["parent"] [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          rendered-row (nth (apple/children renderer outliner) 0)
          toolbar (child-with-identifier
                   renderer root "toolbar.outliner.selection")
          copy-button (nth (apple/children renderer toolbar) 0)]
      (is (property-bool renderer rendered-row proto/Selected)
          "the selected block is projected into retained row state")
      (assert-equal "toolbar.outliner.selection"
                    (property-string renderer toolbar
                                     proto/AccessibilityIdentifier)
                    "selection exposes main's stable toolbar identifier")
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
              (breadcrumb "") (opens-as-page false) (depth 0)
              (has-children false) (is-collapsed false)
              (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))
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
              (opens-as-page false)
                    (depth 2)
                    (has-children true)
                    (is-collapsed false)
                    (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))]
    (driver/start! application)
    (driver/send! application
                  (apply-core-snapshot None (empty-sidebar-projection) []
                                           false "" [] [] None None [] []
                                           [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (descendant-with-identifier renderer root "list.outliner")
          rendered-row (nth (apple/children renderer outliner) 0)
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
       [(model/ZoomOutlinerBlockEffect 1 "parent")
        (model/ToggleOutlinerCollapsedEffect 2 "parent")]
       (:pending-effects (chat/model application))
       "both controls route through LG without triggering row editing"))))

(deftest outliner-row-splices-update-the-existing-keyed-projection
  (let [parent (record model/outline-row
                 (uuid "parent") (title "Parent")
                 (markup-json "[]") (youtube-target-url None)
                 (breadcrumb "") (opens-as-page false) (depth 0)
                 (has-children true) (is-collapsed false)
                 (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))
        child (record model/outline-row
                (uuid "child") (title "Child")
                (markup-json "[]") (youtube-target-url None)
                (breadcrumb "") (opens-as-page false) (depth 1)
                (has-children false) (is-collapsed false)
                (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))
        sibling (record model/outline-row
                  (uuid "sibling") (title "Sibling")
                  (markup-json "[]") (youtube-target-url None)
                  (breadcrumb "") (opens-as-page false) (depth 0)
                  (has-children false) (is-collapsed false)
                  (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))
        collapsed-parent (record model/outline-row
                           (uuid "parent") (title "Parent")
                           (markup-json "[]") (youtube-target-url None)
                           (breadcrumb "") (opens-as-page false) (depth 0)
                           (has-children true) (is-collapsed true)
                           (is-asset false) (asset-type None) (local-path None) (status None) (tags []) (sync-status None))
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
