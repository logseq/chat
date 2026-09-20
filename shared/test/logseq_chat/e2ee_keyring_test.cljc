(ns logseq-chat.e2ee-keyring-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.e2ee :as e2ee]
            [logseq-chat.e2ee-keyring :as keyring]
            [logseq-chat.api :as api]
            [ocaml.Transit_core.Json :as transit]
            [ocaml.Transit_native.Transit.Json :as codec]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Stdlib :as stdlib]))

(def success (Ok (stdlib/ignore 0)))

(defn expect-ok [result] (match result (Ok value) value (Error message) (stdlib/failwith message)))

(def crypto
  (record e2ee/e2ee-crypto
    (decrypt-private-key (fn [_ _ _ _ _] (Ok "private-key")))
    (decrypt-graph-key (fn [_ _] (Ok "remote-graph-key")))
    (encrypt-graph-key (fn [_ _] (Error "unused")))
    (random-bytes (fn [_] (Error "unused")))
    (encrypt-aes-gcm (fn [_ _] (Ok (tuple "iv" "ciphertext"))))
    (decrypt-aes-gcm (fn [_ _ _] (Ok (codec/to-string (transit/String "decrypted title")))))))

(def config (record api/api-config (base-url "https://api.example") (graph-id "encrypted-graph")
                    (graph-name (Some "Private")) (token "access-token")))

(def private-package (codec/to-string (transit/Array (list (transit/String "20251210") (transit/Binary "salt")
                                                         (transit/Binary "private-iv") (transit/Binary "encrypted-private")))))

(def graph-package (codec/to-string (transit/Binary "encrypted-graph-key")))

(defn response [status body] (Ok (record api/api-response (status status) (body body))))

(defn json-body [entries]
  (json/to-string (tag Assoc (apply list (map (fn [entry] (tuple (key entry) (tag String (val entry)))) entries)))))

(defn fetch [request]
  (response 200 (json-body (if (string/ends-with? (:url request) "/user-keys")
                            [(tuple "public-key" "public") (tuple "encrypted-private-key" private-package)]
                            [(tuple "encrypted-aes-key" graph-package)]))))

(deftest unlock-fetches-and-securely-persists-both-keys
  (let [requests (atom []) saved (atom []) passwords (atom [])
        ring (keyring/create crypto (fn [_] (Ok None))
               (fn [graph key] (swap! saved conj (tuple graph key)) success)
               (fn [] (Ok None)) (fn [password] (swap! passwords conj password) success)
               (fn [request] (swap! requests conj (:url request)) (fetch request)))]
    (is (= "remote-graph-key" (expect-ok (keyring/unlock ring config "e2etest"))))
    (is (= [(tuple "encrypted-graph" "remote-graph-key")] @saved))
    (is (= ["e2etest"] @passwords))
    (is (= 2 (count @requests)))))

(deftest cached-account-password-opens-an-uncached-graph-without-rewriting-password
  (let [loads (atom 0) saves (atom 0)
        ring (keyring/create crypto (fn [_] (Ok None)) (fn [_ _] success)
               (fn [] (swap! loads inc) (Ok (Some "e2etest")))
               (fn [_] (swap! saves inc) success) fetch)]
    (is (= "remote-graph-key" (expect-ok (keyring/load-cached ring config))))
    (is (= 1 @loads)) (is (= 0 @saves))))

(deftest multiple-graphs-reuse-the-decrypted-account-private-key
  (let [decryptions (atom 0)
        engine (assoc crypto :decrypt-private-key (fn [_ _ _ _ _] (swap! decryptions inc) (Ok "private-key")))
        ring (keyring/create engine (fn [_] (Ok None)) (fn [_ _] success)
               (fn [] (Ok (Some "e2etest"))) (fn [_] success) fetch)]
    (expect-ok (keyring/load-cached ring config))
    (expect-ok (keyring/load-cached ring (assoc config :graph-id "second-encrypted-graph")))
    (is (= 1 @decryptions))))

(deftest securely-cached-graph-key-opens-offline
  (let [requests (atom 0)
        ring (keyring/create crypto
               (fn [graph] (Ok (when (= graph "encrypted-graph") "cached-key")))
               (fn [_ _] success) (fn [] (Ok None)) (fn [_] success)
               (fn [_] (swap! requests inc) (Error "offline")))]
    (is (= "cached-key" (expect-ok (keyring/load-cached ring config))))
    (is (= 0 @requests))))

(deftest wrong-password-never-persists-key-or-password
  (let [saves (atom 0) passwords (atom 0)
        engine (assoc crypto :decrypt-private-key (fn [_ _ _ _ _] (Error "wrong password")))
        ring (keyring/create engine (fn [_] (Ok None))
               (fn [_ _] (swap! saves inc) success) (fn [] (Ok None))
               (fn [_] (swap! passwords inc) success) fetch)]
    (is (match (keyring/unlock ring config "wrong") (Error _) true (Ok _) false))
    (is (= 0 @saves)) (is (= 0 @passwords))))

(deftest title-codec-uses-the-loaded-key-and-logseq-transit-envelope
  (let [ring (keyring/create crypto (fn [_] (Ok (Some "cached-key"))) (fn [_ _] success)
               (fn [] (Ok None)) (fn [_] success) (fn [_] (Error "unused")))]
    (expect-ok (keyring/load-cached ring config))
    (let [encrypted (expect-ok (keyring/encrypt-title ring "encrypted-graph" "plain title"))]
      (is (= (transit/Array (list (transit/Binary "iv") (transit/Binary "ciphertext"))) (codec/of-string encrypted)))
      (is (= "decrypted title" (expect-ok (keyring/decrypt-title ring "encrypted-graph" encrypted)))))))

(deftest assets-encrypt-transit-binary-with-the-loaded-key
  (let [plaintext (atom None)
        engine (assoc crypto :encrypt-aes-gcm
                      (fn [key value] (is (= "cached-key" key)) (reset! plaintext (Some value))
                        (Ok (tuple "asset-iv" "asset-ciphertext"))))
        ring (keyring/create engine (fn [_] (Ok (Some "cached-key"))) (fn [_ _] success)
               (fn [] (Ok None)) (fn [_] success) (fn [_] (Error "unused")))]
    (expect-ok (keyring/load-cached ring config))
    (let [encrypted (expect-ok (keyring/encrypt-asset ring "encrypted-graph" "raw-image-bytes"))]
      (is (= (transit/Binary "raw-image-bytes") (codec/of-string (or @plaintext (stdlib/failwith "missing plaintext")))))
      (is (= (transit/Array (list (transit/Binary "asset-iv") (transit/Binary "asset-ciphertext")))
             (codec/of-string encrypted))))))

(def provision-crypto
  (assoc crypto :random-bytes (fn [count] (Ok (apply str (repeat count "a"))))
                :encrypt-graph-key (fn [public plaintext] (Ok (string/join "" [public plaintext])))))

(def public-package (codec/to-string (transit/Binary "public")))

(defn public-response []
  (response 200 (json-body [(tuple "public-key" public-package) (tuple "encrypted-private-key" "unused")])))

(deftest provision-uploads-and-caches-the-new-graph-key
  (let [uploaded-body (atom None) saved (atom None)
        ring (keyring/create provision-crypto (fn [_] (Ok None))
               (fn [_ key] (reset! saved (Some key)) success)
               (fn [] (Ok None)) (fn [_] success)
               (fn [request]
                 (when (= (:method_ request) "POST") (reset! uploaded-body (:body request)))
                 (if (string/ends-with? (:url request) "/user-keys") (public-response) (response 200 "{}"))))
        key (expect-ok (keyring/provision ring (assoc config :graph-id "new-graph" :graph-name None :token "token")))
        body (or @uploaded-body (stdlib/failwith "missing upload body"))]
    (is (= (apply str (repeat 32 "a")) key))
    (is (= (Some key) @saved))
    (is (= (transit/Binary (str "public" key)) (codec/of-string (api/graph-key-from-body body))))))

(deftest failed-unlock-preserves-locked-state-and-persistence-order
  (run! (fn [failure]
          (let [writes (atom [])
                ring (keyring/create crypto (fn [_] (Ok None))
                       (fn [_ _] (swap! writes conj "key") (if (= failure "save-key") (Error "key storage failed") success))
                       (fn [] (Ok None))
                       (fn [_] (swap! writes conj "password") (if (= failure "save-password") (Error "password storage failed") success))
                       (fn [request]
                         (case failure "network" (Error "offline") "http" (response 403 "denied")
                               "json" (response 200 "{") (fetch request))))]
            (is (match (keyring/unlock ring config "password") (Error message) (not (empty? message)) (Ok _) false))
            (is (= (Error "encrypted graph is locked") (keyring/graph-key ring (:graph-id config))))
            (is (= (Error "E2EE password is not cached") (keyring/load-cached ring config)))
            (is (= (case failure "save-password" ["password"] "save-key" ["password" "key"] []) @writes))))
        ["network" "http" "json" "save-password" "save-key"]))

(deftest memory-cache-avoids-storage-reads-and-locked-operations-fail
  (let [loads (atom 0)
        ring (keyring/create crypto
               (fn [graph] (swap! loads inc) (if (= graph (:graph-id config)) (Ok (Some "cached-key")) (Error "storage unavailable")))
               (fn [_ _] (stdlib/failwith "unexpected save"))
               (fn [] (stdlib/failwith "unexpected password load"))
               (fn [_] (stdlib/failwith "unexpected password save"))
               (fn [_] (stdlib/failwith "unexpected network request")))]
    (run! #(is (= (Error "encrypted graph is locked") %))
          [(keyring/encrypt-title ring "locked" "text") (keyring/encrypt-asset ring "locked" "bytes")
           (keyring/decrypt-title ring "locked" "ciphertext")])
    (is (= "cached-key" (expect-ok (keyring/load-cached ring config))))
    (is (= "cached-key" (expect-ok (keyring/load-cached ring config))))
    (is (= 1 @loads))
    (is (= (Error "storage unavailable") (keyring/load-cached ring (assoc config :graph-id "other"))))))

(deftest rejected-provision-upload-never-saves-or-unlocks
  (let [ring (keyring/create (assoc provision-crypto :encrypt-graph-key (fn [_ _] (Ok "wrapped")))
               (fn [_] (Ok None)) (fn [_ _] (stdlib/failwith "rejected upload must not be saved"))
               (fn [] (Ok None)) (fn [_] (stdlib/failwith "provision must not save a password"))
               (fn [request] (if (= (:method_ request) "POST") (response 503 "unavailable") (public-response))))]
    (is (= (Error "upload graph E2EE key returned HTTP 503") (keyring/provision ring config)))
    (is (= (Error "encrypted graph is locked") (keyring/graph-key ring (:graph-id config))))))
