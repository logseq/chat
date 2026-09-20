(ns logseq-chat.sync-state-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.sync-session :as session]
            [logseq-chat.sync-protocol :as protocol]
            [ocaml.Stdlib :as stdlib]))

(defn change [graph schema before after]
  (record protocol/sync-change-set
          (format-version 1) (graph-id graph) (schema-version schema)
          (t-before before) (t after) (upserts (list)) (deleted (list)) (operation-ids (list))))

(deftest only-successful-websocket-application-advances-cursor
  (let [state (session/create-state "graph-1" "65.33" 10)
        applied (atom false)]
    (session/submission-accepted state 11)
    (is (= 10 (session/applied-server-t state)))
    (is (= (Ok (stdlib/ignore 0))
           (session/apply-validated-change-set
            state (change "graph-1" "65.33" 10 11)
            (fn [_] (reset! applied true) (Ok (stdlib/ignore 0))))))
    (is @applied)
    (is (= 11 (session/applied-server-t state)))))

(deftest invalid-events-never-reach-database
  (let [state (session/create-state "graph-1" "65.33" 20)]
    (run! (fn [[expected event]]
            (is (= (Error expected)
                   (session/apply-validated-change-set
                    state event (fn [_] (stdlib/failwith "invalid event reached database")))))
            (is (= 20 (session/applied-server-t state))))
          [(tuple session/Cursor_mismatch (change "graph-1" "65.33" 19 21))
           (tuple session/Graph_mismatch (change "graph-2" "65.33" 20 21))
           (tuple session/Schema_mismatch (change "graph-1" "66" 20 21))
           (tuple session/Unsupported_format (assoc (change "graph-1" "65.33" 20 21) :format-version 2))
           (tuple session/Invalid_cursor (change "graph-1" "65.33" 20 19))])))

(deftest failed-application-preserves-error-and-cursor
  (let [state (session/create-state "graph-1" "65.33" 20)]
    (is (= (Error (session/Apply_failed "checkpoint unavailable"))
           (session/apply-validated-change-set
            state (change "graph-1" "65.33" 20 21) (fn [_] (Error "checkpoint unavailable")))))
    (is (= 20 (session/applied-server-t state)))))
