(ns logseq-chat.search-index
  (:require [clojure.string :as string]
            [logseq-chat.cache-model :as model]
            [logseq-chat.graph-read :as graph]
            [logseq-chat.datascript-value :as ds-value]
            [logseq-chat.ref-text :as ref-text]
            [ocaml.Datascript :as ds]
            [ocaml.Datascript.Db :as db-api]
            [ocaml.String :as bytes]
            [ocaml.Char :as char]
            [ocaml.Float :as float]
            [ocaml.Str :as regex]
            [ocaml.Sys :as sys]
            [ocaml.Unix :as unix]
            [ocaml.Filename :as filename]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Rrbvec :as rrbvec]))

(ffi search-open [:string] :unit {:ocaml "logseq_chat_search_index_open"})
(ffi search-upsert [:string :list<tuple<string;string;string>>] :unit
  {:ocaml "logseq_chat_search_index_upsert"})
(ffi search-delete [:string :list<string>] :unit {:ocaml "logseq_chat_search_index_delete"})
(ffi search-query [:string :string :list<string>] :list<tuple<string;string;string>>
  {:ocaml "logseq_chat_search_index_query"})

(type-record search-index (path :string))
(type-record search-result
  (uuid :string) (title :string) (page-uuid :string) (is-page :bool) (score :float))
(type-record indexed-search-hit
  (uuid :string) (title :string) (is-page :bool)
  (page :option<model/entity-summary>) (breadcrumbs :vector<model/entity-summary>))

;; Preserve the existing byte-wise fuzzy matcher and UTF-8 length heuristic.
(defn utf8-length [value]
  (loop [index 0 length 0]
    (if (= index (bytes/length value)) length
        (recur (inc index)
               (if (= (bit-and (char/code (bytes/get value index)) 192) 128)
                 length (inc length))))))

(defn utf8-chars [value]
  (loop [index 0 start 0 result []]
    (cond
      (= index (bytes/length value))
      (if (< start index) (conj result (bytes/sub value start (- index start))) result)
      (and (> index start) (not= (bit-and (char/code (bytes/get value index)) 192) 128))
      (recur (inc index) index (conj result (bytes/sub value start (- index start))))
      :else (recur (inc index) start result))))

(defn clean-str [value]
  (reduce (fn [value part] (string/replace value part ""))
          (bytes/lowercase-ascii value) ["[" " " "\\" "/" "_" "]" "(" ")"]))

(defn str-len-distance [left right]
  (let [left (float/of-int (utf8-length left)) right (float/of-int (utf8-length right))
        longest (max left right) shortest (min left right)]
    (if (= longest 0.0) 1.0 (- 1.0 (/ (- longest shortest) longest)))))

(defn fuzzy-score [query target]
  (let [query (clean-str query) target (clean-str target)]
    (loop [query-index 0 target-index 0 mult 1 acc 0.0]
      (cond
        (>= query-index (bytes/length query))
        (+ acc (str-len-distance query target)
           (cond (string/starts-with? target query) 1010.0
                 (string/includes? target query) 1000.0 :else 0.0)
           (if (>= target-index (bytes/length target)) 1.0 0.0))
        (>= target-index (bytes/length target)) 0.0
        (= (bytes/get query query-index) (bytes/get target target-index))
        (recur (inc query-index) (inc target-index) (inc mult) (+ acc (float/of-int mult)))
        :else (recur query-index (inc target-index) 1 (- acc 0.1))))))

(defn fts-phrase-input [input] (str "\"" (string/replace input "\"" "\"\"") "\"*"))
(defn matches-regex? [pattern input]
  (try (do (regex/search-forward (regex/regexp pattern) input 0) true)
       (catch Not_found false)))
(defn dangling-boolean-operator [input] (matches-regex? "\\(^\\| \\)\\(AND\\|OR\\|NOT\\) *$" input))
(defn whitespace-char [value] (contains? #{\space \tab \newline \return} value))
(defn word-char [value]
  (let [code (char/code value)]
    (or (and (>= code 97) (<= code 122)) (and (>= code 65) (<= code 90))
        (and (>= code 48) (<= code 57)) (= code 95))))
(defn has-punctuation [query]
  (bytes/exists (fn [ch] (and (not (word-char ch)) (not (whitespace-char ch)))) query))
(defn get-match-input [query]
  (let [input (reduce (fn [input [from to]] (string/replace input from to)) query
                      [(tuple " and " " AND ") (tuple " & " " AND ")
                       (tuple " or " " OR ") (tuple " | " " OR ") (tuple " not " " NOT ")])
        boolean-operator (some (fn [operator] (string/includes? input operator)) ["AND" "OR" "NOT"])]
    (cond (dangling-boolean-operator input) (fts-phrase-input input)
          (and (has-punctuation query)
               (or (string/includes? input "\"") (not boolean-operator) (string/includes? query "/")))
          (fts-phrase-input input)
          (not= query input) (string/replace input "," "")
          :else input)))

(defn create [path]
  (let [directory (filename/dirname path)]
    (try (when (not (sys/file-exists directory)) (unix/mkdir directory 493))
         (catch (unix/Unix_error _ _ _) nil))
    (search-open path)
    (record search-index (path path))))

(defn row-of-eid [db eid]
  (let [title-for-uuid
        (fn [uuid]
          (when-some [eid (ds/entid db "block/uuid" (ds/Uuid uuid))]
            (when-some [title (graph/string-value (graph/value db eid "block/title"))]
              (when (not= (string/trim title) "") title))))]
    (when-some [uuid (graph/uuid-value (graph/value db eid "block/uuid"))]
      (when-some [title (graph/string-value (graph/value db eid "block/title"))]
        (let [hidden (or (= (graph/value db eid "logseq.property/built-in?") (Some (ds/Bool true)))
                         (some? (graph/value db eid "block/closed-value-property"))
                         (graph/page-is-hidden? db eid))]
          (when (and (not= (string/trim title) "") (not hidden) (<= (utf8-length title) 10000))
            (let [is-page (some? (graph/string-value (graph/value db eid "block/name")))
                  page-uuid (if is-page uuid
                                (or (when-some [page-eid (ds-value/optional-ref-eid db "block/page" (graph/value db eid "block/page"))]
                                      (graph/uuid-value (graph/value db page-eid "block/uuid"))) uuid))
                  title (ref-text/to-text title-for-uuid title-for-uuid title)
                  title (if-some [day (graph/int-value (graph/value db eid "block/journal-day"))]
                          (str title " " day) title)]
              (tuple uuid title page-uuid))))))))
(defn row-for-uuid [db uuid]
  (when-some [eid (ds/entid db "block/uuid" (ds/Uuid uuid))] (row-of-eid db eid)))
(defn rows-of-db [db]
  (vec (keep (fn [datom] (row-of-eid db (:e datom))) (db-api/datoms db (ds/Aevt) :a "block/uuid"))))
(defn referring-uuids [db uuid]
  (if-some [eid (ds/entid db "block/uuid" (ds/Uuid uuid))]
    (vec (keep (fn [datom] (graph/uuid-value (graph/value db (:e datom) "block/uuid")))
               (db-api/datoms db (ds/Aevt) :a "block/refs" :v (ds/Ref eid)))) []))

(defn refresh-uuids [index before after uuids]
  (let [affected (vec (distinct (mapcat (fn [uuid] (concat [uuid] (referring-uuids before uuid)
                                                         (referring-uuids after uuid))) uuids)))
        wanted (vec (keep (fn [uuid] (row-for-uuid after uuid)) affected))]
    (when (not (empty? affected)) (search-delete (:path index) (rrbvec/to-list affected)))
    (stdlib/ignore (when (not (empty? wanted)) (search-upsert (:path index) (rrbvec/to-list wanted))))))

(defn refresh [index db]
  (let [wanted (rows-of-db db)
        stored (search-query (:path index) "select id, page, title from blocks" (list))
        stored-by-id (into {} (map (fn [[id page title]] (tuple id (tuple title page))) stored))
        wanted-ids (set (map (fn [[id _ _]] id) wanted))
        changed (vec (filter (fn [[id title page]] (not= (get stored-by-id id) (Some (tuple title page)))) wanted))
        stale (vec (keep (fn [[id _ _]] (when (not (contains? wanted-ids id)) id)) stored))]
    (when (not (empty? stale)) (search-delete (:path index) (rrbvec/to-list stale)))
    (stdlib/ignore (when (not (empty? changed)) (search-upsert (:path index) (rrbvec/to-list changed))))))

(defn like-escape [value] (if (contains? #{"%" "_" "\\"} value) (str "\\" value) value))
(defn fuzzy-like-pattern [query] (str "%" (string/join "%" (map like-escape (utf8-chars query))) "%"))
(defn fuzzy-candidate-limit [limit] (min 400 (max 40 (* 4 limit))))
(defn exact-title-query [query] (not (bytes/exists whitespace-char query)))
(defn multi-term-query [query] (matches-regex? "[^ \t\n][ \t\n]+[^ \t\n]" query))
(defn query-rows [index sql binds]
  (try (vec (search-query (:path index) sql (rrbvec/to-list (vec binds))))
       (catch (Failure _) [])))
(defn scored [query rows]
  (mapv (fn [row]
          (match row
            (tuple id page title)
            (record search-result (uuid id) (title title) (page-uuid page)
                    (is-page (= id page)) (score (fuzzy-score query title))))) rows))
(defn fuzzy-rows [index query limit]
  (let [normalized (clean-str query)
        normalized (if (string/starts-with? normalized "#") (subs normalized 1) normalized)]
    (if (= (string/trim normalized) "") []
        (let [candidate-limit (fuzzy-candidate-limit limit)
              pattern (fuzzy-like-pattern normalized)
              page-rows (query-rows index (str "select id, page, title from blocks where id = page and lower(title) like ? escape '\\' limit " candidate-limit) [pattern])
              page-ids (set (map (fn [[id _ _]] id) page-rows))
              remaining (- candidate-limit (count page-rows))
              block-rows (if (pos? remaining)
                           (vec (take remaining
                                      (filter (fn [[id _ _]] (not (contains? page-ids id)))
                                              (query-rows index (str "select id, page, title from blocks where lower(title) like ? escape '\\' limit " (+ remaining (count page-rows))) [pattern])))) [])]
          (vec (filter (fn [result] (> (:score result) 0.0)) (scored normalized (concat page-rows block-rows))))))))

;; Keep candidate precedence stable before score sorting and UUID deduplication.
(defn search [has-tags limit index query]
  (let [query (string/trim query)]
    (if (= query "") []
        (let [input (get-match-input query)
              exact (if (exact-title-query query)
                      (scored query (query-rows index (str "select id, page, title from blocks where title = ? COLLATE NOCASE limit " limit) [query])) [])
              enough-exact (>= (count exact) limit)
              matched (if enough-exact []
                          (scored query (query-rows index (str "select id, page, title from blocks_fts where title match ? limit " limit) [input])))
              short (if (<= (utf8-length query) 2)
                      (scored query (query-rows index (str "select id, page, title from blocks_fts where title like ? limit " limit)
                                               [(str "%" (regex/global-replace (regex/regexp "[ \t\n]+") "%" query) "%")])) [])
              fuzzy (if (or enough-exact (and (multi-term-query query) (not (empty? matched)))) [] (fuzzy-rows index query limit))
              ranked (mapv (fn [result]
                             (tuple result (+ (:score result) (if (:is-page result) 2.0 0.0)
                                              (cond (:is-page result) 0.02 (has-tags (:uuid result)) 0.01 :else 0.0))))
                           (concat exact fuzzy matched short))
              sorted (sort (fn [[_ left] [_ right]] (compare right left)) ranked)
              [_ results] (reduce (fn [[seen results] [result _]]
                                    (if (contains? seen (:uuid result)) (tuple seen results)
                                        (tuple (conj seen (:uuid result)) (conj results result))))
                                  (tuple #{} []) sorted)]
          (vec (take (max 0 limit) results))))))

(defn search-hits [limit index db query]
  (let [entity-eid (fn [uuid] (ds/entid db "block/uuid" (ds/Uuid uuid)))
        has-tags (fn [uuid]
                   (if-some [eid (entity-eid uuid)]
                     (not (empty? (db-api/datoms db (ds/Eavt) :e eid :a "block/tags"))) false))
        plain (fn [value] (Ok value))]
    (mapv (fn [result]
            (let [page (if (:is-page result) nil
                          (when-some [eid (entity-eid (:page-uuid result))] (graph/page-summary plain db eid)))
                  breadcrumbs (if (:is-page result) []
                                  (if-some [eid (entity-eid (:uuid result))] (graph/breadcrumbs plain db eid) []))]
              (record indexed-search-hit (uuid (:uuid result)) (title (:title result)) (is-page (:is-page result))
                      (page page) (breadcrumbs breadcrumbs))))
          (search has-tags limit index query))))
