(ns logseq-chat.fractional-order
  (:require [clojure.string :as string]))

(def digits "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
(def zero "0")
(def lowercase "abcdefghijklmnopqrstuvwxyz")
(def uppercase "ABCDEFGHIJKLMNOPQRSTUVWXYZ")

(defn char-at [^:string value ^:int index]
  (subs value index (inc index)))

(defn suffix [^:string value ^:int offset]
  (if (>= offset (count value))
    ""
    (subs value offset)))

(defn repeat-string [^:string value ^:int times]
  (loop [index 0
         result ""]
    (if (= index times)
      result
      (recur (inc index) (str result value)))))

(def minimum "A00000000000000000000000000")

(defn index-of-in [^:string values ^:string target]
  (loop [index 0]
    (if (= index (count values))
      None
      (if (= (char-at values index) target)
        (Some index)
        (recur (inc index))))))

(defn index-of [^:string character]
  (index-of-in digits character))

(defn digit-at [^:int index]
  (char-at digits index))

(defn adjacent-head [^:string head ^:int offset]
  (match (index-of head)
    (Some index)
    (let [next (+ index offset)]
      (if (or (< next 0) (>= next (count digits)))
        None
        (Some (digit-at next))))
    None None))

(defn integer-length [^:string head]
  (match (index-of-in lowercase head)
    (Some index)
    (OrderIntOk (+ index 2))
    None
    (match (index-of-in uppercase head)
      (Some index)
      (OrderIntOk (+ (- (dec (count uppercase)) index) 2))
      None (OrderIntError "invalid order key head"))))

(defn integer-part [^:string key]
  (if (= key "")
    (OrderStringError "empty order key")
    (match (integer-length (char-at key 0))
      (OrderIntOk length)
      (if (< (count key) length)
        (OrderStringError "invalid integer part of order key")
        (OrderStringOk (subs key 0 length)))
      (OrderIntError message) (OrderStringError message))))

(defn validate-integer-error [^:string value]
  (match (integer-part value)
    (OrderStringOk integer)
    (let [digits-are-valid
          (loop [index 1]
            (if (= index (count integer))
              true
              (let [valid-digit (not (= (index-of (char-at integer index)) None))]
                (if valid-digit
                  (recur (inc index))
                  false))))]
      (if (and (= (count integer) (count value)) digits-are-valid)
        None
        (Some "invalid integer part of order key")))
    (OrderStringError message) (Some message)))

(defn validate-error [^:string key]
  (match (integer-part key)
    (OrderStringOk integer)
    (let [fraction (suffix key (count integer))]
      (if (or (= key minimum)
              (and (not (= fraction ""))
                   (= (char-at fraction (dec (count fraction))) zero)))
        (Some "invalid order key")
        None))
    (OrderStringError message) (Some message)))

(defn set-char [^:string value ^:int index ^:string character]
  (str (subs value 0 index) character (suffix value (inc index))))

(defn digit-run [^:string value ^:bool carried]
  (record digit-run
          (digit-run-value value)
          (digit-run-carried carried)))

(defn increment-digit-run [^:string value ^:int index]
  (if (= index 0)
    (digit-run value true)
    (match (index-of (char-at value index))
      (Some digit)
      (if (= (inc digit) (count digits))
        (increment-digit-run (set-char value index zero) (dec index))
        (digit-run (set-char value index (digit-at (inc digit))) false))
      None (digit-run value true))))

(defn increment [^:string value]
  (match (validate-integer-error value)
    (Some message) (OrderOptionalStringError message)
    None
    (let [run (increment-digit-run value (dec (count value)))]
      (if (not (:digit-run-carried run))
        (OrderOptionalStringOk (Some (:digit-run-value run)))
      (let [head (char-at value 0)]
        (if (= head "Z")
          (OrderOptionalStringOk (Some "a0"))
          (if (= head "z")
            (OrderOptionalStringOk None)
            (match (adjacent-head head 1)
              (Some next)
              (let [tail (suffix (:digit-run-value run) 1)
                    new-tail
                    (if (= (index-of-in lowercase next) None)
                      (subs tail 0 (dec (count tail)))
                      (str tail zero))]
                (OrderOptionalStringOk (Some (str next new-tail))))
              None (OrderOptionalStringError "invalid order key head")))))))))

(defn decrement-digit-run [^:string value ^:int index]
  (if (= index 0)
    (digit-run value true)
    (match (index-of (char-at value index))
      (Some digit)
      (if (= digit 0)
        (decrement-digit-run
         (set-char value index (digit-at (dec (count digits)))) (dec index))
        (digit-run (set-char value index (digit-at (dec digit))) false))
      None (digit-run value true))))

(defn decrement [^:string value]
  (match (validate-integer-error value)
    (Some message) (OrderOptionalStringError message)
    None
    (let [run (decrement-digit-run value (dec (count value)))]
      (if (not (:digit-run-carried run))
        (OrderOptionalStringOk (Some (:digit-run-value run)))
      (let [head (char-at value 0)]
        (if (= head "a")
          (OrderOptionalStringOk (Some "Zz"))
          (if (= head "A")
            (OrderOptionalStringOk None)
            (match (adjacent-head head -1)
              (Some previous)
              (let [tail (suffix (:digit-run-value run) 1)
                    new-tail
                    (if (= (index-of-in uppercase previous) None)
                      (subs tail 0 (dec (count tail)))
                      (str tail (digit-at (dec (count digits)))))]
                (OrderOptionalStringOk (Some (str previous new-tail))))
              None (OrderOptionalStringError "invalid order key head")))))))))

(defn invalid-lower-upper? [^:string lower upper]
  (match upper
    (Some value) (not (< (String.compare lower value) 0))
    None false))

(defn trailing-zero? [^:string value]
  (and (not (= value ""))
       (= (char-at value (dec (count value))) zero)))

(defn midpoint-shared-prefix [^:string lower ^:string upper]
  (loop [index 0]
    (if (= index (count upper))
      index
      (let [lower-character
            (if (< index (count lower)) (char-at lower index) zero)]
        (if (= lower-character (char-at upper index))
          (recur (inc index))
          index)))))

(defn string-less? [^:string lower ^:string upper]
  (< (String.compare lower upper) 0))

(defn midpoint [^:string lower upper]
  (if (invalid-lower-upper? lower upper)
    (OrderStringError "invalid midpoint bounds")
    (if (or (trailing-zero? lower)
            (match upper
              (Some value) (trailing-zero? value)
              None false))
      (OrderStringError "midpoint has trailing zero")
      (let [shared
            (match upper
              (Some value) (midpoint-shared-prefix lower value)
              None 0)]
        (if (> shared 0)
          (match upper
            (Some upper-value)
            (match (midpoint (suffix lower shared) (Some (suffix upper-value shared)))
              (OrderStringOk rest)
              (OrderStringOk (str (subs upper-value 0 shared) rest))
              (OrderStringError message) (OrderStringError message))
            None (OrderStringError "invalid midpoint bounds"))
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
                    (OrderStringOk (digit-at middle)))
                  (match upper
                    (Some upper-value-string)
                    (if (> (count upper-value-string) 1)
                      (OrderStringOk (subs upper-value-string 0 1))
                      (match (midpoint (suffix lower 1) None)
                        (OrderStringOk rest)
                        (OrderStringOk (str (digit-at lower-value) rest))
                        (OrderStringError message) (OrderStringError message)))
                    None
                    (match (midpoint (suffix lower 1) None)
                      (OrderStringOk rest)
                      (OrderStringOk (str (digit-at lower-value) rest))
                      (OrderStringError message) (OrderStringError message))))
                None (OrderStringError "invalid fractional digit"))
              None (OrderStringError "invalid fractional digit"))))))))

(defn validate-optional-error [value]
  (match value
    (Some key) (validate-error key)
    None None))

(defn optional-lower-fails? [lower ^:string value]
  (match lower
    (Some lower-value) (not (string-less? lower-value value))
    None false))

(defn optional-upper-fails? [^:string value upper]
  (match upper
    (Some upper-value) (not (string-less? value upper-value))
    None false))

(defn optional-string-or-error [value ^:string fallback]
  (match value
    (OrderOptionalStringOk maybe-value)
    (match maybe-value
      (Some result) (OrderStringOk result)
      None (OrderStringError fallback))
    (OrderOptionalStringError message) (OrderStringError message)))

(defn optional-string-or-midpoint [value ^:string integer ^:string fraction]
  (match value
    (OrderOptionalStringOk maybe-value)
    (match maybe-value
      (Some result) (OrderStringOk result)
      None
      (match (midpoint fraction None)
        (OrderStringOk middle) (OrderStringOk (str integer middle))
        (OrderStringError message) (OrderStringError message)))
    (OrderOptionalStringError message) (OrderStringError message)))

(defn prepend-string-result [^:string prefix result]
  (match result
    (OrderStringOk value) (OrderStringOk (str prefix value))
    (OrderStringError message) (OrderStringError message)))

(defn before-upper-or-midpoint
  [value ^:string upper-value ^:string lower-integer ^:string lower-fraction]
  (match value
    (OrderOptionalStringOk maybe-value)
    (match maybe-value
      (Some result)
      (if (string-less? result upper-value)
        (OrderStringOk result)
        (prepend-string-result lower-integer (midpoint lower-fraction None)))
      None (prepend-string-result lower-integer (midpoint lower-fraction None)))
    (OrderOptionalStringError message) (OrderStringError message)))

(defn between-before-upper [^:string upper-value ^:string integer]
  (let [fraction (suffix upper-value (count integer))]
    (if (= integer minimum)
      (prepend-string-result integer (midpoint "" (Some fraction)))
      (if (string-less? integer upper-value)
        (prepend-string-result integer (midpoint "" (Some fraction)))
        (optional-string-or-error (decrement integer) "cannot decrement order key")))))

(defn between-after-lower [^:string lower-value ^:string integer]
  (let [fraction (suffix lower-value (count integer))]
    (optional-string-or-midpoint (increment integer) integer fraction)))

(defn between-shared-integers
  [^:string lower-integer ^:string lower-fraction ^:string upper-fraction]
  (prepend-string-result lower-integer (midpoint lower-fraction (Some upper-fraction))))

(defn between-different-integers
  [^:string upper-value ^:string lower-integer ^:string lower-fraction]
  (before-upper-or-midpoint
   (increment lower-integer) upper-value lower-integer lower-fraction))

(defn between-core [lower upper]
  (match lower
    None
    (match upper
      None (OrderStringOk "a0")
      (Some upper-value)
      (match (integer-part upper-value)
        (OrderStringOk integer) (between-before-upper upper-value integer)
        (OrderStringError message) (OrderStringError message)))
    (Some lower-value)
    (match upper
      None
      (match (integer-part lower-value)
        (OrderStringOk integer) (between-after-lower lower-value integer)
        (OrderStringError message) (OrderStringError message))
      (Some upper-value)
      (match (integer-part lower-value)
        (OrderStringOk lower-integer)
        (match (integer-part upper-value)
          (OrderStringOk upper-integer)
          (let [lower-fraction (suffix lower-value (count lower-integer))
                upper-fraction (suffix upper-value (count upper-integer))]
            (if (= lower-integer upper-integer)
              (between-shared-integers lower-integer lower-fraction upper-fraction)
              (between-different-integers upper-value lower-integer lower-fraction)))
          (OrderStringError message) (OrderStringError message))
        (OrderStringError message) (OrderStringError message)))))

(defn between [lower upper]
  (match (validate-optional-error lower)
    (Some message) (OrderStringError message)
    None
    (match (validate-optional-error upper)
      (Some message) (OrderStringError message)
      None
      (match lower
        (Some lower-value)
        (match upper
          (Some upper-value)
          (if (not (string-less? lower-value upper-value))
            (OrderStringError "invalid order bounds")
            (match (between-core lower upper)
              (OrderStringOk value)
              (if (or (optional-lower-fails? lower value)
                      (optional-upper-fails? value upper))
                (OrderStringError "generate-key-between failed")
                (OrderStringOk value))
              (OrderStringError message) (OrderStringError message)))
          None
          (match (between-core lower upper)
            (OrderStringOk value)
            (if (or (optional-lower-fails? lower value)
                    (optional-upper-fails? value upper))
              (OrderStringError "generate-key-between failed")
              (OrderStringOk value))
            (OrderStringError message) (OrderStringError message)))
        None
        (match (between-core lower upper)
          (OrderStringOk value)
          (if (or (optional-lower-fails? lower value)
                  (optional-upper-fails? value upper))
            (OrderStringError "generate-key-between failed")
            (OrderStringOk value))
          (OrderStringError message) (OrderStringError message))))))

(defn n-after [lower ^:int count result]
  (if (= count 0)
    (OrderStringVectorOk result)
    (match (between lower None)
      (OrderStringOk value)
      (n-after (Some value) (dec count) (conj result value))
      (OrderStringError message) (OrderStringVectorError message))))

(defn n-before [upper ^:int count result]
  (if (= count 0)
    (OrderStringVectorOk result)
    (match (between None upper)
      (OrderStringOk value)
      (n-before (Some value) (dec count) (into [value] result))
      (OrderStringError message) (OrderStringVectorError message))))

(defn n-between [lower upper ^:int count]
  (if (< count 0)
    (OrderStringVectorError "order key count must not be negative")
    (if (= count 0)
      (OrderStringVectorOk [])
      (if (= count 1)
        (match (between lower upper)
          (OrderStringOk value) (OrderStringVectorOk [value])
          (OrderStringError message) (OrderStringVectorError message))
        (match upper
          None
          (n-after lower count [])
          (Some upper-value)
          (match lower
            None
            (n-before (Some upper-value) count [])
            (Some _)
            (let [left-count (quot count 2)]
              (match (between lower upper)
                (OrderStringOk middle)
                (match (n-between lower (Some middle) left-count)
                  (OrderStringVectorOk left)
                  (match (n-between (Some middle) upper (- (- count left-count) 1))
                    (OrderStringVectorOk right)
                    (OrderStringVectorOk (into (conj left middle) right))
                    (OrderStringVectorError message) (OrderStringVectorError message))
                  (OrderStringVectorError message) (OrderStringVectorError message))
                (OrderStringError message) (OrderStringVectorError message)))))))))
