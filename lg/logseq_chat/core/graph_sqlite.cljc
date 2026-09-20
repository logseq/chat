(ns logseq-chat.graph-sqlite
  (:require [logseq-chat.snapshot :as snapshot]
            [ocaml.package/sqlite3]
            [ocaml.Sqlite3 :as db]
            [ocaml.Sqlite3.Rc :as rc]
            [ocaml.Sqlite3.Data :as data]
            [ocaml.Int64 :as int64]
            [ocaml.Gc :as gc]
            [ocaml.Stdlib :as stdlib]))

(defn fail [connection operation]
  (throw (Failure (str "SQLite error while " operation ": " (db/errmsg connection)))))

(defn check [connection operation code]
  (match code
    (rc/OK) (stdlib/ignore 0)
    (rc/DONE) (stdlib/ignore 0)
    _ (fail connection operation)))

(defn open-db [path]
  (try (db/db-open path)
       (catch (db/Error message)
         (throw (Failure (str "SQLite error while opening graph database: " message))))
       (catch (db/SqliteError message)
         (throw (Failure (str "SQLite error while opening graph database: " message))))))

(defn with-db [path f]
  (let [connection (open-db path)]
    (try (f connection)
         (finally (stdlib/ignore (db/db-close connection))))))

(defn execute [connection sql]
  (check connection "executing graph SQL" (db/exec connection sql)))

(defn prepare [connection sql]
  (try (db/prepare connection sql)
       (catch (db/Error message)
         (throw (Failure (str "SQLite error while preparing graph SQL: " message))))
       (catch (db/SqliteError message)
         (throw (Failure (str "SQLite error while preparing graph SQL: " message))))))

(defn with-statement [connection sql f]
  (let [statement (prepare connection sql)]
    (try (f statement) (finally (stdlib/ignore (db/finalize statement))))))

(defn bind-values [connection statement values]
  (check connection "binding graph SQL" (db/bind-values statement (apply list values))))

(defn transaction [connection f]
  (execute connection "BEGIN IMMEDIATE")
  (try
    (f)
    (execute connection "COMMIT")
    (catch error
      (stdlib/ignore (db/exec connection "ROLLBACK"))
      (raise error))))

(defn command [connection sql values]
  (with-statement connection sql
    (fn [statement]
      (bind-values connection statement values)
      (check connection "executing graph statement" (db/step statement)))))

(defn batch [connection sql rows]
  (transaction connection
    (fn []
      (with-statement connection sql
        (fn [statement]
          (run! (fn [values]
                  (bind-values connection statement values)
                  (check connection "writing graph row" (db/step statement))
                  (check connection "resetting graph statement" (db/reset statement))
                  (check connection "clearing graph bindings" (db/clear-bindings statement)))
                rows))))))

(defn query [connection sql values decode]
  (with-statement connection sql
    (fn [statement]
      (bind-values connection statement values)
      (loop [rows []]
        (match (db/step statement)
          (rc/ROW) (recur (conj rows (decode statement)))
          (rc/DONE) rows
          _ (fail connection "reading graph rows"))))))

(defn ensure-app-schema [connection]
  (run! #(execute connection %)
        ["CREATE TABLE IF NOT EXISTS logseq_chat_pending_ops (sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL UNIQUE, base_t INTEGER NOT NULL, state TEXT NOT NULL, intent TEXT NOT NULL)"
         "CREATE TABLE IF NOT EXISTS logseq_chat_pending_op_dependencies (operation_id TEXT NOT NULL, depends_on_operation_id TEXT NOT NULL, PRIMARY KEY (operation_id, depends_on_operation_id), FOREIGN KEY (operation_id) REFERENCES logseq_chat_pending_ops(operation_id) ON DELETE CASCADE, FOREIGN KEY (depends_on_operation_id) REFERENCES logseq_chat_pending_ops(operation_id) ON DELETE CASCADE)"
         "CREATE TABLE IF NOT EXISTS logseq_chat_sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)"]))

(defn with-app-db [path f]
  (with-db path (fn [connection] (ensure-app-schema connection) (f connection))))

(defn prepare-staging [path]
  (with-db path
    (fn [connection]
      (execute connection "CREATE TABLE kvs (addr INTEGER PRIMARY KEY, content TEXT, addresses JSON)")
      (ensure-app-schema connection))))

(defn copy-app-tables [source destination]
  (with-db source ensure-app-schema)
  (with-app-db destination
    (fn [connection]
      (command connection "ATTACH DATABASE ? AS app_source" [(data/TEXT source)])
      (try
        (transaction connection
          (fn []
            (run! #(execute connection %)
                  ["INSERT INTO main.logseq_chat_pending_ops (sequence, operation_id, base_t, state, intent) SELECT sequence, operation_id, base_t, state, intent FROM app_source.logseq_chat_pending_ops ORDER BY sequence"
                   "INSERT INTO main.logseq_chat_pending_op_dependencies (operation_id, depends_on_operation_id) SELECT operation_id, depends_on_operation_id FROM app_source.logseq_chat_pending_op_dependencies"
                   "INSERT INTO main.logseq_chat_sync_state (key, value) SELECT key, value FROM app_source.logseq_chat_sync_state"])))
        (finally (execute connection "DETACH DATABASE app_source"))))))

(defn nullable-text [value]
  (if-some [text value] (data/TEXT text) (data/NULL)))

(defn append-staging [path rows]
  (with-db path
    (fn [connection]
      (batch connection
             "INSERT INTO kvs (addr, content, addresses) VALUES (?, ?, ?) ON CONFLICT(addr) DO UPDATE SET content = excluded.content, addresses = excluded.addresses"
             (mapv (fn [row] [(data/INT (int64/of-int (:addr row))) (data/TEXT (:content row))
                             (nullable-text (:addresses row))]) rows)))))

(defn decode-row [statement]
  (tuple (db/column-text statement 0)
         (match (db/column statement 1) (data/NULL) nil _ (Some (db/column-text statement 1)))))

(defn read-stored-row [path address]
  (with-db path
    (fn [connection]
      (first (query connection "SELECT content, addresses FROM kvs WHERE addr = ?"
                    [(data/INT (int64/of-int address))] decode-row)))))

(defn list-stored-addresses [path]
  (with-db path
    (fn [connection]
      (query connection "SELECT addr FROM kvs ORDER BY addr" [] #(db/column-int % 0)))))

(defn delete-stored-addresses [path addresses]
  (with-db path
    (fn [connection]
      (batch connection "DELETE FROM kvs WHERE addr = ?"
             (mapv (fn [address] [(data/INT (int64/of-int address))]) addresses)))))

(type-record graph-reader (connection :Sqlite3.db) (statement :Sqlite3.stmt))

(defn close-reader [reader]
  (stdlib/ignore (db/finalize (:statement reader)))
  (stdlib/ignore (db/db-close (:connection reader))))

(defn open-reader [path]
  (let [connection (open-db path)]
    (try
      (let [reader (record graph-reader (connection connection)
                           (statement (prepare connection "SELECT content, addresses FROM kvs WHERE addr = ?")))]
        (gc/finalise close-reader reader)
        reader)
      (catch error (stdlib/ignore (db/db-close connection)) (raise error)))))

(defn reader-row [reader address]
  (let [connection (:connection reader) statement (:statement reader)]
    (try
      (check connection "binding graph address" (db/bind-int statement 1 address))
      (match (db/step statement)
        (rc/ROW) (Some (decode-row statement))
        (rc/DONE) nil
        _ (fail connection "reading graph node"))
      (finally (stdlib/ignore (db/reset statement))))))

(defn store-pending [path operation-id base-t state intent]
  (with-app-db path
    (fn [connection]
      (command connection
               "INSERT INTO logseq_chat_pending_ops (operation_id, base_t, state, intent) VALUES (?, ?, ?, ?) ON CONFLICT(operation_id) DO UPDATE SET base_t = excluded.base_t, state = excluded.state, intent = excluded.intent"
               [(data/TEXT operation-id) (data/INT (int64/of-int base-t)) (data/TEXT state) (data/TEXT intent)]))))

(defn list-pending [path]
  (with-app-db path
    (fn [connection]
      (query connection "SELECT operation_id, base_t, state, intent FROM logseq_chat_pending_ops ORDER BY sequence" []
             (fn [statement] (tuple (db/column-text statement 0) (db/column-int statement 1)
                                    (db/column-text statement 2) (db/column-text statement 3)))))))

(defn set-pending-state [path operation-id state]
  (with-app-db path
    (fn [connection]
      (command connection "UPDATE logseq_chat_pending_ops SET state = ? WHERE operation_id = ?"
               [(data/TEXT state) (data/TEXT operation-id)]))))

(defn remove-pending [path operation-id]
  (with-app-db path
    (fn [connection]
      (command connection "DELETE FROM logseq_chat_pending_ops WHERE operation_id = ?" [(data/TEXT operation-id)]))))

(defn ensure-search-schema [connection]
  (run! #(execute connection %)
        ["CREATE TABLE IF NOT EXISTS blocks (id TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, page TEXT)"
         "CREATE VIRTUAL TABLE IF NOT EXISTS blocks_fts USING fts5(id, title, page, tokenize=\"trigram\")"
         "CREATE INDEX IF NOT EXISTS blocks_title_nocase_idx ON blocks(title COLLATE NOCASE)"
         "CREATE TRIGGER IF NOT EXISTS blocks_ad AFTER DELETE ON blocks BEGIN DELETE FROM blocks_fts WHERE id = old.id; END"
         "CREATE TRIGGER IF NOT EXISTS blocks_ai AFTER INSERT ON blocks BEGIN INSERT INTO blocks_fts (id, title, page) VALUES (new.id, new.title, new.page); END"
         "CREATE TRIGGER IF NOT EXISTS blocks_au AFTER UPDATE ON blocks BEGIN DELETE FROM blocks_fts WHERE id = old.id; INSERT INTO blocks_fts (id, title, page) VALUES (new.id, new.title, new.page); END"]))

(defn with-search-db [path f]
  (with-db path (fn [connection] (ensure-search-schema connection) (f connection))))

(defn search-open [path]
  (with-db path ensure-search-schema))

(defn search-upsert [path rows]
  (with-search-db path
    (fn [connection]
      (batch connection
             "INSERT INTO blocks (id, title, page) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET (title, page) = (excluded.title, excluded.page)"
             (mapv (fn [[id title page]] [(data/TEXT id) (data/TEXT title) (data/TEXT page)]) rows)))))

(defn search-delete [path ids]
  (with-search-db path
    (fn [connection]
      (batch connection "DELETE FROM blocks WHERE id = ?" (mapv (fn [id] [(data/TEXT id)]) ids)))))

(defn search-query [path sql binds]
  (with-search-db path
    (fn [connection]
      (query connection sql (mapv data/TEXT binds)
             (fn [statement] (tuple (db/column-text statement 0) (db/column-text statement 1)
                                    (db/column-text statement 2)))))))
