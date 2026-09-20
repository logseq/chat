(ns logseq-chat.platform-crypto-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.platform-crypto :as platform]
            [logseq-chat.native-crypto :as native]
            [logseq-chat.e2ee-keyring :as keyring]
            [logseq-chat.api :as api]
            [ocaml.Callback :as callback]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.String :as bytes]
            [ocaml.Char :as char]
            [ocaml.Stdlib :as stdlib]))

(def call-raw native/call-raw)

(def response (atom "{\"ok\":true,\"value\":\"00ff\"}"))

(def request (atom (json/from-string "{}")))

(def transport-failure (atom false))

(callback/register "platform_crypto_test_call"
  (fn [input]
    (when @transport-failure (stdlib/failwith "native crypto unavailable"))
    (reset! request (json/from-string input))
    @response))

(defn reset-transport []
  (reset! transport-failure false)
  (reset! response "{\"ok\":true,\"value\":\"00ff\"}"))

(defn field [name] (json-util/member name @request))

(defn operation [name] (is (= (tag String name) (field "operation"))))

(def config
  (record api/api-config (base-url "https://api.example") (graph-id "graph")
          (graph-name nil) (token "token")))

(deftest native-keyring-loads-offline-and-keeps-graph-keys-isolated
  (reset-transport)
  (let [requests (atom 0)
        ring (platform/create-keyring call-raw
               (fn [_] (swap! requests inc) (Error "offline")))
        key (str (bytes/make 1 (char/chr 0)) (bytes/make 1 (char/chr 255)))]
    (is (= (Ok key) (keyring/load-cached ring config)))
    (operation "loadGraphKey")
    (is (= (tag String "graph") (field "graphID")))
    (is (= (Ok key) (keyring/graph-key ring "graph")))
    (is (= (Error "encrypted graph is locked") (keyring/graph-key ring "other")))
    (reset! response "{\"ok\":false,\"error\":\"locked\"}")
    (is (= (Ok key) (keyring/load-cached ring config)))
    (is (= (Error "locked") (keyring/load-cached ring (assoc config :graph-id "other"))))
    (is (= 0 @requests))))

(deftest native-keyring-preserves-cache-misses-and-transport-errors
  (reset-transport)
  (let [requests (atom 0)
        ring (platform/create-keyring call-raw
               (fn [_] (swap! requests inc) (Error "offline")))]
    (reset! response "{\"ok\":true,\"value\":null}")
    (is (= (Error "E2EE password is not cached") (keyring/load-cached ring config)))
    (operation "loadE2EEPassword")
    (reset! transport-failure true)
    (try
      (is (= (Error "Failure(\"native crypto unavailable\")") (keyring/load-cached ring config)))
      (is (= 0 @requests))
      (finally (reset-transport)))))

(deftest binary-hex-roundtrip
  (let [all-bytes (bytes/init 256 char/chr)]
    (is (= "00ff107f80" (platform/hex (bytes/init 5 #(char/chr (nth [0 255 16 127 128] %))))))
    (is (= (Ok all-bytes) (platform/unhex (platform/hex all-bytes))))
    (is (= (Ok "") (platform/unhex "")))
    (is (= (Ok (bytes/init 2 #(char/chr (nth [171 205] %)))) (platform/unhex "ABcd")))
    (run! #(is (= (Error "platform crypto returned invalid hex") (platform/unhex %)))
          ["0" "gg" "ffffx" "zz"])))

(deftest crypto-operations-cross-native-ffi
  (reset-transport)
  (let [engine (platform/crypto call-raw)
        zero (bytes/make 1 (char/chr 0))
        one (bytes/make 1 (char/chr 1))
        ff (bytes/make 1 (char/chr 255))
        value (str zero ff)]
    (is (= (Ok value) ((:decrypt-private-key engine) "secret" 600000 zero one ff)))
    (operation "decryptPrivateKey")
    (is (= (tag String "secret") (field "password")))
    (is (= (tag Int 600000) (field "iterations")))
    (is (= (tag String "00") (field "salt")))
    (is (= (tag String "01") (field "iv")))
    (is (= (tag String "ff") (field "ciphertext")))
    (is (= (Ok value) ((:decrypt-graph-key engine) zero ff)))
    (operation "decryptGraphKey")
    (is (= (tag String "00") (field "privateKey")))
    (is (= (Ok value) ((:encrypt-graph-key engine) zero ff)))
    (operation "encryptGraphKey")
    (is (= (tag String "00") (field "publicKey")))
    (is (= (tag String "ff") (field "plaintext")))
    (is (= (Ok value) ((:random-bytes engine) 2)))
    (operation "randomBytes")
    (is (= (tag Int 2) (field "count")))
    (reset! response "{\"ok\":true,\"iv\":\"0001\",\"ciphertext\":\"feff\"}")
    (is (= (Ok (tuple (str zero one) (str (bytes/make 1 (char/chr 254)) ff)))
           ((:encrypt-aes-gcm engine) zero ff)))
    (operation "encryptAES")
    (is (= (tag String "00") (field "key")))
    (reset-transport)
    (is (= (Ok value) ((:decrypt-aes-gcm engine) zero one ff)))
    (operation "decryptAES")
    (is (= (tag String "01") (field "iv")))))

(deftest native-secret-cache-protocol
  (reset-transport)
  (let [all-bytes (bytes/init 256 char/chr)
        value (str (bytes/make 1 (char/chr 0)) (bytes/make 1 (char/chr 255)))
        password (str (bytes/make 1 (char/chr 0)) "secret" (bytes/make 1 (char/chr 255)))]
    (is (= (Ok (stdlib/ignore 0)) (platform/save-graph-key call-raw "graph" all-bytes)))
    (operation "saveGraphKey")
    (is (= (tag String "graph") (field "graphID")))
    (is (= (tag String (platform/hex all-bytes)) (field "key")))
    (is (= (Ok (Some value)) (platform/load-graph-key call-raw "graph")))
    (operation "loadGraphKey")
    (is (= (Ok (stdlib/ignore 0)) (platform/save-e2ee-password call-raw password)))
    (operation "saveE2EEPassword")
    (is (= (tag String "00736563726574ff") (field "password")))
    (is (= (Ok (Some value)) (platform/load-e2ee-password call-raw)))
    (operation "loadE2EEPassword"))
  (run! (fn [raw]
          (reset! response raw)
          (is (= (Ok None) (platform/load-graph-key call-raw "graph")))
          (is (= (Ok None) (platform/load-e2ee-password call-raw))))
        ["{\"ok\":true}" "{\"ok\":true,\"value\":null}"])
  (reset! response "{\"ok\":true,\"value\":42}")
  (is (= (Error "platform crypto returned invalid cached graph key") (platform/load-graph-key call-raw "graph")))
  (is (= (Error "platform crypto returned invalid cached E2EE password") (platform/load-e2ee-password call-raw))))

(deftest malformed-responses-and-native-failure
  (reset-transport)
  (let [engine (platform/crypto call-raw)]
    (run! (fn [[raw message]]
            (reset! response raw)
            (is (= (Error message) ((:random-bytes engine) 2))))
          [["{\"ok\":false,\"error\":\"locked\"}" "locked"]
           ["{\"ok\":false}" "platform crypto failed"]
           ["{\"ok\":true}" "platform crypto response is missing value"]
           ["{\"ok\":true,\"value\":\"xx\"}" "platform crypto returned invalid hex"]
           ["{\"ok\":true,\"value\":null}" "platform crypto response is missing value"]
           ["{\"ok\":false,\"ok\":true}" "platform crypto failed"]
           ["[]" "platform crypto returned invalid JSON"]])
    (reset! response "not JSON")
    (match ((:random-bytes engine) 2)
      (Error _) (is true)
      (Ok _) (stdlib/failwith "invalid JSON accepted"))
    (reset! response "{\"ok\":true,\"iv\":\"zz\",\"ciphertext\":\"00\"}")
    (is (= (Error "platform crypto returned invalid hex") ((:encrypt-aes-gcm engine) "" "")))
    (reset! response "{\"ok\":true,\"iv\":\"00\"}")
    (is (= (Error "platform crypto response is missing ciphertext") ((:encrypt-aes-gcm engine) "" "")))
    (reset! transport-failure true)
    (try
      (is (= (Error "Failure(\"native crypto unavailable\")") ((:random-bytes engine) 2)))
      (finally (reset-transport)))))
