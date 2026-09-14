(ns logseq-chat.markup
  (:require [clojure.string :as string]
            [logseq-chat.cache-model :as model]
            [ocaml.Mldoc.Inline :as inline]
            [ocaml.Mldoc.Conf :as conf]
            [ocaml.Angstrom :as angstrom]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.String :as bytes]
            [ocaml.Stdlib :as stdlib]))

(type-variant markup-node
  (Markup_text :string)
  (Markup_emphasis :keyword :vector<markup-node>)
  (Markup_code :string)
  (Markup_code_block :option<string> :string)
  (Markup_quote :vector<markup-node>)
  (Markup_math :string :bool)
  (Markup_video :string)
  (Markup_iframe :string)
  (Markup_youtube_timestamp :int :string)
  (Markup_cloze :string)
  (Markup_link :string :vector<markup-node>)
  (Markup_node_ref :string :string)
  (Markup_tag_ref :string :string))

(defn emphasis-string [style]
  (case style
    :bold "bold"
    :italic "italic"
    :underline "underline"
    :strike-through "strikeThrough"
    :highlight "highlight"))

(defn debug-string [node]
  (match node
    (Markup_text value) (str "Text(" (pr-str value) ")")
    (Markup_code value) (str "Code(" (pr-str value) ")")
    (Markup_code_block language code) (str "CodeBlock(" (pr-str (or language "")) "," (pr-str code) ")")
    (Markup_quote children) (str "Quote([" (string/join ";" (mapv debug-string children)) "])")
    (Markup_math expression display) (str "Math(" display "," (pr-str expression) ")")
    (Markup_video url) (str "Video(" (pr-str url) ")")
    (Markup_iframe url) (str "Iframe(" (pr-str url) ")")
    (Markup_youtube_timestamp seconds label) (str "YoutubeTimestamp(" seconds "," (pr-str label) ")")
    (Markup_cloze value) (str "Cloze(" (pr-str value) ")")
    (Markup_node_ref uuid title) (str "Node(" (pr-str uuid) "," (pr-str title) ")")
    (Markup_tag_ref uuid title) (str "Tag(" (pr-str uuid) "," (pr-str title) ")")
    (Markup_emphasis _ children) (str "Emphasis([" (string/join ";" (mapv debug-string children)) "])")
    (Markup_link url children) (str "Link(" (pr-str url) ",[" (string/join ";" (mapv debug-string children)) "])")))

(defn node-to-yojson [node]
  (let [fields
        (match node
          (Markup_text text) [(tuple "type" (tag String "text")) (tuple "text" (tag String text))]
          (Markup_code text) [(tuple "type" (tag String "code")) (tuple "text" (tag String text))]
          (Markup_code_block language code)
          [(tuple "type" (tag String "codeBlock")) (tuple "text" (tag String code))
           (tuple "style" (tag String (or language "")))]
          (Markup_quote children)
          [(tuple "type" (tag String "quote"))
           (tuple "children" (tag List (rrbvec/to-list (mapv node-to-yojson children))))]
          (Markup_math expression display)
          [(tuple "type" (tag String "math")) (tuple "text" (tag String expression))
           (tuple "style" (tag String (if display "display" "inline")))]
          (Markup_video url) [(tuple "type" (tag String "video")) (tuple "url" (tag String url))]
          (Markup_iframe url) [(tuple "type" (tag String "iframe")) (tuple "url" (tag String url))]
          (Markup_youtube_timestamp seconds label)
          [(tuple "type" (tag String "youtubeTimestamp")) (tuple "text" (tag String label))
           (tuple "style" (tag String (str seconds)))]
          (Markup_cloze text) [(tuple "type" (tag String "cloze")) (tuple "text" (tag String text))]
          (Markup_emphasis style children)
          [(tuple "type" (tag String "emphasis")) (tuple "style" (tag String (emphasis-string style)))
           (tuple "children" (tag List (rrbvec/to-list (mapv node-to-yojson children))))]
          (Markup_link url children)
          [(tuple "type" (tag String "link")) (tuple "url" (tag String url))
           (tuple "children" (tag List (rrbvec/to-list (mapv node-to-yojson children))))]
          (Markup_node_ref uuid title)
          [(tuple "type" (tag String "nodeReference")) (tuple "uuid" (tag String uuid))
           (tuple "title" (tag String title))]
          (Markup_tag_ref uuid title)
          [(tuple "type" (tag String "tagReference")) (tuple "uuid" (tag String uuid))
           (tuple "title" (tag String title))])]
    (tag Assoc (rrbvec/to-list fields))))

(defn to-yojson [nodes] (tag List (rrbvec/to-list (mapv node-to-yojson nodes))))

(def config
  (record Mldoc.Conf.t
    (toc false) (parse-outline-only false) (heading-number false) (keep-line-break true)
    (format (conf/Markdown)) (heading-to-list false) (exporting-keep-properties false)
    (inline-type-with-pos true) (inline-skip-macro false) (export-md-indent-style (conf/Dashes))
    (export-md-remove-options (list)) (hiccup-in-block true) (enable-drawers true)
    (parse-marker true) (parse-priority true)))

(defn strip-wrapped [left right value]
  (if (and (>= (count value) (+ (count left) (count right)))
           (string/starts-with? value left) (string/ends-with? value right))
    (subs value (count left) (- (count value) (count right)))
    value))

(defn find-summary [^:list<model/entity-summary> summaries value]
  (some (fn [summary]
          (when (or (= value (:uuid summary))
                    (= (bytes/lowercase-ascii value) (bytes/lowercase-ascii (:title summary))))
            summary))
        summaries))

(defn append-node [nodes node]
  (match node
    (Markup_text text)
    (cond
      (= text "") nodes
      (empty? nodes) [node]
      :else (match (peek nodes)
              (Some (Markup_text previous)) (conj (pop nodes) (Markup_text (str previous text)))
              _ (conj nodes node)))
    _ (conj nodes node)))

(defn last-path-component [value]
  (last (remove (fn [part] (= part "")) (bytes/split-on-char \/ value))))

(defn youtube-url [value]
  (let [value (string/trim value)]
    (if (or (string/starts-with? value "http://") (string/starts-with? value "https://"))
      value
      (str "https://www.youtube.com/watch?v=" value))))

(defn nonnegative-integer [value]
  (try
    (let [number (stdlib/int-of-string value)] (when (>= number 0) number))
    (catch (Failure _) nil)))

(defn clock-seconds [parts]
  (let [parts (vec parts)
        numbers (vec (keep nonnegative-integer parts))]
    (when (= (count parts) (count numbers))
      (case (count numbers)
        1 (nth numbers 0)
        2 (let [minutes (nth numbers 0) seconds (nth numbers 1)]
            (when (and (<= minutes 59) (<= seconds 59)) (+ (* minutes 60) seconds)))
        3 (let [hours (nth numbers 0) minutes (nth numbers 1) seconds (nth numbers 2)]
            (when (and (<= minutes 59) (<= seconds 59)) (+ (* hours 3600) (* minutes 60) seconds)))
        nil))))

(defn two-digits [value] (str (if (< value 10) "0" "") value))

(defn youtube-timestamp [value]
  (when-some [seconds (clock-seconds (vec (bytes/split-on-char \: (string/trim value))))]
    (let [hours (quot seconds 3600)
          minutes (quot (rem seconds 3600) 60)
          remainder (rem seconds 60)
          label (str (if (> hours 0) (str (two-digits hours) ":") "")
                     (two-digits minutes) ":" (two-digits remainder))]
      (Markup_youtube_timestamp seconds label))))

(defn tweet-id [value]
  (let [value (string/trim value)]
    (if-some [without-query (first (bytes/split-on-char \? value))]
      (or (last-path-component without-query) value)
      value)))

(defn fenced-code [source]
  (when (and (string/starts-with? source "```") (string/ends-with? source "```"))
    (when-some [newline (bytes/index-opt source \newline)]
      (let [language (string/trim (subs source 3 newline))
            length (- (count source) newline 4)]
        (when (>= length 0)
          (Markup_code_block (when (not= language "") language)
                             (subs source (inc newline) (+ (inc newline) length))))))))

(defn node-name [^:Mldoc.Nested_link.t link]
  (string/trim (strip-wrapped "[[" "]]" (:content link))))

(defn source-slice [source position]
  (if-some [position position]
    (if (and (>= (:start-pos position) 0) (>= (:end-pos position) (:start-pos position))
             (<= (:end-pos position) (count source)))
      (subs source (:start-pos position) (:end-pos position))
      "")
    ""))

(defn emphasis [style]
  (match style
    (tag Bold) :bold (tag Italic) :italic (tag Underline) :underline
    (tag Strike_through) :strike-through (tag Highlight) :highlight))

(defn tag-part [node]
  (match node
    (inline/Nested_link link) (node-name link)
    (inline/Link link) (match (:url link) (inline/Page_ref value) value _ (inline/ascii node))
    (inline/Plain value) value
    (inline/Spaces value) value
    _ (inline/ascii node)))

(defn convert-macro [macro raw]
  (let [name (bytes/lowercase-ascii (:name macro))
        arguments (:arguments macro)]
    (cond
      (= name "cloze") [(Markup_cloze (string/trim (string/join ", " arguments)))]
      (empty? arguments) raw
      :else
      (let [value (or (first arguments) "")]
        (case name
          "video" [(Markup_video (string/trim value))]
          "iframe" [(Markup_iframe (string/trim value))]
          "youtube" [(Markup_video (youtube-url value))]
          "youtube-timestamp" (vec (keep identity [(youtube-timestamp value)]))
          "vimeo" [(Markup_video (str "https://player.vimeo.com/video/" (string/trim value)))]
          "bilibili" [(Markup_iframe (str "https://player.bilibili.com/player.html?bvid=" (string/trim value)))]
          "tweet" [(Markup_iframe (str "https://platform.twitter.com/embed/Tweet.html?id=" (tweet-id value)))]
          "twitter" [(Markup_iframe (str "https://platform.twitter.com/embed/Tweet.html?id=" (tweet-id value)))]
          raw)))))

(defn convert-nodes [source references tags ^:vector<tuple<Mldoc.Inline.t;option<Mldoc.Pos.pos_meta>>> nodes]
  (reduce (fn [converted [node position]]
            (reduce append-node converted (convert-node source references tags node position)))
          [] nodes))

(defn convert-node [source references tags node position]
  (let [raw [(Markup_text (source-slice source position))]]
    (match node
      (inline/Plain value) [(Markup_text value)]
      (inline/Spaces value) [(Markup_text value)]
      (inline/Break_Line) [(Markup_text "\n")]
      (inline/Hard_Break_Line) [(Markup_text "\n")]
      (inline/Code value) [(Markup_code value)]
      (inline/Verbatim value) [(Markup_code value)]
      (inline/Latex_Fragment (inline/Inline expression)) [(Markup_math expression false)]
      (inline/Latex_Fragment (inline/Displayed expression)) [(Markup_math expression true)]
      (inline/Macro macro) (convert-macro macro raw)
      (inline/Emphasis [style children])
      [(Markup_emphasis (emphasis style)
         (convert-nodes source references tags (mapv (fn [child] (tuple child nil)) children)))]
      (inline/Nested_link link)
      (if-some [summary (find-summary references (node-name link))]
        [(Markup_node_ref (:uuid summary) (:title summary))] raw)
      (inline/Tag children)
      (let [value (string/trim (string/join "" (mapv tag-part children)))]
        (if-some [summary (find-summary tags value)]
          [(Markup_tag_ref (:uuid summary) (:title summary))] raw))
      (inline/Link link)
      (match (:url link)
        (inline/Block_ref _) raw
        (inline/Page_ref value)
        (if-some [summary (find-summary references value)]
          [(Markup_node_ref (:uuid summary) (:title summary))] raw)
        _ [(Markup_link (inline/string-of-url (:url link))
             (convert-nodes source references tags (mapv (fn [child] (tuple child nil)) (:label link))))])
      _ raw)))

(defn parse-inline [references tags source]
  (match (angstrom/parse-string :consume (angstrom/Consume.All) (inline/parse config) source)
    (Ok nodes) (convert-nodes source references tags (vec nodes))
    (Error _) [(Markup_text source)]))

(defn parse [references tags source]
  (cond
    (= source "") []
    :else
    (if-some [node (fenced-code source)]
      [node]
      (cond
        (and (string/starts-with? source "$$") (string/ends-with? source "$$"))
        [(Markup_math (strip-wrapped "$$" "$$" source) true)]
        (string/starts-with? source ">")
        [(Markup_quote (parse-inline references tags (string/trim (subs source 1))))]
        :else (parse-inline references tags source)))))
