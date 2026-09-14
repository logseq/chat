(ns logseq-chat.datascript-value
  (:require [ocaml.package/datascript-ocaml-native]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Datascript.Schema :as schema]
            [ocaml.Hashtbl :as hashtbl]
            [ocaml.Seq :as seq]))

(defn built-in-ref-attr? [attr]
  (or (= attr "block/parent")
      (= attr "block/page")
      (= attr "block/refs")
      (= attr "block/tags")
      (= attr "block/link")
      (= attr "block/alias")
      (= attr "block/closed-value-property")))

(defn value-type-is-ref [^:Datascript.db db ^:Datascript.value value]
  (match value
    (ds/Keyword "db.type/ref") true
    (ds/Ref eid)
     (seq/exists
     (fn [^:Datascript.datom datom] (= (:v datom) (ds/Keyword "db.type/ref")))
     (db-api/datoms db (ds/Eavt) :e eid :a "db/ident" (run! (fn [_] nil) [])))
    (ds/Int eid)
    (seq/exists
     (fn [^:Datascript.datom datom] (= (:v datom) (ds/Keyword "db.type/ref")))
     (db-api/datoms db (ds/Eavt) :e eid :a "db/ident" (run! (fn [_] nil) [])))
    _ false))

(defn entity-declares-ref [^:Datascript.db db attr]
  (match (ds/entid db "db/ident" (ds/Keyword attr))
    (Some eid)
    (seq/exists
     (fn [^:Datascript.datom datom] (value-type-is-ref db (:v datom)))
     (db-api/datoms db (ds/Eavt) :e eid :a "db/valueType" (run! (fn [_] nil) [])))
    None false))

(defn is-ref-attr [^:Datascript.db db attr]
  (or (built-in-ref-attr? attr)
      (schema/schema_attr_is_ref (:schema db) attr)
      (entity-declares-ref db attr)))

(defn ref-eid [^:Datascript.db db attr ^:Datascript.value value]
  (match value
    (ds/Ref eid) (Some eid)
    (ds/Int eid) (if (is-ref-attr db attr) (Some eid) None)
    _ None))

(defn optional-ref-eid [^:Datascript.db db attr value]
  (match value
    (Some value) (ref-eid db attr value)
    None None))

(defn datoms-by-ref [^:Datascript.db db ^:Datascript.index index attr eid]
  (let [seen-entities (hashtbl/create 8)
        candidates
        (seq/append
         (db-api/datoms db index :a attr :v (ds/Ref eid) (run! (fn [_] nil) []))
         (db-api/datoms db index :a attr :v (ds/Int eid) (run! (fn [_] nil) [])))]
    (seq/filter
     (fn [^:Datascript.datom datom]
       (and (= (ref-eid db attr (:v datom)) (Some eid))
            (not (hashtbl/mem seen-entities (:e datom)))
            (do
              (hashtbl/add seen-entities (:e datom) (run! (fn [_] nil) []))
              true)))
     candidates)))
