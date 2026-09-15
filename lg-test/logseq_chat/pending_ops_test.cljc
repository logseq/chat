(ns logseq-chat.pending-ops-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.pending-ops :as ops]
            [ocaml.Yojson.Basic :as json]
            [ocaml.In_channel :as input]))

(defn move-value [uuid] (record ops/pending-move (uuid uuid) (page-uuid "page") (parent-uuid "parent") (order "a0")))
(defn move [uuid] (ops/Move-block (move-value uuid)))
(def intents
  [(ops/Save-title (record ops/pending-title (uuid "block") (expected-title "Old") (title "New")))
   (ops/Set-property (record ops/pending-property (uuid "block") (attr "user.property/effort") (expected (Some (ops/Int-value 1))) (value (Some (ops/Int-value 2)))))
   (ops/Set-property (record ops/pending-property (uuid "block") (attr "user.property/flag") (expected None) (value None)))
   (ops/Set-properties
     (record ops/pending-properties (uuid "block")
      (changes [(record ops/property-change (attr "logseq.property.fsrs/due") (expected None) (value (Some (ops/Int-value 86400000))))
                (record ops/property-change (attr "logseq.property.fsrs/state") (expected None)
                        (value (Some (ops/Map-value [(tuple "state" (ops/Keyword-value "learning"))
                                                    (tuple "stability" (ops/Float-value 0.4))
                                                    (tuple "reps" (ops/Int-value 1))]))))])))
   (ops/Insert-block (record ops/pending-insert (uuid "new") (title "New") (page-uuid "page") (parent-uuid "parent") (order "a1") (created-at 42)))
   (ops/Create-asset (record ops/pending-asset (uuid "asset") (title "photo.png") (page-uuid "page") (parent-uuid "parent") (order "a2")
                      (created-at 43) (asset-type "png") (asset-size 2048) (asset-checksum "abc123")))
   (move "block")
   (ops/Move-blocks (record ops/pending-moves (moves [(move-value "first") (move-value "second")])))
   (ops/Split-block (record ops/pending-split (uuid "block") (expected-title "Old") (before "O") (after "ld") (new-uuid "new") (new-order "a1") (created-at 42)))
   (ops/Merge-backward (record ops/pending-merge (uuid "source") (expected-title "Source") (title "Source") (previous-uuid "previous")
                        (expected-previous-title "Previous") (merged-title (Some "PreviousSource"))))
   (ops/Merge-backward (record ops/pending-merge (uuid "source") (expected-title "Source") (title "Source") (previous-uuid "previous")
                        (expected-previous-title "Previous") (merged-title None)))
   (ops/Delete-blocks (record ops/pending-delete (uuids ["first" "second"])))
   (ops/Create-tag (record ops/pending-create (uuid "tag") (title "Project") (created-at 42)))])

(def page-intents
  [(ops/Create-page (record ops/pending-create (uuid "page") (title "Page") (created-at 42)))
   (ops/Create-journal (record ops/pending-journal (page-uuid "page") (block-uuid "block") (title "Journal") (journal-day 20260915) (created-at 43)))
   (ops/Add-tag (record ops/pending-tag (uuid "block") (tag-uuid "tag")))
   (ops/Set-favorite (record ops/pending-favorite (page-uuid "page") (favorite-uuid "favorite") (favorite true) (order "a0") (created-at 44)))
   (ops/Set-favorite (record ops/pending-favorite (page-uuid "page") (favorite-uuid "favorite") (favorite false) (order "a0") (created-at 44)))
   (ops/Delete-page (record ops/pending-page-delete (page-uuid "page") (order "a0") (deleted-at 45)))])

(deftest persisted-intents-preserve-independent-legacy-golden-fixtures
  (let [all (into (conj intents (ops/Save-title (record ops/pending-title (uuid "duplicate") (expected-title "") (title "first")))) page-intents)
        expected (string/split-lines (input/with-open-text "../core/pending_ops_golden.jsonl" input/input-all))]
    (is (= (count all) (count expected)))
    (is (= expected (mapv #(json/to-string (ops/intent-json %)) all)))
    (run! #(is (= % (ops/intent-of-json (ops/intent-json %)))) all))
  (is (= ["save-block" "save-block" "save-block" "save-block" "insert-blocks" "insert-blocks"
          "move-blocks" "move-blocks" "split-block" "merge-blocks" "merge-blocks" "delete-blocks" "save-block"]
         (mapv ops/outliner-op intents)))
  (is (= ["save-block" "insert-blocks" "save-block" "insert-blocks" "delete-blocks" "delete-page"]
         (mapv ops/outliner-op page-intents))))

(defn invalid-value? [input]
  (try (do (ops/semantic-value-of-json input) false) (catch (Invalid_argument _) true)))
(defn invalid-intent? [input]
  (try (do (ops/intent-of-json input) false) (catch (Invalid_argument _) true)))

(deftest semantic-values-round-trip-with-order-and-duplicates
  (run! #(is (= % (ops/semantic-value-of-json (ops/semantic-value-json %))))
        [(ops/String-value "text") (ops/Int-value 42) (ops/Instant-value 1776000000000)
         (ops/Bool-value true) (ops/Ref-uuid "uuid") (ops/Ref-ident "db/ident")
         (ops/Float-value 0.4) (ops/Keyword-value "learning")
         (ops/Map-value [(tuple "state" (ops/Keyword-value "learning")) (tuple "stability" (ops/Float-value 0.4))
                         (tuple "nested" (ops/Map-value [(tuple "reps" (ops/Int-value 1))]))
                         (tuple "last-repeat" (ops/Instant-value 1776000000000))])
         (ops/Map-value [(tuple "duplicate" (ops/Int-value 1)) (tuple "duplicate" (ops/Int-value 2))])])
  (run! #(is (invalid-value? (json/from-string %)))
        ["\"invalid\"" "{\"value\":1,\"type\":\"int\"}"
         "{\"type\":\"int\",\"value\":1,\"extra\":null}" "{\"type\":\"map\",\"value\":[null]}"])
  (is (= (ops/Float-value 1.0) (ops/semantic-value-of-json (json/from-string "{\"type\":\"float\",\"value\":1}"))))
  (is (nil? (ops/option-value ops/semantic-value-of-json (ops/option-json ops/semantic-value-json None))))
  (is (= (Some (ops/String-value "value"))
         (ops/option-value ops/semantic-value-of-json (ops/option-json ops/semantic-value-json (Some (ops/String-value "value")))))))

(deftest persisted-state-normalization-and-legacy-cursors
  (run! #(is (= % (ops/state-of-string (ops/state-string %))))
        [ops/Queued ops/Submitted (ops/Accepted 42) ops/Retryable ops/Applied (ops/Conflicted "changed")])
  (run! (fn [[value expected]] (is (= expected (ops/state-of-string value))))
        [(tuple "accepted" ops/Submitted) (tuple "accepted:nope" ops/Retryable) (tuple "unknown" ops/Retryable)
         (tuple "" ops/Retryable) (tuple "accepted:" ops/Retryable) (tuple "accepted:-1" (ops/Accepted -1))
         (tuple "accepted:0x2a" (ops/Accepted 42)) (tuple "accepted:1_000" (ops/Accepted 1000))
         (tuple "accepted:99999999999999999999999" ops/Retryable)
         (tuple "conflicted:" (ops/Conflicted "")) (tuple "conflicted:one:two" (ops/Conflicted "one:two"))]))

(deftest missing-and-duplicate-fields-preserve-legacy-behavior
  (run! (fn [input]
          (is (try (do (ops/intent-of-json (json/from-string input)) false) (catch Not_found true))))
        ["{\"type\":\"set-property\",\"uuid\":\"block\",\"attr\":\"flag\"}"
         "{\"type\":\"set-property\",\"uuid\":\"block\",\"attr\":\"flag\",\"expected\":null}"])
  (is (= (ops/Save-title (record ops/pending-title (uuid "duplicate") (expected-title "") (title "first")))
         (ops/intent-of-json (json/from-string "{\"type\":\"save-title\",\"uuid\":\"duplicate\",\"expectedTitle\":\"\",\"title\":\"first\",\"title\":\"second\"}")))))

(defn replace-field [intent field value]
  (match (ops/intent-json intent)
    (tag Assoc fields) (ops/json-object (into [(tuple field value)] (remove (fn [[key _]] (= key field)) fields)))
    _ (ops/intent-json intent)))

(deftest invalid-intent-shapes-are-rejected
  (run! #(is (invalid-intent? (json/from-string %)))
        ["\"invalid\"" "{\"type\":1}" "{\"type\":\"unknown\"}"
         "{\"type\":\"insert-block\",\"uuid\":\"new\",\"title\":\"New\",\"pageUuid\":\"page\",\"parentUuid\":\"page\",\"order\":\"a0\",\"createdAt\":\"invalid\"}"
         "{\"type\":\"move-blocks\",\"moves\":null}" "{\"type\":\"move-blocks\",\"moves\":[null]}"
         "{\"type\":\"delete-blocks\",\"uuids\":null}" "{\"type\":\"delete-blocks\",\"uuids\":[1]}"])
  (is (invalid-intent? (replace-field (nth intents 8) "createdAt" (tag String "invalid"))))
  (is (invalid-intent? (replace-field (nth intents 9) "mergedTitle" (tag Int 1))))
  (is (= (nth intents 10)
         (ops/intent-of-json
           (match (ops/intent-json (nth intents 9))
             (tag Assoc fields) (ops/json-object (vec (remove (fn [[key _]] (= key "mergedTitle")) fields)))
             other other)))))
