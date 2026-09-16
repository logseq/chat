(ns logseq-chat.flashcards-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.flashcards :as cards]
            [logseq-chat.storage-codec :as storage]
            [ocaml.Datascript :as ds]
            [ocaml.Float :as float]))

(def now 1776000000000)

(def day 86400000)

(deftest again-starts-learning-with-the-upstream-fsrs-parameters
  (let [card (cards/repeat now (cards/new-card now) (cards/Again))]
    (is (= (cards/Learning) (:state card)))
    (is (= 1 (:reps card)))
    (is (= 1 (:lapses card)))
    (is (= (+ now 60000) (:due card)))
    (is (<= (float/abs (- 7.2102 (:difficulty card))) 0.000001))
    (is (<= (float/abs (- 0.4072 (:stability card))) 0.000001))))

(deftest easy-starts-review-with-the-upstream-initial-interval
  (let [card (cards/repeat now (cards/new-card now) (cards/Easy))]
    (is (= (cards/Review) (:state card)))
    (is (= 0 (:lapses card)))
    (is (= 15 (:scheduled-days card)))
    (is (= (+ now (* 15 day)) (:due card)))))

(deftest fsrs-state-round-trips-through-the-logseq-property-map
  (let [original (assoc (cards/new-card now)
                        :due (- now day) :stability 4.2 :difficulty 5.1
                        :elapsed-days 2 :scheduled-days 2 :reps 7 :lapses 1
                        :state (cards/Review) :last-repeat (- now (* 2 day)) :last-rating (Some (cards/Good)))
        decoded (cards/card-of-values (- now (* 10 day)) (Some (:due original))
                                      (Some (cards/state-value original)))
        repeated (cards/repeat now decoded (cards/Good))]
    (is (= original decoded))
    (is (= (cards/Review) (:state repeated)))
    (is (= 8 (:reps repeated)))
    (is (> (:due repeated) now))
    (is (= (Some (cards/Good)) (:last-rating repeated)))))

(deftest review-sequence-matches-the-upstream-fsrs-v5-reference
  (let [started-at 1689432134706
        ratings [(cards/Good) (cards/Good) (cards/Good) (cards/Good) (cards/Good) (cards/Good)
                 (cards/Again) (cards/Again) (cards/Good) (cards/Good) (cards/Good) (cards/Good) (cards/Good)]
        [intervals card _]
        (reduce (fn [[intervals card now] rating]
                  (let [next (cards/repeat now card rating)]
                    (tuple (conj intervals (:scheduled-days next)) next (:due next))))
                (tuple [] (cards/new-card started-at) started-at) ratings)]
    (is (= [0 4 15 48 136 351 0 0 7 13 24 43 77] intervals))
    (is (= 13 (:reps card)))
    (is (= 2 (:lapses card)))
    (is (= (cards/Review) (:state card)))))

(def one (assoc storage/default-schema-attr :indexed true))

(def schema
  (apply list
         (concat
          [(tuple "db/ident" (assoc one :unique (Some (ds/Identity)) :value-type (Some (ds/KeywordType))))
           (tuple "block/uuid" (assoc one :unique (Some (ds/Identity)) :value-type (Some (ds/UuidType))))
           (tuple "logseq.property.fsrs/due" one) (tuple "logseq.property.fsrs/state" one)]
          (map #(tuple % (assoc one :value-type (Some (ds/StringType))))
               ["block/title" "block/name" "block/order"])
          (map #(tuple % (assoc one :value-type (Some (ds/RefType)))) ["block/page" "block/parent"])
          (map #(tuple % (assoc one :value-type (Some (ds/NumberType)))) ["block/created-at" "block/updated-at"])
          (map #(tuple % (assoc one :value-type (Some (ds/RefType)) :cardinality (ds/Many)))
               ["block/tags" "logseq.property.class/extends"]))))

(defn add [eid attr value] (ds/Add (ds/Entity_id eid) attr value))

(defn block-tx [eid uuid title parent order created-at]
  [(add eid "block/uuid" (ds/Uuid uuid)) (add eid "block/title" (ds/String title))
   (add eid "block/page" (ds/Ref 10)) (add eid "block/parent" (ds/Ref parent))
   (add eid "block/order" (ds/String order)) (add eid "block/created-at" (ds/Int created-at))
   (add eid "block/updated-at" (ds/Int created-at))])

(defn ordered-uuids [db] (mapv #(-> % :block :uuid) (cards/due-cards db now)))

(deftest due-cards-include-subclasses-answers-and-stable-due-ordering
  (let [future-state (cards/state-value (assoc (cards/new-card (- now day)) :due (+ now day)))
        tx (concat
            [(add 1 "db/ident" (ds/Keyword "logseq.class/Card"))
             (add 2 "db/ident" (ds/Keyword "user.class/LanguageCard"))
             (add 2 "logseq.property.class/extends" (ds/Ref 1))
             (add 10 "block/uuid" (ds/Uuid "page")) (add 10 "block/title" (ds/String "Page"))
             (add 10 "block/name" (ds/String "page"))]
            (block-tx 11 "new-card" "New card" 10 "a0" (- now day))
            (block-tx 12 "due-subclass" "Due subclass card" 10 "a1" (- now day))
            (block-tx 13 "future-card" "Future card" 10 "a2" (- now day))
            (block-tx 14 "card-answer" "The answer" 11 "a1" now)
            [(add 11 "block/tags" (ds/Ref 1)) (add 12 "block/tags" (ds/Ref 2))
             (add 12 "logseq.property.fsrs/due" (ds/Instant now))
             (add 13 "block/tags" (ds/Ref 1))
             (add 13 "logseq.property.fsrs/due" (ds/Instant (+ now day)))
             (add 13 "logseq.property.fsrs/state" future-state)])
        db (ds/db-with (apply list tx) (ds/empty-db :schema schema))
        due (cards/due-cards db now)
        uuids (set (map #(-> % :block :uuid) due))]
    (is (contains? uuids "new-card"))
    (is (contains? uuids "due-subclass"))
    (is (not (contains? uuids "future-card")))
    (is (= 2 (count due)))
    (is (= (Some ["The answer"])
           (some #(when (= "new-card" (-> % :block :uuid)) (mapv :title (:children %))) due)))
    (let [tied (ds/db-with
                (list (add 11 "logseq.property.fsrs/due" (ds/Instant now))
                      (add 11 "logseq.property.fsrs/state" future-state)
                      (add 12 "logseq.property.fsrs/state" future-state)) db)
          earlier (ds/db-with (list (add 11 "logseq.property.fsrs/due" (ds/Instant (dec now)))) tied)]
      (is (= ["due-subclass" "new-card"] (ordered-uuids tied)))
      (is (= ["new-card" "due-subclass"] (ordered-uuids earlier))))))
