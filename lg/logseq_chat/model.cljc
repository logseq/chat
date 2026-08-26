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
    (outliner-rows [])
    (outliner-editing None)
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
    (SearchNodesEffect id _query) id
    (TapOutlinerBlockEffect id _uuid) id
    (ChangeOutlinerTextEffect id _uuid _title _caret) id
    (ReturnOutlinerEditorEffect id _uuid _title _caret) id
    (BackspaceOutlinerEditorEffect id _uuid _title _selection) id
    (MoveOutlinerCaretEffect id _uuid _caret) id
    (ToggleOutlinerCollapsedEffect id _uuid) id
    (ZoomOutlinerBlockEffect id _uuid) id))

(defn enqueue-effect [current effect]
  (assoc current
         :pending-effects (conj (:pending-effects current) effect)
         :next-effect-id (inc (:next-effect-id current))
         :effect-error None))

(defn update-editing [current uuid title caret]
  (match (:outliner-editing current)
    (Some editing)
    (if (= (:uuid editing) uuid)
      (assoc current :outliner-editing
             (Some (record outliner-editing
                     (uuid uuid)
                     (title title)
                     (caret-utf16-offset caret))))
      current)
    None current))

(defn row-index [rows uuid]
  (loop [index 0]
    (if (= index (count rows))
      None
      (if (= (:uuid (nth rows index)) uuid)
        (Some index)
        (recur (inc index))))))

(defn contains-row? [rows uuid]
  (match (row-index rows uuid)
    (Some _index) true
    None false))

(defn splice-start [rows splice]
  (match (:after-block-id splice)
    (Some uuid)
    (match (row-index rows uuid)
      (Some index) (Some (inc index))
      None
      (match (:before-block-id splice)
        (Some before-uuid) (row-index rows before-uuid)
        None (:start splice)))
    None
    (match (:before-block-id splice)
      (Some uuid) (row-index rows uuid)
      None (:start splice))))

(defn apply-row-splice [rows splice]
  (match (splice-start rows splice)
    None rows
    (Some requested-start)
    (let [start (min (max requested-start 0) (count rows))
          delete-end
          (min (+ start (max (:delete-count splice) 0)) (count rows))
          inserted (:rows splice)
          prefix
          (loop [index 0
                 result (subvec rows 0 0)]
            (if (= index start)
              result
              (let [row (nth rows index)]
                (recur
                 (inc index)
                 (if (contains-row? inserted (:uuid row))
                   result
                   (conj result row))))))]
      (loop [index delete-end
             result (into prefix inserted)]
        (if (= index (count rows))
          result
          (let [row (nth rows index)]
            (recur
             (inc index)
             (if (contains-row? inserted (:uuid row))
               result
               (conj result row)))))))))

(defn apply-row-splices [rows splices]
  (loop [index 0
         result rows]
    (if (= index (count splices))
      result
      (recur (inc index) (apply-row-splice result (nth splices index))))))

(defn merge-row-replacements [rows replacements]
  (mapv
   (fn [row]
     (match (row-index replacements (:uuid row))
       (Some index) (nth replacements index)
       None row))
   rows))

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

    (ApplyCoreSnapshot graph-name sync-connected query results
                       outliner-editing outliner-rows is-outliner-patch
                       outliner-row-splices)
    (let [projected-rows
          (if is-outliner-patch
            (if (empty? outliner-row-splices)
              (merge-row-replacements (:outliner-rows current) outliner-rows)
              (apply-row-splices (:outliner-rows current)
                                 outliner-row-splices))
            outliner-rows)
          updated
          (assoc current
                 :selected-graph graph-name
                 :sync-state (if sync-connected SyncedState OfflineState)
                 :outliner-editing outliner-editing
                 :outliner-rows projected-rows)]
      (if (= query (:search-query current))
        (assoc updated
               :search-results results
               :search-loading false)
        updated))

    (BeginOutlinerEdit uuid)
    (let [id (:next-effect-id current)]
      (enqueue-effect current (TapOutlinerBlockEffect id uuid)))

    (ChangeOutlinerText uuid title caret)
    (let [updated (update-editing current uuid title caret)
          id (:next-effect-id updated)]
      (enqueue-effect updated
                      (ChangeOutlinerTextEffect id uuid title caret)))

    (ReturnOutlinerEditor uuid title caret)
    (let [updated (update-editing current uuid title caret)
          id (:next-effect-id updated)]
      (enqueue-effect updated
                      (ReturnOutlinerEditorEffect id uuid title caret)))

    (BackspaceOutlinerEditor uuid title selection-length)
    (let [id (:next-effect-id current)]
      (enqueue-effect
       current
       (BackspaceOutlinerEditorEffect id uuid title selection-length)))

    (MoveOutlinerCaret uuid caret)
    (let [title
          (match (:outliner-editing current)
            (Some editing) (:title editing)
            None "")
          updated (update-editing current uuid title caret)
          id (:next-effect-id updated)]
      (enqueue-effect updated (MoveOutlinerCaretEffect id uuid caret)))

    (ToggleOutlinerCollapsed uuid)
    (let [id (:next-effect-id current)]
      (enqueue-effect current (ToggleOutlinerCollapsedEffect id uuid)))

    (ZoomOutlinerBlock uuid)
    (let [id (:next-effect-id current)]
      (enqueue-effect current (ZoomOutlinerBlockEffect id uuid)))

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
