(ns logseq-chat.view
  (:require [clojure.string :as string]
            [lui.elements :as elements]
            [lui.macros :refer [defui reactive event]]
            [lui.protocol :refer [TextChanged]]
            [logseq-chat.model :as model]
            [signal.core :as signal]))

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
  (str "search.result." (:uuid hit)))

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
       [:text {:value (reactive :title hit-source)}]
       [:text {:value (reactive :breadcrumb hit-source)}]]])))

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
   [:heading {:level 1} "Logseq"]
   [:text {:value (reactive graph-label model-source)}]
   [:text {:value (reactive sync-label model-source)}]
   [:button
    {:accessibility-identifier "button.search"
     :on-press (fn [_event] (send model/OpenSearch))}
    "Search"]
   [:if {:test (reactive :search-open model-source)}
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
   (composer-view model-source send)])
