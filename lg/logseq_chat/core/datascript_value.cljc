(ns logseq-chat.datascript-value
  (:require [ocaml.package/datascript-ocaml-native]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Datascript.Schema :as schema]
            [ocaml.Hashtbl :as hashtbl]))

(defn built-in-ref-attr? [attr]
  (or (= attr "block/parent")
      (= attr "block/page")
      (= attr "block/refs")
      (= attr "block/tags")
      (= attr "block/link")
      (= attr "block/alias")
      (= attr "block/closed-value-property")))

(defn value-type-is-ref [db value]
  (match value
    (ds/Keyword "db.type/ref") true
    (ds/Ref eid)
    (some
     (fn [datom]
       (= (:v datom) (ds/Keyword "db.type/ref")))
     (db-api/datoms db (ds/Eavt) :e eid :a "db/ident"))
    (ds/Int eid)
    (some
     (fn [datom]
       (= (:v datom) (ds/Keyword "db.type/ref")))
     (db-api/datoms db (ds/Eavt) :e eid :a "db/ident"))
    _ false))

(defn entity-declares-ref [db attr]
  (match (ds/entid db "db/ident" (ds/Keyword attr))
    (Some eid)
    (some
     (fn [datom]
       (value-type-is-ref db (:v datom)))
     (db-api/datoms db (ds/Eavt) :e eid :a "db/valueType"))
    None false))

(defn is-ref-attr [db attr]
  (or (built-in-ref-attr? attr)
      (schema/schema_attr_is_ref (:schema db) attr)
      (entity-declares-ref db attr)))

(defn ref-eid [db attr value]
  (match value
    (ds/Ref eid) (Some eid)
    (ds/Int eid) (if (is-ref-attr db attr) (Some eid) None)
    _ None))

(defn optional-ref-eid [db attr value]
  (match value
    (Some value) (ref-eid db attr value)
    None None))

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
