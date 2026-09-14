(ns logseq-chat.graph-store
  (:require [logseq-chat.snapshot :as snapshot]
            [logseq-chat.storage-codec :as codec]
            [ocaml.package/datascript-ocaml-native]
            [ocaml.package/unix]
            [ocaml.Datascript :as ds]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]
            [ocaml.String :as byte-string]
            [ocaml.Rrbvec :as rrbvec]))

(extern-type graph-reader)
(ffi open-reader [:string] :graph-reader {:ocaml "logseq_chat_graph_reader_open"})
(ffi reader-row [:graph-reader :int] :option<tuple<string;option<string>>>
  {:ocaml "logseq_chat_graph_reader_read"})
(ffi prepare-staging [:string] :unit {:ocaml "logseq_chat_graph_store_prepare"})
(ffi append-staging [:string :list<snapshot/snapshot-row>] :unit
  {:ocaml "logseq_chat_graph_store_append"})
(ffi copy-app-tables [:string :string] :unit {:ocaml "logseq_chat_graph_store_copy_app_tables"})
(ffi read-stored-row [:string :int] :option<tuple<string;option<string>>>
  {:ocaml "logseq_chat_graph_store_read_row"})
(ffi list-stored-addresses [:string] :list<int> {:ocaml "logseq_chat_graph_store_list_addresses"})
(ffi delete-stored-addresses [:string :list<int>] :unit {:ocaml "logseq_chat_graph_store_delete"})

(defn staging-path [active-path]
  (byte-string/cat active-path ".import"))

(defn protect [operation f]
  (try
    (f)
    (Ok (stdlib/ignore 0))
    (catch error (Error (str operation ": " (Printexc/to-string error))))))

(defn begin-import [active-path]
  (let [staging (staging-path active-path)]
    (protect "prepare graph snapshot staging database"
             (fn []
               (when (sys/file-exists staging) (sys/remove staging))
               (prepare-staging staging)
               (when (sys/file-exists active-path) (copy-app-tables active-path staging))))))

(defn append-rows [active-path ^:list<snapshot/snapshot-row> rows]
  (try
    (when (not (empty? rows)) (append-staging (staging-path active-path) rows))
    (Ok (stdlib/ignore 0))
    (catch error (Error (str "append graph snapshot rows: " (Printexc/to-string error))))))

(defn activate [active-path]
  (let [staging (staging-path active-path)]
    (protect "activate graph snapshot"
             (fn []
               (when (not (sys/file-exists staging))
                 (stdlib/invalid-arg "snapshot staging database is missing"))
               (unix/rename staging active-path)))))

(defn read-row [path addr]
  (try (Ok (read-stored-row path addr))
       (catch error (Error (str "read graph snapshot row: " (Printexc/to-string error))))))

(defn int-of-address [address]
  (match (stdlib/int-of-string-opt address)
    (Some number) number
    None (stdlib/invalid-arg (str "Logseq graph storage address is not an integer: " address))))

(defn storage-with-paths [read-path write-path]
  ;; Retain one lazy reader so replacement snapshots cannot mix index nodes.
  (let [reader (delay (open-reader read-path))]
    (record Datascript.storage
      (storage-store
       (fn [entries]
         (append-staging
          write-path
          (rrbvec/to-list
           (mapv (fn [[address payload]]
                   (let [[content addresses] (codec/encode None payload)]
                     (record snapshot/snapshot-row
                       (addr (int-of-address address)) (content content) (addresses addresses))))
                 entries)))))
      (storage-restore
       (fn [address]
         (match (reader-row (force reader) (int-of-address address))
           None None
           (Some (tuple content addresses)) (Some (codec/decode addresses content)))))
      (storage-list-addresses
       (fn [] (rrbvec/to-list (mapv stdlib/string-of-int (list-stored-addresses read-path)))))
      (storage-delete
       (fn [addresses] (delete-stored-addresses write-path (rrbvec/to-list (mapv int-of-address addresses))))))))

(defn storage [path]
  (storage-with-paths path path))

(defn import-storage [active-path]
  (storage (staging-path active-path)))

(defn restore-db [path]
  (try
    (match (ds/restore (storage path))
      (Some db) (Ok db)
      None (Error "graph storage has no DataScript root"))
    (catch error (Error (str "restore graph DataScript db: " (Printexc/to-string error))))))

(defn restore-conn [path]
  (try
    (match (ds/restore-conn (storage path))
      (Some conn) (Ok conn)
      None (Error "graph storage has no DataScript root"))
    (catch error (Error (str "restore graph DataScript connection: " (Printexc/to-string error))))))
