(ns logseq-chat.session-types
  (:require [logseq-chat.api :as api]
            [logseq-chat.flashcards :as cards]
            [logseq-chat.outliner-effects :as effects]
            [logseq-chat.graph-read :as graph]
            [logseq-chat.http :as http]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.outliner-state :as outliner]
            [logseq-chat.search-index :as search]
            [ocaml.Datascript :as ds]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]))

(type-variant pending-transport (Json-request :api/api-request) (File-upload :api/api-file-upload))

(type-record moved-asset (block :model/block) (remote-uuid :string))

(type-record created-journal
             (block :model/block) (encrypted-title :string) (page-id :string) (journal-day :int))

(type-variant transport-operation
              (Create-block :model/block) (Upload-asset :model/block) (Move-created-asset :moved-asset)
              (Update-title :model/block) (Update-status :model/block) (Create-journal :created-journal))

(type-record pending-active
             (id :int) (transport :pending-transport) (operation :transport-operation) (cleanup-path :option<string>))

(type-record pending-sync
             (config :api/api-config) (remaining :ref<vector<model/block>>) (authoritative :set<string>)
             (resolved-journal-pages :ref<map<int;string>>) (active :ref<option<pending-active>>))

(type-record semantic-pending (operation :ops/pending-operation))

(type-record semantic-active (id :int) (pending :semantic-pending) (request :api/api-request))

(type-record node-route
             (uuid :string) (is-tag :bool) (is-property :bool) (page :model/entity-summary)
             (zoom-to-block :bool) (related-blocks :vector<model/block>) (state :outliner/outliner-state))

(type-record host-options
             (storage :option<Datascript.storage>)
             (open-graph :option<fn<string;result<unit;string>>>)
             (import-snapshot :option<fn<string;result<unit;string>>>)
             (model-for-graph :option<fn<string;model/CacheModel>>)
             (apply-sync-event :option<fn<string;result<unit;string>>>)
             (sync-cursor :option<fn<option<int>>>)
             (graph-blocks :option<fn<option<list<model/block>>>>)
             (authoritative-graph-blocks :option<fn<option<list<model/block>>>>)
             (graph-sidebar-pages :option<fn<option<graph/sidebar-pages>>>)
             (graph-tag-pages :option<fn<option<list<model/entity-summary>>>>)
             (graph-node-is-tag :option<fn<string;bool>>)
             (graph-node-is-property :option<fn<string;bool>>)
             (graph-page-blocks :option<fn<string;option<list<model/block>>>>)
             (graph-node-destination :option<fn<string;option<tuple<model/entity-summary;bool>>>>)
             (graph-node-references :option<fn<string;option<list<model/block>>>>)
             (graph-tag-objects :option<fn<string;option<list<model/block>>>>)
             (graph-normalize-titles :option<fn<string;list<string>;tuple<list<string>;list<tuple<string;string>>>>>)
             (graph-search :option<fn<string;list<search/indexed-search-hit>>>)
             (graph-due-flashcards :option<fn<int;list<cards/due-card>>>)
             (graph-review-flashcard :option<fn<string;cards/flashcard-rating;int;string;result<unit;string>>>)
             (graph-set-page-favorite :option<fn<string;bool;string;int;result<unit;string>>>)
             (graph-delete-page :option<fn<string;string;int;result<unit;string>>>)
             (load-older-journals :option<fn<unit>>) (has-older-journals :option<fn<bool>>)
             (load-cached-graph-key :option<fn<api/api-config;result<unit;string>>>)
             (unlock-graph :option<fn<api/api-config;string;result<unit;string>>>)
             (provision-graph-key :option<fn<api/api-config;result<unit;string>>>)
             (graph-unlocked :option<fn<string;bool>>)
             (encrypt-title :option<fn<string;string;result<string;string>>>)
             (resolve-asset-path :fn<string;string>)
             (encrypt-asset-file :option<fn<string;string;result<tuple<string;int>;string>>>)
             (journal-page-id :option<fn<int;option<string>>>)
             (send :fn<api/api-request;result<api/api-response;string>>)
             (upload-file :fn<api/api-file-upload;result<api/api-response;string>>)
             (cleanup-file :fn<string;unit>)
             (stage-operation :option<fn<ops/pending-operation;result<unit;string>>>)
             (prepare-operation :option<fn<ops/pending-operation;result<tuple<string;string>;string>>>)
             (pending-operations :option<fn<list<ops/pending-operation>>>)
             (load-graph-catalog :option<fn<option<string>>>) (save-graph-catalog :option<fn<string;unit>>))

(type-record session-state
             (model :model/CacheModel) (config :option<api/api-config>) (available-graphs :vector<api/api-graph>)
             (related-blocks :vector<model/block>) (selected-sidebar-page :option<model/entity-summary>)
             (node-routes :vector<node-route>) (node-base-state :option<outliner/outliner-state>)
             (accepted-server-t :option<int>) (flashcards :vector<cards/due-card>)
             (search-results :vector<search/indexed-search-hit>) (search-query :string)
             (sync-connected :bool) (pending-sync :option<pending-sync>) (next-pending-request-id :int)
             (semantic-queue :vector<semantic-pending>) (semantic-active :option<semantic-active>)
             (outliner-state :outliner/outliner-state) (outliner-optimistic-blocks :option<vector<model/block>>)
             (outliner-commands :vector<effects/outliner-platform-command>) (outliner-revision :int))

(type-record session (host :host-options) (state :ref<session-state>))

(def default-options
  (record host-options
          (storage nil) (open-graph nil) (import-snapshot nil) (model-for-graph nil) (apply-sync-event nil)
          (sync-cursor nil) (graph-blocks nil) (authoritative-graph-blocks nil) (graph-sidebar-pages nil)
          (graph-tag-pages nil) (graph-node-is-tag nil) (graph-node-is-property nil) (graph-page-blocks nil)
          (graph-node-destination nil) (graph-node-references nil) (graph-tag-objects nil)
          (graph-normalize-titles nil) (graph-search nil) (graph-due-flashcards nil) (graph-review-flashcard nil)
          (graph-set-page-favorite nil) (graph-delete-page nil) (load-older-journals nil) (has-older-journals nil)
          (load-cached-graph-key nil) (unlock-graph nil) (provision-graph-key nil) (graph-unlocked nil)
          (encrypt-title nil) (resolve-asset-path identity) (encrypt-asset-file nil) (journal-page-id nil)
          (send http/send) (upload-file http/upload-file)
          (cleanup-file (fn [path] (try (sys/remove path) (catch _ (stdlib/ignore 0)))))
          (stage-operation nil) (prepare-operation nil) (pending-operations nil)
          (load-graph-catalog nil) (save-graph-catalog nil)))

(defn state [session] @(:state session))

(defn host [session] (:host session))

(defn now-ms [] (int (* (unix/gettimeofday) 1000.0)))

(defn debug [message] (stdlib/prerr-endline (str "LogseqChat core " message)))

(defn fresh-squuid []
  (match (ds/squuid) (ds/Uuid uuid) uuid _ (stdlib/failwith "Datascript.squuid returned a non-UUID value")))

(defn projection-server-t [session] (when-some [cursor (:sync-cursor (host session))] (cursor)))

(defn submission-server-t [session]
  (match (tuple (projection-server-t session) (:accepted-server-t (state session)))
    (tuple (Some applied) (Some accepted)) (Some (max applied accepted))
    (tuple (Some applied) None) (Some applied)
    (tuple None accepted) accepted))

(defn record-accepted-server-t! [session accepted]
  (swap! (:state session) assoc :accepted-server-t
         (Some (if-some [previous (:accepted-server-t (state session))] (max previous accepted) accepted))))

(defn create-session [options]
  (let [options (assoc options :authoritative-graph-blocks
                       (or (:authoritative-graph-blocks options) (:graph-blocks options)))
        catalog (when-some [load (:load-graph-catalog options)] (load))
        graphs (if-some [body catalog] (try (vec (api/graphs-from-graphs-body body)) (catch _ [])) [])]
    (record session
            (host options)
            (state (atom (record session-state
                                 (model (model/create (:storage options))) (config nil) (available-graphs graphs)
                                 (related-blocks []) (selected-sidebar-page nil) (node-routes []) (node-base-state nil)
                                 (accepted-server-t nil) (flashcards []) (search-results []) (search-query "")
                                 (sync-connected false) (pending-sync nil) (next-pending-request-id 0)
                                 (semantic-queue []) (semantic-active nil) (outliner-state outliner/empty)
                                 (outliner-optimistic-blocks nil) (outliner-commands []) (outliner-revision 0)))))))

(def empty-sidebar (record graph/sidebar-pages (favorites []) (recent-pages [])))

(defn transport-operation-block [operation]
  (match operation
    (Create-block block) block (Upload-asset block) block
    (Update-title block) block (Update-status block) block
    (Move-created-asset moved) (:block moved)
    (Create-journal journal) (:block journal)))
