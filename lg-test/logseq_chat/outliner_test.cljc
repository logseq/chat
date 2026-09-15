(ns logseq-chat.outliner-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.outliner :as outliner]))

(defn block [uuid title]
  (record outliner/outliner-block
          (uuid uuid) (title title) (page-uuid "page") (parent-uuid "page") (order "a0")))

(defn split-request []
  (record outliner/split-command
          (source-uuid "source") (expected-title "title") (before "before") (after "after")
          (new-uuid "new") (new-order "a1") (created-at 42)))

(defn merge-request []
  (record outliner/merge-backward-command
          (source-uuid "source") (expected-source-title "source title") (source-title "source title")
          (previous-uuid "previous") (expected-previous-title "previous title") (merged-title nil)))

(defn plan [^:vector<outliner/outliner-block> blocks ^:vector<outliner/outliner-block> children command]
  (outliner/plan
   (fn [uuid] (some #(when (= (:uuid %) uuid) %) blocks))
   (fn [_] (apply list children)) command))

(deftest split-plans-an-atomic-title-update-and-sibling-insert
  (let [request (assoc (split-request) :expected-title "hello world" :before "hello" :after " world")]
    (is (= (Ok (list
                (outliner/Set_title (record outliner/title-mutation (uuid "source") (title "hello")))
                (outliner/Insert (record outliner/insert-mutation
                                         (insert-block (assoc (block "new" " world") :order "a1")) (created-at 42)))))
           (plan [(block "source" "hello world")] [] (outliner/Split request))))))

(deftest split-saves-edited-text-while-checking-the-original-title
  (let [request (assoc (split-request) :expected-title "old title" :before "edited" :after " title")]
    (is (match (plan [(block "source" "old title")] [] (outliner/Split request))
          (Ok _) true (Error _) false))))

(deftest committed-splits-are-idempotent
  (let [request (assoc (split-request) :expected-title "hello world" :before "hello" :after " world")]
    (is (= (Ok (list))
           (plan [(block "source" "hello") (assoc (block "new" " world") :order "a1")]
                 [] (outliner/Split request))))))

(deftest merge-updates-title-reparents-children-and-deletes-source-atomically
  (let [source (assoc (block "source" " world") :parent-uuid "parent")
        previous (assoc (block "previous" "hello") :parent-uuid "parent")
        child (assoc (block "child" "nested") :parent-uuid "source")
        request (assoc (merge-request) :expected-source-title " world" :source-title " world"
                       :expected-previous-title "hello")]
    (is (= (Ok (list
                (outliner/Set_title (record outliner/title-mutation (uuid "previous") (title "hello world")))
                (outliner/Reparent (record outliner/reparent-mutation
                                           (uuid "child") (page-uuid "page") (parent-uuid "previous")))
                (outliner/Delete (record outliner/delete-mutation (uuid "source")))))
           (plan [source previous child] [child] (outliner/Merge_backward request))))))

(deftest split-rejects-conflicts-and-invalid-identities
  (let [request (split-request) source (block "source" "title")]
    (is (= (Error "split source no longer exists") (plan [] [] (outliner/Split request))))
    (run! (fn [uuid]
            (is (= (Error "split requires a distinct new block UUID")
                   (plan [source] [] (outliner/Split (assoc request :new-uuid uuid))))))
          ["source" "  "])
    (is (= (Error "split block UUID already exists")
           (plan [source (block "new" "existing")] [] (outliner/Split request))))
    (is (= (Error "split source title changed on the server")
           (plan [(block "source" "local")] []
                 (outliner/Split (assoc request :expected-title "remote" :before "re" :after "mote")))))))

(deftest merge-rejects-missing-changed-and-structurally-invalid-blocks
  (let [source (block "source" "source title") previous (block "previous" "previous title")
        request (merge-request)]
    (is (= (Error "merge source no longer exists")
           (plan [previous] [] (outliner/Merge_backward request))))
    (is (= (Error "merge target no longer exists")
           (plan [source] [] (outliner/Merge_backward request))))
    (is (= (Error "merge source and target must be different blocks")
           (plan [source previous] [] (outliner/Merge_backward (assoc request :previous-uuid "source")))))
    (is (= (Error "merge source title changed on the server")
           (plan [source previous] [] (outliner/Merge_backward (assoc request :expected-source-title "stale")))))
    (is (= (Error "merge target title changed on the server")
           (plan [source previous] [] (outliner/Merge_backward (assoc request :expected-previous-title "stale")))))
    (is (= (Error "merge source and target must belong to the same page")
           (plan [source (assoc previous :page-uuid "other")] [] (outliner/Merge_backward request))))
    (is (= (Error "merge target cannot be a child of the source")
           (plan [source previous] [previous] (outliner/Merge_backward request))))
    (is (= (Ok (list
                (outliner/Set_title (record outliner/title-mutation (uuid "previous") (title "explicit")))
                (outliner/Delete (record outliner/delete-mutation (uuid "source")))))
           (plan [source previous] [] (outliner/Merge_backward (assoc request :merged-title (Some "explicit"))))))))
