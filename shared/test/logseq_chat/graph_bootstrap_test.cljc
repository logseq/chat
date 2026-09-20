(ns logseq-chat.graph-bootstrap-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.graph-bootstrap :as bootstrap]
            [logseq-chat.snapshot :as snapshot]
            [logseq-chat.storage-codec :as storage-codec]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.pending-projection :as projection]
            [ocaml.Transit_native.Transit.Json :as transit]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Datascript.Entity :as entity]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]))

(defn expect-ok [result]
  (match result (Ok value) value (Error message) (stdlib/failwith message)))

(defn canonical-db [encrypted]
  (expect-ok (bootstrap/database "625e5ba9-fa25-4385-ad8b-f47d0f844387" encrypted #(Ok (str "encrypted:" %)))))

(defn one-value [db ref attr]
  (some-> (ds/entity db ref)
          (entity/entity-attr-raw attr)
          ((fn [value] (match value (ds/One_value value) (Some value) _ None)))))

(defn kv-value [db ident]
  (some-> (ds/entid db "db/ident" (ds/Keyword ident))
          ((fn [eid] (one-value db (ds/Entity_id eid) "kv/value")))))

(defn transit-field [name input]
  (match input
    (transit/Map entries) (some (fn [[key value]] (when (= key (transit/Keyword name)) value)) entries)
    _ None))

(defn index-metadata [index root]
  (let [metadata (or (transit-field (str index "-metadata") root) (transit/Null))]
    (mapv (fn [field]
            (match (transit-field field metadata)
              (Some (transit/Int value)) value
              _ (stdlib/failwith (str "missing " index " metadata " field))))
          ["count" "shift"])))

(deftest encryption-is-optional-and-stops-at-first-failure
  (let [calls (atom 0)
        encrypt (fn [_] (swap! calls inc) (Error "encryption unavailable"))]
    (expect-ok (bootstrap/database "plain" false encrypt))
    (is (= 0 @calls))
    (is (= (Error "encryption unavailable") (bootstrap/database "encrypted" true encrypt)))
    (is (= 1 @calls))))

(deftest snapshots-roundtrip-all-datoms-and-schema
  (run! (fn [encrypted]
          (let [db (canonical-db encrypted)
                rows (expect-ok (bootstrap/snapshot-rows db))
                storage (ds/memory-storage)]
            ((:storage-store storage)
             (apply list (map (fn [row] (tuple (str (:addr row)) (storage-codec/decode (:addresses row) (:content row)))) rows)))
            (match (ds/restore storage)
              (Some restored)
              (do (is (= (ds/schema db) (ds/schema restored)))
                  (is (= (vec (db-api/datoms db (ds/Eavt))) (vec (db-api/datoms restored (ds/Eavt))))))
              None (stdlib/failwith "database was not restored"))))
        [false true]))

(deftest prepared-file-has-complete-frames-and-checksum
  (let [prepared (expect-ok (bootstrap/prepare "prepared" false (fn [_] (stdlib/failwith "plaintext snapshot must not encrypt"))))]
    (try
      (let [channel (stdlib/open-in-bin (:file-path prepared))
            wire (try (stdlib/really-input-string channel (stdlib/in-channel-length channel))
                      (finally (stdlib/close-in-noerr channel)))
            parser (snapshot/create-parser (* 2 1024 1024))
            rows (expect-ok (snapshot/feed parser wire))]
        (expect-ok (snapshot/finish-parser parser))
        (is (= (:row-count prepared) (count rows)))
        (is (= "0000000000000000" (:checksum prepared))))
      (finally (sys/remove (:file-path prepared))))))

(deftest built-in-catalog-and-graph-metadata
  (let [started (stdlib/int-of-float (* (unix/gettimeofday) 1000.0))
        db (canonical-db false)]
    (is (> (count (db-api/datoms db (ds/Aevt) :a "db/ident")) 45))
    (run! (fn [ident]
            (match (ds/entid db "db/ident" (ds/Keyword ident))
              (Some eid) (is (= (Some (ds/Bool true)) (one-value db (ds/Entity_id eid) "logseq.property/built-in?")))
              None (stdlib/failwith (str "missing built-in " ident))))
          ["logseq.class/Root" "logseq.class/Tag" "logseq.class/Property" "logseq.class/Page"
           "logseq.class/Journal" "logseq.class/Task" "logseq.class/Card" "logseq.class/Asset"
           "logseq.class/Code-block" "logseq.class/Quote-block" "logseq.class/Math-block"])
    (run! #(is (not (empty? (db-api/datoms db (ds/Aevt) :a "block/name" :v (ds/String %)))))
          ["$$$favorites" "$$$views" "recycle"])
    (is (= (Some (ds/Uuid "625e5ba9-fa25-4385-ad8b-f47d0f844387")) (kv-value db "logseq.kv/graph-uuid")))
    (is (= (Some (ds/Bool true)) (kv-value db "logseq.kv/graph-remote?")))
    (is (= (Some (ds/Bool false)) (kv-value db "logseq.kv/graph-rtc-e2ee?")))
    (match (kv-value db "logseq.kv/graph-created-at")
      (Some (ds/Int timestamp)) (is (>= timestamp started))
      _ (stdlib/failwith "missing graph creation timestamp"))
    (is (not= (kv-value db "logseq.kv/local-graph-uuid") (kv-value (canonical-db false) "logseq.kv/local-graph-uuid")))))

(deftest encryption-preserves-schema-and-protects-text
  (let [plain (canonical-db false)
        encrypted (canonical-db true)]
    (is (= (ds/schema plain) (ds/schema encrypted)))
    (run! (fn [db]
            (let [schema (into {} (ds/schema db))]
              (run! (fn [[attr cardinality]]
                      (match (get schema attr)
                        (Some installed)
                        (do (is (= cardinality (:cardinality installed)))
                            (is (= (Some (ds/RefType)) (:value-type installed))))
                        None (stdlib/failwith (str "missing schema " attr))))
                    [(tuple "block/tags" (ds/Many)) (tuple "logseq.property.class/extends" (ds/Many))
                     (tuple "logseq.property/status" (ds/One))])))
          [plain encrypted])
    (run! (fn [attr]
            (run! (fn [datom]
                    (match (:v datom)
                      (ds/String value) (is (string/starts-with? value "encrypted:"))
                      _ (stdlib/failwith "encrypted text is not a string")))
                  (db-api/datoms encrypted (ds/Aevt) :a attr)))
          ["block/title" "block/name"])))

(deftest fresh-graph-accepts-tag-creation
  (let [operation (record ops/pending-operation
                          (operation-id "create-tag") (base-t 0) (state ops/Queued)
                          (intent (ops/Create-tag (record ops/pending-create
                                                         (uuid "10000000-0000-0000-0000-000000000001")
                                                         (title "Card") (created-at 1)))))
        projected (projection/build 0 (canonical-db false) [operation])]
    (is (= (Some ops/Applied)
           (some (fn [[id state]] (when (= id "create-tag") state)) (:statuses projected))))
    (is (some? (ds/entid (:db projected) "block/uuid" (ds/Uuid "10000000-0000-0000-0000-000000000001"))))))

(deftest snapshot-index-metadata-and-framing
  (let [db (canonical-db false)
        rows (expect-ok (bootstrap/snapshot-rows db))
        root-row (or (some #(when (= (:addr %) 0) %) rows) (stdlib/failwith "missing root"))
        root (transit/of-string (:content root-row))
        [eavt-count eavt-shift] (index-metadata "eavt" root)
        [aevt-count aevt-shift] (index-metadata "aevt" root)
        [avet-count avet-shift] (index-metadata "avet" root)
        datom-count (count (db-api/datoms db (ds/Eavt)))
        parser (snapshot/create-parser (* 2 1024 1024))]
    (is (some #(= (:addr %) 1) rows))
    (is (= datom-count eavt-count))
    (is (= datom-count aevt-count))
    (is (and (> avet-count 0) (<= avet-count datom-count)))
    (is (> eavt-shift 0))
    (is (> aevt-shift 0))
    (is (>= avet-shift 0))
    (is (= (count rows) (count (expect-ok (snapshot/feed parser (bootstrap/frame-rows rows))))))
    (expect-ok (snapshot/finish-parser parser))))

(deftest empty-index-metadata
  (let [db (ds/empty-db :schema bootstrap/native-schema :storage (ds/memory-storage))
        rows (expect-ok (bootstrap/snapshot-rows db))
        root-row (or (some #(when (= (:addr %) 0) %) rows) (stdlib/failwith "missing root"))
        root (transit/of-string (:content root-row))]
    (run! #(is (= [0 0] (index-metadata % root))) ["eavt" "aevt" "avet"])))
