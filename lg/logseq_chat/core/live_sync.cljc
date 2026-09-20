(ns logseq-chat.live-sync
  (:require [clojure.string :as string]
            [logseq-chat.api :as api]
            [logseq-chat.http :as http]
            [logseq-chat.graph-bootstrap :as bootstrap]
            [logseq-chat.sync-session :as session]
            [logseq-chat.graph-store :as store]
            [logseq-chat.graph-runtime :as runtime]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.fractional-order :as order]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Digest :as digest]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]))

(def contents-page-uuid "00000004-1690-2597-3200-000000000000")

(defn fail [step message] (throw (Failure (str step ": " message))))

(defn require-ok [step result]
  (match result (Ok value) value (Error message) (fail step message)))

(defn env [name]
  (if-some [value (sys/getenv-opt name)]
    (let [value (string/trim value)]
      (if (empty? value) (throw (Failure (str "missing required environment variable " name))) value))
    (throw (Failure (str "missing required environment variable " name)))))

(defn json-object [body]
  (try (let [input (json/from-string body)]
         (match input (tag Assoc _) input _ (throw (Failure (str "expected a JSON object: " body)))))
       (catch (Yojson/Json_error message) (throw (Failure (str "invalid JSON: " message))))))

(defn json-string [name input]
  (match (api/member name input) (tag String value) (Some value) _ nil))

(defn json-int [name input]
  (match (api/member name input) (tag Int value) (Some value) (tag Float value) (Some (int value)) _ nil))

(defn expect-response [step accepted result]
  (let [response (require-ok step result)]
    (if (some #(= % (:status response)) accepted) response
        (fail step (format "HTTP %d %s" (:status response) (:body response))))))

(defn expect [step accepted request]
  (expect-response step accepted (http/send request)))

(defn config [base-url token graph-id]
  (record api/api-config (base-url base-url) (token token) (graph-id graph-id) (graph-name nil)))

(defn write-temp [prefix contents]
  (let [path (filename/temp-file prefix ".bin") channel (stdlib/open-out-bin path)]
    (try (stdlib/output-string channel contents) (finally (stdlib/close-out channel)))
    path))

(defn remove-file [path] (try (sys/remove path) (catch _ (stdlib/ignore 0))))

(defn remove-tree [path]
  (try
    (when (sys/file-exists path)
      (if (sys/is-directory path)
        (do (run! #(remove-tree (filename/concat path %)) (sys/readdir path)) (unix/rmdir path))
        (sys/remove path)))
    (catch _ (stdlib/ignore 0)))
  (stdlib/ignore 0))

(defn with-temp-dir [prefix f]
  (let [path (filename/temp-file prefix "")]
    (sys/remove path)
    (unix/mkdir path 493)
    (try (f path) (finally (remove-tree path)))))

(defn absolute-url [base-url url]
  (cond
    (or (string/starts-with? url "http://") (string/starts-with? url "https://")) url
    (string/starts-with? url "/") (str (api/api-root (config base-url "" "")) url)
    :else url))

(defn merge-pull-cursor [metadata body]
  (try (let [input (json/from-string body)]
         (if (= (json-string "type" input) (Some "pull/ok"))
           (if-some [t (json-int "t" input)] (assoc metadata :baseline-t t) metadata)
           metadata))
       (catch _ metadata)))

(defn download-snapshot [cfg]
  (let [path (str "/sync/" (api/url-encode (:graph-id cfg)))
        response (expect "snapshot metadata" [200] (api/request cfg "GET" (str path "/snapshot/download") nil))
        metadata (require-ok "decode snapshot metadata" (session/decode-snapshot-metadata (:body response)))
        pull (expect "snapshot pull" [200] (api/request cfg "GET" (str path "/pull") nil))
        metadata (merge-pull-cursor metadata (:body pull))
        request (record api/api-request (method_ "GET")
                        (url (absolute-url (:base-url cfg) (:url metadata))) (body nil) (token (:token cfg)))
        stream (expect "snapshot stream" [200] request)]
    (when (empty? (:body stream)) (fail "snapshot stream" "empty snapshot body"))
    (tuple metadata (write-temp "logseq-chat-live-snapshot" (:body stream)))))

(defn import-downloaded [graph-id decrypt dir metadata download-path]
  (let [active-path (filename/concat dir "graph.sqlite") checkpoint (filename/concat dir "sync.checkpoint")]
    (require-ok "import snapshot" (session/import-snapshot-file decrypt graph-id active-path checkpoint metadata download-path))
    active-path))

(defn has-title? [db decrypt expected]
  (some (fn [datom]
          (match (:v datom)
            (ds/String value) (= expected (match (decrypt value) (Ok title) title (Error _) value))
            _ false))
        (db-api/datoms db (ds/Aevt) :a "block/title")))

(defn submit-tx [cfg current operation attempts]
  (when (<= attempts 0) (fail "tx/batch" "exhausted retries after stale cursor"))
  (let [[outliner-op tx] (require-ok "prepare outliner op" (runtime/prepare-sync current operation))
        request (api/tx-batch-request cfg (:server-t (runtime/state current)) (:operation-id operation) outliner-op tx)
        response (expect "tx/batch" [200 409] request)
        fields (json-object (:body response))]
    (match (tuple (json-string "type" fields) (json-int "t" fields) (json-string "reason" fields))
      (tuple (Some "tx/batch/ok") (Some t) _)
      (do (runtime/rebase current t [(:operation-id operation)] []) t)
      (tuple (Some "tx/reject") (Some t) (Some "stale"))
      (do (runtime/rebase current t [] []) (submit-tx cfg current operation (dec attempts)))
      _ (fail "tx/batch" (format "unexpected response HTTP %d %s" (:status response) (:body response))))))

(defn stage-insert [current page-uuid title]
  (let [intent (ops/Insert-block
                (record ops/pending-insert (uuid (runtime/fresh-uuid)) (title title)
                        (page-uuid page-uuid) (parent-uuid page-uuid)
                        (order (require-ok "fractional order" (order/between nil nil))) (created-at (api/epoch-ms))))
        operation (runtime/queued-operation current (runtime/fresh-uuid) intent)]
    (require-ok "stage insert" (runtime/stage current operation))
    operation))

(defn stage-asset [current page-uuid title asset-type asset-size asset-checksum]
  (let [uuid (runtime/fresh-uuid)
        intent (ops/Create-asset
                (record ops/pending-asset (uuid uuid) (title title) (page-uuid page-uuid) (parent-uuid page-uuid)
                        (order (require-ok "asset order" (order/between (Some "a0") nil)))
                        (created-at (api/epoch-ms)) (asset-type asset-type) (asset-size asset-size) (asset-checksum asset-checksum)))
        operation (runtime/queued-operation current (runtime/fresh-uuid) intent)]
    (require-ok "stage asset" (runtime/stage current operation))
    (tuple uuid operation)))

(defn ensure-user-keys [cfg]
  (expect "e2ee user keys" [200 201]
          (api/request cfg "POST" "/e2ee/user-keys"
                       (api/json-body [(tuple "public-key" (tag String "live-sync-public-key"))
                                       (tuple "encrypted-private-key" (tag String "live-sync-encrypted-private-key"))]))))

(defn upload [step request]
  (let [response (require-ok step (http/upload-file request))]
    (when (not (<= 200 (:status response) 299))
      (fail step (format "HTTP %d %s" (:status response) (:body response))))))

(defn create-and-upload [cfg name e2ee encrypt-text]
  (let [response (expect "create graph" [200 201] (api/create-graph-request cfg name bootstrap/schema-version e2ee))
        graph-id (or (json-string "graph-id" (json-object (:body response)))
                     (fail "create graph" (str "missing graph-id in " (:body response))))
        cfg (assoc cfg :graph-id graph-id)]
    (when e2ee (expect "e2ee graph aes key" [200 201] (api/upsert-graph-key-request cfg "live-sync-encrypted-aes-key")))
    (let [prepared (require-ok "prepare initial snapshot" (bootstrap/prepare graph-id e2ee encrypt-text))]
      (try (upload "initial snapshot upload" (api/initial-snapshot-upload-request cfg (:file-path prepared) (:checksum prepared)))
           (finally (remove-file (:file-path prepared)))))
    (let [listed (expect "list graphs" [200] (api/graphs-request cfg))
          graph (first (filter #(= (:id %) graph-id) (api/graphs-from-graphs-body (:body listed))))]
      (if-some [graph graph]
        (do (when (not= (:e2ee graph) e2ee) (fail "list graphs" "created graph encryption flag mismatch"))
            (when (not (:ready graph)) (fail "list graphs" "created graph is not ready after snapshot upload")))
        (fail "list graphs" (str "created graph is missing from GET /graphs: " (:body listed)))))
    cfg))

(defn upload-asset-file [cfg uuid asset-type checksum bytes content-type]
  (let [path (write-temp "logseq-chat-live-asset" bytes)]
    (try (upload "asset upload" (api/raw-asset-upload-request cfg uuid asset-type checksum path content-type))
         (finally (remove-file path)))))

(defn download-asset [cfg uuid asset-type]
  (expect "asset download" [200]
          (api/request cfg "GET" (str "/assets/" (api/url-encode (:graph-id cfg)) "/"
                                      (api/url-encode uuid) "." (api/url-encode asset-type)) nil)))

(defn asset-mismatch [expected actual]
  (str "expected " (pr-str expected) ", got " (pr-str actual)))

(defn verify-titles [cfg decrypt label block-title asset-title capture-title]
  (let [[metadata path] (download-snapshot cfg)]
    (try
      (with-temp-dir "logseq-chat-live-verify"
        (fn [dir]
          (let [verify-path (import-downloaded (:graph-id cfg) decrypt dir metadata path)
                db (require-ok "restore verified graph" (store/restore-db verify-path))
                decode (or decrypt (fn [value] (Ok value)))]
            (run! (fn [[step kind title]]
                    (when (not (has-title? db decode title))
                      (fail step (str "missing " kind " title after re-download: " title))))
                  [(tuple "verify outliner sync" "block" block-title)
                   (tuple "verify asset block" "asset" asset-title)
                   (tuple "verify capture sync" "capture" capture-title)])
            (println (str "ok " label " graph_id=" (:graph-id cfg) " t=" (:baseline-t metadata))))))
      (finally (remove-file path)))))

(defn run-mode [base-url token e2ee]
  (let [label (if e2ee "encrypted" "unencrypted")
        encrypt-text (fn [value] (Ok (if e2ee (str "enc:" value) value)))
        decrypt (fn [value] (Ok (if (and e2ee (string/starts-with? value "enc:")) (subs value 4) value)))
        cfg (config base-url token "")]
    (println (str "==> " label " graph create / download / outliner / asset"))
    (when e2ee (ensure-user-keys cfg))
    (let [name (format "live-%s-%d" (if e2ee "enc" "plain") (api/epoch-ms))
          cfg (create-and-upload cfg name e2ee encrypt-text)
          [metadata path] (download-snapshot cfg)]
      (try
        (with-temp-dir "logseq-chat-live-import"
          (fn [dir]
            (let [decrypt-protected (when e2ee (Some decrypt))
                  active-path (import-downloaded (:graph-id cfg) decrypt-protected dir metadata path)
                  conn (require-ok "restore graph" (store/restore-conn active-path))
                  current (runtime/create active-path (:baseline-t metadata) conn (assoc runtime/default-options :encrypt-title encrypt-text))
                  block-title (str "live-outliner-" label) asset-bytes (str "live-asset-" label)
                  asset-type "png" checksum (digest/to-hex (digest/string asset-bytes))
                  asset-title (str "live-asset-" label ".png") capture-title (str "live-capture-" label)]
              (when (nil? (ds/entid (ds/conn-db conn) "block/uuid" (ds/Uuid contents-page-uuid)))
                (fail "import snapshot" "Contents page is missing after snapshot import"))
              (submit-tx cfg current (stage-insert current contents-page-uuid block-title) 4)
              (let [[uuid operation] (stage-asset current contents-page-uuid asset-title asset-type (count asset-bytes) checksum)]
                (upload-asset-file cfg uuid asset-type checksum asset-bytes
                                   (if e2ee "text/plain" (api/content-type-for-asset-type asset-type)))
                (submit-tx cfg current operation 4)
                (let [downloaded (download-asset cfg uuid asset-type)]
                  (when (not= (:body downloaded) asset-bytes)
                    (fail "asset download" (asset-mismatch asset-bytes (:body downloaded))))))
              (expect "semantic capture" [200 201]
                      (api/capture-request (Some contents-page-uuid) cfg (runtime/fresh-uuid)
                                           (if e2ee (require-ok "encrypt capture" (encrypt-text capture-title)) capture-title)))
              (verify-titles cfg decrypt-protected label block-title asset-title capture-title))))
        (finally (remove-file path))))))

(defn run []
  (let [token (env "LOGSEQ_CHAT_LIVE_TOKEN")
        base-url (or (sys/getenv-opt "LOGSEQ_CHAT_LIVE_BASE_URL") "http://127.0.0.1:8787")]
    (run-mode base-url token false)
    (run-mode base-url token true)
    (println "live sync flows passed")))
