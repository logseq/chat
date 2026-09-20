(ns logseq-chat.asset-files-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.asset-files :as files]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]))

(defn with-directory [f]
  (let [path (filename/temp-file "lg-asset-files-test" "")]
    (sys/remove path)
    (unix/mkdir path 448)
    (try (f path)
         (finally
           (run! #(sys/remove (filename/concat path %)) (sys/readdir path))
           (unix/rmdir path)))))

(defn expect-ok [result]
  (match result (Ok value) value (Error message) (throw (Failure message))))

(deftest relative-assets-resolve-against-the-documents-directory
  (is (= "/documents/assets/image.png"
         (files/resolve-path (Some "/documents/graphs/id/sync.checkpoint") "assets/image.png")))
  (is (= "assets/image.png" (files/resolve-path nil "assets/image.png")))
  (is (= "/tmp/image.png" (files/resolve-path (Some "/documents/graphs/id/sync.checkpoint") "/tmp/image.png"))))

(deftest asset-file-roundtrip-preserves-bytes
  (with-directory
    (fn [dir]
      (let [path (filename/concat dir "source") contents "plain\u0000asset\n"]
        (expect-ok (files/write-file path contents))
        (is (= (Ok contents) (files/read-file path)))
        (expect-ok (files/write-file path ""))
        (is (= (Ok "") (files/read-file path)))))))

(deftest file-errors-retain-operation-context
  (with-directory
    (fn [dir]
      (is (match (files/read-file (filename/concat dir "missing"))
            (Error message) (string/starts-with? message "read asset for encryption: ") _ false))
      (is (match (files/write-file dir "data")
            (Error message) (string/starts-with? message "write encrypted asset: ") _ false)))))

(deftest encrypted-assets-use-a-separate-file-next-to-the-source
  (with-directory
    (fn [dir]
      (let [source (filename/concat dir "source") contents "asset\u0000bytes"
            encrypt (fn [graph-id bytes] (Ok (str graph-id ":" bytes)))]
        (expect-ok (files/write-file source contents))
        (let [[path size] (expect-ok (files/encrypt-file encrypt "graph" source))]
          (is (not= source path))
          (is (= dir (filename/dirname path)))
          (is (string/starts-with? (filename/basename path) "logseq-chat-e2ee-"))
          (is (string/ends-with? path ".transit"))
          (is (= (count (str "graph:" contents)) size))
          (is (= (Ok (str "graph:" contents)) (files/read-file path)))
          (is (= (Ok contents) (files/read-file source))))))))

(deftest encryption-errors-do-not-create-output-files
  (with-directory
    (fn [dir]
      (let [source (filename/concat dir "source")]
        (expect-ok (files/write-file source "plain"))
        (is (= (Error "locked") (files/encrypt-file (fn [_ _] (Error "locked")) "graph" source)))
        (is (= ["source"] (vec (sys/readdir dir))))
        (is (= (Ok "plain") (files/read-file source)))))))

(deftest missing-source-does-not-invoke-encryption
  (with-directory
    (fn [dir]
      (let [called (atom false)
            result (files/encrypt-file (fn [_ bytes] (reset! called true) (Ok bytes))
                                       "graph" (filename/concat dir "missing"))]
        (is (match result (Error _) true _ false))
        (is (not @called))
        (is (empty? (sys/readdir dir)))))))
