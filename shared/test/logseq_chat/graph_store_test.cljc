(ns logseq-chat.graph-store-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [lg.literal :as literal]
            [logseq-chat.graph-store :as store]
            [logseq-chat.snapshot :as snapshot]
            [ocaml.Transit_native.Transit.Json :as transit]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Int64 :as int64]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Gc :as gc]))

(defn expect-ok [result]
  (match result (Ok value) value (Error message) (stdlib/failwith message)))

(defn with-store [f]
  (let [path (filename/temp-file "logseq-chat-graph" ".sqlite")]
    (sys/remove path)
    (try (f path)
         (finally (run! #(when (sys/file-exists %) (sys/remove %))
                        [path (store/staging-path path)])))))

(defmacro transit-data [form]
  `(literal/build {:map transit/Map :vector transit/Array :keyword transit/Keyword
                   :string transit/String :int transit/Int} ~form))

(defn fixture-rows []
  (let [root (transit-data
               {:schema {:block/uuid {:db/valueType :db.type/uuid}
                         :block/parent {:db/valueType :db.type/ref}
                         :block/tags {:db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
                         :block/type {:db/valueType :db.type/keyword}
                         :block/created-at {} :block/properties {}}
                :max-eid 12 :max-tx 536870930 :eavt 2 :aevt 3 :avet 4
                :max-addr 4 :branching-factor 512 :ref-type :soft})
        node (transit-data
               {:keys [[10 :block/created-at (unquote (transit/Int64 (int64/of-int 1723012345678))) 536870930]
                       [10 :block/parent 11 536870930]
                       [10 :block/properties {:priority :A} 536870930]
                       [10 :block/tags 11 536870930] [10 :block/tags 12 536870930]
                       [10 :block/type :whiteboard 536870930]
                       [10 :block/uuid (unquote (transit/Tagged "u" (transit/String "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8"))) 536870930]]})]
    (mapv (fn [[addr value]]
            (record snapshot/snapshot-row
                    (addr addr) (content (transit/to-string :mode (transit/Verbose) value)) (addresses None)))
          [(tuple 0 root) (tuple 1 (transit/Array (list))) (tuple 2 node) (tuple 3 node) (tuple 4 node)])))

(defn activate [path rows]
  (expect-ok (store/begin-import path))
  (expect-ok (store/append-rows path (apply list rows)))
  (expect-ok (store/activate path)))

(defn values [db attr]
  (mapv :v (db-api/datoms db (ds/Eavt) :e 10 :a attr)))

(deftest staging-activation-preserves-content-and-sql-null
  (with-store
    (fn [path]
      (store/storage path)
      (expect-ok (store/append-rows path (list)))
      (is (not (sys/file-exists (store/staging-path path))))
      (is (match (store/activate path) (Error _) true (Ok _) false))
      (let [root "[\"^ \",\"~:schema\",[\"^ \",\"~:block/title\",[\"^ \",\"~:db/valueType\",\"~:db.type/string\"]]]"
            node "[\"^ \",\"~:keys\",[]]"]
        (activate path [(record snapshot/snapshot-row (addr 0) (content root) (addresses None))
                        (record snapshot/snapshot-row (addr 1) (content "[]") (addresses None))
                        (record snapshot/snapshot-row (addr 7) (content node) (addresses (Some "[3,4]")))])
        (is (not (sys/file-exists (store/staging-path path))))
        (is (= (Some (tuple root None)) (expect-ok (store/read-row path 0))))
        (is (= (Some (tuple node (Some "[3,4]"))) (expect-ok (store/read-row path 7))))))))

(deftest typed-restore-and-writable-connection-persist
  (with-store
    (fn [path]
      (activate path (fixture-rows))
      (let [db (expect-ok (store/restore-db path))]
        (is (= [(ds/Uuid "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8")] (values db "block/uuid")))
        (is (= [(ds/Ref 11)] (values db "block/parent")))
        (is (= [(ds/Keyword "whiteboard")] (values db "block/type")))
        (is (= [(ds/Int 1723012345678)] (values db "block/created-at")))
        (is (= [(ds/Map (list (tuple (ds/Keyword "priority") (ds/Keyword "A"))))] (values db "block/properties")))
        (is (= [(ds/Ref 11) (ds/Ref 12)] (values db "block/tags")))
        (let [schema (into {} (ds/schema db))
              tags (get schema "block/tags")]
          (is (= (Some (ds/Many)) (some-> tags :cardinality)))
          (is (= (Some (ds/RefType)) (some-> tags :value-type)))))
      (let [conn (expect-ok (store/restore-conn path))]
        (ds/transact-conn conn (list (ds/Add (ds/Entity_id 10) "block/type" (ds/Keyword "page"))))
        (is (= [(ds/Keyword "page")] (values (expect-ok (store/restore-db path)) "block/type")))))))

(deftest snapshot-reader-isolation-and-write-invalidation
  (with-store
    (fn [path]
      (let [rows (fixture-rows)]
        (activate path rows)
        (let [storage (store/storage path)
              original ((:storage-restore storage) "2")]
          (activate path (mapv #(assoc % :content (string/replace (:content %) "whiteboard" "canvas")) rows))
          (let [current (store/storage path)]
            (is (not= original ((:storage-restore current) "2")))
            (is (= original ((:storage-restore storage) "2")))
            (match original
              (Some node) ((:storage-store current) (list (tuple "2" node)))
              None (stdlib/failwith "fixture node missing"))
            (is (= original ((:storage-restore current) "2")))
            ((:storage-delete current) (list "2"))
            (is (nil? ((:storage-restore current) "2")))
            (gc/full-major)))))))
