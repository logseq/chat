(ns logseq-chat.mobile-graph
  (:require [logseq-chat.graph-runtime :as runtime]
            [logseq-chat.asset-files :as assets]
            [logseq-chat.graph-read :as read]
            [logseq-chat.sync-session :as sync]
            [logseq-chat.sync-checkpoint :as checkpoint]
            [logseq-chat.sync-protocol :as protocol]
            [logseq-chat.graph-store :as store]
            [logseq-chat.mobile-payload :as payload]
            [ocaml.Datascript :as ds]
            [ocaml.Filename :as filename]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Yojson :as yojson]))

(type-record graph-crypto
  (require-key :fn<string;result<unit;string>>)
  (encrypt-title :fn<string;string;result<string;string>>)
  (decrypt-title :fn<string;string;result<string;string>>))

(type-record mobile-graph-runtime
  (conn :Datascript.conn) (state :sync/sync-session-state)
  (checkpoint-path :string) (graph-id :string) (e2ee :bool)
  (read-runtime :runtime/graph-runtime))

(type-record mobile-graph
  (crypto :graph-crypto) (current :ref<option<mobile-graph-runtime>>))

(defn create [crypto]
  (record mobile-graph (crypto crypto) (current (atom nil))))

(defn resolve-asset-path [host source-path]
  (assets/resolve-path
    (when-some [opened @(:current host)] (:checkpoint-path opened)) source-path))

(defn sync-cursor [host]
  (when-some [opened @(:current host)]
    (sync/applied-server-t (:state opened))))

(defn blocks [host]
  (when-some [opened @(:current host)] (runtime/blocks (:read-runtime opened))))

(defn authoritative-blocks [host]
  (when-some [opened @(:current host)]
    (read/blocks #(Ok %) 7 (ds/conn-db (:conn (:read-runtime opened))))))

(defn sidebar-pages [host]
  (when-some [opened @(:current host)] (runtime/sidebar-pages (:read-runtime opened))))

(defn tag-pages [host]
  (when-some [opened @(:current host)] (runtime/tag-pages (:read-runtime opened))))

(defn node-is-tag [host uuid]
  (if-some [opened @(:current host)] (runtime/node-is-tag (:read-runtime opened) uuid) false))

(defn node-is-property [host uuid]
  (if-some [opened @(:current host)] (runtime/node-is-property (:read-runtime opened) uuid) false))

(defn blocks-for-page [host uuid]
  (when-some [opened @(:current host)] (runtime/blocks-for-page (:read-runtime opened) uuid)))

(defn node-destination [host uuid]
  (when-some [opened @(:current host)] (runtime/node-destination (:read-runtime opened) uuid)))

(defn objects-for-tag [host uuid]
  (when-some [opened @(:current host)] (runtime/objects-for-tag (:read-runtime opened) uuid)))

(defn references-for-node [host uuid]
  (when-some [opened @(:current host)] (runtime/references-for-node (:read-runtime opened) uuid)))

(defn normalize-titles [host uuid titles]
  (if-some [opened @(:current host)]
    (runtime/normalize-titles (:read-runtime opened) uuid titles)
    (tuple (vec titles) [])))

(defn search [host query]
  (if-some [opened @(:current host)] (runtime/search (:read-runtime opened) query) []))

(defn due-flashcards [host now]
  (if-some [opened @(:current host)] (runtime/due-flashcards (:read-runtime opened) now) []))

(defn review-flashcard [host uuid rating now operation-id]
  (if-some [opened @(:current host)]
    (runtime/review-flashcard (:read-runtime opened) uuid rating now operation-id)
    (Error "graph runtime is not open")))

(defn set-page-favorite [host uuid favorite operation-id now]
  (if-some [opened @(:current host)]
    (runtime/set-page-favorite (:read-runtime opened) uuid favorite operation-id now)
    (Error "graph runtime is not open")))

(defn delete-page [host uuid operation-id now]
  (if-some [opened @(:current host)]
    (runtime/delete-page (:read-runtime opened) uuid operation-id now)
    (Error "graph runtime is not open")))

(defn load-older-journals [host]
  (when-some [opened @(:current host)] (runtime/load-older-journals (:read-runtime opened)))
  (stdlib/ignore 0))

(defn has-older-journals [host]
  (if-some [opened @(:current host)] (runtime/has-older-journals (:read-runtime opened)) false))

(defn journal-page-uuid [host day]
  (when-some [opened @(:current host)] (runtime/journal-page-uuid (:read-runtime opened) day)))

(defn stage [host operation]
  (if-some [opened @(:current host)]
    (runtime/stage (:read-runtime opened) operation)
    (Error "graph runtime is not open")))

(defn prepare-sync [host operation]
  (if-some [opened @(:current host)]
    (runtime/prepare-sync (:read-runtime opened) operation)
    (Error "graph runtime is not open")))

(defn pending-operations [host]
  (if-some [opened @(:current host)] (runtime/pending-operations (:read-runtime opened)) []))

(defn report-open [started stage]
  (stdlib/prerr-endline
   (str "LOGSEQ_GRAPH_OPEN_METRIC stage=" stage " elapsed_ms="
        (format "%.3f" (* (- (unix/gettimeofday) started) 1000.0)))))

(defn open-paths [host graph-id active-path checkpoint-path e2ee]
  (let [started (unix/gettimeofday)]
    (let* [saved (checkpoint/load-checkpoint checkpoint-path)]
      (report-open started "checkpoint_loaded")
      (let* [saved (match saved
                    (Some saved) (if (= (:graph-id saved) graph-id) (Ok saved)
                                     (Error "graph checkpoint belongs to another graph"))
                    None (Error "graph checkpoint is missing"))
             conn (store/restore-conn active-path)]
        (report-open started "connection_restored")
        (let* [_ (if e2ee ((:require-key (:crypto host)) graph-id) (Ok (stdlib/ignore 0)))]
          (report-open started "encryption_ready")
          (let [state (sync/create-state graph-id (:schema-version saved) (:applied-server-t saved))
                options (assoc runtime/default-options
                               :search-index-path (Some (filename/concat (filename/dirname active-path) "search/db.sqlite"))
                               :auto-create-today true)
                options (if e2ee (assoc options :encrypt-title #((:encrypt-title (:crypto host)) graph-id %)) options)
                read-runtime (runtime/create active-path (:applied-server-t saved) conn options)]
            (report-open started "runtime_created")
            (reset! (:current host)
                    (Some (record mobile-graph-runtime (conn conn) (state state)
                                  (checkpoint-path checkpoint-path) (graph-id graph-id)
                                  (e2ee e2ee) (read-runtime read-runtime))))
            (report-open started "complete")
            (Ok (stdlib/ignore 0))))))))

(defn open-graph [host body]
  (try
    (let* [request (payload/decode-open body)]
      (open-paths host (:graph-id request) (:active-path request) (:checkpoint-path request) (:e2ee request)))
    (catch error (Error (Printexc/to-string error)))))

(defn import-snapshot [host body]
  (try
    (let* [request (payload/decode-import body)
           metadata (sync/decode-snapshot-metadata (:metadata-body request))
           _ (sync/import-snapshot-file
              (when (:e2ee request) (fn [value] ((:decrypt-title (:crypto host)) (:graph-id request) value)))
              (:graph-id request) (:active-path request) (:checkpoint-path request) metadata (:download-path request))]
      (open-paths host (:graph-id request) (:active-path request) (:checkpoint-path request) (:e2ee request)))
    (catch error (Error (Printexc/to-string error)))))

(defn apply-sync-event [host body]
  (try
    (let* [event (payload/decode-sync-event body)]
      (match event
        (protocol/Reset reset) (Error (str "snapshot required: " (:reason reset)))
        (protocol/Graph_changes change)
        (if-some [opened @(:current host)]
          (let* [_ (sync/apply-change-set
                    (if (:e2ee opened)
                      (fn [value] ((:decrypt-title (:crypto host)) (:graph-id opened) value))
                      (fn [value] (Ok value)))
                    (:conn opened) (:checkpoint-path opened) (:state opened) change)]
            (runtime/rebase (:read-runtime opened) (:t change) (:operation-ids change) (protocol/changed-block-uuids change))
            (Ok (stdlib/ignore 0)))
          (Error "graph runtime is not open"))))
    (catch (yojson/Json_error message) (Error message))))
