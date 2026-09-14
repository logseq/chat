(ns logseq-chat.e2ee
  (:require [ocaml.package/melange-transit-core]
            [ocaml.package/melange-transit-native]
            [ocaml.Transit_core.Json :as transit]
            [ocaml.Transit_native.Transit.Json :as codec]))

(type-record e2ee-crypto
  (decrypt-private-key :fn<string;int;string;string;string;result<string;string>>)
  (decrypt-graph-key :fn<string;string;result<string;string>>)
  (encrypt-graph-key :fn<string;string;result<string;string>>)
  (random-bytes :fn<int;result<string;string>>)
  (encrypt-aes-gcm :fn<string;string;result<tuple<string;string>;string>>)
  (decrypt-aes-gcm :fn<string;string;string;result<string;string>>))

(type-record e2ee-private-key-package
  (iterations :int)
  (salt :string)
  (iv :string)
  (ciphertext :string))

(defn protect [operation f]
  (try
    (Ok (f))
    (catch (transit/Decode_error message) (Error (str operation ": " message)))
    (catch (Failure message) (Error (str operation ": " message)))
    (catch (Invalid_argument message) (Error (str operation ": " message)))
    (catch error (Error (str operation ": " (Printexc/to-string error))))))

(defn private-key-package [source]
  (let* [value (protect "decode encrypted private key" (fn [] (codec/of-string source)))]
    (match value
      (transit/Array [(transit/String version) (transit/Binary salt)
                      (transit/Binary iv) (transit/Binary ciphertext)])
      (Ok (record e2ee-private-key-package
            (iterations (if (>= (compare version "20251210") 0) 600000 100000))
            (salt salt) (iv iv) (ciphertext ciphertext)))
      (transit/Array [(transit/Binary salt) (transit/Binary iv) (transit/Binary ciphertext)])
      (Ok (record e2ee-private-key-package
            (iterations 100000) (salt salt) (iv iv) (ciphertext ciphertext)))
      _ (Error "encrypted private key has an invalid Transit envelope"))))

(defn binary [source]
  (let* [value (protect "decode encrypted graph key" (fn [] (codec/of-string source)))]
    (match value
      (transit/Binary value) (Ok value)
      _ (Error "encrypted graph key is not Transit binary"))))

(defn prepare-graph-key [crypto public-key-package]
  (let* [public-key (binary public-key-package)
         graph-key ((:random-bytes crypto) 32)
         encrypted ((:encrypt-graph-key crypto) public-key graph-key)]
    (Ok (tuple graph-key (codec/to-string (transit/Binary encrypted))))))

(defn decrypt-private-key [crypto password private-source]
  (let* [package (private-key-package private-source)]
    ((:decrypt-private-key crypto) password (:iterations package)
     (:salt package) (:iv package) (:ciphertext package))))

(defn decrypt-graph-key [crypto private-key encrypted-graph-key]
  (let* [ciphertext (binary encrypted-graph-key)]
    ((:decrypt-graph-key crypto) private-key ciphertext)))

(defn unlock-graph-key [crypto password private-source encrypted-graph-key]
  (let* [private-key (decrypt-private-key crypto password private-source)]
    (decrypt-graph-key crypto private-key encrypted-graph-key)))

(defn encrypt-value [crypto graph-key value]
  (let [plaintext (codec/to-string value)]
    (let* [[iv ciphertext] ((:encrypt-aes-gcm crypto) graph-key plaintext)]
      (Ok (codec/to-string (transit/Array (list (transit/Binary iv) (transit/Binary ciphertext))))))))

(defn decrypt-value [crypto graph-key source]
  (let [decoded (try (Some (codec/of-string source)) (catch error nil))]
    (match decoded
      None (Ok (transit/String source))
      (Some (transit/Array [(transit/Binary iv) (transit/Binary ciphertext)]))
      (let* [plaintext ((:decrypt-aes-gcm crypto) graph-key iv ciphertext)]
        (protect "decode decrypted value" (fn [] (codec/of-string plaintext))))
      (Some (transit/Array [_ _ & _]))
      (Error "encrypted value has an invalid Transit AES-GCM envelope")
      (Some (transit/String value))
      (try (Ok (codec/of-string value)) (catch error (Ok (transit/String value))))
      (Some value) (Ok value))))

(defn decrypt-string [crypto graph-key source]
  (let* [value (decrypt-value crypto graph-key source)]
    (match value
      (transit/String value) (Ok value)
      _ (Error "decrypted protected value is not a string"))))
