(ns logseq-chat.entity-sync
  (:require [logseq-chat.sync-protocol :as protocol]
            [ocaml.package/datascript-ocaml-native]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Hashtbl :as hashtbl]
            [ocaml.Int64 :as int64]
            [ocaml.List :as list]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.String :as string]
            [ocaml.Stdlib :as stdlib]))

(type-record pending-temp-id
  (identity-attr :string)
  (identity-value :Datascript.value)
  (entity-ref :Datascript.entity_ref))

(type-record entity-identity
  (identity-attr :string)
  (identity-value :Datascript.value)
  (identity-ref :Datascript.entity_ref))

(defn identity-parts [input]
  (match input
    (Transit_core.Json/Array [(Transit_core.Json/Keyword "block/uuid") (Transit_core.Json/Uuid uuid)])
    (Ok (record entity-identity
          (identity-attr "block/uuid")
          (identity-value (ds/Uuid uuid))
          (identity-ref (ds/Lookup_ref "block/uuid" (ds/Uuid uuid)))))
    (Transit_core.Json/Array [(Transit_core.Json/Keyword "db/ident") (Transit_core.Json/Keyword ident)])
    (Ok (record entity-identity
          (identity-attr "db/ident")
          (identity-value (ds/Keyword ident))
          (identity-ref (ds/Ident ident))))
    (Transit_core.Json/Array [(Transit_core.Json/Keyword "file/path") (Transit_core.Json/String path)])
    (Ok (record entity-identity
          (identity-attr "file/path")
          (identity-value (ds/String path))
          (identity-ref (ds/Lookup_ref "file/path" (ds/String path)))))
    _ (Error "unsupported server entity identity")))

(declare generic-value)

(defn generic-value-entry [^:tuple<Transit_core.Json.value;Transit_core.Json.value> entry]
  (let [[key value] entry]
    (tuple (generic-value key)
           (generic-value value))))

(defn ^:Datascript.value generic-value [^:Transit_core.Json.value input]
  (match input
    (Transit_core.Json/Null) (ds/Nil)
    (Transit_core.Json/Bool value) (ds/Bool value)
    (Transit_core.Json/String value) (ds/String value)
    (Transit_core.Json/Int value) (ds/Int value)
    (Transit_core.Json/Int64 value) (ds/Int (int64/to-int value))
    (Transit_core.Json/Float value) (ds/Float value)
    (Transit_core.Json/Binary value) (ds/String value)
    (Transit_core.Json/Big_decimal value) (ds/Float (stdlib/float-of-string value))
    (Transit_core.Json/Big_int value) (ds/Int (int64/to-int (int64/of-string value)))
    (Transit_core.Json/Date value) (ds/Instant (int64/to-int value))
    (Transit_core.Json/Uuid value) (ds/Uuid value)
    (Transit_core.Json/Uri value) (ds/String value)
    (Transit_core.Json/Keyword value) (ds/Keyword value)
    (Transit_core.Json/Symbol value) (ds/Symbol value)
    (Transit_core.Json/Array values)
    (ds/Vector (list/of-seq (map (fn [value] (generic-value value)) values)))
    (Transit_core.Json/Map entries)
    (ds/Map (list/of-seq (map generic-value-entry entries)))
    (Transit_core.Json/Set values)
    (ds/Set (list/of-seq (map (fn [value] (generic-value value)) values)))
    (Transit_core.Json/List values)
    (ds/List (list/of-seq (map (fn [value] (generic-value value)) values)))
    (Transit_core.Json/Tagged "u" (Transit_core.Json/String value)) (ds/Uuid value)
    (Transit_core.Json/Tagged "m" (Transit_core.Json/Int value)) (ds/Instant value)
    (Transit_core.Json/Tagged "m" (Transit_core.Json/Int64 value)) (ds/Instant (int64/to-int value))
    (Transit_core.Json/Tagged "regex" (Transit_core.Json/String value)) (ds/Regex value)
    (Transit_core.Json/Tagged tag value) (ds/Vector (list (ds/String tag) (generic-value value)))))

(defn schema-attr [db attr]
  (list/assoc-opt attr (ds/schema db)))

(defn temp-id [identity-attr identity-value]
  (let [suffix
        (match identity-value
          (ds/Uuid value) value
          (ds/String value) value
          (ds/Keyword value) value
          _ (stdlib/string-of-int (hashtbl/hash identity-value)))]
    (ds/Temp_id (str "remote:" identity-attr ":" suffix))))

(defn pending-temp-id-ref-loop [identity-attr identity-value pending-temp-ids total index]
  (if (= index total)
    None
    (let [pending (nth pending-temp-ids index)]
      (if (and (= (:identity-attr pending) identity-attr)
               (= (:identity-value pending) identity-value))
        (Some (:entity-ref pending))
        (pending-temp-id-ref-loop identity-attr identity-value pending-temp-ids total (inc index))))))

(defn pending-temp-id-ref [identity-attr identity-value pending-temp-ids]
  (let [pending-temp-ids (rrbvec/of-list pending-temp-ids)]
    (pending-temp-id-ref-loop identity-attr identity-value pending-temp-ids (count pending-temp-ids) 0)))

(defn value-for-attr [db pending-temp-ids attr value]
  (match (schema-attr db attr)
    (Some schema)
    (match (:value-type schema)
      (Some ds/RefType)
      (let* [parts (identity-parts value)]
        (let [identity-attr (:identity-attr parts)
              identity-value (:identity-value parts)
              entity-ref (:identity-ref parts)
              entity-ref
              (match (pending-temp-id-ref identity-attr identity-value pending-temp-ids)
                (Some pending) pending
                None entity-ref)]
          (Ok (ds/Ref_to entity-ref))))
      (Some ds/TupleType)
      (match value
        (Transit_core.Json/Array values)
        (Ok (ds/Tuple
             (list/of-seq
              (map
               (fn [item]
                 (match item
                   (Transit_core.Json/Null) None
                   _ (Some (generic-value item))))
               values))))
        (Transit_core.Json/List values)
        (Ok (ds/Tuple
             (list/of-seq
              (map
               (fn [item]
                 (match item
                   (Transit_core.Json/Null) None
                   _ (Some (generic-value item))))
               values))))
        _ (Error (str "tuple attribute " attr " is not a Transit array")))
      _ (Ok (generic-value value)))
    None (Ok (generic-value value))))

(defn values-for-attr [db pending-temp-ids attr value]
  (match (schema-attr db attr)
    (Some schema)
    (match (:cardinality schema)
      ds/Many
      (let [values
            (match value
              (Transit_core.Json/Set values) values
              (Transit_core.Json/Array values) values
              (Transit_core.Json/List values) values
              _ (list value))]
        (let [values (rrbvec/of-list values)]
          (values-for-attr-loop db pending-temp-ids attr values (count values) 0 [])))
      _ (let* [value (value-for-attr db pending-temp-ids attr value)]
          (Ok (list value))))
    None (let* [value (value-for-attr db pending-temp-ids attr value)]
           (Ok (list value)))))

(defn values-for-attr-loop
  [db pending-temp-ids attr
   values
   total
   index
   converted]
  (if (= index total)
    (Ok (rrbvec/to-list converted))
    (let* [value (value-for-attr db pending-temp-ids attr (nth values index))]
      (values-for-attr-loop db pending-temp-ids attr values total (inc index) (conj converted value)))))

(defn protected-attr? [attr]
  (or (= attr "block/title") (= attr "block/name")))

(defn decrypt-attr [decrypt attr value]
  (if (protected-attr? attr)
    (match value
      (Transit_core.Json/String ciphertext)
      (match (decrypt ciphertext)
        (Ok plaintext) (Ok (Transit_core.Json/String plaintext))
        (Error message) (Error message))
      _ (Error (str "protected server attribute " attr " must be a string")))
    (Ok value)))

(defn decoded-attrs-loop
  [decrypt db pending-temp-ids
   ^:vector<tuple<Transit_core.Json.value;Transit_core.Json.value>> attrs
   total
   index
   decoded]
  (if (= index total)
    (Ok (rrbvec/to-list decoded))
    (let [[key value] (nth attrs index)]
      (match key
        (Transit_core.Json/Keyword attr)
        (let* [value (decrypt-attr decrypt attr value)
               values (values-for-attr db pending-temp-ids attr value)]
          (decoded-attrs-loop decrypt db pending-temp-ids attrs total (inc index)
                              (conj decoded (tuple attr values))))
        _ (Error "server entity attribute name is not a keyword")))))

(defn decoded-attrs [decrypt db pending-temp-ids attrs]
  (let [attrs (rrbvec/of-list attrs)]
    (decoded-attrs-loop decrypt db pending-temp-ids attrs (count attrs) 0 [])))

(defn add-ops-for-attr
  [entity-ref identity-attr ^:tuple<string;list<Datascript.value>> attr-values]
  (let [[attr values] attr-values]
    (if (= attr identity-attr)
      (list)
      (map
       (fn [value] (ds/Add entity-ref attr value))
       values))))

(defn pending-temp-ids-loop
  [db
   entities
   total
   index
   pending]
  (if (= index total)
    (Ok pending)
    (let [entity (nth entities index)]
      (let* [parts (identity-parts (:id entity))]
        (let [identity-attr (:identity-attr parts)
              identity-value (:identity-value parts)
              identity-ref (:identity-ref parts)
              pending
              (match (ds/entid-ref db identity-ref)
                (Some _) pending
                None (list*
                      (record pending-temp-id
                        (identity-attr identity-attr)
                        (identity-value identity-value)
                        (entity-ref (temp-id identity-attr identity-value)))
                      pending))]
          (pending-temp-ids-loop db entities total (inc index) pending))))))

(defn ^:result<list<pending-temp-id>;string> pending-temp-ids [db entities]
  (let [entities (rrbvec/of-list entities)]
    (pending-temp-ids-loop db entities (count entities) 0 (list))))

(defn upsert-ops [decrypt db pending-temp-ids entity]
  (match (identity-parts (:id entity))
    (Error message) (Error message)
    (Ok parts)
    (let [identity-attr (:identity-attr parts)
          identity-value (:identity-value parts)
          identity-ref (:identity-ref parts)]
      (match (decoded-attrs decrypt db pending-temp-ids (:attrs entity))
        (Error message) (Error message)
        (Ok attrs)
        (match (ds/entid-ref db identity-ref)
          (Some eid)
          (let [retractions
                (list/of-seq
                 (map
                  (fn [datom]
                    (ds/Retract (ds/Entity_id eid) (:a datom) (Some (:v datom))))
                  (filter
                   (fn [datom]
                     (not= (:a datom) identity-attr))
                   (db-api/datoms db (ds/Eavt) :e eid))))]
            (Ok
             (list/of-seq
              (concat
               retractions
               (mapcat
                (fn [attr-values]
                  (add-ops-for-attr (ds/Entity_id eid) identity-attr attr-values))
                attrs)))))
          None
          (let [entity-ref (temp-id identity-attr identity-value)
                identity (ds/Add entity-ref identity-attr identity-value)]
            (Ok
             (list*
              identity
              (mapcat
               (fn [attr-values]
                 (add-ops-for-attr entity-ref identity-attr attr-values))
               attrs)))))))))

(defn delete-ops-loop
  [db
   identities
   total
   index
   operations]
  (if (= index total)
    (Ok (list/rev operations))
    (let* [parts (identity-parts (nth identities index))]
      (let [entity-ref (:identity-ref parts)
            operations
            (match (ds/entid-ref db entity-ref)
              (Some eid) (list* (ds/RetractEntity (ds/Entity_id eid)) operations)
              None operations)]
        (delete-ops-loop db identities total (inc index) operations)))))

(defn delete-ops [db identities]
  (let [identities (rrbvec/of-list identities)]
    (delete-ops-loop db identities (count identities) 0 (list))))

(defn collect-upserts
  [decrypt db pending-temp-ids
   entities
   total
   index
   operations]
  (if (= index total)
    (Ok (list/concat (rrbvec/to-list operations)))
    (let* [entity-ops (upsert-ops decrypt db pending-temp-ids (nth entities index))]
      (collect-upserts decrypt db pending-temp-ids entities total (inc index) (conj operations entity-ops)))))

(defn apply-change-set
  [decrypt conn change]
  (try
    (let [db (ds/conn-db conn)]
      (let* [pending-temp-ids (pending-temp-ids db (:upserts change))]
        (let [upserts-vector (rrbvec/of-list (:upserts change))]
          (let* [upserts (collect-upserts decrypt db pending-temp-ids upserts-vector (count upserts-vector) 0 [])
                 deletions (delete-ops db (:deleted change))]
            (if (or (not= upserts (list)) (not= deletions (list)))
              (stdlib/ignore (ds/transact-conn conn (list/append upserts deletions)))
              (stdlib/ignore 0))
            (Ok (stdlib/ignore 0))))))
    (catch error
      (Error (Printexc/to-string error)))))
