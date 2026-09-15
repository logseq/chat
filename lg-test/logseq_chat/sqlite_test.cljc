(ns logseq-chat.sqlite-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.sqlite :as sqlite]
            [logseq-chat.cache-model :as model]
            [ocaml.Datascript :as ds]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]))

(defn with-database [f]
  (let [path (filename/temp-file "logseq-chat-sqlite-test" ".sqlite")]
    (try (f path)
         (finally (when (sys/file-exists path) (sys/remove path))))))

(deftest session-roundtrip-and-closed-access
  (with-database
    (fn [path]
      (let [session (sqlite/open-session path)
            text "Unicode 草稿\u0000tail"]
        (try
          (sqlite/store-string session "metadata" text)
          (is (= (Some text) (sqlite/restore-string session "metadata")))
          (finally (sqlite/close session)))
        (sqlite/close session)
        (is (thrown? Invalid_argument (sqlite/restore-string session "metadata")))
        (let [reopened (sqlite/open-session path)]
          (try (is (= (Some text) (sqlite/restore-string reopened "metadata")))
               (finally (sqlite/close reopened))))))))

(deftest invalid-envelope-is-a-cache-miss
  (with-database
    (fn [path]
      (let [session (sqlite/open-session path)]
        (try
          (sqlite/store-raw session [["broken" "not transit"]
                                    ["future" "[\"^ \",\"~:format-version\",2,\"~:value-type\",\"~:string\",\"~:value\",\"future\"]"]])
          (is (nil? (sqlite/restore-string session "broken")))
          (is (nil? (sqlite/restore-string session "future")))
          (finally (sqlite/close session)))))))

(deftest datascript-storage-roundtrip-and-format
  (with-database
    (fn [path]
      (let [session (sqlite/open-session path)
            storage (sqlite/storage session)]
        (try
          ((:storage-store storage) (list (tuple "tail" (ds/Storage_tail (list)))))
          (is (= (Some (ds/Storage_tail (list))) ((:storage-restore storage) "tail")))
          (is (nil? (sqlite/restore-string session "tail")))
          (sqlite/store-string session "metadata" "value")
          (is (nil? ((:storage-restore storage) "metadata")))
          (is (= (Some "[]") (sqlite/decode-envelope "datascript-storage"
                               (or (sqlite/restore-raw session "tail") ""))))
          ((:storage-delete storage) (list "tail"))
          (is (nil? ((:storage-restore storage) "tail")))
          (is (= (list "metadata") ((:storage-list-addresses storage))))
          (finally (sqlite/close session)))))))

(deftest cached-block-survives-reopening
  (with-database
    (fn [path]
      (let [session (sqlite/open-session path)
            cache (model/create (Some (sqlite/storage session)))]
        (try (model/cache-local-message cache "local-persisted" "Persisted offline capture" 1776000000000)
             (finally (sqlite/close session))))
      (let [session (sqlite/open-session path)]
        (try
          (let [cache (model/create (Some (sqlite/storage session)))
                block (model/read-block cache "local-persisted")]
            (is (= (Some "Persisted offline capture") (some-> block :title)))
            (is (= (Some "pending") (some-> block :sync-status))))
          (finally (sqlite/close session)))))))

(deftest migration-preserves-metadata
  (with-database
    (fn [source-path]
      (with-database
        (fn [destination-path]
          (let [source (sqlite/open-session source-path)
                destination (sqlite/open-session destination-path)]
            (try
              (sqlite/store-string source "catalog" "{\"graphs\":[]}")
              (model/cache-local-asset (model/create (Some (sqlite/storage source)))
                "legacy-asset" "photo.jpg" "jpg" 4 "abcd" "Assets/photo.jpg" 1 None)
              (sqlite/migrate-datascript-storage source destination)
              (is (= 1 (count (model/pending-blocks (model/create (Some (sqlite/storage destination)))))))
              (is (empty? (model/pending-blocks (model/create (Some (sqlite/storage source))))))
              (is (= (Some "{\"graphs\":[]}") (sqlite/restore-string source "catalog")))
              (finally (sqlite/close source) (sqlite/close destination)))))))))

(deftest failed-migration-retains-source
  (with-database
    (fn [source-path]
      (with-database
        (fn [destination-path]
          (let [source (sqlite/open-session source-path)
                destination (sqlite/open-session destination-path)]
            (try
              (model/cache-local-message (model/create (Some (sqlite/storage source)))
                "pending" "Keep me" 1)
              (sqlite/execute destination "CREATE TRIGGER reject_all BEFORE INSERT ON kvs BEGIN SELECT RAISE(ABORT, 'rejected'); END")
              (is (thrown? Failure (sqlite/migrate-datascript-storage source destination)))
              (is (= 1 (count (model/pending-blocks (model/create (Some (sqlite/storage source)))))))
              (finally (sqlite/close source) (sqlite/close destination)))))))))

(deftest failed-write-rolls-back-the-whole-batch
  (with-database
    (fn [path]
      (let [session (sqlite/open-session path)]
        (try
          (sqlite/execute session "CREATE TRIGGER reject_bad BEFORE INSERT ON kvs WHEN NEW.address = 'bad' BEGIN SELECT RAISE(ABORT, 'rejected'); END")
          (is (thrown? Failure (sqlite/store-raw session [["first" "one"] ["bad" "two"]])))
          (is (nil? (sqlite/restore-raw session "first")))
          (sqlite/store-raw session [["next" "three"]])
          (is (= (Some "three") (sqlite/restore-raw session "next")))
          (finally (sqlite/close session)))))))
