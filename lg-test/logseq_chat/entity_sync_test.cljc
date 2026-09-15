(ns logseq-chat.entity-sync-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.entity-sync :as sync]
            [logseq-chat.sync-protocol :as protocol]
            [logseq-chat.storage-codec :as storage]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Transit_core.Json :as transit]
            [ocaml.Stdlib :as stdlib]))

(def one storage/default-schema-attr)
(def uuid-schema (assoc one :value-type (Some (ds/UuidType)) :unique (Some (ds/Identity)) :indexed true))
(def string-schema (assoc one :value-type (Some (ds/StringType))))
(def ref-schema (assoc one :value-type (Some (ds/RefType))))

(defn wire-identity [uuid] (transit/Array (list (transit/Keyword "block/uuid") (transit/Uuid uuid))))
(defn wire-block [uuid title]
  [(tuple (transit/Keyword "block/uuid") (transit/Uuid uuid))
   (tuple (transit/Keyword "block/title") (transit/String title))])
(defn entity [uuid attrs]
  (record protocol/sync-entity (id (wire-identity uuid)) (attrs (apply list attrs))))
(defn change-set [upserts deleted]
  (record protocol/sync-change-set
          (format-version 1) (graph-id "graph-1") (schema-version "65.33") (t-before 7) (t 8)
          (upserts (apply list upserts)) (deleted (apply list deleted)) (operation-ids (list))))
(defn eid [db uuid]
  (match (ds/entid db "block/uuid" (ds/Uuid uuid))
    (Some eid) eid None (stdlib/failwith (str "missing entity: " uuid))))
(defn values [db eid attr] (mapv :v (db-api/datoms db (ds/Eavt) :e eid :a attr)))
(defn ok? [result] (match result (Ok _) true (Error _) false))

(deftest authoritative-changes-replace-retract-and-resolve-reference-identities
  (let [schema (list (tuple "block/uuid" uuid-schema) (tuple "block/title" string-schema)
                     (tuple "block/collapsed?" one) (tuple "block/parent" ref-schema)
                     (tuple "block/tags" (assoc ref-schema :cardinality (ds/Many)))
                     (tuple "block/properties" one))
        old "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8"
        parent "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec9"
        tag "018f7850-c6aa-7da0-8b3f-6dbb64aa4eca"
        fresh "018f7850-c6aa-7da0-8b3f-6dbb64aa4ecb"
        doomed "018f7850-c6aa-7da0-8b3f-6dbb64aa4ecc"
        remote-parent "018f7850-c6aa-7da0-8b3f-6dbb64aa4ecd"
        remote-child "018f7850-c6aa-7da0-8b3f-6dbb64aa4ece"
        conn (ds/create-conn :schema schema)]
    (ds/transact-conn conn
                      (list (ds/Add (ds/Entity_id 1) "block/uuid" (ds/Uuid old))
                            (ds/Add (ds/Entity_id 1) "block/title" (ds/String "Before"))
                            (ds/Add (ds/Entity_id 1) "block/collapsed?" (ds/Bool true))
                            (ds/Add (ds/Entity_id 2) "block/uuid" (ds/Uuid parent))
                            (ds/Add (ds/Entity_id 2) "block/title" (ds/String "Parent"))
                            (ds/Add (ds/Entity_id 3) "block/uuid" (ds/Uuid tag))
                            (ds/Add (ds/Entity_id 3) "block/title" (ds/String "Tag"))
                            (ds/Add (ds/Entity_id 4) "block/uuid" (ds/Uuid doomed))
                            (ds/Add (ds/Entity_id 4) "block/title" (ds/String "Delete me"))))
    (let [changes (change-set
                   [(entity old (into (wire-block old "After")
                                      [(tuple (transit/Keyword "block/parent") (wire-identity parent))
                                       (tuple (transit/Keyword "block/tags") (transit/Set (list (wire-identity tag))))
                                       (tuple (transit/Keyword "block/properties")
                                              (transit/Map (list (tuple (transit/Keyword "priority") (transit/Keyword "A")))))]))
                    (entity fresh (wire-block fresh "Created"))
                    (entity remote-child (conj (wire-block remote-child "Remote child")
                                               (tuple (transit/Keyword "block/parent") (wire-identity remote-parent))))
                    (entity remote-parent (wire-block remote-parent "Remote parent"))]
                   [(wire-identity doomed)])]
      (is (ok? (sync/apply-change-set #(Ok %) conn changes)))
      (let [db (ds/conn-db conn) old-eid (eid db old)]
        (is (= [(ds/String "After")] (values db old-eid "block/title")))
        (is (empty? (values db old-eid "block/collapsed?")))
        (is (= [(ds/Ref (eid db parent))] (values db old-eid "block/parent")))
        (is (= [(ds/Ref (eid db tag))] (values db old-eid "block/tags")))
        (is (= [(ds/Map (list (tuple (ds/Keyword "priority") (ds/Keyword "A"))))]
               (values db old-eid "block/properties")))
        (is (some? (ds/entid db "block/uuid" (ds/Uuid fresh))))
        (is (= [(ds/Ref (eid db remote-parent))] (values db (eid db remote-child) "block/parent")))
        (is (nil? (ds/entid db "block/uuid" (ds/Uuid doomed))))))))

(deftest encrypted-server-attributes-are-plaintext-in-local-datascript
  (let [conn (ds/create-conn :schema (list (tuple "block/uuid" uuid-schema)
                                           (tuple "block/title" string-schema) (tuple "block/name" string-schema)))
        changes (assoc (change-set
                        [(entity "encrypted-block"
                                 (conj (wire-block "encrypted-block" "cipher:Title")
                                       (tuple (transit/Keyword "block/name") (transit/String "cipher:title"))))] [])
                       :graph-id "encrypted-graph" :t-before 0 :t 1)
        decrypt (fn [value] (if (string/starts-with? value "cipher:") (Ok (subs value 7)) (Error "expected ciphertext")))]
    (is (ok? (sync/apply-change-set decrypt conn changes)))
    (let [db (ds/conn-db conn) eid (eid db "encrypted-block")]
      (is (= [(ds/String "Title")] (values db eid "block/title")))
      (is (= [(ds/String "title")] (values db eid "block/name"))))))

(deftest failed-decryption-stops-at-first-error-without-committing-any-change
  (let [conn (ds/create-conn :schema (list (tuple "block/uuid" uuid-schema) (tuple "block/title" string-schema)))]
    (ds/transact-conn conn (list (ds/Add (ds/Entity_id 1) "block/uuid" (ds/Uuid "existing"))
                                 (ds/Add (ds/Entity_id 1) "block/title" (ds/String "Original"))))
    (let [before (ds/conn-db conn) calls (atom [])
          decrypt (fn [ciphertext]
                    (swap! calls conj ciphertext)
                    (if (= ciphertext "broken") (Error "decryption failed") (Ok ciphertext)))
          changes (assoc (change-set
                          [(entity "existing" (wire-block "existing" "Updated"))
                           (entity "broken-block" (wire-block "broken-block" "broken"))
                           (entity "later-block" (wire-block "later-block" "must not decrypt"))]
                          [(wire-identity "existing")])
                         :graph-id "encrypted-graph" :t-before 0 :t 1)]
      (is (= (Error "decryption failed") (sync/apply-change-set decrypt conn changes)))
      (is (= ["Updated" "broken"] @calls))
      (is (identical? before (ds/conn-db conn))))))
