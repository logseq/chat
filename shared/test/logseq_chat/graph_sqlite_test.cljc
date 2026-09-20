(ns logseq-chat.graph-sqlite-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.graph-sqlite :as sql]
            [logseq-chat.snapshot :as snapshot]
            [ocaml.Sqlite3 :as db]
            [ocaml.Sqlite3.Rc :as rc]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Stdlib :as stdlib]))

(defn with-path [f]
  (let [path (filename/temp-file "chat-graph-sqlite" ".sqlite")]
    (try (f path) (finally (when (sys/file-exists path) (sys/remove path))))))

(defn execute [path sql]
  (let [connection (db/db-open path)]
    (try (rc/check (db/exec connection sql))
         (finally (stdlib/ignore (db/db-close connection))))))

(defn row [addr content addresses]
  (record snapshot/snapshot-row (addr addr) (content content) (addresses addresses)))

(defn query-text [path statement]
  (sql/with-db path
    (fn [connection]
      (sql/query connection statement [] #(db/column-text % 0)))))

(defn failure? [f]
  (try (f) false (catch (Failure _) true) (catch _ false)))

(deftest graph-rows-preserve-order-null-and-upserts
  (with-path
    (fn [path]
      (sql/prepare-staging path)
      (sql/append-staging path (list (row 9 "nine" nil) (row 2 "two" (Some "[]"))))
      (is (= [2 9] (vec (sql/list-stored-addresses path))))
      (sql/append-staging path (list (row 9 "updated" (Some ""))))
      (is (= (Some (tuple "updated" (Some ""))) (sql/read-stored-row path 9)))
      (sql/delete-stored-addresses path (list 9 100))
      (is (nil? (sql/read-stored-row path 9)))
      (is (= [2] (vec (sql/list-stored-addresses path))))
      (execute path "INSERT INTO kvs VALUES (3, NULL, NULL)")
      (is (= (Some (tuple "" nil)) (sql/read-stored-row path 3))))))

(deftest graph-row-batches-roll-back-on-insert-and-delete-failures
  (with-path
    (fn [path]
      (sql/prepare-staging path)
      (execute path "CREATE TRIGGER reject_bad BEFORE INSERT ON kvs WHEN NEW.addr = 2 BEGIN SELECT RAISE(ABORT, 'rejected'); END")
      (is (failure? #(sql/append-staging path (list (row 1 "one" nil) (row 2 "two" nil)))))
      (is (nil? (sql/read-stored-row path 1)))
      (execute path "DROP TRIGGER reject_bad")
      (sql/append-staging path (list (row 1 "one" nil) (row 2 "two" nil)))
      (execute path "CREATE TRIGGER reject_delete BEFORE DELETE ON kvs WHEN OLD.addr = 2 BEGIN SELECT RAISE(ABORT, 'rejected'); END")
      (is (failure? #(sql/delete-stored-addresses path (list 1 2))))
      (is (= [1 2] (vec (sql/list-stored-addresses path)))))))

(deftest pending-operation-upserts-retain-sequence
  (with-path
    (fn [path]
      (sql/store-pending path "first" 7 "queued" "first intent")
      (sql/store-pending path "second" 8 "queued" "second intent")
      (sql/store-pending path "first" 9 "submitted" "updated intent")
      (is (= [(tuple "first" 9 "submitted" "updated intent")
              (tuple "second" 8 "queued" "second intent")]
             (vec (sql/list-pending path))))
      (sql/set-pending-state path "first" "applied")
      (sql/remove-pending path "second")
      (is (= [(tuple "first" 9 "applied" "updated intent")] (vec (sql/list-pending path)))))))

(deftest search-batches-update-fts-and-roll-back
  (with-path
    (fn [path]
      (sql/search-open path)
      (sql/search-upsert path (list (tuple "a" "alpha first" "page") (tuple "b" "beta second" "page")))
      (sql/search-upsert path (list (tuple "a" "gamma updated" "page")))
      (is (empty? (sql/search-query path "SELECT id, page, title FROM blocks_fts WHERE title MATCH ?" (list "alpha"))))
      (is (= [(tuple "a" "page" "gamma updated")]
             (vec (sql/search-query path "SELECT id, page, title FROM blocks_fts WHERE title MATCH ?" (list "gamma")))))
      (execute path "CREATE TRIGGER reject_bad BEFORE INSERT ON blocks WHEN NEW.id = 'bad' BEGIN SELECT RAISE(ABORT, 'rejected'); END")
      (is (failure? #(sql/search-upsert path (list (tuple "good" "new entry" "page") (tuple "bad" "bad entry" "page")))))
      (is (empty? (sql/search-query path "SELECT id, page, title FROM blocks WHERE id = ?" (list "good"))))
      (sql/search-delete path (list "a"))
      (is (empty? (sql/search-query path "SELECT id, page, title FROM blocks_fts WHERE title MATCH ?" (list "gamma")))))))

(deftest app-table-copy-retains-pending-metadata
  (with-path
    (fn [source]
      (with-path
        (fn [destination]
          (sql/prepare-staging source)
          (sql/prepare-staging destination)
          (sql/store-pending source "first" 7 "queued" "intent")
          (sql/store-pending source "second" 8 "queued" "intent two")
          (execute source "INSERT INTO logseq_chat_pending_op_dependencies VALUES ('second', 'first'); INSERT INTO logseq_chat_sync_state VALUES ('cursor', '8')")
          (sql/copy-app-tables source destination)
          (is (= (vec (sql/list-pending source)) (vec (sql/list-pending destination))))
          (is (= ["first"] (query-text destination "SELECT depends_on_operation_id FROM logseq_chat_pending_op_dependencies WHERE operation_id = 'second'")))
          (is (= ["8"] (query-text destination "SELECT value FROM logseq_chat_sync_state WHERE key = 'cursor'"))))))))

(deftest app-table-copy-rolls-back-all-tables
  (with-path
    (fn [source]
      (with-path
        (fn [destination]
          (sql/prepare-staging source)
          (sql/prepare-staging destination)
          (sql/store-pending source "first" 7 "queued" "intent")
          (execute source "INSERT INTO logseq_chat_sync_state VALUES ('cursor', '8')")
          (execute destination "INSERT INTO logseq_chat_sync_state VALUES ('cursor', 'old')")
          (is (failure? #(sql/copy-app-tables source destination)))
          (is (empty? (sql/list-pending destination)))
          (is (= ["old"] (query-text destination "SELECT value FROM logseq_chat_sync_state WHERE key = 'cursor'"))))))))

(deftest reader-resets-after-a-missing-row
  (with-path
    (fn [path]
      (sql/prepare-staging path)
      (let [reader (sql/open-reader path)]
        (is (nil? (sql/reader-row reader 1)))
        (sql/append-staging path [(row 1 "committed" nil)])
        (is (= (Some (tuple "committed" nil)) (sql/reader-row reader 1)))
        (sql/delete-stored-addresses path [1])
        (is (nil? (sql/reader-row reader 1)))))))

(deftest database-open-and-reader-prepare-errors-remain-failures
  (with-path
    (fn [path]
      (let [missing-parent (str path "/missing.sqlite")]
        (is (failure? #(sql/search-open missing-parent)))
        (is (failure? #(sql/open-reader missing-parent))))
      (is (failure? #(sql/open-reader path))))))
