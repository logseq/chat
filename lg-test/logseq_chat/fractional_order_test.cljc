(ns logseq-chat.fractional-order-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.fractional-order :as order]))

(defn value [result]
  (match result (Ok value) value (Error message) (throw (Failure message))))

(defn error? [result] (match result (Error _) true (Ok _) false))

(def minimum (str "A" (string/join "" (repeat 26 "0"))))

(def maximum (string/join "" (repeat 27 "z")))

(defn inside? [lower key upper]
  (and (neg? (compare lower key)) (neg? (compare key upper)) (nil? (order/validate-error key))))

(deftest repeated-insertion
  (is (= "0G" (value (order/midpoint "" (Some "0V")))))
  (run! (fn [lower]
          (loop [remaining 100 upper (value (order/between (Some lower) nil))]
            (when (pos? remaining)
              (let [key (value (order/between (Some lower) (Some upper)))]
                (is (inside? lower key upper))
                (recur (dec remaining) key)))))
        ["a0" "a0V" "Zz"]))

(deftest basic-boundaries
  (is (= "a0" (value (order/between nil nil))))
  (is (= "a1" (value (order/between (Some "a0") nil))))
  (is (= "a0V" (value (order/between (Some "a0") (Some "a1")))))
  (is (= "Zz" (value (order/between nil (Some "a0")))))
  (is (= ["a0G" "a0V" "a0l"] (value (order/n-between (Some "a0") (Some "a1") 3))))
  (is (error? (order/between (Some "a1") (Some "a0"))))
  (is (error? (order/between (Some "a00") nil))))

(deftest integer-validation-and-suffix
  (is (= (Ok 2) (order/integer-length "a")))
  (is (= (Ok 27) (order/integer-length "z")))
  (is (= (Ok 2) (order/integer-length "Z")))
  (is (= (Ok 27) (order/integer-length "A")))
  (is (error? (order/integer-length "0")))
  (is (error? (order/integer-part "")))
  (is (error? (order/integer-part "b0")))
  (is (= "a0" (value (order/integer-part "a0V"))))
  (is (= "" (order/suffix "abc" 3)))
  (is (= "" (order/suffix "abc" 4)))
  (is (= "bc" (order/suffix "abc" 1)))
  (is (some? (order/validate-integer-error "a!")))
  (is (some? (order/validate-integer-error "a0V")))
  (is (some? (order/validate-error minimum)))
  (is (some? (order/validate-error "a0V0"))))

(deftest integer-increment-and-decrement
  (run! (fn [[input expected]] (is (= (Ok (Some expected)) (order/increment input))))
        [["a0" "a1"] ["aZ" "aa"] ["az" "b00"] ["Yzz" "Z0"] ["Zz" "a0"]])
  (is (= (Ok nil) (order/increment maximum)))
  (is (error? (order/increment "a!")))
  (run! (fn [[input expected]] (is (= (Ok (Some expected)) (order/decrement input))))
        [["a1" "a0"] ["a0" "Zz"] ["Z0" "Yzz"] ["b00" "az"]])
  (is (= (Ok nil) (order/decrement minimum)))
  (is (error? (order/decrement "a!"))))

(deftest midpoint-cases
  (is (= "V" (value (order/midpoint "" nil))))
  (run! (fn [[lower upper expected]]
          (is (= expected (value (order/midpoint lower (Some upper))))))
        [["a1" "a3" "a2"] ["a" "a1" "a0V"] ["1" "2" "1V"] ["" "1x" "1"]])
  (is (error? (order/midpoint "a" (Some "a"))))
  (is (error? (order/midpoint "0" nil)))
  (is (error? (order/midpoint "" (Some "10"))))
  (is (error? (order/midpoint "!" nil))))

(deftest sentinel-and-fraction-boundaries
  (is (= "a0G" (value (order/between nil (Some "a0V")))))
  (let [upper (str minimum "V") key (value (order/between nil (Some upper)))]
    (is (neg? (compare key upper)))
    (is (nil? (order/validate-error key))))
  (is (= "a1" (value (order/between (Some "a0") (Some "b00")))))
  (let [key (value (order/between (Some maximum) nil))]
    (is (neg? (compare maximum key)))
    (is (nil? (order/validate-error key))))
  (let [first-integer (str "A" (string/join "" (repeat 25 "0")) "1")]
    (is (= minimum (value (order/between nil (Some first-integer)))))
    (is (error? (order/n-between nil (Some first-integer) 2)))))

(deftest batch-counts-and-order
  (is (error? (order/n-between nil nil -1)))
  (is (= [] (value (order/n-between nil nil 0))))
  (is (= ["a0"] (value (order/n-between nil nil 1))))
  (let [appended (value (order/n-between (Some "a0") nil 3))
        prepended (value (order/n-between nil (Some "a0") 3))]
    (is (= appended (vec (sort appended))))
    (is (= prepended (vec (sort prepended))))))

(deftest sampled-bounds
  (let [samples [(str minimum "V") "Zz" "a0" "a0V" "a1" "b00" maximum]]
    (run! (fn [lower]
            (run! (fn [upper]
                    (when (neg? (compare lower upper))
                      (is (inside? lower (value (order/between (Some lower) (Some upper))) upper))))
                  samples))
          samples)))

(deftest logseq-pinned-golden-vectors
  (is (= ["a0" "a1" "a2" "a3" "a4" "a5" "a6" "a7" "a8" "a9" "aA" "aB" "aC" "aD" "aE" "aF" "aG" "aH" "aI" "aJ"]
         (value (order/n-between nil nil 20))))
  (is (= ["c0Zj" "c0Zk" "c0Zl" "c0Zm" "c0Zn" "c0Zo" "c0Zp" "c0Zq" "c0Zr" "c0Zs" "c0Zt" "c0Zu" "c0Zv" "c0Zw" "c0Zx" "c0Zy" "c0Zz" "c0a0" "c0a1" "c0a2"]
         (value (order/n-between nil (Some "c0a3") 20))))
  (is (= ["ZxX" "ZxZ" "Zxd" "Zxf" "Zxh" "Zxl" "Zxn" "Zxp" "Zxt" "Zxx" "Zy" "Zy0V" "Zy1" "Zy2" "Zy3" "Zy4" "Zy4V" "Zy5" "Zy6" "Zy6V"]
         (value (order/n-between (Some "ZxV") (Some "Zy7") 20))))
  (is (= ["ZyB" "ZyE" "ZyL" "ZyP" "ZyS" "ZyZ" "Zyd" "Zyg" "Zyn" "Zyu" "Zz" "Zz8" "ZzG" "ZzV" "Zzl" "a0" "a0G" "a0V" "a1" "a2"]
         (value (order/n-between (Some "Zy7") (Some "axV") 20))))
  (is (= ["c0a4" "c0a5" "c0a6" "c0a7" "c0a8" "c0a9" "c0aA" "c0aB" "c0aC" "c0aD" "c0aE" "c0aF" "c0aG" "c0aH" "c0aI" "c0aJ" "c0aK" "c0aL" "c0aM" "c0aN"]
         (value (order/n-between (Some "c0a3") nil 20)))))

