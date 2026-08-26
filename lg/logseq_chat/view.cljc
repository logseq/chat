(ns logseq-chat.view
  (:require [lui.macros :refer [defui reactive]]
            [lui.protocol :refer [TextChanged]]
            [logseq-chat.model :as model]))

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

(defui chat-view [model-source send]
  [:column
   [:heading {:level 1} "Logseq"]
   [:text {:value (reactive graph-label model-source)}]
   [:text {:value (reactive sync-label model-source)}]
   [:button {:on-press (fn [_event] (send model/OpenSearch))} "Search"]
   [:if {:test (reactive :search-open model-source)}
    [:row
     [:search-field
      {:text (reactive :search-query model-source)
       :placeholder "Search pages and blocks"
       :label "Search pages and blocks"
       :on-input
       (fn [input-event]
         (match input-event
           (TextChanged _node text) (send (model/ChangeSearchQuery text))
           _ true))}]
     [:button {:on-press (fn [_event] (send model/CloseSearch))} "Close"]]]])
