(ns logseq-chat.e2e-seed-data
  (:require [logseq-chat.cache-model :as model]
            [logseq-chat.journal :as journal]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.String :as bytes]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Printexc :as exception]))

(def tag-uuid "e2e00000-0000-4000-8000-000000000001")

(def source-uuid "e2e00000-0000-4000-8000-000000000002")

(def older-block-uuid "e2e00000-0000-4000-8000-000000000003")

(def trailing-tag-uuid "e2e00000-0000-4000-8000-000000000004")

(def child-tag-uuid "e2e00000-0000-4000-8000-000000000005")

(def flashcard-uuid "e2e00000-0000-4000-8000-000000000020")

(def flashcard-answer-uuid "e2e00000-0000-4000-8000-000000000021")

(def header-navigation-page-uuid "e2e00000-0000-4000-8000-000000000030")

(def header-navigation-block-uuid "e2e00000-0000-4000-8000-000000000031")

(def composer-page-uuid "e2e30000-0000-4000-8000-000000000001")

(def composer-block-uuid "e2e30000-0000-4000-8000-000000000002")

(def outliner-page-uuid "e2e30000-0000-4000-8000-000000000003")

(def outliner-block-uuid "e2e30000-0000-4000-8000-000000000004")

(def outliner-tag-uuid "e2e30000-0000-4000-8000-000000000005")

(defn entity-has-attr? [db eid attr]
  (not (empty? (db-api/datoms db (ds/Eavt) :e eid :a attr))))

(defn entity-built-in? [db eid]
  (some #(= (:v %) (ds/Bool true))
        (db-api/datoms db (ds/Eavt) :e eid :a "logseq.property/built-in?")))

(defn transact! [conn operations]
  (ds/transact-conn conn (apply list operations))
  (stdlib/ignore 0))

(defn reset-user-page-entities [conn]
  (let [db (ds/conn-db conn)
        operations (vec (keep (fn [datom]
                                (when (and (or (entity-has-attr? db (:e datom) "block/journal-day")
                                               (entity-has-attr? db (:e datom) "block/page"))
                                           (not (entity-built-in? db (:e datom))))
                                  (ds/RetractEntity (ds/Entity_id (:e datom)))))
                              (db-api/datoms db (ds/Aevt) :a "block/uuid")))]
    (when (seq operations) (transact! conn operations))))

(defn uuid-attr [value] (ds/One_value (ds/Uuid value)))

(defn string-attr [value] (ds/One_value (ds/String value)))

(defn int-attr [value] (ds/One_value (ds/Int value)))

(defn ref-attr [id] (ds/One_value (ds/Ref_to (ds/Temp_id id))))

(defn many-refs [ids] (ds/Many_values (apply list (map #(ds/Ref_to (ds/Temp_id %)) ids))))

(defn entity [id attrs]
  (ds/Entity (record Datascript.tx_entity
                     (db-id (some-> id ds/Temp_id)) (attrs (apply list attrs)))))

(defn page-attrs [uuid name title day now]
  {"block/uuid" (uuid-attr uuid) "block/name" (string-attr name) "block/title" (string-attr title)
   "block/journal-day" (int-attr day) "block/created-at" (int-attr now) "block/updated-at" (int-attr now)})

(defn block-attrs [uuid title parent order now]
  {"block/uuid" (uuid-attr uuid) "block/title" (string-attr title)
   "block/page" (ref-attr parent) "block/parent" (ref-attr parent) "block/order" (string-attr order)
   "block/created-at" (int-attr now) "block/updated-at" (int-attr now)})

(defn seed-current-journal [conn now page-uuid block-uuid title]
  (let [day (model/journal-day-for-ms now)
        page-title (journal/day-title day)]
    (transact! conn
               [(entity (Some "e2e-current-page")
                        (page-attrs page-uuid (bytes/lowercase-ascii page-title) page-title day now))
                (entity None (block-attrs block-uuid title "e2e-current-page" "a0" now))])))

(defn attempt [label f]
  (try (f) (Ok (stdlib/ignore 0))
       (catch error (Error (str label (exception/to-string error))))))

(defn seed-composer [conn now]
  (attempt "Seed iOS composer graph: "
           (fn [] (reset-user-page-entities conn)
               (seed-current-journal conn now composer-page-uuid composer-block-uuid "E2E Composer Fixture"))))

(defn page-uuid [index] (format "e2e10000-0000-4000-8000-%012d" index))

(defn block-uuid [index] (format "e2e20000-0000-4000-8000-%012d" index))

(defn seed-header-navigation [conn]
  (attempt "Seed iOS header-navigation graph: "
           (fn []
             (transact! conn
                        [(entity (Some "e2e-header-navigation-page")
                                 (page-attrs header-navigation-page-uuid "aug 24th, 2026" "Aug 24th, 2026" 20260824 50000))
                         (entity None (block-attrs header-navigation-block-uuid "E2E Header Navigation"
                                                   "e2e-header-navigation-page" "a0" 50001))]))))

(def journal-entities
  (vec (mapcat
         (fn [number]
           (let [parent (str "e2e-journal-" number)
                 page-title (if (= number 7) "E2E Page Target" (format "E2E Journal %02d" number))
                 title (case number 7 "E2E Block Target" 1 "E2E Earlier Journal Block"
                             6 "E2E Child Tag Object" (format "E2E Journal Block %02d" number))
                 attrs (block-attrs (if (= number 1) older-block-uuid (block-uuid number)) title parent "a0" (+ 20000 number))]
             [(entity (Some parent)
                      (assoc (page-attrs (page-uuid number) parent page-title (+ 20260809 number) (+ 10000 number))
                             "block/updated-at" (int-attr (if (= number 8) 2000000000001 (+ 10000 number)))))
              (entity (Some (str "e2e-block-" number))
                      (if (= number 6) (assoc attrs "block/tags" (many-refs ["e2e-child-tag"])) attrs))]))
         (range 1 9))))

(def rich-block-titles
  ["> E2E Rich Quote" "$$E = mc^2$$" "```swift\nlet answer = 42\n```"
   "{{video https://www.youtube.com/watch?v=dQw4w9WgXcQ}}" "{{iframe https://example.com}}"
   "E2E before {{video https://www.youtube.com/watch?v=dQw4w9WgXcQ}} E2E after"
   "{{youtube-timestamp 01:23}}"])

(def rich-block-entities
  (vec (map-indexed
         (fn [index title]
           (entity (Some (str "e2e-rich-block-" index))
                   (block-attrs (block-uuid (+ 100 index)) title "e2e-journal-8"
                                (format "a%d" (+ index 2)) (+ 30000 index))))
         rich-block-titles)))

(defn tag-attrs [uuid name title]
  {"block/uuid" (uuid-attr uuid) "block/name" (string-attr name) "block/title" (string-attr title)
   "block/tags" (many-refs ["e2e-tag-class"])})

(defn seed [conn]
  (attempt "Seed iOS E2E graph: "
    (fn []
      (let [existing (first (db-api/datoms (ds/conn-db conn) (ds/Aevt) :a "block/name" :v (ds/String "$$$favorites")))
            favorites (if (some? existing) []
                          [(entity (Some "e2e-favorites-page")
                                   {"block/uuid" (uuid-attr "e2e00000-0000-4000-8000-000000000010")
                                    "block/name" (string-attr "$$$favorites") "block/title" (string-attr "Favorites")})])
            favorite-ref (match existing (Some datom) (ds/One_value (ds/Ref (:e datom)))
                                None (ref-attr "e2e-favorites-page"))
            title (format "E2E links [[%s]] [[%s]] #[[%s]] and ((plain text))" (page-uuid 7) (block-uuid 7) tag-uuid)]
        (transact! conn
          (concat journal-entities rich-block-entities favorites
            [(entity (Some "e2e-favorite-page-target")
                     {"block/uuid" (uuid-attr "e2e00000-0000-4000-8000-000000000011")
                      "block/title" (string-attr "") "block/page" favorite-ref
                      "block/link" (ref-attr "e2e-journal-7") "block/order" (string-attr "a0")})
             (entity (Some "e2e-tag-class") {"db/ident" (ds/One_value (ds/Keyword "logseq.class/Tag"))})
             (entity (Some "e2e-tag") (tag-attrs tag-uuid "e2e-project" "E2E Project"))
             (entity (Some "e2e-trailing-tag") (tag-attrs trailing-tag-uuid "e2e-trailing" "E2E Trailing"))
             (entity (Some "e2e-child-tag")
                     (assoc (tag-attrs child-tag-uuid "e2e-child-project" "E2E Child Project")
                            "logseq.property.class/extends" (many-refs ["e2e-tag"])))
             (entity None (assoc (block-attrs source-uuid title "e2e-journal-8" "a1" 2000000000000)
                                 "block/refs" (many-refs ["e2e-journal-7" "e2e-block-7"])
                                 "block/tags" (many-refs ["e2e-tag" "e2e-trailing-tag"])))
             (entity None (assoc (block-attrs "e2e00000-0000-4000-8000-000000000006"
                                              "E2E explicit tag page reference" "e2e-journal-8" "a8" 2000000000002)
                                 "block/refs" (many-refs ["e2e-tag"])))
             (entity (Some "e2e-card-class") {"db/ident" (ds/One_value (ds/Keyword "logseq.class/Card"))})
             (entity (Some "e2e-flashcard")
                     (assoc (block-attrs flashcard-uuid "The capital of France is {{cloze Paris}}" "e2e-journal-8" "a9" 40000)
                            "block/tags" (many-refs ["e2e-card-class"])))
             (entity None (assoc (block-attrs flashcard-answer-uuid "Paris is the answer" "e2e-journal-8" "a0" 40001)
                                 "block/parent" (ref-attr "e2e-flashcard")))]))))))

(defn seed-outliner [conn now]
  (attempt "Seed iOS outliner graph: "
           (fn []
             (reset-user-page-entities conn)
             (seed-current-journal conn now outliner-page-uuid outliner-block-uuid "E2E Outliner Fixture")
             (transact! conn
                        [(entity (Some "e2e-outliner-tag-class") {"db/ident" (ds/One_value (ds/Keyword "logseq.class/Tag"))})
                         (entity None {"block/uuid" (uuid-attr outliner-tag-uuid)
                                       "block/name" (string-attr "e2e-outliner-tag")
                                       "block/title" (string-attr "E2E Outliner Tag")
                                       "block/tags" (many-refs ["e2e-outliner-tag-class"])})]))))

(defn seed-fixture [conn]
  (reset-user-page-entities conn)
  (seed conn))

(defn performance-page-uuid [index] (format "e2f10000-0000-4000-8000-%012x" (inc index)))

(defn performance-block-uuid [page-index block-index]
  (format "e2f20000-0000-4000-8000-%012x" (+ (* (inc page-index) 100) block-index 1)))

(defn performance-block-title [page-index block-index]
  (let [row (format "%03d-%02d" (inc page-index) (inc block-index))]
    (case (mod block-index 4)
      0 (format "Performance row %s with **bold text** and `inline code`" row)
      1 (format "> Performance quote %s with enough text to exercise wrapping" row)
      2 (format "$$x_%d + y_%d = z_%d$$" page-index block-index (+ page-index block-index))
      (format "```swift\nlet performanceRow = \"%s\"\n```" row))))

(defn seed-performance [conn now]
  (attempt "Seed iOS performance graph: "
    (fn []
      (reset-user-page-entities conn)
      (transact! conn
        (mapcat
          (fn [page-index]
            (let [parent (str "performance-page-" page-index)
                  time (- now (* page-index 86400000))
                  day (model/journal-day-for-ms time)
                  title (journal/day-title day)]
              (into [(entity (Some parent) (page-attrs (performance-page-uuid page-index)
                                                      (bytes/lowercase-ascii title) title day time))]
                    (map (fn [block-index]
                           (entity None (block-attrs (performance-block-uuid page-index block-index)
                                                     (performance-block-title page-index block-index)
                                                     parent (format "a%02d" block-index) (+ time block-index 1))))
                         (range 8)))))
          (range 100))))))
