(ns logseq-chat.sync-checkpoint-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.sync-checkpoint :as checkpoint]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]))

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
