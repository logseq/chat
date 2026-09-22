(ns logseq-chat.rpc-encode
  (:require [clojure.string :as string]
            [logseq-chat.rpc-wire :as wire]
            [logseq-chat.markup :as markup]
            [logseq-chat.outliner-effects :as effects]
            [logseq-chat.outliner-state :as outliner]
            [logseq-chat.cache-model :as model]
            [logseq-chat.flashcards :as flashcards]
            [ocaml.package/yojson]))

(defn youtube-url? [url]
  (let [lower (string/lower-case url)]
    (or (string/includes? lower "youtube.com") (string/includes? lower "youtu.be"))))

(defn youtube-target-urls [blocks]
  (let [[_ targets]
        (reduce
          (fn [[current targets] block]
            (let [[current target]
                  (reduce (fn [[current target] node]
                            (match node
                              (markup/Markup_video url)
                              (tuple (if (youtube-url? url) (Some url) current) target)
                              (markup/Markup_youtube_timestamp _ _)
                              (tuple current (if-some [url current] (Some url) target))
                              _ (tuple current target)))
                          (tuple current nil) (markup/parse (:references block) (:tags block) (:title block)))]
              (tuple current (if-some [url target] (conj targets (tuple (:uuid block) url)) targets))))
          (tuple nil []) blocks)]
    targets))

(defn summary-json [^:model/entity-summary summary]
  (wire/json-object [(tuple "uuid" (tag String (:uuid summary))) (tuple "title" (tag String (:title summary)))]))

(defn status-response-json [^:model/status status]
  (wire/json-object
    (concat [(tuple "uuid" (tag String (:uuid status))) (tuple "title" (tag String (:title status)))]
            (if-some [ident (:ident status)] [(tuple "ident" (tag String ident))] [])
            (match [(:icon-type status) (:icon-id status)]
              [(Some kind) (Some id)]
              [(tuple "icon" (wire/json-object
                (concat [(tuple "type" (tag String kind)) (tuple "id" (tag String id))]
                        (if-some [color (:icon-color status)] [(tuple "color" (tag String color))] []))))]
              _ []))))

;; markup/parse output is pure in (references, tags, title); memoize per uuid so
;; a block's markup is parsed once until its title or summaries change.

(def ^:ref<map<string;tuple<string;list<model/entity-summary>;list<model/entity-summary>;Yojson.Basic.t>>> markup-cache (atom {}))

(defn- markup-json-encode [block]
  (let [encoded (markup/to-yojson (markup/parse (:references block) (:tags block) (:title block)))]
    (when (> (count @markup-cache) 8192) (reset! markup-cache {}))
    (swap! markup-cache assoc (:uuid block) (tuple (:title block) (:references block) (:tags block) encoded))
    encoded))

(defn- markup-json [block]
  (match (get @markup-cache (:uuid block))
    (Some (tuple title references tags encoded))
    (if (and (= title (:title block)) (= references (:references block)) (= tags (:tags block)))
      encoded
      (markup-json-encode block))
    None (markup-json-encode block)))

(defn block-json [block]
  (wire/json-object
    (concat
      [(tuple "uuid" (tag String (:uuid block))) (tuple "title" (tag String (:title block)))
       (tuple "pageId" (tag String (:page-id block))) (tuple "createdAt" (tag Int (:created-at block)))
       (tuple "updatedAt" (tag Int (:updated-at block))) (tuple "syncStatus" (tag String (:sync-status block)))
       (tuple "isAsset" (tag Bool (:is-asset block)))
       (tuple "tags" (tag List (apply list (map summary-json (:tags block)))))
       (tuple "references" (tag List (apply list (map summary-json (:references block)))))
       (tuple "breadcrumbs" (tag List (apply list (map summary-json (:breadcrumbs block)))))
       (tuple "markup" (markup-json block))]
      (if-some [order (:order block)] [(tuple "order" (tag String order))] [])
      (if-some [status (:status block)] [(tuple "status" (status-response-json status))] [])
      (if-some [kind (:asset-type block)] [(tuple "assetType" (tag String kind))] [])
      (if-some [size (:asset-size block)] [(tuple "assetSize" (tag Int size))] [])
      (if-some [checksum (:asset-checksum block)] [(tuple "assetChecksum" (tag String checksum))] [])
      (if-some [path (:local-path block)] [(tuple "localPath" (tag String path))] [])
      (if-some [parent (:parent-id block)] [(tuple "parentId" (tag String parent))] []))))

(defn visible-block-json [block]
  (let [encoded (block-json block)]
    (if-some [[title day] (:journal block)]
      (match encoded
        (tag Assoc fields)
        (wire/json-object (concat [(tuple "journalTitle" (tag String title)) (tuple "journalDay" (tag Int day))] fields))
        _ encoded)
      encoded)))

(defn flashcard-json [due-card]
  (let [card (:card due-card)]
    (wire/json-object [(tuple "block" (block-json (:block due-card)))
                  (tuple "children" (tag List (apply list (map block-json (:children due-card)))))
                  (tuple "due" (tag Int (:due card))) (tuple "repetitions" (tag Int (:reps card)))
                  (tuple "lapses" (tag Int (:lapses card)))
                  (tuple "state" (tag String (flashcards/state-name (:state card))))])))

(defn graph-json [graph]
  (wire/json-object [(tuple "id" (tag String (:id graph))) (tuple "name" (tag String (:name graph)))
                (tuple "schemaVersion" (if-some [version (:schema-version graph)] (tag String version) (tag Null)))
                (tuple "isEncrypted" (tag Bool (:e2ee graph))) (tuple "isReady" (tag Bool (:ready graph)))]))

(defn search-hit-json [hit]
  (wire/json-object [(tuple "uuid" (tag String (:uuid hit))) (tuple "title" (tag String (:title hit)))
                (tuple "isPage" (tag Bool (:is-page hit)))
                (tuple "page" (if-some [page (:page hit)] (summary-json page) (tag Null)))
                (tuple "breadcrumbs" (tag List (apply list (map summary-json (:breadcrumbs hit)))))]))

(defn outliner-row-json [youtube-target-url serialize-block row]
  (wire/json-object
    (concat [(tuple "block" (serialize-block (:block row)))
             (tuple "depth" (tag Int (:depth row)))
             (tuple "hasChildren" (tag Bool (:has-children row)))
             (tuple "isCollapsed" (tag Bool (:is-collapsed row)))]
            (if-some [url youtube-target-url] [(tuple "youtubeTargetURL" (tag String url))] []))))

(defn outliner-rows-json [serialize-block context state]
  (let [rows (outliner/visible-rows context state)
        targets (into {} (reverse (youtube-target-urls (map :block rows))))]
    (wire/json-list (map (fn [row]
                     (outliner-row-json (get targets (:uuid (:block row))) serialize-block row)) rows))))

(defn common-row-prefix [before after]
  (loop [index 0]
    (if (and (< index (count before)) (< index (count after))
             (= (nth before index) (nth after index)))
      (recur (inc index))
      index)))

(defn common-row-suffix [before after start]
  (loop [length 0]
    (let [before-index (- (count before) length 1)
          after-index (- (count after) length 1)]
      (if (and (>= before-index start) (>= after-index start)
               (= (nth before before-index) (nth after after-index)))
        (recur (inc length))
        length))))

(defn row-splice-position [anchored before start]
  (if anchored
    (let [anchors
          (concat
           (if (> start 0)
             [(tuple "afterBlockId" (tag String (:uuid (:block (nth before (dec start))))))] [])
           (if (< start (count before))
             [(tuple "beforeBlockId" (tag String (:uuid (:block (nth before start)))))] []))]
      (if (empty? anchors) [(tuple "start" (tag Int 0))] (vec anchors)))
    [(tuple "start" (tag Int start))]))

(defn structural-outliner-delta [anchored before-context before-state after-context after-state]
  (let [before-rows (vec (outliner/visible-rows before-context before-state))
        after-rows (vec (outliner/visible-rows after-context after-state))
        before-blocks (zipmap (map :uuid (:blocks before-context)) (:blocks before-context))
        after-ids (set (map :uuid (:blocks after-context)))
        blocks (filterv (fn [block] (not= (get before-blocks (:uuid block)) (Some block)))
                        (:blocks after-context))
        deleted (vec (keep (fn [block] (when (not (contains? after-ids (:uuid block))) (:uuid block)))
                           (:blocks before-context)))
        start (common-row-prefix before-rows after-rows)
        suffix (common-row-suffix before-rows after-rows start)
        delete-count (- (count before-rows) start suffix)
        insert-count (- (count after-rows) start suffix)
        targets (into {} (reverse (youtube-target-urls (map :block after-rows))))
        splices
        (if (and (= delete-count 0) (= insert-count 0))
          []
          [(wire/json-object
            (concat
             (row-splice-position anchored before-rows start)
             [(tuple "deleteCount" (tag Int delete-count))
              (tuple "rows"
                     (wire/json-list
                      (map (fn [row]
                             (outliner-row-json (get targets (:uuid (:block row))) visible-block-json row))
                           (subvec after-rows start (+ start insert-count)))))]))])]
    (tuple blocks deleted splices)))

(defn outliner-candidates-json [context state]
  (wire/json-list
      (if-some [request (outliner/autocomplete state)]
        (mapv (fn [candidate]
                (wire/json-object [(tuple "label" (tag String (:label candidate)))
                              (tuple "value" (tag String (:value candidate)))]))
              (outliner/autocomplete-candidates context request))
        [])))

(defn autocomplete-kind-json [kind]
  (match kind outliner/Node "node" outliner/Tag "tag" outliner/Property "property"))

(defn outliner-state-json [state]
  (wire/json-object
    [(tuple "editing"
       (if-some [editing (:editing state)]
         (wire/json-object [(tuple "uuid" (tag String (:uuid editing)))
                       (tuple "title" (tag String (:title editing)))
                       (tuple "caretUTF16Offset" (tag Int (:caret editing)))])
         (tag Null)))
     (tuple "selectedBlockIds" (wire/json-strings (outliner/selected-uuids state)))
     (tuple "collapsedBlockIds" (wire/json-strings (outliner/collapsed-uuids state)))
     (tuple "zoomedBlockIds" (wire/json-strings (:zoomed state)))
     (tuple "autocomplete"
       (if-some [request (:autocomplete state)]
         (wire/json-object [(tuple "kind" (tag String (autocomplete-kind-json (:kind request))))
                       (tuple "query" (tag String (:query request)))])
         (tag Null)))]))

(defn outliner-command-json [command]
  (let [[kind key value]
        (match command
          (effects/Platform_haptic haptic)
          (tuple "haptic" "style" (tag String (match haptic outliner/Selection "selection" outliner/Impact "impact")))
          (effects/Focus_block uuid) (tuple "focusBlock" "uuid" (tag String uuid))
          (effects/Confirm_delete uuids) (tuple "confirmDelete" "uuids" (wire/json-strings uuids))
          (effects/Set_clipboard_text text) (tuple "setClipboardText" "text" (tag String text))
          (effects/Set_clipboard_references uuids) (tuple "setClipboardReferences" "uuids" (wire/json-strings uuids))
          (effects/Set_clipboard_urls uuids) (tuple "setClipboardURLs" "uuids" (wire/json-strings uuids))
          (effects/Platform_pick_attachment uuid) (tuple "pickAttachment" "uuid" (tag String uuid))
          (effects/Platform_take_photo uuid) (tuple "takePhoto" "uuid" (tag String uuid))
          (effects/Platform_record_audio uuid) (tuple "recordAudio" "uuid" (tag String uuid)))]
    (wire/json-object [(tuple "type" (tag String kind)) (tuple key value)])))

(defn outliner-patch-result [revision context state command-revision commands pending blocks deleted splices]
  (wire/success
   (wire/json-object
    [(tuple "revision" (tag Int revision))
     (tuple "blocks" (wire/json-list (map visible-block-json blocks)))
     (tuple "deletedBlockIds" (wire/json-strings deleted))
     (tuple "selectedBlock" (tag Null))
     (tuple "outlinerState" (outliner-state-json state))
     (tuple "outlinerAutocompleteCandidates" (outliner-candidates-json context state))
     (tuple "outlinerRows" (wire/json-list []))
     (tuple "outlinerRowSplices" (wire/json-list splices))
     (tuple "outlinerCommandRevision" (tag Int command-revision))
     (tuple "outlinerCommands" (wire/json-list (map outliner-command-json commands)))
     (tuple "hasPendingSemanticOperations" (tag Bool pending))
     (tuple "isOutlinerPatch" (tag Bool true))])))
