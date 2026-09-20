(ns logseq-chat.sync-tx
  (:require [ocaml.package/datascript-ocaml-native]
            [ocaml.package/melange-transit-core]
            [ocaml.package/melange-transit-native]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Entity :as entity-api]
            [ocaml.Int64 :as int64]
            [ocaml.List :as list]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.Transit_core.Json :as transit]
            [ocaml.Transit_native.Transit.Json :as codec]))

(def ^:vector<Datascript.value> empty-value-vector [])

(def ^:vector<Datascript.tx_entity> empty-entity-vector [])

(def ^:vector<tuple<string;Datascript.tx_value>> empty-entity-attrs-vector [])

(def ^:vector<Transit_core.Json.value> empty-transit-vector [])

(defn lookup-value [entity attr]
  (match (entity-api/entity_attr_raw entity attr)
    (Some (ds/One_value scalar)) (Some scalar)
    _ None))

(defn stable-entity-ref [db eid]
  (match (ds/entity db (ds/Entity_id eid))
    (Some entity)
    (match (tuple (lookup-value entity "block/uuid")
                  (lookup-value entity "db/ident"))
      (tuple (Some (ds/Uuid uuid)) _) (ds/Lookup_ref "block/uuid" (ds/Uuid uuid))
      (tuple _ (Some (ds/Keyword ident))) (ds/Lookup_ref "db/ident" (ds/Keyword ident))
      _ (ds/Entity_id eid))
    None (ds/Entity_id eid)))

(declare transit-of-value)

(defn transit-of-entity-ref [db entity-ref]
  (match entity-ref
    (ds/Entity_id eid)
    (match (stable-entity-ref db eid)
      (ds/Entity_id stable-eid) (transit/Int stable-eid)
      stable-ref (transit-of-entity-ref db stable-ref))
    (ds/Temp_id temp-id) (transit/String temp-id)
    (ds/CurrentTx) (transit/Keyword "db/current-tx")
    (ds/Ident ident) (transit/Keyword ident)
    (ds/Lookup_ref attr value)
    (transit/Array (list (transit/Keyword attr) (transit-of-value db value)))))

(defn ^:Transit_core.Json.value transit-of-value [db value]
  (match value
    (ds/Nil) (transit/Null)
    (ds/Int number) (transit/Int number)
    (ds/Float number) (transit/Float number)
    (ds/String text) (transit/String text)
    (ds/Symbol symbol) (transit/Symbol symbol)
    (ds/Bool flag) (transit/Bool flag)
    (ds/Keyword keyword) (transit/Keyword keyword)
    (ds/Uuid uuid) (transit/Uuid uuid)
    (ds/Instant instant) (transit/Date (int64/of-int instant))
    (ds/Regex pattern) (transit/Tagged "regex" (transit/String pattern))
    (ds/Ref eid) (transit-of-entity-ref db (stable-entity-ref db eid))
    (ds/List values) (transit/List (list/of-seq (map (fn [value] (transit-of-value db value)) values)))
    (ds/Vector values) (transit/Array (list/of-seq (map (fn [value] (transit-of-value db value)) values)))
    (ds/Map entries)
    (transit/Map
     (list/of-seq
      (map
       (fn [[key value]]
         (tuple (transit-of-value db key)
                (transit-of-value db value)))
       entries)))
    (ds/Set values) (transit/Set (list/of-seq (map (fn [value] (transit-of-value db value)) values)))
    (ds/Tuple values)
    (transit/Array
     (list/of-seq
      (map
       (fn [value]
         (match value
           None (transit/Null)
           (Some item) (transit-of-value db item)))
       values)))
    (ds/TxRef) (transit/Keyword "db/current-tx")
    (ds/Ref_to entity-ref) (transit-of-entity-ref db entity-ref)))

(declare transit-of-entity encrypt-entity)

(defn transit-of-tx-value [db value]
  (match value
    (ds/One_value value) (transit-of-value db value)
    (ds/Many_values values)
    (transit/Array (list/of-seq (map (fn [value] (transit-of-value db value)) values)))
    (ds/One_entity entity) (transit-of-entity db entity)
    (ds/Many_entities entities)
    (transit/Array (list/of-seq (map (fn [entity] (transit-of-entity db entity)) entities)))))

(defn transit-of-entity [db entity]
  (let [id
        (match (:db-id entity)
          (Some entity-ref)
          (list (tuple (transit/Keyword "db/id") (transit-of-entity-ref db entity-ref)))
          None (list))]
    (transit/Map
     (list/of-seq
      (concat
       id
       (map
        (fn [[attr value]]
          (tuple (transit/Keyword attr)
                 (transit-of-tx-value db value)))
        (:attrs entity)))))))

(defn protected-attr? [attr]
  (or (= attr "block/title") (= attr "block/name")))

(defn encrypt-value
  [encrypt attr value]
  (if (protected-attr? attr)
    (match value
      (ds/String plaintext)
      (match (encrypt plaintext)
        (Ok ciphertext) (Ok (ds/String ciphertext))
        (Error message) (Error message))
      _ (Error (str "protected attribute " attr " must be a string")))
    (Ok value)))

(defn encrypt-values-loop
  [encrypt
   attr
   values
   total
   index
   encrypted]
  (if (= index total)
    (Ok (rrbvec/to-list encrypted))
    (match (encrypt-value encrypt attr (nth values index))
      (Ok value) (encrypt-values-loop encrypt attr values total (inc index) (conj encrypted value))
      (Error message) (Error message))))

(defn encrypt-values
  [encrypt attr values]
  (let [values (rrbvec/of-list values)]
    (encrypt-values-loop encrypt attr values (count values) 0 empty-value-vector)))

(defn encrypt-entities-loop
  [encrypt
   ^:vector<Datascript.tx_entity> entities
   total
   index
   encrypted]
  (if (= index total)
    (Ok (rrbvec/to-list encrypted))
    (match (encrypt-entity encrypt (nth entities index))
      (Ok entity) (encrypt-entities-loop encrypt entities total (inc index) (conj encrypted entity))
      (Error message) (Error message))))

(defn encrypt-entities
  [encrypt entities]
  (let [entities (rrbvec/of-list entities)]
    (encrypt-entities-loop encrypt entities (count entities) 0 empty-entity-vector)))

(defn encrypt-tx-value
  [encrypt attr value]
  (match value
    (ds/One_value value)
    (match (encrypt-value encrypt attr value)
      (Ok value) (Ok (ds/One_value value))
      (Error message) (Error message))
    (ds/Many_values values)
    (match (encrypt-values encrypt attr values)
      (Ok values) (Ok (ds/Many_values values))
      (Error message) (Error message))
    (ds/One_entity entity)
    (match (encrypt-entity encrypt entity)
      (Ok entity) (Ok (ds/One_entity entity))
      (Error message) (Error message))
    (ds/Many_entities entities)
    (match (encrypt-entities encrypt entities)
      (Ok entities) (Ok (ds/Many_entities entities))
      (Error message) (Error message))))

(defn encrypt-entity-attrs-loop
  [encrypt
   db-id
   ^:vector<tuple<string;Datascript.tx_value>> attrs
   total
   index
   ^:vector<tuple<string;Datascript.tx_value>> encrypted]
  (if (= index total)
    (Ok (record Datascript.tx_entity
          (db-id db-id)
          (attrs (rrbvec/to-list encrypted))))
    (let [[attr value] (nth attrs index)]
      (match (encrypt-tx-value encrypt attr value)
        (Ok value)
        (encrypt-entity-attrs-loop encrypt db-id attrs total (inc index) (conj encrypted (tuple attr value)))
        (Error message) (Error message)))))

(defn encrypt-entity
  [encrypt entity]
  (let [attrs (rrbvec/of-list (:attrs entity))]
    (encrypt-entity-attrs-loop encrypt (:db-id entity) attrs (count attrs) 0 empty-entity-attrs-vector)))

(defn encrypt-tx-op
  [encrypt operation]
  (match operation
    (ds/Add entity-ref attr value)
    (match (encrypt-value encrypt attr value)
      (Ok value) (Ok (ds/Add entity-ref attr value))
      (Error message) (Error message))
    (ds/Retract entity-ref attr (Some value))
    (match (encrypt-value encrypt attr value)
      (Ok value) (Ok (ds/Retract entity-ref attr (Some value)))
      (Error message) (Error message))
    (ds/CompareAndSet entity-ref attr expected value)
    (match
     (match expected
       None (Ok None)
       (Some value)
       (match (encrypt-value encrypt attr value)
         (Ok value) (Ok (Some value))
         (Error message) (Error message)))
      (Ok expected)
      (match (encrypt-value encrypt attr value)
        (Ok value) (Ok (ds/CompareAndSet entity-ref attr expected value))
        (Error message) (Error message))
      (Error message) (Error message))
    (ds/Entity entity)
    (match (encrypt-entity encrypt entity)
      (Ok entity) (Ok (ds/Entity entity))
      (Error message) (Error message))
    (ds/Raw_datom datom)
    (match (encrypt-value encrypt (:a datom) (:v datom))
      (Ok value)
      (Ok (ds/Raw_datom
           (record Datascript.datom
             (e (:e datom))
             (a (:a datom))
             (v value)
             (tx (:tx datom))
             (added (:added datom)))))
      (Error message) (Error message))
    _ (Ok operation)))

(defn transit-of-tx-op
  [db operation]
  (match operation
    (ds/Add entity-ref attr value)
    (Ok (transit/Array (list (transit/Keyword "db/add")
                             (transit-of-entity-ref db entity-ref)
                             (transit/Keyword attr)
                             (transit-of-value db value))))
    (ds/Retract entity-ref attr (Some value))
    (Ok (transit/Array (list (transit/Keyword "db/retract")
                             (transit-of-entity-ref db entity-ref)
                             (transit/Keyword attr)
                             (transit-of-value db value))))
    (ds/Retract entity-ref attr None)
    (Ok (transit/Array (list (transit/Keyword "db.fn/retractAttribute")
                             (transit-of-entity-ref db entity-ref)
                             (transit/Keyword attr))))
    (ds/RetractAttr entity-ref attr)
    (Ok (transit/Array (list (transit/Keyword "db.fn/retractAttribute")
                             (transit-of-entity-ref db entity-ref)
                             (transit/Keyword attr))))
    (ds/RetractEntity entity-ref)
    (Ok (transit/Array (list (transit/Keyword "db/retractEntity")
                             (transit-of-entity-ref db entity-ref))))
    (ds/CompareAndSet entity-ref attr expected value)
    (Ok (transit/Array (list (transit/Keyword "db.fn/cas")
                             (transit-of-entity-ref db entity-ref)
                             (transit/Keyword attr)
                             (match expected
                               None (transit/Null)
                               (Some value) (transit-of-value db value))
                             (transit-of-value db value))))
    (ds/Entity entity) (Ok (transit-of-entity db entity))
    (ds/Raw_datom datom)
    (Ok (transit/Array (list (transit/Keyword (if (:added datom) "db/add" "db/retract"))
                             (transit-of-entity-ref db (stable-entity-ref db (:e datom)))
                             (transit/Keyword (:a datom))
                             (transit-of-value db (:v datom)))))
    (ds/CallIdent entity-ref values)
    (Ok (transit/Array
         (list* (transit-of-entity-ref db entity-ref)
                (list/of-seq (map (fn [value] (transit-of-value db value)) values)))))
    _ (Error "transaction functions cannot be sent over sync")))

(defn encode-loop
  [encrypt
   db
   operations
   total
   index
   encoded]
  (if (= index total)
    (Ok (rrbvec/to-list encoded))
    (let [operation (nth operations index)]
      (match (encrypt-tx-op encrypt operation)
        (Ok operation)
        (match (transit-of-tx-op db operation)
          (Ok value) (encode-loop encrypt db operations total (inc index) (conj encoded value))
          (Error message) (Error message))
        (Error message) (Error message)))))

(defn encode
  [encrypt db tx]
  (let [operations (rrbvec/of-list tx)]
  (match (encode-loop encrypt db operations (count operations) 0 empty-transit-vector)
    (Ok values) (Ok (codec/to-string (transit/Array values)))
    (Error message) (Error message))))
