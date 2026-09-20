(ns logseq-chat.datascript-value
  (:require [ocaml.package/datascript-ocaml-native]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Datascript.Schema :as schema]
            [ocaml.Hashtbl :as hashtbl]))

(def built-in-ref-attrs
  #{"block/parent" "block/page" "block/refs" "block/tags"
    "block/link" "block/alias" "block/closed-value-property"})

(defn built-in-ref-attr? [attr]
  (contains? built-in-ref-attrs attr))

(defn value-type-is-ref [db value]
  (match value
    (ds/Keyword "db.type/ref") true
    (or (ds/Ref eid) (ds/Int eid))
    (some
     (fn [datom]
       (= (:v datom) (ds/Keyword "db.type/ref")))
     (db-api/datoms db (ds/Eavt) :e eid :a "db/ident"))
    _ false))

(defn entity-declares-ref [db attr]
  (if-some [eid (ds/entid db "db/ident" (ds/Keyword attr))]
    (some
     (fn [datom]
       (value-type-is-ref db (:v datom)))
     (db-api/datoms db (ds/Eavt) :e eid :a "db/valueType"))
    false))

(defn is-ref-attr [db attr]
  (or (built-in-ref-attr? attr)
      (schema/schema_attr_is_ref (:schema db) attr)
      (entity-declares-ref db attr)))

(defn ref-eid [db attr value]
  (match value
    (ds/Ref eid) (Some eid)
    (ds/Int eid) (when (is-ref-attr db attr) eid)
    _ nil))

(defn optional-ref-eid [db attr value]
  (when-some [value value] (ref-eid db attr value)))

(defn datoms-by-ref [db index attr eid]
  (let [seen-entities (hashtbl/create 8)
        candidates
        (concat
         (db-api/datoms db index :a attr :v (ds/Ref eid))
         (db-api/datoms db index :a attr :v (ds/Int eid)))]
    (filter
     (fn [datom]
       (and (= (ref-eid db attr (:v datom)) (Some eid))
            (not (hashtbl/mem seen-entities (:e datom)))
            (do
              (hashtbl/add seen-entities (:e datom) (run! (fn [_] nil) []))
              true)))
     candidates)))
