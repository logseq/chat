(ns logseq-chat.logseq-storage-codec-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.storage-codec :as codec]
            [ocaml.Datascript :as ds]
            [ocaml.Persistent_sorted_set :as pset]
            [ocaml.Transit_native.Transit.Json :as transit]
            [ocaml.Stdlib :as stdlib]))

(defn datom [value added]
  (record Datascript.datom (e 7) (a "block/title") (v value) (tx 42) (added added)))

(defn roundtrip [payload]
  (let [[content addresses] (codec/encode None payload)]
    (is (= payload (codec/decode addresses content)))))

(defn metadata-field [key node]
  (match node
    (transit/Map entries)
    (some (fn [[entry-key value]] (when (= entry-key (transit/Keyword key)) value)) entries)
    _ None))

(deftest compact-map-key-cache-is-not-shifted
  (match (codec/decode None "{\"~:keys\":[[1,\"~:block/title\",\"One\",1],[2,\"^1\",\"Two\",1]]}")
    (ds/Storage_node (pset/Leaf datoms))
    (is (= ["block/title" "block/title"] (mapv :a datoms)))
    _ (stdlib/failwith "unexpected storage node")))

(deftest all-value-types-and-storage-nodes-roundtrip
  (let [values [(ds/Nil) (ds/Bool false) (ds/String "text") (ds/Int 12) (ds/Float 1.5)
                (ds/Keyword "block/page") (ds/Uuid "00000000-0000-0000-0000-000000000007")
                (ds/Instant 123) (ds/Regex "a+") (ds/Symbol "x")
                (ds/Vector (list (ds/Int 1) (ds/Nil))) (ds/List (list (ds/String "item")))
                (ds/Map (list (tuple (ds/Keyword "x") (ds/Set (list (ds/Int 2))))))]
        datoms (apply list (mapv #(datom % false) values))]
    (roundtrip (ds/Storage_node (pset/Leaf datoms)))
    (roundtrip (ds/Storage_node (pset/Branch datoms (list "3" "4"))))
    (roundtrip (ds/Storage_tail (list datoms (list) (list (datom (ds/String "added") true)))))))

(defn root []
  (let [schema (assoc codec/default-schema-attr
                      :cardinality (ds/Many) :unique (Some (ds/Identity)) :indexed true
                      :is-component true :no-history true :doc (Some "description")
                      :value-type (Some (ds/TupleType)) :tuple-attrs (Some (list "block/page" "block/title"))
                      :tuple-types (Some (list (ds/RefType) (ds/StringType) (ds/KeywordType) (ds/NumberType)
                                               (ds/UuidType) (ds/InstantType) (ds/TupleType))))]
    (record Datascript.storage_root
            (storage-schema (list (tuple "user/tuple" schema))) (storage-max-eid 7) (storage-max-tx 42)
            (storage-eavt "3") (storage-aevt "4") (storage-avet "5")
            (storage-duplicate-datoms (list (datom (ds/String "duplicate") false)))
            (storage-max-addr 6) (storage-branching-factor 32) (storage-ref-type (pset/Weak)))))

(deftest roots-and-index-metadata-roundtrip
  (let [root (root)
        index (record codec/storage-index-metadata (count 4) (shift 1))
        metadata (record codec/storage-root-index-metadata (eavt index) (aevt index) (avet index))
        [content addresses] (codec/encode (Some metadata) (ds/Storage_root root))]
    (roundtrip (ds/Storage_root root))
    (roundtrip (ds/Storage_root (assoc root :storage-ref-type (pset/Strong))))
    (is (nil? addresses))
    (is (= (ds/Storage_root root) (codec/decode None content)))
    (let [decoded (transit/of-string content)]
      (run! (fn [key]
              (match (metadata-field key decoded)
                (Some node)
                (do (is (= (Some (transit/Int 4)) (metadata-field "count" node)))
                    (is (= (Some (transit/Int 1)) (metadata-field "shift" node))))
                _ (stdlib/failwith "missing index metadata")))
            ["eavt-metadata" "aevt-metadata" "avet-metadata"]))))

(deftest tuple-reference-normalization
  (let [[content _] (codec/encode None
                                  (ds/Storage_node (pset/Leaf (list (datom (ds/Tuple (list (Some (ds/Ref 9)) None)) true)))))]
    (is (= (ds/Storage_node (pset/Leaf (list (datom (ds/Vector (list (ds/Int 9) (ds/Nil))) true))))
           (codec/decode None content)))))

(deftest invalid-storage-is-rejected
  (is (thrown? Invalid_argument
               (codec/encode None (ds/Storage_node (pset/Leaf (list (datom (ds/Ref_to (ds/Entity_id 1)) true)))))))
  (is (thrown? Invalid_argument (codec/encode None (ds/Storage_node (pset/Branch (list) (list "invalid"))))))
  (is (thrown? Invalid_argument (codec/decode (Some "{}") "{\"~:keys\":[]}")))
  (run! #(is (thrown? Invalid_argument (codec/decode None %)))
        ["{\"~:keys\":[[1,\"block/title\",\"x\",1]]}" "{\"~:schema\":{}}" "null"]))
