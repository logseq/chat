(ns logseq-chat.pending-projection
  (:refer-clojure :exclude [compile])
  (:require [clojure.string :as string]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.outliner :as outliner]
            [logseq-chat.datascript-value :as ds-value]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Datascript.Entity :as entity]
            [ocaml.String :as bytes]
            [ocaml.Float :as float]
            [ocaml.Rrbvec :as rrbvec]))

(type-record
  pending-projection-snapshot
  (db :Datascript.db)
  (server-t :int)
  (statuses :vector<tuple<string;ops/pending-state>>))

(defn lookup [uuid] (ds/Lookup_ref "block/uuid" (ds/Uuid uuid)))

(defn one-value [db reference attr]
  (when-some
    [value (ds/entity db reference)]
    (match (entity/entity-attr-raw value attr) (Some (ds/One_value value)) (Some value) _ nil)))

(defn string-value [value] (match value (Some (ds/String text)) (Some text) _ nil))

(defn bool-value [value] (match value (Some (ds/Bool flag)) (Some flag) _ nil))

(defn has-ref [db eid attr target-eid]
  (boolean
    (some
      (fn [datom] (= (ds-value/ref-eid db attr (:v datom)) (Some target-eid)))
      (db-api/datoms db (ds/Eavt) :e eid :a attr))))

(defn named-page-eid [db name]
  (when-some
    [datom (first (db-api/datoms db (ds/Aevt) :a "block/name" :v (ds/String name)))]
    (:e datom)))

(defn favorite-page-eid [db] (named-page-eid db "$$$favorites"))

(defn recycle-page-eid [db] (named-page-eid db "recycle"))

(defn favorite-block-eid [db page-uuid]
  (when-some
    [favorites-eid (favorite-page-eid db)]
    (when-some
      [page-eid (ds/entid db "block/uuid" (ds/Uuid page-uuid))]
      (some
        (fn [datom] (when (has-ref db (:e datom) "block/link" page-eid) (:e datom)))
        (db-api/datoms db (ds/Aevt) :a "block/page" :v (ds/Ref favorites-eid))))))

(defn datascript-value [value]
  (match
    value
    (ops/String-value value)
    (ds/String value)
    (ops/Int-value value)
    (ds/Int value)
    (ops/Instant-value value)
    (ds/Instant value)
    (ops/Float-value value)
    (ds/Float value)
    (ops/Bool-value value)
    (ds/Bool value)
    (ops/Keyword-value value)
    (ds/Keyword value)
    (ops/Map-value entries)
    (ds/Map
      (rrbvec/to-list
        (mapv (fn [[key value]] (tuple (ds/Keyword key) (datascript-value value))) entries)))
    (ops/Ref-uuid uuid)
    (ds/Ref_to (lookup uuid))
    (ops/Ref-ident ident)
    (ds/Ref_to (ds/Lookup_ref "db/ident" (ds/Keyword ident)))))

(defn semantic-value-equal-value [db left right]
  (match
    (tuple left right)
    (tuple (ds/String value) (ops/String-value expected))
    (= value expected)
    (tuple (ds/Int value) (ops/Int-value expected))
    (= value expected)
    (tuple (ds/Instant value) (ops/Instant-value expected))
    (= value expected)
    (tuple (ds/Float value) (ops/Float-value expected))
    (float/equal value expected)
    (tuple (ds/Int value) (ops/Float-value expected))
    (float/equal (float/of-int value) expected)
    (tuple (ds/Bool value) (ops/Bool-value expected))
    (= value expected)
    (tuple (ds/Keyword value) (ops/Keyword-value expected))
    (= value expected)
    (tuple (ds/Map entries) (ops/Map-value expected))
    (and
      (= (count entries) (count expected))
      (every?
        (fn [[key value]]
          (boolean
            (some
              (fn [[actual-key actual-value]]
                (match
                  actual-key
                  (ds/Keyword actual-key)
                  (and (= actual-key key) (semantic-value-equal-value db actual-value value))
                  _
                  false))
              entries)))
        expected))
    (tuple (ds/Ref eid) (ops/Ref-uuid uuid))
    (= (ds/entid db "block/uuid" (ds/Uuid uuid)) (Some eid))
    (tuple (ds/Int eid) (ops/Ref-uuid uuid))
    (= (ds/entid db "block/uuid" (ds/Uuid uuid)) (Some eid))
    (tuple (ds/Ref eid) (ops/Ref-ident ident))
    (= (ds/entid db "db/ident" (ds/Keyword ident)) (Some eid))
    (tuple (ds/Int eid) (ops/Ref-ident ident))
    (= (ds/entid db "db/ident" (ds/Keyword ident)) (Some eid))
    _
    false))

(defn semantic-value-equal [db left right]
  (match
    (tuple left right)
    (tuple None None)
    true
    (tuple (Some value) (Some expected))
    (semantic-value-equal-value db value expected)
    _
    false))

(defn delimited-names [title opener]
  (loop [offset 0 names []]
    (let [opening (string/index-of title opener offset)]
      (if (neg? opening)
        names
        (let [start (+ opening (count opener)) end (string/index-of title "]]" start)]
          (if (neg? end)
            names
            (let [name (string/trim (subs title start end))]
              (recur (+ end 2) (if (= name "") names (conj names name))))))))))

(defn page-names [title] (delimited-names title "[["))

(defn inline-tag-names [title] (delimited-names title "#[["))

(defn eid-for-node [db value]
  (or (ds/entid db "block/uuid" (ds/Uuid value))
      (named-page-eid db (bytes/lowercase-ascii value))))

(defn refs-for-title [db title]
  (vec (sort (distinct (keep (fn [name] (eid-for-node db name)) (page-names title))))))

(defn tag-eids-for-title [db title]
  (if-some
    [tag-class-eid (ds/entid db "db/ident" (ds/Keyword "logseq.class/Tag"))]
    (vec
      (sort
        (distinct
          (filter
            (fn [eid] (has-ref db eid "block/tags" tag-class-eid))
            (keep (fn [name] (eid-for-node db name)) (inline-tag-names title))))))
    []))

(defn title-tx [db uuid title]
  (let [reference (lookup uuid)
        retractions (if-some
                      [eid (ds/entid db "block/uuid" (ds/Uuid uuid))]
                      (into
                        (mapv
                          (fn [datom] (ds/Retract reference "block/refs" (Some (:v datom))))
                          (db-api/datoms db (ds/Eavt) :e eid :a "block/refs"))
                        (map
                          (fn [eid] (ds/Retract reference "block/tags" (Some (ds/Ref eid))))
                          (tag-eids-for-title
                            db
                            (or (string-value (one-value db reference "block/title")) ""))))
                      [])]
    (vec
      (concat
        [(ds/Add reference "block/title" (ds/String title))]
        retractions
        (map (fn [eid] (ds/Add reference "block/refs" (ds/Ref eid))) (refs-for-title db title))
        (map
          (fn [eid] (ds/Add reference "block/tags" (ds/Ref eid)))
          (tag-eids-for-title db title))))))

(defn uuid-for-eid [db eid]
  (match (one-value db (ds/Entity_id eid) "block/uuid") (Some (ds/Uuid uuid)) (Some uuid) _ nil))

(defn journal-page-eid [db day]
  (some
    (fn [datom] (match (:v datom) (ds/Int value) (when (= value day) (:e datom)) _ nil))
    (db-api/datoms db (ds/Aevt) :a "block/journal-day")))

(defn outliner-block [db uuid]
  (let [reference (lookup uuid)]
    (when-some
      [title (string-value (one-value db reference "block/title"))]
      (when-some
        [page-eid
         (ds-value/optional-ref-eid db "block/page" (one-value db reference "block/page"))]
        (when-some
          [parent-eid
           (ds-value/optional-ref-eid db "block/parent" (one-value db reference "block/parent"))]
          (when-some
            [order (string-value (one-value db reference "block/order"))]
            (when-some
              [page-uuid (uuid-for-eid db page-eid)]
              (when-some
                [parent-uuid (uuid-for-eid db parent-eid)]
                (record
                  outliner/outliner-block
                  (uuid uuid)
                  (title title)
                  (page-uuid page-uuid)
                  (parent-uuid parent-uuid)
                  (order order))))))))))

(defn entity-tx [reference attrs]
  (ds/Entity
    (record Datascript.tx_entity (db-id (Some reference)) (attrs (rrbvec/to-list (vec attrs))))))

(defn many-refs [attr eids]
  (if (empty? eids)
    []
    [(tuple
       attr
       (ds/Many_values (rrbvec/to-list (mapv (fn [eid] (ds/Ref_to (ds/Entity_id eid))) eids))))]))

(defn insert-tx [db block created-at]
  [(entity-tx
     (ds/Temp_id (str "pending/" (:uuid block)))
     (concat
       [(tuple "block/uuid" (ds/One_value (ds/Uuid (:uuid block))))
        (tuple "block/title" (ds/One_value (ds/String (:title block))))
        (tuple "block/page" (ds/One_value (ds/Ref_to (lookup (:page-uuid block)))))
        (tuple "block/parent" (ds/One_value (ds/Ref_to (lookup (:parent-uuid block)))))
        (tuple "block/order" (ds/One_value (ds/String (:order block))))
        (tuple "block/created-at" (ds/One_value (ds/Int created-at)))
        (tuple "block/updated-at" (ds/One_value (ds/Int created-at)))]
       (many-refs "block/refs" (refs-for-title db (:title block)))
       (many-refs "block/tags" (tag-eids-for-title db (:title block)))))])

(defn outliner-mutation-tx [db mutation]
  (match
    mutation
    (outliner/Set_title value)
    (title-tx db (:uuid value) (:title value))
    (outliner/Insert value)
    (insert-tx db (:insert-block value) (:created-at value))
    (outliner/Reparent value)
    [(ds/Add (lookup (:uuid value)) "block/page" (ds/Ref_to (lookup (:page-uuid value))))
     (ds/Add (lookup (:uuid value)) "block/parent" (ds/Ref_to (lookup (:parent-uuid value))))]
    (outliner/Delete value)
    (if-some
      [eid (ds/entid db "block/uuid" (ds/Uuid (:uuid value)))]
      [(ds/RetractEntity (ds/Entity_id eid))]
      [])))

(defn compile-outliner [db command]
  (let [find-block (fn [uuid] (outliner-block db uuid))
        children (fn [uuid]
                   (rrbvec/to-list
                     (if-some
                       [eid (ds/entid db "block/uuid" (ds/Uuid uuid))]
                       (vec
                         (keep
                           find-block
                           (keep
                             (fn [datom] (uuid-for-eid db (:e datom)))
                             (ds-value/datoms-by-ref db (ds/Aevt) "block/parent" eid))))
                       [])))]
    (let*
      [mutations (outliner/plan find-block children command)]
      (Ok (vec (mapcat (fn [mutation] (outliner-mutation-tx db mutation)) mutations))))))

(defn children [db eid] (mapv :e (ds-value/datoms-by-ref db (ds/Aevt) "block/parent" eid)))

(defn subtree [db roots]
  (loop [pending (vec (reverse roots)) seen #{} result []]
    (if (empty? pending)
      result
      (let [eid (nth pending (dec (count pending))) pending (pop pending)]
        (if (contains? seen eid)
          (recur pending seen result)
          (recur (into pending (reverse (children db eid))) (conj seen eid) (conj result eid)))))))

(defn page-entity [db eid]
  (or
    (not (empty? (db-api/datoms db (ds/Eavt) :e eid :a "block/name")))
    (not (empty? (db-api/datoms db (ds/Eavt) :e eid :a "block/journal-day")))))

(defn would-create-cycle [db moving-eid parent-eid]
  (boolean (some (fn [eid] (= eid parent-eid)) (subtree db [moving-eid]))))

(defn property-tx [uuid attr value]
  (if-some [value value]
    (ds/Add (lookup uuid) attr (datascript-value value))
    (ds/RetractAttr (lookup uuid) attr)))

(defn create-attrs [uuid title created-at]
  [(tuple "block/uuid" (ds/One_value (ds/Uuid uuid)))
   (tuple "block/name" (ds/One_value (ds/String (bytes/lowercase-ascii title))))
   (tuple "block/title" (ds/One_value (ds/String title)))
   (tuple "block/created-at" (ds/One_value (ds/Int created-at)))
   (tuple "block/updated-at" (ds/One_value (ds/Int created-at)))])

(defn compile [db intent]
  (match
    intent
    (ops/Save-title value)
    (match
      (string-value (one-value db (lookup (:uuid value)) "block/title"))
      (Some current)
      (if (= current (:expected-title value))
        (Ok (title-tx db (:uuid value) (:title value)))
        (Error "title changed on the server"))
      None
      (Error "block no longer exists"))
    (ops/Set-property value)
    (cond
      (nil? (ds/entid db "block/uuid" (ds/Uuid (:uuid value)))) (Error "block no longer exists")
      (not
        (semantic-value-equal
          db
          (one-value db (lookup (:uuid value)) (:attr value))
          (:expected value))) (Error "property changed on the server")
      :else (Ok [(property-tx (:uuid value) (:attr value) (:value value))]))
    (ops/Set-properties value)
    (cond
      (empty? (:changes value)) (Error "property changes cannot be empty")
      (nil? (ds/entid db "block/uuid" (ds/Uuid (:uuid value)))) (Error "block no longer exists")
      (not
        (every?
          (fn [change]
            (semantic-value-equal
              db
              (one-value db (lookup (:uuid value)) (:attr change))
              (:expected change)))
          (:changes value))) (Error "property changed on the server")
      :else (Ok
              (mapv
                (fn [change] (property-tx (:uuid value) (:attr change) (:value change)))
                (:changes value))))
    (ops/Insert-block value)
    (cond
      (some? (ds/entid db "block/uuid" (ds/Uuid (:uuid value)))) (Error
                                                                   "inserted block UUID already exists")
      (or
        (nil? (ds/entid db "block/uuid" (ds/Uuid (:page-uuid value))))
        (nil? (ds/entid db "block/uuid" (ds/Uuid (:parent-uuid value))))) (Error
                                                                            "insert parent or page no longer exists")
      :else (Ok
              (insert-tx
                db
                (record
                  outliner/outliner-block
                  (uuid (:uuid value))
                  (title (:title value))
                  (page-uuid (:page-uuid value))
                  (parent-uuid (:parent-uuid value))
                  (order (:order value)))
                (:created-at value))))
    (ops/Create-asset value)
    (cond
      (some? (ds/entid db "block/uuid" (ds/Uuid (:uuid value)))) (Error
                                                                   "asset block UUID already exists")
      (or
        (nil? (ds/entid db "block/uuid" (ds/Uuid (:page-uuid value))))
        (nil? (ds/entid db "block/uuid" (ds/Uuid (:parent-uuid value))))) (Error
                                                                            "asset parent or page no longer exists")
      (nil? (ds/entid db "db/ident" (ds/Keyword "logseq.class/Asset"))) (Error
                                                                          "the graph does not define logseq.class/Asset")
      :else (Ok
              [(entity-tx
                 (ds/Temp_id (str "pending/" (:uuid value)))
                 [(tuple "block/uuid" (ds/One_value (ds/Uuid (:uuid value))))
                  (tuple "block/title" (ds/One_value (ds/String (:title value))))
                  (tuple "block/page" (ds/One_value (ds/Ref_to (lookup (:page-uuid value)))))
                  (tuple "block/parent" (ds/One_value (ds/Ref_to (lookup (:parent-uuid value)))))
                  (tuple "block/order" (ds/One_value (ds/String (:order value))))
                  (tuple
                    "block/tags"
                    (ds/Many_values
                      (list
                        (ds/Ref_to (ds/Lookup_ref "db/ident" (ds/Keyword "logseq.class/Asset"))))))
                  (tuple "block/created-at" (ds/One_value (ds/Int (:created-at value))))
                  (tuple "block/updated-at" (ds/One_value (ds/Int (:created-at value))))
                  (tuple
                    "logseq.property.asset/type"
                    (ds/One_value (ds/String (:asset-type value))))
                  (tuple "logseq.property.asset/size" (ds/One_value (ds/Int (:asset-size value))))
                  (tuple
                    "logseq.property.asset/checksum"
                    (ds/One_value (ds/String (:asset-checksum value))))
                  (tuple
                    "logseq.property.asset/remote-metadata"
                    (ds/One_value
                      (ds/Map
                        (list
                          (tuple (ds/Keyword "checksum") (ds/String (:asset-checksum value)))
                          (tuple (ds/Keyword "type") (ds/String (:asset-type value)))))))])]))
    (ops/Move-block value)
    (match
      (tuple
        (ds/entid db "block/uuid" (ds/Uuid (:uuid value)))
        (ds/entid db "block/uuid" (ds/Uuid (:page-uuid value)))
        (ds/entid db "block/uuid" (ds/Uuid (:parent-uuid value))))
      (tuple (Some moving-eid) (Some _) (Some parent-eid))
      (if (would-create-cycle db moving-eid parent-eid)
        (Error "move would create an outliner cycle")
        (Ok
          [(ds/Add (lookup (:uuid value)) "block/page" (ds/Ref_to (lookup (:page-uuid value))))
           (ds/Add (lookup (:uuid value)) "block/parent" (ds/Ref_to (lookup (:parent-uuid value))))
           (ds/Add (lookup (:uuid value)) "block/order" (ds/String (:order value)))]))
      _
      (Error "move target no longer exists"))
    (ops/Move-blocks value)
    (if (empty? (:moves value))
      (Error "move batch must not be empty")
      (loop [index 0 projected db tx []]
        (if (= index (count (:moves value)))
          (Ok tx)
          (let*
            [step (compile projected (ops/Move-block (nth (:moves value) index)))]
            (recur (inc index) (ds/db-with (rrbvec/to-list step) projected) (into tx step))))))
    (ops/Split-block value)
    (compile-outliner
      db
      (outliner/Split
        (record
          outliner/split-command
          (source-uuid (:uuid value))
          (expected-title (:expected-title value))
          (before (:before value))
          (after (:after value))
          (new-uuid (:new-uuid value))
          (new-order (:new-order value))
          (created-at (:created-at value)))))
    (ops/Merge-backward value)
    (compile-outliner
      db
      (outliner/Merge_backward
        (record
          outliner/merge-backward-command
          (source-uuid (:uuid value))
          (expected-source-title (:expected-title value))
          (source-title (:title value))
          (previous-uuid (:previous-uuid value))
          (expected-previous-title (:expected-previous-title value))
          (merged-title (:merged-title value)))))
    (ops/Delete-blocks value)
    (let [roots (vec (keep (fn [uuid] (ds/entid db "block/uuid" (ds/Uuid uuid))) (:uuids value)))]
      (cond
        (empty? roots) (Error "block no longer exists")
        (some (fn [eid] (page-entity db eid)) roots) (Error
                                                       "ordinary block delete cannot delete a page")
        :else (Ok (mapv (fn [eid] (ds/RetractEntity (ds/Entity_id eid))) (subtree db roots)))))
    (ops/Create-page value)
    (if (some? (ds/entid db "block/uuid" (ds/Uuid (:uuid value))))
      (Ok [])
      (Ok
        [(entity-tx
           (ds/Temp_id (str "pending/" (:uuid value)))
           (create-attrs (:uuid value) (:title value) (:created-at value)))]))
    (ops/Create-tag value)
    (cond
      (some? (ds/entid db "block/uuid" (ds/Uuid (:uuid value)))) (Ok [])
      (nil? (ds/entid db "db/ident" (ds/Keyword "logseq.class/Tag"))) (Error
                                                                        "the graph does not define logseq.class/Tag")
      (nil? (ds/entid db "db/ident" (ds/Keyword "logseq.class/Root"))) (Error
                                                                         "the graph does not define logseq.class/Root")
      :else (Ok
              [(entity-tx
                 (ds/Temp_id (str "pending/" (:uuid value)))
                 [(tuple "block/uuid" (ds/One_value (ds/Uuid (:uuid value))))
                  (tuple
                    "db/ident"
                    (ds/One_value (ds/Keyword (str "user.class/tag-" (:uuid value)))))
                  (tuple
                    "block/name"
                    (ds/One_value (ds/String (bytes/lowercase-ascii (:title value)))))
                  (tuple "block/title" (ds/One_value (ds/String (:title value))))
                  (tuple
                    "block/tags"
                    (ds/Many_values
                      (list
                        (ds/Ref_to (ds/Lookup_ref "db/ident" (ds/Keyword "logseq.class/Tag"))))))
                  (tuple
                    "logseq.property.class/extends"
                    (ds/Many_values
                      (list
                        (ds/Ref_to (ds/Lookup_ref "db/ident" (ds/Keyword "logseq.class/Root"))))))
                  (tuple "block/created-at" (ds/One_value (ds/Int (:created-at value))))
                  (tuple "block/updated-at" (ds/One_value (ds/Int (:created-at value))))])]))
    (ops/Create-journal value)
    (let [existing-page (journal-page-eid db (:journal-day value))
          [page-ref page-tx] (if-some
                               [eid existing-page]
                               (tuple (ds/Entity_id eid) [])
                               (let [reference (ds/Temp_id (str "pending/" (:page-uuid value)))
                                     attrs [(tuple
                                              "block/uuid"
                                              (ds/One_value (ds/Uuid (:page-uuid value))))
                                            (tuple
                                              "block/name"
                                              (ds/One_value
                                                (ds/String
                                                  (bytes/lowercase-ascii (:title value)))))
                                            (tuple
                                              "block/title"
                                              (ds/One_value (ds/String (:title value))))
                                            (tuple
                                              "block/journal-day"
                                              (ds/One_value (ds/Int (:journal-day value))))
                                            (tuple
                                              "block/created-at"
                                              (ds/One_value (ds/Int (:created-at value))))
                                            (tuple
                                              "block/updated-at"
                                              (ds/One_value (ds/Int (:created-at value))))]
                                     attrs (if (some?
                                                 (ds/entid
                                                   db
                                                   "db/ident"
                                                   (ds/Keyword "logseq.class/Journal")))
                                             (conj
                                               attrs
                                               (tuple
                                                 "block/tags"
                                                 (ds/Many_values
                                                   (list
                                                     (ds/Ref_to
                                                       (ds/Lookup_ref
                                                         "db/ident"
                                                         (ds/Keyword "logseq.class/Journal")))))))
                                             attrs)]
                                 (tuple reference [(entity-tx reference attrs)])))]
      (if-some
        [block-eid (ds/entid db "block/uuid" (ds/Uuid (:block-uuid value)))]
        (let [belongs (fn [attr]
                        (match
                          (tuple existing-page (one-value db (ds/Entity_id block-eid) attr))
                          (tuple (Some page-eid) (Some value))
                          (= (ds-value/ref-eid db attr value) (Some page-eid))
                          _
                          false))]
          (if (and (belongs "block/page") (belongs "block/parent"))
            (Ok page-tx)
            (Error "journal block UUID already exists outside the journal")))
        (Ok
          (conj
            page-tx
            (entity-tx
              (ds/Temp_id (str "pending/" (:block-uuid value)))
              [(tuple "block/uuid" (ds/One_value (ds/Uuid (:block-uuid value))))
               (tuple "block/title" (ds/One_value (ds/String "")))
               (tuple "block/page" (ds/One_value (ds/Ref_to page-ref)))
               (tuple "block/parent" (ds/One_value (ds/Ref_to page-ref)))
               (tuple "block/order" (ds/One_value (ds/String "a0")))
               (tuple "block/created-at" (ds/One_value (ds/Int (:created-at value))))
               (tuple "block/updated-at" (ds/One_value (ds/Int (:created-at value))))])))))
    (ops/Add-tag value)
    (match
      (tuple
        (ds/entid db "block/uuid" (ds/Uuid (:uuid value)))
        (ds/entid db "block/uuid" (ds/Uuid (:tag-uuid value))))
      (tuple (Some block-eid) (Some tag-eid))
      (Ok
        (if (has-ref db block-eid "block/tags" tag-eid)
          []
          [(ds/Add (lookup (:uuid value)) "block/tags" (ds/Ref tag-eid))]))
      (tuple None _)
      (Error "block no longer exists")
      _
      (Error "tag no longer exists"))
    (ops/Set-favorite value)
    (match
      (tuple (favorite-page-eid db) (ds/entid db "block/uuid" (ds/Uuid (:page-uuid value))))
      (tuple None _)
      (Error "favorites page is missing")
      (tuple _ None)
      (Error "page no longer exists")
      (tuple (Some favorites-eid) (Some page-eid))
      (match
        (tuple (:favorite value) (favorite-block-eid db (:page-uuid value)))
        (tuple true (Some _))
        (Ok [])
        (tuple false None)
        (Ok [])
        (tuple false (Some favorite-eid))
        (Ok [(ds/RetractEntity (ds/Entity_id favorite-eid))])
        (tuple true None)
        (if (some? (ds/entid db "block/uuid" (ds/Uuid (:favorite-uuid value))))
          (Error "favorite block UUID already exists")
          (Ok
            [(entity-tx
               (ds/Temp_id (str "pending/" (:favorite-uuid value)))
               [(tuple "block/uuid" (ds/One_value (ds/Uuid (:favorite-uuid value))))
                (tuple "block/title" (ds/One_value (ds/String "")))
                (tuple "block/page" (ds/One_value (ds/Ref favorites-eid)))
                (tuple "block/parent" (ds/One_value (ds/Ref favorites-eid)))
                (tuple "block/link" (ds/One_value (ds/Ref page-eid)))
                (tuple "block/order" (ds/One_value (ds/String (:order value))))
                (tuple "block/created-at" (ds/One_value (ds/Int (:created-at value))))
                (tuple "block/updated-at" (ds/One_value (ds/Int (:created-at value))))])]))))
    (ops/Delete-page value)
    (match
      (tuple (ds/entid db "block/uuid" (ds/Uuid (:page-uuid value))) (recycle-page-eid db))
      (tuple None _)
      (Error "page no longer exists")
      (tuple _ None)
      (Error "Recycle page is missing")
      (tuple (Some page-eid) (Some recycle-eid))
      (let [reference (ds/Entity_id page-eid)]
        (cond
          (and
            (some? (one-value db reference "logseq.property/deleted-at"))
            (=
              (ds-value/optional-ref-eid db "block/parent" (one-value db reference "block/parent"))
              (Some recycle-eid))) (Ok [])
          (or
            (= (bool-value (one-value db reference "logseq.property/built-in?")) (Some true))
            (= (bool-value (one-value db reference "logseq.property/hide?")) (Some true))) (Error
                                                                                             "Built-in page cannot be deleted")
          :else (let [parent (match
                               (one-value db reference "block/parent")
                               (Some (ds/Ref eid))
                               [(tuple
                                  "logseq.property.recycle/original-parent"
                                  (ds/One_value (ds/Ref eid)))]
                               (Some (ds/Int eid))
                               [(tuple
                                  "logseq.property.recycle/original-parent"
                                  (ds/One_value (ds/Ref eid)))]
                               _
                               [])
                      order (match
                              (one-value db reference "block/order")
                              (Some (ds/String order))
                              [(tuple
                                 "logseq.property.recycle/original-order"
                                 (ds/One_value (ds/String order)))]
                              _
                              [])]
                  (Ok
                    [(entity-tx
                       (lookup (:page-uuid value))
                       (concat
                         [(tuple "block/parent" (ds/One_value (ds/Ref recycle-eid)))
                          (tuple "block/order" (ds/One_value (ds/String (:order value))))
                          (tuple
                            "logseq.property/deleted-at"
                            (ds/One_value (ds/Instant (:deleted-at value))))
                          (tuple
                            "logseq.property.recycle/original-page"
                            (ds/One_value (ds/Ref page-eid)))]
                         parent
                         order))])))))))

(defn block-location-matches [db uuid page-uuid parent-uuid order]
  (and
    (some? (ds/entid db "block/uuid" (ds/Uuid uuid)))
    (semantic-value-equal
      db
      (one-value db (lookup uuid) "block/page")
      (Some (ops/Ref-uuid page-uuid)))
    (semantic-value-equal
      db
      (one-value db (lookup uuid) "block/parent")
      (Some (ops/Ref-uuid parent-uuid)))
    (= (string-value (one-value db (lookup uuid) "block/order")) (Some order))))

(defn satisfied [db intent]
  (match
    intent
    (ops/Save-title value)
    (= (string-value (one-value db (lookup (:uuid value)) "block/title")) (Some (:title value)))
    (ops/Set-property value)
    (semantic-value-equal db (one-value db (lookup (:uuid value)) (:attr value)) (:value value))
    (ops/Set-properties value)
    (and
      (not (empty? (:changes value)))
      (every?
        (fn [change]
          (semantic-value-equal
            db
            (one-value db (lookup (:uuid value)) (:attr change))
            (:value change)))
        (:changes value)))
    (ops/Insert-block value)
    (and
      (block-location-matches
        db
        (:uuid value)
        (:page-uuid value)
        (:parent-uuid value)
        (:order value))
      (= (string-value (one-value db (lookup (:uuid value)) "block/title")) (Some (:title value))))
    (ops/Create-asset value)
    (let [reference (lookup (:uuid value))]
      (and
        (block-location-matches
          db
          (:uuid value)
          (:page-uuid value)
          (:parent-uuid value)
          (:order value))
        (= (string-value (one-value db reference "block/title")) (Some (:title value)))
        (=
          (string-value (one-value db reference "logseq.property.asset/type"))
          (Some (:asset-type value)))
        (=
          (one-value db reference "logseq.property.asset/size")
          (Some (ds/Int (:asset-size value))))
        (=
          (string-value (one-value db reference "logseq.property.asset/checksum"))
          (Some (:asset-checksum value)))
        (semantic-value-equal
          db
          (one-value db reference "logseq.property.asset/remote-metadata")
          (Some
            (ops/Map-value
              [(tuple "checksum" (ops/String-value (:asset-checksum value)))
               (tuple "type" (ops/String-value (:asset-type value)))])))))
    (ops/Move-block value)
    (block-location-matches
      db
      (:uuid value)
      (:page-uuid value)
      (:parent-uuid value)
      (:order value))
    (ops/Move-blocks value)
    (and
      (not (empty? (:moves value)))
      (every? (fn [move] (satisfied db (ops/Move-block move))) (:moves value)))
    (ops/Split-block value)
    (and
      (= (string-value (one-value db (lookup (:uuid value)) "block/title")) (Some (:before value)))
      (=
        (string-value (one-value db (lookup (:new-uuid value)) "block/title"))
        (Some (:after value)))
      (=
        (string-value (one-value db (lookup (:new-uuid value)) "block/order"))
        (Some (:new-order value))))
    (ops/Merge-backward value)
    (and
      (nil? (ds/entid db "block/uuid" (ds/Uuid (:uuid value))))
      (=
        (string-value (one-value db (lookup (:previous-uuid value)) "block/title"))
        (Some (or (:merged-title value) (str (:expected-previous-title value) (:title value))))))
    (ops/Delete-blocks value)
    (every? (fn [uuid] (nil? (ds/entid db "block/uuid" (ds/Uuid uuid)))) (:uuids value))
    (ops/Create-tag value)
    (some? (ds/entid db "block/uuid" (ds/Uuid (:uuid value))))
    (ops/Create-page value)
    (some? (ds/entid db "block/uuid" (ds/Uuid (:uuid value))))
    (ops/Create-journal value)
    (match
      (tuple
        (journal-page-eid db (:journal-day value))
        (ds/entid db "block/uuid" (ds/Uuid (:block-uuid value))))
      (tuple (Some page-eid) (Some block-eid))
      (every?
        (fn [attr]
          (=
            (ds-value/optional-ref-eid db attr (one-value db (ds/Entity_id block-eid) attr))
            (Some page-eid)))
        ["block/page" "block/parent"])
      _
      false)
    (ops/Add-tag value)
    (match
      (tuple
        (ds/entid db "block/uuid" (ds/Uuid (:uuid value)))
        (ds/entid db "block/uuid" (ds/Uuid (:tag-uuid value))))
      (tuple (Some block-eid) (Some tag-eid))
      (has-ref db block-eid "block/tags" tag-eid)
      _
      false)
    (ops/Set-favorite value)
    (= (some? (favorite-block-eid db (:page-uuid value))) (:favorite value))
    (ops/Delete-page value)
    (match
      (tuple (ds/entid db "block/uuid" (ds/Uuid (:page-uuid value))) (recycle-page-eid db))
      (tuple (Some page-eid) (Some recycle-eid))
      (and
        (some? (one-value db (ds/Entity_id page-eid) "logseq.property/deleted-at"))
        (=
          (ds-value/optional-ref-eid
            db
            "block/parent"
            (one-value db (ds/Entity_id page-eid) "block/parent"))
          (Some recycle-eid)))
      _
      false)))

(defn build [server-t authoritative operations]
  (reduce
    (fn [snapshot operation]
      (let [[db state] (match
                         (:state operation)
                         (ops/Conflicted message)
                         (tuple (:db snapshot) (ops/Conflicted message))
                         _
                         (match
                           (compile (:db snapshot) (:intent operation))
                           (Ok tx)
                           (tuple (ds/db-with (rrbvec/to-list tx) (:db snapshot)) (ops/Applied))
                           (Error message)
                           (tuple (:db snapshot) (ops/Conflicted message))))]
        (assoc
          snapshot
          :db
          db
          :statuses
          (conj (:statuses snapshot) (tuple (:operation-id operation) state)))))
    (record pending-projection-snapshot (db authoritative) (server-t server-t) (statuses []))
    operations))
