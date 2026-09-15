(ns logseq-chat.sqlite
  (:require [ocaml.package/sqlite3]
            [ocaml.package/datascript-ocaml-native.sqlite]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript_sqlite_codec :as storage-codec]
            [ocaml.Sqlite3 :as db]
            [ocaml.Sqlite3.Rc :as rc]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.Transit_core.Json :as value]
            [ocaml.Transit_native.Transit.Json :as codec]))

(type-record sqlite-session
  (connection :Sqlite3.db)
  (closed :ref<bool>))

(defn ensure-open [session]
  (when @(:closed session) (stdlib/invalid-arg "SQLite session is closed")))

(defn execute [session sql]
  (ensure-open session)
  (rc/check (db/exec (:connection session) sql)))

(defn close [session]
  (stdlib/ignore
    (when-not @(:closed session)
      (if (db/db-close (:connection session))
        (reset! (:closed session) true)
        (stdlib/failwith "SQLite connection is busy")))))

(defn open-session [path]
  (let [session (record sqlite-session
                  (connection (db/db-open path))
                  (closed (atom false)))]
    (try
      (execute session "CREATE TABLE IF NOT EXISTS kvs (address TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL)")
      session
      (catch error (close session) (raise error)))))

(defn with-statement [session sql f]
  (ensure-open session)
  (let [statement (db/prepare (:connection session) sql)]
    (try (f statement)
         (finally (stdlib/ignore (db/finalize statement))))))

(defn transaction [session f]
  (execute session "BEGIN IMMEDIATE")
  (try
    (f)
    (execute session "COMMIT")
    (catch error
      (execute session "ROLLBACK")
      (raise error))))

(defn store-raw [session entries]
  (transaction session
    (fn []
      (with-statement session "INSERT OR REPLACE INTO kvs (address, payload) VALUES (?, ?)"
        (fn [statement]
          (run! (fn [[address payload]]
                  (rc/check (db/bind-text statement 1 address))
                  (rc/check (db/bind-text statement 2 payload))
                  (rc/check (db/step statement))
                  (rc/check (db/reset statement)))
                entries))))))

(defn restore-raw [session address]
  (with-statement session "SELECT payload FROM kvs WHERE address = ?"
    (fn [statement]
      (rc/check (db/bind-text statement 1 address))
      (match (db/step statement)
        (rc/ROW) (Some (db/column-text statement 0))
        (rc/DONE) None
        code (do (rc/check code) None)))))

(defn envelope [value-type text]
  (codec/to-string
    (value/Map
      (rrbvec/to-list [(tuple (value/Keyword "format-version") (value/Int 1))
                       (tuple (value/Keyword "value-type") (value/Keyword value-type))
                       (tuple (value/Keyword "value") (value/String text))]))))

(defn decode-envelope [value-type source]
  (try
    (match (codec/of-string source)
      (value/Map entries)
      (let [field (fn [key] (some (fn [entry]
                                    (when (= (first entry) (value/Keyword key)) (second entry)))
                                  entries))]
        (match (tuple (field "format-version") (field "value-type") (field "value"))
          (tuple (Some (value/Int 1)) (Some (value/Keyword actual-type)) (Some (value/String text)))
          (when (= actual-type value-type) text)
          _ None))
      _ None)
    (catch (value/Decode_error _) None)
    (catch (Yojson/Json_error _) None)
    (catch (Failure _) None)
    (catch (Invalid_argument _) None)))

(defn store-string [session address text]
  (store-raw session [[address (envelope "string" text)]]))

(defn restore-string [session address]
  (when-some [source (restore-raw session address)]
    (decode-envelope "string" source)))

(defn list-addresses [session]
  (with-statement session "SELECT address FROM kvs ORDER BY address DESC"
    (fn [statement]
      (loop [addresses []]
        (match (db/step statement)
          (rc/ROW) (recur (conj addresses (db/column-text statement 0)))
          (rc/DONE) addresses
          code (do (rc/check code) addresses))))))

(defn delete-addresses [session addresses]
  (transaction session
    (fn []
      (with-statement session "DELETE FROM kvs WHERE address = ?"
        (fn [statement]
          (run! (fn [address]
                  (rc/check (db/bind-text statement 1 address))
                  (rc/check (db/step statement))
                  (rc/check (db/reset statement)))
                addresses))))))

(defn decode-payload [source]
  (when-some [encoded (decode-envelope "datascript-storage" source)]
    (try (Some (storage-codec/decode encoded))
         (catch (value/Decode_error _) None)
         (catch (Yojson/Json_error _) None)
         (catch (Failure _) None)
         (catch (Invalid_argument _) None))))

(defn storage [session]
  (record Datascript.storage
    (storage-store
      (fn [entries]
        (store-raw session
          (mapv (fn [[address payload]]
                  [address (envelope "datascript-storage" (storage-codec/encode payload))])
                entries))))
    (storage-restore
      (fn [address]
        (when-some [source (restore-raw session address)] (decode-payload source))))
    (storage-list-addresses (fn [] (rrbvec/to-list (list-addresses session))))
    (storage-delete (fn [addresses] (delete-addresses session addresses)))))

(defn migrate-datascript-storage [source destination]
  (let [entries (vec (keep (fn [address]
                            (when-some [raw (restore-raw source address)]
                              (when (some? (decode-payload raw)) [address raw])))
                          (list-addresses source)))]
    (stdlib/ignore
      (when (seq entries)
        (store-raw destination entries)
        (delete-addresses source (mapv (fn [[address _]] address) entries))))))
