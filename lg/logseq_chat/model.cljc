(ns logseq-chat.model
  (:require [clojure.string :as string]))

(defn initial []
  (record chat-model
    (selected-graph None)
    (sync-state OfflineState)
    (search-open false)
    (search-query "")
    (composer-expanded false)
    (composer-draft "")
    (composer-submission None)
    (composer-submission-revision 0)
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
    (assoc current :search-query query)

    CloseSearch
    (assoc current
           :search-open false
           :search-query ""
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
        (assoc current
               :composer-expanded true
               :composer-draft ""
               :composer-submission (Some submission)
               :composer-submission-revision
               (inc (:composer-submission-revision current)))))

    ClearComposerSubmission
    (assoc current :composer-submission None)

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
