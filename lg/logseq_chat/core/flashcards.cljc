(ns logseq-chat.flashcards
  (:require [ocaml.package/datascript-ocaml-native]
            [ocaml.Datascript :as ds]
            [ocaml.Rrbvec :as rrbvec]))

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

(defn map-value [key entries]
  (let [entries (rrbvec/of-list entries)
        wanted (ds/Keyword key)
        total (count entries)]
    (loop [index 0]
      (if (= index total)
        None
        (let [entry (nth entries index)]
          (if (= (Stdlib/fst entry) wanted)
            (Some (Stdlib/snd entry))
            (recur (inc index))))))))

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
