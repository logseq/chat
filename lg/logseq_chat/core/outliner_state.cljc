(ns logseq-chat.outliner-state
  (:refer-clojure :exclude [empty update drop])
  (:require [clojure.string :as string]
            [clojure.set :as set]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.fractional-order :as order]
            [logseq-chat.ref-text :as ref-text]
            [logseq-chat.search-index :as search]
            [ocaml.String :as bytes]
            [ocaml.Char :as char]))

(type-variant reducer-autocomplete-kind Node Tag Property)

(type-record reducer-autocomplete (kind :reducer-autocomplete-kind) (query :string))

(type-record outliner-candidate (label :string) (value :string))

(type-record editor-draft (uuid :string) (expected-title :string) (title :string) (caret :int))

(type-record outliner-state
             (editing :option<editor-draft>) (selected :set<string>)
             (pending-deletion :list<string>) (autocomplete :option<reducer-autocomplete>)
             (collapsed :set<string>) (zoomed :list<string>))

(type-variant outliner-toolbar
              Task Outdent Indent Tag_action Page_reference Camera Audio Attachment Hide_keyboard
              Copy Delete Copy_reference Copy_url Unselect)

(type-variant outliner-placement Before Inside After)

(type-record outliner-text (title :string) (caret :int))

(type-record outliner-selection (selection-length :int))

(type-record outliner-backspace (title :string) (selection-length :int))

(type-record outliner-drop (target-uuid :string) (placement :outliner-placement))

(type-record outliner-status (uuid :string) (status :ops/semantic-value))

(type-variant outliner-message
              (Tap_block :string) (Long_press_block :string) (Text_changed :outliner-text)
              (Caret_moved :int) Return_pressed (Return_pressed_with_text :outliner-text)
              (Backspace_pressed :outliner-selection) (Backspace_pressed_with_text :outliner-backspace)
              (Toolbar :outliner-toolbar) (Drop_blocks :outliner-drop) (Choose_autocomplete :string)
              Confirm_delete Save_editing Cancel_editing (Set_task_status :outliner-status)
              (Toggle_collapsed :string) (Zoom_in :string) Zoom_out (Add_root_block :string)
              (Operation_staged :ops/pending-intent))

(type-variant outliner-haptic Selection Impact)

(type-record outliner-split (uuid :string) (expected-title :string) (before :string) (after :string))

(type-record outliner-merge
             (uuid :string) (expected-title :string) (title :string)
             (previous-uuid :string) (expected-previous-title :string))

(type-record outliner-tag (uuid :string) (value :string))

(type-record outliner-root (page-uuid :string))

(type-variant outliner-command
              (Haptic :outliner-haptic) (Commit_title :ops/pending-title) (Split_at :outliner-split)
              (Merge_into_previous :outliner-merge) (Reparent_blocks :list<ops/pending-move>)
              (Request_delete_confirmation :list<string>) (Remove_blocks :list<string>)
              (Cycle_task_status :string) (Set_task_status_value :outliner-status)
              (Create_linked_page :string) (Assign_tag :outliner-tag) (Pick_attachment :string)
              (Take_photo :string) (Record_audio :string) (Insert_root_block :outliner-root)
              (Copy_text :string) (Copy_references :list<string>) (Copy_urls :list<string>))

(type-record outliner-context
             (blocks :list<model/block>) (pages :list<outliner-candidate>) (tags :list<outliner-candidate>))

(type-record outliner-row (block :model/block) (depth :int) (has-children :bool) (is-collapsed :bool))

(def ^:set<string> empty-uuids #{})

(def empty
  (record outliner-state (editing nil) (selected empty-uuids) (pending-deletion (list))
          (autocomplete nil) (collapsed empty-uuids) (zoomed (list))))

(defn editing-uuid [^:outliner-state state] (some-> (:editing state) :uuid))

(defn editing-title [^:outliner-state state] (some-> (:editing state) :title))

(defn selected-uuids [^:outliner-state state] (sort (:selected state)))

(defn collapsed-uuids [^:outliner-state state] (sort (:collapsed state)))

(defn autocomplete [^:outliner-state state] (:autocomplete state))

(defn zoom-path [^:outliner-state state] (:zoomed state))

(defn find-block [^:outliner-context context uuid] (some #(when (= (:uuid %) uuid) %) (:blocks context)))

(defn duplicated-labels [candidates]
  (let [by-label (group-by #(bytes/lowercase-ascii (:label %)) candidates)]
    (into empty-uuids (keep (fn [[label values]]
                      (when (> (count (set (map :value values))) 1) label)) by-label))))

(defn summary-candidates [^:seq<model/entity-summary> summaries]
  (mapv #(record outliner-candidate (label (:title %)) (value (:uuid %))) summaries))

(defn summary-title [duplicated ^:seq<model/entity-summary> summaries uuid]
  (some #(when (and (= (:uuid %) uuid) (not (string/blank? (:title %)))
                    (not (contains? duplicated (bytes/lowercase-ascii (:title %)))))
           (:title %)) summaries))

(defn display-block-title [context block]
  (let [candidates (concat (:pages context) (:tags context)
                           (summary-candidates (concat (:references block) (:tags block))))
        duplicated (duplicated-labels candidates)]
    (ref-text/to-text
     #(summary-title duplicated (concat (:tags block) (:references block)) %)
     #(summary-title duplicated (concat (:references block) (:tags block)) %)
     (:title block))))

(defn utf8-sequence-length [byte]
  (cond (= 0 (bit-and byte 128)) 1 (= 192 (bit-and byte 224)) 2
        (= 224 (bit-and byte 240)) 3 (= 240 (bit-and byte 248)) 4 :else 1))

(defn utf16-units [byte] (if (= 4 (utf8-sequence-length byte)) 2 1))

(defn byte-index-of-utf16 [value offset]
  (loop [index 0 units 0]
    (if (or (>= index (bytes/length value)) (>= units (max 0 offset))) index
        (let [byte (char/code (bytes/get value index))]
          (recur (min (bytes/length value) (+ index (utf8-sequence-length byte)))
                 (+ units (utf16-units byte)))))))

(defn utf16-length [value]
  (loop [index 0 units 0]
    (if (>= index (bytes/length value)) units
        (let [byte (char/code (bytes/get value index))]
          (recur (min (bytes/length value) (+ index (utf8-sequence-length byte)))
                 (+ units (utf16-units byte)))))))

(defn prefix-at [value caret] (bytes/sub value 0 (byte-index-of-utf16 value caret)))

(defn last-substring [value needle]
  (let [size (bytes/length needle)]
    (when (pos? size)
      (loop [index 0 found nil]
        (if (> (+ index size) (bytes/length value)) found
            (recur (inc index) (if (= (bytes/sub value index size) needle) (Some index) found)))))))

(defn contains-substring [value needle] (string/includes? value needle))

(defn includes-normalized-query [value query]
  (or (= query "") (string/includes? (bytes/lowercase-ascii value) query)))

(defn includes-case-insensitive [value query]
  (includes-normalized-query value (bytes/lowercase-ascii (string/trim query))))

(defn autocomplete-candidates [context request]
  (let [query (string/trim (:query request)) normalized (bytes/lowercase-ascii query)
        raw (match (:kind request)
              Node (concat (:pages context) (map #(record outliner-candidate (label (:title %)) (value (:uuid %))) (:blocks context)))
              Tag (seq (:tags context))
              Property (map #(record outliner-candidate (label %) (value %)) ["status" "tags" "alias" "priority"]))
        fuzzy (and (= (:kind request) Tag) (not= normalized ""))
        seen (atom empty-uuids)
        matches (filter (fn [candidate]
                          (and (not (string/blank? (:label candidate)))
                               (if fuzzy (> (search/fuzzy-score normalized (:label candidate)) 0.0)
                                   (includes-normalized-query (:label candidate) normalized))
                               (if (contains? @seen (:value candidate)) false
                                   (do (swap! seen conj (:value candidate)) true)))) raw)
        matches (vec (take 12 (if fuzzy (sort-by #(- 0.0 (search/fuzzy-score normalized (:label %))) matches) matches)))
        matches (cond
                  (and (= (:kind request) Tag) (not= query "")
                       (not-any? #(= (bytes/lowercase-ascii (:label %)) normalized) matches))
                  (conj matches (record outliner-candidate (label (str "New tag: " query)) (value query)))
                  (and (= (:kind request) Node) (empty? matches) (not= query ""))
                  [(record outliner-candidate (label (str "New page: " query)) (value query))]
                  :else matches)]
    (apply list matches)))

(defn contains-from [value start needle]
  (some? (last-substring (bytes/sub value start (- (bytes/length value) start)) needle)))

(defn token-request [kind marker prefix]
  (when-some [index (bytes/rindex-opt prefix marker)]
    (let [query (bytes/sub prefix (inc index) (- (bytes/length prefix) index 1))]
      (when (not (string/includes? query "\n")) (record reducer-autocomplete (kind kind) (query query))))))

(defn autocomplete-for [title caret]
  (let [prefix (prefix-at title caret)]
    (match (last-substring prefix "[[")
      (Some index)
      (if (not (contains-from prefix (+ index 2) "]]"))
        (Some (record reducer-autocomplete (kind Node) (query (bytes/sub prefix (+ index 2) (- (bytes/length prefix) index 2)))))
        (if-some [index (last-substring prefix "::")]
          (let [start (or (some-> (bytes/rindex-from-opt prefix index \newline) inc) 0)]
            (Some (record reducer-autocomplete (kind Property) (query (bytes/sub prefix start (- index start))))))
          (token-request Tag \# prefix)))
      None
      (if-some [index (last-substring prefix "::")]
        (let [start (or (some-> (bytes/rindex-from-opt prefix index \newline) inc) 0)]
          (Some (record reducer-autocomplete (kind Property) (query (bytes/sub prefix start (- index start))))))
        (token-request Tag \# prefix)))))

(defn replace-range [value start finish replacement]
  (str (bytes/sub value 0 start) replacement (bytes/sub value finish (- (bytes/length value) finish))))

(defn candidate-label [context ^:seq<outliner-candidate> candidates value]
  (let [duplicated (duplicated-labels (concat (:pages context) (:tags context)))]
    (some #(when (and (= (:value %) value) (not (string/blank? (:label %)))
                      (not (contains? duplicated (bytes/lowercase-ascii (:label %))))) (:label %)) candidates)))

(defn reference-token-end [title caret-byte]
  (let [size (bytes/length title)]
    (loop [index caret-byte]
      (cond (>= index size) caret-byte
            (= (bytes/get title index) \newline) caret-byte
            (and (< (inc index) size) (= (bytes/sub title index 2) "[[")) caret-byte
            (= (bytes/get title index) \])
            (cond (and (< (inc index) size) (= (bytes/get title (inc index)) \])) (+ index 2)
                  (= index caret-byte) (inc index) :else caret-byte)
            :else (recur (inc index))))))

(defn ^:option<editor-draft> complete [context ^:editor-draft editing kind ^:string value]
  (let [caret-byte (byte-index-of-utf16 (:title editing) (:caret editing))
        prefix (bytes/sub (:title editing) 0 caret-byte)
        completion
        (match kind
          Node (let [text (or (candidate-label context (concat (:pages context) (:tags context)) value) value)]
                 (some-> (last-substring prefix "[[") ((fn [index] (tuple index (str "[[" text "]]"))))))
          Tag (let [label (candidate-label context (:tags context) value)
                    text (or label value)
                    plain (and (ref-text/plain-tag-label? text) (or (some? label) (not (ref-text/is-uuid? value))))]
                (some-> (bytes/rindex-opt prefix \#) ((fn [index] (tuple index (if plain (str "#" text) (str "#[[" text "]]")))))))
          Property (Some (tuple (or (some-> (bytes/rindex-opt prefix \newline) inc) 0) (str value ":: "))))]
    (when-some [[start replacement] completion]
      (let [finish (if (= kind Node) (reference-token-end (:title editing) caret-byte) caret-byte)
            title (replace-range (:title editing) start finish replacement)]
        (assoc editing :title title :caret (utf16-length (bytes/sub title 0 (+ start (bytes/length replacement)))))))))

(defn trim-right [value]
  (loop [finish (bytes/length value)]
    (if (and (pos? finish) (contains? #{\space \tab \newline \return} (bytes/get value (dec finish))))
      (recur (dec finish)) (bytes/sub value 0 finish))))

(defn ^:option<editor-draft> remove-tag-token [^:editor-draft editing]
  (let [index (byte-index-of-utf16 (:title editing) (:caret editing))]
    (when-some [start (bytes/rindex-opt (bytes/sub (:title editing) 0 index) \#)]
      (let [before (trim-right (bytes/sub (:title editing) 0 start))
            suffix (bytes/sub (:title editing) index (- (bytes/length (:title editing)) index))
            separator (if (or (= before "") (= suffix "") (string/starts-with? suffix " ") (string/starts-with? suffix "\n")) "" " ")]
        (assoc editing :title (str before separator suffix) :caret (utf16-length before))))))

(defn commit-effect [context ^:option<editor-draft> editing]
  (apply list
         (if-some [editing editing]
           (let [expected (if-some [block (find-block context (:uuid editing))]
                            (display-block-title context (assoc block :title (:expected-title editing)))
                            (:expected-title editing))]
             (if (= expected (:title editing)) []
                 [(Commit_title (record ops/pending-title (uuid (:uuid editing))
                                        (expected-title (:expected-title editing)) (title (:title editing))))])) [])))

(defn insert-at-caret [^:editor-draft editing ^:string text backward-utf16]
  (let [index (byte-index-of-utf16 (:title editing) (:caret editing))
        prefix (bytes/sub (:title editing) 0 index)
        inserted (str (if (or (= prefix "") (string/ends-with? prefix " ")) "" " ") text)]
    (assoc editing :title (replace-range (:title editing) index index inserted)
           :caret (- (utf16-length (str prefix inserted)) backward-utf16))))

(defn compare-blocks [left right]
  (match (tuple (:order left) (:order right))
    (tuple (Some a) (Some b))
    (if (not= a b) (compare a b)
        (let [created (compare (:created-at left) (:created-at right))]
          (if (not= created 0) created (compare (:uuid left) (:uuid right)))))
    (tuple (Some _) None) -1 (tuple None (Some _)) 1
    _ (let [created (compare (:created-at left) (:created-at right))]
        (if (not= created 0) created (compare (:uuid left) (:uuid right))))))

(defn compare-root-blocks [left right]
  (match (tuple (:journal left) (:journal right))
    (tuple (Some [_ a]) (Some [_ b])) (if (not= a b) (compare b a) (compare-blocks left right))
    _ (compare-blocks left right)))

(defn ^:list<model/block> sorted-siblings [^:outliner-context context parent]
  (sort compare-blocks (filter #(= (:parent-id %) parent) (:blocks context))))

(defn visible-rows [^:outliner-context context ^:outliner-state state]
  (let [ids (set (map :uuid (:blocks context)))
        children-by-parent (into {} (map (fn [[parent children]] (tuple parent (vec (sort compare-blocks children))))
                                         (group-by :parent-id (:blocks context))))
        children (fn [^:string uuid] (or (get children-by-parent (Some uuid)) []))
        roots (sort compare-root-blocks
                    (filter #(if-some [parent (:parent-id %)] (not (contains? ids parent)) true) (:blocks context)))
        visited (atom empty-uuids)]
    (letfn [(hide-descendants [uuid]
              (run! (fn [^:model/block block]
                      (when (not (contains? @visited (:uuid block)))
                        (swap! visited conj (:uuid block)) (hide-descendants (:uuid block)))) (children uuid)))
            (append-row [depth ^:vector<outliner-row> rows ^:model/block block]
              (if (contains? @visited (:uuid block)) rows
                  (do (swap! visited conj (:uuid block))
                      (let [descendants (children (:uuid block)) collapsed (contains? (:collapsed state) (:uuid block))
                            rows (conj rows (record outliner-row (block block) (depth depth)
                                                    (has-children (not (empty? descendants))) (is-collapsed collapsed)))]
                        (if collapsed (do (hide-descendants (:uuid block)) rows)
                            (reduce (fn [rows child] (append-row (inc depth) rows child)) rows descendants))))))]
      (let [rows (if-some [root (some-> (last (:zoomed state)) ((fn [uuid] (find-block context uuid))))]
                   (append-row 0 [] root) (reduce #(append-row 0 %1 %2) [] roots))
            rows (if (empty? (:zoomed state)) (reduce #(append-row 0 %1 %2) rows (:blocks context)) rows)]
        (apply list rows)))))

(defn ^:list<model/block> selected-roots [^:outliner-context context ^:set<string> selected]
  (let [by-uuid (into {} (map #(tuple (:uuid %) %) (:blocks context)))
        selected-ancestor? (fn [^:model/block block]
                            (let [visited (atom empty-uuids)]
                             (loop [parent (:parent-id block)]
                               (if-some [uuid parent]
                                 (cond (contains? @visited uuid) false (contains? selected uuid) true
                                       :else (do (swap! visited conj uuid)
                                                 (recur (match (get by-uuid uuid) (Some ancestor) (:parent-id ancestor) None None)))) false))))]
    (apply list (filter #(and (contains? selected (:uuid %)) (not (selected-ancestor? %))) (:blocks context)))))

(defn moves-with-orders [^:list<model/block> roots parent-uuid ^:option<string> lower ^:option<string> upper]
  (match (order/n-between lower upper (count roots))
    (Error _) nil
    (Ok orders)
    (Some (apply list
                 (map (fn [block value]
                        (record ops/pending-move
                                (uuid (:uuid block)) (page-uuid (:page-id block))
                                (parent-uuid parent-uuid) (order value)))
                      roots orders)))))

(defn index-of-uuid [uuid ^:seqable<model/block> blocks]
  (some (fn [[index block]] (when (= (:uuid block) uuid) index)) (map-indexed (fn [index block] (tuple index block)) blocks)))

(defn selection-indices [^:seq<model/block> roots ^:seq<model/block> siblings]
  (let [ids (set (map :uuid roots))]
    (vec (keep (fn [[index block]] (when (contains? ids (:uuid block)) index)) (map-indexed (fn [index block] (tuple index block)) siblings)))))

(defn selection-is-contiguous [^:seq<model/block> roots ^:seq<model/block> siblings]
  (let [indices (selection-indices roots siblings)]
    (and (not (empty? indices)) (= (count indices) (count roots))
         (every? identity (map-indexed (fn [offset index] (= index (+ (nth indices 0) offset))) indices)))))

(defn same-parent? [roots ^:option<string> parent] (every? #(= (:parent-id %) parent) roots))

(defn indent [^:outliner-context context selected]
  (let [roots (selected-roots context selected)]
    (when-some [first (first roots)]
      (let [siblings (vec (sorted-siblings context (:parent-id first))) indices (selection-indices roots siblings)]
        (when (and (same-parent? roots (:parent-id first)) (not (empty? indices))
                   (pos? (nth indices 0)) (selection-is-contiguous roots siblings))
          (let [^:model/block parent (nth siblings (dec (nth indices 0))) children (sorted-siblings context (Some (:uuid parent)))]
            (moves-with-orders roots (:uuid parent) (some-> (last children) :order) nil)))))))

(defn outdent [^:outliner-context context selected]
  (let [roots (selected-roots context selected)]
    (when-some [first (first roots)]
      (when (same-parent? roots (:parent-id first))
        (when-some [parent (some-> (:parent-id first) ((fn [uuid] (find-block context uuid))))]
          (when (selection-is-contiguous roots (sorted-siblings context (Some (:uuid parent))))
            (let [parent-uuid (or (:parent-id parent) (:page-id parent)) siblings (vec (sorted-siblings context (Some parent-uuid)))]
              (when-some [index (index-of-uuid (:uuid parent) siblings)]
                (moves-with-orders roots parent-uuid (:order parent)
                                   (when (< (inc index) (count siblings)) (:order (nth siblings (inc index)))))))))))))

(defn ancestor-uuids [context ^:model/block block]
  (let [visited (atom empty-uuids)]
    (loop [parent (:parent-id block)]
      (if-some [uuid parent]
        (if (contains? @visited uuid) @visited
            (do (swap! visited conj uuid)
                (recur (match (find-block context uuid) (Some ancestor) (:parent-id ancestor) None None)))) @visited))))

(defn drop [context selected ^:string target-uuid placement]
  (let [roots (selected-roots context selected) ids (set (map :uuid roots))]
    (when (not (empty? roots))
      (when-some [target (find-block context target-uuid)]
        (when (and (not (contains? ids target-uuid)) (empty? (set/intersection ids (ancestor-uuids context target))))
          (if (= placement Inside)
            (moves-with-orders roots (:uuid target) (some-> (last (sorted-siblings context (Some (:uuid target)))) :order) nil)
            (let [parent (or (:parent-id target) (:page-id target))
                  siblings (vec (remove #(contains? ids (:uuid %)) (sorted-siblings context (Some parent))))]
              (when-some [index (index-of-uuid target-uuid siblings)]
                (if (= placement Before)
                  (moves-with-orders roots parent (when (pos? index) (:order (nth siblings (dec index)))) (:order target))
                  (moves-with-orders roots parent (:order target) (when (< (inc index) (count siblings)) (:order (nth siblings (inc index))))))))))))))

(defn step [^:outliner-state state ^:seq<outliner-command> commands] (tuple state (apply list commands)))

(defn leave-interaction [context ^:outliner-state state]
  (step (assoc state :editing nil :selected empty-uuids :autocomplete nil) (commit-effect context (:editing state))))

(defn split-editing [^:outliner-state state editing]
  (let [index (byte-index-of-utf16 (:title editing) (:caret editing))]
    (step (assoc state :editing nil :autocomplete nil)
          [(Split_at (record outliner-split (uuid (:uuid editing)) (expected-title (:expected-title editing))
                             (before (bytes/sub (:title editing) 0 index))
                             (after (bytes/sub (:title editing) index (- (bytes/length (:title editing)) index)))))])))

(defn split-or-outdent [context ^:outliner-state state ^:editor-draft editing]
  (let [final-nested-empty?
        (if-some [block (find-block context (:uuid editing))]
          (and (string/blank? (:title editing)) (not= (:parent-id block) (Some (:page-id block)))
               (= (some-> (last (sorted-siblings context (:parent-id block))) :uuid) (Some (:uuid block)))) false)]
    (if final-nested-empty?
      (if-some [moves (outdent context #{(:uuid editing)})]
        (step (assoc state :editing (Some editing) :autocomplete nil)
              (concat (commit-effect context (Some editing)) [(Reparent_blocks moves)]))
        (split-editing state editing))
      (split-editing state editing))))

(defn start-editing [context ^:outliner-state state block caret]
  (assoc state :editing (Some (record editor-draft (uuid (:uuid block)) (expected-title (:title block))
                                      (title (display-block-title context block)) (caret caret)))
         :autocomplete nil))

(defn merge-backward [context ^:outliner-state state ^:editor-draft editing]
  (if-some [block (find-block context (:uuid editing))]
    (let [rows (vec (filter (fn [^:outliner-row row] (= (:page-id (:block row)) (:page-id block))) (visible-rows context state)))
          index (or (some (fn [[index row]] (when (= (:uuid (:block row)) (:uuid editing)) index))
                          (map-indexed (fn [index row] (tuple index row)) rows)) (count rows))]
      (cond
          (pos? index)
          (let [previous (:block (nth rows (dec index)))]
            (step state [(Merge_into_previous (record outliner-merge (uuid (:uuid editing)) (expected-title (:expected-title editing))
                                                 (title (:title editing)) (previous-uuid (:uuid previous))
                                                 (expected-previous-title (:title previous))))]))
          (< (inc index) (count rows))
          (step (start-editing context state (:block (nth rows (inc index))) 0) [(Remove_blocks (list (:uuid editing)))])
          :else (step state [])))
    (step state [])))

(defn toggle-member [^:set<string> values ^:string value] (if (contains? values value) (disj values value) (conj values value)))

(defn interaction-targets [^:outliner-state state]
  (if (empty? (:selected state)) (if-some [editing (:editing state)] #{(:uuid editing)} empty-uuids) (:selected state)))

(defn toolbar-insert [^:outliner-state state text backward]
  (if-some [editing (:editing state)]
    (let [editing (insert-at-caret editing text backward)]
      (step (assoc state :editing (Some editing) :autocomplete (autocomplete-for (:title editing) (:caret editing))) [(Haptic Impact)]))
    (step state [])))

(defn toolbar-move [context ^:outliner-state state outdent?]
  (let [moves (if outdent? (outdent context (interaction-targets state)) (indent context (interaction-targets state)))]
    (step state (if-some [moves moves] [(Reparent_blocks moves) (Haptic Impact)] [(Haptic Impact)]))))

(defn choose-completion [context ^:outliner-state state value]
  (match (tuple (:editing state) (:autocomplete state))
    (tuple (Some editing) (Some request))
    (if (= (:kind request) Tag)
      (if-some [editing (remove-tag-token editing)]
        (step (assoc state :editing (Some editing) :autocomplete nil)
              [(Assign_tag (record outliner-tag (uuid (:uuid editing)) (value value))) (Haptic Selection)])
        (step state []))
      (if-some [editing (complete context editing (:kind request) value)]
        (let [create? (and (= (:kind request) Node) (not (ref-text/is-uuid? value))
                           (not-any? #(= (:value %) value) (:pages context))
                           (not-any? #(= (:uuid %) value) (:blocks context)))]
          (step (assoc state :editing (Some editing) :autocomplete nil)
                (if create? [(Create_linked_page value) (Haptic Selection)] [(Haptic Selection)])))
        (step state [])))
    _ (step state [])))

(defn staged-editing [context ^:outliner-state state uuid fallback at-start?]
  (let [[expected display] (if-some [block (find-block context uuid)]
                             (tuple (:title block) (display-block-title context block)) (tuple fallback fallback))]
    (step (assoc state :editing (Some (record editor-draft (uuid uuid) (expected-title expected)
                                              (title display) (caret (if at-start? 0 (utf16-length display)))))
                 :selected empty-uuids :autocomplete nil) [])))

(defn update [context ^:outliner-state state message]
  (let [^:outliner-state state (assoc state :zoomed (apply list (take-while #(some? (find-block context %)) (:zoomed state))))]
    (match message
      (Tap_block uuid)
      (if (not (empty? (:selected state)))
        (step (assoc state :selected (toggle-member (:selected state) uuid)) [])
        (if-some [block (find-block context uuid)]
          (step (assoc (start-editing context state block (utf16-length (display-block-title context block))) :selected empty-uuids)
                (commit-effect context (:editing state))) (step state [])))
      (Long_press_block uuid)
      (step (assoc state :editing nil :selected #{uuid} :autocomplete nil)
            (concat (commit-effect context (:editing state)) [(Haptic Selection)]))
      (Text_changed value)
      (if-some [editing (:editing state)]
        (step (assoc state :editing (Some (assoc editing :title (:title value) :caret (:caret value)))
                     :autocomplete (autocomplete-for (:title value) (:caret value))) []) (step state []))
      (Caret_moved caret)
      (if-some [editing (:editing state)]
        (step (assoc state :editing (Some (assoc editing :caret caret)) :autocomplete (autocomplete-for (:title editing) caret)) [])
        (step state []))
      (Choose_autocomplete value) (choose-completion context state value)
      Return_pressed
      (if-some [editing (:editing state)] (split-or-outdent context state editing) (step state []))
      (Return_pressed_with_text value)
      (if-some [editing (:editing state)]
        (split-or-outdent context state (assoc editing :title (:title value) :caret (:caret value))) (step state []))
      (Backspace_pressed value)
      (if-some [editing (:editing state)]
        (if (and (= (:selection-length value) 0) (= (:caret editing) 0)) (merge-backward context state editing) (step state []))
        (step state []))
      (Backspace_pressed_with_text value)
      (if-some [editing (:editing state)]
        (if (= (:selection-length value) 0) (merge-backward context state (assoc editing :title (:title value) :caret 0)) (step state []))
        (step state []))
      (Toolbar Indent) (toolbar-move context state false)
      (Toolbar Outdent) (toolbar-move context state true)
      (Toolbar Delete)
      (let [uuids (selected-uuids state)]
        (step (assoc state :selected empty-uuids :pending-deletion uuids) [(Request_delete_confirmation uuids) (Haptic Impact)]))
      Confirm_delete
      (let [uuids (if (empty? (:pending-deletion state)) (selected-uuids state) (:pending-deletion state))]
        (if (empty? uuids) (step state [])
            (step (assoc state :selected empty-uuids :pending-deletion (list)) [(Remove_blocks uuids)])))
      (Toolbar Unselect) (step (assoc state :selected empty-uuids) [(Haptic Impact)])
      (Toolbar Task)
      (if-some [editing (:editing state)] (step state [(Cycle_task_status (:uuid editing)) (Haptic Impact)]) (step state []))
      (Toolbar Hide_keyboard)
      (step (assoc state :editing nil :autocomplete nil) (concat (commit-effect context (:editing state)) [(Haptic Impact)]))
      Save_editing (step state (commit-effect context (:editing state)))
      Cancel_editing (step (assoc state :editing nil :autocomplete nil) (commit-effect context (:editing state)))
      (Toolbar Tag_action) (toolbar-insert state "#" 0)
      (Toolbar Page_reference) (toolbar-insert state "[[]]" 2)
      (Toolbar Camera)
      (if-some [editing (:editing state)] (step state [(Take_photo (:uuid editing)) (Haptic Impact)]) (step state []))
      (Toolbar Audio)
      (if-some [editing (:editing state)] (step state [(Record_audio (:uuid editing)) (Haptic Impact)]) (step state []))
      (Toolbar Attachment)
      (if-some [editing (:editing state)] (step state [(Pick_attachment (:uuid editing)) (Haptic Impact)]) (step state []))
      (Toolbar Copy)
      (step (assoc state :selected empty-uuids)
            [(Copy_text (string/join "\n" (map :title (filter #(contains? (:selected state) (:uuid %)) (:blocks context))))) (Haptic Impact)])
      (Toolbar Copy_reference) (step (assoc state :selected empty-uuids) [(Copy_references (selected-uuids state)) (Haptic Impact)])
      (Toolbar Copy_url) (step (assoc state :selected empty-uuids) [(Copy_urls (selected-uuids state)) (Haptic Impact)])
      (Drop_blocks value)
      (if-some [moves (drop context (:selected state) (:target-uuid value) (:placement value))]
        (step (assoc state :selected empty-uuids) [(Reparent_blocks moves) (Haptic Impact)]) (step state []))
      (Set_task_status value) (step state [(Set_task_status_value value) (Haptic Impact)])
      (Toggle_collapsed uuid)
      (step (assoc state :collapsed (toggle-member (:collapsed state) uuid) :editing nil :autocomplete nil)
            (concat (commit-effect context (:editing state)) [(Haptic Impact)]))
      (Zoom_in uuid)
      (if (some? (find-block context uuid))
        (let [[state effects] (leave-interaction context state)
              zoomed (if (= (last (:zoomed state)) (Some uuid)) (:zoomed state) (apply list (concat (:zoomed state) [uuid])))]
          (step (assoc state :zoomed zoomed) (concat effects [(Haptic Selection)]))) (step state []))
      Zoom_out
      (let [[state effects] (leave-interaction context state)]
        (step (assoc state :zoomed (apply list (take (max 0 (dec (count (:zoomed state)))) (:zoomed state))))
              (concat effects [(Haptic Selection)])))
      (Add_root_block page-uuid)
      (let [[state effects] (leave-interaction context state)]
        (step state (concat effects [(Insert_root_block (record outliner-root (page-uuid page-uuid))) (Haptic Impact)])))
      (Operation_staged intent)
      (match intent
        (ops/Split-block value) (staged-editing context state (:new-uuid value) (:after value) true)
        (ops/Insert-block value) (staged-editing context state (:uuid value) (:title value) false)
        (ops/Merge-backward value)
        (if-some [block (find-block context (:previous-uuid value))]
          (staged-editing context state (:uuid block) (:title block) false) (step state []))
        (ops/Save-title value)
        (if-some [editing (:editing state)]
          (if (= (:uuid editing) (:uuid value))
            (step (assoc state :editing (Some (assoc editing :expected-title (:title value)))) []) (step state [])) (step state []))
        _ (step state [])))))
