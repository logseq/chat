(ns logseq-chat.graph-runtime-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.pending-ops :as pending]
            [logseq-chat.pending-projection :as projection]
            [logseq-chat.search-index :as search]
            [logseq-chat.cache-model :as model]
            [logseq-chat.flashcards :as cards]
            [logseq-chat.storage-codec :as storage]
            [logseq-chat.graph-store :as store]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]
            [ocaml.Gc :as gc]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Datascript :as ds]
            [ocaml.Transit_native.Transit.Json :as transit]
            [logseq-chat.graph-runtime :as runtime]))

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
  (record pending/pending-operation (operation-id id) (base-t 42) (state pending/Queued)
          (intent (pending/Save-title (record pending/pending-title (uuid "block") (expected-title before) (title after))))))

(defn ok? [result] (match result (Ok _) true (Error _) false))

(defn prepares-save? [current op]
  (match (runtime/prepare-sync current op) (Ok ["save-block" _]) true _ false))

(defn with-runtime [f]
  (with-store (fn [path]
                (let [conn (ds/conn-from-db (base-db "Old"))
                      current (runtime/create path 42 conn runtime/default-options)]
                  (f path conn current)))))

(defn operation [id intent]
  (record pending/pending-operation (operation-id id) (base-t 42) (state pending/Queued) (intent intent)))

(defn split-operation [uuid before after new-uuid]
  (pending/Split-block (record pending/pending-split (uuid uuid) (expected-title (str before after))
                               (before before) (after after) (new-uuid new-uuid) (new-order "a1") (created-at 100))))

(defn title [db uuid]
  (match (pending/raw-title db uuid)
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
      (is (= ["title"] (mapv :operation-id (pending/list path)))))))

(deftest favorites-update-sidebar-and-encode-the-link-transaction
  (with-store
    (fn [path]
      (let [db (ds/db-with
                (list (add 20 "block/uuid" (ds/Uuid "favorites-page"))
                      (add 20 "block/title" (ds/String "Favorites"))
                      (add 20 "block/name" (ds/String "$$$favorites"))) (base-db "Old"))
            current (runtime/create path 42 (ds/conn-from-db db) runtime/default-options)]
        (is (ok? (runtime/set-page-favorite current "page" true "favorite" 100)))
        (is (= ["page"] (mapv :uuid (:favorites (runtime/sidebar-pages current)))))
        (let [operations (vec (runtime/pending-operations current))]
          (is (= 1 (count operations)))
          (let [op (nth operations 0)]
            (is (= "favorite" (:operation-id op)))
            (is (match (:intent op) (pending/Set-favorite value) (:favorite value) _ false))
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
            current (runtime/create path 42 (ds/conn-from-db db) runtime/default-options)]
        (is (ok? (runtime/delete-page current "page" "delete-page" 100)))
        (is (not (some #(= "page" (:uuid %)) (:recent-pages (runtime/sidebar-pages current)))))
        (let [operations (vec (runtime/pending-operations current))]
          (is (= 1 (count operations)))
          (let [op (nth operations 0)]
            (is (= "delete-page" (:operation-id op)))
            (is (match (:intent op) (pending/Delete-page value) (= "page" (:page-uuid value)) _ false))
            (is (match (runtime/prepare-sync current op) (Ok ["delete-page" _]) true _ false))))
        (is (not (ok? (runtime/delete-page current "recycle-page" "built-in" 101))))))))

(deftest flashcard-review-is-one-atomic-millisecond-operation
  (with-store
    (fn [path]
      (let [now 1776000000000
            db (ds/db-with (list (add 20 "db/ident" (ds/Keyword "logseq.class/Card"))
                                 (add 10 "block/tags" (ds/Ref 20))) (base-db "Remember this"))
            current (runtime/create path 42 (ds/conn-from-db db) runtime/default-options)]
        (is (= ["block"] (mapv #(:uuid (:block %)) (runtime/due-flashcards current now))))
        (is (ok? (runtime/review-flashcard current "block" cards/Good now "review")))
        (is (empty? (runtime/due-flashcards current now)))
        (let [operations (pending/list path)]
          (is (= 1 (count operations)))
          (is (match (:intent (nth operations 0))
                (pending/Set-properties value)
                (let [changes (:changes value)]
                  (and (= "block" (:uuid value)) (= 2 (count changes))
                       (= "logseq.property.fsrs/state" (:attr (nth changes 0)))
                       (= "logseq.property.fsrs/due" (:attr (nth changes 1)))
                       (match (:value (nth changes 1)) (Some (pending/Int-value _)) true _ false)
                       (match (:value (nth changes 0))
                         (Some (pending/Map-value entries))
                         (some (fn [[key value]] (and (= key "last-repeat") (match value (pending/Int-value _) true _ false))) entries)
                         _ false)))
                _ false)))))))

(deftest legacy-fsrs-instants-never-reach-the-wire-as-dates
  (with-runtime
    (fn [_ _ current]
      (let [op (operation "legacy-review"
                          (pending/Set-properties
                           (record pending/pending-properties (uuid "block")
                                   (changes [(record pending/property-change (attr "logseq.property.fsrs/state") (expected nil)
                                                     (value (Some (pending/Map-value [(tuple "last-repeat" (pending/Instant-value 1776000000000))
                                                                                      (tuple "state" (pending/Keyword-value "review"))]))))
                                             (record pending/property-change (attr "logseq.property.fsrs/due") (expected nil)
                                                     (value (Some (pending/Instant-value 1776086400000))))]))))]
        (is (ok? (runtime/stage current op)))
        (is (match (runtime/prepare-sync current op)
              (Ok ["save-block" wire])
              (not (some #(match % (transit/Date _) true _ false) (wire-values (transit/of-string wire))))
              _ false))))))

(deftest split-preparation-is-atomic-and-leaves-authoritative-data-unchanged
  (with-runtime
    (fn [_ conn current]
      (let [op (operation "split" (split-operation "block" "O" "ld" "new-block"))]
        (is (match (runtime/prepare-sync current op)
              (Ok ["split-block" wire])
              (match (transit/of-string wire) (transit/Array values) (>= (count values) 2) _ false)
              _ false))
        (is (= "Old" (title (ds/conn-db conn) "block")))))))

(deftest consecutive-empty-splits-and-merges-use-the-latest-projection
  (with-runtime
    (fn [_ _ current]
      (let [operations
            [(operation "split-1" (split-operation "block" "Old" "" "empty-1"))
             (operation "split-2"
                        (pending/Split-block (record pending/pending-split (uuid "empty-1") (expected-title "")
                                                     (before "") (after "") (new-uuid "empty-2")
                                                     (new-order "a2") (created-at 101))))
             (operation "merge-1" (pending/Merge-backward
                                   (record pending/pending-merge (uuid "empty-2") (expected-title "") (title "")
                                           (previous-uuid "empty-1") (expected-previous-title "") (merged-title nil))))
             (operation "merge-2" (pending/Merge-backward
                                   (record pending/pending-merge (uuid "empty-1") (expected-title "") (title "")
                                           (previous-uuid "block") (expected-previous-title "Old") (merged-title nil))))]]
        (run! #(is (ok? (runtime/stage current %))) operations)
        (is (= ["block"] (mapv :uuid (runtime/blocks-for-page current "page"))))))))

(deftest remote-title-conflicts-discard-stale-projections
  (with-runtime
    (fn [_ conn current]
      (is (ok? (runtime/stage current (save-title "title" "Old" "Pending"))))
      (ds/reset-conn conn (base-db "Remote"))
      (runtime/rebase current 43 (list) [])
      (is (= "Remote" (title (runtime/db current) "block")))
      (is (some (fn [[id state]] (and (= id "title") (match state (pending/Conflicted _) true _ false)))
                (runtime/operation-statuses current))))))

(deftest cursor-advance-rebases-offline-edits-and-their-structural-dependencies
  (with-runtime
    (fn [path conn current]
      (let [split (operation "split" (split-operation "block" "O" "ld" "dependent-new"))
            edit (operation "edit" (pending/Save-title (record pending/pending-title
                                                               (uuid "dependent-new") (expected-title "ld") (title "Edited"))))]
        (is (ok? (runtime/stage current split)))
        (is (ok? (runtime/stage current edit)))
        (ds/reset-conn conn (base-db "Old"))
        (runtime/rebase current 43 (list) [])
        (is (= "Edited" (title (runtime/db current) "dependent-new")))
        (let [persisted (pending/list path)]
          (is (= 2 (count persisted)))
          (is (every? #(and (= 43 (:base-t %)) (= pending/Queued (:state %))) persisted)))))))

(deftest stale-deletions-restore-authoritative-content-as-durable-conflicts
  (with-runtime
    (fn [path conn current]
      (let [op (operation "delete" (pending/Delete-blocks (record pending/pending-delete (uuids ["block"]))))]
        (is (ok? (runtime/stage current op)))
        (ds/reset-conn conn (base-db "Remote update"))
        (runtime/rebase current 43 (list) [])
        (let [persisted (pending/list path)]
          (is (= 1 (count persisted)))
          (is (match (:state (nth persisted 0)) (pending/Conflicted _) true _ false)))
        (is (= "Remote update" (title (runtime/db current) "block")))))))

(deftest confirmation-requires-both-operation-id-and-authoritative-result
  (run! (fn [[remote confirmed]]
          (with-runtime
            (fn [path conn current]
              (is (ok? (runtime/stage current (save-title "title" "Old" "Pending"))))
              (ds/reset-conn conn (base-db remote))
              (runtime/rebase current 43 (list "title") [])
              (is (= confirmed (empty? (pending/list path))))
              (is (= "Pending" (title (runtime/db current) "block"))))))
        [(tuple "Pending" true) (tuple "Old" false)]))

(deftest rebase-replays-valid-applied-operations-and-persists-invalid-conflicts
  (with-runtime
    (fn [path conn current]
      (run! #(pending/save path %)
            [(assoc (save-title "conflicted" "Old" "Ignored") :state (pending/Conflicted "known"))
             (assoc (save-title "applied" "Old" "Applied") :state pending/Applied)
             (assoc (save-title "bad-applied" "Wrong" "Bad") :state pending/Applied)])
      (ds/reset-conn conn (base-db "Old"))
      (runtime/rebase current 42 (list) [])
      (is (= "Applied" (title (runtime/db current) "block")))
      (is (some #(and (= "bad-applied" (:operation-id %)) (match (:state %) (pending/Conflicted _) true _ false))
                (pending/list path))))))

(deftest retryable-and-submitted-edits-replay-in-order
  (with-runtime
    (fn [path conn current]
      (run! #(pending/save path %)
            [(assoc (save-title "retryable" "Old" "Retry") :state pending/Retryable)
             (assoc (save-title "submitted" "Retry" "Submit") :state pending/Submitted)])
      (ds/reset-conn conn (base-db "Old"))
      (runtime/rebase current 42 (list) [])
      (is (= "Submit" (title (runtime/db current) "block"))))))

(deftest dependent-edits-can-sync-on-an-accepted-projection
  (with-store
    (fn [path]
      (let [current (runtime/create path 42 (ds/conn-from-db (base-db "Old")) runtime/default-options)
            first-op (save-title "accepted-title" "Old" "First")
            second-op (save-title "next-title" "First" "Second")]
        (is (ok? (runtime/stage current first-op)))
        (is (ok? (runtime/stage current (assoc first-op :state (pending/Accepted 43)))))
        (is (ok? (runtime/stage current second-op)))
        (is (prepares-save? current second-op))))))

(deftest stale-completions-cannot-roll-back-persisted-cursors
  (with-store
    (fn [path]
      (let [current (runtime/create path 42 (ds/conn-from-db (base-db "Old")) runtime/default-options)
            first-op (save-title "in-flight-title" "Old" "First")
            second-op (save-title "queued-during-flight" "First" "Second")]
        (is (ok? (runtime/stage current first-op)))
        (is (ok? (runtime/stage current second-op)))
        (is (ok? (runtime/stage current (assoc first-op :state (pending/Accepted 43)))))
        (runtime/rebase current 43 (list) [])
        (is (prepares-save? current second-op))
        (is (ok? (runtime/stage current (assoc second-op :state pending/Retryable))))
        (is (some (fn [op]
                    (and (= "queued-during-flight" (:operation-id op))
                         (= 43 (:base-t op)) (= pending/Retryable (:state op))))
                  (pending/list path)))))))

(deftest reopen-rebases-safe-retries-and-conflicts-stale-deletions
  (with-store
    (fn [path]
      (pending/save path (assoc (save-title "retry-after-reopen" "Old" "New") :state pending/Retryable))
      (let [current (runtime/create-base path 43 (ds/conn-from-db (base-db "Old")) runtime/default-options)
            persisted (pending/list path)]
        (is (= 1 (count persisted)))
        (let [op (nth persisted 0)]
          (is (= 43 (:base-t op)))
          (is (= pending/Queued (:state op)))
          (is (prepares-save? current op))))))
  (with-store
    (fn [path]
      (pending/save path
                    (record pending/pending-operation (operation-id "unsafe-delete-after-reopen") (base-t 42) (state pending/Retryable)
                            (intent (pending/Delete-blocks (record pending/pending-delete (uuids ["block"]))))))
      (runtime/create-base path 43 (ds/conn-from-db (base-db "Old")) runtime/default-options)
      (let [persisted (pending/list path)]
        (is (= 1 (count persisted)))
        (let [op (nth persisted 0)]
          (is (= 43 (:base-t op)))
          (is (match (:state op) (pending/Conflicted _) true _ false)))))))

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
          (let [current (runtime/create path 42 conn (assoc runtime/default-options :search-index-path (Some search-path)))]
            (f search-path conn current))
          (finally
            (run! #(when (sys/file-exists %) (sys/remove %))
                  [search-path (str search-path "-shm") (str search-path "-wal")])))))))

(deftest search-index-incrementally-follows-edits-and-splits
  (with-search-runtime
    (base-db "Old")
    (fn [_ _ current]
      (runtime/search current "Old")
      (is (:search-index-is-fresh (runtime/state current)))
      (is (ok? (runtime/stage current (save-title "search-title" "Old" "Pending"))))
      (is (:search-index-is-fresh (runtime/state current)))
      (is (some #(= "block" (:uuid %)) (runtime/search current "Pending")))
      (let [split (operation "search-split"
                             (pending/Split-block (record pending/pending-split (uuid "block") (expected-title "Pending")
                                                          (before "Head") (after "Tail") (new-uuid "search-new") (new-order "a1") (created-at 100))))]
        (is (ok? (runtime/stage current split)))
        (is (:search-index-is-fresh (runtime/state current)))
        (is (some #(= "search-new" (:uuid %)) (runtime/search current "Tail")))))))

(deftest unavailable-search-index-preserves-projection-and-recovers
  (run!
   (fn [action]
     (with-search-runtime
       (base-db "Old")
       (fn [search-path conn current]
         (runtime/search current "Old")
         (is (:search-index-is-fresh (runtime/state current)))
         (let [backup (str search-path ".backup")]
           (sys/rename search-path backup)
           (try
             (unix/mkdir search-path 448)
             (try
               (case action
                 :stage (is (ok? (runtime/stage current (save-title "search-outage" "Old" "Changed"))))
                 :rebase (do (ds/transact-conn conn (list (add 10 "block/title" (ds/String "Changed"))))
                             (runtime/rebase current 43 [] ["block"])))
               (is (= "Changed" (title (runtime/db current) "block")))
               (is (not (:search-index-is-fresh (runtime/state current))))
               (is (empty? (runtime/search current "Changed")))
               (finally (unix/rmdir search-path)))
             (finally (sys/rename backup search-path))))
         (is (some #(= "block" (:uuid %)) (runtime/search current "Changed")))
         (is (:search-index-is-fresh (runtime/state current))))))
   [:stage :rebase]))

(deftest remote-search-refresh-preserves-unrelated-index-rows
  (with-search-runtime
    (base-db "Old")
    (fn [search-path conn current]
      (runtime/search current "Old")
      (search/search-upsert search-path
                            (list (tuple "search-sentinel" "incremental sentinel" "search-sentinel")))
      (ds/transact-conn conn (list (add 10 "block/title" (ds/String "Remote"))))
      (runtime/rebase current 43 (list) (list "block"))
      (is (some #(= "block" (:uuid %)) (runtime/search current "Remote")))
      (is (if-some [index (:search-index current)]
            (some #(= "search-sentinel" (:uuid %))
                  (search/search (fn [_] false) 100 index "incremental sentinel"))
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
        (let [rename (operation "rename"
                                (pending/Save-title (record pending/pending-title (uuid "target") (expected-title "Target") (title "Renamed"))))]
          (is (ok? (runtime/stage current rename)))
          (is (:search-index-is-fresh (runtime/state current)))
          (let [hits (runtime/search current "Renamed")]
            (run! (fn [uuid] (is (some #(= uuid (:uuid %)) hits))) ["target" "block"])))))))

(defn encrypted-runtime [path conn]
  (runtime/create path 42 conn (assoc runtime/default-options :encrypt-title (fn [value] (Ok (str "enc:" value))))))

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
        (let [stored (pending/list path)]
          (is (= 1 (count stored)))
          (is (match (:intent (nth stored 0))
                (pending/Save-title value) (and (= "Old" (:expected-title value)) (= "Pending" (:title value)))
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
            op (operation "encrypted-merge"
                          (pending/Merge-backward (record pending/pending-merge (uuid "block") (expected-title "Old") (title " World")
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
            current (runtime/create path 42 (ds/conn-from-db db) runtime/default-options)]
        (is (= 1 (count (runtime/blocks current))))
        (is (runtime/has-older-journals current))
        (run! (fn [expected]
                (runtime/load-older-journals current)
                (is (= expected (count (runtime/blocks current))))
                (is (runtime/has-older-journals current))) [3 5])))))

(deftest submitted-echoes-and-accepted-cursors-confirm-only-visible-results
  (with-runtime
    (fn [path conn current]
      (is (ok? (runtime/stage current (assoc (save-title "echo" "Old" "Pending") :state pending/Submitted))))
      (ds/reset-conn conn (base-db "Pending"))
      (runtime/rebase current 43 (list) [])
      (is (empty? (pending/list path)))
      (is (= "Pending" (title (runtime/db current) "block")))))
  (with-runtime
    (fn [path conn current]
      (is (ok? (runtime/stage current (assoc (save-title "accepted" "Old" "Pending") :state (pending/Accepted 44)))))
      (ds/reset-conn conn (base-db "Old"))
      (runtime/rebase current 43 (list) [])
      (is (= "Pending" (title (runtime/db current) "block")))
      (is (= ["accepted"] (mapv :operation-id (pending/list path))))
      (ds/reset-conn conn (base-db "Pending"))
      (runtime/rebase current 44 (list) [])
      (is (empty? (pending/list path)))
      (is (= "Pending" (title (runtime/db current) "block"))))))

(deftest transport-state-updates-do-not-replay-unrelated-late-rows
  (with-runtime
    (fn [path _ current]
      (let [op (save-title "state-only" "Old" "Pending")]
        (is (ok? (runtime/stage current op)))
        (pending/save path (save-title "unrelated" "Old" "Other"))
        (is (ok? (runtime/stage current (assoc op :state (pending/Accepted 44)))))
        (is (some #(and (= "state-only" (:operation-id %)) (= (pending/Accepted 44) (:state %)))
                  (pending/list path)))))))

(deftest invalid-operations-never-reach-persistence-or-projection
  (with-runtime
    (fn [path _ current]
      (let [op (operation "invalid"
                          (pending/Move-block (record pending/pending-move (uuid "block") (page-uuid "page") (parent-uuid "block") (order "a0"))))]
        (is (not (ok? (runtime/stage current op))))
        (is (empty? (pending/list path)))
        (is (= "Old" (title (runtime/db current) "block")))))))

(deftest only-transport-recoverable-states-enter-the-send-queue
  (with-runtime
    (fn [path _ current]
      (run! (fn [[id state]] (pending/save path (assoc (save-title id "Old" id) :state state)))
            [(tuple "queued" pending/Queued) (tuple "retryable" pending/Retryable)
             (tuple "submitted" pending/Submitted) (tuple "accepted" (pending/Accepted 44))
             (tuple "applied" pending/Applied) (tuple "conflicted" (pending/Conflicted "server changed"))])
      (is (= ["queued" "retryable" "submitted"] (mapv :operation-id (runtime/pending-operations current)))))))

(deftest staging-five-hundred-offline-edits-stays-bounded
  (with-runtime
    (fn [_ _ current]
      (let [started (unix/gettimeofday)]
        (loop [index 1 previous "Old"]
          (when (<= index 500)
            (let [next-title (str "Offline " index)]
              (is (ok? (runtime/stage current (save-title (str "incremental-" index) previous next-title))))
              (recur (inc index) next-title))))
        (let [elapsed (- (unix/gettimeofday) started)]
          (is (< elapsed 0.5))
          (is (= "Offline 500" (title (runtime/db current) "block"))))))))

(defn today []
  (model/journal-day-for-ms (stdlib/int-of-float (* (unix/gettimeofday) 1000.0))))

(deftest today-journal-is-canonical-atomic-and-not-duplicated-on-reopen
  (with-store
    (fn [path]
      (let [conn (ds/conn-from-db (ds/empty-db :schema (apply list (seq schema))))
            day (today)
            current (runtime/create path 42 conn (assoc runtime/default-options :auto-create-today true))
            expected (format "00000001-%04d-%04d-0000-000000000000" (quot day 10000) (mod day 10000))]
        (is (= (Some expected) (runtime/journal-page-uuid current day)))
        (is (= [""] (mapv :title (runtime/blocks-for-page current expected))))
        (is (= 1 (count (runtime/pending-operations current))))
        (let [reopened (runtime/create path 42 conn (assoc runtime/default-options :auto-create-today true))]
          (is (= 1 (count (runtime/pending-operations reopened))))
          (is (= 1 (count (runtime/blocks-for-page reopened expected)))))))))

(deftest authoritative-today-journal-is-not-recreated
  (with-store
    (fn [path]
      (let [day (today)
            db (ds/db-with (list (add 1 "block/uuid" (ds/Uuid "existing-today"))
                                 (add 1 "block/title" (ds/String "Today")) (add 1 "block/name" (ds/String "today"))
                                 (add 1 "block/journal-day" (ds/Int day)))
                           (ds/empty-db :schema (apply list (seq schema))))
            current (runtime/create path 42 (ds/conn-from-db db) (assoc runtime/default-options :auto-create-today true))]
        (is (= (Some "existing-today") (runtime/journal-page-uuid current day)))
        (is (empty? (runtime/pending-operations current)))))))

(deftest accepted-partial-journal-keeps-its-pending-first-block
  (with-store
    (fn [path]
      (let [conn (ds/conn-from-db (ds/empty-db :schema (apply list (seq schema))))
            current (runtime/create path 42 conn (assoc runtime/default-options :auto-create-today true))
            operations (pending/list path)]
        (is (= 1 (count operations)))
        (let [op (nth operations 0)]
          (is (ok? (runtime/stage current (assoc op :state (pending/Accepted 43)))))
          (is (match (:intent op)
                (pending/Create-journal value)
                (let [db (ds/db-with
                          (list (add 1 "block/uuid" (ds/Uuid (:page-uuid value)))
                                (add 1 "block/title" (ds/String (:title value)))
                                (add 1 "block/name" (ds/String (:title value)))
                                (add 1 "block/journal-day" (ds/Int (:journal-day value))))
                          (ds/empty-db :schema (apply list (seq schema))))]
                  (ds/reset-conn conn db)
                  (runtime/rebase current 43 (list) [])
                  (and (= 1 (count (pending/list path)))
                       (= [(:block-uuid value)] (mapv :uuid (runtime/blocks-for-page current (:page-uuid value))))))
                _ false)))))))

(deftest persisted-offline-pages-reopen-for-every-transport-state
  (run! (fn [state]
          (with-runtime
            (fn [path conn _]
              (let [payload "{\"type\":\"create-page\",\"uuid\":\"offline-page\",\"title\":\"Offline Page\",\"createdAt\":7}"]
                (pending/store-raw path "offline-page" 42 state payload)
                (let [current (runtime/create path 43 conn runtime/default-options)
                      stored (pending/list path)]
                  (is (not (empty? (runtime/blocks current))))
                  (is (= "Offline Page" (title (runtime/db current) "offline-page")))
                  (is (= 1 (count stored)))
                  (let [op (nth stored 0)]
                    (is (= (json/from-string payload) (pending/intent-json (:intent op))))
                    (if (= state "accepted:43")
                      (is (empty? (runtime/pending-operations current)))
                      (is (prepares-save? current op)))
                    (ds/transact-conn conn
                                      (list (add 20 "block/uuid" (ds/Uuid "offline-page"))
                                            (add 20 "block/title" (ds/String "Server Page")) (add 20 "block/name" (ds/String "server page"))))
                    (pending/save path (assoc op :state (pending/Accepted 44)))
                    (let [reopened (runtime/create path 44 conn runtime/default-options)]
                      (is (empty? (pending/list path)))
                      (is (= "Server Page" (title (runtime/db reopened) "offline-page"))))))))))
        ["queued" "retryable" "submitted" "accepted:43"]))

(deftest sidebar-cache-reuses-unchanged-reads-and-invalidates-on-rebase
  (with-runtime
    (fn [path conn current]
      (let [initial (runtime/sidebar-pages current)]
        (gc/full-major)
        (let [before (gc/allocated-bytes)]
          (dotimes [_ 100] (runtime/sidebar-pages current))
          (is (< (- (gc/allocated-bytes) before) 50000.0)))
        (ds/transact-conn conn (list (add 1 "block/title" (ds/String "Remote title"))))
        (runtime/rebase current 43 (list) [])
        (let [remote (runtime/sidebar-pages current)]
          (is (not= initial remote))
          (is (some #(= "Remote title" (:title %)) (:recent-pages remote)))
          (pending/save path
                        (assoc (operation "page-title"
                                          (pending/Save-title (record pending/pending-title (uuid "page") (expected-title "Remote title") (title "Local title"))))
                               :base-t 43))
          (runtime/rebase current 43 (list) [])
          (is (some #(= "Local title" (:title %)) (:recent-pages (runtime/sidebar-pages current))))
          (pending/remove path "page-title")
          (runtime/rebase current 43 (list) [])
          (is (= remote (runtime/sidebar-pages current))))))))

(deftest startup-persists-stale-conflicts-and-restores-valid-edits
  (with-store
    (fn [path]
      (run! #(pending/save path %)
            [(save-title "stale" "Remote title" "Stale local edit")
             (save-title "valid" "Old" "Valid local edit")])
      (let [current (runtime/create path 42 (ds/conn-from-db (base-db "Old")) runtime/default-options)]
        (is (= ["valid"] (mapv :operation-id (runtime/pending-operations current))))
        (is (= "Valid local edit" (title (runtime/db current) "block")))
        (is (some #(and (= "stale" (:operation-id %))
                        (match (:state %) (pending/Conflicted _) true _ false))
                  (pending/list path)))))))

(deftest startup-split-confirmation-distinguishes-submission-from-collision
  (run!
   (fn [[state cursor confirmed?]]
     (with-store
       (fn [path]
         (let [db (ds/db-with
                   (list (add 11 "block/uuid" (ds/Uuid "already-created"))
                         (add 11 "block/title" (ds/String "Edited later"))
                         (add 11 "block/page" (ds/Ref 1)) (add 11 "block/parent" (ds/Ref 1))
                         (add 11 "block/order" (ds/String "a2"))
                         (add 11 "block/created-at" (ds/Int 2)) (add 11 "block/updated-at" (ds/Int 3)))
                   (base-db "Old"))
               op (assoc (operation "committed-split"
                                    (split-operation "block" "Old" "" "already-created")) :state state)]
           (pending/save path op)
           (runtime/create path cursor (ds/conn-from-db db) runtime/default-options)
           (let [stored (pending/list path)]
             (is (= confirmed? (empty? stored)))
             (when (or (= state pending/Queued) (= state pending/Retryable))
               (is (match (:state (nth stored 0)) (pending/Conflicted _) true _ false)))
             (when (= state (pending/Conflicted "source block changed"))
               (is (= state (:state (nth stored 0))))))))))
   [(tuple (pending/Conflicted "split block UUID already exists") 43 true)
    (tuple pending/Submitted 43 true)
    (tuple (pending/Accepted 44) 43 false)
    (tuple (pending/Accepted 44) 44 true)
    (tuple pending/Queued 43 false)
    (tuple pending/Retryable 43 false)
    (tuple (pending/Conflicted "source block changed") 43 false)]))

(defn measure-allocation [f]
  (gc/full-major)
  (let [before (gc/allocated-bytes)
        result (f)]
    (tuple result (- (gc/allocated-bytes) before))))

(deftest startup-constructs-the-pending-projection-only-once
  (with-runtime
    (fn [path conn _]
      (let [operations (mapv (fn [index]
                               (save-title (str "restore-" index)
                                           (if (= index 0) "Old" (str (dec index)))
                                           (str index))) (range 30))]
        (run! #(pending/save path %) operations)
        (let [[expected projection-bytes]
              (measure-allocation #(projection/build
                                    42 (ds/conn-db conn) operations))
              [current restore-bytes]
              (measure-allocation (fn [] (runtime/create path 42 conn runtime/default-options)))]
          (is (= (title (:db expected) "block") (title (runtime/db current) "block")))
          (is (= (vec (runtime/operation-statuses current)) (:statuses expected)))
          (is (= "Old" (title (ds/conn-db conn) "block")))
          (is (= operations (pending/list path)))
          (is (< restore-bytes (* projection-bytes 1.6))))))))

(defn insert-operation [id]
  (operation id
             (pending/Insert-block (record pending/pending-insert
                                           (uuid "new") (title "Local title") (page-uuid "page")
                                           (parent-uuid "page") (order "a1") (created-at 100)))))

(deftest authoritative-insert-echo-accepts-server-normalized-fields
  (with-runtime
    (fn [path conn current]
      (is (ok? (runtime/stage current (insert-operation "insert-echo"))))
      (ds/reset-conn conn
                     (ds/db-with (list (add 20 "block/uuid" (ds/Uuid "new"))
                                       (add 20 "block/title" (ds/String "Server-normalized title"))
                                       (add 20 "block/page" (ds/Ref 1)) (add 20 "block/parent" (ds/Ref 1))
                                       (add 20 "block/order" (ds/String "a2"))) (base-db "Old")))
      (runtime/rebase current 43 (list) [])
      (is (empty? (pending/list path)))
      (is (= "Server-normalized title" (title (runtime/db current) "new"))))))

(deftest unrelated-server-progress-preserves-and-rebases-offline-inserts
  (with-runtime
    (fn [path conn current]
      (let [op (insert-operation "offline-insert")]
        (is (match (runtime/prepare-sync current op) (Ok ["insert-blocks" _]) true _ false))
        (is (ok? (runtime/stage current op)))
        (ds/reset-conn conn (base-db "Old"))
        (runtime/rebase current 43 (list) [])
        (let [stored (pending/list path)]
          (is (= ["offline-insert"] (mapv :operation-id stored)))
          (is (= [43] (mapv :base-t stored)))
          (is (= [pending/Queued] (mapv :state stored)))
          (is (ok? (runtime/prepare-sync current (nth stored 0)))))
        (is (= "Local title" (title (runtime/db current) "new")))
        (is (= (Some "page") (runtime/journal-page-uuid current 20260816)))
        (is (some #(= "page" (:uuid %)) (:recent-pages (runtime/sidebar-pages current))))))))

(deftest stale-cursors-and-missing-titles-are-rejected-before-staging
  (with-runtime
    (fn [path _ current]
      (let [db (runtime/db current)
            without-title (ds/db-with (list (add 30 "block/uuid" (ds/Uuid "without-title"))) db)
            stale (assoc (save-title "stale" "Old" "New") :base-t 41)
            stale-error (Error "operation was created against a stale server cursor")]
        (is (= (Error "block no longer exists") (pending/raw-title db "missing")))
        (is (= (Error "block title is missing") (pending/raw-title without-title "without-title")))
        (is (= (Error "title changed on the server")
               (pending/normalize-expected-title db "block" "Wrong")))
        (is (= stale-error (runtime/prepare-sync current stale)))
        (is (= stale-error (runtime/stage current stale)))
        (is (empty? (pending/list path)))))))

(deftest pending-task-status-is-visible-without-changing-the-authoritative-ref
  (with-store
    (fn [path]
      (let [db (ds/db-with
                (list (add 20 "block/uuid" (ds/Uuid "status-todo"))
                      (add 20 "db/ident" (ds/Keyword "logseq.property/status.todo"))
                      (add 20 "block/title" (ds/String "Todo"))
                      (add 21 "block/uuid" (ds/Uuid "status-doing"))
                      (add 21 "db/ident" (ds/Keyword "logseq.property/status.doing"))
                      (add 21 "block/title" (ds/String "Doing"))
                      (add 10 "logseq.property/status" (ds/Ref 20))) (base-db "Task"))
            conn (ds/conn-from-db db)
            current (runtime/create path 42 conn runtime/default-options)
            op (operation "status"
                          (pending/Set-property (record pending/pending-property
                                                        (uuid "block") (attr "logseq.property/status")
                                                        (expected (Some (pending/Ref-uuid "status-todo")))
                                                        (value (Some (pending/Ref-uuid "status-doing"))))))]
        (is (ok? (projection/compile db (:intent op))))
        (is (ok? (runtime/stage current op)))
        (let [blocks (runtime/blocks current)]
          (is (= 1 (count blocks)))
          (is (match (:status (nth blocks 0)) (Some status) (= "status-doing" (:uuid status)) _ false)))
        (is (identical? db (ds/conn-db conn)))))))

(deftest title-normalization-preserves-insert-and-non-title-intents
  (with-runtime
    (fn [_path conn _current]
      (let [insert (insert-operation "normalize-insert")
            intents [(pending/Move-block (record pending/pending-move (uuid "block") (page-uuid "page") (parent-uuid "page") (order "a1")))
                     (pending/Set-property (record pending/pending-property (uuid "block") (attr "block/title") (expected nil) (value nil)))
                     (pending/Move-blocks (record pending/pending-moves (moves [])))
                     (pending/Delete-blocks (record pending/pending-delete (uuids ["block"])))]]
        (is (= (Ok insert) (pending/normalize-operation (ds/conn-db conn) insert)))
        (run! (fn [intent]
                (let [op (operation "passthrough" intent)]
                  (is (= (Ok op) (pending/normalize-operation (ds/conn-db conn) op)))))
              intents)))))

(deftest status-only-properties-do-not-invalidate-search
  (let [db (base-db "Old")
        status (pending/Set-property (record pending/pending-property (uuid "block") (attr "logseq.property/status")
                                             (expected nil) (value (Some (pending/Ref-ident "logseq.property/status.todo")))))
        title (pending/Set-property (record pending/pending-property (uuid "block") (attr "block/title")
                                            (expected (Some (pending/String-value "Old"))) (value (Some (pending/String-value "New")))))]
    (is (empty? (pending/affected-uuids db status)))
    (is (= ["block"] (pending/affected-uuids db title)))))

(deftest safe-queued-title-rebases-to-the-latest-cursor-and-prepares-immediately
  (with-runtime
    (fn [path conn current]
      (is (ok? (runtime/stage current (save-title "queued-rebase" "Old" "Pending"))))
      (ds/reset-conn conn (base-db "Old"))
      (runtime/rebase current 43 (list) [])
      (let [stored (pending/list path)]
        (is (= [(save-title "queued-rebase" "Old" "Pending")]
               (mapv #(assoc % :base-t 42) stored)))
        (is (= [43] (mapv :base-t stored)))
        (is (prepares-save? current (nth stored 0)))))))

(deftest property-classification-reads-the-pending-projection
  (with-store
    (fn [path]
      (let [db (ds/db-with
                (list (add 20 "block/uuid" (ds/Uuid "property-class"))
                      (add 20 "db/ident" (ds/Keyword "logseq.class/Property")))
                (base-db "Old"))
            conn (ds/conn-from-db db)
            current (runtime/create path 42 conn runtime/default-options)
            op (operation "classify-property"
                          (pending/Add-tag (record pending/pending-tag
                                                   (uuid "block") (tag-uuid "property-class"))))]
        (is (not (runtime/node-is-property current "block")))
        (is (ok? (runtime/stage current op)))
        (is (runtime/node-is-property current "block"))
        (is (not (runtime/node-is-property current "missing")))
        (is (identical? db (ds/conn-db conn)))))))

(deftest runtime-title-normalization-shares-new-tags-without-mutating-the-graph
  (with-runtime
    (fn [path conn current]
      (let [before (runtime/db current)
            [titles created] (runtime/normalize-titles current "block" ["see [[Page]] #fresh" "#FRESH again"])]
        (is (= 1 (count created)))
        (let [[uuid name] (nth created 0)]
          (is (= "fresh" name))
          (is (not (empty? uuid)))
          (is (= [(str "see [[page]] #[[" uuid "]]") (str "#[[" uuid "]] again")] titles)))
        (is (identical? before (runtime/db current)))
        (is (identical? before (ds/conn-db conn)))
        (is (empty? (pending/list path)))))))
