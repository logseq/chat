(ns logseq-chat.mobile-payload
  (:require [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson :as yojson]
            [logseq-chat.sync-protocol :as protocol]
            [ocaml.Printexc :as exceptions]))

(type-record open-graph-request
  (graph-id :string) (active-path :string) (checkpoint-path :string) (e2ee :bool))

(type-record import-snapshot-request
  (graph-id :string) (active-path :string) (checkpoint-path :string)
  (metadata-body :string) (download-path :string) (e2ee :bool))

(defn field [fields name]
  (some (fn [[key value]] (when (= key name) value)) fields))

(defn database-open-path [payload]
  (try
    (match (json/from-string payload)
      (tag Assoc fields)
      (match (tuple (field fields "method") (field fields "params"))
        (tuple (Some (tag String "open")) (Some (tag Assoc params)))
        (match (field params "path") (Some (tag String path)) (Some path) _ nil)
        _ nil)
      _ nil)
    (catch _ nil)))

(defn required-string [fields name]
  (match (field fields name)
    (Some (tag String value))
    (if (empty? value) (Error (str "graph sync payload requires " name)) (Ok value))
    _ (Error (str "graph sync payload requires " name))))

(defn optional-bool [fields name]
  (match (field fields name)
    (Some (tag Bool value)) (Ok value)
    None (Ok false)
    _ (Error (str "graph sync payload requires a boolean " name))))

(defn decode-open [payload]
  (try
    (match (json/from-string payload)
      (tag Assoc fields)
      (let* [graph-id (required-string fields "graphId")
             active-path (required-string fields "activePath")
             checkpoint-path (required-string fields "checkpointPath")
             e2ee (optional-bool fields "isEncrypted")]
        (Ok (record open-graph-request
                    (graph-id graph-id) (active-path active-path) (checkpoint-path checkpoint-path) (e2ee e2ee))))
      _ (Error "openGraph payload must be an object"))
    (catch error (Error (exceptions/to-string error)))))

(defn decode-import [payload]
  (try
    (match (json/from-string payload)
      (tag Assoc fields)
      (let* [graph-id (required-string fields "graphId")
             active-path (required-string fields "activePath")
             checkpoint-path (required-string fields "checkpointPath")
             metadata-body (required-string fields "metadataBody")
             download-path (required-string fields "downloadPath")
             e2ee (optional-bool fields "isEncrypted")]
        (Ok (record import-snapshot-request
                    (graph-id graph-id) (active-path active-path) (checkpoint-path checkpoint-path)
                    (metadata-body metadata-body) (download-path download-path) (e2ee e2ee))))
      _ (Error "importSnapshot payload must be an object"))
    (catch error (Error (exceptions/to-string error)))))

(defn decode-sync-event [payload]
  (try
    (match (json/from-string payload)
      (tag Assoc fields)
      (let* [event (required-string fields "type")
             data (required-string fields "data")]
        (protocol/decode-event event data))
      _ (Error "WebSocket sync event must be an object"))
    (catch (yojson/Json_error message) (Error message))))
