(ns logseq-chat.mobile-payload-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.sync-protocol :as protocol]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson :as yojson]
            [ocaml.Transit_core.Json :as value]
            [ocaml.Transit_native.Transit.Json :as codec]
            [logseq-chat.mobile-payload :as payload]))

(def open-fields "\"graphId\":\"g\",\"activePath\":\"graph.sqlite\",\"checkpointPath\":\"sync.checkpoint\"")

(deftest open-graph-preserves-fields-and-encryption-default
  (run! (fn [[suffix encrypted]]
          (match (payload/decode-open (str "{" open-fields suffix "}"))
            (Ok request)
            (do (is (= "g" (:graph-id request)))
                (is (= "graph.sqlite" (:active-path request)))
                (is (= "sync.checkpoint" (:checkpoint-path request)))
                (is (= encrypted (:e2ee request))))
            (Error _) (is false)))
        [(tuple "" false) (tuple ",\"isEncrypted\":false" false) (tuple ",\"isEncrypted\":true" true)]))

(deftest explicit-null-is-not-an-absent-encryption-flag
  (run! (fn [value]
          (is (= (Error "graph sync payload requires a boolean isEncrypted")
                 (payload/decode-open (str "{" open-fields ",\"isEncrypted\":" value "}")))))
        ["null" "0" "\"true\"" "[]" "{}"])
  (is (= (Error "graph sync payload requires graphId") (payload/decode-open "{\"isEncrypted\":null}"))))

(deftest required-paths-preserve-validation-order
  (run! (fn [[body field]]
          (is (= (Error (str "graph sync payload requires " field)) (payload/decode-open body))))
        [(tuple "{}" "graphId") (tuple "{\"graphId\":\"\"}" "graphId")
         (tuple "{\"graphId\":1}" "graphId") (tuple "{\"graphId\":\"g\"}" "activePath")
         (tuple "{\"graphId\":\"g\",\"activePath\":\"a\"}" "checkpointPath")]))

(deftest snapshot-import-validates-download-before-encryption
  (is (= (Error "graph sync payload requires metadataBody")
         (payload/decode-import (str "{" open-fields ",\"isEncrypted\":null}"))))
  (is (= (Error "graph sync payload requires downloadPath")
         (payload/decode-import (str "{" open-fields ",\"metadataBody\":\"{}\",\"isEncrypted\":null}"))))
  (match (payload/decode-import (str "{" open-fields ",\"metadataBody\":\"{}\",\"downloadPath\":\"download.bin\",\"isEncrypted\":true}"))
    (Ok request)
    (do (is (= "g" (:graph-id request)))
        (is (= "{}" (:metadata-body request)))
        (is (= "download.bin" (:download-path request)))
        (is (:e2ee request)))
    (Error _) (is false)))

(deftest graph-commands-reject-non-object-and-malformed-json
  (run! (fn [body]
          (is (= (Error "openGraph payload must be an object") (payload/decode-open body)))
          (is (= (Error "importSnapshot payload must be an object") (payload/decode-import body))))
        ["null" "[]" "42" "\"text\""])
  (is (match (payload/decode-open "{")
        (Error message) (string/includes? message "Json_error") _ false))
  (is (match (payload/decode-import "{")
        (Error message) (string/includes? message "Json_error") _ false)))

(defn event-payload [event data]
  (json/to-string (tag Assoc (list (tuple "type" (tag String event))
                                 (tuple "data" (tag String data))))))

(deftest sync-event-envelope-preserves-validation-order
  (run! (fn [[body expected]]
          (is (= (Error expected) (payload/decode-sync-event body))))
        [(tuple "null" "WebSocket sync event must be an object")
         (tuple "[]" "WebSocket sync event must be an object")
         (tuple "{}" "graph sync payload requires type")
         (tuple "{\"type\":null,\"data\":\"wire\"}" "graph sync payload requires type")
         (tuple "{\"type\":\"\",\"data\":\"wire\"}" "graph sync payload requires type")
         (tuple "{\"type\":\"reset\"}" "graph sync payload requires data")
         (tuple "{\"type\":\"reset\",\"data\":{}}" "graph sync payload requires data")
         (tuple "{\"type\":\"reset\",\"data\":\"\"}" "graph sync payload requires data")]))

(deftest sync-event-envelope-decodes-transit-and-propagates-protocol-errors
  (let [wire (codec/to-string
               (value/Map (list (tuple (value/Keyword "reason") (value/String "cursor-expired"))
                                (tuple (value/Keyword "snapshot-required") (value/Bool true)))))]
    (is (= (Ok (protocol/Reset (record protocol/sync-reset
                                      (reason "cursor-expired") (snapshot-required true))))
           (payload/decode-sync-event (event-payload "reset" wire)))))
  (is (= (Error "unsupported sync event: unknown")
         (payload/decode-sync-event (event-payload "unknown" "wire"))))
  (is (= (protocol/decode-event "graph-changes" "malformed")
         (payload/decode-sync-event (event-payload "graph-changes" "malformed")))))

(deftest sync-event-json-errors-remain-unwrapped
  (let [expected (try (json/from-string "{") "unexpected parse success"
                     (catch (yojson/Json_error message) message))]
    (is (= (Error expected) (payload/decode-sync-event "{")))))

(deftest database-open-preserves-path-without-requiring-api-version
  (is (= (Some "graph.sqlite")
         (payload/database-open-path "{\"method\":\"open\",\"params\":{\"path\":\"graph.sqlite\"}}")))
  (is (= (Some "")
         (payload/database-open-path "{\"apiVersion\":1,\"method\":\"open\",\"params\":{\"path\":\"\"}}"))))

(deftest database-open-ignores-other-requests-and-invalid-envelopes
  (run! (fn [body] (is (nil? (payload/database-open-path body))))
        ["{" "null" "[]" "{}"
         "{\"method\":\"snapshot\",\"params\":{\"path\":\"graph.sqlite\"}}"
         "{\"method\":\"open\"}"
         "{\"method\":\"open\",\"params\":null}"
         "{\"method\":\"open\",\"params\":{}}"
         "{\"method\":\"open\",\"params\":{\"path\":null}}"
         "{\"method\":\"open\",\"params\":{\"path\":42}}"
         "{\"method\":\"open\",\"params\":{\"path\":[]}}"]))

(deftest database-open-uses-the-first-duplicate-field
  (is (= (Some "first.sqlite")
         (payload/database-open-path "{\"method\":\"open\",\"params\":{\"path\":\"first.sqlite\",\"path\":\"second.sqlite\"}}")))
  (is (nil? (payload/database-open-path "{\"method\":null,\"method\":\"open\",\"params\":{\"path\":\"graph.sqlite\"}}")))
  (is (nil? (payload/database-open-path "{\"method\":\"open\",\"params\":null,\"params\":{\"path\":\"graph.sqlite\"}}")))
  (is (nil? (payload/database-open-path "{\"method\":\"open\",\"params\":{\"path\":null,\"path\":\"graph.sqlite\"}}"))))
