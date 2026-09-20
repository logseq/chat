(ns logseq-chat.e2ee-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.e2ee :as e2ee]
            [ocaml.Transit_core.Json :as transit]
            [ocaml.Transit_native.Transit.Json :as codec]
            [ocaml.Stdlib :as stdlib]))

(defn expect-ok [result]
  (match result (Ok value) value (Error message) (stdlib/failwith message)))

(defn private-key-package [version]
  (codec/to-string
   (transit/Array
    (apply list (concat (if-some [version version] [(transit/String version)] [])
                        [(transit/Binary "salt") (transit/Binary "private-iv")
                         (transit/Binary "encrypted-private-key")])))))

(def encrypted-graph-key (codec/to-string (transit/Binary "encrypted-graph-key")))

(def status-value (transit/Keyword "logseq.property/status.todo"))

(defn crypto [^:ref<vector<string>> calls]
  (record e2ee/e2ee-crypto
          (decrypt-private-key
           (fn [password iterations salt iv ciphertext]
             (swap! calls conj (str "private:" password ":" iterations ":" salt ":" iv ":" ciphertext))
             (Ok "private-key")))
          (decrypt-graph-key
           (fn [private-key ciphertext]
             (swap! calls conj (str "graph:" private-key ":" ciphertext)) (Ok "graph-key")))
          (encrypt-graph-key
           (fn [public-key plaintext]
             (swap! calls conj (str "wrap:" public-key ":" plaintext)) (Ok "encrypted-graph-key")))
          (random-bytes (fn [size] (Ok (apply str (repeat size "k")))))
          (encrypt-aes-gcm
           (fn [key plaintext]
             (swap! calls conj (str "seal:" key ":" plaintext)) (Ok (tuple "value-iv" "encrypted-value"))))
          (decrypt-aes-gcm
           (fn [key iv ciphertext]
             (swap! calls conj (str "open:" key ":" iv ":" ciphertext))
             (Ok (codec/to-string status-value))))))

(deftest current-and-legacy-private-key-iterations
  (run! (fn [[version iterations]]
          (let [calls (atom [])
                key (expect-ok (e2ee/unlock-graph-key (crypto calls) "e2etest"
                                                      (private-key-package version) encrypted-graph-key))]
            (is (= "graph-key" key))
            (is (= [(str "private:e2etest:" iterations ":salt:private-iv:encrypted-private-key")
                    "graph:private-key:encrypted-graph-key"] @calls))))
        [(tuple (Some "20251210") 600000) (tuple None 100000)])
  (is (= 100000 (:iterations (expect-ok (e2ee/private-key-package (private-key-package (Some "20251209"))))))))

(deftest protected-values-round-trip-with-their-transit-types
  (let [calls (atom []) crypto (crypto calls)
        encrypted (expect-ok (e2ee/encrypt-value crypto "graph-key" status-value))]
    (is (= (transit/Array (list (transit/Binary "value-iv") (transit/Binary "encrypted-value")))
           (codec/of-string encrypted)))
    (is (= status-value (expect-ok (e2ee/decrypt-value crypto "graph-key" encrypted))))))

(deftest graph-key-preparation-uses-transit-binary-envelopes
  (let [calls (atom [])
        [key encrypted] (expect-ok (e2ee/prepare-graph-key (crypto calls) (codec/to-string (transit/Binary "public-key"))))
        expected (apply str (repeat 32 "k"))]
    (is (= expected key))
    (is (= (transit/Binary "encrypted-graph-key") (codec/of-string encrypted)))
    (is (some #(= % (str "wrap:public-key:" expected)) @calls))))

(deftest invalid-envelopes-fail-closed
  (let [calls (atom []) crypto (crypto calls)]
    (run! (fn [values]
            (is (= (Error "encrypted value has an invalid Transit AES-GCM envelope")
                   (e2ee/decrypt-value crypto "graph-key" (codec/to-string (transit/Array (apply list values)))))))
          [[(transit/String "iv") (transit/String "ciphertext")]
           [(transit/Binary "iv") (transit/Binary "cipher") (transit/Int 1)]
           [(transit/String "iv") (transit/Binary "cipher")]])
    (is (empty? @calls))))

(deftest plaintext-and-nested-strings-do-not-invoke-crypto
  (let [calls (atom []) crypto (crypto calls)
        nested (codec/to-string (transit/String (codec/to-string (transit/String "nested"))))]
    (is (= (Ok "Card") (e2ee/decrypt-string crypto "graph-key" "Card")))
    (is (= (Ok "Card") (e2ee/decrypt-string crypto "graph-key" (codec/to-string (transit/String "Card")))))
    (is (= (Ok "nested") (e2ee/decrypt-string crypto "g" nested)))
    (is (= (Error "decrypted protected value is not a string")
           (e2ee/decrypt-string crypto "g" (codec/to-string (transit/Int 1)))))
    (is (empty? @calls))))

(deftest crypto-errors-short-circuit-subsequent-operations
  (let [calls (atom []) base (crypto calls)
        failed-private (assoc base :decrypt-private-key (fn [_ _ _ _ _] (Error "private failure")))
        failed-random (assoc base :random-bytes (fn [_] (Error "random failure")))
        bad-aes (assoc base :decrypt-aes-gcm (fn [_ _ _] (Error "authentication failure")))]
    (is (= (Error "private failure")
           (e2ee/unlock-graph-key failed-private "p" (private-key-package None) encrypted-graph-key)))
    (is (empty? @calls))
    (is (= (Error "random failure")
           (e2ee/prepare-graph-key failed-random (codec/to-string (transit/Binary "public")))))
    (is (empty? @calls))
    (is (= (Error "encrypted graph key is not Transit binary")
           (e2ee/prepare-graph-key base (codec/to-string (transit/String "not binary")))))
    (is (empty? @calls))
    (is (= (Error "authentication failure")
           (e2ee/decrypt-value bad-aes "g"
                               (codec/to-string (transit/Array (list (transit/Binary "iv") (transit/Binary "cipher")))))))
    (is (empty? @calls))))
