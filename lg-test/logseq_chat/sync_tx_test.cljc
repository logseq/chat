(ns logseq-chat.sync-tx-test
  (:refer-clojure :exclude [array])
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.sync-tx :as sync]
            [logseq-chat.storage-codec :as codec]
            [ocaml.Datascript :as ds]
            [ocaml.Transit_native.Transit.Json :as transit]
            [ocaml.Int64 :as int64]
            [ocaml.Stdlib :as stdlib]))

(defn expect-ok [result]
  (match result (Ok value) value (Error message) (stdlib/failwith message)))

(def schema
  (let [one (assoc codec/default-schema-attr :indexed true)]
    (list (tuple "block/uuid" (assoc one :unique (Some (ds/Identity)) :value-type (Some (ds/UuidType))))
          (tuple "block/title" (assoc one :value-type (Some (ds/StringType))))
          (tuple "block/parent" (assoc one :value-type (Some (ds/RefType))))
          (tuple "db/ident" (assoc one :unique (Some (ds/Identity)) :value-type (Some (ds/KeywordType))))
          (tuple "block/tags" (assoc one :cardinality (ds/Many) :value-type (Some (ds/StringType)))))))

(defn reference-db []
  (ds/db-with (list (ds/Add (ds/Entity_id 1) "block/uuid" (ds/Uuid "stable-uuid"))
                    (ds/Add (ds/Entity_id 2) "db/ident" (ds/Keyword "stable.ident"))
                    (ds/Add (ds/Entity_id 3) "block/title" (ds/String "Opaque"))
                    (ds/Add (ds/Entity_id 3) "block/tags" (ds/String "one"))
                    (ds/Add (ds/Entity_id 3) "block/tags" (ds/String "two")))
              (ds/empty-db :schema schema)))

(defn array [values] (transit/Array (apply list values)))
(def stable-ref (array [(transit/Keyword "block/uuid") (transit/Uuid "stable-uuid")]))
(defn entity [id attrs] (record Datascript.tx_entity (db-id id) (attrs (apply list attrs))))
(defn child [title] (entity None [(tuple "block/title" (ds/One_value (ds/String title)))]))
(defn encode [db tx] (sync/encode #(Ok %) db (apply list tx)))

(deftest transaction-wire-preserves-local-ids-and-stable-parent-references
  (let [db (reference-db)
        wire (expect-ok
              (encode db
                      [(ds/Add (ds/Lookup_ref "block/uuid" (ds/Uuid "stable-uuid")) "block/title" (ds/String "before"))
                       (ds/Entity (entity (Some (ds/Temp_id "pending/new"))
                                          [(tuple "block/uuid" (ds/One_value (ds/Uuid "new")))
                                           (tuple "block/title" (ds/One_value (ds/String "after")))
                                           (tuple "block/parent" (ds/One_value (ds/Ref_to (ds/Lookup_ref "block/uuid" (ds/Uuid "stable-uuid")))))]))]))]
    (is (= (array [(array [(transit/Keyword "db/add") stable-ref (transit/Keyword "block/title") (transit/String "before")])
                   (transit/Map (list (tuple (transit/Keyword "db/id") (transit/String "pending/new"))
                                      (tuple (transit/Keyword "block/uuid") (transit/Uuid "new"))
                                      (tuple (transit/Keyword "block/title") (transit/String "after"))
                                      (tuple (transit/Keyword "block/parent") stable-ref)))])
           (transit/of-string wire)))))

(deftest entity-reference-identity-and-fallbacks
  (let [db (reference-db)]
    (run! (fn [[ref expected]] (is (= expected (sync/transit-of-entity-ref db ref))))
          [(tuple (ds/Entity_id 1) stable-ref)
           (tuple (ds/Entity_id 2) (array [(transit/Keyword "db/ident") (transit/Keyword "stable.ident")]))
           (tuple (ds/Entity_id 3) (transit/Int 3)) (tuple (ds/Entity_id 404) (transit/Int 404))
           (tuple (ds/Temp_id "temp") (transit/String "temp"))
           (tuple (ds/CurrentTx) (transit/Keyword "db/current-tx"))
           (tuple (ds/Ident "fn") (transit/Keyword "fn"))
           (tuple (ds/Lookup_ref "block/title" (ds/String "Title")) (array [(transit/Keyword "block/title") (transit/String "Title")]))])
    (let [opaque (or (ds/entity db (ds/Entity_id 3)) (stdlib/failwith "missing opaque entity"))]
      (is (nil? (sync/lookup-value opaque "block/tags"))))))

(deftest every-datascript-value-has-a-sync-encoding
  (let [db (reference-db)]
    (run! (fn [[value expected]] (is (= expected (sync/transit-of-value db value))))
          [(tuple (ds/Nil) (transit/Null)) (tuple (ds/Int 7) (transit/Int 7))
           (tuple (ds/Float 1.5) (transit/Float 1.5)) (tuple (ds/String "text") (transit/String "text"))
           (tuple (ds/Symbol "symbol") (transit/Symbol "symbol")) (tuple (ds/Bool true) (transit/Bool true))
           (tuple (ds/Keyword "keyword") (transit/Keyword "keyword")) (tuple (ds/Uuid "uuid") (transit/Uuid "uuid"))
           (tuple (ds/Instant 123) (transit/Date (int64/of-int 123)))
           (tuple (ds/Regex "a+") (transit/Tagged "regex" (transit/String "a+")))
           (tuple (ds/Ref 1) stable-ref)
           (tuple (ds/List (list (ds/Int 1))) (transit/List (list (transit/Int 1))))
           (tuple (ds/Vector (list (ds/String "v"))) (array [(transit/String "v")]))
           (tuple (ds/Map (list (tuple (ds/Keyword "k") (ds/Bool false))))
                  (transit/Map (list (tuple (transit/Keyword "k") (transit/Bool false)))))
           (tuple (ds/Set (list (ds/Uuid "u"))) (transit/Set (list (transit/Uuid "u"))))
           (tuple (ds/Tuple (list (Some (ds/Int 1)) None)) (array [(transit/Int 1) (transit/Null)]))
           (tuple (ds/TxRef) (transit/Keyword "db/current-tx"))
           (tuple (ds/Ref_to (ds/Temp_id "ref")) (transit/String "ref"))])))

(deftest nested-entity-cardinalities-are-preserved
  (let [nested (child "Child")
        wire (transit/Map (list (tuple (transit/Keyword "block/title") (transit/String "Child"))))
        value (entity (Some (ds/Temp_id "entity"))
                      [(tuple "one" (ds/One_value (ds/Int 1)))
                       (tuple "many" (ds/Many_values (list (ds/Int 2) (ds/Int 3))))
                       (tuple "child" (ds/One_entity nested)) (tuple "children" (ds/Many_entities (list nested)))])]
    (is (= (transit/Map (list (tuple (transit/Keyword "db/id") (transit/String "entity"))
                              (tuple (transit/Keyword "one") (transit/Int 1))
                              (tuple (transit/Keyword "many") (array [(transit/Int 2) (transit/Int 3)]))
                              (tuple (transit/Keyword "child") wire)
                              (tuple (transit/Keyword "children") (array [wire]))))
           (sync/transit-of-entity (reference-db) value)))))

(defn raw [added value]
  (ds/Raw_datom (record Datascript.datom (e 1) (a "block/title") (v (ds/String value)) (tx 1) (added added))))

(deftest transaction-operations-preserve-all-operands
  (let [db (reference-db) ref (ds/Lookup_ref "block/uuid" (ds/Uuid "stable-uuid"))
        attr (transit/Keyword "block/title")
        retract (array [(transit/Keyword "db.fn/retractAttribute") stable-ref attr])]
    (run! (fn [[op expected]] (is (= (Ok expected) (sync/transit-of-tx-op db op))))
          [(tuple (ds/Retract ref "block/title" (Some (ds/String "Old")))
                  (array [(transit/Keyword "db/retract") stable-ref attr (transit/String "Old")]))
           (tuple (ds/Retract ref "block/title" None) retract)
           (tuple (ds/RetractAttr ref "block/title") retract)
           (tuple (ds/RetractEntity ref) (array [(transit/Keyword "db/retractEntity") stable-ref]))
           (tuple (ds/CompareAndSet ref "block/title" (Some (ds/String "Old")) (ds/String "New"))
                  (array [(transit/Keyword "db.fn/cas") stable-ref attr (transit/String "Old") (transit/String "New")]))
           (tuple (ds/CompareAndSet ref "block/title" None (ds/String "New"))
                  (array [(transit/Keyword "db.fn/cas") stable-ref attr (transit/Null) (transit/String "New")]))
           (tuple (ds/Entity (child "Entity")) (transit/Map (list (tuple attr (transit/String "Entity")))))
           (tuple (raw true "Raw") (array [(transit/Keyword "db/add") stable-ref attr (transit/String "Raw")]))
           (tuple (raw false "Raw") (array [(transit/Keyword "db/retract") stable-ref attr (transit/String "Raw")]))
           (tuple (ds/CallIdent (ds/Ident "function") (list (ds/Int 1) (ds/String "x")))
                  (array [(transit/Keyword "function") (transit/Int 1) (transit/String "x")]))])
    (is (= (array []) (transit/of-string (expect-ok (encode db [])))))
    (run! (fn [op]
            (is (= (Error "transaction functions cannot be sent over sync") (sync/transit-of-tx-op db op)))
            (is (= (Error "transaction functions cannot be sent over sync") (encode db [op]))))
          [(ds/InstallTxFn (ds/Ident "install") (fn [_ _] (stdlib/failwith "sync must not execute transaction functions")))
           (ds/Call (fn [_] (stdlib/failwith "sync must not execute transaction functions")))])))

(defn encrypted-entity [prefix]
  (ds/Entity (entity (Some (ds/Temp_id "entity"))
                     [(tuple "block/title" (ds/One_value (ds/String (str prefix "Root"))))
                      (tuple "block/name" (ds/Many_values (list (ds/String (str prefix "one")) (ds/String (str prefix "two")))))
                      (tuple "child" (ds/One_entity (child (str prefix "Child"))))
                      (tuple "children" (ds/Many_entities (list (child (str prefix "A")) (child (str prefix "B")))))])))

(deftest encryption-covers-protected-operands-and-nested-entities
  (let [ref (ds/Temp_id "entity") encrypt #(Ok (str "cipher:" %))]
    (run! (fn [[op expected]] (is (= (Ok expected) (sync/encrypt-tx-op encrypt op))))
          [(tuple (ds/Add ref "block/title" (ds/String "Title")) (ds/Add ref "block/title" (ds/String "cipher:Title")))
           (tuple (ds/Add ref "block/name" (ds/String "name")) (ds/Add ref "block/name" (ds/String "cipher:name")))
           (tuple (ds/Add ref "block/order" (ds/String "a0")) (ds/Add ref "block/order" (ds/String "a0")))
           (tuple (ds/Retract ref "block/title" (Some (ds/String "Old"))) (ds/Retract ref "block/title" (Some (ds/String "cipher:Old"))))
           (tuple (ds/Retract ref "block/title" None) (ds/Retract ref "block/title" None))
           (tuple (ds/CompareAndSet ref "block/title" (Some (ds/String "Old")) (ds/String "New"))
                  (ds/CompareAndSet ref "block/title" (Some (ds/String "cipher:Old")) (ds/String "cipher:New")))
           (tuple (ds/CompareAndSet ref "block/title" None (ds/String "New"))
                  (ds/CompareAndSet ref "block/title" None (ds/String "cipher:New")))
           (tuple (encrypted-entity "") (encrypted-entity "cipher:"))
           (tuple (raw true "Raw") (raw true "cipher:Raw"))])
    (run! (fn [op] (is (match (sync/encrypt-tx-op encrypt op) (Ok _) true (Error _) false)))
          [(ds/Retract ref "block/title" None) (ds/RetractAttr ref "block/title") (ds/RetractEntity ref)
           (ds/CallIdent (ds/Ident "function") (list (ds/String "plaintext argument")))
           (ds/InstallTxFn (ds/Ident "install") (fn [_ _] (stdlib/failwith "encryption must not execute transaction functions")))
           (ds/Call (fn [_] (stdlib/failwith "encryption must not execute transaction functions")))])
    (is (match (sync/encrypt-tx-op encrypt (ds/Add ref "block/title" (ds/Int 1)))
          (Error _) true (Ok _) false))))
