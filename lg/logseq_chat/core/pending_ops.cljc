(ns logseq-chat.pending-ops
  (:refer-clojure :exclude [list remove])
  (:require [clojure.string :as string]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.Datascript.Entity :as entity]
            [ocaml.Rrbvec :as rrbvec]))

(type-variant pending-state
  Queued Submitted (Accepted :int) Retryable Applied (Conflicted :string))

(type-variant semantic-value
  (String-value :string) (Int-value :int) (Instant-value :int)
  (Float-value :float) (Bool-value :bool) (Keyword-value :string)
  (Map-value :vector<tuple<string;semantic-value>>)
  (Ref-uuid :string) (Ref-ident :string))

(defn semantic-value-from-datascript [input]
  (match input
    (ds/String value) (Ok (String-value value))
    (ds/Int value) (Ok (Int-value value))
    (ds/Instant value) (Ok (Instant-value value))
    (ds/Float value) (Ok (Float-value value))
    (ds/Bool value) (Ok (Bool-value value))
    (ds/Keyword value) (Ok (Keyword-value value))
    (ds/Map entries)
    (let* [converted
           (reduce (fn [result [key native-value]]
                     (let* [acc result]
                       (match key
                         (ds/Keyword name)
                         (let* [converted-value (semantic-value-from-datascript native-value)]
                           (Ok (conj acc (tuple name converted-value))))
                         _ (Error "flashcard state contains a non-keyword key"))))
                   (Ok []) entries)]
      (Ok (Map-value converted)))
    _ (Error "flashcard state contains an unsupported value")))

(type-record property-change
  (attr :string) (expected :option<semantic-value>) (value :option<semantic-value>))

(type-record pending-move
  (uuid :string) (page-uuid :string) (parent-uuid :string) (order :string))

(type-record pending-title
  (uuid :string) (expected-title :string) (title :string))

(type-record pending-property
  (uuid :string) (attr :string) (expected :option<semantic-value>) (value :option<semantic-value>))

(type-record pending-properties (uuid :string) (changes :vector<property-change>))

(type-record pending-insert
  (uuid :string) (title :string) (page-uuid :string) (parent-uuid :string)
  (order :string) (created-at :int))

(type-record pending-asset
  (uuid :string) (title :string) (page-uuid :string) (parent-uuid :string)
  (order :string) (created-at :int) (asset-type :string)
  (asset-size :int) (asset-checksum :string))

(type-record pending-moves (moves :vector<pending-move>))

(type-record pending-split
  (uuid :string) (expected-title :string) (before :string) (after :string)
  (new-uuid :string) (new-order :string) (created-at :int))

(type-record pending-merge
  (uuid :string) (expected-title :string) (title :string)
  (previous-uuid :string) (expected-previous-title :string) (merged-title :option<string>))

(type-record pending-delete (uuids :vector<string>))

(type-record pending-create (uuid :string) (title :string) (created-at :int))

(type-record pending-journal
  (page-uuid :string) (block-uuid :string) (title :string) (journal-day :int) (created-at :int))

(type-record pending-tag (uuid :string) (tag-uuid :string))

(type-record pending-favorite
  (page-uuid :string) (favorite-uuid :string) (favorite :bool) (order :string) (created-at :int))

(type-record pending-page-delete (page-uuid :string) (order :string) (deleted-at :int))

(type-variant pending-intent
  (Save-title :pending-title) (Set-property :pending-property)
  (Set-properties :pending-properties) (Insert-block :pending-insert)
  (Create-asset :pending-asset) (Move-block :pending-move) (Move-blocks :pending-moves)
  (Split-block :pending-split) (Merge-backward :pending-merge) (Delete-blocks :pending-delete)
  (Create-tag :pending-create) (Create-page :pending-create) (Create-journal :pending-journal)
  (Add-tag :pending-tag) (Set-favorite :pending-favorite) (Delete-page :pending-page-delete))

(type-record pending-operation
  (operation-id :string) (base-t :int) (state :pending-state) (intent :pending-intent))

(defn raw-title [db uuid]
  (if-some [block (ds/entity db (ds/Lookup_ref "block/uuid" (ds/Uuid uuid)))]
    (match (entity/entity-attr-raw block "block/title")
      (Some (ds/One_value (ds/String title))) (Ok title)
      _ (Error "block title is missing"))
    (Error "block no longer exists")))

(defn normalize-expected-title [db uuid expected]
  (let* [current (raw-title db uuid)]
    (if (= current expected) (Ok current) (Error "title changed on the server"))))

(defn normalize-fsrs-value [attr value]
  (match value
    (Instant-value time) (if (= attr "logseq.property.fsrs/due") (Int-value time) value)
    (Map-value entries)
    (if (= attr "logseq.property.fsrs/state")
      (Map-value (mapv (fn [[key entry]]
                        (tuple key (match entry
                                     (Instant-value time) (if (= key "last-repeat") (Int-value time) entry)
                                     _ entry))) entries))
      value)
    _ value))

(defn normalize-optional-value [attr value]
  (match value (Some present) (Some (normalize-fsrs-value attr present)) None None))

(defn normalize-property-change [change]
  (record property-change
    (attr (:attr change))
    (expected (normalize-optional-value (:attr change) (:expected change)))
    (value (normalize-optional-value (:attr change) (:value change)))))

(defn normalize-operation [db operation]
  (let* [intent
         (match (:intent operation)
           (Save-title value)
           (let* [expected (normalize-expected-title db (:uuid value) (:expected-title value))]
             (Ok (Save-title (assoc value :expected-title expected))))
           (Split-block value)
           (let* [expected (normalize-expected-title db (:uuid value) (:expected-title value))]
             (Ok (Split-block (assoc value :expected-title expected))))
           (Merge-backward value)
           (let* [expected (normalize-expected-title db (:uuid value) (:expected-title value))
                  previous (normalize-expected-title db (:previous-uuid value) (:expected-previous-title value))]
             (Ok (Merge-backward (assoc value :expected-title expected :expected-previous-title previous
                                       :merged-title (Some (str previous (:title value)))))))
           (Set-property value)
           (Ok (Set-property (assoc value
                              :expected (normalize-optional-value (:attr value) (:expected value))
                              :value (normalize-optional-value (:attr value) (:value value)))))
           (Set-properties value)
           (Ok (Set-properties (assoc value :changes (mapv normalize-property-change (:changes value)))))
           other (Ok other))]
    (Ok (assoc operation :intent intent))))

(defn subtree-uuids [db roots]
  (loop [pending (vec (reverse roots)) result []]
    (if (empty? pending)
      result
      (let [uuid (nth pending (dec (count pending)))
            remaining (pop pending)
            children (if-let [eid (ds/entid db "block/uuid" (ds/Uuid uuid))]
                       (into [] (keep (fn [datom]
                               (when-let [identity (first (db-api/datoms db (ds/Eavt) :e (:e datom) :a "block/uuid"))]
                                 (match (:v identity) (ds/Uuid child) (Some child) _ nil)))
                             (db-api/datoms db (ds/Aevt) :a "block/parent" :v (ds/Ref eid))))
                       [])]
        (recur (into remaining (reverse children)) (conj result uuid))))))

(defn search-visible-property? [attr]
  (contains? #{"block/title" "block/name" "block/page" "block/parent"
               "block/journal-day" "block/refs" "logseq.property/built-in?"
               "block/closed-value-property" "logseq.property/hide?"
               "logseq.property/deleted-at"} attr))

(defn affected-uuids [db intent]
  (match intent
    (Set-property value) (if (search-visible-property? (:attr value)) [(:uuid value)] [])
    (Set-properties value) (if (some #(search-visible-property? (:attr %)) (:changes value)) [(:uuid value)] [])
    (Save-title value) [(:uuid value)]
    (Insert-block value) [(:uuid value)]
    (Create-asset value) [(:uuid value)]
    (Move-block value) [(:uuid value)]
    (Add-tag value) [(:uuid value)]
    (Create-tag value) [(:uuid value)]
    (Create-page value) [(:uuid value)]
    (Move-blocks value) (mapv :uuid (:moves value))
    (Split-block value) [(:uuid value) (:new-uuid value)]
    (Merge-backward value) [(:uuid value) (:previous-uuid value)]
    (Delete-blocks value) (subtree-uuids db (:uuids value))
    (Create-journal value) [(:page-uuid value) (:block-uuid value)]
    (Set-favorite value) [(:page-uuid value) (:favorite-uuid value)]
    (Delete-page value) [(:page-uuid value)]))

(defn safe-to-rebase? [intent]
  (match intent
    (Save-title _) true (Set-property _) true (Set-properties _) true
    (Split-block _) true (Merge-backward _) true
    (Create-tag _) true (Create-page _) true (Create-journal _) true
    (Add-tag _) true (Insert-block _) true (Create-asset _) true
    (Move-block _) true (Move-blocks _) true (Set-favorite _) true (Delete-page _) true
    (Delete-blocks _) false))

(defn inserted-result-exists? [db intent]
  (match intent
    (Insert-block value) (some? (ds/entid db "block/uuid" (ds/Uuid (:uuid value))))
    (Create-asset value) (some? (ds/entid db "block/uuid" (ds/Uuid (:uuid value))))
    _ false))

(defn split-result-exists? [db intent]
  (match intent
    (Split-block value) (some? (ds/entid db "block/uuid" (ds/Uuid (:new-uuid value))))
    _ false))

(defn committed-despite-later-changes? [server-t db operation]
  (let [intent (:intent operation)]
    (or (inserted-result-exists? db intent)
        (match (:state operation)
          (Accepted accepted-t) (and (<= accepted-t server-t) (split-result-exists? db intent))
          Submitted (split-result-exists? db intent)
          (Conflicted "split block UUID already exists") (split-result-exists? db intent)
          _ false))))

(ffi store-raw [:string :string :int :string :string] :unit
  {:ocaml "logseq_chat_pending_ops_store"})
(ffi list-raw [:string] :list<tuple<string;int;string;string>>
  {:ocaml "logseq_chat_pending_ops_list"})
(ffi set-state-raw [:string :string :string] :unit
  {:ocaml "logseq_chat_pending_ops_set_state"})
(ffi remove-raw [:string :string] :unit {:ocaml "logseq_chat_pending_ops_remove"})

(defn outliner-op [intent]
  (match intent
    (Save-title _) "save-block"
    (Set-property _) "save-block"
    (Set-properties _) "save-block"
    (Create-tag _) "save-block"
    (Create-page _) "save-block"
    (Add-tag _) "save-block"
    (Insert-block _) "insert-blocks"
    (Create-asset _) "insert-blocks"
    (Create-journal _) "insert-blocks"
    (Set-favorite value) (if (:favorite value) "insert-blocks" "delete-blocks")
    (Move-block _) "move-blocks"
    (Move-blocks _) "move-blocks"
    (Split-block _) "split-block"
    (Merge-backward _) "merge-blocks"
    (Delete-blocks _) "delete-blocks"
    (Delete-page _) "delete-page"))

(defn state-string [state]
  (match state
    Queued "queued" Submitted "submitted" (Accepted cursor) (str "accepted:" cursor)
    Retryable "retryable" Applied "applied" (Conflicted message) (str "conflicted:" message)))

(defn state-of-string [value]
  (cond
    (= value "queued") Queued
    (= value "submitted") Submitted
    (string/starts-with? value "accepted:")
    (match (stdlib/int-of-string-opt (subs value 9)) (Some cursor) (Accepted cursor) _ Retryable)
    (= value "accepted") Submitted
    (= value "applied") Applied
    (string/starts-with? value "conflicted:") (Conflicted (subs value 11))
    :else Retryable))

(defn json-object [entries] (tag Assoc (rrbvec/to-list entries)))

(defn json-array [values] (tag List (rrbvec/to-list values)))

(defn option-json [f value] (match value (Some value) (f value) _ (tag Null)))

(defn option-value [f value] (match value (tag Null) nil _ (Some (f value))))

(defn semantic-value-json [value]
  (let [[kind value]
        (match value
          (String-value value) (tuple "string" (tag String value))
          (Int-value value) (tuple "int" (tag Int value))
          (Instant-value value) (tuple "instant" (tag Int value))
          (Float-value value) (tuple "float" (tag Float value))
          (Bool-value value) (tuple "bool" (tag Bool value))
          (Keyword-value value) (tuple "keyword" (tag String value))
          (Ref-uuid value) (tuple "ref-uuid" (tag String value))
          (Ref-ident value) (tuple "ref-ident" (tag String value))
          (Map-value entries)
          (tuple "map" (json-array (mapv (fn [[key value]]
                                     (json-object [(tuple "key" (tag String key))
                                                   (tuple "value" (semantic-value-json value))]))
                                   entries))))]
    (json-object [(tuple "type" (tag String kind)) (tuple "value" value)])))

(defn object-fields [input message]
  (match input
    (tag Assoc _) (json-util/to-assoc input)
    _ (stdlib/invalid-arg message)))

(defn semantic-value-of-json [input]
  (match (object-fields input "invalid pending semantic value")
    [(tuple "type" (tag String kind)) (tuple "value" value)]
    (match (tuple kind value)
      (tuple "string" (tag String value)) (String-value value)
      (tuple "int" (tag Int value)) (Int-value value)
      (tuple "instant" (tag Int value)) (Instant-value value)
      (tuple "float" (tag Float value)) (Float-value value)
      (tuple "float" (tag Int value)) (Float-value (double value))
      (tuple "bool" (tag Bool value)) (Bool-value value)
      (tuple "keyword" (tag String value)) (Keyword-value value)
      (tuple "ref-uuid" (tag String value)) (Ref-uuid value)
      (tuple "ref-ident" (tag String value)) (Ref-ident value)
      (tuple "map" (tag List entries))
      (Map-value (mapv (fn [entry]
                        (match (object-fields entry "invalid pending semantic map entry")
                          [(tuple "key" (tag String key)) (tuple "value" value)]
                          (tuple key (semantic-value-of-json value))
                          _ (stdlib/invalid-arg "invalid pending semantic map entry"))) entries))
      _ (stdlib/invalid-arg "invalid pending semantic value"))
    _ (stdlib/invalid-arg "invalid pending semantic value")))

(defn field [fields key]
  (some (fn [entry] (match entry (tuple name value) (when (= name key) value))) fields))

(defn required-field [fields key]
  (match (field fields key) (Some value) value _ (throw (stdlib/Not_found))))

(defn string-field [fields key]
  (match (field fields key) (Some (tag String value)) value
    _ (stdlib/invalid-arg (str "invalid pending intent field: " key))))

(defn int-field [fields key]
  (match (field fields key) (Some (tag Int value)) value
    _ (stdlib/invalid-arg (str "invalid pending intent field: " key))))

(defn bool-field [fields key]
  (match (field fields key) (Some (tag Bool value)) value
    _ (stdlib/invalid-arg (str "invalid pending intent field: " key))))

(defn array-field [fields key]
  (match (field fields key) (Some (tag List values)) values
    _ (stdlib/invalid-arg (str "invalid pending intent field: " key))))

(defn semantic-field [fields key]
  (option-value semantic-value-of-json (required-field fields key)))

(defn move-json [value]
  (json-object [(tuple "uuid" (tag String (:uuid value)))
                (tuple "pageUuid" (tag String (:page-uuid value)))
                (tuple "parentUuid" (tag String (:parent-uuid value)))
                (tuple "order" (tag String (:order value)))]))

(defn move-of-json [input]
  (let [fields (object-fields input "invalid pending move")]
    (record pending-move (uuid (string-field fields "uuid"))
      (page-uuid (string-field fields "pageUuid"))
      (parent-uuid (string-field fields "parentUuid")) (order (string-field fields "order")))))

(defn change-json [value]
  (json-object [(tuple "attr" (tag String (:attr value)))
                (tuple "expected" (option-json semantic-value-json (:expected value)))
                (tuple "value" (option-json semantic-value-json (:value value)))]))

(defn change-of-json [input]
  (let [fields (object-fields input "invalid pending property change")]
    (record property-change (attr (string-field fields "attr"))
      (expected (semantic-field fields "expected")) (value (semantic-field fields "value")))))

(defn creation-fields [value]
  [(tuple "uuid" (tag String (:uuid value))) (tuple "title" (tag String (:title value)))
   (tuple "createdAt" (tag Int (:created-at value)))])

(defn insert-fields [value]
  [(tuple "uuid" (tag String (:uuid value))) (tuple "title" (tag String (:title value)))
   (tuple "pageUuid" (tag String (:page-uuid value)))
   (tuple "parentUuid" (tag String (:parent-uuid value)))
   (tuple "order" (tag String (:order value))) (tuple "createdAt" (tag Int (:created-at value)))])

(defn intent-json [intent]
  (let [[kind fields]
        (match intent
          (Save-title value)
          (tuple "save-title" [(tuple "uuid" (tag String (:uuid value)))
                         (tuple "expectedTitle" (tag String (:expected-title value)))
                         (tuple "title" (tag String (:title value)))])
          (Set-property value)
          (tuple "set-property" [(tuple "uuid" (tag String (:uuid value)))
                           (tuple "attr" (tag String (:attr value)))
                           (tuple "expected" (option-json semantic-value-json (:expected value)))
                           (tuple "value" (option-json semantic-value-json (:value value)))])
          (Set-properties value)
          (tuple "set-properties" [(tuple "uuid" (tag String (:uuid value)))
                             (tuple "changes" (json-array (mapv change-json (:changes value))))])
          (Insert-block value) (tuple "insert-block" (insert-fields value))
          (Create-asset value)
          (tuple "create-asset" (into (insert-fields value)
                           [(tuple "assetType" (tag String (:asset-type value)))
                            (tuple "assetSize" (tag Int (:asset-size value)))
                            (tuple "assetChecksum" (tag String (:asset-checksum value)))]))
          (Move-block value)
          (tuple "move-block" [(tuple "uuid" (tag String (:uuid value)))
                         (tuple "pageUuid" (tag String (:page-uuid value)))
                         (tuple "parentUuid" (tag String (:parent-uuid value)))
                         (tuple "order" (tag String (:order value)))])
          (Move-blocks value) (tuple "move-blocks" [(tuple "moves" (json-array (mapv move-json (:moves value))))])
          (Split-block value)
          (tuple "split-block" [(tuple "uuid" (tag String (:uuid value)))
                          (tuple "expectedTitle" (tag String (:expected-title value)))
                          (tuple "before" (tag String (:before value)))
                          (tuple "after" (tag String (:after value)))
                          (tuple "newUuid" (tag String (:new-uuid value)))
                          (tuple "newOrder" (tag String (:new-order value)))
                          (tuple "createdAt" (tag Int (:created-at value)))])
          (Merge-backward value)
          (tuple "merge-backward" [(tuple "uuid" (tag String (:uuid value)))
                             (tuple "expectedTitle" (tag String (:expected-title value)))
                             (tuple "title" (tag String (:title value)))
                             (tuple "previousUuid" (tag String (:previous-uuid value)))
                             (tuple "expectedPreviousTitle" (tag String (:expected-previous-title value)))
                             (tuple "mergedTitle" (option-json (fn [value] (tag String value)) (:merged-title value)))])
          (Delete-blocks value)
          (tuple "delete-blocks" [(tuple "uuids" (json-array (mapv (fn [uuid] (tag String uuid)) (:uuids value))))])
          (Create-tag value) (tuple "create-tag" (creation-fields value))
          (Create-page value) (tuple "create-page" (creation-fields value))
          (Create-journal value)
          (tuple "create-journal" [(tuple "pageUuid" (tag String (:page-uuid value)))
                             (tuple "blockUuid" (tag String (:block-uuid value)))
                             (tuple "title" (tag String (:title value)))
                             (tuple "journalDay" (tag Int (:journal-day value)))
                             (tuple "createdAt" (tag Int (:created-at value)))])
          (Add-tag value) (tuple "add-tag" [(tuple "uuid" (tag String (:uuid value)))
                                     (tuple "tagUuid" (tag String (:tag-uuid value)))])
          (Set-favorite value)
          (tuple "set-favorite" [(tuple "pageUuid" (tag String (:page-uuid value)))
                           (tuple "favoriteUuid" (tag String (:favorite-uuid value)))
                           (tuple "favorite" (tag Bool (:favorite value)))
                           (tuple "order" (tag String (:order value)))
                           (tuple "createdAt" (tag Int (:created-at value)))])
          (Delete-page value)
          (tuple "delete-page" [(tuple "pageUuid" (tag String (:page-uuid value)))
                          (tuple "order" (tag String (:order value)))
                          (tuple "deletedAt" (tag Int (:deleted-at value)))]))]
    (json-object (into [(tuple "type" (tag String kind))] fields))))

(defn create-of-fields [fields]
  (record pending-create (uuid (string-field fields "uuid"))
    (title (string-field fields "title")) (created-at (int-field fields "createdAt"))))

(defn merged-title [fields]
  (match (field fields "mergedTitle")
    (Some (tag String value)) (Some value)
    (Some (tag Null)) nil
    None nil
    _ (stdlib/invalid-arg "invalid pending intent field: mergedTitle")))

(defn intent-of-json [input]
  (let [fields (object-fields input "pending intent must be an object")]
    (case (string-field fields "type")
      "save-title"
      (Save-title (record pending-title (uuid (string-field fields "uuid"))
                    (expected-title (string-field fields "expectedTitle")) (title (string-field fields "title"))))
      "set-property"
      (Set-property (record pending-property (uuid (string-field fields "uuid"))
                      (attr (string-field fields "attr")) (expected (semantic-field fields "expected"))
                      (value (semantic-field fields "value"))))
      "set-properties"
      (Set-properties (record pending-properties (uuid (string-field fields "uuid"))
                        (changes (mapv change-of-json (array-field fields "changes")))))
      "insert-block"
      (Insert-block (record pending-insert (uuid (string-field fields "uuid"))
                      (title (string-field fields "title")) (page-uuid (string-field fields "pageUuid"))
                      (parent-uuid (string-field fields "parentUuid")) (order (string-field fields "order"))
                      (created-at (int-field fields "createdAt"))))
      "create-asset"
      (Create-asset (record pending-asset (uuid (string-field fields "uuid"))
                      (title (string-field fields "title")) (page-uuid (string-field fields "pageUuid"))
                      (parent-uuid (string-field fields "parentUuid")) (order (string-field fields "order"))
                      (created-at (int-field fields "createdAt")) (asset-type (string-field fields "assetType"))
                      (asset-size (int-field fields "assetSize")) (asset-checksum (string-field fields "assetChecksum"))))
      "move-block" (Move-block (move-of-json input))
      "move-blocks" (Move-blocks (record pending-moves (moves (mapv move-of-json (array-field fields "moves")))))
      "split-block"
      (Split-block (record pending-split (uuid (string-field fields "uuid"))
                     (expected-title (string-field fields "expectedTitle"))
                     (before (string-field fields "before")) (after (string-field fields "after"))
                     (new-uuid (string-field fields "newUuid")) (new-order (string-field fields "newOrder"))
                     (created-at (int-field fields "createdAt"))))
      "merge-backward"
      (Merge-backward (record pending-merge (uuid (string-field fields "uuid"))
                        (expected-title (string-field fields "expectedTitle")) (title (string-field fields "title"))
                        (previous-uuid (string-field fields "previousUuid"))
                        (expected-previous-title (string-field fields "expectedPreviousTitle"))
                        (merged-title (merged-title fields))))
      "delete-blocks"
      (Delete-blocks (record pending-delete
                       (uuids (mapv (fn [value] (match value (tag String uuid) uuid
                                                 _ (stdlib/invalid-arg "invalid pending delete uuid")))
                                    (array-field fields "uuids")))))
      "create-tag" (Create-tag (create-of-fields fields))
      "create-page" (Create-page (create-of-fields fields))
      "create-journal"
      (Create-journal (record pending-journal (page-uuid (string-field fields "pageUuid"))
                        (block-uuid (string-field fields "blockUuid")) (title (string-field fields "title"))
                        (journal-day (int-field fields "journalDay")) (created-at (int-field fields "createdAt"))))
      "add-tag" (Add-tag (record pending-tag (uuid (string-field fields "uuid"))
                          (tag-uuid (string-field fields "tagUuid"))))
      "set-favorite"
      (Set-favorite (record pending-favorite (page-uuid (string-field fields "pageUuid"))
                       (favorite-uuid (string-field fields "favoriteUuid")) (favorite (bool-field fields "favorite"))
                       (order (string-field fields "order")) (created-at (int-field fields "createdAt"))))
      "delete-page"
      (Delete-page (record pending-page-delete (page-uuid (string-field fields "pageUuid"))
                     (order (string-field fields "order")) (deleted-at (int-field fields "deletedAt"))))
      (stdlib/invalid-arg (str "unknown pending intent: " (string-field fields "type"))))))

(defn save [path operation]
  (store-raw path (:operation-id operation) (:base-t operation)
             (state-string (:state operation)) (json/to-string (intent-json (:intent operation)))))

(defn list [path]
  (mapv (fn [[id cursor state intent]]
          (record pending-operation (operation-id id) (base-t cursor)
            (state (state-of-string state)) (intent (intent-of-json (json/from-string intent)))))
        (list-raw path)))

(defn set-state [path operation-id state]
  (set-state-raw path operation-id (state-string state)))

(defn remove [path operation-id] (remove-raw path operation-id))

(defn confirm [path operation-ids]
  (run! (fn [operation-id] (remove path operation-id)) operation-ids))
