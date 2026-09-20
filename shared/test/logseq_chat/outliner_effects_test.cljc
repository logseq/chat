(ns logseq-chat.outliner-effects-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.outliner-effects :as effects]
            [logseq-chat.outliner-state :as state]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [ocaml.Stdlib :as stdlib]))

(defn block [uuid title order]
  (record model/block (uuid uuid) (title title) (page-id "page") (parent-id (Some "page")) (order order)
    (created-at 0) (updated-at 0) (sync-status "synced") (tags (list)) (references (list)) (breadcrumbs (list))
    (status None) (is-asset false) (asset-type None) (asset-size None) (asset-checksum None) (local-path None) (journal None)))

(defn context-for [blocks]
  (record state/outliner-context (blocks (apply list blocks)) (pages (list)) (tags (list))))

(def context (context-for [(block "first" "First" (Some "a0")) (block "second" "Second" (Some "a1"))
                          (block "third" "Third" (Some "a2"))]))

(defn fresh-values [values]
  (let [index (atom 0)]
    (fn [] (let [value (nth values @index)] (swap! index inc) value))))

(defn interpret-in [context ids commands]
  (effects/interpret 42 (fn [] 100) (fresh-values ids) context (apply list commands)))

(defn interpret [commands] (interpret-in context ["operation"] commands))

(defn expect-ok [result] (match result (Ok value) value (Error message) (stdlib/failwith message)))

(defn only-operation [result]
  (is (= 1 (count (:operations result))))
  (or (first (:operations result)) (stdlib/failwith "missing operation")))

(defn split [uuid before after]
  (state/Split_at (record state/outliner-split (uuid uuid) (expected-title "Second") (before before) (after after))))

(deftest split-generates-between-sibling-order-and-focus
  (let [result (expect-ok (interpret-in context ["operation-1" "new-block"] [(split "second" "Sec" "ond")]))
        operation (only-operation result)]
    (is (= "operation-1" (:operation-id operation))) (is (= 42 (:base-t operation)))
    (is (match (:intent operation)
          (ops/Split-block value)
          (and (= "new-block" (:new-uuid value)) (= 100 (:created-at value))
               (neg? (compare "a1" (:new-order value))) (neg? (compare (:new-order value) "a2")))
          _ false))
    (is (= [(effects/Focus_block "new-block")] (vec (:platform result)))))
  (let [duplicates (context-for [(block "first" "First" (Some "a0")) (block "second" "Second" (Some "a1"))
                                 (block "duplicate" "Duplicate" (Some "a1")) (block "third" "Third" (Some "a2"))])
        operation (only-operation (expect-ok (interpret-in duplicates ["duplicate-operation" "duplicate-new-block"]
                                                            [(split "second" "Second" "")])))]
    (is (match (:intent operation) (ops/Split-block value)
          (and (neg? (compare "a1" (:new-order value))) (neg? (compare (:new-order value) "a2"))) _ false))))

(deftest explicit-task-status-and-move-batches-preserve-haptics
  (let [result (expect-ok (effects/interpret 43 (fn [] 100) (fresh-values ["operation"]) context
                           (list (state/Set_task_status_value (record state/outliner-status (uuid "first") (status (ops/Ref-uuid "waiting"))))
                                 (state/Haptic state/Impact))))
        operation (only-operation result)]
    (is (= 43 (:base-t operation)))
    (is (= (ops/Set-property (record ops/pending-property (uuid "first") (attr "logseq.property/status")
                                     (expected None) (value (Some (ops/Ref-uuid "waiting"))))) (:intent operation)))
    (is (= [(effects/Platform_haptic state/Impact)] (vec (:platform result)))))
  (let [move (record ops/pending-move (uuid "second") (page-uuid "page") (parent-uuid "first") (order "a0"))
        result (expect-ok (interpret [(state/Reparent_blocks (list move)) (state/Haptic state/Impact)]))]
    (is (= (ops/Move-blocks (record ops/pending-moves (moves [move]))) (:intent (only-operation result))))
    (is (= [(effects/Platform_haptic state/Impact)] (vec (:platform result))))))

(deftest task-cycle-without-status-stays-a-semantic-operation
  (let [result (expect-ok (interpret [(state/Cycle_task_status "first")]))]
    (is (= (ops/Set-property (record ops/pending-property (uuid "first") (attr "logseq.property/status")
                                     (expected None) (value (Some (ops/Ref-ident "logseq.property/status.todo")))))
           (:intent (only-operation result))))
    (is (empty? (:platform result)))))

(deftest platform-commands-map-exactly-without-semantic-operations
  (run! (fn [[command expected]]
          (let [result (expect-ok (interpret [command]))]
            (is (empty? (:operations result))) (is (= [expected] (vec (:platform result))))))
        [(tuple (state/Haptic state/Selection) (effects/Platform_haptic state/Selection))
         (tuple (state/Pick_attachment "first") (effects/Platform_pick_attachment "first"))
         (tuple (state/Record_audio "first") (effects/Platform_record_audio "first"))
         (tuple (state/Take_photo "first") (effects/Platform_take_photo "first"))
         (tuple (state/Copy_text "First") (effects/Set_clipboard_text "First"))
         (tuple (state/Copy_references (list "first")) (effects/Set_clipboard_references (list "first")))
         (tuple (state/Copy_urls (list "first")) (effects/Set_clipboard_urls (list "first")))
         (tuple (state/Request_delete_confirmation (list "first")) (effects/Confirm_delete (list "first")))]))

(deftest missing-sibling-orders-sort-after-orders-then-by-uuid
  (let [context (context-for [(block "z" "Z" None) (block "ordered" "Ordered" (Some "a0")) (block "a" "A" None)])]
    (is (= ["ordered" "a" "z"] (mapv :uuid (effects/sorted-siblings context (Some "page")))))))

(deftest invalid-commands-fail-and-empty-delete-is-a-no-op
  (is (= (Error "split source no longer exists") (interpret [(split "missing" "" "")])))
  (is (= (Error "move batch must not be empty") (interpret [(state/Reparent_blocks (list))])))
  (is (= (Error "task block no longer exists") (interpret [(state/Cycle_task_status "missing")])))
  (is (= (Error "task block no longer exists")
         (interpret [(state/Set_task_status_value (record state/outliner-status (uuid "missing") (status (ops/Ref-uuid "todo"))))])))
  (is (= (Ok (effects/result [] [])) (interpret [(state/Remove_blocks (list))])))
  (is (= (ops/Delete-blocks (record ops/pending-delete (uuids ["first"])))
         (:intent (only-operation (expect-ok (interpret [(state/Remove_blocks (list "first"))])))))))

(deftest title-commit-is-guarded-and-merge-focuses-the-survivor
  (let [title (record ops/pending-title (uuid "first") (expected-title "First") (title "Edited"))
        result (expect-ok (interpret [(state/Commit_title title)]))]
    (is (= (ops/Save-title title) (:intent (only-operation result)))) (is (empty? (:platform result))))
  (let [result (expect-ok (interpret [(state/Merge_into_previous
                                      (record state/outliner-merge (uuid "second") (expected-title "Second") (title "Second")
                                              (previous-uuid "first") (expected-previous-title "First")))]))]
    (is (match (:intent (only-operation result)) (ops/Merge-backward value) (= "first" (:previous-uuid value)) _ false))
    (is (= [(effects/Focus_block "first")] (vec (:platform result))))))

(deftest inserting-root-blocks-orders-and-focuses-the-new-row
  (let [result (expect-ok (interpret-in (context-for []) ["operation" "new-root"]
                           [(state/Insert_root_block (record state/outliner-root (page-uuid "page-1")))]))]
    (is (match (:intent (only-operation result)) (ops/Insert-block value)
          (and (= "new-root" (:uuid value)) (= "" (:title value)) (= "page-1" (:page-uuid value))
               (= "page-1" (:parent-uuid value)) (= 100 (:created-at value)) (not (empty? (:order value)))) _ false))
    (is (= [(effects/Focus_block "new-root")] (vec (:platform result)))))
  (let [result (expect-ok (interpret-in context ["operation" "new-root"]
                           [(state/Insert_root_block (record state/outliner-root (page-uuid "page")))]))]
    (is (match (:intent (only-operation result)) (ops/Insert-block value) (pos? (compare (:order value) "a2")) _ false))))

(defn status [uuid ident]
  (record model/status (uuid uuid) (ident ident) (title uuid) (icon-type None) (icon-id None) (icon-color None)))

(deftest task-cycle-preserves-guards-for-built-in-custom-and-uuid-statuses
  (run! (fn [[current expected value]]
          (let [context (context-for [(assoc (block "task" "Task" (Some "a0")) :status (Some current))])
                operation (only-operation (expect-ok (interpret-in context ["operation"] [(state/Cycle_task_status "task")])))]
            (is (match (:intent operation) (ops/Set-property property)
                  (and (= expected (:expected property)) (= value (:value property))) _ false))))
        [(tuple (status "todo" (Some "logseq.property/status.todo"))
                (Some (ops/Ref-ident "logseq.property/status.todo")) (Some (ops/Ref-ident "logseq.property/status.doing")))
         (tuple (status "doing" (Some "logseq.property/status.doing"))
                (Some (ops/Ref-ident "logseq.property/status.doing")) (Some (ops/Ref-ident "logseq.property/status.done")))
         (tuple (status "done" (Some "logseq.property/status.done")) (Some (ops/Ref-ident "logseq.property/status.done")) None)
         (tuple (status "custom" (Some "user.status/custom"))
                (Some (ops/Ref-ident "user.status/custom")) (Some (ops/Ref-ident "logseq.property/status.todo")))
         (tuple (status "uuid-only" None) (Some (ops/Ref-uuid "uuid-only")) (Some (ops/Ref-ident "logseq.property/status.todo")))]))
