(ns logseq-chat.sync-checkpoint
  (:require [ocaml.package/melange-transit-core]
            [ocaml.package/melange-transit-native]
            [ocaml.Int64 :as int64]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.Transit_core.Json :as value]
            [ocaml.Transit_native.Transit.Json :as codec]))

(type-record sync-checkpoint
  (graph-id :string)
  (schema-version :string)
  (applied-server-t :int))

(defn create [graph-id schema-version applied-server-t]
  (record sync-checkpoint
    (graph-id graph-id)
    (schema-version schema-version)
    (applied-server-t applied-server-t)))

(defn encode [^:sync-checkpoint checkpoint]
  (let [entries [(tuple (value/Keyword "format-version") (value/Int 1))
                 (tuple (value/Keyword "graph-id") (value/String (:graph-id checkpoint)))
                 (tuple (value/Keyword "schema-version") (value/String (:schema-version checkpoint)))
                 (tuple (value/Keyword "applied-server-t")
                        (value/Int (:applied-server-t checkpoint)))]]
    (codec/to-string
     (value/Map (rrbvec/to-list entries)))))

(defn field [key ^:list<tuple<Transit_core.Json.value;Transit_core.Json.value>> entries]
  (let [entries (rrbvec/of-list entries)
        wanted (value/Keyword key)
        total (count entries)]
    (loop [index 0]
      (if (= index total)
        None
        (let [[key value] (nth entries index)]
          (if (= key wanted)
            (Some value)
            (recur (inc index))))))))

(defn int-value [value]
  (match value
    (value/Int value)
    (Some value)
    (value/Int64 value)
    (if (and (>= value int64/zero)
             (<= value (int64/of-int Stdlib/max_int)))
      (Some (int64/to-int value))
      None)
    _ None))

(defn decode-map [entries]
  (match (field "format-version" entries)
    (Some (value/Int 1))
    (match (field "graph-id" entries)
      (Some (value/String graph-id))
      (match (field "schema-version" entries)
        (Some (value/String schema-version))
        (match (field "applied-server-t" entries)
          (Some applied-server-t)
          (match (int-value applied-server-t)
            (Some applied-server-t)
            (if (>= applied-server-t 0)
              (Ok (create graph-id schema-version applied-server-t))
              (Error "invalid graph sync checkpoint"))
            None
            (Error "invalid graph sync checkpoint"))
          None
          (Error "invalid graph sync checkpoint"))
        _
        (Error "invalid graph sync checkpoint"))
      _
      (Error "invalid graph sync checkpoint"))
    _
    (Error "invalid graph sync checkpoint")))

(defn decode [source]
  (try
    (match (codec/of-string source)
      (value/Map entries) (decode-map entries)
      _ (Error "graph sync checkpoint must be a Transit map"))
    (catch error
      (Error (Printexc/to-string error)))))
