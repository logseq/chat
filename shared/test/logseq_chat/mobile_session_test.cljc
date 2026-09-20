(ns logseq-chat.mobile-session-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.mobile-session :as mobile]
            [logseq-chat.mobile-database :as database]
            [logseq-chat.rpc-session :as rpc]
            [logseq-chat.sqlite :as sqlite]
            [logseq-chat.cache-model :as model]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]))

(def snapshot "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")

(def catalog "{\"graphs\":[{\"graph-id\":\"plain\",\"graph-name\":\"Plain\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true}]}")

(defn host []
  (mobile/create (fn [_] (stdlib/failwith "unexpected crypto call"))))

(defn remove-tree [path]
  (when (sys/file-exists path)
    (if (sys/is-directory path)
      (do (run! #(remove-tree (filename/concat path %)) (sys/readdir path)) (unix/rmdir path))
      (sys/remove path)))
  (stdlib/ignore 0))

(defn with-host [f]
  (let [path (filename/temp-file "chat-mobile-session" "") host (host)]
    (sys/remove path)
    (unix/mkdir path 493)
    (try (f host path)
         (finally (database/close (:database host)) (remove-tree path)))))

(defn open-request [path]
  (str "{\"apiVersion\":1,\"method\":\"open\",\"params\":{\"path\":"
       (json/to-string (tag String path)) "}}"))

(deftest requests-without-a-database-path-use-the-existing-session
  (let [host (host) previous @(:session host)]
    (run! (fn [request]
            (is (= (rpc/call previous request) (mobile/call host request)))
            (is (identical? previous @(:session host))))
          [snapshot "{" "null" "{\"apiVersion\":2,\"method\":\"snapshot\",\"params\":{}}"
           "{\"apiVersion\":1,\"method\":\"open\",\"params\":{}}"
           "{\"apiVersion\":1,\"method\":\"open\",\"params\":{\"path\":42}}"])))

(deftest opening-a-catalog-replaces-the-session-and-returns-its-snapshot
  (with-host
    (fn [host dir]
      (let [path (filename/concat dir "catalog.sqlite") saved (sqlite/open-session path)
            previous @(:session host)]
        (try (sqlite/store-string saved "logseq-chat/graph-catalog/v1" catalog)
             (finally (sqlite/close saved)))
        (model/cache-local-message (:model (rpc/state previous)) "draft" "Old session" 100)
        (let [response (mobile/call host (open-request path)) current @(:session host)]
          (is (not (identical? previous current)))
          (is (= (rpc/call current snapshot) response))
          (is (= (tag Bool true) (json-util/member "ok" (json/from-string response))))
          (is (= ["plain"] (mapv :id (:available-graphs (rpc/state current)))))
          (is (nil? (model/read-block (:model (rpc/state current)) "draft"))))))))

(deftest reopening-closes-the-old-catalog-and-retains-persisted-catalog-data
  (with-host
    (fn [host dir]
      (let [path (filename/concat dir "catalog.sqlite")]
        (mobile/call host (open-request path))
        (if-some [first @(:catalog (:database host))]
          (do
            (sqlite/store-string first "logseq-chat/graph-catalog/v1" catalog)
            (mobile/call host (open-request path))
            (is @(:closed first))
            (is (= ["plain"] (mapv :id (:available-graphs (rpc/state @(:session host)))))))
          (stdlib/failwith "catalog was not opened"))))))

(deftest database-open-failure-propagates-without-replacing-the-rpc-session
  (with-host
    (fn [host dir]
      (mobile/call host (open-request (filename/concat dir "catalog.sqlite")))
      (let [previous @(:session host)]
        (is (thrown? Failure
              (mobile/call host (open-request (filename/concat dir "missing/catalog.sqlite")))))
        (is (identical? previous @(:session host)))
        (is (nil? @(:catalog (:database host))))))))
