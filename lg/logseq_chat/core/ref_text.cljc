(ns logseq-chat.ref-text
  (:require [clojure.string :as string]))

(type-record text-step
  (step-index :int)
  (step-result :string))

(defn char-at [value index]
  (subs value index (inc index)))

(defn hex-character? [value]
  (string/includes? "0123456789abcdefABCDEF" value))

(defn is-uuid? [value]
  (and
   (= (count value) 36)
   (loop [index 0]
     (if (= index 36)
       true
       (let [character (char-at value index)
             hyphen-slot
             (or (= index 8) (= index 13) (= index 18) (= index 23))]
         (if (if hyphen-slot (= character "-") (hex-character? character))
           (recur (inc index))
           false))))))

(defn tag-terminator? [value]
  (or (= value " ")
      (= value (str (char 9)))
      (= value "\n")
      (= value ",")
      (= value ".")
      (= value "(")
      (= value ")")
      (= value "[")
      (= value "]")
      (= value "#")))

(defn plain-tag-label? [label]
  (and
   (not= label "")
   (loop [index 0]
     (if (= index (count label))
       true
       (if (tag-terminator? (char-at label index))
         false
         (recur (inc index)))))))

(defn close-index [title start]
  (let [length (count title)]
    (loop [index start]
      (if (>= (inc index) length)
        None
        (if (and (= (char-at title index) "]")
                 (= (char-at title (inc index)) "]"))
          (Some index)
          (recur (inc index)))))))

(defn slice-through-close [title index close]
  (subs title index (+ close 2)))

(defn text-step [index result]
  (record text-step
          (step-index index)
          (step-result result)))

(defn to-text-step
  [tag-title
   ref-title
   title
   length
   index
   result]
  (if (and (< (+ index 2) length)
           (= (char-at title index) "#")
           (= (char-at title (inc index)) "[")
           (= (char-at title (+ index 2)) "["))
    (match (close-index title (+ index 3))
      (Some close)
      (let [inner (subs title (+ index 3) close)]
        (match (tag-title inner)
          (Some label)
          (text-step
           (+ close 2)
           (str result (if (plain-tag-label? label)
                         (str "#" label)
                         (str "#[[" label "]]"))))
          None
          (text-step (+ close 2)
                     (str result (slice-through-close title index close)))))
      None
      (text-step (inc index) (str result (char-at title index))))
    (if (and (< (inc index) length)
             (= (char-at title index) "[")
             (= (char-at title (inc index)) "["))
      (match (close-index title (+ index 2))
        (Some close)
        (let [inner (subs title (+ index 2) close)]
          (match (ref-title inner)
            (Some label)
            (text-step (+ close 2) (str result "[[" label "]]"))
            None
            (text-step (+ close 2)
                       (str result (slice-through-close title index close)))))
        None
        (text-step (inc index) (str result (char-at title index))))
      (text-step (inc index) (str result (char-at title index))))))

(defn to-text
  [tag-title
   ref-title
   title]
  (let [length (count title)]
    (loop [index 0
           result ""]
      (if (>= index length)
        result
        (let [step (to-text-step tag-title ref-title title length index result)]
          (recur (:step-index step) (:step-result step)))))))

(defn hashtag-start? [title index]
  (or (= index 0)
      (let [previous (char-at title (dec index))]
        (or (= previous " ")
            (= previous (str (char 9)))
            (= previous "\n")
            (= previous "(")))))

(defn hashtag-end [title start]
  (let [length (count title)]
    (loop [index start]
      (if (and (< index length)
               (not (tag-terminator? (char-at title index))))
        (recur (inc index))
        index))))

(defn to-ids-step
  [resolve-ref
   resolve-tag
   title
   length
   index
   result]
  (if (and (< (+ index 2) length)
           (= (char-at title index) "#")
           (= (char-at title (inc index)) "[")
           (= (char-at title (+ index 2)) "["))
    (match (close-index title (+ index 3))
      (Some close)
      (let [inner (subs title (+ index 3) close)]
        (match (if (is-uuid? inner) None (resolve-tag inner))
          (Some uuid)
          (text-step (+ close 2) (str result "#[[" uuid "]]"))
          None
          (text-step (+ close 2)
                     (str result (slice-through-close title index close)))))
      None
      (text-step (inc index) (str result (char-at title index))))
    (if (and (< (inc index) length)
             (= (char-at title index) "[")
             (= (char-at title (inc index)) "["))
      (match (close-index title (+ index 2))
        (Some close)
        (let [inner (subs title (+ index 2) close)]
          (match (if (is-uuid? inner) None (resolve-ref inner))
            (Some uuid)
            (text-step (+ close 2) (str result "[[" uuid "]]"))
            None
            (text-step (+ close 2)
                       (str result (slice-through-close title index close)))))
        None
        (text-step (inc index) (str result (char-at title index))))
      (if (and (= (char-at title index) "#")
               (hashtag-start? title index))
        (let [word-end (hashtag-end title (inc index))
              word (subs title (inc index) word-end)]
          (match (if (= word "") None (resolve-tag word))
            (Some uuid)
            (text-step word-end (str result "#[[" uuid "]]"))
            None
            (text-step (inc index) (str result (char-at title index)))))
        (text-step (inc index) (str result (char-at title index)))))))

(defn to-ids
  [resolve-ref
   resolve-tag
   title]
  (let [length (count title)]
    (loop [index 0
           result ""]
      (if (>= index length)
        result
        (let [step (to-ids-step resolve-ref resolve-tag title length index result)]
          (recur (:step-index step) (:step-result step)))))))
