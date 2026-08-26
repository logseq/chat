(ns logseq-chat.model
  (:require [clojure.string :as string]))

(defn initial []
  (record chat-model
    (selected-graph None)
    (sync-state OfflineState)
    (search-open false)
    (search-query "")
    (search-results [])
    (search-loading false)
    (composer-expanded false)
    (composer-draft "")
    (pending-effects [])
    (in-flight-effect-ids [])
    (next-effect-id 1)
    (effect-error None)
    (last-core-response None)
    (attachment-picker-open false)
    (task-status-picker-open false)
    (app-navigation-path [])
    (search-navigation-path [])))

(defn request-route [path route]
  (if (and (not (empty? path)) (= (last path) route))
    path
    (conj path route)))

(defn resolve-route [path route resolved]
  (if resolved
    path
    (loop [index (dec (count path))]
      (if (< index 0)
        path
        (if (= (nth path index) route)
          (into (subvec path 0 index) (subvec path (inc index)))
          (recur (dec index)))))))

(defn pop-route [path]
  (if (empty? path)
    path
    (subvec path 0 (dec (count path)))))

(defn effect-id [effect]
  (match effect
    (SendCaptureEffect id _text) id
    (SearchNodesEffect id _query) id))

(defn remove-search-effects [effects]
  (filterv
   (fn [effect]
     (match effect
       (SearchNodesEffect _id _query) false
       _ true))
   effects))

(defn remove-int [values target]
  (loop [index 0
         result []]
    (if (= index (count values))
      result
      (let [value (nth values index)]
        (recur (inc index)
               (if (= value target) result (conj result value)))))))

(defn contains-int? [values target]
  (loop [index 0]
    (if (= index (count values))
      false
      (if (= (nth values index) target)
        true
        (recur (inc index))))))

(defn remove-effect [effects target]
  (loop [index 0
         result []]
    (if (= index (count effects))
      result
      (let [effect (nth effects index)]
        (recur (inc index)
               (if (= (effect-id effect) target)
                 result
                 (conj result effect)))))))

(defn update [current action]
  (match action
    (SelectGraph graph-name)
    (assoc current :selected-graph (Some graph-name))

    BeginSync
    (assoc current :sync-state SyncingState)

    SyncSucceeded
    (assoc current :sync-state SyncedState)

    (SyncFailed reason)
    (assoc current :sync-state (FailedState reason))

    OpenSearch
    (assoc current :search-open true)

    (ChangeSearchQuery query)
    (let [pending (remove-search-effects (:pending-effects current))]
      (if (string/blank? query)
        (assoc current
               :search-query query
               :search-results []
               :search-loading false
               :pending-effects pending)
        (let [id (:next-effect-id current)]
          (assoc current
                 :search-query query
                 :search-loading true
                 :pending-effects (conj pending (SearchNodesEffect id query))
                 :next-effect-id (inc id)
                 :effect-error None))))

    (ApplySearchResults query results)
    (if (= query (:search-query current))
      (assoc current
             :search-results results
             :search-loading false)
      current)

    (ApplyCoreSnapshot graph-name sync-connected query results)
    (let [updated
          (assoc current
                 :selected-graph graph-name
                 :sync-state (if sync-connected SyncedState OfflineState))]
      (if (= query (:search-query current))
        (assoc updated
               :search-results results
               :search-loading false)
        updated))

    CloseSearch
    (assoc current
           :search-open false
           :search-query ""
           :search-results []
           :search-loading false
           :pending-effects (remove-search-effects (:pending-effects current))
           :search-navigation-path [])

    ExpandComposer
    (assoc current :composer-expanded true)

    (ChangeComposerDraft draft)
    (assoc current :composer-draft draft)

    DismissComposer
    (assoc current :composer-expanded false)

    SendComposer
    (let [submission (string/trim (:composer-draft current))]
      (if (empty? submission)
        current
        (let [id (:next-effect-id current)]
          (assoc current
                 :composer-expanded true
                 :composer-draft ""
                 :pending-effects
                 (conj (:pending-effects current)
                       (SendCaptureEffect id submission))
                 :next-effect-id (inc id)
                 :effect-error None))))

    (DequeueEffect id)
    (let [pending (:pending-effects current)]
      (if (= pending (remove-effect pending id))
        current
        (assoc current
               :pending-effects (remove-effect pending id)
               :in-flight-effect-ids
               (conj (:in-flight-effect-ids current) id))))

    (ResolveEffect id succeeded message)
    (if (contains-int? (:in-flight-effect-ids current) id)
      (assoc current
             :in-flight-effect-ids
             (remove-int (:in-flight-effect-ids current) id)
             :effect-error (if succeeded None (Some message))
             :last-core-response
             (if succeeded (Some message) (:last-core-response current)))
      current)

    OpenAttachmentPicker
    (assoc current :attachment-picker-open true)

    CloseAttachmentPicker
    (assoc current :attachment-picker-open false)

    OpenTaskStatusPicker
    (assoc current :task-status-picker-open true)

    CloseTaskStatusPicker
    (assoc current :task-status-picker-open false)

    (RequestAppNode uuid)
    (assoc current
           :app-navigation-path
           (request-route (:app-navigation-path current) (NodeRoute uuid)))

    (ResolveAppNode uuid resolved)
    (assoc current
           :app-navigation-path
           (resolve-route (:app-navigation-path current)
                          (NodeRoute uuid)
                          resolved))

    BackAppNavigation
    (assoc current
           :app-navigation-path
           (pop-route (:app-navigation-path current)))

    (RequestSearchNode uuid)
    (assoc current
           :search-navigation-path
           (request-route (:search-navigation-path current) (NodeRoute uuid)))

    (ResolveSearchNode uuid resolved)
    (assoc current
           :search-navigation-path
           (resolve-route (:search-navigation-path current)
                          (NodeRoute uuid)
                          resolved))

    BackSearchNavigation
    (assoc current
           :search-navigation-path
           (pop-route (:search-navigation-path current)))))
