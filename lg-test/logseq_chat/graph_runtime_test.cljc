(ns logseq-chat.graph-runtime-test
  (:require [clojure.test :refer [deftest is]]
            [ocaml.Logseq_chat_lg_core_native :as ops]
            [logseq-chat.pending-ops :as pending]
            [logseq-chat.storage-codec :as storage]
            [logseq-chat.graph-store :as store]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Datascript :as ds]
            [ocaml.Logseq_chat_graph_runtime :as runtime]))

(deftest semantic-values-preserve-native-primitives
  (run! (fn [[input expected]]
          (is (= (Ok expected) (pending/semantic-value-from-datascript input))))
        [(tuple (ds/String "text") (pending/String-value "text"))
         (tuple (ds/Int 42) (pending/Int-value 42))
         (tuple (ds/Instant 1234) (pending/Instant-value 1234))
         (tuple (ds/Float 0.5) (pending/Float-value 0.5))
         (tuple (ds/Bool false) (pending/Bool-value false))
         (tuple (ds/Keyword "learning") (pending/Keyword-value "learning"))]))

(deftest semantic-maps-preserve-nesting-entry-order-and-duplicate-keys
  (let [input (ds/Map
               (list (tuple (ds/Keyword "nested")
                            (ds/Map (list (tuple (ds/Keyword "flag") (ds/Bool true)))))
                     (tuple (ds/Keyword "duplicate") (ds/Int 1))
                     (tuple (ds/Keyword "duplicate") (ds/Int 2))))
        expected (pending/Map-value
                  [(tuple "nested" (pending/Map-value [(tuple "flag" (pending/Bool-value true))]))
                   (tuple "duplicate" (pending/Int-value 1))
                   (tuple "duplicate" (pending/Int-value 2))])]
    (is (= (Ok expected) (pending/semantic-value-from-datascript input)))))

(deftest semantic-maps-reject-invalid-keys-and-unsupported-values
  (is (= (Error "flashcard state contains a non-keyword key")
         (pending/semantic-value-from-datascript
          (ds/Map (list (tuple (ds/String "invalid") (ds/Int 1))
                        (tuple (ds/Keyword "later") (ds/Int 2)))))))
  (is (= (Error "flashcard state contains an unsupported value")
         (pending/semantic-value-from-datascript (ds/Map (list (tuple (ds/Keyword "invalid") (ds/Ref 42))))))))

(def one (assoc storage/default-schema-attr :indexed true))
(def string-attr (assoc one :value-type (Some (ds/StringType))))
(def ref-attr (assoc one :value-type (Some (ds/RefType))))
(def number-attr (assoc one :value-type (Some (ds/NumberType))))
(def many-ref (assoc ref-attr :cardinality (ds/Many)))
(def schema
  {"block/uuid" (assoc one :value-type (Some (ds/UuidType)) :unique (Some (ds/Identity)))
   "db/ident" (assoc one :value-type (Some (ds/KeywordType)) :unique (Some (ds/Identity)))
   "block/title" string-attr "block/name" string-attr "block/order" string-attr
   "block/page" ref-attr "block/parent" ref-attr "block/link" ref-attr
   "block/refs" many-ref "block/tags" many-ref "block/journal-day" number-attr
   "block/created-at" number-attr "block/updated-at" number-attr
   "logseq.property/status" ref-attr "logseq.property.class/extends" many-ref
   "logseq.property/built-in?" one "logseq.property/hide?" one
   "logseq.property/deleted-at" (assoc one :value-type (Some (ds/InstantType)))
   "logseq.property.recycle/original-parent" ref-attr
   "logseq.property.recycle/original-page" ref-attr
   "logseq.property.recycle/original-order" string-attr
   "logseq.property.fsrs/due" one "logseq.property.fsrs/state" one})

(defn add [id attr value] (ds/Add (ds/Entity_id id) attr value))
(defn base-db [title]
  (ds/db-with
    (list (add 1 "block/uuid" (ds/Uuid "page")) (add 1 "block/title" (ds/String "Page"))
          (add 1 "block/name" (ds/String "page")) (add 1 "block/journal-day" (ds/Int 20260816))
          (add 10 "block/uuid" (ds/Uuid "block")) (add 10 "block/title" (ds/String title))
          (add 10 "block/page" (ds/Ref 1)) (add 10 "block/parent" (ds/Ref 1))
          (add 10 "block/order" (ds/String "a0")) (add 10 "block/created-at" (ds/Int 1))
          (add 10 "block/updated-at" (ds/Int 1)))
    (ds/empty-db :schema (apply list (seq schema)))))

(defn with-store [f]
  (let [path (filename/temp-file "logseq-chat-runtime" ".sqlite")]
    (try
      (store/prepare-staging path)
      (f path)
      (finally (run! #(when (sys/file-exists %) (sys/remove %)) [path (store/staging-path path)])))))

(defn save-title [id before after]
  (record ops/pending_operation (operation-id id) (base-t 42) (state (ops/Queued))
    (intent (ops/Save_title (record ops/pending_title (uuid "block") (expected-title before) (title after))))))

(defn ok? [result] (match result (Ok _) true (Error _) false))
(defn prepares-save? [current op]
  (match (runtime/prepare-sync current op) (Ok ["save-block" _]) true _ false))

(deftest dependent-edits-can-sync-on-an-accepted-projection
  (with-store
    (fn [path]
      (let [current (runtime/create :path path :server_t 42 (ds/conn-from-db (base-db "Old")))
            first-op (save-title "accepted-title" "Old" "First")
            second-op (save-title "next-title" "First" "Second")]
        (is (ok? (runtime/stage current first-op)))
        (is (ok? (runtime/stage current (assoc first-op :state (ops/Accepted 43)))))
        (is (ok? (runtime/stage current second-op)))
        (is (prepares-save? current second-op))))))

(deftest stale-completions-cannot-roll-back-persisted-cursors
  (with-store
    (fn [path]
      (let [current (runtime/create :path path :server_t 42 (ds/conn-from-db (base-db "Old")))
            first-op (save-title "in-flight-title" "Old" "First")
            second-op (save-title "queued-during-flight" "First" "Second")]
        (is (ok? (runtime/stage current first-op)))
        (is (ok? (runtime/stage current second-op)))
        (is (ok? (runtime/stage current (assoc first-op :state (ops/Accepted 43)))))
        (runtime/rebase current :server_t 43 :operation_ids (list))
        (is (prepares-save? current second-op))
        (is (ok? (runtime/stage current (assoc second-op :state (ops/Retryable)))))
        (is (some (fn [op]
                    (and (= "queued-during-flight" (:operation-id op))
                         (= 43 (:base-t op)) (= (ops/Retryable) (:state op))))
                  (ops/logseq-chat-pending-ops-list path)))))))

(deftest reopen-rebases-safe-retries-and-conflicts-stale-deletions
  (with-store
    (fn [path]
      (ops/logseq-chat-pending-ops-save path (assoc (save-title "retry-after-reopen" "Old" "New") :state (ops/Retryable)))
      (let [current (runtime/create-base :path path :server_t 43 (ds/conn-from-db (base-db "Old")))
            persisted (ops/logseq-chat-pending-ops-list path)]
        (is (= 1 (count persisted)))
        (let [op (nth persisted 0)]
          (is (= 43 (:base-t op)))
          (is (= (ops/Queued) (:state op)))
          (is (prepares-save? current op))))))
  (with-store
    (fn [path]
      (ops/logseq-chat-pending-ops-save path
        (record ops/pending_operation (operation-id "unsafe-delete-after-reopen") (base-t 42) (state (ops/Retryable))
          (intent (ops/Delete_blocks (record ops/pending_delete (uuids ["block"]))))))
      (runtime/create-base :path path :server_t 43 (ds/conn-from-db (base-db "Old")))
      (let [persisted (ops/logseq-chat-pending-ops-list path)]
        (is (= 1 (count persisted)))
        (let [op (nth persisted 0)]
          (is (= 43 (:base-t op)))
          (is (match (:state op) (ops/Conflicted _) true _ false)))))))

(deftest rebase-policy-keeps-stale-deletions-unsafe
  (is (not (pending/safe-to-rebase? (pending/Delete-blocks (record pending/pending-delete (uuids ["block"]))))))
  (run! #(is (pending/safe-to-rebase? %))
        [(pending/Save-title (record pending/pending-title (uuid "block") (expected-title "Old") (title "New")))
         (pending/Set-property (record pending/pending-property (uuid "block") (attr "block/title") (expected nil) (value nil)))
         (pending/Insert-block (record pending/pending-insert (uuid "new") (title "") (page-uuid "page") (parent-uuid "page") (order "a1") (created-at 1)))
         (pending/Move-block (record pending/pending-move (uuid "block") (page-uuid "page") (parent-uuid "page") (order "a0")))
         (pending/Move-blocks (record pending/pending-moves (moves [])))
         (pending/Split-block (record pending/pending-split (uuid "block") (expected-title "Old") (before "") (after "Old")
                               (new-uuid "new") (new-order "a1") (created-at 1)))
         (pending/Merge-backward (record pending/pending-merge (uuid "block") (expected-title "Old") (title "Old")
                                  (previous-uuid "page") (expected-previous-title "Page") (merged-title nil)))]))

(deftest split-confirmation-requires-evidence-of-submission
  (let [db (base-db "Changed later")
        intent (pending/Split-block (record pending/pending-split (uuid "other") (expected-title "Old") (before "O") (after "ld")
                                      (new-uuid "block") (new-order "a1") (created-at 1)))
        op (record pending/pending-operation (operation-id "split") (base-t 41) (state pending/Queued) (intent intent))]
    (run! (fn [[state expected]]
            (is (= expected (pending/committed-despite-later-changes? 42 db (assoc op :state state)))))
          [(tuple pending/Queued false) (tuple pending/Retryable false) (tuple pending/Applied false)
           (tuple (pending/Accepted 43) false) (tuple (pending/Accepted 42) true)
           (tuple pending/Submitted true) (tuple (pending/Conflicted "split block UUID already exists") true)
           (tuple (pending/Conflicted "another conflict") false)])
    (is (not (pending/committed-despite-later-changes? 42 (ds/empty-db :schema (apply list (seq schema)))
               (assoc op :state pending/Submitted))))))

(deftest existing-inserts-remain-confirmed-after-later-title-changes
  (let [intent (pending/Insert-block (record pending/pending-insert (uuid "block") (title "Original") (page-uuid "page")
                                       (parent-uuid "page") (order "a0") (created-at 1)))
        op (record pending/pending-operation (operation-id "insert") (base-t 41) (state pending/Queued) (intent intent))]
    (is (pending/committed-despite-later-changes? 42 (base-db "Changed later") op))
    (is (not (pending/committed-despite-later-changes? 42 (ds/empty-db :schema (apply list (seq schema))) op)))))
