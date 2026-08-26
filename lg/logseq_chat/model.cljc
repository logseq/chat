(ns logseq-chat.model
  (:require [clojure.string :as string]))

(defn task-status [uuid ident title icon-id]
  (record task-status
    (uuid uuid)
    (ident (Some ident))
    (title title)
    (icon-type (Some "tabler-icon"))
    (icon-id (Some icon-id))
    (icon-color None)))

(defn built-in-task-statuses []
  [(task-status "backlog" "logseq.property/status.backlog" "Backlog" "Backlog")
   (task-status "todo" "logseq.property/status.todo" "Todo" "Todo")
   (task-status "doing" "logseq.property/status.doing" "Doing" "InProgress50")
   (task-status "in-review" "logseq.property/status.in-review" "In Review" "InReview")
   (task-status "done" "logseq.property/status.done" "Done" "Done")
   (task-status "canceled" "logseq.property/status.canceled" "Canceled" "Cancelled")])

(defn initial []
  (record chat-model
          (selected-graph None)
          (selected-graph-id None)
          (graphs [])
          (local-graph-ids [])
          (is-graph-encrypted false)
          (is-graph-unlocked false)
          (graph-password-open false)
          (graph-password "")
          (sync-state OfflineState)
          (destination JournalsDestination)
          (sidebar-open false)
          (favorites [])
          (recent-pages [])
          (selected-page None)
          (selected-page-is-tag false)
          (selected-page-is-property false)
          (related-rows [])
          (linked-reference-rows [])
          (task-statuses (built-in-task-statuses))
          (selected-task-status None)
          (flashcards [])
          (flashcard-cloze-revealed false)
          (flashcard-answer-revealed false)
          (create-graph-open false)
          (new-graph-name "")
          (new-graph-encrypted false)
          (pending-graph-deletion None)
          (connection-menu-open false)
          (settings-open false)
          (settings-tabs-open false)
          (runtime-log-open false)
          (appearance "system")
          (language "system")
          (spell-check true)
          (auto-correction true)
          (sidebar-tabs ["journals" "flashcards" "graphs"])
          (base-url "")
          (version "Development")
          (revision "Development")
          (runtime-log-source "ui")
          (runtime-log-errors-only false)
          (runtime-log-newest-first false)
          (runtime-log-records [])
          (search-open false)
          (search-query "")
          (search-results [])
          (search-loading false)
          (node-routes [])
          (outliner-rows [])
          (outliner-selected-block-ids [])
          (outliner-editing None)
          (outliner-autocomplete None)
          (outliner-autocomplete-candidates [])
          (composer-expanded false)
          (composer-draft "")
          (composer-autofocus false)
          (pending-effects [])
          (in-flight-effects [])
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

(defn navigation-route-uuid [route]
  (match route
    (NodeRoute uuid) uuid))

(defn effect-id [effect]
  (match effect
    (SendCaptureEffect id _text) id
    (SendTaskEffect id _text _status) id
    (PersistComposerDraftEffect id _draft) id
    (PresentAttachmentEffect id _kind) id
    (PresentAssetEffect id _title _asset-type _local-path) id
    (SearchNodesEffect id _query) id
    (TapOutlinerBlockEffect id _uuid) id
    (ChangeOutlinerTextEffect id _uuid _title _caret) id
    (ReturnOutlinerEditorEffect id _uuid _title _caret) id
    (BackspaceOutlinerEditorEffect id _uuid _title _selection) id
    (MoveOutlinerCaretEffect id _uuid _caret) id
    (ToggleOutlinerCollapsedEffect id _uuid) id
    (ZoomOutlinerBlockEffect id _uuid) id
    (LongPressOutlinerBlockEffect id _uuid) id
    (OutlinerToolbarEffect id _action) id
    (ChooseOutlinerAutocompleteEffect id _value) id
    (OpenAppNodeEffect id _uuid) id
    (OpenSearchNodeEffect id _uuid) id
    (CloseAppNodeEffect id _uuid) id
    (CloseSearchNodeEffect id _uuid) id
    (AddRootBlockEffect id _uuid) id
    (SelectSidebarPageEffect id _uuid) id
    (ClearSelectedPageEffect id) id
    (LoadFlashcardsEffect id) id
    (ReviewFlashcardEffect id _uuid _rating) id
    (RefreshGraphsEffect id) id
    (OpenGraphEffect id _graph-id) id
    (UnlockGraphEffect id _password) id
    (CreateGraphEffect id _name _is-encrypted) id
    (DeleteLocalGraphEffect id _graph-id) id
    (SaveSettingsEffect id _settings) id
    (RefreshRuntimeLogEffect id _source _errors-only _newest-first) id
    (CopyRuntimeLogEffect id _records) id
    (SignOutEffect id) id))

(defn effect-with-id [effects target]
  (loop [index 0]
    (if (= index (count effects))
      None
      (let [effect (nth effects index)]
        (if (= (effect-id effect) target)
          (Some effect)
          (recur (inc index)))))))

(defn first-flashcard-id [flashcards]
  (if (empty? flashcards)
    None
    (Some (:uuid (nth flashcards 0)))))

(defn graph-by-id [graphs target]
  (loop [index 0]
    (if (= index (count graphs))
      None
      (let [graph (nth graphs index)]
        (if (= (:id graph) target)
          (Some graph)
          (recur (inc index)))))))

(defn task-status-by-id [statuses target]
  (loop [index 0]
    (if (= index (count statuses))
      None
      (let [status (nth statuses index)]
        (if (= (:uuid status) target)
          (Some status)
          (recur (inc index)))))))

(defn task-status-identity [status]
  (match (:ident status)
    (Some ident) ident
    None (:uuid status)))

(defn contains-task-status-identity? [statuses target]
  (loop [index 0]
    (if (= index (count statuses))
      false
      (if (= (task-status-identity (nth statuses index)) target)
        true
        (recur (inc index))))))

(defn available-task-statuses [catalog]
  (loop [index 0
         choices catalog
         fallbacks (built-in-task-statuses)]
    (if (= index (count fallbacks))
      choices
      (let [status (nth fallbacks index)]
        (recur
         (inc index)
         (if (contains-task-status-identity?
              choices (task-status-identity status))
           choices
           (conj choices status))
         fallbacks)))))

(defn string-vector-contains? [values target]
  (loop [index 0]
    (if (= index (count values))
      false
      (if (= (nth values index) target)
        true
        (recur (inc index))))))

(defn graph-local? [current graph-id]
  (string-vector-contains? (:local-graph-ids current) graph-id))

(defn remove-string [values target]
  (filterv (fn [value] (not (= value target))) values))

(defn required-sidebar-tab? [tab]
  (or (= tab "journals") (= tab "graphs")))

(defn toggle-sidebar-tab [tabs tab]
  (if (required-sidebar-tab? tab)
    tabs
    (if (string-vector-contains? tabs tab)
      (remove-string tabs tab)
      (conj tabs tab))))

(defn move-sidebar-tab [tabs tab offset]
  (if (= tab "journals")
    tabs
    (let [without (remove-string tabs tab)]
    (loop [index 0]
      (if (= index (count tabs))
        tabs
        (if (= (nth tabs index) tab)
          (let [target (min (max (+ index offset) 0) (count without))]
            (into (conj (subvec without 0 target) tab)
                  (subvec without target)))
          (recur (inc index))))))))

(defn valid-base-url? [value]
  (let [normalized (string/trim value)]
    (or (and (string/starts-with? normalized "http://")
             (> (count normalized) 7))
        (and (string/starts-with? normalized "https://")
             (> (count normalized) 8)))))

(defn valid-attachment-kind? [kind]
  (or (= kind "files")
      (= kind "camera")
      (= kind "photos")
      (= kind "audio")))

(defn current-settings [current]
  (record settings-projection
    (appearance (:appearance current))
    (language (:language current))
    (spell-check (:spell-check current))
    (auto-correction (:auto-correction current))
    (sidebar-tabs (:sidebar-tabs current))
    (base-url (string/trim (:base-url current)))
    (version (:version current))
    (revision (:revision current))))

(defn rollback-navigation-effect [current effect]
  (match effect
    (OpenAppNodeEffect _id uuid)
    (assoc current :app-navigation-path
           (resolve-route (:app-navigation-path current)
                          (NodeRoute uuid) false))
    (OpenSearchNodeEffect _id uuid)
    (assoc current :search-navigation-path
           (resolve-route (:search-navigation-path current)
                          (NodeRoute uuid) false))
    (CloseAppNodeEffect _id uuid)
    (assoc current :app-navigation-path
           (request-route (:app-navigation-path current) (NodeRoute uuid)))
    (CloseSearchNodeEffect _id uuid)
    (assoc current :search-navigation-path
           (request-route (:search-navigation-path current) (NodeRoute uuid)))
    (SelectSidebarPageEffect _id _uuid)
    (assoc current :sidebar-open true)
    _ current))

(defn resolve-successful-effect [current effect message]
  (match effect
    (OpenGraphEffect _id graph-id)
    (match (graph-by-id (:graphs current) graph-id)
      (Some selected)
      (assoc current
             :destination JournalsDestination
             :selected-graph-id (Some graph-id)
             :selected-graph (Some (:name selected)))
      None (assoc current :destination JournalsDestination))
    (UnlockGraphEffect _id _password)
    (assoc current :graph-password-open false :graph-password "")
    (CreateGraphEffect _id _name _is-encrypted)
    (assoc current
           :destination JournalsDestination
           :create-graph-open false
           :new-graph-name ""
           :new-graph-encrypted false)
    (DeleteLocalGraphEffect _id graph-id)
    (let [deleting-selected
          (match (:selected-graph-id current)
            (Some selected-id) (= selected-id graph-id)
            None false)]
      (assoc current
             :pending-graph-deletion None
             :local-graph-ids (remove-string (:local-graph-ids current) graph-id)
             :selected-graph-id
             (if deleting-selected None (:selected-graph-id current))
             :selected-graph
             (if deleting-selected None (:selected-graph current))))
    (SignOutEffect _id)
    (assoc current
           :settings-open false
           :settings-tabs-open false
           :runtime-log-open false)
    _ current))

(defn enqueue-effect [current effect]
  (assoc current
         :pending-effects (conj (:pending-effects current) effect)
         :next-effect-id (inc (:next-effect-id current))
         :effect-error None))

(defn enqueue-close-search-effects [current path]
  (loop [index (dec (count path))
         updated current]
    (if (< index 0)
      updated
      (let [uuid (navigation-route-uuid (nth path index))
            id (:next-effect-id updated)]
        (recur (dec index)
               (enqueue-effect updated (CloseSearchNodeEffect id uuid)))))))

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

(defn remove-composer-draft-effects [effects]
  (filterv
   (fn [effect]
     (match effect
       (PersistComposerDraftEffect _id _draft) false
       _ true))
   effects))

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

    (ApplyCoreSnapshot projection)
    (let [projected-rows
          (if (:is-outliner-patch projection)
            (if (empty? (:outliner-row-splices projection))
              (merge-row-replacements
               (:outliner-rows current) (:outliner-rows projection))
              (apply-row-splices (:outliner-rows current)
                                 (:outliner-row-splices projection)))
            (:outliner-rows projection))
          card-changed
          (not (= (first-flashcard-id (:flashcards current))
                  (first-flashcard-id (:flashcards projection))))
          local-graph-ids
          (match (:selected-graph-id projection)
            (Some graph-id)
            (if (string-vector-contains? (:local-graph-ids current) graph-id)
              (:local-graph-ids current)
              (conj (:local-graph-ids current) graph-id))
            None (:local-graph-ids current))
          sidebar (:sidebar projection)
          selected-graph-changed
          (not (= (:selected-graph-id current)
                  (:selected-graph-id projection)))
          updated
          (assoc current
                 :selected-graph (:graph-name projection)
                 :selected-graph-id (:selected-graph-id projection)
                 :graphs (:graphs projection)
                 :local-graph-ids local-graph-ids
                 :is-graph-encrypted (:is-graph-encrypted projection)
                 :is-graph-unlocked (:is-graph-unlocked projection)
                 :sync-state
                 (if (:sync-connected projection) SyncedState OfflineState)
                 :favorites (:favorites sidebar)
                 :recent-pages (:recent-pages sidebar)
                 :selected-page (:selected-page sidebar)
                 :selected-page-is-tag (:selected-page-is-tag sidebar)
                 :selected-page-is-property (:selected-page-is-property sidebar)
                 :related-rows (:related-rows sidebar)
                 :linked-reference-rows (:linked-reference-rows sidebar)
                 :task-statuses
                 (available-task-statuses (:task-statuses projection))
                 :flashcards (:flashcards projection)
                 :flashcard-cloze-revealed
                 (if card-changed false (:flashcard-cloze-revealed current))
                 :flashcard-answer-revealed
                 (if card-changed false (:flashcard-answer-revealed current))
                 :node-routes (:node-routes projection)
                 :outliner-editing (:outliner-editing projection)
                 :outliner-autocomplete (:outliner-autocomplete projection)
                 :outliner-autocomplete-candidates
                 (:outliner-autocomplete-candidates projection)
                 :outliner-selected-block-ids
                 (:outliner-selected-block-ids projection)
                 :outliner-rows projected-rows)
          searched
          (if (= (:search-query projection) (:search-query current))
            (assoc updated
                   :search-results (:search-results projection)
                   :search-loading false)
            updated)]
      (match (:selected-graph-id projection)
        None
        (assoc searched :graph-password-open false :graph-password "")
        (Some _graph-id)
        (if (:is-graph-unlocked projection)
          (assoc searched :graph-password-open false :graph-password "")
          (if (and selected-graph-changed
                   (:is-graph-encrypted projection))
            (assoc searched
                   :graph-password-open true
                   :graph-password ""
                   :effect-error None)
            searched))))

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

    (LongPressOutlinerBlock uuid)
    (let [id (:next-effect-id current)]
      (enqueue-effect current (LongPressOutlinerBlockEffect id uuid)))

    (PerformOutlinerToolbarAction action)
    (let [id (:next-effect-id current)]
      (enqueue-effect current (OutlinerToolbarEffect id action)))

    (ChooseOutlinerAutocomplete value)
    (let [id (:next-effect-id current)]
      (enqueue-effect current
                      (ChooseOutlinerAutocompleteEffect id value)))

    (OpenOutlinerAsset uuid)
    (match (row-index (:outliner-rows current) uuid)
      (Some index)
      (let [row (nth (:outliner-rows current) index)]
        (if (:is-asset row)
          (match (:local-path row)
            (Some path)
            (let [id (:next-effect-id current)
                  asset-type
                  (match (:asset-type row)
                    (Some value) value
                    None "application/octet-stream")]
              (enqueue-effect
               current
               (PresentAssetEffect id (:title row) asset-type path)))
            None current)
          current))
      None current)

    CloseSearch
    (let [path (:search-navigation-path current)
          closed
          (assoc current
                 :search-open false
                 :search-query ""
                 :search-results []
                 :search-loading false
                 :pending-effects
                 (remove-search-effects (:pending-effects current))
                 :search-navigation-path [])]
      (enqueue-close-search-effects closed path))

    ExpandComposer
    (assoc current :composer-expanded true :composer-autofocus true)

    FocusComposer
    (assoc current :composer-autofocus true)

    (ApplyComposerDraft draft)
    (assoc current :composer-draft draft)

    (ChangeComposerDraft draft)
    (let [updated
          (assoc current
                 :composer-draft draft
                 :composer-autofocus false
                 :pending-effects
                 (remove-composer-draft-effects (:pending-effects current)))
          id (:next-effect-id updated)]
      (enqueue-effect updated (PersistComposerDraftEffect id draft)))

    DismissComposer
    (assoc current :composer-expanded false :composer-autofocus false)

    SendComposer
    (let [submission (string/trim (:composer-draft current))]
      (if (empty? submission)
        current
        (let [cleared
              (assoc current
                     :composer-expanded true
                     :composer-draft ""
                     :composer-autofocus true
                     :pending-effects
                     (remove-composer-draft-effects (:pending-effects current)))
              persist-id (:next-effect-id cleared)
              persisted
              (enqueue-effect
               cleared (PersistComposerDraftEffect persist-id ""))
              send-id (:next-effect-id persisted)]
          (enqueue-effect
           persisted
           (match (:selected-task-status current)
             (Some status) (SendTaskEffect send-id submission status)
             None (SendCaptureEffect send-id submission))))))

    (DequeueEffect id)
    (let [pending (:pending-effects current)]
      (match (effect-with-id pending id)
        (Some effect)
        (assoc current
               :pending-effects (remove-effect pending id)
               :in-flight-effects
               (conj (:in-flight-effects current) effect))
        None current))

    (ResolveEffect id succeeded message)
    (match (effect-with-id (:in-flight-effects current) id)
      (Some effect)
      (let [resolved-current
            (if succeeded
              (resolve-successful-effect current effect message)
              (rollback-navigation-effect current effect))]
        (assoc resolved-current
               :in-flight-effects
               (remove-effect (:in-flight-effects current) id)
               :effect-error (if succeeded None (Some message))
               :last-core-response
               (if succeeded (Some message) (:last-core-response current))))
      None current)

    OpenAttachmentPicker
    (assoc current :attachment-picker-open true)

    CloseAttachmentPicker
    (assoc current :attachment-picker-open false)

    (ChooseAttachment kind)
    (if (valid-attachment-kind? kind)
      (let [updated (assoc current :attachment-picker-open false)
            id (:next-effect-id updated)]
        (enqueue-effect updated (PresentAttachmentEffect id kind)))
      current)

    OpenTaskStatusPicker
    (assoc current :task-status-picker-open true)

    CloseTaskStatusPicker
    (assoc current :task-status-picker-open false)

    (ChooseTaskStatus uuid)
    (match (task-status-by-id (:task-statuses current) uuid)
      (Some status)
      (assoc current
             :selected-task-status (Some status)
             :task-status-picker-open false)
      None current)

    ClearTaskStatus
    (assoc current
           :selected-task-status None
           :task-status-picker-open false)

    (RequestAppNode uuid)
    (let [path (:app-navigation-path current)
          requested (request-route path (NodeRoute uuid))]
      (if (= path requested)
        current
        (let [updated (assoc current :app-navigation-path requested)
              id (:next-effect-id updated)]
          (enqueue-effect updated (OpenAppNodeEffect id uuid)))))

    (ResolveAppNode uuid resolved)
    (assoc current
           :app-navigation-path
           (resolve-route (:app-navigation-path current)
                          (NodeRoute uuid)
                          resolved))

    BackAppNavigation
    (let [path (:app-navigation-path current)]
      (if (empty? path)
        current
        (let [uuid (navigation-route-uuid (nth path (dec (count path))))
              updated (assoc current :app-navigation-path (pop-route path))
              id (:next-effect-id updated)]
          (enqueue-effect updated (CloseAppNodeEffect id uuid)))))

    (RequestSearchNode uuid)
    (let [path (:search-navigation-path current)
          requested (request-route path (NodeRoute uuid))]
      (if (= path requested)
        current
        (let [updated (assoc current :search-navigation-path requested)
              id (:next-effect-id updated)]
          (enqueue-effect updated (OpenSearchNodeEffect id uuid)))))

    (ResolveSearchNode uuid resolved)
    (assoc current
           :search-navigation-path
           (resolve-route (:search-navigation-path current)
                          (NodeRoute uuid)
                          resolved))

    BackSearchNavigation
    (let [path (:search-navigation-path current)]
      (if (empty? path)
        current
        (let [uuid (navigation-route-uuid (nth path (dec (count path))))
              updated (assoc current :search-navigation-path (pop-route path))
              id (:next-effect-id updated)]
          (enqueue-effect updated (CloseSearchNodeEffect id uuid)))))

    (AddRootBlock uuid)
    (let [id (:next-effect-id current)]
      (enqueue-effect current (AddRootBlockEffect id uuid)))

    OpenSidebar
    (assoc current :sidebar-open true)

    CloseSidebar
    (assoc current :sidebar-open false)

    (SelectSidebarPage uuid)
    (let [updated (assoc current
                         :sidebar-open false
                         :destination JournalsDestination)
          id (:next-effect-id updated)]
      (enqueue-effect updated (SelectSidebarPageEffect id uuid)))

    ShowJournals
    (let [updated (assoc current
                         :sidebar-open false
                         :destination JournalsDestination)
          id (:next-effect-id updated)]
      (enqueue-effect updated (ClearSelectedPageEffect id)))

    ShowFlashcards
    (let [updated (assoc current
                         :sidebar-open false
                         :destination FlashcardsDestination)
          clear-id (:next-effect-id updated)
          cleared
          (enqueue-effect updated (ClearSelectedPageEffect clear-id))
          load-id (:next-effect-id cleared)]
      (enqueue-effect cleared (LoadFlashcardsEffect load-id)))

    ShowGraphs
    (assoc current
           :sidebar-open false
           :destination GraphsDestination)

    (ApplyLocalGraphIds graph-ids)
    (assoc current :local-graph-ids graph-ids)

    RefreshGraphs
    (let [id (:next-effect-id current)]
      (enqueue-effect current (RefreshGraphsEffect id)))

    (RequestOpenGraph graph-id)
    (match (graph-by-id (:graphs current) graph-id)
      (Some graph)
      (if (:is-ready graph)
        (let [id (:next-effect-id current)]
          (enqueue-effect current (OpenGraphEffect id graph-id)))
        current)
      None current)

    (ChangeGraphPassword password)
    (assoc current :graph-password password)

    SubmitGraphPassword
    (if (string/blank? (:graph-password current))
      current
      (let [id (:next-effect-id current)]
        (enqueue-effect current
                        (UnlockGraphEffect id (:graph-password current)))))

    CancelGraphUnlock
    (assoc current
           :graph-password-open false
           :graph-password ""
           :effect-error None)

    OpenCreateGraph
    (assoc current :create-graph-open true)

    DismissCreateGraph
    (assoc current :create-graph-open false)

    (ChangeNewGraphName name)
    (assoc current :new-graph-name name)

    (ToggleNewGraphEncrypted encrypted)
    (assoc current :new-graph-encrypted encrypted)

    SubmitCreateGraph
    (let [name (string/trim (:new-graph-name current))]
      (if (empty? name)
        current
        (let [id (:next-effect-id current)]
          (enqueue-effect
           current
           (CreateGraphEffect id name (:new-graph-encrypted current))))))

    (RequestDeleteGraph graph-id)
    (if (graph-local? current graph-id)
      (assoc current :pending-graph-deletion
             (graph-by-id (:graphs current) graph-id))
      current)

    CancelDeleteGraph
    (assoc current :pending-graph-deletion None)

    ConfirmDeleteGraph
    (match (:pending-graph-deletion current)
      (Some graph)
      (let [updated (assoc current :pending-graph-deletion None)
            id (:next-effect-id updated)]
        (enqueue-effect updated (DeleteLocalGraphEffect id (:id graph))))
      None current)

    (ApplySettingsSnapshot settings)
    (assoc current
           :appearance (:appearance settings)
           :language (:language settings)
           :spell-check (:spell-check settings)
           :auto-correction (:auto-correction settings)
           :sidebar-tabs (:sidebar-tabs settings)
           :base-url (:base-url settings)
           :version (:version settings)
           :revision (:revision settings))

    OpenConnectionMenu
    (assoc current :connection-menu-open true)

    CloseConnectionMenu
    (assoc current :connection-menu-open false)

    OpenSettings
    (assoc current
           :connection-menu-open false
           :settings-open true
           :settings-tabs-open false
           :runtime-log-open false)

    DismissSettings
    (assoc current
           :settings-open false
           :settings-tabs-open false
           :runtime-log-open false)

    OpenSettingsTabs
    (assoc current :settings-tabs-open true)

    BackSettings
    (assoc current :settings-tabs-open false :runtime-log-open false)

    (ChangeAppearance appearance)
    (assoc current :appearance appearance)

    (ChangeLanguage language)
    (assoc current :language language)

    (ToggleSpellCheck enabled)
    (assoc current :spell-check enabled)

    (ToggleAutoCorrection enabled)
    (assoc current :auto-correction enabled)

    (ToggleSidebarTab tab)
    (assoc current :sidebar-tabs
           (toggle-sidebar-tab (:sidebar-tabs current) tab))

    (MoveSidebarTab tab offset)
    (assoc current :sidebar-tabs
           (move-sidebar-tab (:sidebar-tabs current) tab offset))

    (ChangeBaseURL base-url)
    (assoc current :base-url base-url)

    ApplySettings
    (if (valid-base-url? (:base-url current))
      (let [id (:next-effect-id current)]
        (enqueue-effect
         (assoc current
                :settings-open false
                :settings-tabs-open false
                :runtime-log-open false)
         (SaveSettingsEffect id (current-settings current))))
      current)

    OpenRuntimeLog
    (assoc current :runtime-log-open true)

    DismissRuntimeLog
    (assoc current :runtime-log-open false)

    ToggleRuntimeLogErrors
    (let [updated
          (assoc current :runtime-log-errors-only
                 (not (:runtime-log-errors-only current)))
          id (:next-effect-id updated)]
      (enqueue-effect
       updated
       (RefreshRuntimeLogEffect
        id (:runtime-log-source updated) (:runtime-log-errors-only updated)
        (:runtime-log-newest-first updated))))

    ToggleRuntimeLogOrder
    (let [updated
          (assoc current :runtime-log-newest-first
                 (not (:runtime-log-newest-first current)))
          id (:next-effect-id updated)]
      (enqueue-effect
       updated
       (RefreshRuntimeLogEffect
        id (:runtime-log-source updated) (:runtime-log-errors-only updated)
        (:runtime-log-newest-first updated))))

    ToggleRuntimeLogSource
    (let [updated
          (assoc current :runtime-log-source
                 (if (= (:runtime-log-source current) "ui") "core" "ui"))
          id (:next-effect-id updated)]
      (enqueue-effect
       updated
       (RefreshRuntimeLogEffect
        id (:runtime-log-source updated) (:runtime-log-errors-only updated)
        (:runtime-log-newest-first updated))))

    (ApplyRuntimeLog records)
    (assoc current :runtime-log-records records)

    RefreshRuntimeLog
    (let [id (:next-effect-id current)]
      (enqueue-effect
       current
       (RefreshRuntimeLogEffect
        id (:runtime-log-source current) (:runtime-log-errors-only current)
        (:runtime-log-newest-first current))))

    CopyRuntimeLog
    (let [id (:next-effect-id current)]
      (enqueue-effect current
                      (CopyRuntimeLogEffect id (:runtime-log-records current))))

    SignOut
    (let [id (:next-effect-id current)]
      (enqueue-effect current (SignOutEffect id)))

    RevealFlashcardCloze
    (assoc current :flashcard-cloze-revealed true)

    RevealFlashcardAnswer
    (assoc current :flashcard-answer-revealed true)

    (ReviewFlashcard rating)
    (match (first-flashcard-id (:flashcards current))
      (Some uuid)
      (let [id (:next-effect-id current)]
        (enqueue-effect current (ReviewFlashcardEffect id uuid rating)))
      None current)))
