(ns logseq-chat.app-test
  (:require [clojure.test :refer [deftest is testing]]
            [lui.app :as driver]
            [lui.backend.apple :as apple]
            [lui.protocol :as proto :refer [StringValue]]
            [logseq-chat.app :as chat]
            [logseq-chat.native-bridge :as bridge]
            [logseq-chat.model :as model]))

(defmacro assert-equal [expected actual message]
  `(is (= ~expected ~actual) ~message))

(defn property-string [renderer node property]
  (match (apple/property renderer node property)
    (Some (StringValue value)) value
    _ "<missing>"))

(deftest initial-shell-renders-offline-without-a-selected-graph
  (let [renderer (apple/create)
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/flush! application)
    (let [children (apple/children renderer (driver/root-node application))
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
    (let [children (apple/children renderer (driver/root-node application))
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
                    (nth (apple/children renderer (driver/root-node application)) 2)
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

(deftest search-lifecycle-keeps-query-owned-by-the-lg-model
  (let [renderer (apple/create)
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/flush! application)
    (let [root (driver/root-node application)
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
        (assert-equal 5 (count (apple/children renderer root))
                      "the retained search subtree is disposed")))))

(deftest composer-matches-the-main-branch-expand-draft-and-send-contract
  (let [renderer (apple/create)
        application (chat/create (apple/backend renderer))]
    (driver/start! application)
    (driver/flush! application)
    (let [root (driver/root-node application)
          composer (nth (apple/children renderer root) 4)
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
    (assert-equal [1] (:in-flight-effect-ids (chat/model application))
                  "dequeued effects remain tracked until resolution")
    (bridge/resolve-effect 1 false "Network unavailable")
    (assert-equal [] (:in-flight-effect-ids (chat/model application))
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
    (assert-equal [] (:in-flight-effect-ids resolved)
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
    (let [root (driver/root-node application)
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

(deftest native-bridge-returns-initial-and-disposal-patch-batches
  (let [initial-patch (bridge/initialize 2 1)]
    (is (not (= "" initial-patch)))
    (is (> (bridge/root-node) 0))
    (is (not (= "" (bridge/dispose))))))
