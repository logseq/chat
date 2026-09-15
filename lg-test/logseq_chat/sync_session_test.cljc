(ns logseq-chat.sync-session-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [lg.literal :as literal]
            [logseq-chat.sync-session :as session]
            [logseq-chat.sync-checkpoint :as checkpoint]
            [logseq-chat.sync-protocol :as protocol]
            [logseq-chat.snapshot :as snapshot]
            [logseq-chat.graph-store :as store]
            [logseq-chat.storage-codec :as codec]
            [logseq-chat.graph-bootstrap :as bootstrap]
            [ocaml.Transit_native.Transit.Json :as transit]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Filename :as filename]
            [ocaml.Sys :as sys]
            [ocaml.Stdlib :as stdlib]))

(defn expect-ok [result]
  (match result (Ok value) value (Error message) (stdlib/failwith message)))

(defn error? [result] (match result (Error _) true (Ok _) false))

(defmacro transit-data [form]
  `(literal/build {:map transit/Map :vector transit/Array :keyword transit/Keyword
                   :string transit/String :int transit/Int} ~form))

(defn fixture-wire [title]
  (let [root (transit-data
              {:schema {:block/title {:db/valueType :db.type/string}}
               :max-eid 1 :max-tx 536870913 :eavt 2 :aevt 3 :avet 4
               :max-addr 4 :branching-factor 512 :ref-type :soft})
        leaf (transit-data {:keys [[1 :block/title (unquote (transit/String title)) 536870913]]})
        rows (mapv (fn [[addr value]]
                     (record snapshot/snapshot-row
                             (addr addr) (content (transit/to-string :mode (transit/Verbose) value))
                             (addresses None)))
                   [(tuple 0 root) (tuple 1 (transit/Array (list)))
                    (tuple 2 leaf) (tuple 3 leaf) (tuple 4 leaf)])]
    (bootstrap/frame-rows (apply list rows))))

(defn write-file! [path content]
  (let [channel (stdlib/open-out-bin path)]
    (try (stdlib/output-string channel content)
         (finally (stdlib/close-out-noerr channel)))))

(defn with-files [f]
  (let [active (filename/temp-file "logseq-chat-session" ".sqlite")
        saved (filename/temp-file "logseq-chat-session" ".checkpoint")
        download (filename/temp-file "logseq-chat-session" ".snapshot")]
    (sys/remove active)
    (sys/remove saved)
    (try (f active saved download)
         (finally
           (run! #(when (sys/file-exists %) (sys/remove %))
                 [active (store/staging-path active) saved (str saved ".tmp") download])))))

(deftest metadata-rejects-invalid-fields
  (run! #(is (error? (session/decode-snapshot-metadata %)))
        ["[]" "{\"ok\":false}" "{\"url\":\"snapshot\"}"
         "{\"ok\":true,\"url\":\"\",\"t\":0,\"schema-version\":\"1\",\"row-count\":0}"
         "{\"ok\":true,\"url\":\"snapshot\",\"t\":-1,\"schema-version\":\"1\",\"row-count\":0}"
         "{\"ok\":true,\"url\":\"snapshot\",\"t\":0,\"schema-version\":\"1\",\"row-count\":-1}"
         "{\"ok\":true,\"url\":\"snapshot\",\"t\":0,\"schema-version\":\"1\",\"row-count\":0,\"content-encoding\":false}"
         "{\"ok\":true,\"url\":\"snapshot\",\"t\":0,\"schema-version\":\"1\",\"row-count\":0,\"content-encoding\":\"\"}"]))

(deftest metadata-encoding-is-optional
  (run! (fn [suffix]
          (let [body (str "{\"ok\":true,\"url\":\"snapshot\",\"t\":0,\"schema-version\":\"1\",\"row-count\":0" suffix "}")
                metadata (expect-ok (session/decode-snapshot-metadata body))]
            (is (nil? (:content-encoding metadata)))))
        ["" ",\"content-encoding\":null"]))

(defn saved-cursor [path]
  (some-> (expect-ok (checkpoint/load-checkpoint path)) :applied-server-t))

(deftest snapshot-import-failure-is-atomic-and-events-persist-cursor
  (let [body "{\"ok\":true,\"key\":\"stream/graph-1.snapshot\",\"url\":\"https://sync.example/sync/graph-1/snapshot/stream\",\"content-encoding\":\"gzip\",\"t\":48192,\"schema-version\":\"65.33\",\"row-count\":5}"
        metadata (expect-ok (session/decode-snapshot-metadata body))]
    (is (= 48192 (:baseline-t metadata)))
    (is (= 5 (:row-count metadata)))
    (is (= (Some "gzip") (:content-encoding metadata)))
    (with-files
      (fn [active saved download]
        (write-file! download (fixture-wire "Local title"))
        (let [completed (expect-ok (session/import-snapshot-file None "graph-1" active saved metadata download))
              original (expect-ok (store/read-row active 0))]
          (is (= 48192 (:applied-server-t completed)))
          (expect-ok (store/restore-db active))
          (is (= (Some 48192) (saved-cursor saved)))
          (write-file! download "\u0000\u0000\u0000\nbroken")
          (is (error? (session/import-snapshot-file None "graph-1" active saved metadata download)))
          (is (= original (expect-ok (store/read-row active 0))))
          (is (= (Some 48192) (saved-cursor saved)))
          (is (not (sys/file-exists (store/staging-path active))))
          (let [conn (expect-ok (store/restore-conn active))
                state (session/create-state "graph-1" "65.33" 48192)
                change (record protocol/sync-change-set
                               (format-version 1) (graph-id "graph-1") (schema-version "65.33")
                               (t-before 48192) (t 48193) (upserts (list)) (deleted (list))
                               (operation-ids (list)))]
            (expect-ok (session/apply-change-set #(Ok %) conn saved state change))
            (is (= 48193 (session/applied-server-t state)))
            (is (= (Some 48193) (saved-cursor saved)))))))))

(defn decrypt [value]
  (if (string/starts-with? value "cipher:")
    (Ok (subs value 7))
    (Error "expected encrypted snapshot title")))

(deftest encrypted-snapshot-persists-only-plaintext
  (with-files
    (fn [active saved download]
      (write-file! download (fixture-wire "cipher:Private title"))
      (let [metadata (record session/snapshot-metadata
                             (url "https://sync.example/snapshot") (content-encoding None)
                             (baseline-t 9) (schema-version "65.33") (row-count 5))]
        (expect-ok (session/import-snapshot-file (Some decrypt) "encrypted-graph" active saved metadata download))
        (let [db (expect-ok (store/restore-db active))]
          (is (= [(ds/String "Private title")] (mapv :v (db-api/datoms db (ds/Aevt) :a "block/title")))))
        (run! (fn [addr]
                (match (expect-ok (store/read-row active addr))
                  (Some [content _]) (is (not (string/includes? content "cipher:Private title")))
                  None (stdlib/failwith "stored address has no row")))
              (store/list-stored-addresses active))))))

(deftest encrypted-legacy-built-in-titles-are-also-decrypted
  (let [one codec/default-schema-attr
        schema (list (tuple "block/uuid" (assoc one :value-type (Some (ds/UuidType))))
                     (tuple "block/title" (assoc one :value-type (Some (ds/StringType))))
                     (tuple "logseq.property/built-in?" one))
        db (ds/db-with (list (ds/Add (ds/Entity_id 1) "block/title" (ds/String "cipher:Private title"))
                             (ds/Add (ds/Entity_id 2) "block/uuid" (ds/Uuid "00000002-0000-0000-0000-000000000001"))
                             (ds/Add (ds/Entity_id 2) "block/title" (ds/String "cipher:Card")))
                       (ds/empty-db :schema schema))
        plaintext (expect-ok (session/plaintext-snapshot-db decrypt db))]
    (run! (fn [[eid title]]
            (is (= [(ds/String title)] (mapv :v (db-api/datoms plaintext (ds/Eavt) :e eid :a "block/title")))))
          [(tuple 1 "Private title") (tuple 2 "Card")])))
