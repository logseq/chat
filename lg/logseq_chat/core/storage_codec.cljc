(ns logseq-chat.storage-codec
  (:require [ocaml.package/datascript-ocaml-native]
            [ocaml.package/persistent_sorted_set_ocaml]
            [ocaml.package/melange-transit-native]
            [ocaml.package/yojson]
            [ocaml.Datascript :as ds]
            [ocaml.Persistent_sorted_set :as pset]
            [ocaml.Transit_native.Transit.Json :as transit]
            [ocaml.Yojson.Safe :as json]
            [ocaml.Int64 :as int64]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Rrbvec :as rrbvec]))

(type-record storage-index-metadata (count :int) (shift :int))
(type-record storage-root-index-metadata
  (eavt :storage-index-metadata)
  (aevt :storage-index-metadata)
  (avet :storage-index-metadata))

(def default-schema-attr
  (record Datascript.schema_attr
    (cardinality (ds/One)) (unique None) (indexed false) (is-component false)
    (no-history false) (doc None) (value-type None) (tuple-attrs None) (tuple-types None)))

(defn string-of-key [input]
  (match input
    (transit/Keyword text) (Some text)
    (transit/String text) (Some text)
    _ None))

(defn keyword-value [input]
  (match input (transit/Keyword text) (Some text) _ None))

(defn lookup [key entries]
  (let [entries (rrbvec/of-list entries)]
    (loop [index 0]
      (if (= index (count entries))
        None
        (let [[entry-key value] (nth entries index)]
          (if (= (string-of-key entry-key) (Some key))
            (Some value)
            (recur (inc index))))))))

(defn int-value [input]
  (match input
    (transit/Int number) (Some number)
    (transit/Int64 number)
    (if (and (>= number (int64/of-int stdlib/min-int))
             (<= number (int64/of-int stdlib/max-int)))
      (Some (int64/to-int number))
      None)
    _ None))

(defn required [key entries]
  (match (lookup key entries)
    (Some value) value
    None (stdlib/invalid-arg (str "Logseq storage payload is missing :" key))))

(defn required-int [label input]
  (match (int-value input)
    (Some number) number
    None (stdlib/invalid-arg (str label " must be a Transit integer"))))

(defn cardinality-of-transit [input]
  (match input (transit/Keyword "db.cardinality/many") (ds/Many) _ (ds/One)))

(defn unique-of-transit [input]
  (match input
    (transit/Keyword "db.unique/value") (Some (ds/Value))
    (transit/Keyword "db.unique/identity") (Some (ds/Identity))
    _ None))

(defn value-type-of-transit [input]
  (match input
    (transit/Keyword "db.type/ref") (Some (ds/RefType))
    (transit/Keyword "db.type/tuple") (Some (ds/TupleType))
    (transit/Keyword "db.type/string") (Some (ds/StringType))
    (transit/Keyword "db.type/keyword") (Some (ds/KeywordType))
    (transit/Keyword "db.type/number") (Some (ds/NumberType))
    (transit/Keyword "db.type/uuid") (Some (ds/UuidType))
    (transit/Keyword "db.type/instant") (Some (ds/InstantType))
    _ None))

(defn value-type-to-transit [input]
  (match input
    (ds/RefType) (transit/Keyword "db.type/ref")
    (ds/TupleType) (transit/Keyword "db.type/tuple")
    (ds/StringType) (transit/Keyword "db.type/string")
    (ds/KeywordType) (transit/Keyword "db.type/keyword")
    (ds/NumberType) (transit/Keyword "db.type/number")
    (ds/UuidType) (transit/Keyword "db.type/uuid")
    (ds/InstantType) (transit/Keyword "db.type/instant")))

(defn tuple-attrs [input]
  (match input
    (transit/Array values) (Some (rrbvec/to-list (vec (keep keyword-value values))))
    (transit/List values) (Some (rrbvec/to-list (vec (keep keyword-value values))))
    _ None))

(defn valid-tuple-types [values]
  (let [types (vec (keep value-type-of-transit values))]
    (if (= (count types) (count values)) (Some (rrbvec/to-list types)) None)))

(defn tuple-types [input]
  (match input
    (transit/Array values) (valid-tuple-types values)
    (transit/List values) (valid-tuple-types values)
    _ None))

(defn schema-attr-of-transit [input]
  (match input
    (transit/Map props)
    (reduce
     (fn [attr [key value]]
       (match (keyword-value key)
         (Some "db/cardinality") (assoc attr :cardinality (cardinality-of-transit value))
         (Some "db/unique") (assoc attr :unique (unique-of-transit value))
         (Some "db/index") (assoc attr :indexed (= value (transit/Bool true)))
         (Some "db/isComponent") (assoc attr :is-component (= value (transit/Bool true)))
         (Some "db/noHistory") (assoc attr :no-history (= value (transit/Bool true)))
         (Some "db/doc") (assoc attr :doc (match value (transit/String text) (Some text) _ None))
         (Some "db/valueType") (assoc attr :value-type (value-type-of-transit value))
         (Some "db/tupleAttrs") (assoc attr :tuple-attrs (tuple-attrs value))
         (Some "db/tupleTypes") (assoc attr :tuple-types (tuple-types value))
         _ attr))
     default-schema-attr props)
    _ default-schema-attr))

(defn schema-of-transit [input]
  (match input
    (transit/Map entries)
    (rrbvec/to-list
     (vec (keep (fn [[name attr]]
                  (match (keyword-value name)
                    (Some name) (Some (tuple name (schema-attr-of-transit attr)))
                    None None))
                entries)))
    _ (list)))

(defn transit-of-cardinality [input]
  (match input (ds/One) (transit/Keyword "db.cardinality/one") (ds/Many) (transit/Keyword "db.cardinality/many")))

(defn transit-of-unique [input]
  (match input (ds/Value) (transit/Keyword "db.unique/value") (ds/Identity) (transit/Keyword "db.unique/identity")))

(defn schema-attr-to-transit [^:Datascript.schema_attr attr]
  (let [entries []
        entries (if (not= (:cardinality attr) (ds/One))
                  (conj entries (tuple (transit/Keyword "db/cardinality") (transit-of-cardinality (:cardinality attr)))) entries)
        entries (match (:unique attr)
                  (Some value) (conj entries (tuple (transit/Keyword "db/unique") (transit-of-unique value)))
                  None entries)
        entries (if (:indexed attr) (conj entries (tuple (transit/Keyword "db/index") (transit/Bool true))) entries)
        entries (if (:is-component attr) (conj entries (tuple (transit/Keyword "db/isComponent") (transit/Bool true))) entries)
        entries (if (:no-history attr) (conj entries (tuple (transit/Keyword "db/noHistory") (transit/Bool true))) entries)
        entries (match (:doc attr)
                  (Some text) (conj entries (tuple (transit/Keyword "db/doc") (transit/String text)))
                  None entries)
        entries (match (:value-type attr)
                  (Some value) (conj entries (tuple (transit/Keyword "db/valueType") (value-type-to-transit value)))
                  None entries)
        entries (match (:tuple-attrs attr)
                  (Some values) (conj entries (tuple (transit/Keyword "db/tupleAttrs")
                                                    (transit/Array (rrbvec/to-list (mapv (fn [text] (transit/Keyword text)) values)))))
                  None entries)
        entries (match (:tuple-types attr)
                  (Some values) (conj entries (tuple (transit/Keyword "db/tupleTypes")
                                                    (transit/Array (rrbvec/to-list (mapv value-type-to-transit values)))))
                  None entries)]
    (transit/Map (rrbvec/to-list entries))))

(defn schema-to-transit [^:Datascript.schema schema]
  (transit/Map (rrbvec/to-list (mapv (fn [[name attr]] (tuple (transit/Keyword name) (schema-attr-to-transit attr))) schema))))

(defn value-of-transit [input]
  (match input
    (transit/Null) (ds/Nil)
    (transit/Bool value) (ds/Bool value)
    (transit/String value) (ds/String value)
    (transit/Int value) (ds/Int value)
    (transit/Int64 value) (ds/Int (int64/to-int value))
    (transit/Float value) (ds/Float value)
    (transit/Binary value) (ds/String value)
    (transit/Big_decimal value) (ds/Float (stdlib/float-of-string value))
    (transit/Big_int value) (ds/Int (int64/to-int (int64/of-string value)))
    (transit/Date value) (ds/Instant (int64/to-int value))
    (transit/Uuid value) (ds/Uuid value)
    (transit/Uri value) (ds/String value)
    (transit/Keyword value) (ds/Keyword value)
    (transit/Symbol value) (ds/Symbol value)
    (transit/Array values) (ds/Vector (rrbvec/to-list (mapv value-of-transit values)))
    (transit/Map entries) (ds/Map (rrbvec/to-list (mapv (fn [[key value]] (tuple (value-of-transit key) (value-of-transit value))) entries)))
    (transit/Set values) (ds/Set (rrbvec/to-list (mapv value-of-transit values)))
    (transit/List values) (ds/List (rrbvec/to-list (mapv value-of-transit values)))
    (transit/Tagged "u" (transit/String value)) (ds/Uuid value)
    (transit/Tagged "m" (transit/Int value)) (ds/Instant value)
    (transit/Tagged "m" (transit/Int64 value)) (ds/Instant (int64/to-int value))
    (transit/Tagged "regex" (transit/String value)) (ds/Regex value)
    (transit/Tagged tag value) (ds/Vector (list (ds/String tag) (value-of-transit value)))))

(defn value-to-transit [input]
  (match input
    (ds/Nil) (transit/Null)
    (ds/Int value) (transit/Int value)
    (ds/Float value) (transit/Float value)
    (ds/String value) (transit/String value)
    (ds/Symbol value) (transit/Symbol value)
    (ds/Bool value) (transit/Bool value)
    (ds/Keyword value) (transit/Keyword value)
    (ds/Uuid value) (transit/Tagged "u" (transit/String value))
    (ds/Instant value) (transit/Tagged "m" (transit/Int value))
    (ds/Regex value) (transit/Tagged "regex" (transit/String value))
    (ds/Ref value) (transit/Int value)
    (ds/List values) (transit/List (rrbvec/to-list (mapv value-to-transit values)))
    (ds/Vector values) (transit/Array (rrbvec/to-list (mapv value-to-transit values)))
    (ds/Map entries) (transit/Map (rrbvec/to-list (mapv (fn [[key value]] (tuple (value-to-transit key) (value-to-transit value))) entries)))
    (ds/Set values) (transit/Set (rrbvec/to-list (mapv value-to-transit values)))
    (ds/Tuple values) (transit/Array (rrbvec/to-list (mapv (fn [value] (match value None (transit/Null) (Some value) (value-to-transit value))) values)))
    (ds/TxRef) (transit/Keyword "db/current-tx")
    (ds/Ref_to _) (stdlib/invalid-arg "storage payload cannot contain unresolved refs")))

(defn datom-of-transit [input]
  (match input
    (transit/Array [entity attr value tx])
    (let [e (required-int "datom entity" entity)
          a (match (keyword-value attr)
              (Some attr) attr
              None (stdlib/invalid-arg "storage datom attr must be a Transit keyword"))
          tx (required-int "datom tx" tx)]
      (record Datascript.datom (e e) (a a) (v (value-of-transit value)) (tx (abs tx)) (added (>= tx 0))))
    _ (stdlib/invalid-arg "storage datom must be [e a v tx]")))

(defn datom-to-transit [^:Datascript.datom datom]
  (transit/Array (list (transit/Int (:e datom))
                       (transit/Keyword (:a datom))
                       (value-to-transit (:v datom))
                       (transit/Int (if (:added datom) (:tx datom) (- 0 (:tx datom)))))))

(defn datoms-of-transit [input]
  (match input
    (transit/Array values) (rrbvec/to-list (mapv datom-of-transit values))
    (transit/List values) (rrbvec/to-list (mapv datom-of-transit values))
    _ (stdlib/invalid-arg "storage datoms must be a Transit array")))

(defn address-of-transit [label input]
  (match input
    (transit/Int value) (stdlib/string-of-int value)
    (transit/Int64 value) (int64/to-string value)
    (transit/String value) value
    _ (stdlib/invalid-arg (str label " must be a storage address"))))

(defn address-to-transit [address]
  (match (stdlib/int-of-string-opt address)
    (Some number) (transit/Int number)
    None (stdlib/invalid-arg (str "Logseq SQLite storage address is not an integer: " address))))

(defn address-of-json [input]
  (match input
    (tag Int number) (stdlib/string-of-int number)
    (tag Intlit text) text
    _ (stdlib/invalid-arg "Logseq storage addresses must be integers")))

(defn addresses-of-json [addresses]
  (match addresses
    None (list)
    (Some source)
    (match (json/from-string source)
      (tag List values)
      (rrbvec/to-list (mapv address-of-json values))
      _ (stdlib/invalid-arg "Logseq storage addresses must be a JSON array"))))

(defn address-to-json [address]
  (match (stdlib/int-of-string-opt address)
    (Some number) (tag Int number)
    None (stdlib/invalid-arg "Logseq storage child address is not an integer")))

(defn addresses-to-json [addresses]
  (json/to-string (tag List (rrbvec/to-list (mapv address-to-json addresses)))))

(defn root-of-transit [entries]
  (record Datascript.storage_root
    (storage-schema (schema-of-transit (required "schema" entries)))
    (storage-max-eid (required-int "root :max-eid" (required "max-eid" entries)))
    (storage-max-tx (required-int "root :max-tx" (required "max-tx" entries)))
    (storage-eavt (address-of-transit "root :eavt" (required "eavt" entries)))
    (storage-aevt (address-of-transit "root :aevt" (required "aevt" entries)))
    (storage-avet (address-of-transit "root :avet" (required "avet" entries)))
    (storage-duplicate-datoms (match (lookup "duplicate-datoms" entries) None (list) (Some value) (datoms-of-transit value)))
    (storage-max-addr (required-int "root :max-addr" (required "max-addr" entries)))
    (storage-branching-factor (required-int "root :branching-factor" (required "branching-factor" entries)))
    (storage-ref-type (match (required "ref-type" entries)
                        (transit/Keyword "soft") (pset/Weak)
                        (transit/Keyword "weak") (pset/Weak)
                        _ (pset/Strong)))))

(defn index-metadata-to-transit [metadata]
  (transit/Map (list (tuple (transit/Keyword "count") (transit/Int (:count metadata)))
                     (tuple (transit/Keyword "shift") (transit/Int (:shift metadata))))))

(defn root-to-transit [index-metadata ^:Datascript.storage_root root]
  (let [metadata (match index-metadata
                   None []
                   (Some metadata)
                   [(tuple (transit/Keyword "eavt-metadata") (index-metadata-to-transit (:eavt metadata)))
                    (tuple (transit/Keyword "aevt-metadata") (index-metadata-to-transit (:aevt metadata)))
                    (tuple (transit/Keyword "avet-metadata") (index-metadata-to-transit (:avet metadata)))])]
    (transit/Map
     (rrbvec/to-list
      (into
       (into [(tuple (transit/Keyword "schema") (schema-to-transit (:storage-schema root)))
              (tuple (transit/Keyword "max-eid") (transit/Int (:storage-max-eid root)))
              (tuple (transit/Keyword "max-tx") (transit/Int (:storage-max-tx root)))
              (tuple (transit/Keyword "eavt") (address-to-transit (:storage-eavt root)))
              (tuple (transit/Keyword "aevt") (address-to-transit (:storage-aevt root)))
              (tuple (transit/Keyword "avet") (address-to-transit (:storage-avet root)))] metadata)
       [(tuple (transit/Keyword "duplicate-datoms") (transit/Array (rrbvec/to-list (mapv datom-to-transit (:storage-duplicate-datoms root)))))
        (tuple (transit/Keyword "max-addr") (transit/Int (:storage-max-addr root)))
        (tuple (transit/Keyword "branching-factor") (transit/Int (:storage-branching-factor root)))
        (tuple (transit/Keyword "ref-type") (transit/Keyword (match (:storage-ref-type root) (pset/Weak) "soft" (pset/Strong) "strong")))])))))

(defn decode [addresses content]
  (match (transit/of-string content)
    (transit/Map entries)
    (cond
      (some? (lookup "schema" entries)) (ds/Storage_root (root-of-transit entries))
      (some? (lookup "keys" entries))
      (let [keys (datoms-of-transit (required "keys" entries))
            children (addresses-of-json addresses)]
        (ds/Storage_node (if (empty? children) (pset/Leaf keys) (pset/Branch keys children))))
      :else (stdlib/invalid-arg "unknown Logseq storage payload"))
    (transit/Array groups) (ds/Storage_tail (rrbvec/to-list (mapv datoms-of-transit groups)))
    (transit/List groups) (ds/Storage_tail (rrbvec/to-list (mapv datoms-of-transit groups)))
    _ (stdlib/invalid-arg "unknown Logseq storage payload")))

(defn encode-node [datoms]
  (transit/to-string :mode (transit/Verbose)
                     (transit/Map (list (tuple (transit/Keyword "keys")
                                              (transit/Array (rrbvec/to-list (mapv datom-to-transit datoms))))))))

(defn encode [root-index-metadata payload]
  (match payload
    (ds/Storage_root root)
    (tuple (transit/to-string :mode (transit/Verbose) (root-to-transit root-index-metadata root)) None)
    (ds/Storage_node (pset/Leaf datoms)) (tuple (encode-node datoms) None)
    (ds/Storage_node (pset/Branch keys children)) (tuple (encode-node keys) (Some (addresses-to-json children)))
    (ds/Storage_tail groups)
    (tuple (transit/to-string :mode (transit/Verbose)
                              (transit/Array (rrbvec/to-list (mapv (fn [datoms] (transit/Array (rrbvec/to-list (mapv datom-to-transit datoms)))) groups)))) None)))
