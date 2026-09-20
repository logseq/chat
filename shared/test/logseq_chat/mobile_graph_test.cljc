(ns logseq-chat.mobile-graph-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.mobile-graph :as mobile]
            [logseq-chat.mobile-database :as database]
            [logseq-chat.sqlite :as sqlite]
            [logseq-chat.cache-model :as model]
            [logseq-chat.graph-runtime :as runtime]
            [logseq-chat.flashcards :as cards]
            [logseq-chat.graph-store :as store]
            [logseq-chat.graph-bootstrap :as bootstrap]
            [logseq-chat.sync-checkpoint :as checkpoint]
            [logseq-chat.sync-session :as sync]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Transit_core.Json :as value]
            [ocaml.Transit_native.Transit.Json :as transit]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]))

(defn expect-ok [result]
  (match result (Ok value) value (Error message) (throw (Failure message))))

(defn error? [result] (match result (Error _) true _ false))

(defn remove-tree [path]
  (when (sys/file-exists path)
    (if (sys/is-directory path)
      (do (run! #(remove-tree (filename/concat path %)) (sys/readdir path)) (unix/rmdir path))
      (sys/remove path)))
  (stdlib/ignore 0))

(defn with-directory [f]
  (let [path (filename/temp-file "chat-mobile-graph" "")]
    (sys/remove path)
    (unix/mkdir path 493)
    (try (f path) (finally (remove-tree path)))))

(defn database []
  (ds/empty-db :schema bootstrap/native-schema :storage (ds/memory-storage)))

(defn prepare-graph [dir]
  (let [active (filename/concat dir "graph.sqlite") saved (filename/concat dir "checkpoint")]
    (store/prepare-staging active)
    (ds/store :storage (store/storage active) (database))
    (expect-ok (checkpoint/save-checkpoint-atomic saved (checkpoint/create "graph" "1" 7)))))

(defn open-fields [dir encrypted]
  [(tuple "graphId" (tag String "graph"))
   (tuple "activePath" (tag String (filename/concat dir "graph.sqlite")))
   (tuple "checkpointPath" (tag String (filename/concat dir "checkpoint")))
   (tuple "isEncrypted" (tag Bool encrypted))])

(defn json-object [fields] (json/to-string (tag Assoc (apply list fields))))

(defn open-payload [dir encrypted] (json-object (open-fields dir encrypted)))

(defn crypto [require-key]
  (record mobile/graph-crypto (require-key require-key)
          (encrypt-title (fn [_ title] (Ok title))) (decrypt-title (fn [_ title] (Ok title)))))

(defn host [] (mobile/create (crypto (fn [_] (Ok (stdlib/ignore 0))))))

(defn expect-opened [value]
  (if-some [value value] value (throw (Failure "graph was not opened"))))

(deftest asset-path-resolution-follows-the-current-graph
  (with-directory
    (fn [dir]
      (prepare-graph dir)
      (let [host (host) relative "assets/photo.jpg"
            absolute (filename/concat dir "photo.jpg")]
        (is (= relative (mobile/resolve-asset-path host relative)))
        (is (= absolute (mobile/resolve-asset-path host absolute)))
        (expect-ok (mobile/open-graph host (open-payload dir false)))
        (is (= (filename/concat (filename/dirname (filename/dirname dir)) relative)
               (mobile/resolve-asset-path host relative)))
        (is (= absolute (mobile/resolve-asset-path host absolute)))
        (reset! (:current host) nil)
        (is (= relative (mobile/resolve-asset-path host relative)))))))

(deftest unopened-host-preserves-query-and-command-defaults
  (let [host (host)]
    (is (nil? (mobile/sync-cursor host)))
    (is (nil? (mobile/blocks host)))
    (is (nil? (mobile/authoritative-blocks host)))
    (is (nil? (mobile/sidebar-pages host)))
    (is (nil? (mobile/tag-pages host)))
    (is (nil? (mobile/blocks-for-page host "missing")))
    (is (nil? (mobile/node-destination host "missing")))
    (is (nil? (mobile/objects-for-tag host "missing")))
    (is (nil? (mobile/references-for-node host "missing")))
    (is (not (mobile/node-is-tag host "missing")))
    (is (not (mobile/node-is-property host "missing")))
    (is (= (tuple ["one" "two"] []) (mobile/normalize-titles host "missing" ["one" "two"])))
    (is (= [] (mobile/search host "anything")))
    (is (= [] (mobile/due-flashcards host 0)))
    (is (= [] (mobile/pending-operations host)))
    (is (nil? (mobile/journal-page-uuid host 20260916)))
    (is (not (mobile/has-older-journals host)))
    (mobile/load-older-journals host)
    (is (= (Error "graph runtime is not open")
           (mobile/set-page-favorite host "missing" true "favorite" 0)))
    (is (= (Error "graph runtime is not open")
           (mobile/delete-page host "missing" "delete" 0)))
    (is (= (Error "graph runtime is not open")
           (mobile/review-flashcard host "missing" cards/Good 0 "review")))))

(deftest unopened-graph-models-are-isolated-and-do-not-open-projections
  (let [database (database/create (host))
        first-model (database/model-for-graph database "missing")]
    (model/cache-local-message first-model "draft" "Local" 100)
    (is (some? (model/read-block first-model "draft")))
    (is (nil? (model/read-block (database/model-for-graph database "missing") "draft")))
    (is (nil? @(:projection database)))))

(deftest graph-projection-migrates-storage-but-keeps-catalog-metadata
  (with-directory
    (fn [dir]
      (prepare-graph dir)
      (let [host (host) database (database/create host)
            catalog (database/open-catalog database (filename/concat dir "catalog.sqlite"))]
        (try
          (let [legacy (model/create (Some (sqlite/storage catalog)))]
            (model/cache-local-message legacy "draft" "From catalog" 100))
          (sqlite/store-string catalog "catalog-marker" "keep")
          (expect-ok (mobile/open-graph host (open-payload dir false)))
          (let [projection-model (database/model-for-graph database "graph")]
            (is (= (Some "From catalog") (some-> (model/read-block projection-model "draft") :title)))
            (is (= (Some "keep") (sqlite/restore-string catalog "catalog-marker")))
            (is (= ["catalog-marker"] (sqlite/list-addresses catalog)))
            (is (sys/file-exists (filename/concat dir "projection.sqlite"))))
          (finally (database/close database)))))))

(deftest existing-projection-is-reused-without-reimporting-catalog
  (with-directory
    (fn [dir]
      (prepare-graph dir)
      (let [host (host) database (database/create host)
            catalog (database/open-catalog database (filename/concat dir "catalog.sqlite"))]
        (try
          (expect-ok (mobile/open-graph host (open-payload dir false)))
          (let [first-model (database/model-for-graph database "graph")
                first-projection (expect-opened @(:projection database))]
            (model/cache-local-message first-model "draft" "Keep projection" 100)
            (is (nil? (model/read-block (database/model-for-graph database "another-graph") "draft")))
            (is (not @(:closed first-projection)))
            (model/cache-local-message (model/create (Some (sqlite/storage catalog)))
                                       "draft" "Do not overwrite" 100)
            (let [reopened (database/model-for-graph database "graph")]
              (is @(:closed first-projection))
              (is (= (Some "Keep projection") (some-> (model/read-block reopened "draft") :title)))
              (is (not (empty? (sqlite/list-addresses catalog))))))
          (finally (database/close database)))))))

(deftest failed-catalog-open-leaves-no-closed-session-installed
  (with-directory
    (fn [dir]
      (let [database (database/create (host))
            previous (database/open-catalog database (filename/concat dir "catalog.sqlite"))]
        (try
          (is (thrown? Failure
                (database/open-catalog database (filename/concat dir "missing/catalog.sqlite"))))
          (is @(:closed previous))
          (is (nil? @(:catalog database)))
          (is (nil? @(:projection database)))
          (finally (database/close database)))))))

(deftest catalog-reopen-closes-connections-and-clears-the-open-graph
  (with-directory
    (fn [dir]
      (prepare-graph dir)
      (let [host (host) database (database/create host)
            first-catalog (database/open-catalog database (filename/concat dir "first.sqlite"))]
        (try
          (expect-ok (mobile/open-graph host (open-payload dir false)))
          (database/model-for-graph database "graph")
          (let [projection (expect-opened @(:projection database))
                second-catalog (database/open-catalog database (filename/concat dir "second.sqlite"))]
            (is @(:closed first-catalog))
            (is @(:closed projection))
            (is (not @(:closed second-catalog)))
            (is (nil? @(:projection database)))
            (is (nil? @(:current host))))
          (finally (database/close database)))))))

(deftest opened-host-reads-live-runtime-and-observes-close
  (with-directory
    (fn [dir]
      (prepare-graph dir)
      (let [host (host)]
        (expect-ok (mobile/open-graph host (open-payload dir false)))
        (let [opened (expect-opened @(:current host)) current (:read-runtime opened)]
          (is (= (Some 7) (mobile/sync-cursor host)))
          (is (= (Some (runtime/blocks current)) (mobile/blocks host)))
          (is (= (Some []) (mobile/authoritative-blocks host)))
          (is (= (Some (runtime/sidebar-pages current)) (mobile/sidebar-pages host)))
          (is (= (Some (runtime/tag-pages current)) (mobile/tag-pages host)))
          (is (= (Some []) (mobile/blocks-for-page host "missing")))
          (is (= (Some []) (mobile/objects-for-tag host "missing")))
          (is (= (Some []) (mobile/references-for-node host "missing")))
          (is (= (runtime/search current "missing") (mobile/search host "missing")))
          (is (= (runtime/due-flashcards current 0) (mobile/due-flashcards host 0)))
          (is (= (runtime/pending-operations current) (mobile/pending-operations host)))
          (let [operation (expect-opened (first (mobile/pending-operations host)))]
            (reset! (:current host) nil)
            (is (nil? (mobile/blocks host)))
            (is (= (Error "graph runtime is not open") (mobile/stage host operation)))
            (is (= (Error "graph runtime is not open") (mobile/prepare-sync host operation)))))))))

(defn event-payload [event data]
  (json-object [(tuple "type" (tag String event)) (tuple "data" (tag String (transit/to-string data)))]))

(defn change-event [before after]
  (event-payload "graph-changes"
    (value/Map (list (tuple (value/Keyword "format-version") (value/Int 1))
                     (tuple (value/Keyword "graph-id") (value/String "graph"))
                     (tuple (value/Keyword "schema-version") (value/String "1"))
                     (tuple (value/Keyword "t-before") (value/Int before))
                     (tuple (value/Keyword "t") (value/Int after))
                     (tuple (value/Keyword "upserts") (value/Array (list)))
                     (tuple (value/Keyword "deleted") (value/Array (list)))
                     (tuple (value/Keyword "operation-ids") (value/Array (list)))))))

(defn snapshot-request [dir encrypted db]
  (let [rows (expect-ok (bootstrap/snapshot-rows db))
        download (filename/concat dir "snapshot") channel (stdlib/open-out-bin download)
        metadata (json-object [(tuple "ok" (tag Bool true)) (tuple "url" (tag String "snapshot"))
                               (tuple "t" (tag Int 12)) (tuple "schema-version" (tag String "1"))
                               (tuple "row-count" (tag Int (count rows)))])]
    (try (stdlib/output-string channel (bootstrap/frame-rows rows)) (finally (stdlib/close-out channel)))
    (json-object (into (open-fields dir encrypted)
                       [(tuple "metadataBody" (tag String metadata)) (tuple "downloadPath" (tag String download))]))))

(deftest open-validates-checkpoint-before-accessing-keys
  (with-directory
    (fn [dir]
      (let [calls (atom 0) host (mobile/create (crypto (fn [_] (swap! calls inc) (Error "locked"))))
            saved (filename/concat dir "checkpoint")]
        (is (= (Error "graph checkpoint is missing") (mobile/open-graph host (open-payload dir true))))
        (expect-ok (checkpoint/save-checkpoint-atomic saved (checkpoint/create "other" "1" 7)))
        (is (= (Error "graph checkpoint belongs to another graph") (mobile/open-graph host (open-payload dir true))))
        (is (= 0 @calls))
        (is (nil? @(:current host)))))))

(deftest plaintext-open-restores-cursor-search-and-today-without-key-access
  (with-directory
    (fn [dir]
      (prepare-graph dir)
      (let [calls (atom 0) host (mobile/create (crypto (fn [_] (swap! calls inc) (Error "locked"))))]
        (expect-ok (mobile/open-graph host (open-payload dir false)))
        (let [opened (expect-opened @(:current host))]
          (is (= "graph" (:graph-id opened)))
          (is (= 7 (sync/applied-server-t (:state opened))))
          (is (= 7 (:server-t (runtime/state (:read-runtime opened)))))
          (is (not (empty? (runtime/pending-operations (:read-runtime opened)))))
          (is (sys/file-exists (filename/concat dir "search/db.sqlite"))))
        (is (= 0 @calls))))))

(deftest failed-reopen-keeps-the-previous-runtime
  (with-directory
    (fn [dir]
      (prepare-graph dir)
      (let [host (mobile/create (crypto (fn [_] (Error "locked"))))]
        (expect-ok (mobile/open-graph host (open-payload dir false)))
        (let [opened (expect-opened @(:current host))]
          (is (= (Error "locked") (mobile/open-graph host (open-payload dir true))))
          (is (identical? opened (expect-opened @(:current host))))
          (is (error? (mobile/open-graph host "{")))
          (is (identical? opened (expect-opened @(:current host)))))))))

(deftest restoring-a-broken-database-fails-before-key-access
  (with-directory
    (fn [dir]
      (let [calls (atom 0) host (mobile/create (crypto (fn [_] (swap! calls inc) (Error "locked"))))]
        (expect-ok (checkpoint/save-checkpoint-atomic (filename/concat dir "checkpoint")
                                                       (checkpoint/create "graph" "1" 7)))
        (store/prepare-staging (filename/concat dir "graph.sqlite"))
        (is (= (Error "graph storage has no DataScript root")
               (mobile/open-graph host (open-payload dir true))))
        (is (= 0 @calls))
        (is (nil? @(:current host)))))))

(deftest encrypted-open-requires-the-selected-key-and-configures-title-encryption
  (with-directory
    (fn [dir]
      (prepare-graph dir)
      (let [keys (atom [])
            host (mobile/create
                   (record mobile/graph-crypto
                           (require-key (fn [graph] (swap! keys conj graph) (Ok (stdlib/ignore 0))))
                           (encrypt-title (fn [graph title] (Ok (str graph ":" title))))
                           (decrypt-title (fn [_ title] (Ok title)))))]
        (expect-ok (mobile/open-graph host (open-payload dir true)))
        (is (= ["graph"] @keys))
        (let [opened (expect-opened @(:current host))]
          (is (:e2ee opened))
          (is (= (Ok "graph:private") ((:encrypt-title (:read-runtime opened)) "private"))))))))

(deftest reset-and-invalid-events-do-not-require-an-open-graph
  (let [host (host)]
    (is (= (Error "graph runtime is not open") (mobile/apply-sync-event host (change-event 7 8))))
    (is (= (Error "snapshot required: expired")
           (mobile/apply-sync-event host
             (event-payload "reset" (value/Map (list (tuple (value/Keyword "reason") (value/String "expired"))
                                                    (tuple (value/Keyword "snapshot-required") (value/Bool true))))))))
    (is (= (Error "WebSocket sync event must be an object") (mobile/apply-sync-event host "null")))))

(deftest sync-events-persist-cursor-and-rebase-the-read-runtime
  (with-directory
    (fn [dir]
      (prepare-graph dir)
      (let [host (host)]
        (expect-ok (mobile/open-graph host (open-payload dir false)))
        (expect-ok (mobile/apply-sync-event host (change-event 7 8)))
        (let [opened (expect-opened @(:current host))]
          (is (= 8 (sync/applied-server-t (:state opened))))
          (is (= 8 (:server-t (runtime/state (:read-runtime opened)))))
          (is (= (Ok (Some (checkpoint/create "graph" "1" 8)))
                 (checkpoint/load-checkpoint (:checkpoint-path opened))))
          (is (= (Error "sync cursor mismatch") (mobile/apply-sync-event host (change-event 6 9))))
          (is (= 8 (sync/applied-server-t (:state opened))))
          (is (= 8 (:server-t (runtime/state (:read-runtime opened))))))))))

(deftest snapshot-import-activates-a-real-snapshot-and-reopens-it
  (with-directory
    (fn [dir]
      (let [payload (snapshot-request dir false (database))
            host (host)]
        (expect-ok (mobile/import-snapshot host payload))
        (is (= 12 (sync/applied-server-t (:state (expect-opened @(:current host))))))
        (expect-ok (store/restore-db (filename/concat dir "graph.sqlite")))
        (let [opened (expect-opened @(:current host))]
          (is (error? (mobile/import-snapshot host "{}")))
          (is (identical? opened (expect-opened @(:current host)))))))))

(deftest encrypted-import-decrypts-before-opening-the-local-graph
  (with-directory
    (fn [dir]
      (let [encrypted (ds/db-with (list (ds/Add (ds/Entity_id 1) "block/title" (ds/String "cipher:Private"))) (database))
            decryptions (atom [])
            host (mobile/create
                   (record mobile/graph-crypto
                           (require-key (fn [_] (Ok (stdlib/ignore 0))))
                           (encrypt-title (fn [_ title] (Ok (str "cipher:" title))))
                           (decrypt-title (fn [graph title]
                                            (swap! decryptions conj graph)
                                            (if (string/starts-with? title "cipher:")
                                              (Ok (subs title 7)) (Error "invalid ciphertext"))))))]
        (expect-ok (mobile/import-snapshot host (snapshot-request dir true encrypted)))
        (is (= ["graph"] @decryptions))
        (let [db (expect-ok (store/restore-db (filename/concat dir "graph.sqlite")))]
          (is (= [(ds/String "Private")] (mapv :v (db-api/datoms db (ds/Eavt) :e 1 :a "block/title")))))
        (is (:e2ee (expect-opened @(:current host))))))))

(deftest invalid-snapshot-does-not-replace-the-open-runtime-or-checkpoint
  (with-directory
    (fn [dir]
      (prepare-graph dir)
      (let [host (host) download (filename/concat dir "invalid-snapshot")
            channel (stdlib/open-out-bin download)
            metadata "{\"ok\":true,\"url\":\"snapshot\",\"t\":12,\"schema-version\":\"1\",\"row-count\":5}"
            payload (json-object (into (open-fields dir false)
                                      [(tuple "metadataBody" (tag String metadata)) (tuple "downloadPath" (tag String download))]))]
        (try (stdlib/output-string channel "broken") (finally (stdlib/close-out channel)))
        (expect-ok (mobile/open-graph host (open-payload dir false)))
        (let [opened (expect-opened @(:current host))]
          (is (error? (mobile/import-snapshot host payload)))
          (is (identical? opened (expect-opened @(:current host))))
          (is (= (Ok (Some (checkpoint/create "graph" "1" 7)))
                 (checkpoint/load-checkpoint (:checkpoint-path opened))))
          (expect-ok (store/restore-db (filename/concat dir "graph.sqlite"))))))))
