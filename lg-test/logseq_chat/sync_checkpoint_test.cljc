(ns logseq-chat.sync-checkpoint-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.sync-checkpoint :as checkpoint]
            [ocaml.Transit_core.Json :as value]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]))

(defn decode-fields [fields]
  (checkpoint/decode-map
   (apply list (map (fn [[key value]] (tuple (value/Keyword key) value)) fields))))

(deftest checkpoint-validates-every-required-field
  (let [fields {"format-version" (value/Int 1)
                "graph-id" (value/String "graph")
                "schema-version" (value/String "1")
                "applied-server-t" (value/Int 0)}
        invalid (Error "invalid graph sync checkpoint")]
    (is (= (Ok (checkpoint/create "graph" "1" 0)) (decode-fields fields)))
    (doseq [field (keys fields)]
      (is (= invalid (decode-fields (dissoc fields field))))
      (is (= invalid (decode-fields (assoc fields field (value/Bool false))))))
    (is (= invalid (decode-fields (assoc fields "format-version" (value/Int 2)))))
    (is (= invalid (decode-fields (assoc fields "applied-server-t" (value/Int -1)))))))

(defn remove-file! [path]
  (when (sys/file-exists path) (sys/remove path)))

(deftest checkpoint-persists-privately-and-roundtrips
  (let [path (filename/temp-file "logseq-chat-sync-checkpoint" ".transit")]
    (sys/remove path)
    (try
      (is (= (Ok nil) (checkpoint/load-checkpoint path)))
      (match (checkpoint/save-checkpoint-atomic path (checkpoint/create "graph-1" "65.33" 48192))
        (Ok _) (is true)
        (Error message) (is false message))
      (is (= 0 (bit-and (:st-perm (unix/stat path)) 63)))
      (match (checkpoint/load-checkpoint path)
        (Ok (Some restored))
        (do (is (= "graph-1" (:graph-id restored)))
            (is (= "65.33" (:schema-version restored)))
            (is (= 48192 (:applied-server-t restored))))
        _ (is false "checkpoint disappeared or failed to load"))
      (finally
        (remove-file! path)
        (remove-file! (str path ".tmp"))))))

(deftest failed-save-preserves-directory-and-removes-temporary-file
  (let [path (filename/temp-file "logseq-chat-checkpoint-directory" "")]
    (sys/remove path)
    (unix/mkdir path 448)
    (try
      (match (checkpoint/save-checkpoint-atomic path (checkpoint/create "graph" "1" 0))
        (Error _) (is true)
        (Ok _) (is false "checkpoint replaced a directory"))
      (is (not (sys/file-exists (str path ".tmp"))))
      (finally
        (remove-file! (str path ".tmp"))
        (unix/rmdir path)))))
