(ns logseq-chat.fractional-order
  (:require [clojure.string :as string]))

(def digits "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
(def zero "0")
(def lowercase "abcdefghijklmnopqrstuvwxyz")
(def uppercase "ABCDEFGHIJKLMNOPQRSTUVWXYZ")

(type-record digit-run
  (digit-run-value :string)
  (digit-run-carried :bool))

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
    (Ok (+ index 2))
    None
    (match (index-of-in uppercase head)
      (Some index)
      (Ok (+ (- (dec (count uppercase)) index) 2))
      None (Error "invalid order key head"))))

(defn integer-part [^:string key]
  (if (= key "")
    (Error "empty order key")
    (match (integer-length (char-at key 0))
      (Ok length)
      (if (< (count key) length)
        (Error "invalid integer part of order key")
        (Ok (subs key 0 length)))
      (Error message) (Error message))))

(defn validate-integer-error [^:string value]
  (match (integer-part value)
    (Ok integer)
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
    (Error message) (Some message)))

(defn validate-error [^:string key]
  (match (integer-part key)
    (Ok integer)
    (let [fraction (suffix key (count integer))]
      (if (or (= key minimum)
              (and (not (= fraction ""))
                   (= (char-at fraction (dec (count fraction))) zero)))
        (Some "invalid order key")
        None))
    (Error message) (Some message)))

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

(defn ^:result<string;string> midpoint [^:string lower ^:option<string> upper]
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

(defn optional-lower-fails? [lower ^:string value]
  (match lower
    (Some lower-value) (not (string-less? lower-value value))
    None false))

(defn optional-upper-fails? [^:string value upper]
  (match upper
    (Some upper-value) (not (string-less? value upper-value))
    None false))

(defn optional-string-or-error [^:result<option<string>;string> value ^:string fallback]
  (match value
    (Ok maybe-value)
    (match maybe-value
      (Some result) (Ok result)
      None (Error fallback))
    (Error message) (Error message)))

(defn optional-string-or-midpoint
  [^:result<option<string>;string> value ^:string integer ^:string fraction]
  (match value
    (Ok maybe-value)
    (match maybe-value
      (Some result) (Ok result)
      None
      (match (midpoint fraction None)
        (Ok middle) (Ok (str integer middle))
        (Error message) (Error message)))
    (Error message) (Error message)))

(defn prepend-string-result [^:string prefix ^:result<string;string> result]
  (match result
    (Ok value) (Ok (str prefix value))
    (Error message) (Error message)))

(defn before-upper-or-midpoint
  [^:result<option<string>;string> value
   ^:string upper-value
   ^:string lower-integer
   ^:string lower-fraction]
  (match value
    (Ok maybe-value)
    (match maybe-value
      (Some result)
      (if (string-less? result upper-value)
        (Ok result)
        (prepend-string-result lower-integer (midpoint lower-fraction None)))
      None (prepend-string-result lower-integer (midpoint lower-fraction None)))
    (Error message) (Error message)))

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

(defn ^:result<string;string> between-core [^:option<string> lower ^:option<string> upper]
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

(defn ^:result<string;string> between [^:option<string> lower ^:option<string> upper]
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

(def ^:vector<string> empty-string-vector (subvec [""] 0 0))

(defn ^:result<vector<string>;string> n-after [^:option<string> lower ^:int count ^:vector<string> result]
  (if (= count 0)
    (Ok result)
    (match (between lower None)
      (Ok value)
      (n-after (Some value) (dec count) (conj result value))
      (Error message) (Error message))))

(defn ^:result<vector<string>;string> n-before [^:option<string> upper ^:int count ^:vector<string> result]
  (if (= count 0)
    (Ok result)
    (match (between None upper)
      (Ok value)
      (n-before (Some value) (dec count) (into [value] result))
      (Error message) (Error message))))

(defn ^:result<vector<string>;string> n-between [^:option<string> lower ^:option<string> upper ^:int count]
  (if (< count 0)
    (Error "order key count must not be negative")
    (if (= count 0)
      (Ok empty-string-vector)
      (if (= count 1)
        (match (between lower upper)
          (Ok value) (Ok [value])
          (Error message) (Error message))
        (match upper
          None
          (n-after lower count empty-string-vector)
          (Some upper-value)
          (match lower
            None
            (n-before (Some upper-value) count empty-string-vector)
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
