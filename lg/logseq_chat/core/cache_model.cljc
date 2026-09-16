(ns logseq-chat.cache-model
  (:require [clojure.string :as string]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Datascript_lg :as typed-db]
            [ocaml.Datascript_lg.Attribute :as attribute]
            [ocaml.Datascript_lg.Codec :as codec]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]))

(type-record entity-summary (uuid :string) (title :string))

(type-record status
  (uuid :string) (ident :option<string>) (title :string)
  (icon-type :option<string>) (icon-id :option<string>) (icon-color :option<string>))

(type-record block
  (uuid :string) (title :string) (page-id :string) (parent-id :option<string>)
  (order :option<string>) (created-at :int) (updated-at :int) (sync-status :string)
  (tags :list<entity-summary>) (references :list<entity-summary>) (breadcrumbs :list<entity-summary>)
  (status :option<status>) (is-asset :bool) (asset-type :option<string>)
  (asset-size :option<int>) (asset-checksum :option<string>) (local-path :option<string>)
  (journal :option<tuple<string;int>>))

(deftype CacheModel [^:mutable ^:Datascript.db db
                     ^:mutable ^:option<string> selected-block-uuid
                     ^:mutable ^:option<int> last-refresh-at
                     ^:mutable ^:int revision])

(defn one [value-type indexed unique]
  (record Datascript.schema_attr
    (cardinality (ds/One)) (unique unique) (indexed indexed) (is-component false)
    (no-history false) (doc nil) (value-type (Some value-type))
    (tuple-attrs nil) (tuple-types nil)))

(defn text-attribute [name indexed]
  (attribute/make name codec/string (one (ds/StringType) indexed nil)))

(defn number-attribute [name indexed]
  (attribute/make name codec/int (one (ds/NumberType) indexed nil)))

(def block-uuid (attribute/make "block/uuid" codec/string (one (ds/StringType) true (Some (ds/Identity)))))

(def block-title (text-attribute "block/title" false))

(def block-page-id (text-attribute "block/page-id" true))

(def block-parent-id (text-attribute "block/parent-id" false))

(def block-order (text-attribute "block/order" true))

(def block-created-at (number-attribute "block/created-at" true))

(def block-updated-at (number-attribute "block/updated-at" true))

(def block-sync-status (text-attribute "block/sync-status" true))

(def block-tags-json (text-attribute "block/tags-json" false))

(def block-references-json (text-attribute "block/references-json" false))

(def block-breadcrumbs-json (text-attribute "block/breadcrumbs-json" false))

(def block-status-json (text-attribute "block/status-json" false))

(def block-asset-type (text-attribute "block/asset-type" true))

(def block-asset-size (number-attribute "block/asset-size" false))

(def block-asset-checksum (text-attribute "block/asset-checksum" false))

(def block-local-path (text-attribute "block/local-path" false))

(def page-journal-day (number-attribute "page/journal-day" true))

(def page-title (text-attribute "page/title" false))

(def schema
  [(attribute/schema block-uuid) (attribute/schema block-title) (attribute/schema block-page-id)
   (attribute/schema block-parent-id) (attribute/schema block-order)
   (attribute/schema block-created-at) (attribute/schema block-updated-at)
   (attribute/schema block-sync-status) (attribute/schema block-tags-json)
   (attribute/schema block-references-json) (attribute/schema block-breadcrumbs-json)
   (attribute/schema block-status-json) (attribute/schema block-asset-type)
   (attribute/schema block-asset-size) (attribute/schema block-asset-checksum)
   (attribute/schema block-local-path) (attribute/schema page-journal-day) (attribute/schema page-title)])

(defn add [attribute entity value]
  (ds/Add entity (attribute/name attribute) (codec/encode (attribute/codec attribute) value)))

(defn read [attribute entity]
  (when-some [entity entity] (typed-db/or-raise (attribute/read-one attribute entity))))

(defn block-ref [uuid] (ds/Lookup_ref "block/uuid" (ds/String uuid)))

(defn create [storage]
  (let [db (if-some [storage storage]
             (if-some [db (ds/restore storage)]
               db
               (let [db (ds/empty-db :schema (rrbvec/to-list schema) :storage storage)]
                 (ds/store :storage storage db)
                 db))
             (ds/empty-db :schema (rrbvec/to-list schema)))]
    (CacheModel. db nil nil 0)))

(defn summaries-json [^:list<entity-summary> summaries]
  (json/to-string
   (tag List (rrbvec/to-list
              (mapv (fn [summary]
                      (tag Assoc (list (tuple "uuid" (tag String (:uuid summary)))
                                       (tuple "title" (tag String (:title summary))))))
                    summaries)))))

(defn json-string [^:map<string;Yojson.Basic.t> fields key]
  (match (get fields key) (Some (tag String value)) (Some value) _ nil))

(defn summaries-of-json [source]
  (try
    (match (json/from-string source)
      (tag List values)
      (vec (keep (fn [value]
                   (match value
                     (tag Assoc entries)
                     (let [fields (into {} entries)]
                       (when-some [uuid (json-string fields "uuid")]
                         (when-some [title (json-string fields "title")]
                           (record entity-summary (uuid uuid) (title title)))))
                     _ nil))
                 values))
      _ [])
    (catch _ [])))

(defn status-json [^:status status]
  (let [optional (keep (fn [[key value]] (when-some [value value] (tuple key (tag String value))))
                      [(tuple "ident" (:ident status)) (tuple "icon-type" (:icon-type status))
                       (tuple "icon-id" (:icon-id status)) (tuple "icon-color" (:icon-color status))])]
    (json/to-string
     (tag Assoc (rrbvec/to-list
                 (into [(tuple "uuid" (tag String (:uuid status))) (tuple "title" (tag String (:title status)))]
                       optional))))))

(defn status-of-json [source]
  (try
    (match (json/from-string source)
      (tag Assoc entries)
      (let [fields (into {} entries)]
        (when-some [uuid (json-string fields "uuid")]
          (when-some [title (json-string fields "title")]
            (record status (uuid uuid) (title title) (ident (json-string fields "ident"))
              (icon-type (json-string fields "icon-type")) (icon-id (json-string fields "icon-id"))
              (icon-color (json-string fields "icon-color"))))))
      _ nil)
    (catch _ nil)))

(defn block-exists? [model uuid]
  (some? (read block-uuid (ds/entity (.-db model) (block-ref uuid)))))

(defn read-block [model uuid]
  (let [entity (ds/entity (.-db model) (block-ref uuid))]
    (when-some [uuid (read block-uuid entity)]
      (let [asset-type (read block-asset-type entity)]
        (record block
          (uuid uuid) (title (or (read block-title entity) "")) (page-id (or (read block-page-id entity) ""))
          (parent-id (read block-parent-id entity)) (order (read block-order entity))
          (created-at (or (read block-created-at entity) 0)) (updated-at (or (read block-updated-at entity) 0))
          (sync-status (or (read block-sync-status entity) "synced"))
          (tags (rrbvec/to-list (summaries-of-json (or (read block-tags-json entity) "[]"))))
          (references (rrbvec/to-list (summaries-of-json (or (read block-references-json entity) "[]"))))
          (breadcrumbs (rrbvec/to-list (summaries-of-json (or (read block-breadcrumbs-json entity) "[]"))))
          (status (when-some [value (read block-status-json entity)] (status-of-json value)))
          (is-asset (some? asset-type)) (asset-type asset-type) (asset-size (read block-asset-size entity))
          (asset-checksum (read block-asset-checksum entity)) (local-path (read block-local-path entity))
          (journal nil))))))

(defn journal-metadata [model page-id]
  (let [entity (ds/entity (.-db model) (block-ref page-id))
        day (or (read page-journal-day entity) 0)]
    (when (pos? day) (tuple (or (read page-title entity) "") day))))

(defn all-block-uuids [model]
  (vec (keep (fn [datom] (match (:v datom) (ds/String uuid) (Some uuid) _ nil))
             (db-api/datoms (.-db model) (ds/Aevt) :a "block/uuid"))))

(defn all-blocks [model] (vec (keep (fn [uuid] (read-block model uuid)) (all-block-uuids model))))

(defn all-statuses [model]
  (vec (keep (fn [uuid]
               (when (and (> (count uuid) 15) (string/starts-with? uuid "status-catalog/"))
                 (when-some [block (read-block model uuid)] (:status block))))
             (all-block-uuids model))))

(defn local-time [now] (unix/localtime (/ (double now) 1000.0)))

(defn journal-day-for-ms [now]
  (let [tm (local-time now)] (+ (* (+ (:tm-year tm) 1900) 10000) (* (inc (:tm-mon tm)) 100) (:tm-mday tm))))

(defn journal-page-id-for-ms [now]
  (let [tm (local-time now)]
    (format "journal/%04d-%02d-%02d" (+ (:tm-year tm) 1900) (inc (:tm-mon tm)) (:tm-mday tm))))

(defn block-journal-metadata [model block]
  (or (:journal block) (journal-metadata model (:page-id block))))

(defn journal-feed-block? [model block]
  (and (not= (:page-id block) "")
       (if-some [[_ day] (block-journal-metadata model block)]
         (<= day (journal-day-for-ms (long (* (unix/gettimeofday) 1000.0)))) false)))

(defn recent-feed-block? [model block]
  (and (not= (string/trim (:title block)) "") (journal-feed-block? model block)))

(defn compare-recent [left right]
  (let [order (compare (:created-at right) (:created-at left))]
    (if (zero? order) (compare (:uuid left) (:uuid right)) order)))

(defn compare-outliner [left right]
  (match (tuple (:order left) (:order right))
    [(Some left-order) (Some right-order)]
    (let [order (compare left-order right-order)] (if (zero? order) (compare (:uuid left) (:uuid right)) order))
    [(Some _) None] -1
    [None (Some _)] 1
    [None None]
    (let [order (compare (:created-at left) (:created-at right))]
      (if (zero? order) (compare (:uuid left) (:uuid right)) order))))

(defn outliner-preorder [page-id blocks]
  (let [blocks (vec blocks)
        by-uuid (into {} (map (fn [block] (tuple (:uuid block) block)) blocks))
        children (group-by (fn [block]
                             (if-some [parent (:parent-id block)]
                               (if (or (contains? by-uuid parent) (= parent page-id)) parent page-id)
                               page-id)) blocks)]
    (loop [pending (vec (reverse (sort compare-outliner (get children page-id [])))) seen #{} ordered []]
      (if (empty? pending)
        (into ordered (sort compare-outliner (remove (fn [block] (contains? seen (:uuid block))) blocks)))
        (let [block (nth pending (dec (count pending))) pending (pop pending)]
          (if (contains? seen (:uuid block))
            (recur pending seen ordered)
            (recur (into pending (reverse (sort compare-outliner (get children (:uuid block) []))))
                   (conj seen (:uuid block)) (conj ordered block))))))))

(defn journal-blocks [include-empty model blocks]
  (let [groups (group-by :page-id (filter (fn [block]
                                          (if include-empty (journal-feed-block? model block)
                                              (recent-feed-block? model block))) blocks))
        day (fn [[page-id blocks]]
              (let [journal (if-some [block (first blocks)] (block-journal-metadata model block)
                              (journal-metadata model page-id))]
                (if-some [[_ day] journal] day 0)))
        groups (sort (fn [[left-page left-blocks] [right-page right-blocks]]
                       (let [order (compare (day (tuple left-page left-blocks)) (day (tuple right-page right-blocks)))]
                         (if (zero? order) (compare left-page right-page) order))) groups)]
    (vec (mapcat (fn [[page-id blocks]] (outliner-preorder page-id blocks)) groups))))

(defn recent-blocks [model]
  (journal-blocks false model (take 100 (sort compare-recent (filter (fn [block] (recent-feed-block? model block))
                                                                  (all-blocks model))))))

(defn visible-blocks [model] (recent-blocks model))

(defn visible-from [model blocks]
  (journal-blocks true model (take 100 (sort compare-recent (filter (fn [block] (journal-feed-block? model block)) blocks)))))

(defn selected-block [model]
  (when-some [uuid (.-selected-block-uuid model)] (read-block model uuid)))

(defn commit [model transactions]
  (let [report (ds/transact (.-db model) (rrbvec/to-list (vec transactions)))]
    (set! (.-db model) (:db-after report))
    (set! (.-revision model) (inc (.-revision model)))
    (when-some [storage (ds/storage (.-db model))] (ds/store :storage storage (.-db model)))
    (stdlib/ignore 0)))

(defn upsert-statuses [model statuses]
  (let [transactions (vec (mapcat (fn [status]
                                   (let [uuid (str "status-catalog/" (:uuid status))
                                         entity (if (block-exists? model uuid) (block-ref uuid) (ds/Temp_id (str "status-" (:uuid status))))]
                                     [(add block-uuid entity uuid) (add block-title entity "") (add block-page-id entity "")
                                      (add block-created-at entity 0) (add block-updated-at entity 0)
                                      (add block-sync-status entity "synced") (add block-status-json entity (status-json status))])) statuses))]
    (when (seq transactions) (commit model transactions))
    (stdlib/ignore 0)))

(defn prefer-local-asset [local ^:block remote]
  (assoc remote :is-asset (or (:is-asset local) (:is-asset remote))
         :asset-type (or (:asset-type local) (:asset-type remote))
         :asset-size (or (:asset-size local) (:asset-size remote))
         :asset-checksum (or (:asset-checksum local) (:asset-checksum remote))
         :local-path (or (:local-path local) (:local-path remote))))

(defn block-transactions [model incoming]
  (let [existing (read-block model (:uuid incoming))
        block (if-some [existing existing]
                (cond
                  (and (not= (:sync-status existing) "synced") (= (:sync-status incoming) "synced")) existing
                  (and (some? (:local-path existing)) (nil? (:local-path incoming))) (prefer-local-asset existing incoming)
                  :else incoming)
                incoming)
        entity (if (some? existing) (block-ref (:uuid block)) (ds/Temp_id (str "block-" (:uuid block))))
        created-at (if (pos? (:created-at block)) (:created-at block) (if-some [existing existing] (:created-at existing) 0))
        updated-at (if (pos? (:updated-at block)) (:updated-at block) (if-some [existing existing] (:updated-at existing) created-at))
        page-id (if (not= (:page-id block) "") (:page-id block) (if-some [existing existing] (:page-id existing) ""))
        order (or (:order block) (when-some [existing existing] (:order existing)))
        optional [(when-some [status (:status block)] (add block-status-json entity (status-json status)))
                  (when-some [value (:asset-type block)] (add block-asset-type entity value))
                  (when-some [value (:asset-size block)] (add block-asset-size entity value))
                  (when-some [value (:asset-checksum block)] (add block-asset-checksum entity value))
                  (when-some [value (:local-path block)] (add block-local-path entity value))
                  (when-some [value order] (add block-order entity value))
                  (when-some [value (:parent-id block)] (add block-parent-id entity value))]]
    (into [(add block-uuid entity (:uuid block)) (add block-title entity (:title block)) (add block-page-id entity page-id)
           (add block-created-at entity created-at) (add block-updated-at entity updated-at)
           (add block-sync-status entity (:sync-status block)) (add block-tags-json entity (summaries-json (:tags block)))
           (add block-references-json entity (summaries-json (:references block)))
           (add block-breadcrumbs-json entity (summaries-json (:breadcrumbs block)))]
          (keep identity optional))))

(defn upsert-blocks [model blocks refresh-time]
  (let [transactions (vec (mapcat (fn [block] (block-transactions model block)) blocks))]
    (when (seq transactions) (commit model transactions))
    (set! (.-last-refresh-at model) (Some refresh-time))
    (stdlib/ignore 0)))

(defn select [model uuid]
  (if (block-exists? model uuid)
    (do (set! (.-selected-block-uuid model) (Some uuid)) (Ok (stdlib/ignore 0)))
    (Error (str "unknown block: " uuid))))

(defn clear-selection [model] (set! (.-selected-block-uuid model) nil) (stdlib/ignore 0))

(defn upsert-journal-page [model uuid day title]
  (let [entity (if (block-exists? model uuid) (block-ref uuid) (ds/Temp_id (str "page-" uuid)))]
    (commit model [(add block-uuid entity uuid) (add page-journal-day entity day) (add page-title entity title)])))

(defn local-block [uuid title page-id parent-id now]
  (record block (uuid uuid) (title title) (page-id page-id) (parent-id parent-id) (order nil)
    (created-at now) (updated-at now) (sync-status "pending") (tags (list)) (references (list))
    (breadcrumbs (list)) (status nil) (is-asset false) (asset-type nil) (asset-size nil)
    (asset-checksum nil) (local-path nil) (journal nil)))

(defn local-journal [model now]
  (let [page-id (journal-page-id-for-ms now)] (upsert-journal-page model page-id (journal-day-for-ms now) "") page-id))

(defn cache-local-message [model uuid title now]
  (upsert-blocks model [(local-block uuid title (local-journal model now) nil now)] now))

(defn cache-local-task [model uuid title status now]
  (upsert-blocks model [(assoc (local-block uuid title (local-journal model now) nil now) :status (Some status))] now))

(defn cache-local-asset [model uuid title asset-type asset-size asset-checksum local-path now target-block-id]
  (let [target (when-some [uuid target-block-id] (read-block model uuid))
        page-id (if-some [target target] (:page-id target) (local-journal model now))
        parent-id (when-some [target target] (:uuid target))]
    (upsert-blocks model [(assoc (local-block uuid title page-id parent-id now)
                                :is-asset true :asset-type (Some asset-type) :asset-size (Some asset-size)
                                :asset-checksum (Some asset-checksum) :local-path (Some local-path))] now)))

(defn cache-local-child [model uuid title parent-id now]
  (if-some [parent (read-block model parent-id)]
    (do (upsert-blocks model [(local-block uuid title (:page-id parent) (Some parent-id) now)] now) (Ok (stdlib/ignore 0)))
    (Error (str "unknown parent block: " parent-id))))

(defn pending-blocks [model]
  (vec (sort compare-recent (filter (fn [block] (contains? #{"pending" "failed"} (:sync-status block))) (all-blocks model)))))

(defn unsynced-blocks [model]
  (vec (sort compare-recent (filter (fn [block] (not= (:sync-status block) "synced")) (all-blocks model)))))

(defn update-sync-status [model uuid sync-status]
  (if (block-exists? model uuid)
    (do (commit model [(add block-sync-status (block-ref uuid) sync-status)]) (Ok (stdlib/ignore 0)))
    (Error (str "unknown block: " uuid))))

(defn mark-block-synced [model uuid] (update-sync-status model uuid "synced"))

(defn mark-block-submitted [model uuid] (update-sync-status model uuid "submitted"))

(defn mark-block-sync-failed [model uuid] (update-sync-status model uuid "failed"))

(defn reconcile-created-block [model local-uuid remote-uuid sync-status]
  (if-some [local (read-block model local-uuid)]
    (if (= local-uuid remote-uuid)
      (update-sync-status model local-uuid sync-status)
      (let [base (or (read-block model remote-uuid) local)
            reconciled (assoc (prefer-local-asset local base) :uuid remote-uuid :sync-status sync-status)]
        (upsert-blocks model [reconciled] (max (:updated-at local) (:updated-at base)))
        (commit model [(ds/RetractEntity (block-ref local-uuid))])
        (Ok (stdlib/ignore 0))))
    (Error (str "unknown block: " local-uuid))))

(defn update-block-title [model uuid title now]
  (if (block-exists? model uuid)
    (let [entity (block-ref uuid)]
      (commit model [(add block-title entity title) (add block-updated-at entity now) (add block-sync-status entity "pending")])
      (Ok (stdlib/ignore 0)))
    (Error (str "unknown block: " uuid))))

(defn update-block-status [model uuid status now]
  (if (block-exists? model uuid)
    (let [entity (block-ref uuid)]
      (commit model [(add block-status-json entity (status-json status)) (add block-updated-at entity now)
                     (add block-sync-status entity "pending")])
      (Ok (stdlib/ignore 0)))
    (Error (str "unknown block: " uuid))))
