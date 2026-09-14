(ns logseq-chat.sync-protocol
  (:require [ocaml.package/melange-transit-core]
            [ocaml.package/melange-transit-native]
            [ocaml.Int64 :as int64]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.Transit_core.Json :as value]
            [ocaml.Transit_native.Transit.Json :as codec]))

(defn contains-uuid? [^:vector<string> uuids ^:string uuid]
  (let [total (count uuids)]
    (loop [index 0]
      (if (= index total)
        false
        (if (= (nth uuids index) uuid)
          true
          (recur (inc index)))))))

(defn collect-identity [^:vector<string> uuids ^:Transit_core.Json.value identity]
  (match identity
    (value/Array [(value/Keyword "block/uuid") (value/Uuid uuid)])
    (if (contains-uuid? uuids uuid)
      uuids
      (conj uuids uuid))
    _ uuids))

(defn changed-block-uuids [^sync-change-set change]
  (let [upserts (rrbvec/of-list (:upserts change))
        deleted (rrbvec/of-list (:deleted change))
        upsert-count (count upserts)
        deleted-count (count deleted)
        uuids
        (loop [index 0
               uuids []]
          (if (= index upsert-count)
            uuids
            (recur (inc index)
                   (collect-identity uuids (:id (nth upserts index))))))]
    (loop [index 0
           uuids uuids]
      (if (= index deleted-count)
        uuids
        (recur (inc index)
               (collect-identity uuids (nth deleted index)))))))

(defn field [key fields]
  (let [fields (rrbvec/of-list fields)
        wanted (value/Keyword key)
        total (count fields)]
    (loop [index 0]
      (if (= index total)
        None
        (let [entry (nth fields index)]
          (if (= (Stdlib/fst entry) wanted)
            (Some (Stdlib/snd entry))
            (recur (inc index))))))))

(defn bind [result f]
  (match result
    (Ok value) (f value)
    (Error message) (Error message)))

(defn required [key decode fields]
  (match (field key fields)
    (Some value) (decode value)
    None (Error (str "missing Transit field: " key))))

(defn as-int [^:Transit_core.Json.value input]
  (match input
    (value/Int number) (Ok number)
    (value/Int64 number)
    (if (and (>= number (int64/of-int Stdlib/min_int))
             (<= number (int64/of-int Stdlib/max_int)))
      (Ok (int64/to-int number))
      (Error "expected Transit integer"))
    _ (Error "expected Transit integer")))

(defn as-string [^:Transit_core.Json.value input]
  (match input
    (value/String text) (Ok text)
    _ (Error "expected Transit string")))

(defn as-bool [^:Transit_core.Json.value input]
  (match input
    (value/Bool value) (Ok value)
    _ (Error "expected Transit boolean")))

(defn as-array [^:Transit_core.Json.value input]
  (match input
    (value/Array values) (Ok values)
    _ (Error "expected Transit array")))

(defn as-map [^:Transit_core.Json.value input]
  (match input
    (value/Map fields) (Ok fields)
    _ (Error "expected Transit map")))

(defn as-identity [^:Transit_core.Json.value input]
  (match input
    (value/Array [(value/Keyword "block/uuid") (value/Uuid uuid)])
    (Ok (value/Array (list (value/Keyword "block/uuid") (value/Uuid uuid))))
    (value/Array [(value/Keyword "db/ident") (value/Keyword ident)])
    (Ok (value/Array (list (value/Keyword "db/ident") (value/Keyword ident))))
    (value/Array [(value/Keyword "file/path") (value/String path)])
    (Ok (value/Array (list (value/Keyword "file/path") (value/String path))))
    _ (Error "expected stable Transit lookup identity")))

(defn keyword-key? [entry]
  (match (Stdlib/fst entry)
    (value/Keyword _) true
    _ false))

(defn all-keyword-keys? [fields]
  (let [fields (rrbvec/of-list fields)
        total (count fields)]
    (loop [index 0]
      (if (= index total)
        true
        (if (keyword-key? (nth fields index))
          (recur (inc index))
          false)))))

(defn as-attrs [^:Transit_core.Json.value input]
  (match input
    (value/Map fields)
    (if (all-keyword-keys? fields)
      (Ok fields)
      (Error "expected Transit keyword attribute keys"))
    _ (Error "expected Transit attribute map")))

(defn decode-entity [input]
  (bind (as-map input)
        (fn [fields]
          (bind (required "id" as-identity fields)
                (fn [id]
                  (bind (required "attrs" as-attrs fields)
                        (fn [attrs]
                          (Ok (record sync-entity
                                      (id id)
                                      (attrs attrs))))))))))

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
    (bind (as-array input) decode-string-list)))

(defn decode-change-value [input]
  (bind (as-map input)
        (fn [fields]
          (bind (required "format-version" as-int fields)
                (fn [format-version]
                  (bind (required "graph-id" as-string fields)
                        (fn [graph-id]
                          (bind (required "schema-version" as-string fields)
                                (fn [schema-version]
                                  (bind (required "t-before" as-int fields)
                                        (fn [t-before]
                                          (bind (required "t" as-int fields)
                                                (fn [t]
                                                  (bind (required "upserts" as-array fields)
                                                        (fn [upsert-values]
                                                          (bind (decode-entity-list upsert-values)
                                                                (fn [upserts]
                                                                  (bind (required "deleted" as-array fields)
                                                                        (fn [deleted-values]
                                                                          (bind (decode-identity-list deleted-values)
                                                                                (fn [deleted]
                                                                                  (bind (optional-string-list "operation-ids" fields)
                                                                                        (fn [operation-ids]
                                                                                          (Ok (record sync-change-set
                                                                                                      (format-version format-version)
                                                                                                      (graph-id graph-id)
                                                                                                      (schema-version schema-version)
                                                                                                      (t-before t-before)
                                                                                                      (t t)
                                                                                                      (upserts upserts)
                                                                                                      (deleted deleted)
                                                                                                      (operation-ids operation-ids))))))))))))))))))))))))))

(defn decode-change-set [wire]
  (try
    (decode-change-value (codec/of-string wire))
    (catch error
           (Error (Printexc/to-string error)))))

(defn decode-reset-value [input]
  (bind (as-map input)
        (fn [fields]
          (bind (required "reason" as-string fields)
                (fn [reason]
                  (bind (required "snapshot-required" as-bool fields)
                        (fn [snapshot-required]
                          (Ok (record sync-reset
                                      (reason reason)
                                      (snapshot-required snapshot-required))))))))))

(defn decode-event [event-name wire]
  (if (= event-name "graph-changes")
    (bind (decode-change-set wire)
          (fn [change] (Ok (Graph_changes change))))
    (if (= event-name "reset")
      (try
        (bind (decode-reset-value (codec/of-string wire))
              (fn [reset] (Ok (Reset reset))))
        (catch error
               (Error (Printexc/to-string error))))
      (Error (str "unsupported sync event: " event-name)))))
