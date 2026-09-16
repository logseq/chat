(ns logseq-chat.e2e-seed-data-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.e2e-seed-data :as seed]
            [logseq-chat.e2e-seed-cli :as cli]
            [logseq-chat.journal :as journal]
            [logseq-chat.graph-read :as graph]
            [logseq-chat.markup :as markup]
            [logseq-chat.flashcards :as cards]
            [logseq-chat.storage-codec :as codec]
            [ocaml.Datascript :as ds]
            [ocaml.Stdlib :as stdlib]))

(deftest command-line-validation-preserves-modes-and-exit-codes
  (is (= (Ok (tuple "graph.sqlite" :default)) (cli/parse-args ["seed" "graph.sqlite"])))
  (run! (fn [[flag mode]]
          (is (= (Ok (tuple "graph.sqlite" mode)) (cli/parse-args ["seed" "graph.sqlite" flag]))))
        [(tuple "--inspect" :inspect) (tuple "--header-navigation" :header-navigation)
         (tuple "--composer" :composer) (tuple "--outliner" :outliner)
         (tuple "--fixture" :fixture) (tuple "--performance" :performance)])
  (run! (fn [args] (is (= (Error (tuple 2 cli/usage)) (cli/parse-args args))))
        [[] ["seed"] ["seed" "graph.sqlite" "--inspect" "extra"]])
  (is (= (Error (tuple 2 "unknown seed mode: --unknown"))
         (cli/parse-args ["seed" "graph.sqlite" "--unknown"])))
  (is (= (tuple 2 "unknown seed mode: --unknown")
         (cli/run ["seed" "/nonexistent/graph.sqlite" "--unknown"]))))

(defn expect-ok [result]
  (match result (Ok value) value (Error message) (stdlib/failwith message)))

(def schema
  (let [one codec/default-schema-attr
        text (assoc one :value-type (Some (ds/StringType)))
        number (assoc one :value-type (Some (ds/NumberType)))
        ref (assoc one :value-type (Some (ds/RefType)) :indexed true)
        many-ref (assoc ref :cardinality (ds/Many))]
    (apply list
           {"block/uuid" (assoc one :unique (Some (ds/Identity)) :value-type (Some (ds/UuidType)) :indexed true)
            "block/name" (assoc text :unique (Some (ds/Identity)) :indexed true)
            "block/title" text "block/page" ref "block/parent" ref "block/link" ref
            "block/order" text "block/refs" many-ref "block/tags" many-ref
            "logseq.property.class/extends" many-ref
            "block/journal-day" (assoc number :indexed true)
            "block/created-at" number "block/updated-at" number "logseq.property/built-in?" one
            "db/ident" (assoc one :unique (Some (ds/Identity)) :value-type (Some (ds/KeywordType)) :indexed true)})))

(defn plain [value] (Ok value))

(defn visible [db] (graph/blocks plain 7 db))

(defn exists? [db uuid] (some? (ds/entid db "block/uuid" (ds/Uuid uuid))))

(deftest standard-fixture-links-tags-rich-blocks-and-cards
  (let [conn (ds/create-conn :schema schema)]
    (expect-ok (seed/seed conn))
    (let [db (ds/conn-db conn)
          blocks (visible db)
          source (or (some #(when (= (:uuid %) seed/source-uuid) %) blocks)
                     (stdlib/failwith "missing link source"))
          nodes (markup/parse (:references source) (:tags source) (:title source))]
      (is (= 8 (graph/journal-page-count db)))
      (is (= [(seed/page-uuid 7)] (mapv :uuid (:favorites (graph/sidebar-pages plain db)))))
      (is (= 18 (count blocks)))
      (is (not-any? #(= (:uuid %) seed/older-block-uuid) blocks))
      (is (= 2 (count (:references source))))
      (is (= [(tuple seed/tag-uuid "E2E Project") (tuple seed/trailing-tag-uuid "E2E Trailing")]
             (vec (sort (map #(tuple (:uuid %) (:title %)) (:tags source))))))
      (is (string/includes? (string/join " " (map markup/debug-string nodes)) "("))
      (is (= [seed/tag-uuid]
             (vec (keep (fn [node] (match node (markup/Markup_tag_ref uuid _) (Some uuid) _ None)) nodes))))
      (is (some #(= (:title %) "E2E Child Tag Object") (graph/objects-for-tag plain db seed/tag-uuid)))
      (let [due (cards/due-cards db 2000000100000)]
        (is (= 1 (count due)))
        (let [card (nth due 0)]
          (is (= "e2e00000-0000-4000-8000-000000000020" (:uuid (:block card))))
          (is (= "The capital of France is {{cloze Paris}}" (:title (:block card))))
          (is (= ["Paris is the answer"] (mapv :title (:children card)))))))))

(deftest outliner-reset-is-idempotent
  (let [conn (ds/create-conn :schema schema)]
    (dotimes [_ 2] (expect-ok (seed/seed-outliner conn 1787893600000)))
    (let [db (ds/conn-db conn)]
      (is (= 1 (graph/journal-page-count db)))
      (is (exists? db seed/outliner-block-uuid))
      (is (some #(= (:uuid %) seed/outliner-tag-uuid) (graph/tag-pages plain db)))
      (is (= 1 (count (visible db)))))))

(deftest standard-reset-is-idempotent
  (let [conn (ds/create-conn :schema schema)]
    (dotimes [_ 2] (expect-ok (seed/seed-fixture conn)))
    (is (= 8 (graph/journal-page-count (ds/conn-db conn))))
    (is (= 18 (count (visible (ds/conn-db conn)))))))

(deftest performance-reset-retains-one-hundred-journals
  (let [conn (ds/create-conn :schema schema)]
    (dotimes [_ 2] (expect-ok (seed/seed-performance conn 1788000000000)))
    (is (= 100 (graph/journal-page-count (ds/conn-db conn))))
    (is (= 56 (count (visible (ds/conn-db conn)))))))

(deftest header-navigation-has-fixed-date-and-title
  (let [conn (ds/create-conn :schema schema)]
    (expect-ok (seed/seed-header-navigation conn))
    (let [db (ds/conn-db conn)
          blocks (visible db)]
      (is (= 1 (graph/journal-page-count db)))
      (is (= 1 (count blocks)))
      (is (= (Some (tuple "Aug 24th, 2026" 20260824)) (:journal (nth blocks 0))))
      (is (= "E2E Header Navigation" (:title (nth blocks 0)))))))

(defn entity [id attrs]
  (ds/Entity (record Datascript.tx_entity (db-id id) (attrs (apply list attrs)))))

(deftest composer-reset-preserves-built-ins-and-removes-user-content
  (let [conn (ds/create-conn :schema schema)
        built-in-page "00000002-0000-4000-8000-000000000001"
        built-in-child "00000004-0000-4000-8000-000000000001"]
    (ds/transact-conn conn
                      (list
                       (entity (Some (ds/Temp_id "built-in-page"))
                               {"block/uuid" (ds/One_value (ds/Uuid built-in-page))
                                "block/title" (ds/One_value (ds/String "Built in"))
                                "logseq.property/built-in?" (ds/One_value (ds/Bool true))})
                       (entity None
                               {"block/uuid" (ds/One_value (ds/Uuid built-in-child))
                                "block/title" (ds/One_value (ds/String "Built-in child"))
                                "block/page" (ds/One_value (ds/Ref_to (ds/Temp_id "built-in-page")))
                                "block/parent" (ds/One_value (ds/Ref_to (ds/Temp_id "built-in-page")))
                                "block/order" (ds/One_value (ds/String "a0"))
                                "logseq.property/built-in?" (ds/One_value (ds/Bool true))})
                       (entity (Some (ds/Temp_id "stale-page"))
                               {"block/uuid" (ds/One_value (ds/Uuid "e2e-stale-page"))
                                "block/name" (ds/One_value (ds/String "stale journal"))
                                "block/title" (ds/One_value (ds/String "Stale Journal"))
                                "block/journal-day" (ds/One_value (ds/Int 20260827))})
                       (entity None
                               {"block/uuid" (ds/One_value (ds/Uuid "e2e-stale-block"))
                                "block/title" (ds/One_value (ds/String "Stale composer traffic"))
                                "block/page" (ds/One_value (ds/Ref_to (ds/Temp_id "stale-page")))
                                "block/parent" (ds/One_value (ds/Ref_to (ds/Temp_id "stale-page")))
                                "block/order" (ds/One_value (ds/String "a0"))})))
    (dotimes [_ 2] (expect-ok (seed/seed-composer conn 1787893600000)))
    (let [db (ds/conn-db conn)]
      (is (exists? db built-in-page))
      (is (exists? db built-in-child))
      (is (not (exists? db "e2e-stale-page")))
      (is (not (exists? db "e2e-stale-block")))
      (is (= 1 (graph/journal-page-count db)))
      (is (= ["E2E Composer Fixture"] (mapv :title (visible db)))))))

(deftest journal-title-ordinal-boundaries
  (run! (fn [[day title]] (is (= title (journal/day-title day))))
        [(tuple 20260101 "Jan 1st, 2026") (tuple 20260202 "Feb 2nd, 2026")
         (tuple 20260303 "Mar 3rd, 2026") (tuple 20260404 "Apr 4th, 2026")
         (tuple 20260511 "May 11th, 2026") (tuple 20260612 "Jun 12th, 2026")
         (tuple 20260713 "Jul 13th, 2026") (tuple 20260821 "Aug 21st, 2026")
         (tuple 20260922 "Sep 22nd, 2026") (tuple 20261023 "Oct 23rd, 2026")
         (tuple 20261130 "Nov 30th, 2026") (tuple 20261231 "Dec 31st, 2026")]))
