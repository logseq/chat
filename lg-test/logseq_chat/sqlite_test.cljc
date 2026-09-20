(ns logseq-chat.sqlite-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.sqlite :as sqlite]
            [logseq-chat.cache-model :as model]
            [clojure.string :as string]
            [logseq-chat.rpc-session :as rpc-session]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Marshal :as marshal]
            [ocaml.Transit_native.Transit.Json :as transit]
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
          (sqlite/store-raw session
                            [["broken" "not transit"]
                             ["legacy" (marshal/to-string "old" (list))]
                             ["future" "[\"^ \",\"~:format-version\",2,\"~:value-type\",\"~:string\",\"~:value\",\"future\"]"]])
          (is (nil? (sqlite/restore-string session "broken")))
          (is (nil? (sqlite/restore-string session "legacy")))
          (is (nil? (sqlite/restore-string session "future")))
          (finally (sqlite/close session)))))))

(deftest opening-errors-preserve-failure-contract
  (with-database
    (fn [path]
      (is (thrown? Failure (sqlite/open-session (filename/concat path "child.sqlite")))))))

(deftest sqlite-errors-preserve-failure-contract
  (with-database
    (fn [path]
      (let [session (sqlite/open-session path)]
        (try
          (is (thrown-with-msg? Failure #"no such table"
                (sqlite/execute session "INSERT INTO missing_table VALUES (1)")))
          (is (thrown-with-msg? Failure #"no such table"
                (sqlite/with-statement session "SELECT * FROM missing_table" (fn [_] nil))))
          (sqlite/store-string session "after-error" "usable")
          (is (= (Some "usable") (sqlite/restore-string session "after-error")))
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
          (sqlite/store-raw session [["legacy-tail" (marshal/to-string (ds/Storage_tail (list)) (list))]])
          (is (nil? ((:storage-restore storage) "legacy-tail")))
          (is (= (Some "[]") (sqlite/decode-envelope "datascript-storage"
                                                     (or (sqlite/restore-raw session "tail") ""))))
          ((:storage-delete storage) (list "tail"))
          (is (nil? ((:storage-restore storage) "tail")))
          (is (= (list "metadata" "legacy-tail") ((:storage-list-addresses storage))))
          (finally (sqlite/close session)))))))

(deftest cached-block-survives-reopening
  (with-database
    (fn [path]
      (let [session (sqlite/open-session path)
            cache (model/create (Some (sqlite/storage session)))]
        (try (model/cache-local-message cache "local-persisted" "Persisted offline capture" 1776000000000)
             (model/upsert-statuses cache
                                    [(record model/status (uuid "status-waiting") (ident (Some "user.status/waiting"))
                                             (title "Waiting") (icon-type (Some "tabler-icon"))
                                             (icon-id (Some "clock")) (icon-color (Some "#7c3aed")))])
             (finally (sqlite/close session))))
      (let [session (sqlite/open-session path)]
        (try
          (let [cache (model/create (Some (sqlite/storage session)))
                block (model/read-block cache "local-persisted")]
            (is (= (Some "Persisted offline capture") (some-> block :title)))
            (is (= (Some "pending") (some-> block :sync-status)))
            (is (string/starts-with? (or (some-> block :page-id) "") "journal/"))
            (is (= ["Waiting"] (mapv :title (model/all-statuses cache))))
            (is (= [(Some "#7c3aed")] (mapv :icon-color (model/all-statuses cache)))))
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
          (is (thrown-with-msg? Failure #"rejected"
                (sqlite/store-raw session [["first" "one"] ["bad" "two"]])))
          (is (nil? (sqlite/restore-raw session "first")))
          (sqlite/store-raw session [["next" "three"]])
          (is (= (Some "three") (sqlite/restore-raw session "next")))
          (finally (sqlite/close session)))))))

(deftest metadata-has-versioned-transit-envelope
  (with-database
    (fn [path]
      (let [session (sqlite/open-session path)]
        (try
          (sqlite/store-string session "metadata" "value")
          (is (= (transit/Map (list (tuple (transit/Keyword "format-version") (transit/Int 1))
                                    (tuple (transit/Keyword "value-type") (transit/Keyword "string"))
                                    (tuple (transit/Keyword "value") (transit/String "value"))))
                 (transit/of-string (or (sqlite/restore-raw session "metadata") ""))))
          (finally (sqlite/close session)))))))

(deftest rpc-restart-isolates-the-open-graph
  (with-database
    (fn [path]
      (let [session (sqlite/open-session path)]
        (try
          (let [app (rpc-session/create-session (assoc rpc-session/default-options
                                                       :storage (Some (sqlite/storage session))))]
            (rpc-session/call app "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"send\",\"payload\":\"{\\\"text\\\":\\\"Survives restart\\\",\\\"uuid\\\":\\\"local-restart\\\",\\\"now\\\":1776000000000}\"}}"))
          (finally (sqlite/close session))))
      (let [session (sqlite/open-session path)
            remote (record model/block
                           (uuid "remote-existing") (title "Existing server block")
                           (page-id "journal/2026-04-13") (parent-id None) (order None)
                           (created-at 1776000000001) (updated-at 1776000000001)
                           (sync-status "synced") (tags (list)) (references (list))
                           (breadcrumbs (list)) (status None) (is-asset false)
                           (asset-type None) (asset-size None) (asset-checksum None)
                           (local-path None) (journal None))]
        (try
          (let [app (rpc-session/create-session (assoc rpc-session/default-options
                                                       :storage (Some (sqlite/storage session))
                                                       :graph-blocks (Some (fn [] (Some (list remote))))))]
            (model/upsert-journal-page (:model (rpc-session/state app)) "journal/2026-04-13" 20260413 "")
            (let [response (json/from-string (rpc-session/call app "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}"))
                  blocks (json-util/to-list (json-util/member "blocks" (json-util/member "result" response)))
                  uuids (mapv (fn [block] (json-util/to-string (json-util/member "uuid" block))) blocks)]
              (is (not-any? #(= % "local-restart") uuids))
              (is (some #(= % "remote-existing") uuids))))
          (finally (sqlite/close session)))))))

(def catalog "{\"graphs\":[{\"graph-id\":\"plain-graph\",\"graph-name\":\"Sync 2\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true}]}")

(deftest catalog-survives-reopening-and-configures-rpc
  (with-database
    (fn [path]
      (let [session (sqlite/open-session path)]
        (try (sqlite/store-string session "logseq-chat/graph-catalog/v1" catalog)
             (finally (sqlite/close session))))
      (let [session (sqlite/open-session path)]
        (try
          (is (= (Some catalog) (sqlite/restore-string session "logseq-chat/graph-catalog/v1")))
          (let [app (rpc-session/create-session (assoc rpc-session/default-options
                                                       :storage (Some (sqlite/storage session))
                                                       :load-graph-catalog (Some (fn [] (sqlite/restore-string session "logseq-chat/graph-catalog/v1")))))
                response (json/from-string (rpc-session/call app "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"configure\",\"payload\":\"{\\\"baseUrl\\\":\\\"http://127.0.0.1:8787\\\",\\\"graphId\\\":\\\"plain-graph\\\",\\\"token\\\":\\\"\\\"}\"}}"))
                result (json-util/member "result" response)]
            (is (= "Sync 2" (json-util/to-string (json-util/member "graphName" result))))
            (is (= 1 (count (json-util/to-list (json-util/member "graphs" result))))))
          (finally (sqlite/close session)))))))
