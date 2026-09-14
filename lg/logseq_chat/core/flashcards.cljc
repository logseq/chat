(ns logseq-chat.flashcards
  (:require [ocaml.package/datascript-ocaml-native]
            [ocaml.Datascript :as ds]
            [ocaml.Rrbvec :as rrbvec]))

(defn rating-keyword [rating]
  (match rating
    Again "again"
    Hard "hard"
    Good "good"
    Easy "easy"))

(defn rating-of-keyword [value]
  (if (= value "again")
    (Some Again)
    (if (= value "hard")
      (Some Hard)
      (if (= value "good")
        (Some Good)
        (if (= value "easy")
          (Some Easy)
          None)))))

(defn state-keyword [state]
  (match state
    New "new"
    Learning "learning"
    Review "review"
    Relearning "relearning"))

(defn state-of-keyword [value]
  (if (= value "new")
    (Some New)
    (if (= value "learning")
      (Some Learning)
      (if (= value "review")
        (Some Review)
        (if (= value "relearning")
          (Some Relearning)
          None)))))

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
                 (tuple (ds/Keyword "state") (ds/Keyword (state-keyword (:state card))))
                 (tuple (ds/Keyword "last-repeat") (ds/Int (:last-repeat card)))]
        entries (match (:last-rating card)
                  None entries
                  (Some rating)
                  (conj entries
                        (tuple (ds/Keyword "logseq/last-rating")
                               (ds/Keyword (rating-keyword rating)))))]
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
    (Some (ds/Keyword value)) (Some value)
    _ None))

(defn card-of-values [created-at due state]
  (match due
    (Some due)
    (match state
      (Some (ds/Map entries))
      (match (float-value (map-value "stability" entries))
        (Some stability)
        (match (float-value (map-value "difficulty" entries))
          (Some difficulty)
          (match (int-value (map-value "elapsed-days" entries))
            (Some elapsed-days)
            (match (int-value (map-value "scheduled-days" entries))
              (Some scheduled-days)
              (match (int-value (map-value "reps" entries))
                (Some reps)
                (match (int-value (map-value "lapses" entries))
                  (Some lapses)
                  (match (keyword-value (map-value "state" entries))
                    (Some state-keyword)
                    (match (state-of-keyword state-keyword)
                      (Some state)
                      (match (int-value (map-value "last-repeat" entries))
                        (Some last-repeat)
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
                           (match (keyword-value
                                   (map-value "logseq/last-rating" entries))
                             (Some rating-keyword)
                             (rating-of-keyword rating-keyword)
                             None None)))
                        _ (new-card created-at))
                      None (new-card created-at))
                    None (new-card created-at))
                  None (new-card created-at))
                None (new-card created-at))
              None (new-card created-at))
            None (new-card created-at))
          None (new-card created-at))
        None (new-card created-at))
      _ (new-card created-at))
    None (new-card created-at)))
