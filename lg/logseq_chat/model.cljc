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

(defn settings-language-choice [id title]
  (record settings-language-choice (id id) (title title)))

(defn settings-language-choices []
  [(settings-language-choice "system" "System")
   (settings-language-choice "en" "English")
   (settings-language-choice "fr" "Français")
   (settings-language-choice "de" "Deutsch")
   (settings-language-choice "nl" "Dutch (Nederlands)")
   (settings-language-choice "zh-CN" "简体中文")
   (settings-language-choice "zh-Hant" "繁體中文")
   (settings-language-choice "af" "Afrikaans")
   (settings-language-choice "ca" "Català")
   (settings-language-choice "es" "Español")
   (settings-language-choice "vi" "Tiếng Việt")
   (settings-language-choice "nb-NO" "Norsk (bokmål)")
   (settings-language-choice "pl" "Polski")
   (settings-language-choice "pt-BR" "Português (Brasileiro)")
   (settings-language-choice "pt-PT" "Português (Europeu)")
   (settings-language-choice "ru" "Русский")
   (settings-language-choice "ja" "日本語")
   (settings-language-choice "it" "Italiano")
   (settings-language-choice "tr" "Türkçe")
   (settings-language-choice "uk" "Українська")
   (settings-language-choice "ko" "한국어")
   (settings-language-choice "sk" "Slovenčina")
   (settings-language-choice "fa" "فارسی")
   (settings-language-choice "id" "Bahasa Indonesia")
   (settings-language-choice "cs" "Čeština")
   (settings-language-choice "ar" "العربية")])

(defn settings-community-link [id title url]
  (record settings-community-link (id id) (title title) (url url)))

(defn settings-community-links []
  [(settings-community-link
    "report-bug" "Report bug" "https://github.com/logseq/db-test/issues")
   (settings-community-link
    "discord" "Discord community" "https://discord.com/invite/KpN4eHY")
   (settings-community-link "forum" "Forum" "https://discuss.logseq.com")
   (settings-community-link
    "github" "GitHub" "https://github.com/logseq/logseq")])

(defn settings-language-by-id [choices target]
  (loop [index 0]
    (if (= index (count choices))
      None
      (let [choice (nth choices index)]
        (if (= target (:id choice))
          (Some choice)
          (recur (inc index)))))))

(defn initial []
  (record chat-model
          (selected-graph None)
          (selected-graph-id None)
          (graphs [])
          (local-graph-ids [])
          (is-graph-encrypted false)
          (is-graph-unlocked false)
          (graph-loading false)
          (graph-password-open false)
          (graph-password "")
          (authentication-state "restoring")
          (authentication-error None)
          (sync-state OfflineState)
          (applied-server-t None)
          (has-pending-semantic-operations false)
          (has-pending-sync-request false)
          (sync-details-open false)
          (destination JournalsDestination)
          (sidebar-open false)
          (graph-menu-open false)
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
          (new-graph-encrypted true)
          (pending-graph-deletion None)
          (pending-page-deletion None)
          (connection-menu-open false)
          (settings-open false)
          (settings-tabs-open false)
          (runtime-log-open false)
          (appearance "system")
          (settings-appearance-menu-open false)
          (language "system")
          (language-choices (settings-language-choices))
          (settings-language-menu-open false)
          (community-links (settings-community-links))
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
          (journal-outliner-rows [])
          (outliner-rows [])
          (outliner-selected-block-ids [])
          (outliner-editing None)
          (outliner-autocomplete None)
          (outliner-autocomplete-candidates [])
          (outliner-task-status-block-id None)
          (outliner-section-markers [])
          (has-older-journals false)
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
          (app-navigation-previews [])
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

(defn remove-node-projection [routes uuid]
  (filterv (fn [route] (not (= (:uuid route) uuid))) routes))

(defn back-app-navigation [current requested]
  (loop [remaining (min (max requested 0)
                        (count (:app-navigation-path current)))
         updated current]
    (if (= remaining 0)
      updated
      (let [path (:app-navigation-path updated)
            uuid (navigation-route-uuid (nth path (dec (count path))))
            popped
            (assoc (cancel-outliner-editing updated)
                   :app-navigation-path (pop-route path)
                   :app-navigation-previews
                   (remove-node-projection
                    (:app-navigation-previews updated) uuid))
            id (:next-effect-id popped)]
        (recur (dec remaining)
               (enqueue-effect popped (CloseAppNodeEffect id uuid)))))))

(defn return-to-app-root [current]
  (back-app-navigation current (count (:app-navigation-path current))))

(defn back-search-navigation [current requested]
  (loop [remaining (min (max requested 0)
                        (count (:search-navigation-path current)))
         updated current]
    (if (= remaining 0)
      updated
      (let [path (:search-navigation-path updated)
            uuid (navigation-route-uuid (nth path (dec (count path))))
            popped
            (assoc (cancel-outliner-editing updated)
                   :search-navigation-path (pop-route path))
            id (:next-effect-id popped)]
        (recur (dec remaining)
               (enqueue-effect popped (CloseSearchNodeEffect id uuid)))))))

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
    (PresentPageShareEffect id _text _paths) id
    (SetPageFavoriteEffect id _uuid _favorite) id
    (DeletePageEffect id _uuid) id
    (SyncNowEffect id) id
    (SetOutlinerTaskStatusEffect id _block-id _status) id
    (SearchNodesEffect id _query) id
    (TapOutlinerBlockEffect id _uuid) id
    (ChangeOutlinerTextEffect id _uuid _title _caret) id
    (ReturnOutlinerEditorEffect id _uuid _title _caret) id
    (BackspaceOutlinerEditorEffect id _uuid _title _selection) id
    (MoveOutlinerCaretEffect id _uuid _caret) id
    (ToggleOutlinerCollapsedEffect id _uuid) id
    (LongPressOutlinerBlockEffect id _uuid) id
    (DropOutlinerBlocksEffect id _target-uuid _placement) id
    (OutlinerToolbarEffect id _action) id
    (ChooseOutlinerAutocompleteEffect id _value) id
    (CancelOutlinerEditingEffect id) id
    (OpenAppNodeEffect id _uuid) id
    (OpenSearchNodeEffect id _uuid) id
    (CloseAppNodeEffect id _uuid) id
    (CloseSearchNodeEffect id _uuid) id
    (AddRootBlockEffect id _uuid) id
    (SelectSidebarPageEffect id _uuid) id
    (ClearSelectedPageEffect id) id
    (LoadOlderJournalsEffect id) id
    (LoadFlashcardsEffect id) id
    (ReviewFlashcardEffect id _uuid _rating) id
    (RefreshGraphsEffect id) id
    (OpenGraphEffect id _graph-id) id
    (UnlockGraphEffect id _password) id
    (CreateGraphEffect id _name _is-encrypted) id
    (DeleteLocalGraphEffect id _graph-id) id
    (SaveSettingsEffect id _settings) id
    (ExportGraphDatabaseEffect id) id
    (OpenExternalURLEffect id _url) id
    (RefreshRuntimeLogEffect id _source _errors-only _newest-first) id
    (CopyRuntimeLogEffect id _records) id
    (SignInEffect id) id
    (SignOutEffect id) id))

(defn effect-with-id [effects target]
  (loop [index 0]
    (if (= index (count effects))
      None
      (let [effect (nth effects index)]
        (if (= (effect-id effect) target)
          (Some effect)
          (recur (inc index)))))))

(defn contains-sign-in-effect? [effects]
  (loop [index 0]
    (if (= index (count effects))
      false
      (let [found
            (match (nth effects index)
              (SignInEffect _id) true
              _ false)]
        (if found true (recur (inc index)))))))

(defn contains-load-older-journals-effect? [effects]
  (loop [index 0]
    (if (= index (count effects))
      false
      (let [found
            (match (nth effects index)
              (LoadOlderJournalsEffect _id) true
              _ false)]
        (if found true (recur (inc index)))))))

(defn load-older-journals-active? [current]
  (or
   (contains-load-older-journals-effect? (:pending-effects current))
   (contains-load-older-journals-effect? (:in-flight-effects current))))

(defn graph-effect-key [effect]
  (match effect
    (RefreshGraphsEffect _id) "refresh"
    (CreateGraphEffect _id _name _is-encrypted) "create"
    (UnlockGraphEffect _id _password) "unlock"
    (DeleteLocalGraphEffect _id graph-id) (str "delete:" graph-id)
    _ ""))

(defn contains-graph-effect? [effects key]
  (loop [index 0]
    (if (= index (count effects))
      false
      (if (= key (graph-effect-key (nth effects index)))
        true
        (recur (inc index))))))

(defn graph-effect-active? [current key]
  (or (contains-graph-effect? (:pending-effects current) key)
      (contains-graph-effect? (:in-flight-effects current) key)))

(defn graph-refresh-active? [current]
  (graph-effect-active? current "refresh"))

(defn graph-create-active? [current]
  (graph-effect-active? current "create"))

(defn graph-unlock-active? [current]
  (graph-effect-active? current "unlock"))

(defn graph-delete-active? [current graph-id]
  (graph-effect-active? current (str "delete:" graph-id)))

(defn sign-in-active? [current]
  (or (contains-sign-in-effect? (:pending-effects current))
      (contains-sign-in-effect? (:in-flight-effects current))))

(defn change-outliner-text-effect-for? [effect uuid]
  (match effect
    (ChangeOutlinerTextEffect _id effect-uuid _title _caret)
    (= effect-uuid uuid)
    _ false))

(defn contains-change-outliner-text-effect? [effects uuid]
  (loop [index 0]
    (if (= index (count effects))
      false
      (if (change-outliner-text-effect-for? (nth effects index) uuid)
        true
        (recur (inc index))))))

(defn change-outliner-text-active? [current uuid]
  (or (contains-change-outliner-text-effect?
       (:pending-effects current) uuid)
      (contains-change-outliner-text-effect?
       (:in-flight-effects current) uuid)))

(defn snapshot-outliner-editing [current projection]
  (match (:outliner-editing current)
    (Some editing)
    (if (change-outliner-text-active? current (:uuid editing))
      (Some editing)
      (:outliner-editing projection))
    None (:outliner-editing projection)))

(defn first-flashcard-id [flashcards]
  (if (empty? flashcards)
    None
    (Some (:uuid (nth flashcards 0)))))

(defn journal-section-key [row]
  (match (:journal-day row)
    (Some day) (Some (str day))
    None
    (match (:journal-title row)
      (Some title) (if (string/blank? title) None (Some title))
      None None)))

(defn journal-section-title [row]
  (match (:journal-title row)
    (Some title) (if (string/blank? title)
                   (match (:journal-day row)
                     (Some day) (str day)
                     None "")
                   title)
    None
    (match (:journal-day row)
      (Some day) (str day)
      None "")))

(defn finish-journal-section [result start start-index end-index]
  (match start
    (Some row)
    (conj
     result
     (record journal-section-marker
       (block-id (:uuid row))
       (page-id (:page-id row))
       (title (journal-section-title row))
       (has-divider (not (empty? result)))
       (start-index start-index)
       (end-index end-index)))
    None result))

(defn journal-section-markers [rows]
  (loop [index 0
         section-key None
         section-start None
         section-start-index 0
         result []]
    (if (= index (count rows))
      (finish-journal-section result section-start section-start-index index)
      (let [row (nth rows index)
            row-key (journal-section-key row)
            starts-section
            (match row-key
              (Some _key) (not (= row-key section-key))
              None false)
            next-result
            (if starts-section
              (finish-journal-section
               result section-start section-start-index index)
              result)
            next-start
            (if starts-section (Some row) section-start)
            next-start-index
            (if starts-section index section-start-index)]
        (recur (inc index)
               (if starts-section row-key section-key)
               next-start
               next-start-index
               next-result)))))

(defn node-route-by-uuid [routes uuid]
  (loop [index 0]
    (if (= index (count routes))
      None
      (let [route (nth routes index)]
        (if (= (:uuid route) uuid)
          (Some route)
          (recur (inc index)))))))

(defn journal-preview-route [current uuid]
  (let [rows (:journal-outliner-rows current)
        markers (journal-section-markers rows)]
    (loop [index 0]
      (if (= index (count markers))
        None
        (let [section (nth markers index)]
          (if (= (:page-id section) uuid)
            (Some
             (record node-projection
               (uuid uuid)
               (page-uuid uuid)
               (title (:title section))
               (is-tag false)
               (is-property false)
               (outliner-rows
                (subvec rows (:start-index section) (:end-index section)))
               (related-rows [])
               (linked-reference-rows [])
               (outliner-editing None)
               (outliner-autocomplete None)
               (outliner-autocomplete-candidates [])
               (outliner-selected-block-ids [])))
            (recur (inc index))))))))

(defn publish-navigation-preview [current uuid]
  (match (node-route-by-uuid (:node-routes current) uuid)
    (Some _route) current
    None
    (match (node-route-by-uuid (:app-navigation-previews current) uuid)
      (Some _preview) current
      None
      (match (journal-preview-route current uuid)
        (Some preview)
        (assoc current :app-navigation-previews
               (conj (:app-navigation-previews current) preview))
        None current))))

(defn app-node-routes-from [current path index]
  (if (= index (count path))
    []
    (let [uuid (navigation-route-uuid (nth path index))
          route
          (match (node-route-by-uuid (:node-routes current) uuid)
            (Some resolved) (Some resolved)
            None
            (node-route-by-uuid (:app-navigation-previews current) uuid))]
      (match route
        (Some resolved)
        (into [resolved] (app-node-routes-from current path (inc index)))
        None []))))

(defn app-node-routes [current]
  (app-node-routes-from current (:app-navigation-path current) 0))

(defn sidebar-page-in [pages uuid]
  (loop [index 0]
    (if (= index (count pages))
      None
      (let [page (nth pages index)]
        (if (= (:uuid page) uuid)
          (Some page)
          (recur (inc index)))))))

(defn sidebar-page-by-uuid [current uuid]
  (match (sidebar-page-in (:favorites current) uuid)
    (Some page) (Some page)
    None (sidebar-page-in (:recent-pages current) uuid)))

(defn journal-rows-for-page [current uuid]
  (let [rows (:journal-outliner-rows current)
        markers (journal-section-markers rows)]
    (loop [index 0]
      (if (= index (count markers))
        []
        (let [marker (nth markers index)]
          (if (= (:page-id marker) uuid)
            (subvec rows (:start-index marker) (:end-index marker))
            (recur (inc index))))))))

(defn preview-sidebar-page [current uuid]
  (match (sidebar-page-by-uuid current uuid)
    (Some page)
    (let [rows (journal-rows-for-page current uuid)]
      (assoc current
             :selected-page (Some page)
             :selected-page-is-tag false
             :selected-page-is-property false
             :related-rows []
             :linked-reference-rows []
             :outliner-rows rows
             :outliner-section-markers (journal-section-markers rows)))
    None current))

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

(defn valid-sidebar-tab? [tab]
  (or (= tab "journals") (= tab "flashcards") (= tab "graphs")))

(defn normalize-sidebar-tabs [tabs]
  (if (empty? tabs)
    ["journals" "flashcards" "graphs"]
    (let [normalized
          (loop [index 0
                 result ["journals"]]
            (if (= index (count tabs))
              result
              (let [tab (nth tabs index)]
                (recur
                 (inc index)
                 (if (and (valid-sidebar-tab? tab)
                          (not (= tab "journals"))
                          (not (string-vector-contains? result tab)))
                   (conj result tab)
                   result)))))]
      (if (string-vector-contains? normalized "graphs")
        normalized
        (conj normalized "graphs")))))

(defn toggle-sidebar-tab [tabs tab]
  (if (not (= tab "flashcards"))
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

(defn bounded-url-delimiter [index fallback]
  (if (< index 0) fallback index))

(defn valid-base-url? [value]
  (let [normalized (string/trim value)
        prefix-length
        (cond
          (string/starts-with? normalized "https://") 8
          (string/starts-with? normalized "http://") 7
          :else 0)]
    (if (= prefix-length 0)
      false
      (let [remainder (subs normalized prefix-length)
            length (count remainder)
            host-end
            (min
             (bounded-url-delimiter (string/index-of remainder "/") length)
             (bounded-url-delimiter (string/index-of remainder "?") length)
             (bounded-url-delimiter (string/index-of remainder "#") length))
            host (subs remainder 0 host-end)]
        (and (not (string/blank? host))
             (not (string/includes? normalized " "))
             (not (string/includes? normalized "\n"))
             (not (string/includes? normalized "\r")))))))

(defn valid-attachment-kind? [kind]
  (or (= kind "files")
      (= kind "camera")
      (= kind "photos")
      (= kind "audio")))

(defn indexed-outliner-autocomplete-candidates [candidates]
  (loop [index 0
         result []]
    (if (= index (count candidates))
      result
      (let [candidate (nth candidates index)]
        (recur
         (inc index)
         (conj result
               (record outliner-autocomplete-candidate
                 (index index)
                 (label (:label candidate))
                 (value (:value candidate)))))))))

(defn valid-authentication-state? [state]
  (or (= state "restoring")
      (= state "signedOut")
      (= state "signingIn")
      (= state "signedIn")
      (= state "signingOut")))

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

(defn active-page [current]
  (if (not (= (:destination current) JournalsDestination))
    None
    (if (empty? (:node-routes current))
      (:selected-page current)
      (let [route (last (:node-routes current))]
        (Some
         (record sidebar-page
           (uuid (:page-uuid route))
           (title (:title route))))))))

(defn page-is-favorite? [current uuid]
  (loop [index 0]
    (if (= index (count (:favorites current)))
      false
      (if (= (:uuid (nth (:favorites current) index)) uuid)
        true
        (recur (inc index))))))

(defn page-share-text [page rows]
  (loop [index 0
         lines [(:title page)]]
    (if (= index (count rows))
      (string/join "\n" lines)
      (let [title (string/trim (:title (nth rows index)))]
        (recur (inc index)
               (if (empty? title) lines (conj lines (str "- " title))))))))

(defn page-share-asset-paths [rows]
  (loop [index 0
         paths []]
    (if (= index (count rows))
      paths
      (let [row (nth rows index)
            next-paths
            (match (:local-path row)
              (Some path)
              (if (and (:is-asset row)
                       (not (empty? path))
                       (not (string-vector-contains? paths path)))
                (conj paths path)
                paths)
              None paths)]
        (recur (inc index) next-paths)))))

(defn rollback-navigation-effect [current effect]
  (match effect
    (OpenAppNodeEffect _id uuid)
    (assoc current
           :app-navigation-path
           (resolve-route (:app-navigation-path current)
                          (NodeRoute uuid) false)
           :app-navigation-previews
           (remove-node-projection (:app-navigation-previews current) uuid))
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
    (OpenGraphEffect _id _graph-id)
    (assoc current :graph-loading false)
    _ current))

(defn resolve-failed-effect [current effect message]
  (match effect
    (SignInEffect _id)
    (assoc current
           :authentication-state "signedOut"
           :authentication-error (Some message))
    (RefreshGraphsEffect _id)
    (assoc current :sync-state (FailedState message))
    _ (rollback-navigation-effect current effect)))

(defn resolve-successful-effect [current effect message]
  (match effect
    (SignInEffect _id)
    (assoc current
           :authentication-state "signedIn"
           :authentication-error None)
    (OpenGraphEffect _id graph-id)
    (match (graph-by-id (:graphs current) graph-id)
      (Some selected)
      (assoc current
             :destination JournalsDestination
             :graph-loading false
             :selected-graph-id (Some graph-id)
             :selected-graph (Some (:name selected)))
      None (assoc current
                  :destination JournalsDestination
                  :graph-loading false))
    (UnlockGraphEffect _id _password)
    (assoc current :graph-password-open false :graph-password "")
    (CreateGraphEffect _id _name _is-encrypted)
    (assoc current
           :destination JournalsDestination
           :create-graph-open false
           :new-graph-name "")
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
           :authentication-state "signedOut"
           :authentication-error None
           :settings-open false
           :settings-tabs-open false
           :runtime-log-open false)
    _ current))

(defn enqueue-effect [current effect]
  (assoc current
         :pending-effects (conj (:pending-effects current) effect)
         :next-effect-id (inc (:next-effect-id current))
         :effect-error None))

(defn enqueue-open-graph [current graph-id]
  (let [loading (assoc current :graph-loading true)
        id (:next-effect-id loading)]
    (enqueue-effect loading (OpenGraphEffect id graph-id))))

(defn persist-settings-change [current updated]
  (if (= (current-settings current) (current-settings updated))
    updated
    (let [id (:next-effect-id updated)]
      (enqueue-effect
       updated
       (SaveSettingsEffect id (current-settings updated))))))

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

(defn cancel-outliner-editing [current]
  (match (:outliner-editing current)
    (Some _editing)
    (let [updated
          (assoc current
                 :outliner-editing None
                 :outliner-autocomplete None
                 :outliner-autocomplete-candidates [])
          id (:next-effect-id updated)]
      (enqueue-effect updated (CancelOutlinerEditingEffect id)))
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
    (if (:is-pending-sync-patch projection)
      (assoc current
             :has-pending-semantic-operations
             (:has-pending-semantic-operations projection)
             :has-pending-sync-request
             (:has-pending-sync-request projection))
      (if (:is-outliner-patch projection)
        (let [projected-rows
              (if (empty? (:outliner-row-splices projection))
                (merge-row-replacements
                 (:outliner-rows current) (:outliner-rows projection))
                (apply-row-splices (:outliner-rows current)
                                   (:outliner-row-splices projection)))
              journal-rows
              (if (and
                   (empty? (:node-routes current))
                   (match (:selected-page current)
                     None true
                     (Some _page) false))
                projected-rows
                (:journal-outliner-rows current))]
          (assoc current
                 :has-pending-semantic-operations
                 (:has-pending-semantic-operations projection)
                 :has-pending-sync-request
                 (:has-pending-sync-request projection)
                 :journal-outliner-rows journal-rows
                 :outliner-editing (snapshot-outliner-editing current projection)
                 :outliner-autocomplete (:outliner-autocomplete projection)
                 :outliner-autocomplete-candidates
                 (indexed-outliner-autocomplete-candidates
                  (:outliner-autocomplete-candidates projection))
                 :outliner-selected-block-ids
                 (:outliner-selected-block-ids projection)
                 :outliner-section-markers
                 (journal-section-markers projected-rows)
                 :outliner-rows projected-rows))
        (let [projected-rows (:outliner-rows projection)
          journal-rows
          (if (and
               (empty? (:node-routes projection))
               (match (:selected-page (:sidebar projection))
                 None true
                 (Some _page) false))
            projected-rows
            (if (and
                 (empty? (:journal-outliner-rows current))
                 (match (:selected-page (:sidebar projection))
                   None true
                   (Some _page) false))
              (:journal-outliner-rows projection)
              (:journal-outliner-rows current)))
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
                 (if (:sync-connected projection)
                   (if (or (:has-pending-semantic-operations projection)
                           (:has-pending-sync-request projection))
                     SyncingState
                     SyncedState)
                   OfflineState)
                 :applied-server-t (:applied-server-t projection)
                 :has-pending-semantic-operations
                 (:has-pending-semantic-operations projection)
                 :has-pending-sync-request
                 (:has-pending-sync-request projection)
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
                 :journal-outliner-rows journal-rows
                 :outliner-editing (snapshot-outliner-editing current projection)
                 :outliner-autocomplete (:outliner-autocomplete projection)
                 :outliner-autocomplete-candidates
                 (indexed-outliner-autocomplete-candidates
                  (:outliner-autocomplete-candidates projection))
                 :outliner-selected-block-ids
                 (:outliner-selected-block-ids projection)
                 :has-older-journals (:has-older-journals projection)
                 :outliner-section-markers
                 (journal-section-markers projected-rows)
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
            searched))))))

    (BeginOutlinerEdit uuid)
    (let [id (:next-effect-id current)]
      (enqueue-effect current (TapOutlinerBlockEffect id uuid)))

    (ChangeOutlinerText uuid title caret)
    (let [updated (assoc (update-editing current uuid title caret)
                         :sync-state SyncingState)
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

    (LongPressOutlinerBlock uuid)
    (let [id (:next-effect-id current)]
      (enqueue-effect current (LongPressOutlinerBlockEffect id uuid)))

    (BeginOutlinerDrag uuid)
    (if (string-vector-contains? (:outliner-selected-block-ids current) uuid)
      current
      (let [id (:next-effect-id current)]
        (enqueue-effect current (LongPressOutlinerBlockEffect id uuid))))

    (DropOutlinerBlocks target-uuid placement)
    (let [id (:next-effect-id current)]
      (enqueue-effect
       current
       (DropOutlinerBlocksEffect id target-uuid placement)))

    (PerformOutlinerToolbarAction action)
    (let [updated (cond
                    (= action "task")
                    (assoc current :sync-state SyncingState)

                    (= action "hideKeyboard")
                    (assoc current
                           :outliner-editing None
                           :outliner-autocomplete None
                           :outliner-autocomplete-candidates [])

                    :else current)
          id (:next-effect-id updated)]
      (enqueue-effect updated (OutlinerToolbarEffect id action)))

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
          editing-ended
          (if (empty? path) current (cancel-outliner-editing current))
          closed
          (assoc editing-ended
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
              (resolve-failed-effect current effect message))]
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
        (let [updated
              (assoc (publish-navigation-preview
                      (cancel-outliner-editing current) uuid)
                     :app-navigation-path requested)
              id (:next-effect-id updated)]
          (enqueue-effect updated (OpenAppNodeEffect id uuid)))))

    (ResolveAppNode uuid resolved)
    (let [updated
          (assoc current
                 :app-navigation-path
                 (resolve-route (:app-navigation-path current)
                                (NodeRoute uuid)
                                resolved))]
      (if resolved
        updated
        (assoc updated
               :app-navigation-previews
               (remove-node-projection
                (:app-navigation-previews updated) uuid))))

    (BackAppNavigation count)
    (back-app-navigation current count)

    (RequestSearchNode uuid)
    (let [path (:search-navigation-path current)
          requested (request-route path (NodeRoute uuid))]
      (if (= path requested)
        current
        (let [updated
              (assoc (cancel-outliner-editing current)
                     :search-navigation-path requested)
              id (:next-effect-id updated)]
          (enqueue-effect updated (OpenSearchNodeEffect id uuid)))))

    (ResolveSearchNode uuid resolved)
    (assoc current
           :search-navigation-path
           (resolve-route (:search-navigation-path current)
                          (NodeRoute uuid)
                          resolved))

    (BackSearchNavigation count)
    (back-search-navigation current count)

    (AddRootBlock uuid)
    (let [id (:next-effect-id current)]
      (enqueue-effect current (AddRootBlockEffect id uuid)))

    LoadOlderJournals
    (if (load-older-journals-active? current)
      current
      (let [id (:next-effect-id current)]
        (enqueue-effect current (LoadOlderJournalsEffect id))))

    OpenSidebar
    (assoc current :sidebar-open true)

    CloseSidebar
    (assoc current :sidebar-open false :graph-menu-open false)

    OpenGraphMenu
    (assoc current :graph-menu-open true)

    DismissGraphMenu
    (assoc current :graph-menu-open false)

    (SelectSidebarGraph graph-id)
    (match (graph-by-id (:graphs current) graph-id)
      (Some graph)
      (if (:is-ready graph)
        (let [updated
              (assoc (cancel-outliner-editing (return-to-app-root current))
                     :sidebar-open false
                     :graph-menu-open false)
              selected
              (match (:selected-graph-id updated)
                (Some selected-id) (= selected-id graph-id)
                None false)]
          (if selected
            (let [id (:next-effect-id updated)]
              (enqueue-effect updated (ClearSelectedPageEffect id)))
            (enqueue-open-graph updated graph-id)))
        current)
      None current)

    (SelectSidebarPage uuid)
    (let [updated
          (preview-sidebar-page
           (assoc (cancel-outliner-editing (return-to-app-root current))
                  :sidebar-open false
                  :graph-menu-open false
                  :destination JournalsDestination)
           uuid)
          id (:next-effect-id updated)]
      (enqueue-effect updated (SelectSidebarPageEffect id uuid)))

    ShowJournals
    (let [updated (assoc (cancel-outliner-editing (return-to-app-root current))
                         :sidebar-open false
                         :graph-menu-open false
                         :destination JournalsDestination)
          id (:next-effect-id updated)]
      (enqueue-effect updated (ClearSelectedPageEffect id)))

    ShowFlashcards
    (let [updated (assoc (cancel-outliner-editing (return-to-app-root current))
                         :sidebar-open false
                         :graph-menu-open false
                         :destination FlashcardsDestination)
          clear-id (:next-effect-id updated)
          cleared
          (enqueue-effect updated (ClearSelectedPageEffect clear-id))
          load-id (:next-effect-id cleared)]
      (enqueue-effect cleared (LoadFlashcardsEffect load-id)))

    ShowGraphs
    (assoc (cancel-outliner-editing (return-to-app-root current))
           :sidebar-open false
           :graph-menu-open false
           :destination GraphsDestination)

    (ApplyLocalGraphIds graph-ids)
    (assoc current :local-graph-ids graph-ids)

    (ApplyGraphLoading loading)
    (assoc current :graph-loading loading)

    RefreshGraphs
    (if (graph-refresh-active? current)
      current
      (let [id (:next-effect-id current)]
        (enqueue-effect current (RefreshGraphsEffect id))))

    (RequestOpenGraph graph-id)
    (match (graph-by-id (:graphs current) graph-id)
      (Some graph)
      (if (:is-ready graph)
        (enqueue-open-graph (cancel-outliner-editing current) graph-id)
        current)
      None current)

    (ChangeGraphPassword password)
    (assoc current :graph-password password)

    SubmitGraphPassword
    (if (or (string/blank? (:graph-password current))
            (graph-unlock-active? current))
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
      (if (or (empty? name) (graph-create-active? current))
        current
        (let [id (:next-effect-id current)]
          (enqueue-effect
           current
           (CreateGraphEffect id name (:new-graph-encrypted current))))))

    (RequestDeleteGraph graph-id)
    (if (and (graph-local? current graph-id)
             (not (graph-delete-active? current graph-id)))
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

    (ApplyAuthentication state error)
    (if (valid-authentication-state? state)
      (if (and (= state "signedOut") (sign-in-active? current))
        current
        (assoc current
               :authentication-state state
               :authentication-error error))
      current)

    SignIn
    (if (= (:authentication-state current) "signedOut")
      (let [updated
            (assoc current
                   :authentication-state "signingIn"
                   :authentication-error None)
            id (:next-effect-id updated)]
        (enqueue-effect updated (SignInEffect id)))
      current)

    (ApplySettingsSnapshot settings)
    (assoc current
           :appearance (:appearance settings)
           :language (:language settings)
           :spell-check (:spell-check settings)
           :auto-correction (:auto-correction settings)
           :sidebar-tabs (normalize-sidebar-tabs (:sidebar-tabs settings))
           :base-url (:base-url settings)
           :version (:version settings)
           :revision (:revision settings))

    OpenConnectionMenu
    (assoc current :connection-menu-open true)

    CloseConnectionMenu
    (assoc current :connection-menu-open false)

    OpenSyncDetails
    (assoc current :sync-details-open true)

    CloseSyncDetails
    (assoc current :sync-details-open false)

    SyncNow
    (let [id (:next-effect-id current)]
      (enqueue-effect current (SyncNowEffect id)))

    (OpenOutlinerTaskStatusPicker block-id)
    (assoc current :outliner-task-status-block-id (Some block-id))

    CloseOutlinerTaskStatusPicker
    (assoc current :outliner-task-status-block-id None)

    (ChooseOutlinerTaskStatus status-id)
    (match (:outliner-task-status-block-id current)
      (Some block-id)
      (match (task-status-by-id (:task-statuses current) status-id)
        (Some status)
        (let [updated (assoc current
                             :outliner-task-status-block-id None
                             :sync-state SyncingState)
              id (:next-effect-id updated)]
          (enqueue-effect
           updated (SetOutlinerTaskStatusEffect id block-id status)))
        None current)
      None current)

    ToggleActivePageFavorite
    (match (active-page current)
      (Some page)
      (let [updated (assoc current :connection-menu-open false)
            id (:next-effect-id updated)]
        (enqueue-effect
         updated
         (SetPageFavoriteEffect
          id (:uuid page) (not (page-is-favorite? current (:uuid page))))))
      None current)

    ShareActivePage
    (match (active-page current)
      (Some page)
      (let [updated (assoc current :connection-menu-open false)
            id (:next-effect-id updated)]
        (enqueue-effect
         updated
         (PresentPageShareEffect
          id
          (page-share-text page (:outliner-rows current))
          (page-share-asset-paths (:outliner-rows current)))))
      None current)

    RequestDeleteActivePage
    (match (active-page current)
      (Some page)
      (assoc current
             :connection-menu-open false
             :pending-page-deletion (Some page))
      None current)

    CancelDeleteActivePage
    (assoc current :pending-page-deletion None)

    ConfirmDeleteActivePage
    (match (:pending-page-deletion current)
      (Some page)
      (let [updated (assoc current :pending-page-deletion None)
            delete-id (:next-effect-id updated)
            deleting
            (enqueue-effect updated (DeletePageEffect delete-id (:uuid page)))]
        (if (empty? (:app-navigation-path deleting))
          (let [clear-id (:next-effect-id deleting)]
            (enqueue-effect deleting (ClearSelectedPageEffect clear-id)))
          (let [path (:app-navigation-path deleting)
                route (nth path (dec (count path)))
                closed (assoc deleting :app-navigation-path (pop-route path))
                close-id (:next-effect-id closed)]
            (enqueue-effect
             closed
             (CloseAppNodeEffect close-id (navigation-route-uuid route))))))
      None current)

    OpenSettings
    (assoc current
           :connection-menu-open false
           :settings-open true
           :settings-tabs-open false
           :settings-appearance-menu-open false
           :settings-language-menu-open false
           :runtime-log-open false)

    DismissSettings
    (assoc current
           :settings-open false
           :settings-tabs-open false
           :settings-appearance-menu-open false
           :settings-language-menu-open false
           :runtime-log-open false)

    OpenSettingsTabs
    (assoc current :settings-tabs-open true)

    BackSettings
    (assoc current :settings-tabs-open false :runtime-log-open false)

    OpenSettingsAppearanceMenu
    (assoc current :settings-appearance-menu-open true)

    CloseSettingsAppearanceMenu
    (assoc current :settings-appearance-menu-open false)

    (ChangeAppearance appearance)
    (persist-settings-change
     current
     (assoc current
            :appearance appearance
            :settings-appearance-menu-open false))

    OpenSettingsLanguageMenu
    (assoc current :settings-language-menu-open true)

    CloseSettingsLanguageMenu
    (assoc current :settings-language-menu-open false)

    (ChooseSettingsLanguage language)
    (match (settings-language-by-id (:language-choices current) language)
      (Some choice)
      (persist-settings-change
       current
       (assoc current
              :language (:id choice)
              :settings-language-menu-open false))
      None (assoc current :settings-language-menu-open false))

    (ToggleSpellCheck enabled)
    (persist-settings-change
     current
     (assoc current :spell-check enabled))

    (ToggleAutoCorrection enabled)
    (persist-settings-change
     current
     (assoc current :auto-correction enabled))

    (ToggleSidebarTab tab)
    (persist-settings-change
     current
     (assoc current :sidebar-tabs
            (toggle-sidebar-tab (:sidebar-tabs current) tab)))

    (MoveSidebarTab tab offset)
    (persist-settings-change
     current
     (assoc current :sidebar-tabs
            (move-sidebar-tab (:sidebar-tabs current) tab offset)))

    (ChangeBaseURL base-url)
    (assoc current :base-url base-url)

    ApplySettings
    (if (valid-base-url? (:base-url current))
      (let [id (:next-effect-id current)]
        (enqueue-effect
         (assoc current
                :settings-open false
                :settings-tabs-open false
                :settings-language-menu-open false
                :runtime-log-open false)
         (SaveSettingsEffect id (current-settings current))))
      current)

    ExportGraphDatabase
    (let [id (:next-effect-id current)]
      (enqueue-effect current (ExportGraphDatabaseEffect id)))

    (OpenExternalURL url)
    (let [id (:next-effect-id current)]
      (enqueue-effect current (OpenExternalURLEffect id url)))

    OpenRuntimeLog
    (let [updated (assoc current :runtime-log-open true)
          id (:next-effect-id updated)]
      (enqueue-effect
       updated
       (RefreshRuntimeLogEffect
        id (:runtime-log-source updated) (:runtime-log-errors-only updated)
        (:runtime-log-newest-first updated))))

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
