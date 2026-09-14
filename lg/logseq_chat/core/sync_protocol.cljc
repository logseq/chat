(ns logseq-chat.sync-protocol
  (:require [ocaml.package/melange-transit-core]
            [ocaml.package/melange-transit-native]
            [ocaml.Int64 :as int64]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.Transit_core.Json :as value]
            [ocaml.Transit_native.Transit.Json :as codec]))

(type-record sync-entity
  (id :Transit_core.Json.value)
  (attrs :list<tuple<Transit_core.Json.value;Transit_core.Json.value>>))

(type-record sync-change-set
  (format-version :int)
  (graph-id :string)
  (schema-version :string)
  (t-before :int)
  (t :int)
  (upserts :list<sync-entity>)
  (deleted :list<Transit_core.Json.value>)
  (operation-ids :list<string>))

(type-record sync-reset
  (reason :string)
  (snapshot-required :bool))

(type-variant sync-event
  (Graph_changes :sync-change-set)
  (Reset :sync-reset))

(defn identity-uuid [identity]
  (match identity
    (value/Array [(value/Keyword "block/uuid") (value/Uuid uuid)])
    (Some uuid)
    _ None))

(defn changed-block-uuids [change]
  (into []
        (distinct
         (keep identity-uuid
               (concat (map :id (:upserts change)) (:deleted change))))))

(defn field [key ^:list<tuple<Transit_core.Json.value;Transit_core.Json.value>> fields]
  (some (fn [entry]
          (when (= (first entry) (value/Keyword key)) (second entry)))
        fields))

(defn required [key decode fields]
  (match (field key fields)
    (Some value) (decode value)
    None (Error (str "missing Transit field: " key))))

(defn as-int [input]
  (match input
    (value/Int number) (Ok number)
    (value/Int64 number)
    (if (and (>= number (int64/of-int Stdlib/min_int))
             (<= number (int64/of-int Stdlib/max_int)))
      (Ok (int64/to-int number))
      (Error "expected Transit integer"))
    _ (Error "expected Transit integer")))

(defn as-string [input]
  (match input
    (value/String text) (Ok text)
    _ (Error "expected Transit string")))

(defn as-bool [input]
  (match input
    (value/Bool value) (Ok value)
    _ (Error "expected Transit boolean")))

(defn as-array [input]
  (match input
    (value/Array values) (Ok values)
    _ (Error "expected Transit array")))

(defn as-map [input]
  (match input
    (value/Map fields) (Ok fields)
    _ (Error "expected Transit map")))

(defn as-identity [input]
  (match input
    (value/Array [(value/Keyword "block/uuid") (value/Uuid uuid)])
    (Ok (value/Array (list (value/Keyword "block/uuid") (value/Uuid uuid))))
    (value/Array [(value/Keyword "db/ident") (value/Keyword ident)])
    (Ok (value/Array (list (value/Keyword "db/ident") (value/Keyword ident))))
    (value/Array [(value/Keyword "file/path") (value/String path)])
    (Ok (value/Array (list (value/Keyword "file/path") (value/String path))))
    _ (Error "expected stable Transit lookup identity")))

(defn keyword-key? [^:tuple<Transit_core.Json.value;Transit_core.Json.value> entry]
  (match (first entry)
    (value/Keyword _) true
    _ false))

(defn all-keyword-keys? [fields]
  (every? keyword-key? fields))

(defn as-attrs [input]
  (match input
    (value/Map fields)
    (if (all-keyword-keys? fields)
      (Ok fields)
      (Error "expected Transit keyword attribute keys"))
    _ (Error "expected Transit attribute map")))

(defn decode-entity [input]
  (match (as-map input)
    (Ok fields)
    (match (tuple (required "id" as-identity fields)
                  (required "attrs" as-attrs fields))
      (tuple (Ok id) (Ok attrs))
      (Ok (record sync-entity
                  (id id)
                  (attrs attrs)))
      (tuple (Error message) _) (Error message)
      (tuple _ (Error message)) (Error message))
    (Error message) (Error message)))

(defn decode-entity-list-loop [values total index decoded]
  (if (= index total)
    (Ok (rrbvec/to-list decoded))
    (match (decode-entity (nth values index))
      (Ok entity)
      (decode-entity-list-loop values total (inc index) (conj decoded entity))
      (Error message) (Error message))))

(defn decode-entity-list [values]
  (let [values (rrbvec/of-list values)]
    (decode-entity-list-loop values (count values) 0 [])))

(defn decode-identity-list-loop [values total index decoded]
  (if (= index total)
    (Ok (rrbvec/to-list decoded))
    (match (as-identity (nth values index))
      (Ok identity)
      (decode-identity-list-loop values total (inc index) (conj decoded identity))
      (Error message) (Error message))))

(defn decode-identity-list [values]
  (let [values (rrbvec/of-list values)]
    (decode-identity-list-loop values (count values) 0 [])))

(defn decode-string-list-loop [values total index decoded]
  (if (= index total)
    (Ok (rrbvec/to-list decoded))
    (match (as-string (nth values index))
      (Ok text)
      (decode-string-list-loop values total (inc index) (conj decoded text))
      (Error message) (Error message))))

(defn decode-string-list [values]
  (let [values (rrbvec/of-list values)]
    (decode-string-list-loop values (count values) 0 [])))

(defn optional-string-list [key fields]
  (match (field key fields)
    None (Ok (list))
    (Some input)
    (match (as-array input)
      (Ok values) (decode-string-list values)
      (Error message) (Error message))))

(defn required-entity-list [key fields]
  (match (required key as-array fields)
    (Ok values) (decode-entity-list values)
    (Error message) (Error message)))

(defn required-identity-list [key fields]
  (match (required key as-array fields)
    (Ok values) (decode-identity-list values)
    (Error message) (Error message)))

(defn decode-change-value [input]
  (let* [fields (as-map input)
         format-version (required "format-version" as-int fields)
         graph-id (required "graph-id" as-string fields)
         schema-version (required "schema-version" as-string fields)
         t-before (required "t-before" as-int fields)
         t (required "t" as-int fields)
         upserts (required-entity-list "upserts" fields)
         deleted (required-identity-list "deleted" fields)
         operation-ids (optional-string-list "operation-ids" fields)]
    (Ok (record sync-change-set
                (format-version format-version)
                (graph-id graph-id)
                (schema-version schema-version)
                (t-before t-before)
                (t t)
                (upserts upserts)
                (deleted deleted)
                (operation-ids operation-ids)))))

(defn decode-change-set [wire]
  (try
    (decode-change-value (codec/of-string wire))
    (catch error
           (Error (Printexc/to-string error)))))

(defn decode-reset-value [input]
  (match (as-map input)
    (Ok fields)
    (match (tuple (required "reason" as-string fields)
                  (required "snapshot-required" as-bool fields))
      (tuple (Ok reason) (Ok snapshot-required))
      (Ok (record sync-reset
                  (reason reason)
                  (snapshot-required snapshot-required)))
      (tuple (Error message) _) (Error message)
      (tuple _ (Error message)) (Error message))
    (Error message) (Error message)))

(defn decode-event [event-name wire]
  (if (= event-name "graph-changes")
    (match (decode-change-set wire)
      (Ok change) (Ok (Graph_changes change))
      (Error message) (Error message))
    (if (= event-name "reset")
      (try
        (match (decode-reset-value (codec/of-string wire))
          (Ok reset) (Ok (Reset reset))
          (Error message) (Error message))
        (catch error
               (Error (Printexc/to-string error))))
      (Error (str "unsupported sync event: " event-name)))))
