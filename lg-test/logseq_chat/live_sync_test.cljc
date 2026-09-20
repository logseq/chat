(ns logseq-chat.live-sync-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.live-sync :as live]
            [logseq-chat.api :as api]
            [logseq-chat.sync-session :as session]
            [ocaml.Sys :as sys]
            [ocaml.Filename :as filename]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]))

(defn failure-message [f]
  (try (f) nil (catch (Failure message) (Some message))))

(deftest snapshot-urls-preserve-absolute-and-relative-addresses
  (is (= "https://cdn.example/a" (live/absolute-url "https://example/api" "https://cdn.example/a")))
  (is (= "http://cdn.example/a" (live/absolute-url "https://example/api" "http://cdn.example/a")))
  (is (= "https://example/snapshot" (live/absolute-url "https://example/api/" "/snapshot")))
  (is (= "relative" (live/absolute-url "https://example/api" "relative")))
  (is (= "" (live/absolute-url "https://example/api" ""))))

(deftest pull-cursor-only-changes-on-recognized-success
  (let [metadata (record session/snapshot-metadata
                         (url "/snapshot") (content-encoding nil) (baseline-t 7)
                         (schema-version "1") (row-count 12))]
    (is (= (assoc metadata :baseline-t 9)
           (live/merge-pull-cursor metadata "{\"type\":\"pull/ok\",\"t\":9}")))
    (is (= (assoc metadata :baseline-t 9)
           (live/merge-pull-cursor metadata "{\"type\":\"pull/ok\",\"t\":9.8}")))
    (run! (fn [body] (is (= metadata (live/merge-pull-cursor metadata body))))
          ["invalid" "[]" "null" "{}" "{\"type\":\"pull/error\",\"t\":9}"
           "{\"type\":\"pull/ok\",\"t\":\"9\"}"])))

(deftest http-results-preserve-accepted-statuses-and-step-context
  (let [created (api/response 201 "created") rejected (api/response 409 "stale")]
    (is (= created (live/expect-response "create" [200 201] (Ok created))))
    (is (= rejected (live/expect-response "submit" [200 409] (Ok rejected))))
    (is (= (Some "create: HTTP 409 stale")
           (failure-message #(live/expect-response "create" [200 201] (Ok rejected)))))
    (is (= (Some "download: offline")
           (failure-message #(live/expect-response "download" [200] (Error "offline")))))))

(deftest json-fields-retain-original-decoding-semantics
  (let [input (live/json-object "{\"s\":\"\",\"n\":3.9,\"b\":true}")]
    (is (= (Some "") (live/json-string "s" input)))
    (is (= (Some 3) (live/json-int "n" input)))
    (is (nil? (live/json-int "b" input)))
    (is (nil? (live/json-string "missing" input))))
  (is (= (Some "expected a JSON object: []") (failure-message #(live/json-object "[]")))))

(deftest temporary-directories-clean-up-nested-files
  (let [path (live/with-temp-dir "lg-live-test"
               (fn [path]
                 (let [nested (filename/concat path "nested")]
                   (unix/mkdir nested 493)
                   (let [channel (stdlib/open-out-bin (filename/concat nested "data"))]
                     (stdlib/output-string channel "snapshot")
                     (stdlib/close-out channel)))
                 (is (sys/file-exists path))
                 path))]
    (is (not (sys/file-exists path)))
    (live/remove-tree path)))

(deftest temporary-directories-clean-up-when-the-flow-fails
  (let [created (atom "")]
    (is (= (Some "flow failed")
           (failure-message #(live/with-temp-dir "lg-live-failure"
                               (fn [path] (reset! created path) (throw (Failure "flow failed")))))))
    (is (not (sys/file-exists @created)))))

(deftest asset-mismatch-quotes-values-without-changing-case
  (is (= "expected \"lowercase\", got \"Mixed Case\""
         (live/asset-mismatch "lowercase" "Mixed Case"))))
