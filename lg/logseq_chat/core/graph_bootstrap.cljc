(ns logseq-chat.graph-bootstrap
  (:require [logseq-chat.graph-bootstrap-data :as data]
            [logseq-chat.storage-codec :as codec]
            [logseq-chat.snapshot :as snapshot]
            [logseq-chat.api :as api]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Datascript.Built_ins :as built-ins]
            [ocaml.Persistent_sorted_set :as pset]
            [ocaml.Transit_native.Transit.Json :as transit]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.String :as bytes]
            [ocaml.Char :as char]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Stdlib :as stdlib]))

(type-record prepared-snapshot (file-path :string) (row-count :int) (checksum :string))

(def schema-version data/schema-version)
(def initial-checksum "0000000000000000")

(defn fresh-local-graph-uuid []
  (match (ds/squuid)
    (ds/Uuid uuid) (str "00000000" (subs uuid 8))
    _ (throw (Failure "Datascript.squuid returned a non-UUID value"))))

(def schema
  (let [one codec/default-schema-attr
        indexed (assoc one :indexed true)
        identity (assoc one :unique (Some (ds/Identity)))
        ref (assoc one :value-type (Some (ds/RefType)))
        indexed-ref (assoc ref :indexed true)
        many-ref (assoc ref :cardinality (ds/Many))]
    {"db/ident" identity "kv/value" one "block/uuid" identity
     "block/parent" indexed-ref "block/order" indexed "block/collapsed?" one
     "block/page" indexed-ref "block/refs" many-ref "block/tags" many-ref
     "block/link" indexed-ref "block/alias" (assoc many-ref :indexed true)
     "block/created-at" indexed "block/updated-at" indexed "block/name" indexed
     "block/title" indexed "block/journal-day" indexed "block/tx-id" one
     "block/closed-value-property" many-ref "file/path" identity "file/content" one
     "file/created-at" one "file/last-modified-at" one "file/size" one}))

(def native-schema (rrbvec/to-list (vec schema)))

(defn kv [ident value]
  (ds/Entity (record Datascript.tx_entity
               (db-id nil)
               (attrs (list (tuple "db/ident" (ds/One_value (ds/Keyword ident)))
                            (tuple "kv/value" (ds/One_value value)))))))

(defn graph-metadata [graph-id e2ee now]
  [(kv "logseq.kv/graph-uuid" (ds/Uuid graph-id))
   (kv "logseq.kv/graph-remote?" (ds/Bool true))
   (kv "logseq.kv/graph-rtc-e2ee?" (ds/Bool e2ee))
   (kv "logseq.kv/graph-created-at" (ds/Int now))
   (kv "logseq.kv/local-graph-uuid" (ds/Uuid (fresh-local-graph-uuid)))])

(defn scalar-tx-value [value]
  (match value
    (ds/One_value value) value
    (ds/Many_values values) (ds/Set values)
    (ds/One_entity entity)
    (ds/Map (rrbvec/to-list
              (mapv (fn [[attr value]] (tuple (ds/Keyword attr) (scalar-tx-value value))) (:attrs entity))))
    (ds/Many_entities entities)
    (ds/Vector (rrbvec/to-list (mapv (fn [entity] (scalar-tx-value (ds/One_entity entity))) entities)))))

(defn normalize-scalar-maps [tx]
  (match tx
    (ds/Entity entity)
    (ds/Entity (assoc entity :attrs
      (rrbvec/to-list
        (mapv (fn [[attr value]]
                (tuple attr
                  (if (contains? #{"kv/value" "logseq.property/icon"} attr)
                    (match value
                      (ds/One_entity _) (ds/One_value (scalar-tx-value value))
                      (ds/Many_entities _) (ds/One_value (scalar-tx-value value))
                      _ value)
                    value)))
              (:attrs entity)))))
    _ tx))

(defn valid-ref-value? [value]
  (match value
    (ds/TxRef) true (ds/Ref _) true (ds/Ref_to _) true
    (ds/Int _) true (ds/String _) true (ds/Keyword _) true
    (ds/Symbol value) (contains? #{"db/current-tx" "datomic.tx" "datascript.tx"} value)
    (ds/List [key _]) (match key (ds/Keyword _) true (ds/String _) true (ds/Symbol _) true _ false)
    (ds/Vector [key _]) (match key (ds/Keyword _) true (ds/String _) true (ds/Symbol _) true _ false)
    _ false))

(defn validate-ref [attr value]
  (when (not (valid-ref-value? value))
    (throw (Invalid_argument
      (str "invalid initial reference for " attr ": " (built-ins/print-query-value :readably true value))))))

(defn validate-ref-values [tx]
  (match tx
    (ds/Entity entity)
    (run! (fn [[attr value]]
            (if-some [definition (get schema attr)]
              (when (= (:value-type definition) (Some (ds/RefType)))
                (let [many (= (:cardinality definition) (ds/Many))]
                  (match value
                    (ds/One_value value)
                    (match value
                      (ds/List values) (if many (run! (fn [value] (validate-ref attr value)) values) (validate-ref attr value))
                      (ds/Vector values) (if many (run! (fn [value] (validate-ref attr value)) values) (validate-ref attr value))
                      (ds/Set values) (if many (run! (fn [value] (validate-ref attr value)) values) (validate-ref attr value))
                      _ (validate-ref attr value))
                    (ds/Many_values values) (run! (fn [value] (validate-ref attr value)) values)
                    _ nil)))
              nil))
          (:attrs entity))
    _ nil))

(defn unique-identity-attr? [attr]
  (if-some [definition (get schema attr)] (= (:unique definition) (Some (ds/Identity))) false))

(defn identity-only [tx]
  (match tx
    (ds/Entity entity)
    (let [attrs (filterv (fn [[attr _]] (unique-identity-attr? attr)) (:attrs entity))]
      (when (not (empty? attrs))
        (ds/Entity (assoc entity :db-id nil :attrs (rrbvec/to-list attrs)))))
    _ nil))

(defn schema-definition-attr? [attr]
  (contains? #{"db/valueType" "db/cardinality" "db/index" "db/unique" "db/isComponent"
               "db/noHistory" "db/tupleAttrs" "db/tupleTypes" "db/doc"} attr))

(defn schema-definition-only [tx]
  (match tx
    (ds/Entity entity)
    (let [attrs (filterv (fn [[attr _]] (or (unique-identity-attr? attr) (schema-definition-attr? attr))) (:attrs entity))]
      (when (some (fn [[attr _]] (schema-definition-attr? attr)) attrs)
        (ds/Entity (assoc entity :db-id nil :attrs (rrbvec/to-list attrs)))))
    _ nil))

(defn unique-ref-key? [schema key]
  (let [attr (match key (ds/Keyword attr) (Some attr) (ds/String attr) (Some attr) (ds/Symbol attr) (Some attr) _ nil)]
    (if-some [attr attr]
      (if-some [definition (get schema attr)] (some? (:unique definition)) false)
      false)))

(defn lookup-ref-collection? [schema values]
  (and (= (count values) 2)
       (if-some [key (first values)] (unique-ref-key? schema key) false)))

(defn normalize-many-attributes [^:map<string;Datascript.schema_attr> schema tx]
  (match tx
    (ds/Entity entity)
    (ds/Entity (assoc entity :attrs
      (rrbvec/to-list
        (mapv (fn [[attr value]]
                (tuple attr
                  (if-some [definition (get schema attr)]
                    (if (= (:cardinality definition) (ds/Many))
                      (match value
                        (ds/One_value (ds/Set values)) (ds/Many_values values)
                        (ds/One_value (ds/List values))
                        (if (lookup-ref-collection? schema values) value (ds/Many_values values))
                        (ds/One_value (ds/Vector values))
                        (if (lookup-ref-collection? schema values) value (ds/Many_values values))
                        _ value)
                      value)
                    value)))
              (:attrs entity)))))
    _ tx))

(defn refresh-initial-timestamps [now tx]
  (match tx
    (ds/Entity entity)
    (ds/Entity (assoc entity :attrs
      (rrbvec/to-list
        (mapv (fn [[attr value]]
                (tuple attr
                  (cond
                    (contains? #{"block/created-at" "block/updated-at"} attr) (ds/One_value (ds/Int now))
                    (contains? #{"file/created-at" "file/last-modified-at"} attr) (ds/One_value (ds/Instant now))
                    :else value)))
              (:attrs entity)))))
    _ tx))

(defn encrypt-database [encrypt-text db]
  (let [datoms (vec (db-api/datoms db (ds/Eavt)))]
    (loop [index 0 encrypted []]
      (if (= index (count datoms))
        (Ok encrypted)
        (let [datom (nth datoms index)]
          (if (and (:added datom) (contains? #{"block/title" "block/name"} (:a datom)))
            (match (:v datom)
              (ds/String value)
              (let* [value (encrypt-text value)]
                (recur (inc index) (conj encrypted (assoc datom :v (ds/String value)))))
              _ (recur (inc index) (conj encrypted datom)))
            (recur (inc index) (conj encrypted datom))))))))

(defn install-canonical-entities [initial-tx storage]
  (try
    (let [identities (rrbvec/to-list (vec (keep identity-only initial-tx)))
          definitions (rrbvec/to-list (vec (keep schema-definition-only initial-tx)))
          identified (ds/db-with identities (ds/empty-db :schema native-schema :storage storage))
          schematized (ds/db-with definitions identified)
          installed-schema (into {} (ds/schema schematized))]
      (ds/db-with (rrbvec/to-list (mapv (fn [tx] (normalize-many-attributes installed-schema tx)) initial-tx)) schematized))
    (catch error (throw (Failure (str "transact canonical entities: " (Printexc/to-string error)))))))

(defn database [graph-id e2ee encrypt-text]
  (try
    (let [now (api/epoch-ms)
          storage (ds/memory-storage)
          initial-tx (mapv (fn [tx] (refresh-initial-timestamps now (normalize-scalar-maps tx)))
                           (ds/parse-tx-data-string data/transaction-edn))]
      (run! validate-ref-values initial-tx)
      (let [initial (install-canonical-entities initial-tx storage)
            plain (try (ds/db-with (rrbvec/to-list (graph-metadata graph-id e2ee now)) initial)
                    (catch error (throw (Failure (str "transact graph metadata: " (Printexc/to-string error))))))]
        (if e2ee
          (let* [datoms (encrypt-database encrypt-text plain)]
            (let [encrypted (ds/init-db :schema (ds/schema plain) :storage (ds/memory-storage) (rrbvec/to-list datoms))]
              (ds/store encrypted)
              (Ok encrypted)))
          (Ok plain))))
    (catch error (Error (str "prepare canonical graph: " (Printexc/to-string error))))))

(defn index-shift [^:Datascript.storage storage ^:string address]
  (match ((:storage-restore storage) address)
    (Some (ds/Storage_node (pset/Leaf _))) 0
    (Some (ds/Storage_node (pset/Branch _ children)))
    (let [shifts (mapv (fn [child] (index-shift storage child)) children)]
      (when (empty? shifts) (throw (Invalid_argument "DataScript storage branch has no children")))
      (let [first-shift (nth shifts 0)]
        (when (not (every? (fn [shift] (= first-shift shift)) shifts))
          (throw (Invalid_argument "DataScript storage index is not balanced")))
        (inc first-shift)))
    (Some _) (throw (Invalid_argument (str "DataScript index address is not a node: " address)))
    None (throw (Invalid_argument (str "missing DataScript storage address " address)))))

(defn root-index-metadata [db storage root]
  (record codec/storage-root-index-metadata
    (eavt (record codec/storage-index-metadata (count (pset/count (:eavt-index db))) (shift (index-shift storage (:storage-eavt root)))))
    (aevt (record codec/storage-index-metadata (count (pset/count (:aevt-index db))) (shift (index-shift storage (:storage-aevt root)))))
    (avet (record codec/storage-index-metadata (count (pset/count (:avet-index db))) (shift (index-shift storage (:storage-avet root)))))))

(defn storage-row [db storage address]
  (let [addr (stdlib/int-of-string address)]
    (if-some [payload ((:storage-restore storage) address)]
      (let [metadata (match payload (ds/Storage_root root) (Some (root-index-metadata db storage root)) _ nil)
            [content addresses] (codec/encode metadata payload)]
        (record snapshot/snapshot-row (addr addr) (content content) (addresses addresses)))
      (throw (Invalid_argument (str "missing DataScript storage address " address))))))

(defn snapshot-rows [db]
  (try
    (ds/store db)
    (if-some [storage (ds/storage db)]
      (Ok (rrbvec/to-list
            (vec (sort-by :addr (mapv (fn [address] (storage-row db storage address))
                                     ((:storage-list-addresses storage)))))))
      (Error "canonical graph has no DataScript storage"))
    (catch error (Error (str "encode canonical graph snapshot: " (Printexc/to-string error))))))

(defn frame-rows [rows]
  (let [payload (transit/to-string
                  (transit/Array
                    (rrbvec/to-list
                      (mapv (fn [row]
                              (transit/Array
                                (list (transit/Int (:addr row)) (transit/String (:content row))
                                      (if-some [addresses (:addresses row)] (transit/String addresses) (transit/Null)))))
                            rows))))
        length (count payload)
        prefix (bytes/init 4 (fn [index] (char/chr (bit-and (bit-shift-right length (* (- 3 index) 8)) 255))))]
    (str prefix payload)))

(defn prepare [graph-id e2ee encrypt-text]
  (let* [db (database graph-id e2ee encrypt-text)
         rows (snapshot-rows db)]
    (let [path (filename/temp-file "logseq-chat-initial-" ".snapshot")]
      (try
        (let [channel (stdlib/open-out-bin path)]
          (try (stdlib/output-string channel (frame-rows rows))
            (finally (stdlib/close-out-noerr channel))))
        (Ok (record prepared-snapshot (file-path path) (row-count (count rows)) (checksum initial-checksum)))
        (catch error
          (try (sys/remove path) (catch _ nil))
          (Error (str "write canonical graph snapshot: " (Printexc/to-string error))))))))
