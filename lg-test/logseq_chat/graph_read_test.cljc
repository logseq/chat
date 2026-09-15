(ns logseq-chat.graph-read-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.graph-read :as read]
            [logseq-chat.graph-projection :as projection]
            [logseq-chat.cache-model :as model]
            [logseq-chat.sync-protocol :as protocol]
            [logseq-chat.storage-codec :as storage]
            [ocaml.Datascript :as ds]
            [ocaml.Transit_core.Json :as transit]
            [ocaml.Int64 :as int64]
            [ocaml.Stdlib :as stdlib]))

(def one storage/default-schema-attr)
(def string-attr (assoc one :value-type (Some (ds/StringType))))
(def ref-attr (assoc one :value-type (Some (ds/RefType))))
(def instant-attr (assoc one :value-type (Some (ds/InstantType))))
(def many-ref (assoc ref-attr :cardinality (ds/Many) :indexed true))
(def schema
  {"block/uuid" (assoc one :value-type (Some (ds/UuidType)) :unique (Some (ds/Identity)) :indexed true)
   "block/name" (assoc string-attr :unique (Some (ds/Identity)) :indexed true)
   "block/title" string-attr "block/page" ref-attr "block/parent" ref-attr "block/link" ref-attr
   "block/order" string-attr "block/created-at" instant-attr "block/updated-at" instant-attr
   "block/journal-day" one "block/refs" many-ref "block/tags" many-ref
   "logseq.property.class/extends" many-ref "logseq.property/hide?" one
   "logseq.property/deleted-at" instant-attr "logseq.property/view-for" ref-attr
   "logseq.property.class/hide-from-node" one
   "db/ident" (assoc one :value-type (Some (ds/KeywordType)) :unique (Some (ds/Identity)) :indexed true)})
(defn new-conn [attributes overrides]
  (ds/create-conn :schema
    (apply list (seq (merge (select-keys schema ["block/uuid" "block/name" "block/title"])
                           (select-keys schema attributes) overrides)))))
(defn field [name value] (tuple name (ds/One_value value)))
(defn refs [name ids]
  (tuple name (ds/Many_values (apply list (map #(ds/Ref_to (ds/Temp_id %)) ids)))))
(defn entity-input [id attributes]
  (ds/Entity (record Datascript.tx_entity (db-id (Some id)) (attrs (apply list attributes)))))
(defn entity [id title attributes]
  (entity-input (ds/Temp_id id)
    (into [(field "block/uuid" (ds/Uuid id)) (field "block/title" (ds/String title))] attributes)))
(defn page [id name title attributes]
  (entity id title (into [(field "block/name" (ds/String name))] attributes)))
(defn journal [id title day]
  (page id id title [(field "block/journal-day" (ds/Int day))]))
(defn block [id title page parent created attributes]
  (entity id title (into [(field "block/page" (ds/Ref_to (ds/Temp_id page)))
                         (field "block/parent" (ds/Ref_to (ds/Temp_id parent)))
                         (field "block/created-at" (ds/Instant created))] attributes)))
(defn transact [conn entities] (ds/transact-conn conn (apply list entities)))
(defn add [conn uuid attr value]
  (transact conn [(ds/Add (ds/Lookup_ref "block/uuid" (ds/Uuid uuid)) attr value)]))
(defn eid [db uuid]
  (or (ds/entid db "block/uuid" (ds/Uuid uuid)) (stdlib/failwith (str "missing entity: " uuid))))
(defn wire-id [uuid] (transit/Array (list (transit/Keyword "block/uuid") (transit/Uuid uuid))))
(defn wire-entity [uuid attr value]
  (record protocol/sync-entity (id (wire-id uuid)) (attrs (list (tuple (transit/Keyword attr) value)))))
(defn change [t upserts deleted]
  (record protocol/sync-change-set (format-version 1) (graph-id "graph-1") (schema-version "65.33")
    (t-before (dec t)) (t t) (upserts (apply list upserts)) (deleted (apply list deleted)) (operation-ids (list))))
(defn uuids [blocks] (mapv :uuid blocks))
(defn summaries [values] (vec (sort (map #(tuple (:uuid %) (:title %)) values))))
(defn find-block [uuid ^:seq<model/block> blocks]
  (if-some [block (some #(when (= uuid (:uuid %)) %) blocks)]
    block
    (stdlib/failwith (str "missing projected block: " uuid))))

(deftest incremental-projection-refreshes-dependencies-and-evicts-recycled-journals
  (let [conn (new-conn ["block/page" "block/parent" "block/created-at" "block/journal-day" "logseq.property/deleted-at"] {})
        page-id "028f7850-c6aa-7da0-8b3f-6dbb64aa4ec8"
        first-id "028f7850-c6aa-7da0-8b3f-6dbb64aa4ec9"
        second-id "028f7850-c6aa-7da0-8b3f-6dbb64aa4eca"
        decrypted (atom 0) fail? (atom false)
        decrypt (fn [title]
                  (when @fail? (stdlib/failwith "projection decryption failed"))
                  (swap! decrypted inc) (Ok title))]
    (transact conn [(journal page-id "Journal" 20260816)
                    (block first-id "First" page-id page-id 1 [])
                    (block second-id "Second" page-id page-id 2 [])])
    (let [current (projection/create decrypt (ds/conn-db conn))]
      (reset! fail? true)
      (is (try (do (projection/rebuild current (ds/conn-db conn)) false)
               (catch (Failure message) (= "projection decryption failed" message))))
      (is (empty? (projection/blocks current)))
      (reset! fail? false)
      (projection/rebuild current (ds/conn-db conn))
      (reset! decrypted 0)
      (add conn first-id "block/title" (ds/String "First updated"))
      (projection/update current (ds/conn-db conn)
        (change 2 [(wire-entity first-id "block/title" (transit/String "First updated"))] []))
      (is (<= @decrypted 2))
      (is (= ["First updated" "Second"] (mapv :title (projection/blocks current))))
      (reset! decrypted 0)
      (add conn page-id "block/title" (ds/String "Journal updated"))
      (projection/update current (ds/conn-db conn)
        (change 3 [(wire-entity page-id "block/title" (transit/String "Journal updated"))] []))
      (is (<= @decrypted 4))
      (is (= [(Some (tuple "Journal updated" 20260816)) (Some (tuple "Journal updated" 20260816))]
             (mapv :journal (projection/blocks current))))
      (transact conn [(ds/RetractEntity (ds/Entity_id (eid (ds/conn-db conn) first-id)))])
      (projection/update current (ds/conn-db conn) (change 4 [] [(wire-id first-id)]))
      (is (= [second-id] (uuids (projection/blocks current))))
      (let [next-page "028f7850-c6aa-7da0-8b3f-6dbb64aa4ecb" next-block "028f7850-c6aa-7da0-8b3f-6dbb64aa4ecc"]
        (transact conn [(journal next-page "Next journal" 20260817) (block next-block "Next block" next-page next-page 3 [])])
        (projection/update current (ds/conn-db conn)
          (change 5 [(wire-entity next-page "block/journal-day" (transit/Int 20260817))] []))
        (is (= [(eid (ds/conn-db conn) next-page)] (read/recent-journal-page-ids 1 (ds/conn-db conn))))
        (is (= 2 (read/journal-page-count (ds/conn-db conn))))
        (add conn next-page "logseq.property/deleted-at" (ds/Instant 6))
        (let [db (ds/conn-db conn)]
          (is (= [(eid db page-id)] (read/recent-journal-page-ids 7 db)))
          (is (not (some #(= next-page (:page-id %)) (read/blocks #(Ok %) 7 db))))
          (is (= 1 (read/journal-page-count db)))
          (is (nil? (read/journal-page-uuid db 20260817))))
        (projection/update current (ds/conn-db conn)
          (change 6 [(wire-entity next-page "logseq.property/deleted-at" (transit/Date (int64/of-int 6)))] []))
        (is (= [second-id] (uuids (projection/blocks current))))))))

(deftest node-navigation-and-related-blocks-respect-visibility-and-breadcrumbs
  (let [conn (new-conn ["block/page" "block/parent" "block/tags" "block/refs" "block/created-at"
                       "logseq.property/hide?" "logseq.property/deleted-at" "logseq.property/view-for"] {})]
    (transact conn
      [(page "node-page" "node-page" "Node page" []) (page "tag" "project" "Project" [])
       (block "parent-block" "Parent block" "node-page" "node-page" 1 [])
       (block "referenced-block" "Referenced block" "node-page" "node-page" 1 [])
       (block "object" "Tagged object" "node-page" "parent-block" 2 [(refs "block/tags" ["tag"])])
       (block "linked-reference" "Linked reference" "node-page" "node-page" 3 [(refs "block/refs" ["node-page"])])
       (block "hidden-tagged-object" "Hidden tagged object" "node-page" "node-page" 4
         [(refs "block/tags" ["tag"]) (field "logseq.property/hide?" (ds/Bool true))])
       (block "view-linked-reference" "View linked reference" "node-page" "node-page" 5
         [(refs "block/refs" ["node-page"]) (field "logseq.property/view-for" (ds/Ref_to (ds/Temp_id "tag")))])
       (block "recycled-linked-reference" "Recycled linked reference" "node-page" "node-page" 6
         [(refs "block/refs" ["node-page"]) (field "logseq.property/deleted-at" (ds/Instant 6))])
       (entity "hidden-parent" "Hidden parent"
         [(field "block/page" (ds/Ref_to (ds/Temp_id "node-page")))
          (field "block/parent" (ds/Ref_to (ds/Temp_id "node-page"))) (field "logseq.property/hide?" (ds/Bool true))])
       (entity "hidden-child" "Hidden child"
         [(field "block/page" (ds/Ref_to (ds/Temp_id "node-page"))) (field "block/parent" (ds/Ref_to (ds/Temp_id "hidden-parent")))])])
    (let [db (ds/conn-db conn)]
      (is (match (read/node-destination #(Ok %) db "node-page")
            (Some [page false]) (and (= "node-page" (:uuid page)) (= "Node page" (:title page))) _ false))
      (is (match (read/node-destination #(Ok %) db "referenced-block") (Some [page true]) (= "node-page" (:uuid page)) _ false))
      (run! #(is (nil? (read/node-destination (fn [value] (Ok value)) db %))) ["hidden-parent" "hidden-child"])
      (let [objects (read/objects-for-tag #(Ok %) db "tag") references (read/references-for-node #(Ok %) db "node-page")]
        (is (= ["object"] (uuids objects))) (is (= ["Tagged object"] (mapv :title objects)))
        (is (= ["Node page" "Parent block"] (mapv :title (:breadcrumbs (nth objects 0)))))
        (is (= ["linked-reference"] (uuids references))) (is (= ["Linked reference"] (mapv :title references)))
        (is (= ["Node page"] (mapv :title (:breadcrumbs (nth references 0)))))))))

(deftest journals-stay-grouped-newest-first-in-outliner-order
  (let [conn (new-conn ["block/page" "block/parent" "block/order" "block/created-at" "block/journal-day"] {})]
    (transact conn [(journal "older-page" "Older" 20260827) (journal "newer-page" "Newer" 20260828)
                    (block "older-first" "Older first" "older-page" "older-page" 10 [(field "block/order" (ds/String "a0"))])
                    (block "newer-second" "Newer second" "newer-page" "newer-page" 20 [(field "block/order" (ds/String "a1"))])
                    (block "older-second" "Older second" "older-page" "older-page" 30 [(field "block/order" (ds/String "a1"))])
                    (block "newer-first" "Newer first" "newer-page" "newer-page" 40 [(field "block/order" (ds/String "a0"))])])
    (is (= ["newer-first" "newer-second" "older-first" "older-second"] (uuids (read/blocks #(Ok %) 2 (ds/conn-db conn)))))))

(deftest transitive-class-cycles-include-tagged-pages-and-classify-assets
  (let [conn (new-conn ["block/page" "block/parent" "block/tags" "logseq.property.class/extends" "block/created-at" "db/ident"] {})]
    (transact conn
      [(entity "tag-class" "Tag" [(field "db/ident" (ds/Keyword "logseq.class/Tag"))])
       (entity "asset-class" "Asset" [(field "db/ident" (ds/Keyword "logseq.class/Asset"))])
       (entity "property-class" "Property" [(field "db/ident" (ds/Keyword "logseq.class/Property"))])
       (page "status-property" "status" "Status" [(refs "block/tags" ["property-class"])])
       (page "page" "page" "Page" [])
       (page "parent-tag" "parent tag" "Parent tag" [(refs "block/tags" ["tag-class"]) (refs "logseq.property.class/extends" ["grandchild-tag"])])
       (page "child-tag" "child tag" "Child tag" [(refs "block/tags" ["tag-class"]) (refs "logseq.property.class/extends" ["parent-tag"])])
       (page "grandchild-tag" "grandchild tag" "Grandchild tag" [(refs "block/tags" ["tag-class"]) (refs "logseq.property.class/extends" ["child-tag"])])
       (block "tagged-object" "Tagged through a descendant" "page" "page" 1 [(refs "block/tags" ["grandchild-tag"])])
       (page "tagged-page" "tagged page" "Tagged page" [(refs "block/tags" ["grandchild-tag"]) (field "block/created-at" (ds/Instant 3))])
       (page "asset-child" "asset child" "Asset child" [(refs "logseq.property.class/extends" ["asset-class"])])
       (block "asset-object" "Asset" "page" "page" 2 [(refs "block/tags" ["asset-child"])])])
    (let [db (ds/conn-db conn) objects (read/objects-for-tag #(Ok %) db "parent-tag")]
      (is (read/node-is-tag? db "child-tag")) (is (read/node-is-property? db "status-property"))
      (is (not (read/node-is-property? db "tagged-page")))
      (is (= ["tagged-object" "tagged-page"] (uuids objects)))
      (is (= "tagged-page" (:page-id (nth objects 1)))) (is (nil? (:parent-id (nth objects 1))))
      (is (:is-asset (find-block "asset-object" (read/blocks-for-page #(Ok %) db "page")))))))

(deftest graph-blocks-preserve-identities-instants-order-and-decrypt-journal-titles
  (let [conn (new-conn ["block/page" "block/parent" "block/order" "block/created-at" "block/updated-at"
                       "logseq.property/hide?" "block/journal-day"] {})
        page-id "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" block-id "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec9"]
    (transact conn [(journal page-id "Page" 20260815)
                    (block block-id "Desktop seed" page-id page-id 1776000000000
                      [(field "block/order" (ds/String "a1")) (field "block/updated-at" (ds/Instant 1776000000001))])])
    (let [db (ds/conn-db conn) blocks (read/blocks #(Ok %) 7 db) block (nth blocks 0)]
      (is (= (Some page-id) (read/journal-page-uuid db 20260815))) (is (nil? (read/journal-page-uuid db 20260816)))
      (is (= [block-id] (uuids blocks))) (is (= "Desktop seed" (:title block))) (is (= page-id (:page-id block)))
      (is (= (Some "a1") (:order block))) (is (= 1776000000000 (:created-at block)))
      (is (= (Some (tuple "Page" 20260815)) (:journal block))))
    (add conn block-id "block/title" (ds/String "cipher-block")) (add conn page-id "block/title" (ds/String "cipher-page"))
    (let [decrypt (fn [value] (Ok (case value "cipher-block" "Decrypted block" "cipher-page" "Decrypted journal" value)))
          blocks (read/blocks decrypt 7 (ds/conn-db conn))]
      (is (= ["Decrypted block"] (mapv :title blocks)))
      (is (= [(Some (tuple "Decrypted journal" 20260815))] (mapv :journal blocks))))))

(deftest reference-target-renames-refresh-projections-and-public-tags-stay-visible
  (let [conn (new-conn ["block/page" "block/parent" "block/created-at" "block/journal-day" "block/refs"
                       "block/tags" "logseq.property.class/hide-from-node" "db/ident"] {"block/page" one "block/parent" one})]
    (transact conn
      [(entity "tag-class" "Tag" [(field "db/ident" (ds/Keyword "logseq.class/Tag"))])
       (journal "journal" "Journal" 20260817) (page "page-target" "page target" "Page target" [])
       (entity "block-target" "Block target" [(field "block/page" (ds/Ref_to (ds/Temp_id "journal")))
                                               (field "block/parent" (ds/Ref_to (ds/Temp_id "journal")))])
       (page "tag-target" "project" "Project" [(refs "block/tags" ["tag-class"])])
       (page "public-built-in-tag" "card" "Card" [(refs "block/tags" ["tag-class"]) (field "db/ident" (ds/Keyword "logseq.class/Card"))])
       (page "internal-tag" "task" "Task" [(refs "block/tags" ["tag-class"]) (field "db/ident" (ds/Keyword "logseq.class/Task"))])
       (block "source" "Source" "journal" "journal" 1
         [(refs "block/refs" ["page-target" "block-target"]) (refs "block/tags" ["tag-target" "public-built-in-tag" "internal-tag"])])])
    (let [db (ds/conn-db conn) source (find-block "source" (read/blocks #(Ok %) 7 db)) current (projection/create #(Ok %) db)]
      (is (= [(tuple "internal-tag" "Task") (tuple "public-built-in-tag" "Card") (tuple "tag-target" "Project")]
             (summaries (read/tag-pages #(Ok %) db))))
      (is (= [(tuple "block-target" "Block target") (tuple "page-target" "Page target")] (summaries (:references source))))
      (is (= [(tuple "public-built-in-tag" "Card") (tuple "tag-target" "Project")] (summaries (:tags source))))
      (add conn "page-target" "block/title" (ds/String "Renamed page"))
      (projection/update current (ds/conn-db conn) (change 2 [(wire-entity "page-target" "block/title" (transit/String "Renamed page"))] []))
      (is (= [(tuple "block-target" "Block target") (tuple "page-target" "Renamed page")]
             (summaries (:references (find-block "source" (projection/blocks current)))))))))

(deftest sidebar-favorites-preserve-order-and-exclude-hidden-built-in-and-favorite-recents
  (let [conn (new-conn ["block/page" "block/link" "block/order" "block/created-at" "block/updated-at"] {})]
    (transact conn
      [(page "favorites-page" "$$$favorites" "Favorites" [])
       (page "page-alpha" "alpha" "Alpha" [(field "block/updated-at" (ds/Instant 200))])
       (page "page-beta" "beta" "Beta" [(field "block/updated-at" (ds/Instant 300))])
       (page "page-hidden" "hidden" "Hidden" [(field "block/updated-at" (ds/Instant 400)) (field "logseq.property/hide?" (ds/Bool true))])
       (page "page-seeded-recent" "seeded-recent" "Seeded recent" [])
       (page "page-built-in" "built-in-page" "Built-in page" [(field "block/updated-at" (ds/Instant 500)) (field "logseq.property/built-in?" (ds/Bool true))])
       (entity "favorite-alpha" "" [(field "block/page" (ds/Ref_to (ds/Temp_id "favorites-page")))
                                     (field "block/link" (ds/Ref_to (ds/Temp_id "page-alpha"))) (field "block/order" (ds/String "b"))])
       (entity "favorite-beta" "" [(field "block/page" (ds/Ref_to (ds/Temp_id "favorites-page")))
                                    (field "block/link" (ds/Ref_to (ds/Temp_id "page-beta"))) (field "block/order" (ds/String "a"))])
       (entity "alpha-block" "Alpha content" [(field "block/page" (ds/Ref_to (ds/Temp_id "page-alpha")))
                                               (field "block/created-at" (ds/Instant 100)) (field "block/updated-at" (ds/Instant 100))])])
    (let [db (ds/conn-db conn) sidebar (read/sidebar-pages #(Ok %) db)]
      (is (= ["page-beta" "page-alpha"] (uuids (:favorites sidebar))))
      (is (= ["page-seeded-recent"] (uuids (:recent-pages sidebar))))
      (is (not (some #(= "favorites-page" (:uuid %)) (:recent-pages sidebar))))
      (is (= ["alpha-block"] (uuids (read/blocks-for-page #(Ok %) db "page-alpha")))))))

(deftest thousand-journal-graphs-only-materialize-the-requested-window
  (let [conn (new-conn ["block/page" "block/parent" "block/created-at" "block/journal-day"] {})
        decrypted (atom 0) decrypt (fn [value] (swap! decrypted inc) (Ok value))]
    (transact conn (mapcat (fn [index]
                            (let [page-id (str "large-page-" index)]
                              [(journal page-id (str "Journal " index) (+ 2000000 index))
                               (block (str "large-block-" index) (str "Block " index) page-id page-id index [])]))
                          (range 1000)))
    (let [db (ds/conn-db conn) visible (read/blocks decrypt 7 db)]
      (is (= 7 (count visible))) (is (= 14 @decrypted)) (is (= 1000 (read/journal-page-count db)))
      (is (= (mapv #(str "large-block-" (- 999 %)) (range 7)) (uuids visible))))))

(deftest restored-raw-numeric-references-remain-navigable
  (let [conn (new-conn ["block/page" "block/parent" "block/created-at" "block/journal-day"] {"block/page" one "block/parent" one})
        raw (fn [e a v] (ds/Raw_datom (ds/datom :e e :a a :v v)))
        db (ds/db-with
             (list (raw 1 "block/uuid" (ds/Uuid "raw-page")) (raw 1 "block/name" (ds/String "raw-page"))
                   (raw 1 "block/title" (ds/String "Raw journal")) (raw 1 "block/journal-day" (ds/Int 20260817))
                   (raw 2 "block/uuid" (ds/Uuid "raw-block")) (raw 2 "block/title" (ds/String "Restored block"))
                   (raw 2 "block/page" (ds/Int 1)) (raw 2 "block/parent" (ds/Int 1)) (raw 2 "block/created-at" (ds/Instant 1)))
             (ds/conn-db conn))
        blocks (read/blocks #(Ok %) 7 db)]
    (is (= ["raw-block"] (uuids blocks)))
    (let [block (nth blocks 0)]
      (is (= "raw-page" (:page-id block))) (is (= (Some "raw-page") (:parent-id block)))
      (is (= (Some (tuple "Raw journal" 20260817)) (:journal block))))))

(deftest title-normalization-resolves-unique-names-and-shares-new-tags-across-titles
  (let [conn (new-conn ["block/page" "block/parent" "block/refs" "block/tags" "block/created-at" "db/ident"]
                       {"block/name" (assoc string-attr :indexed true)})]
    (transact conn [(entity "tag-class" "Tag" [(field "db/ident" (ds/Keyword "logseq.class/Tag"))])
                    (page "project-tag-uuid" "project" "Project" [(refs "block/tags" ["tag-class"])])
                    (page "roadmap-page-uuid" "roadmap" "Roadmap" [])
                    (page "dup-a-uuid" "dup" "Dup" []) (page "dup-b-uuid" "dup" "Dup" [])
                    (entity "note-uuid" "Note" [(refs "block/refs" ["roadmap-page-uuid"])])])
    (let [db (ds/conn-db conn) normalize (fn [title] (read/normalize-title-text (fn [_] nil) db "note-uuid" title))]
      (run! (fn [[title expected]] (is (= expected (normalize title))))
        [(tuple "Ship [[Roadmap]] as #project and #[[Project]]" "Ship [[roadmap-page-uuid]] as #[[project-tag-uuid]] and #[[project-tag-uuid]]")
         (tuple "todo #PROJECT." "todo #[[project-tag-uuid]].") (tuple "see [[Dup]] and #nothing" "see [[Dup]] and #nothing")
         (tuple "#roadmap stays" "#roadmap stays") (tuple "kept [[roadmap-page-uuid]]" "kept [[roadmap-page-uuid]]")])
      (let [counter (atom 0) fresh (fn [] (swap! counter inc) (str "fresh-" @counter))
            [titles created] (read/normalize-titles-creating-tags db fresh "note-uuid" ["start #foobar" "end #FooBar and #project"])
            [unchanged none-created] (read/normalize-titles-creating-tags db fresh "note-uuid" ["plain #project"])]
        (is (= ["start #[[fresh-1]]" "end #[[fresh-1]] and #[[project-tag-uuid]]"] titles))
        (is (= [(tuple "fresh-1" "foobar")] created))
        (is (= ["plain #[[project-tag-uuid]]"] unchanged)) (is (empty? none-created))))))

(defn recent-page [eid title attributes]
  (entity-input (ds/Entity_id eid)
    (into [(field "block/uuid" (ds/Uuid (str "recent-" eid)))
                             (field "block/name" (ds/String (str "recent-" eid)))
           (field "block/title" (ds/String title)) (field "block/updated-at" (ds/Instant eid))] attributes)))
(deftest recent-window-fills-past-hidden-and-blank-pages-without-decrypting-older-pages
  (let [conn (ds/create-conn) decrypted (atom []) decrypt (fn [title] (swap! decrypted conj title) (Ok title))]
    (transact conn (into (mapv #(recent-page % (str %) []) (range 1 101))
      [(recent-page 101 "Hidden" [(field "logseq.property/hide?" (ds/Bool true))])
       (recent-page 102 "Built-in" [(field "logseq.property/built-in?" (ds/Bool true))])
       (recent-page 103 "Deleted" [(field "logseq.property/deleted-at" (ds/Instant 1))])
       (recent-page 104 "  " []) (recent-page 105 "Hidden child" [(field "block/parent" (ds/Ref 101))])]))
    (is (= (mapv #(str "recent-" (- 100 %)) (range 15)) (uuids (:recent-pages (read/sidebar-pages decrypt (ds/conn-db conn))))))
    (is (not (some #(contains? #{"1" "85"} %) @decrypted)))
    (is (empty? (:recent-pages (read/sidebar-pages #(Ok %) (ds/empty-db)))))))

(deftest built-in-tag-filtering-and-recent-assignment-order-match-logseq
  (let [conn (new-conn ["block/tags" "db/ident"]
                       {"block/uuid" (assoc one :unique (Some (ds/Identity)) :indexed true)
                        "db/ident" (assoc one :unique (Some (ds/Identity)) :indexed true)
                        "block/name" one "block/title" one})]
    (transact conn
      (mapcat (fn [[id name ident]]
                [(ds/Add (ds/Entity_id id) "block/uuid" (ds/Uuid name))
                 (ds/Add (ds/Entity_id id) "block/name" (ds/String (string/lower-case name)))
                 (ds/Add (ds/Entity_id id) "block/title" (ds/String name))
                 (ds/Add (ds/Entity_id id) "db/ident" (ds/Keyword ident))
                 (ds/Add (ds/Entity_id id) "block/tags" (ds/Ref 1))])
        [(tuple 1 "Tag" "logseq.class/Tag") (tuple 2 "Root" "logseq.class/Root") (tuple 3 "Journal" "logseq.class/Journal")
         (tuple 4 "Card" "logseq.class/Card") (tuple 5 "Task" "logseq.class/Task") (tuple 6 "Alpha" "user.class/alpha")
         (tuple 7 "Zeta" "user.class/zeta") (tuple 8 "Asset" "logseq.class/Asset") (tuple 9 "Page" "logseq.class/Page")
         (tuple 10 "Property" "logseq.class/Property") (tuple 11 "Whiteboard" "logseq.class/Whiteboard")
         (tuple 12 "Pdf" "logseq.class/Pdf-annotation")]))
    (transact conn [(ds/Add (ds/Entity_id 20) "block/uuid" (ds/Uuid "older-use")) (ds/Add (ds/Entity_id 20) "block/tags" (ds/Ref 6))])
    (transact conn [(ds/Add (ds/Entity_id 21) "block/uuid" (ds/Uuid "newer-use")) (ds/Add (ds/Entity_id 21) "block/tags" (ds/Ref 7))])
    (let [db (ds/conn-db conn) recent (mapv :title (:recent-pages (read/sidebar-pages #(Ok %) db))) tags (mapv :title (read/tag-pages #(Ok %) db))]
      (is (= ["Alpha" "Zeta"] (vec (sort recent))))
      (is (= ["Alpha" "Card" "Task" "Zeta"] (vec (sort tags))))
      (is (= ["Zeta" "Alpha"] (vec (take 2 tags)))))))
