(ns logseq-chat.mobile-database
  (:require [logseq-chat.mobile-graph :as graph]
            [logseq-chat.sqlite :as sqlite]
            [logseq-chat.cache-model :as model]
            [ocaml.Filename :as filename]
            [ocaml.Stdlib :as stdlib]))

(type-record mobile-database
  (graph :graph/mobile-graph)
  (catalog :ref<option<sqlite/sqlite-session>>)
  (projection :ref<option<sqlite/sqlite-session>>))

(defn create [graph]
  (record mobile-database (graph graph) (catalog (atom nil)) (projection (atom nil))))

(defn- close-projection [database]
  (when-some [projection @(:projection database)] (sqlite/close projection))
  (reset! (:projection database) nil)
  (stdlib/ignore 0))

(defn close [database]
  (when-some [catalog @(:catalog database)] (sqlite/close catalog))
  (reset! (:catalog database) nil)
  (close-projection database)
  (reset! (:current (:graph database)) nil)
  (stdlib/ignore 0))

(defn open-catalog [database path]
  (close database)
  (let [catalog (sqlite/open-session path)]
    (reset! (:catalog database) (Some catalog))
    catalog))

(defn model-for-graph [database graph-id]
  (if-some [opened @(:current (:graph database))]
    (if (= (:graph-id opened) graph-id)
      (do
        (close-projection database)
        (let [path (filename/concat (filename/dirname (:checkpoint-path opened)) "projection.sqlite")
              projection (sqlite/open-session path)]
          (try
            (let [storage (sqlite/storage projection)]
              (when (empty? ((:storage-list-addresses storage)))
                (when-some [catalog @(:catalog database)]
                  (sqlite/migrate-datascript-storage catalog projection)))
              (let [model (model/create (Some storage))]
                (reset! (:projection database) (Some projection))
                model))
            (catch error (sqlite/close projection) (throw error)))))
      (model/create nil))
    (model/create nil)))
