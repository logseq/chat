(ns logseq-chat.sqlite-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.sqlite :as sqlite]
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
