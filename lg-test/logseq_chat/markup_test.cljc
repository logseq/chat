(ns logseq-chat.markup-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.markup :as markup]
            [logseq-chat.cache-model :as model]
            [ocaml.Yojson.Basic :as json]))

(defn summary [uuid title] (record model/entity-summary (uuid uuid) (title title)))
(defn parse [source] (markup/parse (list) (list) source))
(defn markup-json [source] (markup/to-yojson (parse source)))

(deftest rich-node-semantics
  (is (= [(markup/Markup_text "Hello ")
          (markup/Markup_emphasis :bold [(markup/Markup_text "bold")])
          (markup/Markup_text " ") (markup/Markup_code "code") (markup/Markup_text " ")
          (markup/Markup_node_ref "page-uuid" "Page target") (markup/Markup_text " ")
          (markup/Markup_node_ref "block-uuid" "Block target") (markup/Markup_text " ")
          (markup/Markup_tag_ref "tag-uuid" "Project")]
         (markup/parse (list (summary "page-uuid" "Page target") (summary "block-uuid" "Block target"))
                       (list (summary "tag-uuid" "Project"))
                       "Hello **bold** `code` [[page-uuid]] [[Block target]] #[[tag-uuid]]"))))

(deftest reference-resolution-and-raw-source
  (run! (fn [source] (is (= [(markup/Markup_text source)] (parse source))))
        ["Legacy ((block-uuid)) stays text" "Unknown [[missing]]" "Unknown #[[missing]]"
         "😀 Unknown [[missing]] and #[[missing]]" "{{unknown value}}"])
  (is (= [(markup/Markup_text "Inline ") (markup/Markup_tag_ref "tag-uuid" "Project") (markup/Markup_text " tag")]
         (markup/parse (list) (list (summary "tag-uuid" "Project")) "Inline #[[Project]] tag")))
  (is (= [(markup/Markup_node_ref "target-id" "Canonical Title")]
         (markup/parse (list (summary "target-id" "Canonical Title")) (list) "[[canonical title]]"))))

(deftest stable-native-json-contract
  (is (= (json/from-string "[{\"type\":\"text\",\"text\":\"Open \"},{\"type\":\"nodeReference\",\"uuid\":\"block-uuid\",\"title\":\"Target\"},{\"type\":\"tagReference\",\"uuid\":\"tag-uuid\",\"title\":\"Project\"}]")
         (markup/to-yojson [(markup/Markup_text "Open ") (markup/Markup_node_ref "block-uuid" "Target")
                            (markup/Markup_tag_ref "tag-uuid" "Project")]))))

(deftest inline-math-cloze-and-text-coalescing
  (is (= [(markup/Markup_text "Inline ") (markup/Markup_math "x^2" false) (markup/Markup_text " math")]
         (parse "Inline $x^2$ math")))
  (is (= [(markup/Markup_cloze "first, second")] (parse "{{cloze first, second}}")))
  (is (= [(markup/Markup_cloze "")] (parse "{{cloze}}")))
  (run! #(is (nil? (markup/fenced-code %))) ["```" "plain"])
  (is (= [(markup/Markup_text "first second")]
         (markup/append-node [(markup/Markup_text "first")] (markup/Markup_text " second")))))

(deftest timestamp-validation
  (run! (fn [[source seconds label]]
          (is (= (Some (markup/Markup_youtube_timestamp seconds label)) (markup/youtube-timestamp source))))
        [(tuple "0" 0 "00:00") (tuple " 83 " 83 "01:23")
         (tuple "59:59" 3599 "59:59") (tuple "25:01:02" 90062 "25:01:02")])
  (run! #(is (nil? (markup/youtube-timestamp %)))
        ["" "-1" "60:00" "00:60" "1:60:00" "1:00:60" "1:2:3:4" "words" "999999999999999999999999999999"])
  (is (= (json/from-string "[]") (markup-json "{{youtube-timestamp 60:00}}"))))

(deftest block-markup-boundaries
  (is (= (json/from-string "[]") (markup-json "")))
  (is (= (json/from-string "[{\"type\":\"codeBlock\",\"text\":\"line 1\\nline 2\\n\",\"style\":\"\"}]")
         (markup-json "```\nline 1\nline 2\n```")))
  (is (= (json/from-string "[{\"type\":\"math\",\"text\":\"\",\"style\":\"display\"}]") (markup-json "$$$$")))
  (is (= "123" (markup/tweet-id " https://x.com/logseq/status/123/?tracking=true ")))
  (run! (fn [[source expected]]
          (is (= (json/from-string expected) (markup-json source))))
        [["> quoted text" "[{\"type\":\"quote\",\"children\":[{\"type\":\"text\",\"text\":\"quoted text\"}]}]"]
         ["$$x^2 + y^2$$" "[{\"type\":\"math\",\"text\":\"x^2 + y^2\",\"style\":\"display\"}]"]
         ["```swift\nlet value = 1\n```" "[{\"type\":\"codeBlock\",\"text\":\"let value = 1\\n\",\"style\":\"swift\"}]"]
         ["{{cloze Remember this}}" "[{\"type\":\"cloze\",\"text\":\"Remember this\"}]"]]))

(deftest playable-and-web-embeds
  (run! (fn [[source expected]]
          (is (= (json/from-string expected) (markup-json source))))
        [["{{video https://cdn.example.com/demo.mp4}}" "[{\"type\":\"video\",\"url\":\"https://cdn.example.com/demo.mp4\"}]"]
         ["{{iframe https://example.com/embed}}" "[{\"type\":\"iframe\",\"url\":\"https://example.com/embed\"}]"]
         ["{{video https://www.youtube.com/watch?v=dQw4w9WgXcQ}}" "[{\"type\":\"video\",\"url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}]"]
         ["{{youtube dQw4w9WgXcQ}}" "[{\"type\":\"video\",\"url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}]"]
         ["{{vimeo 76979871}}" "[{\"type\":\"video\",\"url\":\"https://player.vimeo.com/video/76979871\"}]"]
         ["{{bilibili BV1xx411c7mD}}" "[{\"type\":\"iframe\",\"url\":\"https://player.bilibili.com/player.html?bvid=BV1xx411c7mD\"}]"]
         ["{{twitter https://x.com/logseq/status/1234567890}}" "[{\"type\":\"iframe\",\"url\":\"https://platform.twitter.com/embed/Tweet.html?id=1234567890\"}]"]
         ["{{youtube-timestamp 83}}" "[{\"type\":\"youtubeTimestamp\",\"text\":\"01:23\",\"style\":\"83\"}]"]
         ["{{youtube-timestamp 01:01:23}}" "[{\"type\":\"youtubeTimestamp\",\"text\":\"01:01:23\",\"style\":\"3683\"}]"]]))

(deftest mixed-embeds-retain-surrounding-text
  (is (= (json/from-string "[{\"type\":\"text\",\"text\":\"Before \"},{\"type\":\"video\",\"url\":\"https://cdn.example.com/demo.mp4\"},{\"type\":\"text\",\"text\":\" after\"}]")
         (markup-json "Before {{video https://cdn.example.com/demo.mp4}} after"))))
