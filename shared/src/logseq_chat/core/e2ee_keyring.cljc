(ns logseq-chat.e2ee-keyring
  (:require [logseq-chat.api :as api]
            [logseq-chat.e2ee :as e2ee]
            [ocaml.Transit_core.Json :as transit]
            [ocaml.Stdlib :as stdlib]))

(type-record e2ee-keyring
  (crypto :e2ee-crypto)
  (load :fn<string;result<option<string>;string>>)
  (save :fn<string;string;result<unit;string>>)
  (load-password :fn<result<option<string>;string>>)
  (save-password :fn<string;result<unit;string>>)
  (fetch :fn<api-request;result<api-response;string>>)
  (keys :ref<map<string;string>>)
  (private-key :ref<option<string>>))

(defn create [crypto load save load-password save-password fetch]
  (record e2ee-keyring
    (crypto crypto) (load load) (save save)
    (load-password load-password) (save-password save-password) (fetch fetch)
    (keys (atom {})) (private-key (atom nil))))

(defn response-body [operation response]
  (let* [response response]
    (if (and (>= (:status response) 200) (< (:status response) 300))
      (Ok (:body response))
      (Error (str operation " returned HTTP " (:status response))))))

(defn protect [operation f]
  (try
    (Ok (f))
    (catch (Failure message) (Error (str operation ": " message)))
    (catch (Yojson/Json_error message) (Error (str operation ": " message)))
    (catch error (Error (str operation ": " (Printexc/to-string error))))))

(defn remember [keyring graph-id key]
  (swap! (:keys keyring) assoc graph-id key)
  key)

(defn fetch-graph-key [keyring config]
  (let* [body (response-body "fetch graph E2EE key" ((:fetch keyring) (api/graph-key-request config)))]
    (protect "decode graph E2EE key" (fn [] (api/graph-key-from-body body)))))

(defn remember-graph-key [keyring config key]
  (let* [_ ((:save keyring) (:graph-id config) key)]
    (Ok (remember keyring (:graph-id config) key))))

(defn unlock-with-private-key [keyring config private-key]
  (let* [encrypted (fetch-graph-key keyring config)
         key (e2ee/decrypt-graph-key (:crypto keyring) private-key encrypted)]
    (remember-graph-key keyring config key)))

(defn unlock-with-password [keyring config password persist-password]
  (let* [body (response-body "fetch user E2EE keys" ((:fetch keyring) (api/user-keys-request config)))
         user-keys (protect "decode user E2EE keys" (fn [] (api/user-keys-from-body body)))
         private-key (e2ee/decrypt-private-key (:crypto keyring) password (:encrypted-private-key user-keys))
         encrypted (fetch-graph-key keyring config)
         key (e2ee/decrypt-graph-key (:crypto keyring) private-key encrypted)
         _ (if persist-password ((:save-password keyring) password) (Ok (stdlib/ignore 0)))
         key (remember-graph-key keyring config key)]
    (reset! (:private-key keyring) (Some private-key))
    (Ok key)))

(defn unlock-cached-account [keyring config]
  (if-some [private-key @(:private-key keyring)]
    (unlock-with-private-key keyring config private-key)
    (let* [password ((:load-password keyring))]
      (if-some [password password]
        (unlock-with-password keyring config password false)
        (Error "E2EE password is not cached")))))

(defn load-cached [keyring config]
  (let [graph-id (:graph-id config)]
    (if-some [key (get @(:keys keyring) graph-id)]
      (Ok key)
      (let* [key ((:load keyring) graph-id)]
        (if-some [key key]
          (Ok (remember keyring graph-id key))
          (unlock-cached-account keyring config))))))

(defn unlock [keyring config password]
  (unlock-with-password keyring config password true))

(defn provision [keyring config]
  (let* [body (response-body "fetch user E2EE keys" ((:fetch keyring) (api/user-keys-request config)))
         user-keys (protect "decode user E2EE keys" (fn [] (api/user-keys-from-body body)))
         [key encrypted] (e2ee/prepare-graph-key (:crypto keyring) (:public-key user-keys))
         _ (response-body "upload graph E2EE key" ((:fetch keyring) (api/upsert-graph-key-request config encrypted)))]
    (remember-graph-key keyring config key)))

(defn graph-key [keyring graph-id]
  (if-some [key (get @(:keys keyring) graph-id)]
    (Ok key)
    (Error "encrypted graph is locked")))

(defn encrypt-title [keyring graph-id title]
  (let* [key (graph-key keyring graph-id)]
    (e2ee/encrypt-value (:crypto keyring) key (transit/String title))))

(defn encrypt-asset [keyring graph-id bytes]
  (let* [key (graph-key keyring graph-id)]
    (e2ee/encrypt-value (:crypto keyring) key (transit/Binary bytes))))

(defn decrypt-title [keyring graph-id ciphertext]
  (let* [key (graph-key keyring graph-id)]
    (e2ee/decrypt-string (:crypto keyring) key ciphertext)))
