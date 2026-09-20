(ns logseq-chat.sync-protocol-test
  (:refer-clojure :exclude [uuid])
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.sync-protocol :as protocol]
            [logseq-chat.sync-checkpoint :as checkpoint]
            [logseq-chat.flashcards :as flashcards]
            [ocaml.Transit_core.Json :as value]
            [ocaml.Transit_native.Transit.Json :as codec]
            [ocaml.Datascript :as ds]
            [ocaml.Stdlib :as stdlib]))

(def uuid "7b45785d-710c-47f8-9e7e-e9c4f5229830")

(def second-uuid "7b45785d-710c-47f8-9e7e-e9c4f5229831")

(defn identity-value [uuid] (value/Array (list (value/Keyword "block/uuid") (value/Uuid uuid))))

(def task-tag (value/Set (list (value/Array (list (value/Keyword "db/ident") (value/Keyword "logseq.class/Task"))))))

(def payload
  (value/Map
   (list (tuple (value/Keyword "format-version") (value/Int 1))
         (tuple (value/Keyword "graph-id") (value/String "graph-1"))
         (tuple (value/Keyword "schema-version") (value/String "65.33"))
         (tuple (value/Keyword "t-before") (value/Int 41))
         (tuple (value/Keyword "t") (value/Int 42))
         (tuple (value/Keyword "upserts")
                (value/Array
                 (list (value/Map
                        (list (tuple (value/Keyword "id") (identity-value uuid))
                              (tuple (value/Keyword "attrs")
                                     (value/Map
                                      (list (tuple (value/Keyword "block/uuid") (value/Uuid uuid))
                                            (tuple (value/Keyword "block/title") (value/String "Encrypted or plain title"))
                                            (tuple (value/Keyword "block/tags") task-tag)))))))))
         (tuple (value/Keyword "deleted") (value/Array (list)))
         (tuple (value/Keyword "operation-ids") (value/Array (list (value/String "op-delete") (value/String "op-title")))))))

(defn decode [payload]
  (match (protocol/decode-change-set (codec/to-string payload))
    (Ok change) change
    (Error message) (stdlib/failwith message)))

(deftest lookup-preserves-first-false-and-null-values
  (run! (fn [lookup]
          (run! (fn [input]
                  (let [entries (list (tuple (value/Keyword "key") input) (tuple (value/Keyword "key") (value/Int 42)))]
                    (is (= (Some input) (lookup "key" entries)))
                    (is (nil? (lookup "missing" entries)))))
                [(value/Null) (value/Bool false) (value/Int 0) (value/String "")]))
        [protocol/field checkpoint/field])
  (run! (fn [input]
          (let [entries (list (tuple (ds/Keyword "key") input) (tuple (ds/Keyword "key") (ds/Int 42)))]
            (is (= (Some input) (flashcards/map-value "key" entries)))
            (is (nil? (flashcards/map-value "missing" entries)))))
        [(ds/Nil) (ds/Bool false) (ds/Int 0) (ds/String "")]))

(deftest wire-contract-preserves-identities-sets-and-cursors
  (let [change (decode payload)]
    (is (= 1 (:format-version change)))
    (is (= "graph-1" (:graph-id change)))
    (is (= "65.33" (:schema-version change)))
    (is (= 41 (:t-before change)))
    (is (= 42 (:t change)))
    (is (= ["op-delete" "op-title"] (vec (:operation-ids change))))
    (is (= [uuid] (protocol/changed-block-uuids change)))
    (is (= 1 (count (:upserts change))))
    (let [entity (nth (:upserts change) 0)]
      (is (= (identity-value uuid) (:id entity)))
      (is (= (Some task-tag) (protocol/field "block/tags" (:attrs entity)))))
    (let [repeated (assoc change
                          :upserts (apply list (concat (:upserts change) (:upserts change)))
                          :deleted (list (identity-value uuid)
                                         (value/Array (list (value/Keyword "db/ident") (value/Keyword "logseq.class/Card")))
                                         (identity-value second-uuid) (identity-value second-uuid)))]
      (is (= [uuid second-uuid] (protocol/changed-block-uuids repeated))))))

(deftest operation-identities-are-optional-but-must-be-strings
  (match payload
    (value/Map fields)
    (let [without (remove (fn [[key _]] (= key (value/Keyword "operation-ids"))) fields)]
      (is (empty? (:operation-ids (decode (value/Map (apply list without))))))
      (match (protocol/decode-change-set
              (codec/to-string
               (value/Map (apply list (cons (tuple (value/Keyword "operation-ids") (value/Array (list (value/Int 1)))) without)))))
        (Error _) (is true)
        (Ok _) (stdlib/failwith "non-string operation identity accepted")))
    _ (stdlib/failwith "expected a map fixture")))

(deftest reset-event-contract
  (is (= (Ok (protocol/Reset (record protocol/sync-reset (reason "cursor-expired") (snapshot-required true))))
         (protocol/decode-event
          "reset" (codec/to-string
                   (value/Map (list (tuple (value/Keyword "reason") (value/String "cursor-expired"))
                                    (tuple (value/Keyword "snapshot-required") (value/Bool true)))))))))

(deftest numeric-server-local-identities-are-rejected
  (match payload
    (value/Map fields)
    (let [fields (remove (fn [[key _]] (= key (value/Keyword "upserts"))) fields)
          malformed (value/Map
                     (apply list
                            (cons (tuple (value/Keyword "upserts")
                                         (value/Array (list (value/Map (list (tuple (value/Keyword "id") (value/Int 123))
                                                                           (tuple (value/Keyword "attrs") (value/Map (list)))))))) fields)))]
      (match (protocol/decode-change-set (codec/to-string malformed))
        (Error _) (is true)
        (Ok _) (stdlib/failwith "numeric server-local entity identity accepted")))
    _ (stdlib/failwith "expected a map fixture")))
