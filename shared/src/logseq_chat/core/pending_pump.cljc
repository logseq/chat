(ns logseq-chat.pending-pump
  (:require [clojure.string :as string]
            [logseq-chat.session-types :as types]
            [logseq-chat.session-outliner :as so]
            [logseq-chat.rpc :as rpc]
            [logseq-chat.api :as api]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Printexc :as exceptions]))

(defn pending-request-json [session]
  (if-some [active (:semantic-active (types/state session))]
    (rpc/request-json (:id active) (:request active) nil "application/json" [])
    (if-some [pump (:pending-sync (types/state session))]
      (if-some [active @(:active pump)]
        (match (:transport active)
          (types/Json-request request) (rpc/request-json (:id active) request nil "application/json" [])
          (types/File-upload upload) (rpc/request-json (:id active) (:request upload) (Some (:file-path upload))
                                                 (:content-type upload) (:headers upload)))
        (tag Null))
      (tag Null))))

(defn pending-block-unchanged [session sent]
  (if-some [current (model/read-block (:model (types/state session)) (:uuid sent))] (rpc/same-pending-version? sent current) false))

(defn mark-pending-failed! [session block]
  (when (pending-block-unchanged session block) (model/mark-block-sync-failed (:model (types/state session)) (:uuid block))))

(defn set-pending-active! [session pump transport operation cleanup]
  (let [next-id (inc (:next-pending-request-id (types/state session)))]
    (swap! (:state session) assoc :next-pending-request-id next-id)
    (reset! (:active pump) (Some (record types/pending-active (id next-id) (transport transport) (operation operation) (cleanup-path cleanup))))))

(defn encrypted-title [session config title]
  (if-some [encrypt (:encrypt-title (types/host session))] (encrypt (:graph-id config) title)
           (Error "encrypted graph title encryption is unavailable")))

(defn prepare-pending-create-request [session pump block title page-id]
  (let [config (:config pump)]
    (match (tuple (:status block) (:local-path block) (:asset-type block) (:asset-size block) (:asset-checksum block))
      (tuple (Some status) _ _ _ _)
      (do (set-pending-active! session pump (types/Json-request (api/task-request page-id config (:uuid block) (:uuid status) title))
                               (types/Create-block block) nil)
          (Ok (stdlib/ignore 0)))
      (tuple None (Some source) (Some asset-type) (Some _) (Some checksum))
      (let [source ((:resolve-asset-path (types/host session)) source)]
        (if (so/selected-graph-is-encrypted session)
          (if-some [encrypt (:encrypt-asset-file (types/host session))]
            (let* [[path _] (encrypt (:graph-id config) source)]
              (set-pending-active! session pump
                                   (types/File-upload (api/raw-asset-upload-request config (:uuid block) asset-type checksum path "text/plain"))
                                   (types/Upload-asset block) (Some path))
              (Ok (stdlib/ignore 0)))
            (Error "encrypted asset encryption is unavailable"))
          (do (set-pending-active! session pump
                                   (types/File-upload (api/raw-asset-upload-request config (:uuid block) asset-type checksum source
                                                                              (api/content-type-for-asset-type asset-type)))
                                   (types/Upload-asset block) nil)
              (Ok (stdlib/ignore 0)))))
      (tuple None None None None None)
      (let [request (match (:parent-id block)
                      (Some parent) (if (not= parent (:page-id block))
                                      (api/child-block-request config parent (:uuid block) title)
                                      (api/capture-request page-id config (:uuid block) title))
                      None (api/capture-request page-id config (:uuid block) title))]
        (set-pending-active! session pump (types/Json-request request) (types/Create-block block) nil)
        (Ok (stdlib/ignore 0)))
      _ (Error "pending block has incomplete semantic REST metadata"))))

(defn prepare-pending-creation [session pump block]
  (if (so/selected-graph-is-encrypted session)
    (let* [title (encrypted-title session (:config pump) (:title block))]
      (let [day (model/journal-day-for-ms (:created-at block))
            page (or (get @(:resolved-journal-pages pump) day)
                     (when-some [find (:journal-page-id (types/host session))] (find day)))]
        (if-some [page page]
          (prepare-pending-create-request session pump block title (Some page))
          (let [page (rpc/journal-page-uuid day) journal-title (rpc/journal-day-title day)
                encrypted-journal-title (encrypted-title session (:config pump) journal-title)
                encrypted-name (encrypted-title session (:config pump) (string/lower-case journal-title))]
            (let* [journal-title encrypted-journal-title journal-name encrypted-name]
              (set-pending-active! session pump
                                   (types/Json-request (api/encrypted-journal-page-request (:config pump) page journal-title journal-name day))
                                   (types/Create-journal (record types/created-journal (block block) (encrypted-title title) (page-id page) (journal-day day))) nil)
              (Ok (stdlib/ignore 0)))))))
    (prepare-pending-create-request session pump block (:title block)
                                    (when (some? (:parent-id block)) (Some (:page-id block))))))

(defn prepare-pending-block [session pump block]
  (if (contains? (:authoritative pump) (:uuid block))
    (let* [title (if (so/selected-graph-is-encrypted session) (encrypted-title session (:config pump) (:title block)) (Ok (:title block)))]
      (set-pending-active! session pump (types/Json-request (api/update-block-request (:config pump) (:uuid block) title))
                           (types/Update-title block) nil)
      (Ok (stdlib/ignore 0)))
    (prepare-pending-creation session pump block)))

(defn prepare-pending-next! [session pump]
  (if-some [block (first @(:remaining pump))]
    (do (swap! (:remaining pump) #(subvec % 1))
        (match (prepare-pending-block session pump block)
          (Ok _) (stdlib/ignore 0)
          (Error message)
          (do (types/debug (str "prepare pending block failed uuid=" (:uuid block) " message=" message))
              (mark-pending-failed! session block)
              (prepare-pending-next! session pump))))
    (do (reset! (:active pump) nil) (swap! (:state session) assoc :pending-sync nil) (stdlib/ignore 0))))

(defn activate-semantic-request [session config accepted]
  (let [s (types/state session)]
    (when (nil? (:semantic-active s))
      (when-some [pending (first (:semantic-queue s))]
        (when-some [prepare (:prepare-operation (types/host session))]
          (match (prepare (:operation pending))
            (Error message) (types/debug (str "semantic operation id=" (:operation-id (:operation pending))
                                        " is waiting for authoritative dependencies: " message))
            (Ok (tuple outliner-op tx))
            (let [operation (:operation pending)
                  latest (or (types/submission-server-t session) (:base-t operation))
                  before (if-some [accepted accepted] (max latest accepted) latest)
                  tx-id (match (:intent operation) (ops/Create-asset asset) (:uuid asset) _ (:operation-id operation))
                  request (api/tx-batch-request config before tx-id outliner-op tx)
                  next-id (inc (:next-pending-request-id s))]
              (stdlib/ignore
               (swap! (:state session) assoc :next-pending-request-id next-id
                      :semantic-queue (subvec (:semantic-queue s) 1)
                      :semantic-active (Some (record types/semantic-active (id next-id) (pending pending) (request request)))))))))))
  (stdlib/ignore 0))

(defn enqueue-semantic [session operation]
  (match (tuple (:stage-operation (types/host session)) (:prepare-operation (types/host session)))
    (tuple (Some stage) (Some _))
    (let* [_ (stage operation)]
      (swap! (:state session) update :semantic-queue conj (record types/semantic-pending (operation operation)))
      (Ok (stdlib/ignore 0)))
    _ (Error "projected graph operations are unavailable")))

(defn normalize-operation-titles [session operation]
  (let [normalizer (when-some [normalize (:graph-normalize-titles (types/host session))]
                     (Some (fn [uuid titles]
                             (let [[titles tags] (normalize uuid (apply list titles))]
                               (tuple (vec titles) (mapv (fn [[uuid title]] [uuid title]) tags))))))]
    (rpc/normalize-operation-titles normalizer types/fresh-squuid types/now-ms operation)))

(defn capture-operations [session uuid title now status]
  (rpc/capture-operations (types/projection-server-t session) uuid title now status
                          #(so/base-outliner-context session) (:journal-page-id (types/host session)) types/fresh-squuid
                          #(normalize-operation-titles session %)))

(defn enqueue-capture [session uuid title now status]
  (let* [operations (capture-operations session uuid title now status)]
    (reduce (fn [result operation] (let* [_ result] (enqueue-semantic session operation))) (Ok (stdlib/ignore 0)) operations)))

(defn restore-semantic-queue! [session]
  (when-some [pending (:pending-operations (types/host session))]
    (let [active (when-some [active (:semantic-active (types/state session))] (Some (:operation-id (:operation (:pending active)))))]
      (swap! (:state session) assoc :semantic-queue
             (mapv (fn [operation] (record types/semantic-pending (operation operation)))
                   (filter #(not= active (Some (:operation-id %))) (pending)))))))

(defn begin-pending-sync! [session config]
  (when (not (string/blank? (:token config)))
    (restore-semantic-queue! session)
    (let [pending (model/pending-blocks (:model (types/state session)))
          assets (filterv :is-asset pending)]
      (when (empty? assets) (activate-semantic-request session config nil))
      (let [s (types/state session)]
        (when (and (nil? (:semantic-active s)) (nil? (:pending-sync s)))
          (let [authoritative (set (map :uuid (or (when-some [load (:authoritative-graph-blocks (types/host session))] (load)) (list))))
                pump (record types/pending-sync (config config) (remaining (atom (if (empty? assets) pending assets)))
                             (authoritative authoritative) (resolved-journal-pages (atom {})) (active (atom nil)))]
            (swap! (:state session) assoc :pending-sync (Some pump))
            (prepare-pending-next! session pump))))))
  (stdlib/ignore 0))

(defn finish-semantic-active! [session active succeeded accepted]
  (let [next-state (cond (not succeeded) ops/Retryable
                         (some? accepted) (match accepted (Some t) (ops/Accepted t) None ops/Submitted)
                         :else ops/Submitted)]
    (when-some [stage (:stage-operation (types/host session))] (stage (assoc (:operation (:pending active)) :state next-state)))
    (when succeeded (when-some [accepted accepted] (types/record-accepted-server-t! session accepted)))
    (swap! (:state session) assoc :semantic-active nil)
    (when succeeded (when-some [config (:config (types/state session))] (activate-semantic-request session config accepted)))
    (stdlib/ignore 0)))

(defn cleanup-pending-active! [session active]
  (when-some [path (:cleanup-path active)] ((:cleanup-file (types/host session)) path)))

(defn finish-pending-block! [session pump block succeeded]
  (if succeeded
    (when (pending-block-unchanged session block) (model/mark-block-submitted (:model (types/state session)) (:uuid block)))
    (mark-pending-failed! session block))
  (reset! (:active pump) nil)
  (prepare-pending-next! session pump))

(defn asset-datoms-operation [session block status]
  (rpc/asset-datoms-operation (types/projection-server-t session) status block #(so/base-outliner-context session)
                              (:journal-page-id (types/host session))))

(defn reconcile-created-block! [session pump block remote-uuid]
  (model/reconcile-created-block (:model (types/state session)) (:uuid block) remote-uuid
                                 (if (pending-block-unchanged session block) "submitted" "pending"))
  (reset! (:active pump) nil)
  (prepare-pending-next! session pump))

(defn complete-pending-active! [session pump active response]
  (if-not (<= 200 (:status response) 299)
    (finish-pending-block! session pump (types/transport-operation-block (:operation active)) false)
    (match (:operation active)
      (types/Update-title block)
      (if-some [status (:status block)]
        (do (set-pending-active! session pump
                                (types/Json-request (api/update-block-status-request (:config pump) (:uuid block) (:uuid status)))
                                (types/Update-status block) nil)
            (stdlib/ignore 0))
        (finish-pending-block! session pump block true))

      (types/Update-status block)
      (finish-pending-block! session pump block true)

      (types/Create-journal journal)
      (do (swap! (:resolved-journal-pages pump) assoc (:journal-day journal) (:page-id journal))
          (reset! (:active pump) nil)
          (match (prepare-pending-create-request session pump (:block journal) (:encrypted-title journal) (Some (:page-id journal)))
            (Ok _) (stdlib/ignore 0)
            (Error message)
            (do (types/debug (str "prepare pending create after journal failed uuid=" (:uuid (:block journal)) " message=" message))
                (mark-pending-failed! session (:block journal))
                (prepare-pending-next! session pump))))

      (types/Upload-asset block)
      (match (asset-datoms-operation session block ops/Queued)
        (Error message)
        (do (types/debug (str "prepare asset datoms failed uuid=" (:uuid block) " message=" message))
            (finish-pending-block! session pump block false))
        (Ok operation)
        (match (enqueue-semantic session operation)
          (Error message)
          (do (types/debug (str "stage asset datoms failed uuid=" (:uuid block) " message=" message))
              (finish-pending-block! session pump block false))
          (Ok _)
          (do (let [queue (:semantic-queue (types/state session))
                    asset? (fn [pending] (= (:operation-id (:operation pending)) (:operation-id operation)))]
                (swap! (:state session) assoc :semantic-queue (into (filterv asset? queue) (remove asset? queue))))
              (finish-pending-block! session pump block true)
              (activate-semantic-request session (:config pump) nil))))

      (types/Create-block block)
      (match (try (Ok (api/created-block-uuid-from-body (:body response)))
                  (catch error (Error (exceptions/to-string error))))
        (Error message)
        (do (types/debug (str "pending creation response failed uuid=" (:uuid block) " message=" message))
            (finish-pending-block! session pump block false))
        (Ok remote)
        (match (tuple (:local-path block) (:parent-id block))
          (tuple (Some _) (Some parent))
          (do (set-pending-active! session pump (types/Json-request (api/move-block-request (:config pump) remote parent))
                                  (types/Move-created-asset (record types/moved-asset (block block) (remote-uuid remote))) nil)
              (stdlib/ignore 0))
          _ (reconcile-created-block! session pump block remote)))

      (types/Move-created-asset moved)
      (reconcile-created-block! session pump (:block moved) (:remote-uuid moved)))))

(defn accepted-transaction [body]
  (try
    (let [body (json/from-string body)]
      (match body
        (tag Assoc _)
        (let [rejected (= (json-util/member "type" body) (tag String "tx/reject"))
              accepted (match (tuple (json-util/member "acceptedT" body) (json-util/member "t" body))
                         (tuple (tag Int t) _) (Some t) (tuple _ (tag Int t)) (Some t) _ nil)]
          (tuple rejected accepted))
        _ (tuple false nil)))
    (catch _ (tuple false nil))))

(defn completion-error [input]
  (match (json-util/member "error" input)
    (tag String message) (when (not= message "") (Some message))
    _ nil))

(defn- validate-completion-id [input expected-id]
  (match input
    (tag Assoc _)
    (match (json-util/member "id" input)
      (tag Int id)
      (if (= id expected-id)
        (Ok id)
        (Error "pending sync request id does not match"))
      _ (Error "pending sync completion requires id"))
    _ (Error "pending sync completion must be an object")))

(defn parse-semantic-completion [input expected-id]
  (let* [_ (validate-completion-id input expected-id)]
    (if (some? (completion-error input))
      (Ok (tuple false nil))
      (match (json-util/member "status" input)
        (tag Int status)
        (let [[rejected accepted] (match (json-util/member "body" input)
                                    (tag String body) (accepted-transaction body)
                                    _ (tuple false nil))]
          (Ok (tuple (and (<= 200 status 299) (not rejected))
                     (if rejected nil accepted))))
        _ (Error "pending transport returned no HTTP status")))))

(defn parse-transport-completion [input expected-id]
  (let* [_ (validate-completion-id input expected-id)]
    (Ok (if-some [message (completion-error input)]
          (Error message)
          (match (json-util/member "status" input)
            (tag Int status)
            (Ok (record api/api-response
                  (status status)
                  (body (match (json-util/member "body" input) (tag String body) body _ ""))))
            _ (Error "pending transport returned no HTTP status"))))))

(defn- complete-semantic-response! [session active input]
  (try
    (let* [[succeeded accepted] (parse-semantic-completion input (:id active))]
      (finish-semantic-active! session active succeeded accepted)
      (Ok (stdlib/ignore 0)))
    (catch error (Error (str "invalid pending sync completion: " (exceptions/to-string error))))))

(defn- complete-transport-response! [session pump active input]
  (try
    (let* [response (parse-transport-completion input (:id active))]
      (cleanup-pending-active! session active)
      (match response
        (Ok response) (complete-pending-active! session pump active response)
        (Error message)
        (do (types/debug (str "pending transport failed id=" (:id active) " message=" message))
            (finish-pending-block! session pump (types/transport-operation-block (:operation active)) false)))
      (Ok (stdlib/ignore 0)))
    (catch error (Error (str "invalid pending sync completion: " (exceptions/to-string error))))))

(defn complete-pending-sync [session payload]
  (let [input (json/from-string payload)
        id (match input (tag Assoc _) (match (json-util/member "id" input) (tag Int id) (when (> id 0) (Some id)) _ nil) _ nil)
        stale? (fn [expected] (if-some [id id] (< id expected) false))
        finished? (if-some [id id] (<= id (:next-pending-request-id (types/state session))) false)]
    (if-some [active (:semantic-active (types/state session))]
      (if (stale? (:id active))
        (Ok (stdlib/ignore 0))
        (complete-semantic-response! session active input))
      (if-some [pump (:pending-sync (types/state session))]
        (if-some [active @(:active pump)]
          (if (stale? (:id active))
            (Ok (stdlib/ignore 0))
            (complete-transport-response! session pump active input))
          (if finished? (Ok (stdlib/ignore 0)) (Error "pending sync has no active request")))
        (if finished? (Ok (stdlib/ignore 0)) (Error "pending sync is not active"))))))

(defn cancel-pending-sync! [session]
  (when-some [active (:semantic-active (types/state session))]
    (swap! (:state session) update :semantic-queue #(into [(:pending active)] %))
    (swap! (:state session) assoc :semantic-active nil))
  (when-some [pump (:pending-sync (types/state session))]
    (when-some [active @(:active pump)] (cleanup-pending-active! session active)))
  (swap! (:state session) assoc :pending-sync nil)
  (stdlib/ignore 0))
