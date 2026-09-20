(ns logseq-chat.search-index-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.search-index :as search]
            [logseq-chat.storage-codec :as storage]
            [ocaml.Datascript :as ds]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]))

(def one storage/default-schema-attr)

(def schema
  (list (tuple "block/uuid" (assoc one :unique (Some (ds/Identity)) :indexed true :value-type (Some (ds/UuidType))))
        (tuple "block/name" (assoc one :value-type (Some (ds/StringType))))
        (tuple "block/title" (assoc one :value-type (Some (ds/StringType))))
        (tuple "block/page" (assoc one :value-type (Some (ds/RefType))))
        (tuple "block/parent" (assoc one :value-type (Some (ds/RefType))))
        (tuple "block/journal-day" one) (tuple "logseq.property/built-in?" one)
        (tuple "logseq.property/hide?" one)))

(def page-uuid "018f7850-0000-7da0-8b3f-6dbb64aa4ec1")

(def block-uuid "018f7850-0000-7da0-8b3f-6dbb64aa4ec2")

(def ref-block-uuid "018f7850-0000-7da0-8b3f-6dbb64aa4ec3")

(def journal-uuid "018f7850-0000-7da0-8b3f-6dbb64aa4ec4")

(def hidden-uuid "018f7850-0000-7da0-8b3f-6dbb64aa4ec5")

(def cjk-uuid "018f7850-0000-7da0-8b3f-6dbb64aa4ec6")

(defn add [eid attr value] (ds/Add (ds/Entity_id eid) attr value))

(defn seeded-conn []
  (let [conn (ds/create-conn :schema schema)]
    (ds/transact-conn conn
                      (list (add 1 "block/uuid" (ds/Uuid page-uuid))
                            (add 1 "block/name" (ds/String "movies")) (add 1 "block/title" (ds/String "Movies"))
                            (add 2 "block/uuid" (ds/Uuid block-uuid))
                            (add 2 "block/title" (ds/String "watch 4k movies tonight")) (add 2 "block/page" (ds/Ref 1))
                            (add 3 "block/uuid" (ds/Uuid ref-block-uuid))
                            (add 3 "block/title" (ds/String (str "[[" page-uuid "]] marathon plan")))
                            (add 3 "block/page" (ds/Ref 1))
                            (add 4 "block/uuid" (ds/Uuid journal-uuid))
                            (add 4 "block/name" (ds/String "aug 16th, 2026"))
                            (add 4 "block/title" (ds/String "Aug 16th, 2026"))
                            (add 4 "block/journal-day" (ds/Int 20260816))
                            (add 5 "block/uuid" (ds/Uuid hidden-uuid))
                            (add 5 "block/name" (ds/String "secret"))
                            (add 5 "block/title" (ds/String "Secret movies page"))
                            (add 5 "logseq.property/hide?" (ds/Bool true))
                            (add 6 "block/uuid" (ds/Uuid cjk-uuid))
                            (add 6 "block/title" (ds/String "晚上看电影"))
                            (add 6 "block/page" (ds/Ref 1))))
    conn))

(defn with-index [f]
  (let [root (filename/temp-file "logseq-chat-search" "")
        directory (filename/concat root "search") path (filename/concat directory "db.sqlite")]
    (sys/remove root)
    (unix/mkdir root 493)
    (try (f (search/create path))
         (finally
           (run! #(when (sys/file-exists %) (sys/remove %))
                 [path (str path "-wal") (str path "-shm") (str path "-journal")])
           (when (sys/file-exists directory) (unix/rmdir directory))
           (unix/rmdir root)))))

(defn results [index query] (search/search (fn [_] false) 100 index query))

(defn find-result [index query uuid]
  (some #(when (= (:uuid %) uuid) %) (results index query)))

(deftest match-input-preserves-logseq-boolean-and-phrase-rules
  (run! (fn [[query expected]] (is (= expected (search/get-match-input query))))
        [(tuple "movie" "movie") (tuple "left and right" "left AND right")
         (tuple "block/title" "\"block/title\"*") (tuple "left and " "\"left AND \"*")
         (tuple "say \"hello\"" "\"say \"\"hello\"\"\"*")]))

(deftest fuzzy-scores-and-utf8-segmentation-preserve-search-semantics
  (is (> (search/fuzzy-score "mov" "movies") (search/fuzzy-score "mov" "my old vase")))
  (is (< (search/fuzzy-score "mov" "task") 1.0))
  (is (= 1018.0 (search/fuzzy-score "abc" "abc")))
  (is (= 1012.0 (search/fuzzy-score "" "")))
  (let [cjk "电" emoji "😀" text (str "a" cjk emoji)]
    (is (= 3 (search/utf8-length text)))
    (is (= ["a" cjk emoji] (search/utf8-chars text))))
  (is (= "%\\%%\\_%\\\\%" (search/fuzzy-like-pattern "%_\\"))))

(deftest candidates-are-deduplicated-limited-and-idempotently-refreshed
  (with-index
    (fn [index]
      (let [db (ds/conn-db (seeded-conn))]
        (search/refresh index db)
        (let [found (results index "movies") ids (mapv :uuid found)]
          (is (not (empty? found)))
          (is (= (count ids) (count (set ids))))
          (run! #(is (empty? (search/search (fn [_] false) % index "movies"))) [0 -1])
          (is (empty? (results index " \t\n")))
          (is (= (vec (take 1 found)) (search/search (fn [_] false) 1 index "movies")))
          (is (empty? (search/query-rows index "select id, page, title from missing_table" [])))
          (search/refresh index db)
          (is (= found (results index "movies"))))))))

(deftest persisted-search-ranks-pages-resolves-references-and-refreshes-changes
  (with-index
    (fn [index]
      (let [conn (seeded-conn)]
        (search/refresh index (ds/conn-db conn))
        (let [found (results index "movies")]
          (is (= (Some page-uuid) (some-> (first found) :uuid)))
          (is (= (Some true) (some-> (first found) :is-page))))
        (run! #(is (some? (find-result index % block-uuid))) ["movies" "ovie" "4k"])
        (is (some? (find-result index "电影" cjk-uuid)))
        (is (= (Some "[[Movies]] marathon plan")
               (some-> (find-result index "Movies marathon" ref-block-uuid) :title)))
        (is (some? (find-result index "20260816" journal-uuid)))
        (is (nil? (find-result index "Secret" hidden-uuid)))
        (is (= (results index "movies") (results (search/create (:path index)) "movies")))
        (ds/transact-conn conn (list (ds/Add (ds/Lookup_ref "block/uuid" (ds/Uuid block-uuid))
                                             "block/title" (ds/String "listen to jazz records"))))
        (search/refresh index (ds/conn-db conn))
        (is (nil? (find-result index "4k movies" block-uuid)))
        (is (some? (find-result index "jazz" block-uuid)))
        (ds/transact-conn conn (list (ds/RetractEntity (ds/Lookup_ref "block/uuid" (ds/Uuid block-uuid)))))
        (search/refresh index (ds/conn-db conn))
        (is (nil? (find-result index "jazz" block-uuid)))))))
