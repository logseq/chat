(ns logseq-chat.snapshot
  (:require [clojure.string :as string]
            [logseq-chat.model :as model]
            [ocaml.Yojson :as yojson]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.String :as bytes]
            [ocaml.Buffer :as buffer]))

(defn fields-from-entries [entries]
  (reduce (fn [fields entry]
            (match entry (tuple name value)
              (if (contains? fields name) fields (assoc fields name value)))) {} entries))
(defn object-fields [input]
  (match input (tag Assoc _) (fields-from-entries (json-util/to-assoc input)) _ {}))
(defn object-member [name fields]
  (if-some [value (get fields name)] (object-fields value) {}))
(defn string-member [name fields]
  (when-some [value (get fields name)]
    (match value (tag String _) (Some (json-util/to-string value)) _ nil)))
(defn bool-member [name fields]
  (if-some [value (get fields name)]
    (match value (tag Bool _) (json-util/to-bool value) _ false) false))
(defn int-member [name fields]
  (when-some [value (get fields name)]
    (match value (tag Int _) (Some (json-util/to-int value)) _ nil)))
(defn list-member [name fields]
  (if-some [value (get fields name)]
    (match value (tag List _) (vec (json-util/to-list value)) _ []) []))
(defn string-list-member [name fields]
  (vec (keep (fn [value] (match value (tag String text) (Some text) _ nil))
             (list-member name fields))))

(defn sidebar-page [input]
  (let [fields (object-fields input)]
    (when-some [uuid (string-member "uuid" fields)]
      (when-some [title (string-member "title" fields)]
        (record model/sidebar-page (uuid uuid) (title title))))))
(defn sidebar-pages-member [name fields]
  (vec (keep sidebar-page (list-member name fields))))
(defn breadcrumbs [fields] (sidebar-pages-member "breadcrumbs" fields))
(defn breadcrumb [fields]
  (let [titles (mapv :title (breadcrumbs fields))]
    (if (empty? titles) (or (string-member "title" (object-member "page" fields)) "")
        (string/join " › " titles))))
(defn search-hit [input]
  (let [fields (object-fields input)]
    (when-some [uuid (string-member "uuid" fields)]
      (when-some [title (string-member "title" fields)]
        (record model/search-hit (uuid uuid) (title title) (breadcrumb (breadcrumb fields))
                (breadcrumbs (breadcrumbs fields)) (is-page (bool-member "isPage" fields)))))))
(defn graph [input]
  (let [fields (object-fields input)]
    (when-some [id (string-member "id" fields)]
      (when-some [name (string-member "name" fields)]
        (record model/graph (id id) (name name) (is-encrypted (bool-member "isEncrypted" fields))
                (is-ready (bool-member "isReady" fields)))))))
(defn task-status [input]
  (let [fields (object-fields input) icon (object-member "icon" fields)]
    (when-some [uuid (string-member "uuid" fields)]
      (when-some [title (string-member "title" fields)]
        (record model/task-status (uuid uuid) (title title) (ident (string-member "ident" fields))
                (icon-type (string-member "type" icon)) (icon-id (string-member "id" icon))
                (icon-color (string-member "color" icon)))))))

(defn markup-text [reveal-cloze input]
  (let [fields (object-fields input)
        children (string/join "" (map (fn [child] (markup-text reveal-cloze child))
                                     (list-member "children" fields)))]
    (case (or (string-member "type" fields) "")
      "cloze" (if reveal-cloze (or (string-member "text" fields) "") "[…]")
      "nodeReference" (or (string-member "title" fields) "")
      "tagReference" (str "#" (or (string-member "title" fields) ""))
      "link" (if (empty? children) (or (string-member "url" fields) "") children)
      "video" (or (string-member "url" fields) "")
      "iframe" (or (string-member "url" fields) "")
      "emphasis" children
      "quote" children
      (or (string-member "text" fields) children))))
(defn markup-has-cloze [input]
  (let [fields (object-fields input)]
    (or (= (string-member "type" fields) (Some "cloze"))
        (boolean (some markup-has-cloze (list-member "children" fields))))))
(defn inline-tag-ids [input]
  (let [fields (object-fields input)
        ids (if (= (string-member "type" fields) (Some "tagReference"))
              (if-some [uuid (string-member "uuid" fields)] [uuid] []) [])]
    (into ids (mapcat inline-tag-ids (list-member "children" fields)))))
(defn trailing-tags [fields]
  (let [inline-ids (set (mapcat inline-tag-ids (list-member "markup" fields)))
        [_ tags] (reduce (fn [[seen result] tag]
                           (if (or (contains? inline-ids (:uuid tag)) (contains? seen (:uuid tag)))
                             (tuple seen result)
                             (tuple (conj seen (:uuid tag)) (conj result tag))))
                         (tuple #{} []) (sidebar-pages-member "tags" fields))]
    tags))

(defn find-substring [value pattern start]
  (loop [index start]
    (cond (> (+ index (count pattern)) (count value)) nil
          (= (subs value index (+ index (count pattern))) pattern) (Some index)
          :else (recur (inc index)))))
(defn legacy-cloze-text [reveal value]
  (let [result (buffer/create (count value))]
    (loop [offset 0 has-cloze false]
      (if-some [opening (find-substring value "{{" offset)]
        (do (buffer/add-substring result value offset (- opening offset))
            (if-some [closing (find-substring value "}}" (+ opening 2))]
              (let [body (subs value (+ opening 2) closing)
                    cloze (string/starts-with? (bytes/lowercase-ascii body) "cloze ")]
                (buffer/add-string result
                  (if cloze (if reveal (string/trim (subs body 6)) "[…]")
                      (subs value opening (+ closing 2))))
                (recur (+ closing 2) (or has-cloze cloze)))
              (do (buffer/add-substring result value opening (- (count value) opening))
                  (tuple (buffer/contents result) has-cloze))))
        (do (buffer/add-substring result value offset (- (count value) offset))
            (tuple (buffer/contents result) has-cloze))))))
(defn block-markup-text [reveal fields]
  (let [markup (list-member "markup" fields)]
    (if (empty? markup) (first (legacy-cloze-text reveal (or (string-member "title" fields) "")))
        (string/join "" (map (fn [node] (markup-text reveal node)) markup)))))
(defn flashcard-answer [input]
  (let [fields (object-fields input)]
    (when-some [uuid (string-member "uuid" fields)]
      (record model/flashcard-answer-row (uuid uuid) (index 0) (text (block-markup-text true fields))))))
(defn flashcard [input]
  (let [fields (object-fields input) block (object-member "block" fields)]
    (when-some [uuid (string-member "uuid" block)]
      (record model/flashcard (uuid uuid)
        (question-hidden (block-markup-text false block)) (question-revealed (block-markup-text true block))
        (answer-rows (vec (map-indexed (fn [index row] (assoc row :index index))
                                      (keep flashcard-answer (list-member "children" fields)))))
        (has-cloze (or (boolean (some markup-has-cloze (list-member "markup" block)))
                       (second (legacy-cloze-text false (or (string-member "title" block) "")))))))))

(defn outline-row-from-block [youtube-target-url opens-as-page depth has-children is-collapsed fields]
  (when-some [uuid (string-member "uuid" fields)]
    (when-some [title (string-member "title" fields)]
      (record model/outline-row (uuid uuid) (title title)
        (markup-json (if-some [markup (get fields "markup")] (json/to-string markup) "[]"))
        (youtube-target-url youtube-target-url) (breadcrumb (breadcrumb fields)) (breadcrumbs (breadcrumbs fields))
        (opens-as-page opens-as-page) (depth depth) (has-children has-children) (is-collapsed is-collapsed)
        (is-asset (bool-member "isAsset" fields)) (asset-type (string-member "assetType" fields))
        (local-path (string-member "localPath" fields))
        (status (when-some [status (get fields "status")] (task-status status)))
        (tags (trailing-tags fields)) (sync-status (string-member "syncStatus" fields))
        (page-id (or (string-member "pageId" fields) "")) (journal-title (string-member "journalTitle" fields))
        (journal-day (int-member "journalDay" fields))))))
(defn outline-row [input]
  (let [fields (object-fields input)]
    (when-some [depth (int-member "depth" fields)]
      (outline-row-from-block (string-member "youtubeTargetURL" fields) false depth
        (bool-member "hasChildren" fields) (bool-member "isCollapsed" fields) (object-member "block" fields)))))
(defn related-row [input]
  (let [fields (object-fields input)
        opens-as-page (if-some [uuid (string-member "uuid" fields)]
                        (= (string-member "pageId" fields) (Some uuid)) false)]
    (outline-row-from-block (string-member "youtubeTargetURL" fields) opens-as-page 0 false false fields)))
(defn outliner-rows-member [name fields] (vec (keep outline-row (list-member name fields))))
(defn related-rows-member [name fields] (vec (keep related-row (list-member name fields))))

(defn outliner-editing [input]
  (let [fields (object-fields input)]
    (when-some [uuid (string-member "uuid" fields)]
      (when-some [title (string-member "title" fields)]
        (when-some [caret (int-member "caretUTF16Offset" fields)]
          (record model/outliner-editing (uuid uuid) (title title) (caret-utf16-offset caret)))))))
(defn outliner-autocomplete [input]
  (let [fields (object-fields input)
        kind (case (or (string-member "kind" fields) "")
               "node" (Some model/NodeAutocomplete) "tag" (Some model/TagAutocomplete)
               "property" (Some model/PropertyAutocomplete) nil)]
    (when-some [kind kind]
      (when-some [query (string-member "query" fields)]
        (record model/outliner-autocomplete (kind kind) (query query))))))
(defn autocomplete-candidate [input]
  (let [fields (object-fields input)]
    (when-some [label (string-member "label" fields)]
      (when-some [value (string-member "value" fields)]
        (record model/outliner-autocomplete-candidate (index 0) (label label) (value value))))))
(defn autocomplete-candidates-member [fields]
  (vec (map-indexed (fn [index candidate] (assoc candidate :index index))
                   (keep autocomplete-candidate (list-member "outlinerAutocompleteCandidates" fields)))))
(defn editing-member [fields]
  (when-some [value (get (object-member "outlinerState" fields) "editing")] (outliner-editing value)))
(defn autocomplete-member [fields]
  (when-some [value (get (object-member "outlinerState" fields) "autocomplete")] (outliner-autocomplete value)))
(defn selection-member [fields]
  (string-list-member "selectedBlockIds" (object-member "outlinerState" fields)))
(defn outliner-row-splice [input]
  (let [fields (object-fields input)]
    (when-some [delete-count (int-member "deleteCount" fields)]
      (record model/outline-row-splice (start (int-member "start" fields))
        (after-block-id (string-member "afterBlockId" fields)) (before-block-id (string-member "beforeBlockId" fields))
        (delete-count delete-count) (rows (outliner-rows-member "rows" fields))))))

(defn node-title [uuid is-tag fields]
  (let [title (or (string-member "title" (object-member "page" fields)) "Untitled")]
    (if is-tag (str "#" title)
        (or (some (fn [block]
                    (let [block (object-fields block)]
                      (when (= (string-member "uuid" block) (Some uuid)) (string-member "title" block))))
                  (list-member "blocks" fields)) title))))
(defn node-route [input]
  (let [fields (object-fields input)]
    (when-some [uuid (string-member "uuid" fields)]
      (let [is-tag (bool-member "isTag" fields)]
        (record model/node-projection (uuid uuid)
          (page-uuid (or (string-member "uuid" (object-member "page" fields)) uuid))
          (title (node-title uuid is-tag fields)) (is-tag is-tag) (is-property (bool-member "isProperty" fields))
          (outliner-rows (outliner-rows-member "outlinerRows" fields))
          (related-rows (related-rows-member "relatedBlocks" fields))
          (linked-reference-rows (related-rows-member "linkedReferenceBlocks" fields))
          (outliner-editing (editing-member fields)) (outliner-autocomplete (autocomplete-member fields))
          (outliner-autocomplete-candidates (autocomplete-candidates-member fields))
          (outliner-selected-block-ids (selection-member fields)))))))
(defn sidebar-projection [fields]
  (record model/sidebar-projection
    (favorites (sidebar-pages-member "favorites" fields)) (recent-pages (sidebar-pages-member "recentPages" fields))
    (selected-page (when-some [page (get fields "selectedPage")] (sidebar-page page)))
    (selected-page-is-tag (bool-member "selectedPageIsTag" fields))
    (selected-page-is-property (bool-member "selectedPageIsProperty" fields))
    (related-rows (related-rows-member "relatedBlocks" fields))
    (linked-reference-rows (related-rows-member "linkedReferenceBlocks" fields))))
(defn core-projection [fields]
  (let [is-patch (bool-member "isOutlinerPatch" fields)
        rows (outliner-rows-member "outlinerRows" fields)
        base-rows (if (and is-patch (empty? rows)) (related-rows-member "blocks" fields) rows)
        routes (vec (keep node-route (list-member "nodeRoutes" fields)))
        active (last routes)]
    (record model/core-projection
      (graph-name (string-member "graphName" fields)) (selected-graph-id (string-member "selectedGraphId" fields))
      (graphs (vec (keep graph (list-member "graphs" fields))))
      (is-graph-encrypted (bool-member "isGraphEncrypted" fields)) (is-graph-unlocked (bool-member "isGraphUnlocked" fields))
      (sidebar (sidebar-projection fields)) (task-statuses (vec (keep task-status (list-member "taskStatuses" fields))))
      (flashcards (vec (keep flashcard (list-member "flashcards" fields))))
      (search-query (or (string-member "searchQuery" fields) "")) (search-results (vec (keep search-hit (list-member "searchResults" fields))))
      (node-routes routes) (journal-outliner-rows base-rows)
      (outliner-rows (if-some [route active] (:outliner-rows route) base-rows))
      (outliner-row-splices (vec (keep outliner-row-splice (list-member "outlinerRowSplices" fields))))
      (outliner-editing (if-some [route active] (:outliner-editing route) (editing-member fields)))
      (outliner-autocomplete (if-some [route active] (:outliner-autocomplete route) (autocomplete-member fields)))
      (outliner-autocomplete-candidates (if-some [route active] (:outliner-autocomplete-candidates route) (autocomplete-candidates-member fields)))
      (outliner-selected-block-ids (if-some [route active] (:outliner-selected-block-ids route) (selection-member fields)))
      (has-older-journals (bool-member "hasOlderJournals" fields)) (is-outliner-patch is-patch)
      (sync-connected (bool-member "syncConnected" fields)) (applied-server-t (int-member "appliedServerT" fields))
      (has-pending-semantic-operations (bool-member "hasPendingSemanticOperations" fields))
      (has-pending-sync-request (match (get fields "pendingSyncRequest") None false (Some (tag Null)) false _ true))
      (is-pending-sync-patch (bool-member "isPendingSyncPatch" fields)) (is-graph-catalog-patch (bool-member "isGraphCatalogPatch" fields)))))
(defn error-message [fields]
  (let [error (object-member "error" fields)]
    (str (or (string-member "code" error) "core_request_failed") "\n"
         (or (string-member "message" error) "Core request failed"))))
(defn decode-response [encoded]
  (try
    (match (json/from-string encoded)
      (tag Assoc entries)
      (let [fields (fields-from-entries entries)]
        (if (bool-member "ok" fields)
          (match (get fields "result")
            (Some (tag Assoc entries)) (Ok (core-projection (fields-from-entries entries)))
            _ (Error "Core response did not contain a snapshot"))
          (Error (error-message fields))))
      _ (Error "Core response must be a JSON object"))
    (catch (yojson/Json_error message) (Error (str "Invalid core response: " message)))))
