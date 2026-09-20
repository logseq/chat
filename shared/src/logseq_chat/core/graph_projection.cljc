(ns logseq-chat.graph-projection
  (:refer-clojure :exclude [identity update])
  (:require [logseq-chat.datascript-value :as ds-value]
            [logseq-chat.sync-protocol :as protocol]
            [ocaml.package/datascript-ocaml-native]
            [ocaml.Datascript :as ds]
            [logseq-chat.graph-read :as graph-read]
            [logseq-chat.cache-model :as model]
            [ocaml.Transit_core.Json :as transit]
            [ocaml.Stdlib :as stdlib]))

(type-record graph-projection
  (decrypt-title :fn<string;result<string;string>>)
  (recent-pages :ref<set<int>>)
  (blocks-by-uuid :ref<map<string;model/block>>))

(defn recent-pages [db]
  (set (graph-read/recent-journal-page-ids 7 db)))

(defn read-blocks [decrypt-title db]
  (into {} (map (fn [block] (tuple (:uuid block) block))
               (graph-read/blocks decrypt-title 7 db))))

(defn rebuild [projection db]
  (reset! (:recent-pages projection) (recent-pages db))
  (reset! (:blocks-by-uuid projection) {})
  (reset! (:blocks-by-uuid projection) (read-blocks (:decrypt-title projection) db))
  (stdlib/ignore 0))

(defn create [decrypt-title db]
  (record graph-projection
    (decrypt-title decrypt-title)
    (recent-pages (atom (recent-pages db)))
    (blocks-by-uuid (atom (read-blocks decrypt-title db)))))

(defn blocks [projection]
  (sort graph-read/compare-journal-blocks
        (vals @(:blocks-by-uuid projection))))

(defn identity [value]
  (match value
    (transit/Array [(transit/Keyword "block/uuid") (transit/Uuid uuid)]) (Some (tuple :uuid uuid))
    (transit/Array [(transit/Keyword "db/ident") (transit/Keyword ident)]) (Some (tuple :ident ident))
    _ nil))

(defn refresh-block [projection db uuid]
  (let [block (when-some [eid (ds/entid db "block/uuid" (ds/Uuid uuid))]
                (when-some [page-eid (ds-value/optional-ref-eid db "block/page" (graph-read/value db eid "block/page"))]
                  (when (contains? @(:recent-pages projection) page-eid)
                    (graph-read/block (:decrypt-title projection) db eid))))]
    (if-some [block block]
      (swap! (:blocks-by-uuid projection) assoc uuid block)
      (swap! (:blocks-by-uuid projection) dissoc uuid))
    (stdlib/ignore 0)))

(defn changed-identities [change]
  (reduce (fn [[uuids idents] value]
            (match (identity value)
              (Some (tuple :uuid uuid)) (tuple (conj uuids uuid) idents)
              (Some (tuple :ident ident)) (tuple uuids (conj idents ident))
              _ (tuple uuids idents)))
          [#{} #{}]
          (concat (map :id (:upserts change)) (:deleted change))))

(defn related-entity-changed? [changed-uuids block]
  (or (some (fn [summary] (contains? changed-uuids (:uuid summary))) (:tags block))
      (some (fn [summary] (contains? changed-uuids (:uuid summary))) (:references block))))

(defn status-changed? [changed-uuids changed-idents block]
  (if-some [status (:status block)]
    (or (contains? changed-uuids (:uuid status))
        (boolean (some->> (:ident status) (contains? changed-idents))))
    false))

(defn update [projection db change]
  (if (not= @(:recent-pages projection) (recent-pages db))
    (rebuild projection db)
    (let [[changed-uuids changed-idents] (changed-identities change)
          affected (reduce (fn [affected block]
                             (if (or (contains? changed-uuids (:page-id block))
                                     (related-entity-changed? changed-uuids block)
                                     (status-changed? changed-uuids changed-idents block))
                               (conj affected (:uuid block))
                               affected))
                           changed-uuids
                           (vals @(:blocks-by-uuid projection)))]
      (stdlib/ignore (run! (fn [uuid] (refresh-block projection db uuid)) affected)))))
