(ns logseq-chat.flashcards
  (:refer-clojure :exclude [repeat descendants])
  (:require [ocaml.package/datascript-ocaml-native]
            [ocaml.package/ocaml-fsrs]
            [logseq-chat.datascript-value :as ds-value]
            [ocaml.Datascript :as ds]
            [ocaml.Float :as float]
            [ocaml.Fsrs :as fsrs]
            [ocaml.List :as list]
            [logseq-chat.graph-read :as graph-read]
            [logseq-chat.cache-model :as model]
            [ocaml.Models :as models]
            [ocaml.Parameters :as parameters]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.Seq :as seq]
            [ocaml.Stdlib :as stdlib]))

(type-variant flashcard-rating
  Again
  Hard
  Good
  Easy)

(type-variant flashcard-state
  New
  Learning
  Review
  Relearning)

(type-record fsrs-card
  (due :int)
  (stability :float)
  (difficulty :float)
  (elapsed-days :int)
  (scheduled-days :int)
  (reps :int)
  (lapses :int)
  (state :flashcard-state)
  (last-repeat :int)
  (last-rating :option<flashcard-rating>))

(type-record due-card
  (block :model/block)
  (children :list<model/block>)
  (card :fsrs-card))

(defn rating-keyword [rating]
  (match rating
    Again :again
    Hard :hard
    Good :good
    Easy :easy))

(defn rating-name [rating]
  (name (rating-keyword rating)))

(defn rating-of-keyword [value]
  (case value
    :again (Some Again)
    :hard (Some Hard)
    :good (Some Good)
    :easy (Some Easy)
    None))

(defn state-keyword [state]
  (match state
    New :new
    Learning :learning
    Review :review
    Relearning :relearning))

(defn state-name [state]
  (name (state-keyword state)))

(defn state-of-keyword [value]
  (case value
    :new (Some New)
    :learning (Some Learning)
    :review (Some Review)
    :relearning (Some Relearning)
    None))

(defn new-card [now]
  (record fsrs-card
    (due now)
    (stability 0.0)
    (difficulty 0.0)
    (elapsed-days 0)
    (scheduled-days 0)
    (reps 0)
    (lapses 0)
    (state New)
    (last-repeat now)
    (last-rating None)))

(defn timestamp [milliseconds]
  (Timedesc.Timestamp.of_float_s (/ (stdlib/float_of_int milliseconds) 1000.0)))

(defn milliseconds [value]
  (stdlib/int_of_float (float/round (* (Timedesc.Timestamp.to_float_s value) 1000.0))))

(defn upstream-state [state]
  (match state
    New (models/New)
    Learning (models/Learning)
    Review (models/Review)
    Relearning (models/Relearning)))

(defn upstream-rating [rating]
  (match rating
    Again (models/Again)
    Hard (models/Hard)
    Good (models/Good)
    Easy (models/Easy)))

(defn state-of-upstream [state]
  (match state
    (models/New) New
    (models/Learning) Learning
    (models/Review) Review
    (models/Relearning) Relearning))

(def scheduler (fsrs/create (parameters/default)))

(defn upstream-card [card]
  (record Models.card
    (due (timestamp (:due card)))
    (stability (:stability card))
    (difficulty (:difficulty card))
    (elapsed-days (:elapsed-days card))
    (scheduled-days (:scheduled-days card))
    (reps (:reps card))
    (lapses (:lapses card))
    (state (upstream-state (:state card)))
    (last-review (timestamp (:last-repeat card)))))

(defn repeat [now card rating]
  (let [scheduled (fsrs/next scheduler (upstream-card card) (timestamp now) (upstream-rating rating))
        next (:card scheduled)]
    (record fsrs-card
      (due (milliseconds (:due next)))
      (stability (:stability next))
      (difficulty (:difficulty next))
      (elapsed-days (:elapsed-days next))
      (scheduled-days (:scheduled-days next))
      (reps (:reps next))
      (lapses (+ (:lapses card) (if (= rating Again) 1 0)))
      (state (state-of-upstream (:state next)))
      (last-repeat (milliseconds (:last-review next)))
      (last-rating (Some rating)))))

(defn state-value [card]
  (let [entries [(tuple (ds/Keyword "stability") (ds/Float (:stability card)))
                 (tuple (ds/Keyword "difficulty") (ds/Float (:difficulty card)))
                 (tuple (ds/Keyword "elapsed-days") (ds/Int (:elapsed-days card)))
                 (tuple (ds/Keyword "scheduled-days") (ds/Int (:scheduled-days card)))
                 (tuple (ds/Keyword "reps") (ds/Int (:reps card)))
                 (tuple (ds/Keyword "lapses") (ds/Int (:lapses card)))
                 (tuple (ds/Keyword "state") (ds/Keyword (state-name (:state card))))
                 (tuple (ds/Keyword "last-repeat") (ds/Int (:last-repeat card)))]
        entries (match (:last-rating card)
                  None entries
                  (Some rating)
                  (conj entries
                        (tuple (ds/Keyword "logseq/last-rating")
                               (ds/Keyword (rating-name rating)))))]
    (ds/Map (rrbvec/to-list entries))))

(defn map-value [key ^:list<tuple<Datascript.value;Datascript.value>> entries]
  (some (fn [entry]
          (when (= (first entry) (ds/Keyword key)) (second entry)))
        entries))

(defn float-value [value]
  (match value
    (Some (ds/Float value)) (Some value)
    (Some (ds/Int value)) (Some (Stdlib/float-of-int value))
    _ None))

(defn int-value [value]
  (match value
    (Some (ds/Int value)) (Some value)
    (Some (ds/Instant value)) (Some value)
    _ None))

(defn keyword-value [value]
  (match value
    (Some (ds/Keyword value)) (Some (keyword value))
    _ None))

(defn decoded-card [due entries]
  (match (tuple
          (float-value (map-value "stability" entries))
          (float-value (map-value "difficulty" entries))
          (int-value (map-value "elapsed-days" entries))
          (int-value (map-value "scheduled-days" entries))
          (int-value (map-value "reps" entries))
          (int-value (map-value "lapses" entries))
          (some-> (keyword-value (map-value "state" entries)) state-of-keyword)
          (int-value (map-value "last-repeat" entries)))
    (tuple
     (Some stability)
     (Some difficulty)
     (Some elapsed-days)
     (Some scheduled-days)
     (Some reps)
     (Some lapses)
     (Some state)
     (Some last-repeat))
    (Some
     (record fsrs-card
       (due due)
       (stability stability)
       (difficulty difficulty)
       (elapsed-days elapsed-days)
       (scheduled-days scheduled-days)
       (reps reps)
       (lapses lapses)
       (state state)
       (last-repeat last-repeat)
       (last-rating
        (some-> (keyword-value (map-value "logseq/last-rating" entries))
                rating-of-keyword))))
    _ None))

(defn card-of-values [created-at due state]
  (match (tuple due state)
    (tuple (Some due) (Some (ds/Map entries)))
    (match (decoded-card due entries)
      (Some card) card
      None (new-card created-at))
    _ (new-card created-at)))

(defn decrypt-title [value]
  (Ok value))

(defn contains-class-eid? [class-eids tag-eids]
  (some
   (fn [class-eid] (contains? class-eids class-eid))
   tag-eids))

(defn card-eid [db eid]
  (match (ds/entid db "db/ident" (ds/Keyword "logseq.class/Card"))
    None false
    (Some card-class-eid)
    (let [classes (graph-read/class-descendants db card-class-eid)]
      (boolean (contains-class-eid? classes (graph-read/ref-eids db eid "block/tags"))))))

(defn ^:list<model/block> descendants [^:list<model/block> page-blocks parent-uuid]
  (list/of-seq
   (mapcat
    (fn [child]
      (list* child (descendants page-blocks (:uuid child))))
    (filter
     (fn [candidate]
       (= (:parent-id candidate) (Some parent-uuid)))
     page-blocks))))

(defn page-blocks-for-page [page-blocks-cache db page-uuid]
  (match (get @page-blocks-cache page-uuid)
    (Some blocks) blocks
    None
    (let [blocks (rrbvec/to-list (graph-read/blocks-for-page decrypt-title db page-uuid))]
      (swap! page-blocks-cache assoc page-uuid blocks)
      blocks)))

(defn card-for-eid [page-blocks-cache db now uuid eid]
  (if (card-eid db eid)
    (match (graph-read/block decrypt-title db eid)
      (Some block)
      (let [page-blocks (page-blocks-for-page page-blocks-cache db (:page-id block))
            created-at (if (> (:created-at block) 0) (:created-at block) now)
            due (graph-read/int-value
                 (graph-read/value db eid "logseq.property.fsrs/due"))
            card (card-of-values
                  created-at
                  due
                  (graph-read/value db eid "logseq.property.fsrs/state"))]
        (Some
         (record due-card
           (block block)
           (children (descendants page-blocks uuid))
           (card card))))
      None None)
    None))

(defn card-for-uuid [db now uuid]
  (match (ds/entid db "block/uuid" (ds/Uuid uuid))
    (Some eid)
    (card-for-eid (atom {}) db now uuid eid)
    None None))

(defn int-compare [left right]
  (if (< left right)
    -1
    (if (> left right) 1 0)))

(defn due-card-for-eid [page-blocks-cache db now eid]
  (match (graph-read/uuid-for-eid db eid)
    None None
    (Some uuid)
    (match (card-for-eid page-blocks-cache db now uuid eid)
      None None
      (Some due-card)
      (if (> (:due (:card due-card)) now)
        None
        (Some due-card)))))

(defn due-cards [db now]
  (match (ds/entid db "db/ident" (ds/Keyword "logseq.class/Card"))
    None (list)
    (Some card-class-eid)
    (let [page-blocks-cache (atom {})
          class-eids (graph-read/class-descendants db card-class-eid)
          tagged-datoms (mapcat
                         (fn [class-eid]
                           (ds-value/datoms-by-ref db (ds/Aevt) "block/tags" class-eid))
                         class-eids)
          tagged-eids (map (fn [datom] (:e datom)) tagged-datoms)
          unique-eids (list/sort_uniq int-compare (list/of_seq tagged-eids))
          due (list/of-seq
               (keep
                (fn [eid] (due-card-for-eid page-blocks-cache db now eid))
                unique-eids))]
      (sort-by (fn [due-card]
                 (tuple (:due (:card due-card)) (:uuid (:block due-card))))
               due))))
