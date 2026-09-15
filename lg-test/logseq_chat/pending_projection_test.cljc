(ns logseq-chat.pending-projection-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.graph-read :as read]
            [logseq-chat.outliner :as outliner]
            [logseq-chat.pending-projection :as projection]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.storage-codec :as storage]
            [logseq-chat.graph-store :as store]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Stdlib :as stdlib]))

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
   "logseq.property/built-in?" one "logseq.property/hide?" one
   "logseq.property/deleted-at" (assoc one :value-type (Some (ds/InstantType)))
   "logseq.property.recycle/original-parent" ref-attr
   "logseq.property.recycle/original-page" ref-attr
   "logseq.property.recycle/original-order" string-attr
   "logseq.property/status" ref-attr "logseq.property.class/extends" many-ref
   "logseq.property.asset/type" string-attr "logseq.property.asset/size" number-attr
   "logseq.property.asset/checksum" string-attr
   "logseq.property.asset/remote-metadata" storage/default-schema-attr
   "user.property/effort" number-attr "user.property/label" string-attr
   "user.property/enabled" one})

(defn add [id attr value] (ds/Add (ds/Entity_id id) attr value))
(defn with-tx [db tx] (ds/db-with (apply list tx) db))
(defn base-db []
  (with-tx (ds/empty-db :schema (apply list (seq schema)))
    [(add 1 "block/uuid" (ds/Uuid "page")) (add 1 "block/title" (ds/String "Page"))
     (add 1 "block/name" (ds/String "page"))
     (add 2 "block/uuid" (ds/Uuid "project")) (add 2 "block/title" (ds/String "Project"))
     (add 2 "block/name" (ds/String "project")) (add 2 "block/tags" (ds/Ref 4))
     (add 3 "block/uuid" (ds/Uuid "old-ref")) (add 3 "block/title" (ds/String "Old ref"))
     (add 3 "block/name" (ds/String "old ref"))
     (add 4 "db/ident" (ds/Keyword "logseq.class/Tag"))
     (add 6 "db/ident" (ds/Keyword "logseq.class/Root"))
     (add 7 "db/ident" (ds/Keyword "logseq.class/Asset"))
     (add 5 "block/uuid" (ds/Uuid "non-inline-tag")) (add 5 "block/title" (ds/String "Non-inline"))
     (add 5 "block/name" (ds/String "non-inline")) (add 5 "block/tags" (ds/Ref 4))
     (add 10 "block/uuid" (ds/Uuid "block")) (add 10 "block/title" (ds/String "Old"))
     (add 10 "block/page" (ds/Ref 1)) (add 10 "block/parent" (ds/Ref 1))
     (add 10 "block/order" (ds/String "a0")) (add 10 "block/refs" (ds/Ref 3))
     (add 10 "block/tags" (ds/Ref 5))]))
(defn value [db uuid attr] (projection/one-value db (projection/lookup uuid) attr))
(defn title [db uuid]
  (match (value db uuid "block/title")
    (Some (ds/String text)) text _ (stdlib/failwith (str "missing title: " uuid))))
(defn operation [id intent]
  (record ops/pending-operation (operation-id id) (base-t 42) (state ops/Queued) (intent intent)))
(defn save-title [uuid before after]
  (ops/Save-title (record ops/pending-title (uuid uuid) (expected-title before) (title after))))
(defn property [uuid attr expected value]
  (ops/Set-property (record ops/pending-property (uuid uuid) (attr attr) (expected expected) (value value))))
(defn insert [uuid title parent order]
  (ops/Insert-block (record ops/pending-insert (uuid uuid) (title title) (page-uuid "page")
                            (parent-uuid parent) (order order) (created-at 100))))
(defn move [uuid parent order]
  (ops/Move-block (record ops/pending-move (uuid uuid) (page-uuid "page") (parent-uuid parent) (order order))))
(defn delete-blocks [uuids] (ops/Delete-blocks (record ops/pending-delete (uuids uuids))))
(defn apply-intent [db intent]
  (match (projection/compile db intent) (Ok tx) (with-tx db tx) (Error message) (stdlib/failwith message)))
(defn conflict? [snapshot id]
  (boolean (some (fn [[key state]] (and (= key id) (match state (ops/Conflicted _) true _ false))) (:statuses snapshot))))

(deftest title-replay-updates-references-without-mutating-authoritative-db
  (let [db (base-db) snapshot (projection/build 42 db [(operation "title" (save-title "block" "Old" "New [[Project]]"))])
        projected (:db snapshot)]
    (is (= "New [[Project]]" (title projected "block")))
    (is (projection/has-ref projected 10 "block/refs" 2))
    (is (not (projection/has-ref projected 10 "block/refs" 3)))
    (is (= "Old" (title db "block")))
    (is (projection/has-ref db 10 "block/refs" 3))
    (is (= [(tuple "title" ops/Applied)] (:statuses snapshot)))))

(deftest inline-tag-replacement-preserves-independent-tags
  (let [db (base-db) tagged (apply-intent db (save-title "block" "Old" "New #[[project]]"))
        plain (apply-intent tagged (save-title "block" "New #[[project]]" "Plain"))]
    (is (projection/has-ref tagged 10 "block/tags" 2))
    (is (projection/has-ref tagged 10 "block/tags" 5))
    (is (not (projection/has-ref plain 10 "block/tags" 2)))
    (is (projection/has-ref plain 10 "block/tags" 5))))

(deftest replay-is-ordered-and-rebase-conflicts-preserve-remote-data
  (let [db (base-db) first-op (operation "first" (save-title "block" "Old" "First"))
        second-op (operation "second" (save-title "block" "First" "Second"))
        snapshot (projection/build 42 db [first-op second-op])
        remote (with-tx db [(add 10 "block/title" (ds/String "Remote"))])
        rebased (projection/build 43 remote [first-op])]
    (is (= "Second" (title (:db snapshot) "block")))
    (is (= [(tuple "first" ops/Applied) (tuple "second" ops/Applied)] (:statuses snapshot)))
    (is (= "Remote" (title (:db rebased) "block")))
    (is (conflict? rebased "first"))))

(deftest properties-replay-with-compare-and-set-and-retraction
  (let [db (with-tx (base-db)
             [(add 10 "user.property/label" (ds/String "Old label"))
              (add 10 "user.property/enabled" (ds/Bool false))])
        snapshot (projection/build 42 db
                                   [(operation "label" (property "block" "user.property/label" (Some (ops/String-value "Old label")) (Some (ops/String-value "New label"))))
                                    (operation "enabled" (property "block" "user.property/enabled" (Some (ops/Bool-value false)) (Some (ops/Bool-value true))))
                                    (operation "retract" (property "block" "user.property/label" (Some (ops/String-value "New label")) nil))])
        projected (:db snapshot)]
    (is (nil? (value projected "block" "user.property/label")))
    (is (= (Some (ds/Bool true)) (value projected "block" "user.property/enabled")))
    (is (= (Some (ds/String "Old label")) (value db "block" "user.property/label")))
    (is (match (projection/compile projected (property "block" "user.property/enabled" (Some (ops/Bool-value false)) nil))
          (Error _) true _ false))))

(deftest insertion-followed-by-move-uses-the-projected-database
  (let [db (base-db)
        snapshot (projection/build 42 db
                   [(operation "insert" (insert "inserted" "Inserted [[Project]]" "block" "a1"))
                    (operation "move" (move "inserted" "page" "a2"))])
        projected (:db snapshot)]
    (is (= "Inserted [[Project]]" (title projected "inserted")))
    (is (= (Some (ds/Ref 1)) (value projected "inserted" "block/parent")))
    (is (= (Some (ds/String "a2")) (value projected "inserted" "block/order")))
    (is (if-some [eid (ds/entid projected "block/uuid" (ds/Uuid "inserted"))]
          (projection/has-ref projected eid "block/refs" 2) false))
    (is (nil? (ds/entid db "block/uuid" (ds/Uuid "inserted"))))))

(deftest recursive-delete-does-not-change-authoritative-entities
  (let [db (apply-intent (base-db) (insert "child" "Child" "block" "a0"))
        snapshot (projection/build 42 db [(operation "delete" (delete-blocks ["block"]))])]
    (run! (fn [uuid]
            (is (nil? (ds/entid (:db snapshot) "block/uuid" (ds/Uuid uuid))))
            (is (some? (ds/entid db "block/uuid" (ds/Uuid uuid))))) ["block" "child"])))

(deftest invalid-targets-and-cycles-become-conflicts
  (let [db (base-db)]
    (run! (fn [intent]
            (let [snapshot (projection/build 42 db [(operation "invalid" intent)])]
              (is (conflict? snapshot "invalid"))
              (is (= "Old" (title (:db snapshot) "block")))
              (is (= "Page" (title (:db snapshot) "page")))))
          [(property "missing" "block/title" nil (Some (ops/String-value "Must not transact")))
           (move "block" "block" "a0") (insert "orphan" "Orphan" "missing" "a0")
           (delete-blocks ["page"]) (delete-blocks ["missing"])
           (save-title "block" "Wrong" "New") (save-title "missing" "" "New")
           (insert "block" "Duplicate" "page" "a1") (move "block" "missing" "a1")
           (ops/Move-blocks (record ops/pending-moves (moves [])))])))

(deftest reference-properties-compare-stable-identities
  (let [db (base-db)
        snapshot (projection/build 42 db
                   [(operation "status" (property "block" "logseq.property/status" nil (Some (ops/Ref-uuid "project"))))])
        projected (:db snapshot)
        conflict (projection/build 42 projected
                                   [(operation "stale" (property "block" "logseq.property/status" (Some (ops/Ref-uuid "old-ref")) nil))])]
    (is (= (Some (ds/Ref 2)) (value projected "block" "logseq.property/status")))
    (is (conflict? conflict "stale"))))

(deftest split-and-merge-are-atomic-and-reparent-children
  (let [db (base-db)
        split (ops/Split-block (record ops/pending-split (uuid "block") (expected-title "Old")
                                       (before "O") (after "ld") (new-uuid "split") (new-order "a1") (created-at 100)))
        snapshot (projection/build 42 db [(operation "split" split)])
        split-db (:db snapshot)]
    (is (= "O" (title split-db "block")))
    (is (= "ld" (title split-db "split")))
    (is (projection/satisfied split-db split))
    (is (= "Old" (title db "block")))
    (is (nil? (ds/entid db "block/uuid" (ds/Uuid "split"))))
    (let [with-child (apply-intent split-db (insert "child" "Child" "split" "a0"))
          merge-intent (ops/Merge-backward
                        (record ops/pending-merge (uuid "split") (expected-title "ld") (title "ld")
                                (previous-uuid "block") (expected-previous-title "O") (merged-title nil)))
          merged (:db (projection/build 42 with-child [(operation "merge" merge-intent)]))]
      (is (= "Old" (title merged "block")))
      (is (nil? (ds/entid merged "block/uuid" (ds/Uuid "split"))))
      (is (= (Some (ds/Ref 10)) (value merged "child" "block/parent")))
      (is (some? (ds/entid with-child "block/uuid" (ds/Uuid "split")))))
    (let [linked (apply-intent db
                               (ops/Split-block (record ops/pending-split (uuid "block") (expected-title "Old")
                                                        (before "O") (after "[[Project]]") (new-uuid "linked") (new-order "a1") (created-at 100))))]
      (is (if-some [eid (ds/entid linked "block/uuid" (ds/Uuid "linked"))]
            (projection/has-ref linked eid "block/refs" 2) false)))))

(deftest flashcard-property-batch-is-atomic
  (let [db (base-db)
        state (ops/Map-value [(tuple "state" (ops/Keyword-value "learning"))
                              (tuple "stability" (ops/Float-value 0.4)) (tuple "reps" (ops/Int-value 1))])
        intent (ops/Set-properties
                (record ops/pending-properties (uuid "block")
                        (changes [(record ops/property-change (attr "logseq.property.fsrs/state") (expected nil) (value (Some state)))
                                  (record ops/property-change (attr "logseq.property.fsrs/due") (expected nil)
                                          (value (Some (ops/Int-value 1776000060000))))])))
        projected (apply-intent db intent)
        remote (with-tx db [(add 10 "logseq.property.fsrs/due" (ds/Int 99))])]
    (is (projection/satisfied projected intent))
    (is (projection/semantic-value-equal projected (value projected "block" "logseq.property.fsrs/state") (Some state)))
    (is (= (Some (ds/Int 1776000060000)) (value projected "block" "logseq.property.fsrs/due")))
    (is (match (projection/compile remote intent) (Error _) true _ false))
    (is (nil? (value remote "block" "logseq.property.fsrs/state")))))

(deftest asset-projection-keeps-upload-metadata-and-built-in-class
  (let [intent (ops/Create-asset
                (record ops/pending-asset (uuid "asset") (title "photo.png") (page-uuid "page")
                        (parent-uuid "block") (order "a1") (created-at 100)
                        (asset-type "png") (asset-size 2048) (asset-checksum "abc123")))
        db (apply-intent (base-db) intent)]
    (is (projection/satisfied db intent))
    (is (= "photo.png" (title db "asset")))
    (is (if-some [eid (ds/entid db "block/uuid" (ds/Uuid "asset"))]
          (projection/has-ref db eid "block/tags" 7) false))
    (is (= (Some (ds/String "png")) (value db "asset" "logseq.property.asset/type")))
    (is (= (Some (ds/Int 2048)) (value db "asset" "logseq.property.asset/size")))
    (is (= (Some (ds/String "abc123")) (value db "asset" "logseq.property.asset/checksum")))
    (is (match (value db "asset" "logseq.property.asset/remote-metadata")
          (Some (ds/Map entries))
          (and (some #(= (tuple (ds/Keyword "checksum") (ds/String "abc123")) %) entries)
               (some #(= (tuple (ds/Keyword "type") (ds/String "png")) %) entries))
          _ false))))

(defn with-store [f]
  (let [path (filename/temp-file "logseq-chat-pending-projection" ".sqlite")]
    (try
      (store/prepare-staging path)
      (f path)
      (finally (run! #(when (sys/file-exists %) (sys/remove %)) [path (store/staging-path path)])))))

(deftest pending-storage-preserves-legacy-wire-format-and-state-transitions
  (with-store
    (fn [path]
      (let [op (operation "op-persisted" (save-title "block" "Old" "Offline"))
            payload "{\"type\":\"save-title\",\"uuid\":\"block\",\"expectedTitle\":\"Old\",\"title\":\"Offline\"}"]
        (ops/store-raw path "op-persisted" 42 "queued" payload)
        (is (= [op] (ops/list path)))
        (ops/save path (assoc op :state (ops/Accepted 43)))
        (is (= [(tuple "op-persisted" 42 "accepted:43" payload)] (vec (ops/list-raw path))))
        (run! (fn [state]
                (ops/set-state path "op-persisted" state)
                (is (= [(assoc op :state state)] (ops/list path)))) [ops/Retryable ops/Submitted])
        (ops/confirm path ["op-persisted" "unknown"])
        (is (empty? (ops/list path)))))))

(deftest pending-storage-upsert-preserves-insertion-order
  (with-store
    (fn [path]
      (let [intents [(save-title "block" "Old" "你好 [[Project]]")
                     (property "block" "user.property/effort" (Some (ops/Int-value 1)) (Some (ops/Int-value 2)))
                     (insert "new" "New" "block" "a0") (move "new" "page" "a1")
                     (ops/Move-blocks (record ops/pending-moves
                                              (moves [(record ops/pending-move (uuid "new") (page-uuid "page") (parent-uuid "block") (order "a1"))])))
                     (ops/Split-block (record ops/pending-split (uuid "block") (expected-title "Old")
                                              (before "O") (after "ld") (new-uuid "split") (new-order "a2") (created-at 8)))
                     (ops/Merge-backward (record ops/pending-merge (uuid "split") (expected-title "ld") (title "ld")
                                                 (previous-uuid "block") (expected-previous-title "O") (merged-title nil)))
                     (delete-blocks ["block" "new"])
                     (ops/Set-favorite (record ops/pending-favorite (page-uuid "project") (favorite-uuid "favorite-project")
                                               (favorite true) (order "a0") (created-at 9)))
                     (ops/Delete-page (record ops/pending-page-delete (page-uuid "project") (order "a1") (deleted-at 10)))]
            operations (mapv (fn [index intent] (operation (str "op-" index) intent)) (range (count intents)) intents)]
        (run! #(ops/save path %) operations)
        (is (= operations (ops/list path)))
        (let [replacement (assoc (nth operations 0) :state ops/Retryable :intent (save-title "block" "Old" "Replacement"))]
          (ops/save path replacement)
          (is (= (assoc operations 0 replacement) (ops/list path))))))))

(deftest cursor-advance-does-not-confirm-unidentified-operations
  (with-store
    (fn [path]
      (let [first-op (assoc (operation "first" (save-title "block" "Old" "First")) :state (ops/Accepted 43))
            second-op (assoc (operation "second" (save-title "block" "First" "Second")) :state ops/Submitted)]
        (run! #(ops/save path %) [first-op second-op])
        (ops/confirm path [])
        (is (= [first-op second-op] (ops/list path)))
        (ops/confirm path ["first" "unknown"])
        (is (= [second-op] (ops/list path)))))))

(deftest snapshot-replacement-preserves-pending-operations
  (with-store
    (fn [path]
      (let [op (operation "survives-snapshot" (save-title "block" "Old" "Offline"))]
        (ops/save path op)
        (is (match (store/begin-import path) (Ok _) true (Error _) false))
        (is (match (store/activate path) (Ok _) true (Error _) false))
        (is (= [op] (ops/list path)))))))

(deftest favorite-and-unfavorite-update-the-sidebar
  (let [db (with-tx (base-db)
             [(add 20 "block/uuid" (ds/Uuid "favorites-page"))
              (add 20 "block/title" (ds/String "Favorites"))
              (add 20 "block/name" (ds/String "$$$favorites"))])
        favorite (record ops/pending-favorite (page-uuid "project") (favorite-uuid "favorite-project")
                         (favorite true) (order "a0") (created-at 100))
        on (ops/Set-favorite favorite) off (ops/Set-favorite (assoc favorite :favorite false))
        favorited (apply-intent db on) unfavorited (apply-intent favorited off)]
    (is (projection/satisfied favorited on))
    (is (= ["project"] (mapv :uuid (:favorites (read/sidebar-pages #(Ok %) favorited)))))
    (is (projection/satisfied unfavorited off))
    (is (empty? (:favorites (read/sidebar-pages #(Ok %) unfavorited))))))

(deftest recycling-pages-hides-descendants-and-preserves-original-location
  (let [db (with-tx (base-db)
             [(add 1 "block/parent" (ds/Ref 6)) (add 1 "block/order" (ds/String "a1"))
              (add 30 "block/uuid" (ds/Uuid "recycle-page")) (add 30 "block/title" (ds/String "Recycle"))
              (add 30 "block/name" (ds/String "recycle"))
              (add 30 "logseq.property/built-in?" (ds/Bool true)) (add 30 "logseq.property/hide?" (ds/Bool true))])
        intent (ops/Delete-page (record ops/pending-page-delete (page-uuid "page") (order "a0") (deleted-at 100)))
        recycled (apply-intent db intent)]
    (is (projection/satisfied recycled intent))
    (is (not (some #(= "page" (:uuid %)) (:recent-pages (read/sidebar-pages #(Ok %) recycled)))))
    (run! #(is (nil? (read/node-destination (fn [value] (Ok value)) recycled %))) ["page" "block"])
    (is (= (Some (ds/Ref 6)) (value recycled "page" "logseq.property.recycle/original-parent")))
    (is (= (Some (ds/Ref 1)) (value recycled "page" "logseq.property.recycle/original-page")))
    (is (= (Some (ds/String "a1")) (value recycled "page" "logseq.property.recycle/original-order")))
    (is (= "Page" (title recycled "page")))))

(deftest new-tags-can-be-referenced-by-later-pending-edits
  (let [db (base-db) intent (ops/Create-tag (record ops/pending-create (uuid "new-tag") (title "Foobar") (created-at 99)))
        snapshot (projection/build 42 db [(operation "create" intent)
                                          (operation "save" (save-title "block" "Old" "New #[[new-tag]]"))])
        projected (:db snapshot)]
    (is (= "Foobar" (title projected "new-tag")))
    (is (if-some [eid (ds/entid projected "block/uuid" (ds/Uuid "new-tag"))]
          (and (projection/has-ref projected eid "block/tags" 4)
               (projection/has-ref projected eid "logseq.property.class/extends" 6)
               (projection/has-ref projected 10 "block/tags" eid)) false))
    (is (match (value projected "new-tag" "db/ident")
          (Some (ds/Keyword ident)) (string/starts-with? ident "user.class/") _ false))
    (is (= (Ok []) (projection/compile projected intent)))
    (is (match (projection/compile (ds/empty-db :schema (apply list (seq schema))) intent) (Error _) true _ false))
    (is (projection/satisfied projected intent))
    (is (not (projection/satisfied db intent)))))

(def journal-intent
  (ops/Create-journal (record ops/pending-journal (page-uuid "today-page") (block-uuid "today-block")
                              (title "Aug 22nd, 2026") (journal-day 20260822) (created-at 99))))

(deftest partial-journal-creation-restores-the-missing-first-block
  (let [journal-schema (assoc schema "block/journal-day" (assoc number-attr :unique (Some (ds/Identity))))
        db (with-tx (ds/empty-db :schema (apply list (seq journal-schema)))
             [(add 20 "block/uuid" (ds/Uuid "today-page")) (add 20 "block/title" (ds/String "Aug 22nd, 2026"))
              (add 20 "block/name" (ds/String "aug 22nd, 2026")) (add 20 "block/journal-day" (ds/Int 20260822))])
        snapshot (projection/build 1 db [(assoc (operation "journal" journal-intent) :base-t 0)])]
    (is (some? (ds/entid db "block/journal-day" (ds/Int 20260822))))
    (is (nil? (ds/entid db "block/uuid" (ds/Uuid "today-block"))))
    (is (not (projection/satisfied db journal-intent)))
    (is (some? (ds/entid (:db snapshot) "block/uuid" (ds/Uuid "today-block"))))
    (is (projection/satisfied (:db snapshot) journal-intent))))

(deftest journals-use-the-canonical-journal-class
  (let [db (with-tx (ds/empty-db :schema (apply list (seq schema))) [(add 1 "db/ident" (ds/Keyword "logseq.class/Journal"))])
        projected (:db (projection/build 1 db [(assoc (operation "journal" journal-intent) :base-t 0)]))]
    (is (if-some [eid (ds/entid projected "block/uuid" (ds/Uuid "today-page"))]
          (projection/has-ref projected eid "block/tags" 1) false))))

(deftest ordinary-page-creation-is-visible-and-survives-restart
  (let [intent (ops/intent-of-json (json/from-string "{\"type\":\"create-page\",\"uuid\":\"new-page\",\"title\":\"New Page\",\"createdAt\":7}"))
        op (operation "create-page" intent) projected (:db (projection/build 42 (base-db) [op]))]
    (is (= "New Page" (title projected "new-page")))
    (is (if-some [eid (ds/entid projected "block/uuid" (ds/Uuid "new-page"))]
          (not (projection/has-ref projected eid "block/tags" 4)) false))
    (is (some #(= "new-page" (:uuid %)) (:recent-pages (read/sidebar-pages #(Ok %) projected))))
    (with-store (fn [path] (ops/save path op) (is (= [op] (ops/list path)))))))

(deftest semantic-equality-preserves-nested-values-and-reference-identities
  (let [db (with-tx (base-db) [(add 50 "db/ident" (ds/Keyword "status.todo"))])
        nested (ops/Map-value [(tuple "nested" (ops/Map-value [(tuple "value" (ops/Int-value 1))]))])]
    (run! (fn [[actual expected]] (is (projection/semantic-value-equal db (Some actual) (Some expected))))
          [(tuple (ds/Instant 42) (ops/Instant-value 42))
           (tuple (ds/Float 1.0) (ops/Float-value 1.0)) (tuple (ds/Int 1) (ops/Float-value 1.0))
           (tuple (ds/Int 8) (ops/Int-value 8)) (tuple (ds/Bool true) (ops/Bool-value true))
           (tuple (ds/Ref 50) (ops/Ref-ident "status.todo")) (tuple (ds/Int 50) (ops/Ref-ident "status.todo"))
           (tuple (ds/Map (list (tuple (ds/Keyword "nested") (ds/Map (list (tuple (ds/Keyword "value") (ds/Int 1))))))) nested)])
    (run! #(is (not (projection/semantic-value-equal db (Some %) (Some nested))))
          [(ds/Map (list))
           (ds/Map (list (tuple (ds/String "nested") (ds/Map (list (tuple (ds/Keyword "value") (ds/Int 1)))))))
           (ds/Map (list (tuple (ds/Keyword "nested") (ds/Map (list (tuple (ds/Keyword "value") (ds/Int 2)))))))])))

(deftest lookup-and-title-helpers-reject-incomplete-data
  (let [db (base-db)
        without-tag (with-tx (ds/empty-db :schema (apply list (seq schema)))
                      [(add 1 "block/uuid" (ds/Uuid "project")) (add 1 "block/name" (ds/String "project"))])]
    (is (= ["Project"] (projection/page-names "[[]] [[Project]] [[")))
    (is (empty? (projection/page-names "plain")))
    (is (empty? (projection/inline-tag-names "#[[]] #[[unfinished")))
    (is (empty? (projection/tag-eids-for-title without-tag "#[[project]]")))
    (is (nil? (value db "missing" "block/title")))
    (is (nil? (value db "block" "block/refs")))
    (is (nil? (projection/uuid-for-eid db 999)))
    (run! #(is (nil? (projection/outliner-block db %))) ["missing" "project"])
    (is (= [(ds/Add (projection/lookup "new-title-target") "block/title" (ds/String "New"))]
           (projection/title-tx db "new-title-target" "New")))
    (is (empty? (projection/outliner-mutation-tx db (outliner/Delete (record outliner/delete-mutation (uuid "missing"))))))))

(deftest inline-tagged-insertion-emits-one-entity-transaction
  (let [db (base-db) intent (insert "inline-tagged-insert" "New #[[project]]" "page" "a1")]
    (is (match (projection/compile db intent)
          (Ok tx) (and (= 1 (count tx))
                       (match (nth tx 0)
                         (ds/Entity entity) (some (fn [[attr _]] (= attr "block/tags")) (:attrs entity))
                         _ false))
          _ false))
    (let [projected (apply-intent db intent)]
      (is (if-some [eid (ds/entid projected "block/uuid" (ds/Uuid "inline-tagged-insert"))]
            (projection/has-ref projected eid "block/tags" 2) false)))))

(defn raw [id attr value] (ds/Raw_datom (ds/datom :e id :a attr :v value)))

(deftest malformed-structural-references-are-not-editable
  (let [db (with-tx (base-db)
             [(add 41 "block/title" (ds/String "No UUID"))
              (add 40 "block/uuid" (ds/Uuid "dangling")) (add 40 "block/title" (ds/String "Dangling"))
              (add 40 "block/page" (ds/Ref 41)) (add 40 "block/parent" (ds/Ref 1)) (add 40 "block/order" (ds/String "a9"))
              (add 42 "block/uuid" (ds/Uuid "malformed-ref")) (add 42 "block/title" (ds/String "Malformed ref"))
              (raw 42 "block/page" (ds/String "not-a-ref")) (add 42 "block/parent" (ds/Ref 1)) (add 42 "block/order" (ds/String "b0"))])]
    (run! #(is (nil? (projection/outliner-block db %))) ["dangling" "malformed-ref"])))

(deftest raw-numeric-references-support-editing-and-recursive-deletion
  (let [db (with-tx (ds/empty-db :schema (apply list (seq schema)))
             [(raw 1 "block/uuid" (ds/Uuid "raw-page")) (raw 1 "block/name" (ds/String "raw-page"))
              (raw 1 "block/title" (ds/String "Raw page"))
              (raw 10 "block/uuid" (ds/Uuid "raw-parent")) (raw 10 "block/title" (ds/String "Parent"))
              (raw 10 "block/page" (ds/Int 1)) (raw 10 "block/parent" (ds/Int 1)) (raw 10 "block/order" (ds/String "a0"))
              (raw 11 "block/uuid" (ds/Uuid "raw-child")) (raw 11 "block/title" (ds/String "Child"))
              (raw 11 "block/page" (ds/Int 1)) (raw 11 "block/parent" (ds/Int 10)) (raw 11 "block/order" (ds/String "a0"))])
        deleted (apply-intent db (delete-blocks ["raw-parent"]))]
    (is (projection/semantic-value-equal db (value db "raw-child" "block/parent") (Some (ops/Ref-uuid "raw-parent"))))
    (is (if-some [block (projection/outliner-block db "raw-child")]
          (and (= "raw-page" (:page-uuid block)) (= "raw-parent" (:parent-uuid block))) false))
    (run! #(is (nil? (ds/entid deleted "block/uuid" (ds/Uuid %)))) ["raw-parent" "raw-child"])))

(deftest batch-moves-project-all-structural-updates
  (let [db (apply-intent (apply-intent (base-db) (insert "second" "Second" "page" "a1"))
                        (insert "target" "Target" "page" "a2"))
        intent (ops/Move-blocks (record ops/pending-moves
                                 (moves [(record ops/pending-move (uuid "block") (page-uuid "page") (parent-uuid "target") (order "a0"))
                                         (record ops/pending-move (uuid "second") (page-uuid "page") (parent-uuid "target") (order "a1"))])))
        snapshot (projection/build 42 db [(operation "batch" intent)])]
    (is (= [(tuple "batch" ops/Applied)] (:statuses snapshot)))
    (is (projection/satisfied (:db snapshot) intent))
    (run! (fn [uuid]
            (is (projection/semantic-value-equal (:db snapshot) (value (:db snapshot) uuid "block/parent")
                                                (Some (ops/Ref-uuid "target"))))) ["block" "second"])))

(deftest built-in-status-properties-resolve-identities
  (let [db (with-tx (base-db) [(add 20 "db/ident" (ds/Keyword "logseq.property/status.todo"))
                              (add 20 "block/title" (ds/String "Todo"))
                              (add 21 "db/ident" (ds/Keyword "logseq.property/status.doing"))
                              (add 21 "block/title" (ds/String "Doing"))
                              (add 10 "logseq.property/status" (ds/Ref 20))])
        snapshot (projection/build 42 db
                   [(operation "status" (property "block" "logseq.property/status"
                                          (Some (ops/Ref-ident "logseq.property/status.todo"))
                                          (Some (ops/Ref-ident "logseq.property/status.doing"))))])]
    (is (= (Some (ds/Ref 21)) (value (:db snapshot) "block" "logseq.property/status")))
    (is (= [(tuple "status" ops/Applied)] (:statuses snapshot)))))

(deftest satisfaction-checks-resulting-values-and-structure
  (let [db (base-db) insertion (insert "inserted" "Inserted" "page" "a1")
        inserted (apply-intent db insertion)
        current (record ops/pending-move (uuid "block") (page-uuid "page") (parent-uuid "page") (order "a0"))]
    (is (projection/satisfied db (save-title "block" "Before" "Old")))
    (is (not (projection/satisfied db (save-title "block" "Old" "Other"))))
    (is (projection/satisfied db (property "block" "user.property/label" nil nil)))
    (is (not (projection/satisfied db (property "block" "user.property/label" nil (Some (ops/String-value "value"))))))
    (is (projection/satisfied inserted insertion))
    (is (not (projection/satisfied inserted (insert "inserted" "Inserted" "block" "a1"))))
    (is (projection/satisfied db (ops/Move-block current)))
    (is (projection/satisfied db (ops/Move-blocks (record ops/pending-moves (moves [current])))))
    (is (not (projection/satisfied db (ops/Move-blocks (record ops/pending-moves (moves []))))))
    (is (not (projection/satisfied db (ops/Move-blocks (record ops/pending-moves (moves [(assoc current :order "wrong")]))))))
    (is (projection/satisfied db (delete-blocks ["missing"])))
    (is (not (projection/satisfied db (delete-blocks ["block"]))))
    (let [split (record ops/pending-split (uuid "block") (expected-title "Old") (before "O") (after "ld")
                  (new-uuid "split") (new-order "a1") (created-at 1))
          split-db (apply-intent db (ops/Split-block split))
          merge-intent (ops/Merge-backward (record ops/pending-merge (uuid "split") (expected-title "ld") (title "ld")
                                            (previous-uuid "block") (expected-previous-title "O") (merged-title (Some "Old"))))]
      (is (projection/satisfied split-db (ops/Split-block split)))
      (is (not (projection/satisfied split-db (ops/Split-block (assoc split :new-order "wrong")))))
      (is (projection/satisfied (apply-intent split-db merge-intent) merge-intent)))))

(deftest invalid-batches-missing-pages-and-missing-split-sources-are-rejected
  (let [db (base-db)
        valid-move (record ops/pending-move (uuid "block") (page-uuid "page") (parent-uuid "page") (order "a1"))]
    (run! (fn [intent] (is (match (projection/compile db intent) (Error _) true _ false)))
          [(ops/Insert-block (record ops/pending-insert (uuid "new") (title "New") (page-uuid "missing")
                               (parent-uuid "page") (order "a1") (created-at 1)))
           (ops/Move-blocks (record ops/pending-moves (moves [valid-move (assoc valid-move :uuid "missing" :order "a2")])) )
           (ops/Split-block (record ops/pending-split (uuid "missing") (expected-title "") (before "") (after "")
                              (new-uuid "new") (new-order "a1") (created-at 1)))])
    (is (= (Some (ds/String "a0")) (value db "block" "block/order")))))

(deftest journal-deletion-and-cyclic-parent-traversal-are-rejected
  (let [journal-db (with-tx (base-db)
                     [(add 30 "block/uuid" (ds/Uuid "journal")) (add 30 "block/title" (ds/String "Journal"))
                      (add 30 "block/journal-day" (ds/Int 20260817))])
        cyclic (with-tx (base-db) [(add 10 "block/parent" (ds/Ref 10))])]
    (is (match (projection/compile journal-db (delete-blocks ["journal"])) (Error _) true _ false))
    (is (match (projection/compile cyclic (move "block" "block" "a0")) (Error _) true _ false))))

(deftest projected-properties-are-queryable-without-changing-authoritative-indexes
  (let [db (base-db)
        projected (:db (projection/build 42 db
                         [(operation "effort" (property "block" "user.property/effort" nil (Some (ops/Int-value 8))))]))]
    (is (some (fn [_] true) (db-api/datoms projected (ds/Aevt) :a "user.property/effort" :v (ds/Int 8))))
    (is (empty? (db-api/datoms db (ds/Aevt) :a "user.property/effort")))))
