(ns logseq-chat.model-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.cache-model :as model]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript_lg :as typed-db]
            [ocaml.Stdlib :as stdlib]))

(def now 1776000000000)

(defn block [uuid title page created]
  (record model/block
    (uuid uuid) (title title) (page-id page) (parent-id None) (order None)
    (created-at created) (updated-at created) (sync-status "synced")
    (tags (list)) (references (list)) (breadcrumbs (list)) (status None)
    (is-asset false) (asset-type None) (asset-size None) (asset-checksum None)
    (local-path None) (journal None)))

(defn read-block [cache uuid]
  (or (model/read-block cache uuid) (stdlib/failwith (str "missing block " uuid))))

(defn ok? [result] (match result (Ok _) true (Error _) false))

(defn ids [blocks] (mapv :uuid blocks))

(deftest recent-captures-keep-the-newest-hundred-in-order
  (let [cache (model/create None)]
    (run! (fn [index]
            (model/cache-local-message cache (str "local-" index) (str "Capture " index) (+ now index)))
          (range 105))
    (let [recent (model/recent-blocks cache)]
      (is (= 100 (count recent)))
      (is (= "local-5" (:uuid (first recent))))
      (is (= "Capture 5" (:title (first recent))))
      (is (= "local-104" (:uuid (last recent))))
      (is (= "Capture 104" (:title (last recent)))))))

(deftest refresh-selection-and-outliner-orphans
  (let [cache (model/create None)
        row (fn [uuid parent order]
              (assoc (block uuid uuid "page" 1) :parent-id (Some parent) :order (Some order)))
        rows [(row "orphan" "missing" "a2") (row "root" "page" "a1")
              (row "child" "root" "a0") (row "cycle-a" "cycle-b" "a3") (row "cycle-b" "cycle-a" "a4")]]
    (model/upsert-blocks cache [] 42)
    (is (= 0 (.-revision cache)))
    (is (= (Some 42) (.-last-refresh-at cache)))
    (is (= (Error "unknown block: missing") (model/select cache "missing")))
    (is (= ["root" "child" "orphan" "cycle-a" "cycle-b"] (ids (model/outliner-preorder "page" rows))))
    (model/upsert-blocks cache rows 43)
    (is (ok? (model/select cache "child")))
    (is (= "child" (:uuid (or (model/selected-block cache) (stdlib/failwith "missing selection")))))
    (model/clear-selection cache)
    (is (nil? (model/selected-block cache)))))

(deftest partial-refresh-preserves-timestamps-and-journal-relation
  (let [cache (model/create None)]
    (model/cache-local-message cache "stable-created-at" "Original" now)
    (model/upsert-blocks cache [(block "stable-created-at" "Updated remotely" "page-1" 0)] (+ now 10000))
    (let [restored (read-block cache "stable-created-at")]
      (is (= now (:created-at restored))) (is (= now (:updated-at restored)))))
  (let [cache (model/create None) original (block "search-block" "Before search" "journal-1" 100)]
    (model/upsert-journal-page cache "journal-1" 20260813 "Aug 13th, 2026")
    (model/upsert-blocks cache [original] 100)
    (model/upsert-blocks cache [(assoc original :title "Search result" :page-id "" :created-at 0 :updated-at 0)] 200)
    (let [recent (model/recent-blocks cache)]
      (is (= 1 (count recent)))
      (is (= "journal-1" (:page-id (first recent))))
      (is (= "Search result" (:title (first recent)))))))

(deftest recent-journals-filter-pages-empty-and-future-blocks
  (let [cache (model/create None)]
    (model/upsert-blocks cache [(block "empty-block" "   " "journal-1" 200)
                                (block "real-block" "Visible" "journal-1" 100)] 400)
    (model/upsert-journal-page cache "journal-1" 20260813 "")
    (is (= ["real-block"] (ids (model/recent-blocks cache))))
    (is (= ["empty-block"]
           (ids (model/visible-from cache [(assoc (block "empty-block" "" "journal-1" 100)
                                                 :journal (Some (tuple "Aug 22nd, 2026" 20260822)))])))))
  (let [cache (model/create None)]
    (model/upsert-journal-page cache "past-journal" 20260812 "")
    (model/upsert-journal-page cache "future-journal" 20990101 "")
    (model/upsert-blocks cache [(block "past-block" "past-block" "past-journal" 300)
                                (block "future-block" "future-block" "future-journal" 400)
                                (block "ordinary-page-block" "ordinary-page-block" "ordinary-page" 500)] 600)
    (is (= ["past-block"] (ids (model/recent-blocks cache))))))

(deftest journal-rows-follow-tree-order-not-timestamps
  (let [cache (model/create None)
        row (fn [uuid parent order created]
              (assoc (block uuid uuid "journal-today" created) :parent-id (Some parent) :order (Some order)))]
    (model/upsert-journal-page cache "journal-today" 20260815 "")
    (model/upsert-blocks cache [(row "second-root" "journal-today" "a2" 100)
                                (assoc (block "other-page" "Other" "project" 500) :parent-id (Some "project") :order (Some "a0"))
                                (row "child" "first-root" "a0" 300) (row "first-root" "journal-today" "a1" 400)] 500)
    (is (= ["first-root" "child" "second-root"] (ids (model/recent-blocks cache))))))

(deftest local-task-and-asset-metadata-survive-caching
  (let [cache (model/create None)
        status (record model/status (uuid "status-waiting") (ident (Some "user.status/waiting")) (title "Waiting")
                       (icon-type (Some "tabler-icon")) (icon-id (Some "clock")) (icon-color (Some "#7c3aed")))]
    (model/cache-local-task cache "task-local" "Follow up" status now)
    (model/cache-local-asset cache "asset-local" "voice.m4a" "m4a" 4096 "checksum" "/documents/voice.m4a" (inc now) None)
    (is (= "Waiting" (:title (or (:status (read-block cache "task-local")) (stdlib/failwith "missing status")))))
    (is (= (Some "m4a") (:asset-type (read-block cache "asset-local"))))
    (is (= (Some "/documents/voice.m4a") (:local-path (read-block cache "asset-local"))))))

(deftest targeted-assets-and-transcripts-inherit-the-editing-page
  (let [cache (model/create None)]
    (model/upsert-blocks cache [(assoc (block "editing-block" "Editing" "page-target" 100) :parent-id (Some "page-target"))] 100)
    (model/cache-local-asset cache "audio-asset" "Audio.m4a" "m4a" 4096 "checksum" "/documents/Audio.m4a" 200 (Some "editing-block"))
    (is (= "page-target" (:page-id (read-block cache "audio-asset"))))
    (is (= (Some "editing-block") (:parent-id (read-block cache "audio-asset"))))
    (is (ok? (model/cache-local-child cache "transcript" "Transcript" "audio-asset" 201)))
    (is (= "page-target" (:page-id (read-block cache "transcript"))))
    (is (= (Some "audio-asset") (:parent-id (read-block cache "transcript"))))))

(deftest uploaded-assets-merge-local-metadata-into-server-identity
  (let [cache (model/create None)]
    (model/cache-local-asset cache "local-asset" "photo.jpg" "jpg" 2048 "checksum" "/documents/photo.jpg" now None)
    (model/upsert-blocks cache [(assoc (block "server-asset" "photo" "remote-journal" (+ now 100)) :parent-id (Some "remote-journal"))] (+ now 100))
    (is (ok? (model/reconcile-created-block cache "local-asset" "server-asset" "submitted")))
    (is (nil? (model/read-block cache "local-asset")))
    (let [asset (read-block cache "server-asset")]
      (is (= (Some "/documents/photo.jpg") (:local-path asset)))
      (is (= (Some "checksum") (:asset-checksum asset)))
      (is (= "submitted" (:sync-status asset))))
    (is (= 1 (count (filter #(some? (:asset-type %)) (model/all-blocks cache)))))))

(deftest refresh-preserves-synced-asset-metadata-and-offline-edits
  (let [cache (model/create None)]
    (model/cache-local-asset cache "stable-asset" "photo.jpg" "jpg" 2048 "checksum" "/documents/photo.jpg" now None)
    (is (ok? (model/mark-block-synced cache "stable-asset")))
    (model/upsert-blocks cache [(block "stable-asset" "photo.jpg" "journal/2026-08-15" now)] (+ now 100))
    (let [asset (read-block cache "stable-asset")]
      (is (= (Some "jpg") (:asset-type asset))) (is (= (Some "checksum") (:asset-checksum asset)))
      (is (= (Some "/documents/photo.jpg") (:local-path asset)))))
  (let [cache (model/create None) original (block "offline-edit" "Server title" "journal/2026-08-15" now)]
    (model/upsert-blocks cache [original] now)
    (is (ok? (model/update-block-title cache "offline-edit" "Edited offline" (+ now 100))))
    (model/upsert-blocks cache [original] (+ now 200))
    (is (= "Edited offline" (:title (read-block cache "offline-edit"))))
    (is (= "pending" (:sync-status (read-block cache "offline-edit"))))))

(deftest local-captures-use-journals-and-remain-retryable-after-failure
  (let [cache (model/create None)]
    (model/cache-local-message cache "local-test" "Capture note" now)
    (let [captured (read-block cache "local-test")]
      (is (not= "local-pending" (:page-id captured)))
      (is (string/starts-with? (:page-id captured) "journal/"))
      (is (= "pending" (:sync-status captured))))
    (is (ok? (model/mark-block-synced cache "local-test")))
    (is (= "synced" (:sync-status (read-block cache "local-test"))))
    (model/cache-local-message cache "local-failed" "Capture failed" (inc now))
    (is (ok? (model/mark-block-sync-failed cache "local-failed")))
    (is (= "failed" (:sync-status (read-block cache "local-failed"))))
    (is (some #(= "local-failed" (:uuid %)) (model/pending-blocks cache))))
  (let [cache (model/create None)]
    (model/cache-local-message cache "local-block" "Offline capture" now)
    (is (ok? (model/reconcile-created-block cache "local-block" "server-block" "submitted")))
    (is (nil? (model/read-block cache "local-block")))
    (is (= "Offline capture" (:title (read-block cache "server-block"))))
    (is (= "submitted" (:sync-status (read-block cache "server-block"))))))

(deftest missing-attributes-default-but-malformed-attributes-raise
  (let [cache (model/create None)]
    (model/commit cache [(ds/Add (ds/Temp_id "minimal") "block/uuid" (ds/String "minimal"))])
    (let [minimal (read-block cache "minimal")]
      (is (= "" (:title minimal))) (is (= 0 (:created-at minimal)))
      (is (= "synced" (:sync-status minimal))) (is (nil? (:asset-size minimal))))
    (is (nil? (model/read-block cache "absent"))))
  (run! (fn [[attr value]]
          (let [cache (model/create None)]
            (set! (.-db cache) (ds/empty-db :schema (list (nth model/schema 0))))
            (model/commit cache [(ds/Add (ds/Temp_id "invalid") "block/uuid" (ds/String "invalid"))
                                 (ds/Add (ds/Temp_id "invalid") attr value)])
            (is (try (do (model/read-block cache "invalid") false)
                     (catch (typed-db/Invalid_data error) (string/starts-with? (:path error) attr))))))
        [(tuple "block/title" (ds/Int 42)) (tuple "block/created-at" (ds/Float 1.5))
         (tuple "block/asset-size" (ds/String "large")) (tuple "block/local-path" (ds/Bool false))]))
