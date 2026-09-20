(ns logseq-chat.sync-session
  (:require [logseq-chat.sync-checkpoint :as checkpoint]
            [logseq-chat.sync-state :as sync-state]
            [logseq-chat.snapshot :as snapshot]
            [logseq-chat.graph-store :as store]
            [logseq-chat.entity-sync :as entity-sync]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.Bytes :as bytes]
            [ocaml.Sys :as sys]
            [ocaml.Stdlib :as stdlib]))

(type-record sync-session-state
  (graph-id :string)
  (schema-version :string)
  (applied-server-t :ref<int>))

(type-variant sync-error
  Unsupported_format Graph_mismatch Schema_mismatch Cursor_mismatch Invalid_cursor
  (Apply_failed :string))

(type-record snapshot-metadata
  (url :string)
  (content-encoding :option<string>)
  (baseline-t :int)
  (schema-version :string)
  (row-count :int))

(defn create-state [graph-id schema-version applied-server-t]
  (record sync-session-state
    (graph-id graph-id) (schema-version schema-version)
    (applied-server-t (atom applied-server-t))))

(defn applied-server-t [state] @(:applied-server-t state))

(defn submission-accepted [state server-t] (stdlib/ignore 0))

(defn sync-error-of-code [code]
  (case code
    "unsupported-format" Unsupported_format
    "graph-mismatch" Graph_mismatch
    "schema-mismatch" Schema_mismatch
    "cursor-mismatch" Cursor_mismatch
    "invalid-cursor" Invalid_cursor
    (Apply_failed (str "Unknown LG sync-state error: " code))))

(defn apply-validated-change-set [state change apply]
  (if-some [code (sync-state/apply-change-set-error
                  (:graph-id state) (:schema-version state) (applied-server-t state)
                  (:format-version change) (:graph-id change) (:schema-version change)
                  (:t-before change) (:t change))]
    (Error (sync-error-of-code code))
    (match (apply change)
      (Error message) (Error (Apply_failed message))
      (Ok _) (do (reset! (:applied-server-t state) (:t change))
                 (Ok (stdlib/ignore 0))))))

(defn string-field [name input]
  (match (json-util/member name input)
    (tag String value)
    (if (not (empty? value)) (Ok value) (Error (str "snapshot metadata is missing " name)))
    _ (Error (str "snapshot metadata is missing " name))))

(defn non-negative-int-field [name input]
  (match (json-util/member name input)
    (tag Int value)
    (if (>= value 0) (Ok value) (Error (str "snapshot metadata is missing " name)))
    _ (Error (str "snapshot metadata is missing " name))))

(defn decode-snapshot-metadata [body]
  (try
    (let [input (json/from-string body)]
     (match input
      (tag Assoc _)
      (match (json-util/member "ok" input)
        (tag Bool true)
        (let* [url (string-field "url" input)
               baseline-t (non-negative-int-field "t" input)
               schema-version (string-field "schema-version" input)
               row-count (non-negative-int-field "row-count" input)]
          (let [encoding (match (json-util/member "content-encoding" input)
                           (tag String value)
                           (if (empty? value)
                             (stdlib/invalid-arg "snapshot metadata has invalid content-encoding")
                             (Some value))
                           (tag Null) None
                           _ (stdlib/invalid-arg "snapshot metadata has invalid content-encoding"))]
            (Ok (record snapshot-metadata
                  (url url) (content-encoding encoding) (baseline-t baseline-t)
                  (schema-version schema-version) (row-count row-count)))))
        (tag Bool false) (Error "snapshot download is not ready")
        _ (Error "snapshot metadata is missing ok"))
      _ (Error "snapshot metadata must be an object")))
    (catch (Yojson/Json_error message) (Error message))
    (catch (Invalid_argument message) (Error message))))

(defn cleanup-staging [active-path]
  (try
    (let [path (store/staging-path active-path)]
      (when (sys/file-exists path) (sys/remove path)))
    (catch _ nil)))

(defn- plaintext-datom [decrypt ^:Datascript.datom datom]
  (if (entity-sync/protected-attr? (:a datom))
    (match (:v datom)
      (ds/String ciphertext)
      (let* [value (decrypt ciphertext)]
        (Ok (assoc datom :v (ds/String value))))
      _ (Error (str "protected snapshot attribute " (:a datom) " must be a string")))
    (Ok datom)))

(defn plaintext-snapshot-db [decrypt db]
  (loop [remaining (seq (db-api/datoms db (ds/Eavt))) plaintext []]
    (if-some [datom (first remaining)]
      (let* [datom (plaintext-datom decrypt datom)]
        (recur (rest remaining) (conj plaintext datom)))
      (Ok (ds/init-db :schema (ds/schema db) (rrbvec/to-list plaintext))))))

(defn materialize-plaintext-snapshot [active-path decrypt encrypted-db]
  (let* [db (plaintext-snapshot-db decrypt encrypted-db)]
    (try
      (let [storage (store/import-storage active-path)]
        (ds/store :storage storage db)
        (ds/collect-garbage storage)
        (Ok (stdlib/ignore 0)))
      (catch error (Error (str "store local plaintext graph: " (Printexc/to-string error)))))))

(defn stream-snapshot [active-path download-path parser import]
  (let [channel (stdlib/open-in-bin download-path)
        buffer (bytes/create (* 256 1024))]
    (try
      (loop []
        (let [count (stdlib/input channel buffer 0 (bytes/length buffer))]
          (if (= count 0)
            (Ok (stdlib/ignore 0))
            (let* [rows (snapshot/feed parser (bytes/sub-string buffer 0 count))
                   _ (snapshot/accept-rows import rows)
                   _ (store/append-rows active-path rows)]
              (recur)))))
      (finally (stdlib/close-in-noerr channel)))))

(defn import-snapshot [decrypt graph-id active-path checkpoint-path metadata download-path]
  (let [parser (snapshot/create-parser (* 64 1024 1024))
        import (snapshot/create-import graph-id (:schema-version metadata)
                                       (:baseline-t metadata) (:row-count metadata))]
    (let* [_ (store/begin-import active-path)
           _ (stream-snapshot active-path download-path parser import)
           _ (snapshot/finish-parser parser)
           completed (snapshot/finish-import import)
           db (store/restore-db (store/staging-path active-path))
           _ (if-some [decrypt decrypt]
               (materialize-plaintext-snapshot active-path decrypt db)
               (Ok (stdlib/ignore 0)))
           _ (store/restore-db (store/staging-path active-path))
           _ (store/activate active-path)
           _ (checkpoint/save-checkpoint-atomic
               checkpoint-path
               (checkpoint/create graph-id (:schema-version metadata) (:baseline-t metadata)))]
      (Ok completed))))

(defn import-snapshot-file [decrypt graph-id active-path checkpoint-path metadata download-path]
  (try
    (match (import-snapshot decrypt graph-id active-path checkpoint-path metadata download-path)
      (Ok completed) (Ok completed)
      (Error message) (do (cleanup-staging active-path) (Error message)))
    (catch error
      (cleanup-staging active-path)
      (Error (str "import graph snapshot: " (Printexc/to-string error))))))

(defn error-message [error]
  (match error
    Unsupported_format "unsupported sync format"
    Graph_mismatch "sync graph mismatch"
    Schema_mismatch "sync schema mismatch"
    Cursor_mismatch "sync cursor mismatch"
    Invalid_cursor "invalid sync cursor"
    (Apply_failed message) message))

(defn apply-change-set [decrypt conn checkpoint-path state change]
  (match (apply-validated-change-set
           state change
           (fn [change]
             (let* [_ (entity-sync/apply-change-set decrypt conn change)]
               (checkpoint/save-checkpoint-atomic
                checkpoint-path (checkpoint/create (:graph-id change) (:schema-version change) (:t change))))))
    (Ok _) (Ok (stdlib/ignore 0))
    (Error error) (Error (error-message error))))
