(ns logseq-chat.mobile-session
  (:require [logseq-chat.mobile-graph :as graph]
            [logseq-chat.mobile-database :as database]
            [logseq-chat.mobile-payload :as payload]
            [logseq-chat.platform-crypto :as platform]
            [logseq-chat.e2ee-keyring :as keyring]
            [logseq-chat.asset-files :as assets]
            [logseq-chat.rpc-session :as rpc]
            [logseq-chat.session-types :as types]
            [logseq-chat.sqlite :as sqlite]
            [logseq-chat.http :as http]
            [ocaml.Callback :as callback]
            [ocaml.Stdlib :as stdlib]))

(type-record mobile-session
  (database :database/mobile-database)
  (keyring :keyring/e2ee-keyring)
  (session :ref<types/session>))

(def graph-catalog-address "logseq-chat/graph-catalog/v1")

(def snapshot-request "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")

(defn- discard-value [result]
  (let* [_ result] (Ok (stdlib/ignore 0))))

(defn host-options [database ring catalog]
  (let [graph (:graph database)]
    (assoc rpc/default-options
      :load-graph-catalog (when-some [catalog catalog]
                            (fn [] (sqlite/restore-string catalog graph-catalog-address)))
      :save-graph-catalog (when-some [catalog catalog]
                            (fn [body] (sqlite/store-string catalog graph-catalog-address body)))
      :open-graph (Some #(graph/open-graph graph %))
      :import-snapshot (Some #(graph/import-snapshot graph %))
      :model-for-graph (Some #(database/model-for-graph database %))
      :apply-sync-event (Some #(graph/apply-sync-event graph %))
      :sync-cursor (Some #(graph/sync-cursor graph))
      :graph-blocks (Some #(when-some [blocks (graph/blocks graph)] (apply list blocks)))
      :authoritative-graph-blocks (Some #(when-some [blocks (graph/authoritative-blocks graph)] (apply list blocks)))
      :graph-sidebar-pages (Some #(graph/sidebar-pages graph))
      :graph-tag-pages (Some #(when-some [pages (graph/tag-pages graph)] (apply list pages)))
      :graph-node-is-tag (Some #(graph/node-is-tag graph %))
      :graph-node-is-property (Some #(graph/node-is-property graph %))
      :graph-page-blocks (Some #(when-some [blocks (graph/blocks-for-page graph %)] (apply list blocks)))
      :graph-node-destination (Some #(graph/node-destination graph %))
      :graph-node-references (Some #(when-some [blocks (graph/references-for-node graph %)] (apply list blocks)))
      :graph-tag-objects (Some #(when-some [blocks (graph/objects-for-tag graph %)] (apply list blocks)))
      :graph-normalize-titles (Some (fn [uuid titles]
                                     (let [[titles tags] (graph/normalize-titles graph uuid titles)]
                                       (tuple (apply list titles) (apply list tags)))))
      :graph-search (Some #(apply list (graph/search graph %)))
      :graph-due-flashcards (Some #(apply list (graph/due-flashcards graph %)))
      :graph-review-flashcard (Some #(graph/review-flashcard graph %1 %2 %3 %4))
      :graph-set-page-favorite (Some #(graph/set-page-favorite graph %1 %2 %3 %4))
      :graph-delete-page (Some #(graph/delete-page graph %1 %2 %3))
      :load-older-journals (Some #(graph/load-older-journals graph))
      :has-older-journals (Some #(graph/has-older-journals graph))
      :stage-operation (Some #(graph/stage graph %))
      :prepare-operation (Some #(graph/prepare-sync graph %))
      :pending-operations (Some #(apply list (graph/pending-operations graph)))
      :load-cached-graph-key (Some #(discard-value (keyring/load-cached ring %)))
      :unlock-graph (Some #(discard-value (keyring/unlock ring %1 %2)))
      :provision-graph-key (Some #(discard-value (keyring/provision ring %)))
      :graph-unlocked (Some #(match (keyring/graph-key ring %) (Ok _) true (Error _) false))
      :encrypt-title (Some #(keyring/encrypt-title ring %1 %2))
      :resolve-asset-path #(graph/resolve-asset-path graph %)
      :encrypt-asset-file (Some (fn [graph-id path]
                                  (assets/encrypt-file #(keyring/encrypt-asset ring %1 %2) graph-id path)))
      :journal-page-id (Some #(graph/journal-page-uuid graph %)))))

(defn create [crypto-call]
  (let [ring (platform/create-keyring crypto-call http/send)
        graph (graph/create
                (record graph/graph-crypto
                  (require-key #(discard-value (keyring/graph-key ring %)))
                  (encrypt-title #(keyring/encrypt-title ring %1 %2))
                  (decrypt-title #(keyring/decrypt-title ring %1 %2))))
        database (database/create graph)]
    (record mobile-session (database database) (keyring ring)
            (session (atom (rpc/create-session (host-options database ring nil)))))))

(defn call [host request]
  (if-some [path (payload/database-open-path request)]
    (let [catalog (database/open-catalog (:database host) path)
          session (rpc/create-session (host-options (:database host) (:keyring host) (Some catalog)))]
      (reset! (:session host) session)
      (rpc/call session snapshot-request))
    (rpc/call @(:session host) request)))

(defn start! [crypto-call]
  (let [host (create crypto-call)]
    (callback/register "logseq_chat_mobile_call" #(call host %))))
