(ns logseq-chat.outliner-effects
  (:require [clojure.string :as string]
            [logseq-chat.outliner-state :as state]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.fractional-order :as order]))

(type-variant outliner-platform-command
              (Platform_haptic :state/outliner-haptic) (Focus_block :string) (Confirm_delete :list<string>)
              (Set_clipboard_text :string) (Set_clipboard_references :list<string>) (Set_clipboard_urls :list<string>)
              (Platform_pick_attachment :string) (Platform_take_photo :string) (Platform_record_audio :string))

(type-record outliner-effects (operations :list<ops/pending-operation>) (platform :list<outliner-platform-command>))

(defn result [operations platform]
  (record outliner-effects (operations (apply list operations)) (platform (apply list platform))))

(defn find-block [context uuid] (state/find-block context uuid))

(defn ^:list<model/block> sorted-siblings [^:state/outliner-context context ^:option<string> parent]
  (apply list
         (sort (fn [left right]
                 (match (tuple (:order left) (:order right))
                   (tuple (Some a) (Some b)) (if (not= a b) (compare a b) (compare (:uuid left) (:uuid right)))
                   (tuple (Some _) None) -1 (tuple None (Some _)) 1
                   _ (compare (:uuid left) (:uuid right))))
               (filter #(= (:parent-id %) parent) (:blocks context)))))

(defn next-order [context block]
  (let [siblings (vec (sorted-siblings context (:parent-id block)))]
    (when-some [index (state/index-of-uuid (:uuid block) (apply list siblings))]
      (some (fn [candidate]
              (match (tuple (:order block) (:order candidate))
                (tuple (Some lower) (Some upper)) (when (pos? (compare upper lower)) upper)
                _ nil)) (drop (inc index) siblings)))))

(defn operation [base-t fresh-uuid intent]
  (record ops/pending-operation (operation-id (fresh-uuid)) (base-t base-t) (state ops/Queued) (intent intent)))

(defn status-reference [status]
  (if-some [ident (:ident status)] (ops/Ref-ident ident) (ops/Ref-uuid (:uuid status))))

(defn next-status-value [block]
  (match (some-> (:status block) :ident)
    (Some "logseq.property/status.todo") (Some (ops/Ref-ident "logseq.property/status.doing"))
    (Some "logseq.property/status.doing") (Some (ops/Ref-ident "logseq.property/status.done"))
    (Some "logseq.property/status.done") nil
    _ (Some (ops/Ref-ident "logseq.property/status.todo"))))

(defn append-result [left right]
  (result (concat (:operations left) (:operations right)) (concat (:platform left) (:platform right))))

(defn command [base-t now fresh-uuid context cmd]
  (match cmd
    (state/Haptic haptic) (Ok (result [] [(Platform_haptic haptic)]))
    (state/Commit_title value) (Ok (result [(operation base-t fresh-uuid (ops/Save-title value))] []))
    (state/Split_at value)
    (if-some [block (find-block context (:uuid value))]
      (let* [new-order (order/between (:order block) (next-order context block))]
        (let [operation-id (fresh-uuid) new-uuid (fresh-uuid)
              intent (ops/Split-block (record ops/pending-split (uuid (:uuid value)) (expected-title (:expected-title value))
                                              (before (:before value)) (after (:after value)) (new-uuid new-uuid)
                                              (new-order new-order) (created-at (now))))]
          (Ok (result [(record ops/pending-operation (operation-id operation-id) (base-t base-t) (state ops/Queued) (intent intent))]
                      [(Focus_block new-uuid)])))) (Error "split source no longer exists"))
    (state/Merge_into_previous value)
    (Ok (result [(operation base-t fresh-uuid
                            (ops/Merge-backward (record ops/pending-merge (uuid (:uuid value)) (expected-title (:expected-title value))
                                                        (title (:title value)) (previous-uuid (:previous-uuid value))
                                                        (expected-previous-title (:expected-previous-title value)) (merged-title nil))))]
                [(Focus_block (:previous-uuid value))]))
    (state/Reparent_blocks moves)
    (if (empty? moves) (Error "move batch must not be empty")
        (Ok (result [(operation base-t fresh-uuid (ops/Move-blocks (record ops/pending-moves (moves (vec moves)))))] [])))
    (state/Request_delete_confirmation uuids) (Ok (result [] [(Confirm_delete uuids)]))
    (state/Remove_blocks uuids)
    (Ok (result (if (empty? uuids) [] [(operation base-t fresh-uuid (ops/Delete-blocks (record ops/pending-delete (uuids (vec uuids)))))]) []))
    (state/Cycle_task_status uuid)
    (if-some [block (find-block context uuid)]
      (Ok (result [(operation base-t fresh-uuid
                              (ops/Set-property (record ops/pending-property (uuid uuid) (attr "logseq.property/status")
                                                        (expected (some-> (:status block) status-reference)) (value (next-status-value block)))))] []))
      (Error "task block no longer exists"))
    (state/Set_task_status_value value)
    (if-some [block (find-block context (:uuid value))]
      (Ok (result [(operation base-t fresh-uuid
                              (ops/Set-property (record ops/pending-property (uuid (:uuid value)) (attr "logseq.property/status")
                                                        (expected (some-> (:status block) status-reference)) (value (Some (:status value))))))] []))
      (Error "task block no longer exists"))
    (state/Create_linked_page title)
    (let [title (string/trim title)]
      (if (= title "") (Error "page title must not be empty")
          (let [uuid (fresh-uuid)]
            (Ok (result [(operation base-t fresh-uuid (ops/Create-page (record ops/pending-create (uuid uuid) (title title) (created-at (now)))))] [])))))
    (state/Assign_tag value)
    (if (some? (find-block context (:uuid value)))
      (if-some [candidate (some #(when (= (:value %) (:value value)) %) (:tags context))]
        (Ok (result [(operation base-t fresh-uuid (ops/Add-tag (record ops/pending-tag (uuid (:uuid value)) (tag-uuid (:value candidate)))))] []))
        (let [title (string/trim (:value value))]
          (if (= title "") (Error "tag title must not be empty")
              (let [tag-uuid (fresh-uuid)
                    create (operation base-t fresh-uuid (ops/Create-tag (record ops/pending-create (uuid tag-uuid) (title title) (created-at (now)))))
                    add (operation base-t fresh-uuid (ops/Add-tag (record ops/pending-tag (uuid (:uuid value)) (tag-uuid tag-uuid))))]
                (Ok (result [create add] []))))))
      (Error "tag target block no longer exists"))
    (state/Insert_root_block value)
    (let* [position (order/between (match (last (sorted-siblings context (Some (:page-uuid value))))
                                    (Some block) (:order block) None None) nil)]
      (let [operation-id (fresh-uuid) uuid (fresh-uuid)
            intent (ops/Insert-block (record ops/pending-insert (uuid uuid) (title "") (page-uuid (:page-uuid value))
                                             (parent-uuid (:page-uuid value)) (order position) (created-at (now))))]
        (Ok (result [(record ops/pending-operation (operation-id operation-id) (base-t base-t) (state ops/Queued) (intent intent))]
                    [(Focus_block uuid)]))))
    (state/Pick_attachment uuid) (Ok (result [] [(Platform_pick_attachment uuid)]))
    (state/Take_photo uuid) (Ok (result [] [(Platform_take_photo uuid)]))
    (state/Record_audio uuid) (Ok (result [] [(Platform_record_audio uuid)]))
    (state/Copy_text text) (Ok (result [] [(Set_clipboard_text text)]))
    (state/Copy_references uuids) (Ok (result [] [(Set_clipboard_references uuids)]))
    (state/Copy_urls uuids) (Ok (result [] [(Set_clipboard_urls uuids)]))))

(defn interpret [base-t now fresh-uuid context ^:list<state/outliner-command> commands]
  (let [commands (vec commands)]
    (loop [index 0 operations [] platform []]
      (if (= index (count commands)) (Ok (result operations platform))
          (let* [next (command base-t now fresh-uuid context (nth commands index))]
            (recur (inc index) (into operations (:operations next)) (into platform (:platform next))))))))
