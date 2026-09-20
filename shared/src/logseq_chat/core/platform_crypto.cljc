(ns logseq-chat.platform-crypto
  (:require [logseq-chat.e2ee :as e2ee]
            [logseq-chat.e2ee-keyring :as keyring]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.String :as byte-string]
            [ocaml.Bytes :as bytes]
            [ocaml.Char :as char]
            [ocaml.Buffer :as buffer]
            [ocaml.Stdlib :as stdlib]))

(defn hex [value]
  (let [result (buffer/create (* (count value) 2))
        digits "0123456789abcdef"]
    (dotimes [index (count value)]
      (let [code (char/code (byte-string/get value index))]
        (buffer/add-char result (byte-string/get digits (quot code 16)))
        (buffer/add-char result (byte-string/get digits (mod code 16)))))
    (buffer/contents result)))

(defn unhex [value]
  (if (odd? (count value))
    (Error "platform crypto returned invalid hex")
    (try
      (let [result (bytes/create (quot (count value) 2))]
        (dotimes [index (bytes/length result)]
          (bytes/set result index
            (char/chr (stdlib/int-of-string
                        (str "0x" (subs value (* index 2) (+ (* index 2) 2)))))))
        (Ok (bytes/to-string result)))
      (catch error (Error "platform crypto returned invalid hex")))))

(defn field [name fields]
  (json-util/member name fields))

(defn invoke [call operation fields]
  (try
    (let [request (tag Assoc (rrbvec/to-list
                              (into [(tuple "operation" (tag String operation))] fields)))
          response (json/from-string (call (json/to-string request)))]
      (match response
        (tag Assoc _)
        (match (field "ok" response)
          (tag Bool true) (Ok response)
          _ (match (field "error" response)
              (tag String message) (Error message)
              _ (Error "platform crypto failed")))
        _ (Error "platform crypto returned invalid JSON")))
    (catch error (Error (Printexc/to-string error)))))

(defn binary-field [name fields]
  (match (field name fields)
    (tag String value) (unhex value)
    _ (Error (str "platform crypto response is missing " name))))

(defn crypto [call]
  (record e2ee/e2ee-crypto
    (decrypt-private-key
      (fn [password iterations salt iv ciphertext]
        (let* [fields (invoke call "decryptPrivateKey"
                        [(tuple "password" (tag String password))
                         (tuple "iterations" (tag Int iterations))
                         (tuple "salt" (tag String (hex salt)))
                         (tuple "iv" (tag String (hex iv)))
                         (tuple "ciphertext" (tag String (hex ciphertext)))])]
          (binary-field "value" fields))))
    (decrypt-graph-key
      (fn [private-key ciphertext]
        (let* [fields (invoke call "decryptGraphKey"
                        [(tuple "privateKey" (tag String (hex private-key)))
                         (tuple "ciphertext" (tag String (hex ciphertext)))])]
          (binary-field "value" fields))))
    (encrypt-graph-key
      (fn [public-key plaintext]
        (let* [fields (invoke call "encryptGraphKey"
                        [(tuple "publicKey" (tag String (hex public-key)))
                         (tuple "plaintext" (tag String (hex plaintext)))])]
          (binary-field "value" fields))))
    (random-bytes
      (fn [size]
        (let* [fields (invoke call "randomBytes" [(tuple "count" (tag Int size))])]
          (binary-field "value" fields))))
    (encrypt-aes-gcm
      (fn [key plaintext]
        (let* [fields (invoke call "encryptAES"
                        [(tuple "key" (tag String (hex key)))
                         (tuple "plaintext" (tag String (hex plaintext)))])
               iv (binary-field "iv" fields)
               ciphertext (binary-field "ciphertext" fields)]
          (Ok (tuple iv ciphertext)))))
    (decrypt-aes-gcm
      (fn [key iv ciphertext]
        (let* [fields (invoke call "decryptAES"
                        [(tuple "key" (tag String (hex key)))
                         (tuple "iv" (tag String (hex iv)))
                         (tuple "ciphertext" (tag String (hex ciphertext)))])]
          (binary-field "value" fields))))))

(defn save-graph-key [call graph-id key]
  (let* [_ (invoke call "saveGraphKey"
             [(tuple "graphID" (tag String graph-id))
              (tuple "key" (tag String (hex key)))])]
    (Ok (stdlib/ignore nil))))

(defn cached-value [fields message]
  (match (field "value" fields)
    (tag String value) (let* [decoded (unhex value)] (Ok (Some decoded)))
    (tag Null) (Ok nil)
    _ (Error message)))

(defn load-graph-key [call graph-id]
  (let* [fields (invoke call "loadGraphKey" [(tuple "graphID" (tag String graph-id))])]
    (cached-value fields "platform crypto returned invalid cached graph key")))

(defn save-e2ee-password [call password]
  (let* [_ (invoke call "saveE2EEPassword" [(tuple "password" (tag String (hex password)))])]
    (Ok (stdlib/ignore nil))))

(defn load-e2ee-password [call]
  (let* [fields (invoke call "loadE2EEPassword" [])]
    (cached-value fields "platform crypto returned invalid cached E2EE password")))

(defn create-keyring [call fetch]
  (keyring/create (crypto call)
                  #(load-graph-key call %)
                  #(save-graph-key call %1 %2)
                  #(load-e2ee-password call)
                  #(save-e2ee-password call %)
                  fetch))
