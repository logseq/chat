(ns logseq-chat.graph-read
  (:require [clojure.string :as string]
            [logseq-chat.cache-model :as model]
            [logseq-chat.datascript-value :as ds-value]
            [logseq-chat.ref-text :as ref-text]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.String :as bytes]
            [ocaml.Rrbvec :as rrbvec]))

(type-record sidebar-pages
             (favorites :vector<model/entity-summary>) (recent-pages :vector<model/entity-summary>))

(defn value [db eid attr]
  (when-some [datom (first (db-api/datoms db (ds/Eavt) :e eid :a attr))] (:v datom)))
(defn string-value [value]
  (match value (Some (ds/String value)) (Some value) _ nil))
(defn uuid-value [value]
  (match value (Some (ds/Uuid value)) (Some value) (Some (ds/String value)) (Some value) _ nil))
(defn int-value [value]
  (match value (Some (ds/Int value)) (Some value) (Some (ds/Instant value)) (Some value) _ nil))
(defn protected-string [decrypt-title value]
  (when-some [value (string-value value)]
    (match (decrypt-title value) (Ok value) value (Error message) (throw (Failure (str "decrypt graph title: " message))))))
(defn uuid-for-eid [db eid] (uuid-value (value db eid "block/uuid")))
(defn has-ref? [db eid attr target-eid]
  (boolean (some (fn [datom] (= (ds-value/ref-eid db attr (:v datom)) (Some target-eid)))
                 (db-api/datoms db (ds/Eavt) :e eid :a attr))))
(defn ref-eids [db eid attr]
  (vec (keep (fn [datom] (ds-value/ref-eid db attr (:v datom))) (db-api/datoms db (ds/Eavt) :e eid :a attr))))
(defn class-descendants [db root-eid]
  (loop [pending [root-eid] seen #{}]
    (if (empty? pending)
      seen
      (let [eid (nth pending (dec (count pending))) pending (pop pending)]
        (if (contains? seen eid)
          (recur pending seen)
          (recur (into pending (map :e (ds-value/datoms-by-ref db (ds/Aevt) "logseq.property.class/extends" eid)))
                 (conj seen eid)))))))
(defn entity-is-instance-of? [db eid class-ident]
  (if-some [class-eid (ds/entid db "db/ident" (ds/Keyword class-ident))]
    (let [accepted (class-descendants db class-eid)]
      (boolean (some (fn [eid] (contains? accepted eid)) (ref-eids db eid "block/tags"))))
    false))
(defn entity-summary [decrypt-title db eid]
  (let [uuid (uuid-for-eid db eid)
        title (protected-string decrypt-title (value db eid "block/title"))]
    (when-some [uuid uuid]
      (when-some [title title] (record model/entity-summary (uuid uuid) (title title))))))
(defn entity-summaries [decrypt-title db eid attr]
  (vec (keep (fn [datom]
               (when-some [eid (ds-value/ref-eid db attr (:v datom))] (entity-summary decrypt-title db eid)))
             (db-api/datoms db (ds/Eavt) :e eid :a attr))))
(defn tag-is-visible-in-node? [db eid]
  (and (not= (value db eid "db/ident") (Some (ds/Keyword "logseq.class/Task")))
       (not= (value db eid "logseq.property.class/hide-from-node") (Some (ds/Bool true)))))
(defn visible-tag-summaries [decrypt-title db eid]
  (vec (keep (fn [datom]
               (when-some [tag-eid (ds-value/ref-eid db "block/tags" (:v datom))]
                 (when (and (tag-is-visible-in-node? db tag-eid) (entity-is-instance-of? db tag-eid "logseq.class/Tag"))
                   (entity-summary decrypt-title db tag-eid))))
             (db-api/datoms db (ds/Eavt) :e eid :a "block/tags"))))
(defn breadcrumbs [decrypt-title db eid]
  (loop [seen #{} eid eid ancestors []]
    (if (contains? seen eid)
      (vec (reverse ancestors))
      (if-some [parent-eid (ds-value/optional-ref-eid db "block/parent" (value db eid "block/parent"))]
        (recur (conj seen eid) parent-eid
               (if-some [summary (entity-summary decrypt-title db parent-eid)] (conj ancestors summary) ancestors))
        (vec (reverse ancestors))))))
(defn status-for-eid [decrypt-title db eid]
  (when-some [status-eid (ds-value/optional-ref-eid db "logseq.property/status" (value db eid "logseq.property/status"))]
    (let [ident (match (value db status-eid "db/ident") (Some (ds/Keyword ident)) (Some ident) _ nil)
          uuid (or (uuid-for-eid db status-eid) ident "")
          title (or (protected-string decrypt-title (value db status-eid "block/title")) uuid)]
      (when (not= uuid "")
        (record model/status (uuid uuid) (ident ident) (title title)
                (icon-type nil) (icon-id nil) (icon-color nil))))))
(defn block [decrypt-title db eid]
  (let [uuid (uuid-for-eid db eid)
        title (protected-string decrypt-title (value db eid "block/title"))
        name (value db eid "block/name")]
    (when (nil? name)
      (when-some [uuid uuid]
        (when-some [title title]
          (let [referenced-uuid (fn [attr] (when-some [eid (ds-value/optional-ref-eid db attr (value db eid attr))] (uuid-for-eid db eid)))
                page-eid (ds-value/optional-ref-eid db "block/page" (value db eid "block/page"))
                page-id (or (when-some [eid page-eid] (uuid-for-eid db eid)) "")
                ancestors (breadcrumbs decrypt-title db eid)
                journal (when-some [eid page-eid]
                          (let [title (some (fn [summary] (when (= (:uuid summary) page-id) (:title summary))) ancestors)
                                day (int-value (value db eid "block/journal-day"))]
                            (when-some [title title] (when-some [day day] (tuple title day)))))
                created-at (or (int-value (value db eid "block/created-at")) 0)]
            (record model/block
                    (uuid uuid) (title title) (page-id page-id) (parent-id (referenced-uuid "block/parent"))
                    (order (string-value (value db eid "block/order"))) (created-at created-at)
                    (updated-at (or (int-value (value db eid "block/updated-at")) created-at)) (sync-status "synced")
                    (tags (rrbvec/to-list (visible-tag-summaries decrypt-title db eid)))
                    (references (rrbvec/to-list (entity-summaries decrypt-title db eid "block/refs")))
                    (breadcrumbs (rrbvec/to-list ancestors)) (status (status-for-eid decrypt-title db eid))
                    (is-asset (entity-is-instance-of? db eid "logseq.class/Asset"))
                    (asset-type (string-value (value db eid "logseq.property.asset/type")))
                    (asset-size (int-value (value db eid "logseq.property.asset/size")))
                    (asset-checksum (string-value (value db eid "logseq.property.asset/checksum")))
                    (local-path nil) (journal journal))))))))

(defn page-is-hidden? [db eid]
  (loop [seen #{} eid eid]
    (cond
      (contains? seen eid) false
      (= (value db eid "logseq.property/hide?") (Some (ds/Bool true))) true
      (some? (value db eid "logseq.property/deleted-at")) true
      :else
      (if-some [parent-eid (ds-value/optional-ref-eid db "block/parent" (value db eid "block/parent"))]
        (recur (conj seen eid) parent-eid) false))))
(defn page-summary [decrypt-title db eid]
  (let [uuid (uuid-for-eid db eid) title (protected-string decrypt-title (value db eid "block/title"))
        name (string-value (value db eid "block/name"))]
    (when-some [uuid uuid]
      (when-some [title title]
        (when-some [name name]
          (when (and (not= (string/trim title) "") (not (string/starts-with? name "$$$")) (not (page-is-hidden? db eid)))
            (record model/entity-summary (uuid uuid) (title title))))))))
(defn favorite-page-eid [db]
  (when-some [datom (first (db-api/datoms db (ds/Aevt) :a "block/name" :v (ds/String "$$$favorites")))] (:e datom)))
(defn recycle-page-eid [db]
  (when-some [datom (first (db-api/datoms db (ds/Aevt) :a "block/name" :v (ds/String "recycle")))] (:e datom)))
(defn last-order [db attr eid]
  (let [orders (keep (fn [datom] (string-value (value db (:e datom) "block/order")))
                     (ds-value/datoms-by-ref db (ds/Aevt) attr eid))]
    (when-some [initial (first orders)]
      (reduce (fn [latest order] (if (>= (compare latest order) 0) latest order))
              initial (rest orders)))))
(defn last-recycle-order [db] (when-some [eid (recycle-page-eid db)] (last-order db "block/parent" eid)))
(defn last-favorite-order [db] (when-some [eid (favorite-page-eid db)] (last-order db "block/page" eid)))
(defn favorite-block-eid [db page-uuid]
  (let [favorites-eid (favorite-page-eid db) page-eid (ds/entid db "block/uuid" (ds/Uuid page-uuid))]
    (when-some [favorites-eid favorites-eid]
      (when-some [page-eid page-eid]
        (some (fn [datom]
                (when (= (ds-value/optional-ref-eid db "block/link" (value db (:e datom) "block/link")) (Some page-eid)) (:e datom)))
              (ds-value/datoms-by-ref db (ds/Aevt) "block/page" favorites-eid))))))
(defn favorite-block-uuid [db page-uuid] (when-some [eid (favorite-block-eid db page-uuid)] (uuid-for-eid db eid)))
(defn page-is-favorite? [db page-uuid] (some? (favorite-block-eid db page-uuid)))
(defn built-in-class? [db eid]
  (match (value db eid "db/ident") (Some (ds/Keyword ident)) (string/starts-with? ident "logseq.class/") _ false))

(defn sidebar-pages [decrypt-title db]
  (let [favorites (if-some [eid (favorite-page-eid db)]
                    (mapv second
                          (sort-by first
                                   (keep (fn [datom]
                                           (when-some [eid (ds-value/optional-ref-eid db "block/link" (value db (:e datom) "block/link"))]
                                             (when-some [page (page-summary decrypt-title db eid)]
                                               (tuple (or (string-value (value db (:e datom) "block/order")) "") page))))
                                         (ds-value/datoms-by-ref db (ds/Aevt) "block/page" eid))))
                    [])
        favorite-uuids (set (map :uuid favorites))
        candidates (keep (fn [datom]
                           (match (:v datom)
                             (ds/String name)
                             (when (not (string/starts-with? name "$$$"))
                               (let [attrs (into {} (map (fn [datom] (tuple (:a datom) (:v datom)))
                                                         (db-api/datoms db (ds/Eavt) :e (:e datom))))
                                     built-in (match (get attrs "db/ident")
                                                (Some (ds/Keyword ident)) (string/starts-with? ident "logseq.class/") _ false)]
                                 (when (and (not built-in) (not= (get attrs "logseq.property/built-in?") (Some (ds/Bool true))))
                                   (tuple (or (int-value (get attrs "block/updated-at")) 0)
                                          (or (int-value (get attrs "block/journal-day")) 0) (:e datom)))))
                             _ nil))
                         (db-api/datoms db (ds/Aevt) :a "block/name"))
        ranked (sort (fn [[left-updated left-day left-eid] [right-updated right-day right-eid]]
                       (let [updated (compare right-updated left-updated) day (compare right-day left-day)]
                         (cond (not= updated 0) updated (not= day 0) day :else (compare right-eid left-eid)))) candidates)
        ;; Resolve and decrypt only enough ranked pages to fill the visible window.
        recent (vec (take 15 (keep (fn [eid]
                                     (when-some [page (page-summary decrypt-title db eid)]
                                       (when (not (contains? favorite-uuids (:uuid page))) page)))
                                   (distinct (map (fn [[_ _ eid]] eid) ranked)))))]
    (record sidebar-pages (favorites favorites) (recent-pages recent))))

(defn page-block [decrypt-title db eid]
  (when-some [page (page-summary decrypt-title db eid)]
    (let [created-at (or (int-value (value db eid "block/created-at")) 0)]
      (record model/block
              (uuid (:uuid page)) (title (:title page)) (page-id (:uuid page)) (parent-id nil) (order nil)
              (created-at created-at) (updated-at (or (int-value (value db eid "block/updated-at")) created-at))
              (sync-status "synced") (tags (rrbvec/to-list (visible-tag-summaries decrypt-title db eid)))
              (references (list)) (breadcrumbs (list)) (status nil) (is-asset false)
              (asset-type nil) (asset-size nil) (asset-checksum nil) (local-path nil)
              (journal (when-some [day (int-value (value db eid "block/journal-day"))] (tuple (:title page) day)))))))
(defn tag-available-for-completion? [db eid]
  (match (value db eid "db/ident")
    (Some (ds/Keyword ident))
    (not (contains? #{"logseq.class/Root" "logseq.class/Page" "logseq.class/Property" "logseq.class/Tag"
                      "logseq.class/Asset" "logseq.class/Journal" "logseq.class/Whiteboard" "logseq.class/Pdf-annotation"} ident))
    _ true))
(defn tag-last-used [db eid]
  (reduce (fn [latest datom] (max latest (:tx datom))) 0 (ds-value/datoms-by-ref db (ds/Aevt) "block/tags" eid)))
(defn tag-pages [decrypt-title db]
  (if-some [eid (ds/entid db "db/ident" (ds/Keyword "logseq.class/Tag"))]
    (mapv second
          (sort (fn [[left-used left] [right-used right]]
                  (let [used (compare right-used left-used) title (compare (:title left) (:title right))]
                    (cond (not= used 0) used (not= title 0) title :else (compare (:uuid left) (:uuid right)))))
                (keep (fn [datom]
                        (when (tag-available-for-completion? db (:e datom))
                          (when-some [page (page-summary decrypt-title db (:e datom))] (tuple (tag-last-used db (:e datom)) page))))
                      (ds-value/datoms-by-ref db (ds/Aevt) "block/tags" eid))))
    []))
(defn node-is-tag? [db uuid]
  (if-some [eid (ds/entid db "block/uuid" (ds/Uuid uuid))] (entity-is-instance-of? db eid "logseq.class/Tag") false))
(defn node-is-property? [db uuid]
  (if-some [eid (ds/entid db "block/uuid" (ds/Uuid uuid))] (entity-is-instance-of? db eid "logseq.class/Property") false))
(defn unique-named-uuid [require-tag db name]
  (let [key (bytes/lowercase-ascii (string/trim name))]
    (when (not= key "")
      (let [matches (vec (filter (fn [eid] (or (not require-tag) (entity-is-instance-of? db eid "logseq.class/Tag")))
                                 (map :e (db-api/datoms db (ds/Aevt) :a "block/name" :v (ds/String key)))))]
        (when (= (count matches) 1) (uuid-for-eid db (nth matches 0)))))))
(defn known-title [^:seqable<model/entity-summary> summaries name]
  (let [key (bytes/lowercase-ascii (string/trim name))]
    (when (not= key "")
      (let [matches (filterv (fn [summary] (= (bytes/lowercase-ascii (:title summary)) key)) summaries)]
        (when (= (count matches) 1) (:uuid (nth matches 0)))))))
(defn normalize-title-text [create-tag db uuid title]
  (let [[refs tags] (if-some [eid (ds/entid db "block/uuid" (ds/Uuid uuid))]
                      (tuple (entity-summaries (fn [value] (Ok value)) db eid "block/refs")
                             (entity-summaries (fn [value] (Ok value)) db eid "block/tags"))
                      (tuple [] []))]
    (ref-text/to-ids (fn [name] (or (known-title (concat refs tags) name) (unique-named-uuid false db name)))
                     (fn [name] (or (known-title tags name) (unique-named-uuid true db name) (create-tag name))) title)))
(type-record created-tags (entries :ref<vector<tuple<string;string>>>))
(defn normalize-titles-creating-tags [db fresh-uuid uuid titles]
  (let [created (record created-tags (entries (atom [])))
        create-tag (fn [name]
                     (let [name (string/trim name) key (bytes/lowercase-ascii name)]
                       (when (not= key "")
                         (if-some [uuid (some (fn [[uuid existing]] (when (= (bytes/lowercase-ascii existing) key) uuid)) @(:entries created))]
                           uuid
                           (let [uuid (fresh-uuid)] (swap! (:entries created) conj (tuple uuid name)) uuid)))))
        titles (mapv (fn [title] (normalize-title-text create-tag db uuid title)) titles)]
    (tuple titles @(:entries created))))

(defn compare-blocks [left right]
  (match (tuple (:order left) (:order right))
    [(Some left-order) (Some right-order)] (compare left-order right-order)
    [(Some _) None] -1 [None (Some _)] 1 [None None] (compare (:created-at left) (:created-at right))))
(defn journal-day [block] (if-some [[_ day] (:journal block)] day 0))
(defn compare-journal-blocks [left right]
  (let [order (compare (journal-day right) (journal-day left))] (if (zero? order) (compare-blocks left right) order)))
(defn related-candidate-is-visible? [db eid]
  (and (not (page-is-hidden? db eid)) (nil? (value db eid "logseq.property/view-for"))))
(defn blocks-referencing [decrypt-title db attr target-uuid]
  (if-some [eid (ds/entid db "block/uuid" (ds/Uuid target-uuid))]
    (vec (sort compare-blocks (keep (fn [datom] (when (related-candidate-is-visible? db (:e datom)) (block decrypt-title db (:e datom))))
                                    (ds-value/datoms-by-ref db (ds/Aevt) attr eid)))) []))
(defn blocks-for-page [decrypt-title db uuid] (blocks-referencing decrypt-title db "block/page" uuid))
(defn references-for-node [decrypt-title db uuid] (blocks-referencing decrypt-title db "block/refs" uuid))
(defn node-destination [decrypt-title db uuid]
  (when-some [eid (ds/entid db "block/uuid" (ds/Uuid uuid))]
    (when (not (page-is-hidden? db eid))
      (let [is-page (some? (string-value (value db eid "block/name")))
            page-eid (if is-page (Some eid) (ds-value/optional-ref-eid db "block/page" (value db eid "block/page")))]
        (when-some [eid page-eid]
          (when-some [page (page-summary decrypt-title db eid)] (tuple page (not is-page))))))))
(defn objects-for-tag [decrypt-title db uuid]
  (if-some [eid (ds/entid db "block/uuid" (ds/Uuid uuid))]
    (let [ids (set (map :e (mapcat (fn [eid] (ds-value/datoms-by-ref db (ds/Aevt) "block/tags" eid))
                                   (sort (class-descendants db eid)))))]
      (vec (sort compare-journal-blocks
                 (keep (fn [eid] (when (related-candidate-is-visible? db eid)
                                   (or (block decrypt-title db eid) (page-block decrypt-title db eid)))) (sort ids))))) []))
(defn recent-journal-page-ids [limit db]
  (mapv second
        (take limit (sort (fn [[left _] [right _]] (compare right left))
                          (keep (fn [datom]
                                  (match (:v datom)
                                    (ds/Int day) (when (not (page-is-hidden? db (:e datom))) (tuple day (:e datom)))
                                    _ nil))
                                (db-api/datoms db (ds/Aevt) :a "block/journal-day"))))))
(defn journal-page-count [db]
  (reduce (fn [count datom] (if (page-is-hidden? db (:e datom)) count (inc count)))
          0 (db-api/datoms db (ds/Aevt) :a "block/journal-day")))
(defn journal-page-uuid [db day]
  (some (fn [datom]
          (match (:v datom)
            (ds/Int candidate) (when (and (= day candidate) (not (page-is-hidden? db (:e datom)))) (uuid-for-eid db (:e datom)))
            _ nil)) (db-api/datoms db (ds/Aevt) :a "block/journal-day")))
(defn blocks [decrypt-title journal-limit db]
  (let [ids (set (map :e (mapcat (fn [eid] (ds-value/datoms-by-ref db (ds/Aevt) "block/page" eid))
                                 (recent-journal-page-ids journal-limit db))))]
    (vec (sort compare-journal-blocks (keep (fn [eid] (block decrypt-title db eid)) (sort ids))))))
