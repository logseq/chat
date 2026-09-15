(ns logseq-chat.lui-snapshot-test
  (:require [clojure.string :as string]
            [clojure.test :refer [deftest is]]
            [logseq-chat.snapshot :as snapshot]
            [logseq-chat.model :as model]))

(defn decoded [input]
  (match (snapshot/decode-response input)
    (Ok projection) projection
    (Error message) (throw (Failure message))))

(deftest invalid-envelopes-preserve-errors
  (run! (fn [[input expected]]
          (match (snapshot/decode-response input)
            (Error message) (is (= expected message))
            (Ok _) (is false "invalid envelope was accepted")))
    [["[]" "Core response must be a JSON object"]
     ["{\"ok\":true}" "Core response did not contain a snapshot"]
     ["{\"ok\":true,\"result\":null}" "Core response did not contain a snapshot"]
     ["{\"ok\":false,\"error\":null}" "core_request_failed\nCore request failed"]
     ["{\"apiVersion\":1,\"ok\":false,\"error\":{\"code\":\"graph_discovery_failed\",\"message\":\"Connection refused\"}}" "graph_discovery_failed\nConnection refused"]])
  (match (snapshot/decode-response "{")
    (Error message) (is (string/starts-with? message "Invalid core response: "))
    (Ok _) (is false "malformed JSON was accepted")))

(deftest empty-route-and-legacy-boundaries
  (let [projection (decoded "{\"ok\":true,\"result\":{\"graphName\":\"first\",\"graphName\":\"second\",\"outlinerState\":{\"editing\":{\"uuid\":\"base\",\"title\":\"Base\",\"caretUTF16Offset\":2},\"selectedBlockIds\":[\"base\"]},\"nodeRoutes\":[{\"uuid\":\"empty\",\"outlinerRows\":[]}],\"outlinerAutocompleteCandidates\":[null,{\"label\":\"Good\",\"value\":\"good\"}],\"outlinerRows\":[{\"depth\":0,\"block\":{\"uuid\":\"base\",\"title\":\"Base\",\"markup\":null}}],\"flashcards\":[{\"block\":{\"uuid\":\"card\",\"title\":\"{{CLOZE answer}} {{unknown x}} {{cloze unfinished\"},\"children\":[null,{\"uuid\":\"answer\",\"title\":\"Answer\"}]}]}}")
        card (nth (:flashcards projection) 0)]
    (is (= (Some "first") (:graph-name projection)))
    (is (empty? (:outliner-rows projection)))
    (is (nil? (:outliner-editing projection)))
    (is (empty? (:outliner-selected-block-ids projection)))
    (is (= "null" (:markup-json (nth (:journal-outliner-rows projection) 0))))
    (is (= "[…] {{unknown x}} {{cloze unfinished" (:question-hidden card)))
    (is (= "answer {{unknown x}} {{cloze unfinished" (:question-revealed card)))
    (is (= 0 (:index (nth (:answer-rows card) 0))))))

(deftest full-snapshot-retains-search-outliner-and-sync
  (let [projection (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"graphName\":\"Work\",\"searchQuery\":\"project\",\"searchResults\":[{\"uuid\":\"page-a\",\"title\":\"Project Alpha\",\"isPage\":true,\"page\":null,\"breadcrumbs\":[]},{\"uuid\":\"block-a\",\"title\":\"Project note\",\"isPage\":false,\"page\":{\"uuid\":\"page-a\",\"title\":\"Project Alpha\"},\"breadcrumbs\":[{\"uuid\":\"parent-a\",\"title\":\"Parent\"}]}],\"outlinerState\":{\"editing\":{\"uuid\":\"outline-a\",\"title\":\"Nested note\",\"caretUTF16Offset\":6},\"selectedBlockIds\":[\"outline-a\"],\"autocomplete\":{\"kind\":\"node\",\"query\":\"Pro\"}},\"outlinerAutocompleteCandidates\":[{\"label\":\"Project Alpha\",\"value\":\"page-a\"}],\"outlinerRows\":[{\"block\":{\"uuid\":\"outline-a\",\"title\":\"Nested note\",\"pageId\":\"journal-a\",\"journalTitle\":\"August 27th, 2026\",\"journalDay\":20260827},\"depth\":2,\"hasChildren\":true,\"isCollapsed\":false}],\"hasOlderJournals\":true,\"appliedServerT\":42,\"hasPendingSemanticOperations\":true,\"pendingSyncRequest\":{\"id\":7},\"syncConnected\":true}}")
        results (:search-results projection)
        page (nth results 0)
        block (nth results 1)
        rows (:outliner-rows projection)
        row (nth rows 0)]
    (is (= (Some "Work") (:graph-name projection)))
    (is (= "project" (:search-query projection)))
    (is (:sync-connected projection))
    (is (= (Some 42) (:applied-server-t projection)))
    (is (:has-pending-semantic-operations projection))
    (is (:has-pending-sync-request projection))
    (is (:has-older-journals projection))
    (is (= 2 (count results)))
    (is (= "page-a" (:uuid page)))
    (is (:is-page page))
    (is (= "Parent" (:breadcrumb block)))
    (is (= [["parent-a" "Parent"]]
           (mapv (fn [entry] [(:uuid entry) (:title entry)]) (:breadcrumbs block))))
    (is (= 1 (count rows)))
    (is (= "outline-a" (:uuid row)))
    (is (= "Nested note" (:title row)))
    (is (= "journal-a" (:page-id row)))
    (is (= (Some "August 27th, 2026") (:journal-title row)))
    (is (= (Some 20260827) (:journal-day row)))
    (is (= 2 (:depth row)))
    (is (:has-children row))
    (is (not (:is-collapsed row)))
    (match (:outliner-editing projection)
      (Some editing)
      (do (is (= "outline-a" (:uuid editing)))
          (is (= "Nested note" (:title editing)))
          (is (= 6 (:caret-utf16-offset editing))))
      None (is false "missing editor"))
    (is (not (:is-outliner-patch projection)))
    (is (= ["outline-a"] (:outliner-selected-block-ids projection)))
    (match (:outliner-autocomplete projection)
      (Some autocomplete)
      (do (is (= model/NodeAutocomplete (:kind autocomplete)))
          (is (= "Pro" (:query autocomplete))))
      None (is false "missing autocomplete"))
    (is (= 1 (count (:outliner-autocomplete-candidates projection))))
    (let [candidate (nth (:outliner-autocomplete-candidates projection) 0)]
      (is (= "Project Alpha" (:label candidate)))
      (is (= "page-a" (:value candidate)))
      (is (= 0 (:index candidate))))))

(deftest patch-identities
  (is (:is-pending-sync-patch (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"revision\":2,\"blocks\":[],\"pendingSyncRequest\":null,\"hasPendingSemanticOperations\":false,\"isPendingSyncPatch\":true}}")))
  (is (:is-graph-catalog-patch (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"graphs\":[],\"isGraphCatalogPatch\":true}}"))))

(deftest active-route-becomes-outliner-surface
  (let [projection (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"graphName\":\"Work\",\"outlinerState\":{\"editing\":null},\"outlinerRows\":[{\"block\":{\"uuid\":\"base\",\"title\":\"Base\"},\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false}],\"nodeRoutes\":[{\"uuid\":\"node-a\",\"isTag\":false,\"isProperty\":false,\"page\":{\"uuid\":\"page-a\",\"title\":\"Project\"},\"outlinerState\":{\"editing\":{\"uuid\":\"child\",\"title\":\"Child\",\"caretUTF16Offset\":5},\"selectedBlockIds\":[],\"autocomplete\":null},\"outlinerAutocompleteCandidates\":[],\"outlinerRows\":[{\"block\":{\"uuid\":\"child\",\"title\":\"Child\"},\"depth\":1,\"hasChildren\":false,\"isCollapsed\":false}]}],\"syncConnected\":true}}")]
    (is (= [["node-a" "Project"]]
           (mapv (fn [route] [(:uuid route) (:title route)]) (:node-routes projection))))
    (is (= ["child"] (mapv :uuid (:outliner-rows projection))))
    (is (= (Some "child") (when-some [editing (:outliner-editing projection)] (:uuid editing))))))

(deftest rich-markup-and-cross-block-youtube-target
  (let [rows (:outliner-rows (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"outlinerState\":{\"editing\":null},\"outlinerRows\":[{\"block\":{\"uuid\":\"video\",\"title\":\"{{youtube dQw4w9WgXcQ}}\",\"markup\":[{\"type\":\"video\",\"url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}]},\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false},{\"block\":{\"uuid\":\"timestamp\",\"title\":\"{{youtube-timestamp 01:23}}\",\"markup\":[{\"type\":\"youtubeTimestamp\",\"text\":\"01:23\",\"style\":\"83\"}]},\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false,\"youtubeTargetURL\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}],\"syncConnected\":true}}"))]
    (is (= 2 (count rows)))
    (is (= "[{\"type\":\"video\",\"url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}]" (:markup-json (nth rows 0))))
    (is (= (Some "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
           (:youtube-target-url (nth rows 1))))))

(deftest asset-status-and-deduplicated-trailing-tags
  (let [rows (:outliner-rows (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"outlinerState\":{\"editing\":null},\"outlinerRows\":[{\"block\":{\"uuid\":\"asset-a\",\"title\":\"Photo.jpg\",\"markup\":[{\"type\":\"emphasis\",\"style\":\"bold\",\"children\":[{\"type\":\"tagReference\",\"uuid\":\"tag-a\",\"title\":\"Project\"}]}],\"isAsset\":true,\"assetType\":\"image/jpeg\",\"localPath\":\"Assets/Photo.jpg\",\"syncStatus\":\"failed\",\"tags\":[{\"uuid\":\"tag-a\",\"title\":\"Project\"},{\"uuid\":\"tag-b\",\"title\":\"Trailing\"},{\"uuid\":\"tag-b\",\"title\":\"Trailing\"}],\"status\":{\"uuid\":\"todo\",\"ident\":\"logseq.property/status.todo\",\"title\":\"Todo\",\"icon\":{\"type\":\"tabler-icon\",\"id\":\"Todo\"}}},\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false}],\"syncConnected\":true}}"))
        row (nth rows 0)]
    (is (= 1 (count rows)))
    (is (:is-asset row))
    (is (= (Some "image/jpeg") (:asset-type row)))
    (is (= (Some "Assets/Photo.jpg") (:local-path row)))
    (is (= (Some "failed") (:sync-status row)))
    (is (= [["tag-b" "Trailing"]]
           (mapv (fn [tag] [(:uuid tag) (:title tag)]) (:tags row))))
    (is (= (Some "todo") (when-some [status (:status row)] (:uuid status))))))

(deftest related-page-navigation-and-breadcrumb-identity
  (let [routes (:node-routes (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"outlinerState\":{\"editing\":null},\"nodeRoutes\":[{\"uuid\":\"tag-a\",\"isTag\":true,\"isProperty\":false,\"page\":{\"uuid\":\"tag-a\",\"title\":\"Project\"},\"blocks\":[],\"relatedBlocks\":[{\"uuid\":\"page-object\",\"title\":\"Tagged page\",\"pageId\":\"page-object\",\"breadcrumbs\":[{\"uuid\":\"journal\",\"title\":\"Journal\"}],\"markup\":[]}],\"linkedReferenceBlocks\":[{\"uuid\":\"linked\",\"title\":\"Linked block\",\"pageId\":\"journal\",\"breadcrumbs\":[],\"markup\":[]}],\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"outlinerAutocompleteCandidates\":[]}],\"syncConnected\":true}}"))
        route (nth routes 0)
        related (:related-rows route)
        linked (:linked-reference-rows route)
        row (nth related 0)]
    (is (= 1 (count routes)))
    (is (= 1 (count related)))
    (is (= 1 (count linked)))
    (is (:opens-as-page row))
    (is (= "Journal" (:breadcrumb row)))
    (is (= [["journal" "Journal"]]
           (mapv (fn [entry] [(:uuid entry) (:title entry)]) (:breadcrumbs row))))
    (is (= "linked" (:uuid (nth linked 0))))))

(deftest sidebar-pages-and-related-rows
  (let [sidebar (:sidebar (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"favorites\":[{\"uuid\":\"page-a\",\"title\":\"Favorite page\"}],\"recentPages\":[{\"uuid\":\"page-b\",\"title\":\"Recent page\"}],\"selectedPage\":{\"uuid\":\"page-a\",\"title\":\"Favorite page\"},\"selectedPageIsTag\":false,\"selectedPageIsProperty\":false,\"relatedBlocks\":[{\"uuid\":\"reference\",\"title\":\"Linked from journal\",\"pageId\":\"journal\",\"breadcrumbs\":[{\"uuid\":\"journal\",\"title\":\"Journal\"}],\"markup\":[]}],\"linkedReferenceBlocks\":[],\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"syncConnected\":true}}"))]
    (is (= ["page-a"] (mapv :uuid (:favorites sidebar))))
    (is (= ["page-b"] (mapv :uuid (:recent-pages sidebar))))
    (is (= (Some "page-a") (when-some [page (:selected-page sidebar)] (:uuid page))))
    (is (= [["reference" "Journal"]]
           (mapv (fn [row] [(:uuid row) (:breadcrumb row)]) (:related-rows sidebar))))))

(deftest rich-flashcard-cloze-and-answers
  (let [cards (:flashcards (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"flashcards\":[{\"block\":{\"uuid\":\"card-a\",\"title\":\"Remember {{cloze this}}\",\"markup\":[{\"type\":\"text\",\"text\":\"Remember \"},{\"type\":\"cloze\",\"text\":\"this\"}]},\"children\":[{\"uuid\":\"answer-a\",\"title\":\"Child answer\",\"markup\":[{\"type\":\"text\",\"text\":\"Child answer\"}]}],\"due\":1,\"repetitions\":0,\"lapses\":0,\"state\":\"new\"}],\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"syncConnected\":true}}"))
        card (nth cards 0)]
    (is (= 1 (count cards)))
    (is (= "card-a" (:uuid card)))
    (is (= "Remember […]" (:question-hidden card)))
    (is (= "Remember this" (:question-revealed card)))
    (is (:has-cloze card))
    (is (= 1 (count (:answer-rows card))))
    (let [answer (nth (:answer-rows card) 0)]
      (is (= "answer-a" (:uuid answer)))
      (is (= "Child answer" (:text answer)))
      (is (= 0 (:index answer))))))

(deftest legacy-flashcard-cloze
  (let [cards (:flashcards (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"flashcards\":[{\"block\":{\"uuid\":\"legacy-card\",\"title\":\"Remember {{cloze this}}\"},\"children\":[],\"due\":1,\"repetitions\":0,\"lapses\":0,\"state\":\"new\"}],\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"syncConnected\":true}}"))
        card (nth cards 0)]
    (is (= 1 (count cards)))
    (is (= "Remember […]" (:question-hidden card)))
    (is (= "Remember this" (:question-revealed card)))
    (is (:has-cloze card))))

(deftest graph-catalog-flags
  (let [projection (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"graphName\":\"Local graph\",\"selectedGraphId\":\"local\",\"graphs\":[{\"id\":\"local\",\"name\":\"Local graph\",\"schemaVersion\":\"65.33\",\"isEncrypted\":false,\"isReady\":true},{\"id\":\"remote\",\"name\":\"Remote graph\",\"schemaVersion\":null,\"isEncrypted\":true,\"isReady\":false}],\"isGraphEncrypted\":false,\"isGraphUnlocked\":true,\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"syncConnected\":true}}")
        graphs (:graphs projection)
        local (nth graphs 0)
        remote (nth graphs 1)]
    (is (= (Some "local") (:selected-graph-id projection)))
    (is (not (:is-graph-encrypted projection)))
    (is (:is-graph-unlocked projection))
    (is (= 2 (count graphs)))
    (is (= "local" (:id local)))
    (is (= "Local graph" (:name local)))
    (is (not (:is-encrypted local)))
    (is (:is-ready local))
    (is (:is-encrypted remote))
    (is (not (:is-ready remote)))))

(deftest task-status-icons
  (let [statuses (:task-statuses (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"taskStatuses\":[{\"uuid\":\"waiting\",\"ident\":\"user.status/waiting\",\"title\":\"Waiting\",\"icon\":{\"type\":\"tabler-icon\",\"id\":\"clock\",\"color\":\"#7c3aed\"}}],\"outlinerState\":{\"editing\":null},\"outlinerRows\":[],\"syncConnected\":true}}"))
        status (nth statuses 0)]
    (is (= 1 (count statuses)))
    (is (= "waiting" (:uuid status)))
    (is (= (Some "user.status/waiting") (:ident status)))
    (is (= "Waiting" (:title status)))
    (is (= (Some "tabler-icon") (:icon-type status)))
    (is (= (Some "clock") (:icon-id status)))
    (is (= (Some "#7c3aed") (:icon-color status)))))

(deftest row-splice-bounds-and-content
  (let [projection (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"outlinerRows\":[],\"outlinerRowSplices\":[{\"start\":0,\"afterBlockId\":null,\"beforeBlockId\":null,\"deleteCount\":2,\"rows\":[{\"block\":{\"uuid\":\"outline-a\",\"title\":\"Nested note\",\"pageId\":\"journal-a\",\"journalTitle\":\"August 27th, 2026\",\"journalDay\":20260827},\"depth\":0,\"hasChildren\":true,\"isCollapsed\":true}]}],\"outlinerState\":{\"editing\":null},\"isOutlinerPatch\":true,\"syncConnected\":false}}")
        splices (:outliner-row-splices projection)
        splice (nth splices 0)
        rows (:rows splice)
        row (nth rows 0)]
    (is (:is-outliner-patch projection))
    (is (= 1 (count splices)))
    (is (= (Some 0) (:start splice)))
    (is (= 2 (:delete-count splice)))
    (is (= 1 (count rows)))
    (is (= "outline-a" (:uuid row)))
    (is (:is-collapsed row))
    (is (= "journal-a" (:page-id row)))
    (is (= (Some 20260827) (:journal-day row)))))

(deftest bounded-block-replacements-become-outliner-rows
  (let [rows (:outliner-rows (decoded "{\"apiVersion\":1,\"ok\":true,\"result\":{\"blocks\":[{\"uuid\":\"outline-a\",\"title\":\"Nested note\",\"pageId\":\"journal-a\",\"syncStatus\":\"pending\",\"status\":{\"uuid\":\"todo\",\"ident\":\"logseq.property/status.todo\",\"title\":\"Todo\"}}],\"outlinerRows\":[],\"outlinerRowSplices\":[],\"outlinerState\":{\"editing\":null},\"isOutlinerPatch\":true,\"syncConnected\":false}}"))
        row (nth rows 0)]
    (is (= 1 (count rows)))
    (is (= "outline-a" (:uuid row)))
    (is (= (Some "Todo") (when-some [status (:status row)] (:title status))))))

