(ns logseq-chat.graph-projection
  (:require [logseq-chat.datascript-value :as ds-value]
            [logseq-chat.sync-protocol :as protocol]
            [ocaml.package/datascript-ocaml-native]
            [ocaml.Datascript :as ds]
            [ocaml.Logseq_chat_graph_read :as graph-read]
            [ocaml.Logseq_chat_model :as model]
            [ocaml.Transit_core.Json :as transit]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Rrbvec :as rrbvec]))

(type-record graph-projection
  (decrypt-title :fn<string;result<string;string>>)
  (recent-pages :ref<set<int>>)
  (blocks-by-uuid :ref<map<string;Logseq_chat_model.block>>))

(defn recent-pages [db]
  (set (graph-read/recent-journal-page-ids db)))

(defn read-blocks [decrypt-title db]
  (into {} (map (fn [block] (tuple (:uuid block) block))
               (graph-read/blocks :decrypt_title decrypt-title db))))

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
  (rrbvec/to-list
   (vec (sort (fn [left right] (graph-read/compare-journal-blocks left right))
              (vals @(:blocks-by-uuid projection))))))

(defn identity [value]
  (match value
    (transit/Array [(transit/Keyword "block/uuid") (transit/Uuid uuid)]) (Some (tuple :uuid uuid))
    (transit/Array [(transit/Keyword "db/ident") (transit/Keyword ident)]) (Some (tuple :ident ident))
    _ None))

(defn refresh-block [projection db uuid]
  (let [block
        (match (ds/entid db "block/uuid" (ds/Uuid uuid))
          None None
          (Some eid)
          (match (ds-value/optional-ref-eid db "block/page" (graph-read/value db eid "block/page"))
            (Some page-eid)
            (if (contains? @(:recent-pages projection) page-eid)
              (graph-read/block (:decrypt-title projection) db eid)
              None)
            None None))]
    (reset! (:blocks-by-uuid projection)
            (match block
              (Some block) (assoc @(:blocks-by-uuid projection) uuid block)
              None (dissoc @(:blocks-by-uuid projection) uuid)))
    (stdlib/ignore 0)))

(defn changed-identities [change]
  (let [^:set<string> empty-ids #{}]
    (reduce (fn [[uuids idents] value]
              (match (identity value)
                (Some (tuple :uuid uuid)) (tuple (conj uuids uuid) idents)
                (Some (tuple :ident ident)) (tuple uuids (conj idents ident))
                _ (tuple uuids idents)))
            (tuple empty-ids empty-ids)
            (concat (map :id (:upserts change)) (:deleted change)))))

(defn related-entity-changed? [changed-uuids ^:Logseq_chat_model.block block]
  (or (some (fn [summary] (contains? changed-uuids (:uuid summary))) (:tags block))
      (some (fn [summary] (contains? changed-uuids (:uuid summary))) (:references block))))

(defn status-changed? [changed-uuids changed-idents ^:Logseq_chat_model.block block]
  (match (:status block)
    None false
    (Some status)
    (or (contains? changed-uuids (:uuid status))
        (match (:ident status)
          None false
          (Some ident) (contains? changed-idents ident)))))

(defn update [projection db change]
  (if (not= @(:recent-pages projection) (recent-pages db))
    (rebuild projection db)
    (let [[changed-uuids changed-idents] (changed-identities change)
          affected (reduce (fn [^:set<string> affected ^:Logseq_chat_model.block block]
                             (if (or (contains? changed-uuids (:page-id block))
                                     (related-entity-changed? changed-uuids block)
                                     (status-changed? changed-uuids changed-idents block))
                               (conj affected (:uuid block))
                               affected))
                           changed-uuids
                           (vals @(:blocks-by-uuid projection)))]
      (stdlib/ignore (run! (fn [uuid] (refresh-block projection db uuid)) affected)))))
