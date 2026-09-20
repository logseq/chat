(ns logseq-chat.snapshot-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.snapshot :as snapshot]
            [ocaml.Transit_core.Json :as value]
            [ocaml.Transit_native.Transit.Json :as codec]
            [ocaml.String :as bytes]
            [ocaml.Char :as char]
            [ocaml.Stdlib :as stdlib]))

(defn expect-ok [result]
  (match result (Ok value) value (Error message) (stdlib/failwith message)))

(defn frame [value]
  (let [payload (codec/to-string value)
        length (count payload)]
    (str (bytes/init 4 (fn [index] (char/chr (bit-and (unsigned-bit-shift-right length (* (- 3 index) 8)) 255)))) payload)))

(defn row [addr content addresses]
  (value/Array (list (value/Int addr) (value/String content)
                     (match addresses None (value/Null) (Some text) (value/String text)))))

(def root "[\"^ \",\"~:schema\",[\"^ \",\"~:block/title\",[\"^ \",\"~:db/valueType\",\"~:db.type/string\"]]]")

(def wire (frame (value/Array (list (row 0 root None) (row 1 "[]" None) (row 7 "[\"^ \",\"~:keys\",[]]" (Some "[3,4]"))))))

(deftest partial-prefix-payload-and-import-metadata
  (let [parser (snapshot/create-parser 4096)]
    (is (empty? (expect-ok (snapshot/feed parser (subs wire 0 3)))))
    (is (empty? (expect-ok (snapshot/feed parser (subs wire 3 14)))))
    (let [rows (expect-ok (snapshot/feed parser (subs wire 14)))
          importer (snapshot/create-import "graph-1" "65.33" 48192 3)]
      (is (= [0 1 7] (mapv :addr rows)))
      (is (= root (:content (nth rows 0))))
      (is (= (Some "[3,4]") (:addresses (nth rows 2))))
      (expect-ok (snapshot/finish-parser parser))
      (expect-ok (snapshot/accept-rows importer rows))
      (let [completed (expect-ok (snapshot/finish-import importer))]
        (is (= 48192 (:applied-server-t completed)))
        (is (= "65.33" (:schema-version completed)))
        (is (= "graph-1" (:graph-id completed)))
        (is (= 3 (:row-count completed)))))))

(deftest incomplete-oversized-and-unsigned-frames
  (let [parser (snapshot/create-parser 4096)]
    (expect-ok (snapshot/feed parser (subs wire 0 3)))
    (is (= (Error "incomplete framed snapshot stream") (snapshot/finish-parser parser))))
  (run! (fn [[limit input]]
          (is (= (Error "snapshot frame exceeds configured size limit")
                 (snapshot/feed (snapshot/create-parser limit) input))))
        [(tuple 2 wire) (tuple 4096 (bytes/init 4 #(char/chr (if (= % 0) 128 0))))]))

(deftest multiple-frames-preserve-row-order
  (let [parser (snapshot/create-parser 4096)
        combined (str (frame (value/Array (list))) wire (frame (value/Array (list (row 9 "last" None)))))]
    (is (= [0 1 7 9] (mapv :addr (expect-ok (snapshot/feed parser combined)))))
    (expect-ok (snapshot/finish-parser parser))))

(deftest rejected-import-batches-do-not-mutate-progress
  (let [rows (expect-ok (snapshot/feed (snapshot/create-parser 4096) wire))
        valid (list (nth rows 0) (nth rows 1))
        unordered (snapshot/create-import "graph-1" "65.33" 0 2)
        bounded (snapshot/create-import "g" "s" 0 2)]
    (is (= (Error "snapshot row addresses must be strictly increasing")
           (snapshot/accept-rows unordered (list (nth rows 1) (nth rows 0)))))
    (expect-ok (snapshot/accept-rows unordered valid))
    (is (= 2 (:row-count (expect-ok (snapshot/finish-import unordered)))))
    (is (= (Error "snapshot contains more rows than advertised") (snapshot/accept-rows bounded rows)))
    (expect-ok (snapshot/accept-rows bounded valid))
    (is (= 2 (:row-count (expect-ok (snapshot/finish-import bounded)))))))

(deftest malformed-snapshot-rows-are-rejected
  (run! (fn [payload]
          (match (snapshot/feed (snapshot/create-parser 4096) (frame payload))
            (Error _) (is true)
            (Ok _) (stdlib/failwith "malformed snapshot accepted")))
        [(value/Null) (value/Array (list (value/Int 0)))
         (value/Array (list (value/Array (list (value/Int 0) (value/String "x") (value/Bool true)))))]))
