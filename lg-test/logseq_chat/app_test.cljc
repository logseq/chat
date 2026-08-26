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

(defn main-root [renderer application]
  (nth (apple/children renderer (driver/root-node application)) 0))

(defn empty-sidebar-projection []
  (record model/sidebar-projection
    (favorites [])
    (recent-pages [])
    (selected-page None)
    (selected-page-is-tag false)
    (selected-page-is-property false)
    (related-rows [])
    (linked-reference-rows [])))

(deftest outliner-editor-extension-contract-is-pinned
  (assert-equal
   "lui-extension-v1|15:outliner-editor|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:0|children:|properties:18:caret-utf16-offset:int:required:none,5:title:string:required:none,8:block-id:string:required:none|events:11:text-change[18:caret-utf16-offset:int:required,5:title:string:required],12:caret-change[18:caret-utf16-offset:int:required],6:return[18:caret-utf16-offset:int:required,5:title:string:required],9:backspace[16:selection-length:int:required,5:title:string:required]"
   (ext/fingerprint (view/outliner-editor-schema))
   "the native editor registry must match the LG wire schema"))

(deftest outliner-block-content-extension-contract-is-pinned
  (assert-equal
   "lui-extension-v1|22:outliner-block-content|profiles:android/swiftui,ios/swiftui,macos/swiftui|standard-children:0|children:|properties:11:markup-json:string:required:none,18:youtube-target-url:string:required:none,5:title:string:required:none|events:9:open-node[4:uuid:string:required]"
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

(deftest sidebar-state-and-page-selection-are-owned-by-lg
  (let [favorite (record model/sidebar-page (uuid "page-a") (title "Favorite"))
        recent (record model/sidebar-page (uuid "page-b") (title "Recent"))
        opened (model/update (model/initial) model/OpenSidebar)
        projected
        (model/update
         opened
         (model/ApplyCoreSnapshot
          None
          (record model/sidebar-projection
            (favorites [favorite])
            (recent-pages [recent])
            (selected-page None)
            (selected-page-is-tag false)
            (selected-page-is-property false)
            (related-rows [])
            (linked-reference-rows []))
          false "" [] [] None None [] [] [] false []))
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
                  (model/ApplyCoreSnapshot None sidebar false "" [] []
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
          (is-collapsed false))
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
                  (model/ApplyCoreSnapshot None sidebar false "" [] []
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
      (let [search-panel (nth (apple/children renderer root) 4)
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
        (assert-equal 7 (count (apple/children renderer root))
                      "the retained search subtree is disposed")))))

(deftest composer-matches-the-main-branch-expand-draft-and-send-contract
  (let [renderer (apple/create)
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/flush! application)
    (let [root (main-root renderer application)
          composer (nth (apple/children renderer root) 5)
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
        (assert-equal [(model/SendCaptureEffect 1 "Project note")]
                      (:pending-effects (chat/model application))
                      "send publishes one typed capture effect")
        (assert-equal 2
                      (:next-effect-id (chat/model application))
                      "send advances the stable effect identifier exactly once")
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
    (assert-equal [(model/SendCaptureEffect 1 "Later")]
                  (:pending-effects empty-send)
                  "a preserved non-empty draft can still be submitted")))

(deftest native-bridge-drains-and-resolves-typed-effects-once
  (bridge/initialize 2 1)
  (let [application (bridge/app)]
    (driver/send! application model/ExpandComposer)
    (driver/send! application (model/ChangeComposerDraft "Project \"alpha\"\nNext"))
    (driver/send! application model/SendComposer)
    (driver/flush! application)
    (assert-equal
     "{\"id\":1,\"kind\":\"send-capture\",\"text\":\"Project \\\"alpha\\\"\\nNext\"}"
     (bridge/take-effect)
     "the bridge emits escaped JSON for the host executor")
    (assert-equal "" (bridge/take-effect)
                  "an effect is never dispatched to the host twice")
    (assert-equal [(model/SendCaptureEffect 1 "Project \"alpha\"\nNext")]
                  (:in-flight-effects (chat/model application))
                  "dequeued effects remain tracked until resolution")
    (bridge/resolve-effect 1 false "Network unavailable")
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
        dequeued (model/update queued (model/DequeueEffect 1))
        resolved (model/update dequeued
                               (model/ResolveEffect 1 true "{\"ok\":true}"))]
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
                    (is-collapsed false))])
                (linked-reference-rows []))
        row (record model/outline-row
                    (uuid "child") (title "Child") (depth 1)
              (markup-json "[]") (youtube-target-url None)
              (breadcrumb "") (opens-as-page false)
                    (has-children false) (is-collapsed false))]
    (driver/start! application)
    (driver/send! application (model/RequestAppNode "node-a"))
    (driver/send!
     application
     (model/ApplyCoreSnapshot None (empty-sidebar-projection) false "" [] [route]
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
                  (model/ApplyCoreSnapshot None (empty-sidebar-projection)
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
          search-panel (nth (apple/children renderer root) 4)
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
                    (is-collapsed false))
        editing (record model/outliner-editing
                        (uuid "block-a")
                        (title "Project note")
                        (caret-utf16-offset 4))]
    (driver/start! application)
    (driver/send! application
                  (model/ApplyCoreSnapshot None (empty-sidebar-projection)
                                           false "" [] []
                                           (Some editing) None [] []
                                           [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (nth (apple/children renderer root) 4)
          rendered-row (nth (apple/children renderer outliner) 0)]
      (assert-equal "outliner.block.block-a"
                    (property-string renderer rendered-row
                                     proto/AccessibilityIdentifier)
                    "the LG row keeps main's stable block identifier")
      (let [content (nth (apple/children renderer rendered-row) 0)
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
                    (is-collapsed false))]
    (driver/start! application)
    (driver/send! application
                  (model/ApplyCoreSnapshot None (empty-sidebar-projection)
                                           false "" [] [] None None [] []
                                           [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (nth (apple/children renderer root) 4)
          rendered-row (nth (apple/children renderer outliner) 0)
          content (nth (apple/children renderer rendered-row) 0)
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

(deftest outliner-row-press-publishes-a-typed-core-effect
  (let [current (model/initial)
        editing (model/update current (model/BeginOutlinerEdit "block-a"))]
    (assert-equal [(model/TapOutlinerBlockEffect 1 "block-a")]
                  (:pending-effects editing)
                  "tapBlock crosses the LG effect boundary")
    (assert-equal 2 (:next-effect-id editing)
                  "outliner effects share the monotonic effect sequence")))

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

(deftest outliner-long-press-selection-and-toolbar-use-typed-effects
  (let [renderer (apple/create-with-extensions (view/extension-registry))
        application (chat/create (apple/backend renderer))
        row (record model/outline-row
                    (uuid "parent") (title "Parent") (depth 0)
              (markup-json "[]") (youtube-target-url None)
              (breadcrumb "") (opens-as-page false)
                    (has-children false) (is-collapsed false))]
    (driver/start! application)
    (driver/send! application
                  (model/ApplyCoreSnapshot None (empty-sidebar-projection)
                                           false "" [] [] None None []
                                           ["parent"] [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (nth (apple/children renderer root) 4)
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
                    (uuid "block-a") (title "Project [[Pro") (depth 0)
              (markup-json "[]") (youtube-target-url None)
              (breadcrumb "") (opens-as-page false)
                    (has-children false) (is-collapsed false))
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
     (model/ApplyCoreSnapshot None (empty-sidebar-projection) false "" [] []
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
                    (is-collapsed false))]
    (driver/start! application)
    (driver/send! application
                  (model/ApplyCoreSnapshot None (empty-sidebar-projection)
                                           false "" [] [] None None [] []
                                           [row] false []))
    (driver/flush! application)
    (let [root (main-root renderer application)
          outliner (nth (apple/children renderer root) 4)
          rendered-row (nth (apple/children renderer outliner) 0)
          content (nth (apple/children renderer rendered-row) 0)
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
                       (uuid "parent") (title "Parent") (depth 0)
                 (markup-json "[]") (youtube-target-url None)
                 (breadcrumb "") (opens-as-page false)
                       (has-children true) (is-collapsed false))
        child (record model/outline-row
                      (uuid "child") (title "Child") (depth 1)
                (markup-json "[]") (youtube-target-url None)
                (breadcrumb "") (opens-as-page false)
                      (has-children false) (is-collapsed false))
        sibling (record model/outline-row
                        (uuid "sibling") (title "Sibling") (depth 0)
                  (markup-json "[]") (youtube-target-url None)
                  (breadcrumb "") (opens-as-page false)
                        (has-children false) (is-collapsed false))
        collapsed-parent (record model/outline-row
                                 (uuid "parent") (title "Parent") (depth 0)
                           (markup-json "[]") (youtube-target-url None)
                           (breadcrumb "") (opens-as-page false)
                                 (has-children true) (is-collapsed true))
        initial
        (model/update
         (model/initial)
         (model/ApplyCoreSnapshot None (empty-sidebar-projection)
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
         (model/ApplyCoreSnapshot None (empty-sidebar-projection)
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
