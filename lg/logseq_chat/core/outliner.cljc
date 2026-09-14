(ns logseq-chat.outliner
  (:require [ocaml.List :as list]
            [ocaml.String :as string]))

(type-record outliner-block
  (uuid :string)
  (title :string)
  (page-uuid :string)
  (parent-uuid :string)
  (order :string))

(type-record split-command
  (source-uuid :string)
  (expected-title :string)
  (before :string)
  (after :string)
  (new-uuid :string)
  (new-order :string)
  (created-at :int))

(type-record merge-backward-command
  (source-uuid :string)
  (expected-source-title :string)
  (source-title :string)
  (previous-uuid :string)
  (expected-previous-title :string)
  (merged-title :option<string>))

(type-variant command
  (Split :split-command)
  (Merge_backward :merge-backward-command))

(type-record title-mutation
  (uuid :string)
  (title :string))

(type-record insert-mutation
  (insert-block :outliner-block)
  (created-at :int))

(type-record reparent-mutation
  (uuid :string)
  (page-uuid :string)
  (parent-uuid :string))

(type-record delete-mutation
  (uuid :string))

(type-variant mutation
  (Set_title :title-mutation)
  (Insert :insert-mutation)
  (Reparent :reparent-mutation)
  (Delete :delete-mutation))

(defn nonblank [value]
  (not= (string/trim value) ""))

(defn contains-block? [blocks uuid]
  (some
   (fn [block] (= (:uuid block) uuid))
   blocks))

(defn plan-split [^:fn<string;option<outliner-block>> find request]
  (match (find (:source-uuid request))
    None (Error "split source no longer exists")
    (Some source)
    (if (or (= (:source-uuid request) (:new-uuid request))
            (not (nonblank (:new-uuid request))))
      (Error "split requires a distinct new block UUID")
      (match (find (:new-uuid request))
        (Some inserted)
        (if (and (= (:title inserted) (:after request))
                 (= (:page-uuid inserted) (:page-uuid source))
                 (= (:parent-uuid inserted) (:parent-uuid source))
                 (= (:order inserted) (:new-order request))
                 (= (:title source) (:before request)))
          (Ok (list))
          (Error "split block UUID already exists"))
        None
        (if (not= (:title source) (:expected-title request))
          (Error "split source title changed on the server")
          (Ok (list
               (Set_title (record title-mutation
                            (uuid (:uuid source))
                            (title (:before request))))
               (Insert (record insert-mutation
                         (insert-block (record outliner-block
                                         (uuid (:new-uuid request))
                                         (title (:after request))
                                         (page-uuid (:page-uuid source))
                                         (parent-uuid (:parent-uuid source))
                                         (order (:new-order request))))
                         (created-at (:created-at request)))))))))))

(defn plan-merge [^:fn<string;option<outliner-block>> find
                  ^:fn<string;list<outliner-block>> children
                  request]
  (match (tuple (find (:source-uuid request)) (find (:previous-uuid request)))
    (tuple None _) (Error "merge source no longer exists")
    (tuple _ None) (Error "merge target no longer exists")
    (tuple (Some source) (Some previous))
    (if (= (:uuid source) (:uuid previous))
      (Error "merge source and target must be different blocks")
      (if (not= (:title source) (:expected-source-title request))
        (Error "merge source title changed on the server")
        (if (not= (:title previous) (:expected-previous-title request))
          (Error "merge target title changed on the server")
          (if (not= (:page-uuid source) (:page-uuid previous))
            (Error "merge source and target must belong to the same page")
            (let [direct-children (children (:uuid source))]
              (if (contains-block? direct-children (:uuid previous))
                (Error "merge target cannot be a child of the source")
                (Ok
                 (list/of-seq
                  (concat
                   (list
                    (Set_title
                     (record title-mutation
                       (uuid (:uuid previous))
                       (title
                        (match (:merged-title request)
                          (Some title) title
                          None (str (:title previous) (:source-title request)))))))
                   (map
                    (fn [child]
                      (Reparent
                       (record reparent-mutation
                         (uuid (:uuid child))
                         (page-uuid (:page-uuid previous))
                         (parent-uuid (:uuid previous)))))
                    direct-children)
                   (list (Delete (record delete-mutation
                                   (uuid (:uuid source))))))))))))))))

(defn plan [find
            children
            command]
  (match command
    (Split request) (plan-split find request)
    (Merge_backward request) (plan-merge find children request)))
