(ns logseq-chat.outliner-state-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.outliner-state :as state]
            [logseq-chat.cache-model :as model]
            [logseq-chat.pending-ops :as ops]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]))

(defn block [uuid title]
  (record model/block (uuid uuid) (title title) (page-id "page") (parent-id (Some "page")) (order (Some "a0"))
          (created-at 0) (updated-at 0) (sync-status "synced") (tags (list)) (references (list)) (breadcrumbs (list))
          (status None) (is-asset false) (asset-type None) (asset-size None) (asset-checksum None) (local-path None) (journal None)))
(defn row [uuid parent order] (assoc (block uuid uuid) :parent-id (Some parent) :order (Some order)))
(defn context-for [blocks]
  (record state/outliner-context (blocks (apply list blocks)) (pages (list)) (tags (list))))
(def context (context-for [(block "a" "Alpha") (assoc (block "b" "Beta") :order (Some "a1"))]))
(defn candidate [label value] (record state/outliner-candidate (label label) (value value)))
(defn request [kind query] (record state/reducer-autocomplete (kind kind) (query query)))
(defn text [title caret] (record state/outliner-text (title title) (caret caret)))
(defn step [ctx current message]
  (let [[next commands] (state/update ctx current message)] (tuple next (vec commands))))
(defn advance [ctx current messages]
  (reduce (fn [current message] (key (step ctx current message))) current messages))
(defn start [ctx uuid title caret]
  (advance ctx state/empty [(state/Tap_block uuid) (state/Text_changed (text title caret))]))
(defn commit [uuid expected title]
  (state/Commit_title (record ops/pending-title (uuid uuid) (expected-title expected) (title title))))
(defn split [uuid expected before after]
  (state/Split_at (record state/outliner-split (uuid uuid) (expected-title expected) (before before) (after after))))
(defn merge-command [title]
  (state/Merge_into_previous (record state/outliner-merge (uuid "b") (expected-title "Beta") (title title)
                                     (previous-uuid "a") (expected-previous-title "Alpha"))))
(defn backspace [selection] (state/Backspace_pressed (record state/outliner-selection (selection-length selection))))
(defn atomic-backspace [title selection]
  (state/Backspace_pressed_with_text (record state/outliner-backspace (title title) (selection-length selection))))
(defn visible-ids [ctx current] (mapv (fn [row] (:uuid (:block row))) (state/visible-rows ctx current)))
(defn selected [current] (vec (state/selected-uuids current)))
(defn zoom-path [current] (vec (state/zoom-path current)))

(deftest journal-roots-stay-grouped-newest-first
  (let [journal-row (fn [uuid page order title day]
                      (assoc (row uuid page order) :page-id page :journal (Some (tuple title day))))
        ctx (context-for [(journal-row "older-first" "older-page" "a0" "Older" 20260827)
                          (journal-row "newer-second" "newer-page" "a1" "Newer" 20260828)
                          (journal-row "older-second" "older-page" "a1" "Older" 20260827)
                          (journal-row "newer-first" "newer-page" "a0" "Newer" 20260828)])]
    (is (= ["newer-first" "newer-second" "older-first" "older-second"] (visible-ids ctx state/empty)))))

(deftest editing-and-page-completion-are-pure-until-a-command-is-needed
  (let [[editing commands] (step context state/empty (state/Tap_block "a"))
        [changed changes] (step context editing (state/Text_changed (text "A [[Pro" 7)))
        [completed effects] (step context changed (state/Choose_autocomplete "Project"))]
    (is (= (Some "a") (state/editing-uuid editing))) (is (empty? commands)) (is (empty? changes))
    (is (= (Some (request state/Node "Pro")) (state/autocomplete changed)))
    (is (= (Some "A [[Project]]") (state/editing-title completed)))
    (is (= [(state/Create_linked_page "Project") (state/Haptic state/Selection)] effects))))

(deftest tag-completion-removes-inline-tokens-and-keeps-editing
  (run! (fn [[label title]]
          (let [ctx (assoc (context-for [(block "a" "Alpha")]) :tags (list (candidate label "tag-uuid")))
                editing (start ctx "a" title 10)
                [completed commands] (step ctx editing (state/Choose_autocomplete "tag-uuid"))]
            (when (= label "Project") (is (= (Some (request state/Tag "Pro")) (state/autocomplete editing))))
            (is (= (Some "Alpha") (state/editing-title completed)))
            (is (= (Some "a") (state/editing-uuid completed))) (is (= 2 (count commands)))))
        [(tuple "Project" "Alpha #Pro") (tuple "favorite book" "Alpha #fav")]))

(defn summary [uuid title] (record model/entity-summary (uuid uuid) (title title)))
(deftest display-references-resolve-names-but-preserve-ambiguous-uuids
  (let [stored (assoc (block "a" "Ship [[page-uuid-1]] with #[[tag-uuid-1]] and #[[tag-uuid-2]]")
                      :references (list (summary "page-uuid-1" "Roadmap"))
                      :tags (list (summary "tag-uuid-1" "Project") (summary "tag-uuid-2" "favorite book")))
        ctx (context-for [stored]) [editing _] (step ctx state/empty (state/Tap_block "a"))]
    (is (= (Some "Ship [[Roadmap]] with #Project and #[[favorite book]]") (state/editing-title editing)))
    (is (empty? (val (step ctx editing state/Cancel_editing)))))
  (let [stored (assoc (block "a" "See [[page-uuid-1]] or [[page-uuid-2]]")
                      :references (list (summary "page-uuid-1" "Roadmap") (summary "page-uuid-2" "roadmap")))
        [editing _] (step (context-for [stored]) state/empty (state/Tap_block "a"))]
    (is (= (Some "See [[page-uuid-1]] or [[page-uuid-2]]") (state/editing-title editing)))))

(def tree (context-for [(block "parent" "Parent") (assoc (block "child" "Child") :parent-id (Some "parent"))
                        (assoc (block "sibling" "Sibling") :order (Some "a1"))]))
(deftest collapse-and-zoom-own-visible-subtrees
  (let [[collapsed commands] (step tree state/empty (state/Toggle_collapsed "parent"))
        [zoomed zoom-commands] (step tree collapsed (state/Zoom_in "parent"))
        [back _] (step tree zoomed state/Zoom_out)
        rows (state/visible-rows tree zoomed)]
    (is (= [(state/Haptic state/Impact)] commands))
    (is (= ["parent" "sibling"] (visible-ids tree collapsed)))
    (is (= [(state/Haptic state/Selection)] zoom-commands))
    (is (= ["parent"] (visible-ids tree zoomed)))
    (is (= 0 (:depth (or (first rows) (stdlib/failwith "missing zoom root")))))
    (is (= ["parent" "sibling"] (visible-ids tree back)))))

(deftest navigation-commits-drafts-and-clears-editing-and-selection
  (let [editing (start tree "parent" "Changed" 7)
        [navigated commands] (step tree editing (state/Zoom_in "child"))]
    (is (nil? (state/editing-uuid navigated))) (is (empty? (selected navigated)))
    (is (= [(commit "parent" "Parent" "Changed") (state/Haptic state/Selection)] commands)))
  (let [selected (advance tree state/empty [(state/Long_press_block "parent") (state/Zoom_in "parent")])]
    (is (empty? (state/selected-uuids selected))))
  (let [zoomed (key (step tree state/empty (state/Zoom_in "parent")))
        editing (advance tree zoomed [(state/Tap_block "child") (state/Text_changed (text "Edited child" 12))])
        [back commands] (step tree editing state/Zoom_out)
        selected-back (advance tree zoomed [(state/Long_press_block "child") state/Zoom_out])]
    (is (nil? (state/editing-uuid back))) (is (empty? (zoom-path back)))
    (is (= [(commit "child" "Child" "Edited child") (state/Haptic state/Selection)] commands))
    (is (empty? (selected selected-back)))))

(deftest selection-toggles-and-long-press-restarts-selection
  (let [a (key (step context state/empty (state/Long_press_block "a")))
        both (key (step context a (state/Tap_block "b")))
        b (key (step context both (state/Tap_block "a")))
        restarted (key (step context b (state/Long_press_block "a")))]
    (is (= ["a"] (selected a))) (is (= ["a" "b"] (selected both)))
    (is (= ["b"] (selected b))) (is (= ["a"] (selected restarted)))))

(deftest task-toolbar-preserves-the-editor
  (let [editing (key (step context state/empty (state/Tap_block "a")))
        [same commands] (step context editing (state/Toolbar state/Task))]
    (is (= editing same))
    (is (= [(state/Cycle_task_status "a") (state/Haptic state/Impact)] commands))))

(deftest return-splits-the-current-or-atomic-native-text
  (run! (fn [[title caret message before after]]
          (let [[next commands] (step context (start context "a" title caret) message)]
            (is (nil? (state/editing-uuid next)))
            (is (= [(split "a" "Alpha" before after)] commands))))
        [(tuple "Alpha Beta" 5 state/Return_pressed "Alpha" " Beta")
         (tuple "Alpha" 5 (state/Return_pressed_with_text (text "Changed text" 7)) "Changed" " text")]))

(deftest backspace-merges-current-or-atomic-text
  (let [editing (advance context state/empty [(state/Tap_block "b") (state/Caret_moved 0)])]
    (is (= [(merge-command "Beta")] (val (step context editing (backspace 0))))))
  (let [editing (key (step context state/empty (state/Tap_block "b")))]
    (is (= [(merge-command "Changed")] (val (step context editing (atomic-backspace "Changed" 0)))))))

(deftest first-block-backspace-deletes-and-focuses-the-next-block
  (let [ctx (context-for [(block "journal-one" "First journal block")
                          (assoc (row "journal-two-block" "journal-two" "a1") :page-id "journal-two" :title "Second journal block")
                          (assoc (row "journal-two-next" "journal-two" "a2") :page-id "journal-two" :title "Next journal block")])
        editing (key (step ctx state/empty (state/Tap_block "journal-two-block")))
        [next commands] (step ctx editing (atomic-backspace "Second journal block" 0))]
    (is (= (Some "journal-two-next") (state/editing-uuid next)))
    (is (= [(state/Remove_blocks (list "journal-two-block"))] commands)))
  (let [editing (advance context state/empty [(state/Tap_block "a") (state/Caret_moved 0)])
        [next commands] (step context editing (backspace 0))]
    (is (= (Some "b") (state/editing-uuid next))) (is (= [(state/Remove_blocks (list "a"))] commands))))

(deftest return-only-outdents-the-final-empty-child
  (let [ctx (context-for [(block "parent" "Parent") (row "child" "parent" "a0")
                          (assoc (row "empty" "parent" "a1") :title "")])
        editing (key (step ctx state/empty (state/Tap_block "empty")))
        [next commands] (step ctx editing (state/Return_pressed_with_text (text "" 0)))]
    (is (= (Some "empty") (state/editing-uuid next)))
    (is (match commands [(state/Reparent_blocks [move])]
               (and (= "empty" (:uuid move)) (= "page" (:parent-uuid move))) _ false)))
  (let [ctx (context-for [(block "parent" "Parent") (assoc (row "empty" "parent" "a0") :title "")
                          (row "following" "parent" "a1")])
        editing (key (step ctx state/empty (state/Tap_block "empty")))
        [next commands] (step ctx editing state/Return_pressed)]
    (is (nil? (state/editing-uuid next))) (is (match commands [(state/Split_at _)] true _ false))))

(defn moves [commands]
  (match (vec commands) [(state/Reparent_blocks values) (state/Haptic state/Impact)] (vec values)
         _ (stdlib/failwith "expected one move batch and impact haptic")))
(deftest selected-indent-and-outdent-stay-atomic-and-preserve-selection
  (let [ctx (context-for [(row "first" "page" "a0") (row "second" "page" "a1") (row "third" "page" "a2")])
        current (advance ctx state/empty [(state/Long_press_block "second") (state/Tap_block "third")])
        [next commands] (step ctx current (state/Toolbar state/Indent))
        batch (moves commands)]
    (is (= ["second" "third"] (selected next)))
    (is (= ["second" "third"] (mapv :uuid batch)))
    (is (every? #(= "first" (:parent-uuid %)) batch)))
  (let [ctx (context-for [(row "parent" "page" "a0") (row "child-a" "parent" "a0")
                          (row "child-b" "parent" "a1") (row "next" "page" "a1")])
        current (advance ctx state/empty [(state/Long_press_block "child-a") (state/Tap_block "child-b")])
        [next commands] (step ctx current (state/Toolbar state/Outdent))
        batch (moves commands) a (nth batch 0) b (nth batch 1)]
    (is (= ["child-a" "child-b"] (selected next))) (is (= 2 (count batch)))
    (is (= "page" (:parent-uuid a))) (is (= "page" (:parent-uuid b)))
    (is (neg? (compare "a0" (:order a)))) (is (neg? (compare (:order a) (:order b))))
    (is (neg? (compare (:order b) "a1")))))

(deftest delete-confirmation-is-consumed-once
  (let [current (key (step context state/empty (state/Long_press_block "a")))
        [asked commands] (step context current (state/Toolbar state/Delete))
        [deleted confirmed] (step context asked state/Confirm_delete)]
    (is (= [(state/Request_delete_confirmation (list "a")) (state/Haptic state/Impact)] commands))
    (is (empty? (selected asked)))
    (is (= [(state/Remove_blocks (list "a"))] confirmed))
    (is (empty? (val (step context deleted state/Confirm_delete))))))

(defn drop-message [uuid placement]
  (state/Drop_blocks (record state/outliner-drop (target-uuid uuid) (placement placement))))
(deftest drop-rejects-descendants-and-valid-drop-clears-selection
  (let [ctx (context-for [(row "parent" "page" "a0") (row "child" "parent" "a0") (row "target" "page" "a1")])
        current (key (step ctx state/empty (state/Long_press_block "parent")))
        [same ignored] (step ctx current (drop-message "child" state/After))
        [next commands] (step ctx current (drop-message "target" state/Inside))
        batch (moves commands)]
    (is (= current same)) (is (empty? ignored)) (is (empty? (selected next)))
    (is (= 1 (count batch))) (is (= "parent" (:uuid (nth batch 0))))
    (is (= "target" (:parent-uuid (nth batch 0))))))

(deftest structural-toolbar-keeps-the-editing-block-focused
  (run! (fn [[ctx uuid action parent]]
          (let [current (key (step ctx state/empty (state/Tap_block uuid)))
                [next commands] (step ctx current (state/Toolbar action)) batch (moves commands)]
            (is (= (Some uuid) (state/editing-uuid next))) (is (= 1 (count batch)))
            (is (= uuid (:uuid (nth batch 0)))) (is (= parent (:parent-uuid (nth batch 0))))))
        [(tuple context "b" state/Indent "a")
         (tuple (context-for [(row "parent" "page" "a0") (row "child" "parent" "a0") (row "next" "page" "a1")])
                "child" state/Outdent "page")]))

(deftest toolbar-inserts-at-caret-and-targets-media-without-leaving-editor
  (run! (fn [[action title caret kind]]
          (let [[next commands] (step context (start context "a" "AlphaBeta" 5) (state/Toolbar action))]
            (is (= (Some "a") (state/editing-uuid next))) (is (= (Some title) (state/editing-title next)))
            (is (= (Some caret) (some-> (:editing next) :caret)))
            (is (= (Some kind) (some-> (state/autocomplete next) :kind)))
            (is (= [(state/Haptic state/Impact)] commands))))
        [(tuple state/Tag_action "Alpha #Beta" 7 state/Tag) (tuple state/Page_reference "Alpha [[]]Beta" 8 state/Node)])
  (let [current (key (step context state/empty (state/Tap_block "a")))]
    (run! (fn [[action expected]]
            (let [[same commands] (step context current (state/Toolbar action))]
              (is (= current same)) (is (= [expected (state/Haptic state/Impact)] commands))))
          [(tuple state/Camera (state/Take_photo "a")) (tuple state/Audio (state/Record_audio "a"))
           (tuple state/Attachment (state/Pick_attachment "a"))]))
  (let [[next commands] (step context (start context "a" "Changed" 7) (state/Toolbar state/Hide_keyboard))]
    (is (nil? (state/editing-uuid next)))
    (is (= [(commit "a" "Alpha" "Changed") (state/Haptic state/Impact)] commands))))

(deftest selection-copy-and-unselect-close-selection
  (let [current (key (step context state/empty (state/Long_press_block "a")))]
    (run! (fn [[action expected]]
            (let [[next commands] (step context current (state/Toolbar action))]
              (is (empty? (selected next))) (is (= [expected (state/Haptic state/Impact)] commands))))
          [(tuple state/Copy (state/Copy_text "Alpha")) (tuple state/Copy_reference (state/Copy_references (list "a")))
           (tuple state/Copy_url (state/Copy_urls (list "a")))])
    (let [[next commands] (step context current (state/Toolbar state/Unselect))]
      (is (empty? (selected next))) (is (= [(state/Haptic state/Impact)] commands)))))

(deftest nested-zoom-and-deleted-destinations-maintain-valid-paths
  (let [ctx (context-for [(row "parent" "page" "a0") (row "child" "parent" "a0")
                          (row "grandchild" "child" "a0") (row "sibling" "page" "a1")])
        nested (advance ctx state/empty [(state/Zoom_in "parent") (state/Zoom_in "child")])
        back (key (step ctx nested state/Zoom_out))]
    (is (= ["parent" "child"] (zoom-path nested))) (is (= ["child" "grandchild"] (visible-ids ctx nested)))
    (is (= ["parent"] (zoom-path back))) (is (empty? (zoom-path (key (step ctx back state/Zoom_out)))))
    (let [deleted (key (step (context-for []) nested
                             (state/Operation_staged (ops/Delete-blocks (record ops/pending-delete (uuids ["parent"]))))))]
      (is (empty? (zoom-path deleted))))))

(deftest large-outlines-retain-the-existing-latency-bound
  (let [blocks (mapv (fn [index] (row (str "performance-" index)
                                      (if (zero? index) "page" (str "performance-" (dec index))) "a0")) (range 5000))
        ctx (context-for blocks) started (unix/gettimeofday)
        rows (state/visible-rows ctx state/empty) elapsed (- (unix/gettimeofday) started)]
    (is (= 5000 (count rows))) (is (< elapsed 0.1))))

(deftest unicode-carets-and-token-search-handle-boundaries
  (run! (fn [[byte length]] (is (= length (state/utf8-sequence-length byte))))
        [(tuple 65 1) (tuple 195 2) (tuple 228 3) (tuple 240 4) (tuple 128 1)])
  (is (= 5 (state/utf16-length "Aé中😀")))
  (run! (fn [[offset index]] (is (= index (state/byte-index-of-utf16 "Aé中😀" offset))))
        [(tuple 0 0) (tuple 2 3) (tuple 5 10) (tuple 99 10)])
  (is (nil? (state/last-substring "value" ""))) (is (= (Some 2) (state/last-substring "aba" "a")))
  (is (state/includes-case-insensitive "Value" "  ")))

(deftest autocomplete-candidates-combine-deduplicate-and-bound-results
  (let [ctx (assoc (context-for [(block "alpha" "Alpha block") (assoc (block "beta" "Beta") :order (Some "a1"))])
                   :pages (list (candidate "Project Alpha" "Project Alpha")))]
    (is (= [(candidate "Project Alpha" "Project Alpha") (candidate "Alpha block" "alpha")]
           (vec (state/autocomplete-candidates ctx (request state/Node "alpha"))))))
  (let [candidates (list (candidate "Project" "project") (candidate "Project duplicate" "project"))
        ctx (assoc (context-for [(block "alpha" "Alpha")]) :pages candidates :tags candidates)]
    (is (= [(candidate "Project" "project")] (vec (state/autocomplete-candidates ctx (request state/Node "project")))))
    (is (every? #(not= "" (:label %))
                (state/autocomplete-candidates (assoc ctx :blocks (list (block "blank" "") (block "alpha" "Alpha")))
                                               (request state/Node ""))))
    (is (= 1 (count (state/autocomplete-candidates ctx (request state/Tag "project")))))
    (is (= [(candidate "Project" "project")] (vec (state/autocomplete-candidates ctx (request state/Tag "Project")))))
    (is (= [(candidate "New tag: foobar" "foobar")] (vec (state/autocomplete-candidates ctx (request state/Tag "foobar")))))
    (is (= [(candidate "priority" "priority")] (vec (state/autocomplete-candidates ctx (request state/Property "prio"))))))
  (is (empty? (state/autocomplete-candidates (context-for []) (request state/Tag ""))))
  (let [pages (mapv #(candidate (str %) (str %)) (range 20))]
    (is (= 12 (count (state/autocomplete-candidates (assoc (context-for []) :pages (apply list pages)) (request state/Node ""))))))
  (let [ctx (assoc (context-for []) :tags (list (candidate "Project" "project") (candidate "Personal" "personal")))]
    (is (some #(contains? #{"project"} (:value %))
              (state/autocomplete-candidates ctx (request state/Tag "prj"))))))

(deftest autocomplete-token-parsing-preserves-current-line-rules
  (run! (fn [[title expected]] (is (= expected (state/autocomplete-for title (state/utf16-length title)))))
        [(tuple "[[Al" (Some (request state/Node "Al"))) (tuple "property::" (Some (request state/Property "property")))
         (tuple "#tag" (Some (request state/Tag "tag"))) (tuple "text #tag" (Some (request state/Tag "tag")))
         (tuple "text\n#tag" (Some (request state/Tag "tag"))) (tuple "text#tag" (Some (request state/Tag "tag")))
         (tuple "#two words" (Some (request state/Tag "two words")))
         (tuple "before\nstatus::" (Some (request state/Property "status")))
         (tuple "[[Page]]" None) (tuple "((Block" None) (tuple "/query" None) (tuple "text\n/query" None) (tuple "plain text" None)])
  (is (= (Some (request state/Tag "two words")) (state/token-request state/Tag \# "#two words")))
  (is (nil? (state/token-request state/Tag \# "#two\nwords"))))

(defn editing [title]
  (record state/editor-draft (uuid "a") (expected-title title) (title title) (caret (state/utf16-length title))))
(deftest completion-and-caret-insertion-preserve-literal-text
  (run! (fn [[kind title value expected]]
          (is (= (Some expected) (some-> (state/complete context (editing title) kind value) :title))))
        [(tuple state/Node "[[Pr" "Project" "[[Project]]") (tuple state/Tag "#ta" "tag" "#tag")
         (tuple state/Tag "#ta" "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" "#[[018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8]]")
         (tuple state/Tag "#ta" "two words" "#[[two words]]") (tuple state/Property "before\nsta::" "status" "before\nstatus:: ")])
  (is (nil? (state/complete context (editing "plain") state/Node "Project")))
  (is (empty? (state/commit-effect context (Some (editing "Alpha"))))) (is (empty? (state/commit-effect context None)))
  (is (= "#" (:title (state/insert-at-caret (editing "") "#" 0))))
  (is (= "A #" (:title (state/insert-at-caret (editing "A ") "#" 0)))))

(deftest block-ordering-and-contiguity-handle-missing-values
  (let [ordered (block "ordered" "Ordered") unordered (assoc (block "unordered" "Unordered") :order None)
        earlier (assoc (block "earlier" "Earlier") :order None :created-at -1)
        later (assoc (block "later" "Later") :order None)]
    (is (= ["ordered" "earlier" "later"] (mapv :uuid (sort state/compare-blocks [later earlier ordered]))))
    (is (neg? (state/compare-blocks ordered unordered))) (is (pos? (state/compare-blocks unordered ordered)))
    (is (not (state/selection-is-contiguous (seq []) (seq [ordered]))))
    (is (state/selection-is-contiguous (seq [ordered]) (seq [unordered ordered]))))
  (is (= ["a" "b"] (mapv :uuid (sort state/compare-blocks [(assoc (block "b" "B") :order None)
                                                           (assoc (block "a" "A") :order None)]))))
  (is (nil? (state/index-of-uuid "missing" (list)))))

(deftest structural-helpers-reject-invalid-selections-and-order-bounds
  (is (nil? (state/moves-with-orders (list (block "root" "Root")) "page" (Some "a1") (Some "a0"))))
  (is (nil? (state/indent context #{}))) (is (nil? (state/outdent context #{})))
  (is (nil? (state/drop context #{} "a" state/After)))
  (is (nil? (state/drop context #{"a"} "missing" state/After)))
  (let [ctx (context-for [(row "first" "page" "a0") (row "second" "page" "a1")
                          (row "third" "page" "a2") (row "fourth" "page" "a3") (row "other-child" "other" "a0")])]
    (is (nil? (state/indent ctx #{"first"})))
    (is (nil? (state/indent ctx #{"second" "fourth"})))
    (is (nil? (state/indent ctx #{"second" "other-child"}))))
  (let [ctx (context-for [(row "first" "page" "a0") (row "existing" "first" "a0") (row "second" "page" "a1")])]
    (is (if-some [batch (state/indent ctx #{"second"})]
          (and (= 1 (count batch)) (pos? (compare (:order (nth batch 0)) "a0"))) false)))
  (is (nil? (state/outdent context #{"a"})))
  (let [ctx (context-for [(row "parent" "page" "a0") (row "first" "parent" "a0")
                          (row "second" "parent" "a1") (row "third" "parent" "a2") (row "other-child" "other" "a0")])]
    (is (nil? (state/outdent ctx #{"first" "third"}))) (is (nil? (state/outdent ctx #{"first" "other-child"}))))
  (is (nil? (state/outdent (context-for [(assoc (block "parent" "Parent") :parent-id None) (row "child" "parent" "a0")]) #{"child"})))
  (is (if-some [batch (state/outdent (context-for [(row "parent" "page" "a0") (row "child" "parent" "a0")]) #{"child"})]
        (and (= 1 (count batch)) (pos? (compare (:order (nth batch 0)) "a0"))) false)))

(deftest drop-allocates-before-after-and-inside-orders
  (let [ctx (context-for [(row "first" "page" "a0") (row "middle" "page" "a1") (row "last" "page" "a2")
                          (row "last-child" "last" "a0") (assoc (block "detached" "Detached") :parent-id None)])]
    (is (match (state/drop ctx #{"middle"} "first" state/Before) (Some [move]) (neg? (compare (:order move) "a0")) _ false))
    (is (match (state/drop ctx #{"middle"} "last" state/After) (Some [move]) (pos? (compare (:order move) "a2")) _ false))
    (is (nil? (state/drop ctx #{"middle"} "middle" state/Inside)))
    (is (match (state/drop ctx #{"middle"} "last" state/Inside) (Some [move]) (pos? (compare (:order move) "a0")) _ false))
    (run! (fn [[target placement]]
            (is (match (state/drop ctx #{"middle"} target placement) (Some [move])
                       (and (pos? (compare (:order move) "a0")) (neg? (compare (:order move) "a2"))) _ false)))
          [(tuple "last" state/Before) (tuple "first" state/After)])
    (is (nil? (state/drop ctx #{"middle"} "detached" state/Before)))))

(deftest ancestor-and-selected-root-traversal-terminate-on-cycles
  (let [a (row "cyclic-a" "cyclic-b" "a0") b (row "cyclic-b" "cyclic-a" "a0") ctx (context-for [a b])]
    (is (= 2 (count (state/ancestor-uuids ctx a))))
    (is (empty? (state/selected-roots ctx #{"cyclic-a" "cyclic-b"}))))
  (let [selected (row "selected" "cycle-a" "a0")
        ctx (context-for [selected (row "cycle-a" "cycle-b" "a0") (row "cycle-b" "cycle-a" "a0")])]
    (is (= [selected] (vec (state/selected-roots ctx #{"selected"}))))))

(deftest idle-and-stale-editor-messages-are-no-ops
  (run! (fn [message] (is (= (tuple state/empty []) (step context state/empty message))))
        [(state/Tap_block "missing") (state/Text_changed (text "x" 1)) (state/Caret_moved 1)
         state/Return_pressed (backspace 0) (backspace 1) (state/Choose_autocomplete "value") state/Confirm_delete
         (state/Return_pressed_with_text (text "Draft" 5)) (atomic-backspace "Draft" 0) state/Cancel_editing
         (state/Toolbar state/Task) (state/Toolbar state/Tag_action) (state/Toolbar state/Page_reference)
         (state/Toolbar state/Camera) (state/Toolbar state/Attachment) (state/Zoom_in "missing")])
  (run! (fn [action]
          (is (= (tuple state/empty [(state/Haptic state/Impact)]) (step context state/empty (state/Toolbar action)))))
        [state/Indent state/Outdent])
  (let [current (key (step context state/empty (state/Tap_block "a")))]
    (is (= (tuple current []) (step context current (atomic-backspace "Draft" 1))))
    (is (= (tuple current []) (step (context-for [(block "other" "Other")]) current (backspace 0)))))
  (let [stale (assoc state/empty :editing (Some (assoc (editing "") :uuid "missing")))]
    (is (= (tuple stale []) (step context stale (backspace 0)))))
  (let [stale (assoc state/empty :editing (Some (editing "plain")) :autocomplete (Some (request state/Node "")))]
    (is (= (tuple stale []) (step context stale (state/Choose_autocomplete "Project"))))))

(deftest staged-operations-and-repeated-navigation-maintain-editor-state
  (let [zoomed (key (step context state/empty (state/Zoom_in "a")))
        [same commands] (step context zoomed (state/Zoom_in "a"))
        [root root-commands] (step context state/empty state/Zoom_out)]
    (is (= ["a"] (zoom-path same))) (is (= [(state/Haptic state/Selection)] commands))
    (is (empty? (zoom-path root))) (is (= [(state/Haptic state/Selection)] root-commands)))
  (let [missing (ops/Merge-backward (record ops/pending-merge (uuid "a") (expected-title "Alpha") (title "Alpha")
                                            (previous-uuid "missing") (expected-previous-title "Missing") (merged-title None)))]
    (is (= (tuple state/empty []) (step context state/empty (state/Operation_staged missing)))))
  (let [intent (ops/Split-block (record ops/pending-split (uuid "a") (expected-title "Alpha") (before "A") (after "lpha")
                                        (new-uuid "new") (new-order "a1") (created-at 1)))
        [next commands] (step context state/empty (state/Operation_staged intent))]
    (is (= (Some "new") (state/editing-uuid next))) (is (= (Some "lpha") (state/editing-title next))) (is (empty? commands)))
  (is (= (tuple state/empty [(state/Insert_root_block (record state/outliner-root (page-uuid "page-1"))) (state/Haptic state/Impact)])
         (step context state/empty (state/Add_root_block "page-1"))))
  (let [intent (ops/Insert-block (record ops/pending-insert (uuid "new-root") (title "") (page-uuid "page-1")
                                         (parent-uuid "page-1") (order "a0") (created-at 1)))
        [next commands] (step context state/empty (state/Operation_staged intent))]
    (is (= (Some "new-root") (state/editing-uuid next))) (is (= (Some "") (state/editing-title next))) (is (empty? commands)))
  (let [collapsed (key (step context state/empty (state/Toggle_collapsed "a")))
        [expanded commands] (step context collapsed (state/Toggle_collapsed "a"))]
    (is (empty? (:collapsed expanded))) (is (= [(state/Haptic state/Impact)] commands))))

(deftest balanced-completion-and-collapse-preserve-unsaved-text
  (let [ctx (assoc context :pages (list (candidate "Project" "page-id")))]
    (run! (fn [[title caret value expected]]
            (let [[next commands] (step ctx (start ctx "a" title caret) (state/Choose_autocomplete value))]
              (is (= (Some expected) (state/editing-title next)))
              (is (= (if (= value "Novel") [(state/Create_linked_page "Novel") (state/Haptic state/Selection)]
                         [(state/Haptic state/Selection)]) commands))))
          [(tuple "[[Pro]]" 5 "page-id" "[[Project]]") (tuple "[[]]" 2 "Novel" "[[Novel]]")
           (tuple "Before [[Pro]] after" 12 "page-id" "Before [[Project]] after")
           (tuple "😀 [[Pro]] tail" 8 "page-id" "😀 [[Project]] tail")
           (tuple "[[Pro]" 5 "page-id" "[[Project]]") (tuple "[[Pro" 5 "page-id" "[[Project]]")
           (tuple "[[Pro]] [[Next]]" 5 "page-id" "[[Project]] [[Next]]") (tuple "[[Project]]" 5 "page-id" "[[Project]]")])
    (is (= [(candidate "New page: Novel" "Novel")] (vec (state/autocomplete-candidates ctx (request state/Node "Novel")))))
    (is (empty? (state/autocomplete-candidates (context-for []) (request state/Node ""))))
    (run! (fn [collapsed?]
            (let [current (start ctx "a" "Edited [[Pro" 12)
                  current (if collapsed? (assoc current :collapsed #{"b"}) current)
                  [next commands] (step ctx current (state/Toggle_collapsed "b"))]
              (is (nil? (state/editing-uuid next))) (is (nil? (state/autocomplete next)))
              (is (some #(match % (state/Commit_title _) true _ false) commands)))) [false true])))
