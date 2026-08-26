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
      (driver/dispatch-event! application (proto/Press search-button))
      (driver/flush! application)
      (is (:search-open (chat/model application))
          "search presentation is model-owned")
      (let [search-panel (nth (apple/children renderer root) 4)
            search-field (nth (apple/children renderer search-panel) 0)
            close-button (nth (apple/children renderer search-panel) 1)]
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
        (assert-equal 4 (count (apple/children renderer root))
                      "the retained search subtree is disposed")))))

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

(deftest native-bridge-returns-initial-and-disposal-patch-batches
  (let [initial-patch (bridge/initialize 2 1)]
    (is (not (= "" initial-patch)))
    (is (> (bridge/root-node) 0))
    (is (not (= "" (bridge/dispose))))))
