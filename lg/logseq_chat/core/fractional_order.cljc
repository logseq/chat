(ns logseq-chat.fractional-order
  (:require [clojure.string :as string]))

(def digits "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

(def zero "0")

(def lowercase "abcdefghijklmnopqrstuvwxyz")

(def uppercase "ABCDEFGHIJKLMNOPQRSTUVWXYZ")

(type-record digit-run
  (digit-run-value :string)
  (digit-run-carried :bool))

(defn char-at [value index]
  (subs value index (inc index)))

(defn suffix [value offset]
  (if (>= offset (count value))
    ""
    (subs value offset)))

(defn repeat-string [value times]
  (loop [index 0
         result ""]
    (if (= index times)
      result
      (recur (inc index) (str result value)))))

(def minimum "A00000000000000000000000000")

(defn index-of-in [values target]
  (loop [index 0]
    (cond
      (= index (count values)) nil
      (= (char-at values index) target) (Some index)
      :else (recur (inc index)))))

(defn index-of [character]
  (index-of-in digits character))

(defn digit-at [index]
  (char-at digits index))

(defn adjacent-head [head offset]
  (when-some [index (index-of head)]
    (let [next (+ index offset)]
      (when (and (>= next 0) (< next (count digits)))
        (digit-at next)))))

(defn integer-length [head]
  (match (index-of-in lowercase head)
    (Some index)
    (Ok (+ index 2))
    None
    (match (index-of-in uppercase head)
      (Some index)
      (Ok (+ (- (dec (count uppercase)) index) 2))
      None (Error "invalid order key head"))))

(defn integer-part [key]
  (if (= key "")
    (Error "empty order key")
    (let* [length (integer-length (char-at key 0))]
      (if (< (count key) length)
        (Error "invalid integer part of order key")
        (Ok (subs key 0 length))))))

(defn validate-integer-error [value]
  (match (integer-part value)
    (Ok integer)
    (when-not (and (= (count integer) (count value))
                   (every? #(some? (index-of (char-at integer %)))
                           (range 1 (count integer))))
      "invalid integer part of order key")
    (Error message) (Some message)))

(defn validate-error [key]
  (match (integer-part key)
    (Ok integer)
    (let [fraction (suffix key (count integer))]
      (if (or (= key minimum)
              (and (not= fraction "")
                   (= (char-at fraction (dec (count fraction))) zero)))
        (Some "invalid order key")
        None))
    (Error message) (Some message)))

(defn set-char [value index character]
  (str (subs value 0 index) character (suffix value (inc index))))

(defn digit-run [value carried]
  (record digit-run
          (digit-run-value value)
          (digit-run-carried carried)))

(defn increment-digit-run [value index]
  (if (= index 0)
    (digit-run value true)
    (match (index-of (char-at value index))
      (Some digit)
      (if (= (inc digit) (count digits))
        (increment-digit-run (set-char value index zero) (dec index))
        (digit-run (set-char value index (digit-at (inc digit))) false))
      None (digit-run value true))))

(defn increment [value]
  (if-some [message (validate-integer-error value)]
    (Error message)
    (let [run (increment-digit-run value (dec (count value)))
          head (char-at value 0)]
      (cond
        (not (:digit-run-carried run)) (Ok (Some (:digit-run-value run)))
        (= head "Z") (Ok (Some "a0"))
        (= head "z") (Ok nil)
        :else
        (if-some [next-head (adjacent-head head 1)]
          (let [tail (suffix (:digit-run-value run) 1)
                new-tail (if (nil? (index-of-in lowercase next-head))
                           (subs tail 0 (dec (count tail)))
                           (str tail zero))]
            (Ok (Some (str next-head new-tail))))
          (Error "invalid order key head"))))))

(defn decrement-digit-run [value index]
  (if (= index 0)
    (digit-run value true)
    (match (index-of (char-at value index))
      (Some digit)
      (if (= digit 0)
        (decrement-digit-run
         (set-char value index (digit-at (dec (count digits)))) (dec index))
        (digit-run (set-char value index (digit-at (dec digit))) false))
      None (digit-run value true))))

(defn decrement [value]
  (if-some [message (validate-integer-error value)]
    (Error message)
    (let [run (decrement-digit-run value (dec (count value)))
          head (char-at value 0)]
      (cond
        (not (:digit-run-carried run)) (Ok (Some (:digit-run-value run)))
        (= head "a") (Ok (Some "Zz"))
        (= head "A") (Ok nil)
        :else
        (if-some [next-head (adjacent-head head -1)]
          (let [tail (suffix (:digit-run-value run) 1)
                new-tail (if (nil? (index-of-in uppercase next-head))
                           (subs tail 0 (dec (count tail)))
                           (str tail (digit-at (dec (count digits)))))]
            (Ok (Some (str next-head new-tail))))
          (Error "invalid order key head"))))))

(defn invalid-lower-upper? [lower upper]
  (if-some [upper upper] (not (neg? (String.compare lower upper))) false))

(defn trailing-zero? [value]
  (and (not= value "")
       (= (char-at value (dec (count value))) zero)))

(defn midpoint-shared-prefix [lower upper]
  (loop [index 0]
    (if (= index (count upper))
      index
      (let [lower-character
            (if (< index (count lower)) (char-at lower index) zero)]
        (if (= lower-character (char-at upper index))
          (recur (inc index))
          index)))))

(defn string-less? [lower upper]
  (neg? (String.compare lower upper)))

(defn midpoint [lower upper]
  (cond
    (invalid-lower-upper? lower upper) (Error "invalid midpoint bounds")
    (or (trailing-zero? lower) (boolean (some-> upper trailing-zero?)))
    (Error "midpoint has trailing zero")
    :else
    (let [shared (if-some [upper upper] (midpoint-shared-prefix lower upper) 0)]
      (if (pos? shared)
        (if-some [upper upper]
          (let* [rest (midpoint (suffix lower shared) (Some (suffix upper shared)))]
            (Ok (str (subs upper 0 shared) rest)))
          (Error "invalid midpoint bounds"))
        (match (tuple (if (= lower "") (Some 0) (index-of (char-at lower 0)))
                      (if-some [upper upper] (index-of (char-at upper 0)) (Some (count digits))))
          (tuple (Some lower-digit) (Some upper-digit))
          (cond
            (> (- upper-digit lower-digit) 1)
            (Ok (digit-at (quot (inc (+ lower-digit upper-digit)) 2)))

            (> (or (some-> upper count) 0) 1)
            (Ok (subs (or upper "") 0 1))

            :else
            (let* [rest (midpoint (suffix lower 1) None)]
              (Ok (str (digit-at lower-digit) rest))))
          _ (Error "invalid fractional digit"))))))

(defn validate-optional-error [value]
  (some-> value validate-error))

(defn optional-lower-fails? [lower value]
  (match lower
    (Some lower-value) (not (string-less? lower-value value))
    None false))

(defn optional-upper-fails? [value upper]
  (match upper
    (Some upper-value) (not (string-less? value upper-value))
    None false))

(defn optional-string-or-error [value fallback]
  (let* [value value]
    (if-some [value value] (Ok value) (Error fallback))))

(defn optional-string-or-midpoint
  [value integer fraction]
  (let* [value value]
    (if-some [value value]
      (Ok value)
      (let* [middle (midpoint fraction nil)]
        (Ok (str integer middle))))))

(defn prepend-string-result [prefix result]
  (let* [value result] (Ok (str prefix value))))

(defn before-upper-or-midpoint
  [value
   upper-value
   lower-integer
   lower-fraction]
  (let* [value value]
    (if-some [value (when-some [value value] (when (string-less? value upper-value) value))]
      (Ok value)
      (prepend-string-result lower-integer (midpoint lower-fraction nil)))))

(defn between-before-upper [upper-value integer]
  (let [fraction (suffix upper-value (count integer))]
    (if (or (= integer minimum) (string-less? integer upper-value))
      (prepend-string-result integer (midpoint "" (Some fraction)))
      (optional-string-or-error (decrement integer) "cannot decrement order key"))))

(defn between-after-lower [lower-value integer]
  (let [fraction (suffix lower-value (count integer))]
    (optional-string-or-midpoint (increment integer) integer fraction)))

(defn between-shared-integers
  [lower-integer lower-fraction upper-fraction]
  (prepend-string-result lower-integer (midpoint lower-fraction (Some upper-fraction))))

(defn between-different-integers
  [upper-value lower-integer lower-fraction]
  (before-upper-or-midpoint
   (increment lower-integer) upper-value lower-integer lower-fraction))

(defn between-core [lower upper]
  (match (tuple lower upper)
    (tuple None None) (Ok "a0")
    (tuple None (Some upper))
    (let* [integer (integer-part upper)]
      (between-before-upper upper integer))
    (tuple (Some lower) None)
    (let* [integer (integer-part lower)]
      (between-after-lower lower integer))
    (tuple (Some lower) (Some upper))
    (let* [lower-integer (integer-part lower)
           upper-integer (integer-part upper)]
      (let [lower-fraction (suffix lower (count lower-integer))
            upper-fraction (suffix upper (count upper-integer))]
        (if (= lower-integer upper-integer)
          (between-shared-integers lower-integer lower-fraction upper-fraction)
          (between-different-integers upper lower-integer lower-fraction))))))

(defn between [lower upper]
  (if-some [message (or (validate-optional-error lower) (validate-optional-error upper))]
    (Error message)
    (if (boolean (some-> lower (invalid-lower-upper? upper)))
      (Error "invalid order bounds")
      (let* [value (between-core lower upper)]
        (if (or (optional-lower-fails? lower value)
                (optional-upper-fails? value upper))
          (Error "generate-key-between failed")
          (Ok value))))))

(defn n-after [lower count]
  (loop [lower lower remaining count result []]
    (if (= remaining 0)
      (Ok result)
      (let* [value (between lower nil)]
        (recur (Some value) (dec remaining) (conj result value))))))

(defn n-before [upper count]
  (loop [upper upper remaining count result []]
    (if (= remaining 0)
      (Ok result)
      (let* [value (between nil upper)]
        (recur (Some value) (dec remaining) (into [value] result))))))

(defn ^:result<vector<string>;string> n-between [lower upper count]
  (cond
    (neg? count) (Error "order key count must not be negative")
    (zero? count) (Ok [])
    (= count 1) (let* [value (between lower upper)] (Ok [value]))
    (nil? upper) (n-after lower count)
    (nil? lower) (n-before upper count)
    :else
    (let [left-count (quot count 2)]
      (let* [middle (between lower upper)
             left (n-between lower (Some middle) left-count)
             right (n-between (Some middle) upper (- count left-count 1))]
        (Ok (into (conj left middle) right))))))
