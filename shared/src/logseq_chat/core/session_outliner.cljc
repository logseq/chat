(ns logseq-chat.session-outliner
  (:require [clojure.string :as string]
            [logseq-chat.session-types :as types]
            [logseq-chat.rpc :as rpc]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.outliner-state :as outliner]
            [ocaml.Stdlib :as stdlib]))

(defn sidebar-pages [session]
  (or (when-some [load (:graph-sidebar-pages (types/host session))] (load)) types/empty-sidebar))

(defn outliner-context-with-blocks [session sidebar blocks]
  (let [sidebar (or sidebar (sidebar-pages session))
        pages (mapv (fn [page] (record outliner/outliner-candidate (label (:title page)) (value (:uuid page))))
                    (concat (:favorites sidebar) (:recent-pages sidebar)))
        tags (if-some [load (:graph-tag-pages (types/host session))]
               (mapv (fn [page] (record outliner/outliner-candidate (label (:title page)) (value (:uuid page))))
                     (or (load) (list))) [])]
    (outliner/context blocks pages tags)))

(defn base-outliner-context-live [session]
  (let [s (types/state session) h (types/host session)
        blocks (match (tuple (:selected-sidebar-page s) (:graph-page-blocks h) (:graph-blocks h))
                 (tuple (Some page) (Some load) _) (vec (or (load (:uuid page)) (list)))
                 (tuple _ _ (Some load)) (vec (or (load) (list)))
                 _ (model/visible-blocks (:model s)))]
    (outliner-context-with-blocks session nil blocks)))

(defn page-overlay [session page-id blocks]
  (rpc/page-blocks-with-optimistic-overlay (:outliner-optimistic-blocks (types/state session))
                                           (outliner/editing-uuid (:outliner-state (types/state session))) page-id blocks))

(defn scope-selected-page [session context]
  (if-some [page (:selected-sidebar-page (types/state session))]
    (assoc context :blocks (apply list (page-overlay session (:uuid page) (:blocks context)))) context))

(defn base-outliner-context-with-blocks [session sidebar blocks]
  (scope-selected-page session (outliner-context-with-blocks session sidebar blocks)))

(defn base-outliner-context [session] (scope-selected-page session (base-outliner-context-live session)))

(defn page-outliner-context [session uuid]
  (when-some [load (:graph-page-blocks (types/host session))]
    (when-some [blocks (load uuid)] (Some (outliner-context-with-blocks session nil blocks)))))

(defn node-route-context [session route]
  (let [blocks (if-some [load (:graph-page-blocks (types/host session))] (or (load (:uuid (:page route))) (list)) (list))]
    (outliner-context-with-blocks session nil (page-overlay session (:uuid (:page route)) blocks))))

(defn active-node-route [session] (last (:node-routes (types/state session))))

(defn node-route-related-blocks [session route]
  (let [loader (if (:is-tag route) (:graph-tag-objects (types/host session)) (:graph-node-references (types/host session)))]
    (if-some [blocks (when-some [load loader] (load (:uuid route)))] (vec blocks) (:related-blocks route))))

(defn node-route-linked-reference-blocks [session route]
  (if (:is-tag route)
    (vec (or (when-some [load (:graph-node-references (types/host session))] (load (:uuid route))) (list))) []))

(defn page-for-visible-block [block]
  (let [title (match (:journal block)
                (Some (tuple title _)) (when (not (string/blank? title)) (Some title))
                None nil)
        title (or title (when-some [page (first (filter #(= (:uuid %) (:page-id block)) (:breadcrumbs block)))]
                          (Some (:title page))) (:title block))]
    (record model/entity-summary (uuid (:page-id block)) (title title))))

(defn projected-node-destination [session uuid]
  (let [s (types/state session) h (types/host session)
        graph-blocks (or (when-some [load (:graph-blocks h)] (load)) (list))
        selected-blocks (match (tuple (:selected-sidebar-page s) (:graph-page-blocks h))
                          (tuple (Some page) (Some load)) (or (load (:uuid page)) (list)) _ (list))
        blocks (vec (concat graph-blocks selected-blocks
                            (mapcat #(vec (:blocks (node-route-context session %))) (:node-routes s))
                            (:related-blocks s) (or (:outliner-optimistic-blocks s) [])))
        candidate (if-some [block (first (filter #(= (:uuid %) uuid) blocks))]
                    (Some (tuple block true))
                    (when-some [block (first (filter #(= (:page-id %) uuid) blocks))] (Some (tuple block false))))]
    (when-some [[block zoom] candidate]
      (when (not= (:page-id block) "") (Some (tuple (page-for-visible-block block) zoom))))))

(defn with-extra-blocks [context extra]
  (let [present (set (map :uuid (:blocks context)))]
    (assoc context :blocks (apply list (concat (:blocks context) (filter #(not (contains? present (:uuid %))) extra))))))

(defn outliner-context [session]
  (if-some [route (active-node-route session)]
    (with-extra-blocks (node-route-context session route)
      (concat (node-route-related-blocks session route) (node-route-linked-reference-blocks session route)))
    (with-extra-blocks (base-outliner-context session) (:related-blocks (types/state session)))))

(defn project-outliner-operations [context operations]
  (assoc context :blocks
         (apply list (reduce (fn [blocks operation] (rpc/project-outliner-intent blocks (:intent operation)))
                             (vec (:blocks context)) operations))))

(defn selected-graph [session]
  (when-some [config (:config (types/state session))]
    (first (filter #(= (:id %) (:graph-id config)) (:available-graphs (types/state session))))))

(defn selected-graph-is-encrypted [session]
  (if-some [graph (selected-graph session)] (:e2ee graph) false))

(defn selected-graph-is-unlocked [session]
  (match (tuple (:config (types/state session)) (selected-graph session))
    (tuple config (Some graph))
    (if (not (:e2ee graph)) true
        (match (tuple config (:graph-unlocked (types/host session)))
          (tuple (Some config) (Some unlocked)) (unlocked (:graph-id config)) _ false))
    _ false))

(defn selected-page-is-tag [session]
  (match (tuple (:selected-sidebar-page (types/state session)) (:graph-node-is-tag (types/host session)))
    (tuple (Some page) (Some check)) (check (:uuid page)) _ false))

(defn selected-page-is-property [session]
  (match (tuple (:selected-sidebar-page (types/state session)) (:graph-node-is-property (types/host session)))
    (tuple (Some page) (Some check)) (check (:uuid page)) _ false))

(defn snapshot-related-blocks [session]
  (if (selected-page-is-tag session)
    (match (tuple (:selected-sidebar-page (types/state session)) (:graph-tag-objects (types/host session)))
      (tuple (Some page) (Some load)) (vec (or (load (:uuid page)) (list))) _ [])
    (:related-blocks (types/state session))))

(defn snapshot-linked-reference-blocks [session]
  (if (selected-page-is-tag session)
    (match (tuple (:selected-sidebar-page (types/state session)) (:graph-node-references (types/host session)))
      (tuple (Some page) (Some load)) (vec (or (load (:uuid page)) (list))) _ []) []))

(defn has-pending-operations [session]
  (let [s (types/state session)]
    (or (not (empty? (:semantic-queue s))) (some? (:semantic-active s)) (some? (:pending-sync s))
        (not (empty? (model/pending-blocks (:model s)))))))

(defn reset-outliner! [session]
  (swap! (:state session) assoc :outliner-state outliner/empty :outliner-optimistic-blocks nil
         :outliner-commands [] :outliner-revision (inc (:outliner-revision (types/state session))))
  (stdlib/ignore 0))

(defn clear-node-navigation! [session]
  (when-some [base (:node-base-state (types/state session))] (swap! (:state session) assoc :outliner-state base))
  (swap! (:state session) assoc :node-routes [] :node-base-state nil)
  (stdlib/ignore 0))

(defn persist-active-node-state! [session]
  (let [s (types/state session) routes (:node-routes s)]
    (when (not (empty? routes))
      (swap! (:state session) assoc :node-routes
             (assoc routes (dec (count routes)) (assoc (nth routes (dec (count routes))) :state (:outliner-state s))))))
  (stdlib/ignore 0))

(defn initial-node-state [session route]
  (if (:zoom-to-block route)
    (let [[state _] (outliner/update (node-route-context session route) outliner/empty (outliner/Zoom_in (:uuid route)))] state)
    outliner/empty))

(defn push-node-route! [session route]
  (persist-active-node-state! session)
  (when (empty? (:node-routes (types/state session)))
    (swap! (:state session) assoc :node-base-state (Some (:outliner-state (types/state session)))))
  (let [current (initial-node-state session route)]
    (swap! (:state session) update :node-routes conj (assoc route :state current))
    (swap! (:state session) assoc :outliner-state current :outliner-commands []
           :outliner-revision (inc (:outliner-revision (types/state session)))))
  (stdlib/ignore 0))

(defn pop-node-route! [session]
  (persist-active-node-state! session)
  (let [routes (:node-routes (types/state session))]
    (when (not (empty? routes))
      (swap! (:state session) assoc :node-routes (subvec routes 0 (dec (count routes))))
      (if-some [route (active-node-route session)]
        (swap! (:state session) assoc :outliner-state (:state route))
        (swap! (:state session) assoc :outliner-state (or (:node-base-state (types/state session)) outliner/empty) :node-base-state nil))
      (swap! (:state session) assoc :outliner-commands [] :outliner-revision (inc (:outliner-revision (types/state session))))))
  (stdlib/ignore 0))

(defn aggregate-return-context [session payload message]
  (let [s (types/state session)
        return? (match message outliner/Return_pressed true (outliner/Return_pressed_with_text _) true _ false)]
    (when (and (nil? (:selected-sidebar-page s)) (empty? (:node-routes s)) return?)
      (when-some [source (rpc/outliner-structure-source payload)]
        (when-some [destination (:graph-node-destination (types/host session))]
          (when-some [[page _] (destination source)]
            (when-some [context (page-outliner-context session (:uuid page))]
              (Some (tuple context (:uuid page))))))))))

(type-variant outliner-patch-plan (Patch-blocks :vector<string>) Structural-diff)

(defn event-patch-plan [message operations]
  (match message
    (outliner/Toggle_collapsed _) Structural-diff
    _ (cond
        (= (count operations) 1)
        (match (:intent (nth operations 0))
          (ops/Save-title title) (Patch-blocks [(:uuid title)])
          (ops/Set-property property) (Patch-blocks [(:uuid property)])
          _ Structural-diff)
        (empty? operations)
        (match message
          (outliner/Tap_block _) (Patch-blocks []) (outliner/Long_press_block _) (Patch-blocks [])
          (outliner/Text_changed _) (Patch-blocks []) (outliner/Caret_moved _) (Patch-blocks [])
          (outliner/Choose_autocomplete _) (Patch-blocks []) outliner/Save_editing (Patch-blocks [])
          outliner/Cancel_editing (Patch-blocks []) (outliner/Toolbar _) (Patch-blocks []) _ Structural-diff)
        :else Structural-diff)))

(defn refresh-reference-metadata [session aggregate projected operations]
  (if (some #(match (:intent %) (ops/Save-title _) true (ops/Add-tag _) true _ false) operations)
    (let [live (if-some [uuid aggregate] (or (page-outliner-context session uuid) (outliner-context session))
                        (outliner-context session))
          by-id (zipmap (map :uuid (:blocks live)) (:blocks live))]
      (assoc projected :blocks
             (apply list (map (fn [block]
                                (if-some [current (get by-id (:uuid block))]
                                  (assoc block :references (:references current) :tags (:tags current)) block)) (:blocks projected)))))
    projected))
