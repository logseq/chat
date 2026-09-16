(ns logseq-chat.asset-files
  (:require [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Printexc :as printexc]))

(defn read-file [path]
  (try
    (let [channel (stdlib/open-in-bin path)]
      (try (Ok (stdlib/really-input-string channel (stdlib/in-channel-length channel)))
           (finally (stdlib/close-in-noerr channel))))
    (catch error (Error (str "read asset for encryption: " (printexc/to-string error))))))

(defn write-file [path contents]
  (try
    (let [channel (stdlib/open-out-bin path)]
      (try (stdlib/output-string channel contents)
           (finally (stdlib/close-out-noerr channel))))
    (Ok (stdlib/ignore 0))
    (catch error (Error (str "write encrypted asset: " (printexc/to-string error))))))

(defn resolve-path [checkpoint-path source-path]
  (if (filename/is-relative source-path)
    (if-some [checkpoint checkpoint-path]
      (filename/concat (-> checkpoint filename/dirname filename/dirname filename/dirname) source-path)
      source-path)
    source-path))

(defn encrypt-file [encrypt graph-id source-path]
  (let* [bytes (read-file source-path)
         encrypted (encrypt graph-id bytes)]
    (let [path (filename/temp-file :temp_dir (filename/dirname source-path) "logseq-chat-e2ee-" ".transit")]
      (match (write-file path encrypted)
        (Ok _) (Ok (tuple path (count encrypted)))
        (Error message)
        (do (try (sys/remove path) (catch _ (stdlib/ignore 0)))
            (Error message))))))
