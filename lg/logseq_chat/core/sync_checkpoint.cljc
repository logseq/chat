(ns logseq-chat.sync-checkpoint
  (:require [ocaml.package/melange-transit-core]
            [ocaml.package/melange-transit-native]
            [ocaml.package/unix]
            [ocaml.Int64 :as int64]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]
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
  (some (fn [entry]
          (when (= (first entry) (value/Keyword key)) (second entry)))
        entries))

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

(defn load-checkpoint [path]
  (if (not (sys/file-exists path))
    (Ok None)
    (try
      (let [channel (stdlib/open-in-bin path)
            source (try
                     (stdlib/really-input-string channel (stdlib/in-channel-length channel))
                     (finally (stdlib/close-in-noerr channel)))]
        (let* [checkpoint (decode source)] (Ok (Some checkpoint))))
      (catch error (Error (str "read checkpoint " path ": " (Printexc/to-string error)))))))

(defn save-checkpoint-atomic [path checkpoint]
  (let [temporary (str path ".tmp")]
    (try
      (let [channel (stdlib/open-out-gen
                     (list (stdlib/Open_wronly) (stdlib/Open_creat) (stdlib/Open_trunc) (stdlib/Open_binary))
                     384 temporary)]
        (try
          (stdlib/output-string channel (encode checkpoint))
          (stdlib/flush channel)
          (unix/fsync (unix/descr-of-out-channel channel))
          (finally (stdlib/close-out-noerr channel))))
      (unix/rename temporary path)
      (Ok (stdlib/ignore 0))
      (catch error
        (try (when (sys/file-exists temporary) (sys/remove temporary))
             (catch _ nil))
        (Error (str "write checkpoint " path ": " (Printexc/to-string error)))))))
