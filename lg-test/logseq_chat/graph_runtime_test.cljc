(ns logseq-chat.graph-runtime-test
  (:require [clojure.test :refer [deftest is]]
            [ocaml.Logseq_chat_lg_core_native :as ops]
            [logseq-chat.pending-ops :as pending]
            [logseq-chat.storage-codec :as storage]
            [logseq-chat.graph-store :as store]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Datascript :as ds]
            [ocaml.Transit_native.Transit.Json :as transit]
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

(defn with-runtime [f]
  (with-store (fn [path]
                (let [conn (ds/conn-from-db (base-db "Old"))
                      current (runtime/create :path path :server_t 42 conn)]
                  (f path conn current)))))

(defn native-operation [id intent]
  (record ops/pending_operation (operation-id id) (base-t 42) (state (ops/Queued)) (intent intent)))

(defn native-split [uuid before after new-uuid]
  (ops/Split_block (record ops/pending_split (uuid uuid) (expected-title (str before after))
                          (before before) (after after) (new-uuid new-uuid) (new-order "a1") (created-at 100))))

(defn title [db uuid]
  (match (ops/logseq-chat-pending-ops-raw-title db uuid)
    (Ok value) value (Error message) (throw (Failure message))))

(defn wire-values [input]
  (into [input]
        (match input
          (transit/Array values) (vec (mapcat wire-values values))
          (transit/List values) (vec (mapcat wire-values values))
          (transit/Set values) (vec (mapcat wire-values values))
          (transit/Map entries) (vec (mapcat (fn [[key value]] (concat (wire-values key) (wire-values value))) entries))
          (transit/Tagged _ value) (wire-values value)
          _ [])))

(deftest projected-readers-share-offline-edits-without-changing-authoritative-data
  (with-runtime
    (fn [path conn current]
      (is (ok? (runtime/stage current (save-title "title" "Old" "Pending"))))
      (is (= "Pending" (title (runtime/db current) "block")))
      (is (= "Old" (title (ds/conn-db conn) "block")))
      (is (= ["Pending"] (mapv :title (runtime/blocks-for-page current "page"))))
      (is (= ["Pending"] (mapv :title (runtime/blocks current))))
      (is (nil? (runtime/node-destination current "missing")))
      (is (empty? (runtime/objects-for-tag current "missing")))
      (is (empty? (runtime/tag-pages current)))
      (is (not (runtime/node-is-tag current "missing")))
      (is (empty? (runtime/references-for-node current "missing")))
      (is (= ["title"] (mapv :operation-id (ops/logseq-chat-pending-ops-list path)))))))

(deftest favorites-update-sidebar-and-encode-the-link-transaction
  (with-store
    (fn [path]
      (let [db (ds/db-with
                 (list (add 20 "block/uuid" (ds/Uuid "favorites-page"))
                       (add 20 "block/title" (ds/String "Favorites"))
                       (add 20 "block/name" (ds/String "$$$favorites"))) (base-db "Old"))
            current (runtime/create :path path :server_t 42 (ds/conn-from-db db))]
        (is (ok? (runtime/set-page-favorite current :page_uuid "page" :favorite true :operation_id "favorite" :now 100)))
        (is (= ["page"] (mapv :uuid (:favorites (runtime/sidebar-pages current)))))
        (let [operations (vec (runtime/pending-operations current))]
          (is (= 1 (count operations)))
          (let [op (nth operations 0)]
            (is (= "favorite" (:operation-id op)))
            (is (match (:intent op) (ops/Set_favorite value) (:favorite value) _ false))
            (is (match (runtime/prepare-sync current op)
                  (Ok ["insert-blocks" wire])
                  (some #(= (transit/Keyword "block/link") %) (wire-values (transit/of-string wire)))
                  _ false))))))))

(deftest page-deletion-is-optimistic-durable-and-rejects-built-ins
  (with-store
    (fn [path]
      (let [db (ds/db-with
                 (list (ds/Retract (ds/Entity_id 1) "block/journal-day" (Some (ds/Int 20260816)))
                       (add 20 "block/uuid" (ds/Uuid "recycle-page"))
                       (add 20 "block/title" (ds/String "Recycle")) (add 20 "block/name" (ds/String "recycle"))
                       (add 20 "logseq.property/built-in?" (ds/Bool true))
                       (add 20 "logseq.property/hide?" (ds/Bool true))) (base-db "Old"))
            current (runtime/create :path path :server_t 42 (ds/conn-from-db db))]
        (is (ok? (runtime/delete-page current :page_uuid "page" :operation_id "delete-page" :now 100)))
        (is (not (some #(= "page" (:uuid %)) (:recent-pages (runtime/sidebar-pages current)))))
        (let [operations (vec (runtime/pending-operations current))]
          (is (= 1 (count operations)))
          (let [op (nth operations 0)]
            (is (= "delete-page" (:operation-id op)))
            (is (match (:intent op) (ops/Delete_page value) (= "page" (:page-uuid value)) _ false))
            (is (match (runtime/prepare-sync current op) (Ok ["delete-page" _]) true _ false))))
        (is (not (ok? (runtime/delete-page current :page_uuid "recycle-page" :operation_id "built-in" :now 101))))))))

(deftest flashcard-review-is-one-atomic-millisecond-operation
  (with-store
    (fn [path]
      (let [now 1776000000000
            db (ds/db-with (list (add 20 "db/ident" (ds/Keyword "logseq.class/Card"))
                                 (add 10 "block/tags" (ds/Ref 20))) (base-db "Remember this"))
            current (runtime/create :path path :server_t 42 (ds/conn-from-db db))]
        (is (= ["block"] (mapv #(:uuid (:block %)) (runtime/due-flashcards current :now now))))
        (is (ok? (runtime/review-flashcard current :uuid "block" :rating (ops/Good) :now now :operation_id "review")))
        (is (empty? (runtime/due-flashcards current :now now)))
        (let [operations (ops/logseq-chat-pending-ops-list path)]
          (is (= 1 (count operations)))
          (is (match (:intent (nth operations 0))
                (ops/Set_properties value)
                (let [changes (:changes value)]
                  (and (= "block" (:uuid value)) (= 2 (count changes))
                       (= "logseq.property.fsrs/state" (:attr (nth changes 0)))
                       (= "logseq.property.fsrs/due" (:attr (nth changes 1)))
                       (match (:value (nth changes 1)) (Some (ops/Int_value _)) true _ false)
                       (match (:value (nth changes 0))
                         (Some (ops/Map_value entries))
                         (some (fn [[key value]] (and (= key "last-repeat") (match value (ops/Int_value _) true _ false))) entries)
                         _ false)))
                _ false)))))))

(deftest legacy-fsrs-instants-never-reach-the-wire-as-dates
  (with-runtime
    (fn [_ _ current]
      (let [op (native-operation "legacy-review"
                 (ops/Set_properties
                   (record ops/pending_properties (uuid "block")
                     (changes [(record ops/property_change (attr "logseq.property.fsrs/state") (expected nil)
                                 (value (Some (ops/Map_value [(tuple "last-repeat" (ops/Instant_value 1776000000000))
                                                            (tuple "state" (ops/Keyword_value "review"))]))))
                               (record ops/property_change (attr "logseq.property.fsrs/due") (expected nil)
                                 (value (Some (ops/Instant_value 1776086400000))))]))))]
        (is (ok? (runtime/stage current op)))
        (is (match (runtime/prepare-sync current op)
              (Ok ["save-block" wire])
              (not (some #(match % (transit/Date _) true _ false) (wire-values (transit/of-string wire))))
              _ false))))))

(deftest split-preparation-is-atomic-and-leaves-authoritative-data-unchanged
  (with-runtime
    (fn [_ conn current]
      (let [op (native-operation "split" (native-split "block" "O" "ld" "new-block"))]
        (is (match (runtime/prepare-sync current op)
              (Ok ["split-block" wire])
              (match (transit/of-string wire) (transit/Array values) (>= (count values) 2) _ false)
              _ false))
        (is (= "Old" (title (ds/conn-db conn) "block")))))))

(deftest consecutive-empty-splits-and-merges-use-the-latest-projection
  (with-runtime
    (fn [_ _ current]
      (let [operations
            [(native-operation "split-1" (native-split "block" "Old" "" "empty-1"))
             (native-operation "split-2" (native-split "empty-1" "" "" "empty-2"))
             (native-operation "merge-1" (ops/Merge_backward
                                          (record ops/pending_merge (uuid "empty-2") (expected-title "") (title "")
                                            (previous-uuid "empty-1") (expected-previous-title "") (merged-title nil))))
             (native-operation "merge-2" (ops/Merge_backward
                                          (record ops/pending_merge (uuid "empty-1") (expected-title "") (title "")
                                            (previous-uuid "block") (expected-previous-title "Old") (merged-title nil))))]]
        (run! #(is (ok? (runtime/stage current %))) operations)
        (is (= ["block"] (mapv :uuid (runtime/blocks-for-page current "page"))))))))

(deftest remote-title-conflicts-discard-stale-projections
  (with-runtime
    (fn [_ conn current]
      (is (ok? (runtime/stage current (save-title "title" "Old" "Pending"))))
      (ds/reset-conn conn (base-db "Remote"))
      (runtime/rebase current :server_t 43 :operation_ids (list))
      (is (= "Remote" (title (runtime/db current) "block")))
      (is (some (fn [[id state]] (and (= id "title") (match state (ops/Conflicted _) true _ false)))
                (runtime/operation-statuses current))))))

(deftest cursor-advance-rebases-offline-edits-and-their-structural-dependencies
  (with-runtime
    (fn [path conn current]
      (let [split (native-operation "split" (native-split "block" "O" "ld" "dependent-new"))
            edit (native-operation "edit" (ops/Save_title (record ops/pending_title
                                                           (uuid "dependent-new") (expected-title "ld") (title "Edited"))))]
        (is (ok? (runtime/stage current split)))
        (is (ok? (runtime/stage current edit)))
        (ds/reset-conn conn (base-db "Old"))
        (runtime/rebase current :server_t 43 :operation_ids (list))
        (is (= "Edited" (title (runtime/db current) "dependent-new")))
        (let [persisted (ops/logseq-chat-pending-ops-list path)]
          (is (= 2 (count persisted)))
          (is (every? #(and (= 43 (:base-t %)) (= (ops/Queued) (:state %))) persisted)))))))

(deftest stale-deletions-restore-authoritative-content-as-durable-conflicts
  (with-runtime
    (fn [path conn current]
      (let [op (native-operation "delete" (ops/Delete_blocks (record ops/pending_delete (uuids ["block"]))))]
        (is (ok? (runtime/stage current op)))
        (ds/reset-conn conn (base-db "Remote update"))
        (runtime/rebase current :server_t 43 :operation_ids (list))
        (let [persisted (ops/logseq-chat-pending-ops-list path)]
          (is (= 1 (count persisted)))
          (is (match (:state (nth persisted 0)) (ops/Conflicted _) true _ false)))
        (is (= "Remote update" (title (runtime/db current) "block")))))))

(deftest confirmation-requires-both-operation-id-and-authoritative-result
  (run! (fn [[remote confirmed]]
          (with-runtime
            (fn [path conn current]
              (is (ok? (runtime/stage current (save-title "title" "Old" "Pending"))))
              (ds/reset-conn conn (base-db remote))
              (runtime/rebase current :server_t 43 :operation_ids (list "title"))
              (is (= confirmed (empty? (ops/logseq-chat-pending-ops-list path))))
              (is (= "Pending" (title (runtime/db current) "block"))))))
        [(tuple "Pending" true) (tuple "Old" false)]))

(deftest rebase-replays-valid-applied-operations-and-persists-invalid-conflicts
  (with-runtime
    (fn [path conn current]
      (run! #(ops/logseq-chat-pending-ops-save path %)
            [(assoc (save-title "conflicted" "Old" "Ignored") :state (ops/Conflicted "known"))
             (assoc (save-title "applied" "Old" "Applied") :state (ops/Applied))
             (assoc (save-title "bad-applied" "Wrong" "Bad") :state (ops/Applied))])
      (ds/reset-conn conn (base-db "Old"))
      (runtime/rebase current :server_t 42 :operation_ids (list))
      (is (= "Applied" (title (runtime/db current) "block")))
      (is (some #(and (= "bad-applied" (:operation-id %)) (match (:state %) (ops/Conflicted _) true _ false))
                (ops/logseq-chat-pending-ops-list path))))))

(deftest retryable-and-submitted-edits-replay-in-order
  (with-runtime
    (fn [path conn current]
      (run! #(ops/logseq-chat-pending-ops-save path %)
            [(assoc (save-title "retryable" "Old" "Retry") :state (ops/Retryable))
             (assoc (save-title "submitted" "Retry" "Submit") :state (ops/Submitted))])
      (ds/reset-conn conn (base-db "Old"))
      (runtime/rebase current :server_t 42 :operation_ids (list))
      (is (= "Submit" (title (runtime/db current) "block"))))))

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

(defn with-search-runtime [db f]
  (with-store
    (fn [path]
      (let [search-path (filename/temp-file "logseq-chat-runtime-search" ".sqlite")
            conn (ds/conn-from-db db)]
        (try
          (let [current (runtime/create :path path :search_index_path search-path :server_t 42 conn)]
            (f search-path conn current))
          (finally
            (run! #(when (sys/file-exists %) (sys/remove %))
                  [search-path (str search-path "-shm") (str search-path "-wal")])))))))

(deftest search-index-incrementally-follows-edits-and-splits
  (with-search-runtime
    (base-db "Old")
    (fn [_ _ current]
      (runtime/search current "Old")
      (is (:search-index-is-fresh current))
      (is (ok? (runtime/stage current (save-title "search-title" "Old" "Pending"))))
      (is (:search-index-is-fresh current))
      (is (some #(= "block" (:uuid %)) (runtime/search current "Pending")))
      (let [split (native-operation "search-split"
                    (ops/Split_block (record ops/pending_split (uuid "block") (expected-title "Pending")
                                      (before "Head") (after "Tail") (new-uuid "search-new") (new-order "a1") (created-at 100))))]
        (is (ok? (runtime/stage current split)))
        (is (:search-index-is-fresh current))
        (is (some #(= "search-new" (:uuid %)) (runtime/search current "Tail")))))))

(deftest remote-search-refresh-preserves-unrelated-index-rows
  (with-search-runtime
    (base-db "Old")
    (fn [search-path conn current]
      (runtime/search current "Old")
      (ops/logseq-chat-search-index-search-upsert search-path
        (list (tuple "search-sentinel" "incremental sentinel" "search-sentinel")))
      (ds/transact-conn conn (list (add 10 "block/title" (ds/String "Remote"))))
      (runtime/rebase current :server_t 43 :operation_ids (list) :changed_uuids (list "block"))
      (is (some #(= "block" (:uuid %)) (runtime/search current "Remote")))
      (is (if-some [index (:search-index current)]
            (some #(= "search-sentinel" (:uuid %))
                  (ops/logseq-chat-search-index-search (fn [_] false) 100 index "incremental sentinel"))
            false)))))

(deftest referenced-page-renames-reindex-the-page-and-its-referrers
  (let [db (ds/db-with
             (list (add 2 "block/uuid" (ds/Uuid "target"))
                   (add 2 "block/title" (ds/String "Target")) (add 2 "block/name" (ds/String "target"))
                   (add 10 "block/refs" (ds/Ref 2))) (base-db "[[target]]"))]
    (with-search-runtime
      db
      (fn [_ _ current]
        (runtime/search current "Target")
        (let [rename (native-operation "rename"
                       (ops/Save_title (record ops/pending_title (uuid "target") (expected-title "Target") (title "Renamed"))))]
          (is (ok? (runtime/stage current rename)))
          (is (:search-index-is-fresh current))
          (let [hits (runtime/search current "Renamed")]
            (run! (fn [uuid] (is (some #(= uuid (:uuid %)) hits))) ["target" "block"])))))))

(defn encrypted-runtime [path conn]
  (runtime/create :encrypt_title (fn [value] (Ok (str "enc:" value))) :path path :server_t 42 conn))

(deftest encrypted-sync-keeps-projection-and-pending-storage-plaintext
  (with-store
    (fn [path]
      (let [conn (ds/conn-from-db (base-db "Old"))
            current (encrypted-runtime path conn)
            op (save-title "encrypted-title" "Old" "Pending")]
        (is (match (runtime/prepare-sync current op)
              (Ok ["save-block" wire])
              (let [values (wire-values (transit/of-string wire))]
                (and (some #(= (transit/String "enc:Pending") %) values)
                     (not (some #(or (= (transit/String "Old") %) (= (transit/String "Pending") %)) values))))
              _ false))
        (is (ok? (runtime/stage current op)))
        (is (= "Pending" (title (runtime/db current) "block")))
        (is (= ["Pending"] (mapv :title (runtime/blocks current))))
        (let [stored (ops/logseq-chat-pending-ops-list path)]
          (is (= 1 (count stored)))
          (is (match (:intent (nth stored 0))
                (ops/Save_title value) (and (= "Old" (:expected-title value)) (= "Pending" (:title value)))
                _ false)))))))

(deftest encrypted-merge-encrypts-the-completed-title-once
  (with-store
    (fn [path]
      (let [db (ds/db-with
                 (list (add 11 "block/uuid" (ds/Uuid "previous")) (add 11 "block/title" (ds/String "Hello"))
                       (add 11 "block/page" (ds/Ref 1)) (add 11 "block/parent" (ds/Ref 1))
                       (add 11 "block/order" (ds/String "Zz")) (add 11 "block/created-at" (ds/Int 0))
                       (add 11 "block/updated-at" (ds/Int 0))) (base-db "Old"))
            current (encrypted-runtime path (ds/conn-from-db db))
            op (native-operation "encrypted-merge"
                 (ops/Merge_backward (record ops/pending_merge (uuid "block") (expected-title "Old") (title " World")
                                       (previous-uuid "previous") (expected-previous-title "Hello") (merged-title nil))))]
        (is (match (runtime/prepare-sync current op)
              (Ok ["merge-blocks" wire])
              (some #(= (transit/String "enc:Hello World") %) (wire-values (transit/of-string wire)))
              _ false))
        (is (ok? (runtime/stage current op)))
        (is (= "Hello World" (title (runtime/db current) "previous")))
        (is (nil? (ds/entid (runtime/db current) "block/uuid" (ds/Uuid "block"))))))))

(deftest journal-window-grows-by-two-pages-per-request
  (with-store
    (fn [path]
      (let [tx (mapcat
                 (fn [index]
                   (let [page (inc index) block (+ index 101)]
                     [(add page "block/uuid" (ds/Uuid (str "page-" index)))
                      (add page "block/title" (ds/String (str "Page " index)))
                      (add page "block/name" (ds/String (str "page-" index)))
                      (add page "block/journal-day" (ds/Int (+ 20260801 index)))
                      (add block "block/uuid" (ds/Uuid (str "block-" index)))
                      (add block "block/title" (ds/String (str "Block " index)))
                      (add block "block/page" (ds/Ref page)) (add block "block/parent" (ds/Ref page))
                      (add block "block/created-at" (ds/Int index))])) (range 8))
            db (ds/db-with (apply list tx) (ds/empty-db :schema (apply list (seq schema))))
            current (runtime/create :path path :server_t 42 (ds/conn-from-db db))]
        (is (= 1 (count (runtime/blocks current))))
        (is (runtime/has-older-journals current))
        (run! (fn [expected]
                (runtime/load-older-journals current)
                (is (= expected (count (runtime/blocks current))))
                (is (runtime/has-older-journals current))) [3 5])))))
