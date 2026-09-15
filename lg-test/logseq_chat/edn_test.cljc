(ns logseq-chat.edn-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.edn :as edn]
            [ocaml.Melange_edn_native :as native]
            [ocaml.Stdlib :as stdlib]))

(deftest typed-map-set-and-keyword-roundtrip
  (match (edn/decode "{:block/tags #{:logseq.class/Task}}")
    (Error message) (stdlib/failwith message)
    (Ok value)
    (do
    (match value
      (native/Any (native/Map entries))
      (do
        (is (= 1 (count entries)))
        (let [[key tags] (nth entries 0)]
          (match key
            (native/Any (native/Keyword keyword))
            (is (= "block/tags" (native/keyword-to-string keyword)))
            _ (stdlib/failwith "expected a keyword map key"))
          (match tags
            (native/Any (native/Set values))
            (do (is (= 1 (count values)))
                (match (nth values 0)
                  (native/Any (native/Keyword keyword))
                  (is (= "logseq.class/Task" (native/keyword-to-string keyword)))
                  _ (stdlib/failwith "expected a keyword set member")))
            _ (stdlib/failwith "expected an EDN set"))))
      _ (stdlib/failwith "expected a typed EDN map"))
    (match (edn/decode (edn/encode value))
      (Ok _) (is true)
      (Error message) (stdlib/failwith message)))))
