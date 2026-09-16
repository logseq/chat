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
    (if (= index (count values))
      None
      (if (= (char-at values index) target)
        (Some index)
        (recur (inc index))))))

(defn index-of [character]
  (index-of-in digits character))

(defn digit-at [index]
  (char-at digits index))

(defn adjacent-head [head offset]
  (match (index-of head)
    (Some index)
    (let [next (+ index offset)]
      (if (or (< next 0) (>= next (count digits)))
        None
        (Some (digit-at next))))
    None None))

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
    (match (integer-length (char-at key 0))
      (Ok length)
      (if (< (count key) length)
        (Error "invalid integer part of order key")
        (Ok (subs key 0 length)))
      (Error message) (Error message))))

(defn validate-integer-error [value]
  (match (integer-part value)
    (Ok integer)
    (let [digits-are-valid
          (loop [index 1]
            (if (= index (count integer))
              true
              (let [valid-digit (not= (index-of (char-at integer index)) None)]
                (if valid-digit
                  (recur (inc index))
                  false))))]
      (if (and (= (count integer) (count value)) digits-are-valid)
        None
        (Some "invalid integer part of order key")))
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
  (match (validate-integer-error value)
    (Some message) (Error message)
    None
    (let [run (increment-digit-run value (dec (count value)))]
      (if (not (:digit-run-carried run))
        (Ok (Some (:digit-run-value run)))
      (let [head (char-at value 0)]
        (if (= head "Z")
          (Ok (Some "a0"))
          (if (= head "z")
            (Ok None)
            (match (adjacent-head head 1)
              (Some next)
              (let [tail (suffix (:digit-run-value run) 1)
                    new-tail
                    (if (= (index-of-in lowercase next) None)
                      (subs tail 0 (dec (count tail)))
                      (str tail zero))]
                (Ok (Some (str next new-tail))))
              None (Error "invalid order key head")))))))))

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
  (match (validate-integer-error value)
    (Some message) (Error message)
    None
    (let [run (decrement-digit-run value (dec (count value)))]
      (if (not (:digit-run-carried run))
        (Ok (Some (:digit-run-value run)))
      (let [head (char-at value 0)]
        (if (= head "a")
          (Ok (Some "Zz"))
          (if (= head "A")
            (Ok None)
            (match (adjacent-head head -1)
              (Some previous)
              (let [tail (suffix (:digit-run-value run) 1)
                    new-tail
                    (if (= (index-of-in uppercase previous) None)
                      (subs tail 0 (dec (count tail)))
                      (str tail (digit-at (dec (count digits)))))]
                (Ok (Some (str previous new-tail))))
              None (Error "invalid order key head")))))))))

(defn invalid-lower-upper? [lower upper]
  (match upper
    (Some value) (not (< (String.compare lower value) 0))
    None false))

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
  (< (String.compare lower upper) 0))

(defn midpoint [lower upper]
  (if (invalid-lower-upper? lower upper)
    (Error "invalid midpoint bounds")
    (if (or (trailing-zero? lower)
            (match upper
              (Some value) (trailing-zero? value)
              None false))
      (Error "midpoint has trailing zero")
      (let [shared
            (match upper
              (Some value) (midpoint-shared-prefix lower value)
              None 0)]
        (if (> shared 0)
          (match upper
            (Some upper-value)
            (match (midpoint (suffix lower shared) (Some (suffix upper-value shared)))
              (Ok rest)
              (Ok (str (subs upper-value 0 shared) rest))
              (Error message) (Error message))
            None (Error "invalid midpoint bounds"))
          (let [lower-digit
                (if (= lower "") (Some 0) (index-of (char-at lower 0)))
                upper-digit
                (match upper
                  (Some value) (index-of (char-at value 0))
                  None (Some (count digits)))]
            (match lower-digit
              (Some lower-value)
              (match upper-digit
                (Some upper-value)
                (if (> (- upper-value lower-value) 1)
                  (let [middle (quot (inc (+ lower-value upper-value)) 2)]
                    (Ok (digit-at middle)))
                  (match upper
                    (Some upper-value-string)
                    (if (> (count upper-value-string) 1)
                      (Ok (subs upper-value-string 0 1))
                      (match (midpoint (suffix lower 1) None)
                        (Ok rest)
                        (Ok (str (digit-at lower-value) rest))
                        (Error message) (Error message)))
                    None
                    (match (midpoint (suffix lower 1) None)
                      (Ok rest)
                      (Ok (str (digit-at lower-value) rest))
                      (Error message) (Error message))))
                None (Error "invalid fractional digit"))
              None (Error "invalid fractional digit"))))))))

(defn validate-optional-error [value]
  (match value
    (Some key) (validate-error key)
    None None))

(defn optional-lower-fails? [lower value]
  (match lower
    (Some lower-value) (not (string-less? lower-value value))
    None false))

(defn optional-upper-fails? [value upper]
  (match upper
    (Some upper-value) (not (string-less? value upper-value))
    None false))

(defn optional-string-or-error [value fallback]
  (match value
    (Ok maybe-value)
    (match maybe-value
      (Some result) (Ok result)
      None (Error fallback))
    (Error message) (Error message)))

(defn optional-string-or-midpoint
  [value integer fraction]
  (match value
    (Ok maybe-value)
    (match maybe-value
      (Some result) (Ok result)
      None
      (match (midpoint fraction None)
        (Ok middle) (Ok (str integer middle))
        (Error message) (Error message)))
    (Error message) (Error message)))

(defn prepend-string-result [prefix result]
  (match result
    (Ok value) (Ok (str prefix value))
    (Error message) (Error message)))

(defn before-upper-or-midpoint
  [value
   upper-value
   lower-integer
   lower-fraction]
  (match value
    (Ok maybe-value)
    (match maybe-value
      (Some result)
      (if (string-less? result upper-value)
        (Ok result)
        (prepend-string-result lower-integer (midpoint lower-fraction None)))
      None (prepend-string-result lower-integer (midpoint lower-fraction None)))
    (Error message) (Error message)))

(defn between-before-upper [upper-value integer]
  (let [fraction (suffix upper-value (count integer))]
    (if (= integer minimum)
      (prepend-string-result integer (midpoint "" (Some fraction)))
      (if (string-less? integer upper-value)
        (prepend-string-result integer (midpoint "" (Some fraction)))
        (optional-string-or-error (decrement integer) "cannot decrement order key")))))

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
  (match lower
    None
    (match upper
      None (Ok "a0")
      (Some upper-value)
      (match (integer-part upper-value)
        (Ok integer) (between-before-upper upper-value integer)
        (Error message) (Error message)))
    (Some lower-value)
    (match upper
      None
      (match (integer-part lower-value)
        (Ok integer) (between-after-lower lower-value integer)
        (Error message) (Error message))
      (Some upper-value)
      (match (integer-part lower-value)
        (Ok lower-integer)
        (match (integer-part upper-value)
          (Ok upper-integer)
          (let [lower-fraction (suffix lower-value (count lower-integer))
                upper-fraction (suffix upper-value (count upper-integer))]
            (if (= lower-integer upper-integer)
              (between-shared-integers lower-integer lower-fraction upper-fraction)
              (between-different-integers upper-value lower-integer lower-fraction)))
          (Error message) (Error message))
        (Error message) (Error message)))))

(defn between [lower upper]
  (match (validate-optional-error lower)
    (Some message) (Error message)
    None
    (match (validate-optional-error upper)
      (Some message) (Error message)
      None
      (match lower
        (Some lower-value)
        (match upper
          (Some upper-value)
          (if (not (string-less? lower-value upper-value))
            (Error "invalid order bounds")
            (match (between-core lower upper)
              (Ok value)
              (if (or (optional-lower-fails? lower value)
                      (optional-upper-fails? value upper))
                (Error "generate-key-between failed")
                (Ok value))
              (Error message) (Error message)))
          None
          (match (between-core lower upper)
            (Ok value)
            (if (or (optional-lower-fails? lower value)
                    (optional-upper-fails? value upper))
              (Error "generate-key-between failed")
              (Ok value))
            (Error message) (Error message)))
        None
        (match (between-core lower upper)
          (Ok value)
          (if (or (optional-lower-fails? lower value)
                  (optional-upper-fails? value upper))
            (Error "generate-key-between failed")
            (Ok value))
          (Error message) (Error message))))))

(defn n-after [lower count]
  (loop [lower lower remaining count result []]
    (if (= remaining 0)
      (Ok result)
      (match (between lower None)
        (Ok value) (recur (Some value) (dec remaining) (conj result value))
        (Error message) (Error message)))))

(defn n-before [upper count]
  (loop [upper upper remaining count result []]
    (if (= remaining 0)
      (Ok result)
      (match (between None upper)
        (Ok value) (recur (Some value) (dec remaining) (into [value] result))
        (Error message) (Error message)))))

(defn ^:result<vector<string>;string> n-between [lower upper count]
  (if (< count 0)
    (Error "order key count must not be negative")
    (if (= count 0)
      (Ok [])
      (if (= count 1)
        (match (between lower upper)
          (Ok value) (Ok [value])
          (Error message) (Error message))
        (match upper
          None
          (n-after lower count)
          (Some upper-value)
          (match lower
            None
            (n-before (Some upper-value) count)
            (Some _)
            (let [left-count (quot count 2)]
              (match (between lower upper)
                (Ok middle)
                (match (n-between lower (Some middle) left-count)
                  (Ok left)
                  (match (n-between (Some middle) upper (- (- count left-count) 1))
                    (Ok right)
                    (Ok (into (conj left middle) right))
                    (Error message) (Error message))
                  (Error message) (Error message))
                (Error message) (Error message)))))))))
