module Markup = Logseq_chat_lg_core_native
module Model = Logseq_chat_lg_core_native

let summary uuid title : Model.entity_summary = Model.{ uuid; title }
let assert_bool label value = if not value then failwith label
let parse ~references ~tags source =
  Markup.logseq_chat_markup_parse references tags source |> Rrbvec.to_list
let to_yojson nodes = Markup.logseq_chat_markup_to_yojson (List.to_seq, nodes)
let debug_string = Markup.logseq_chat_markup_debug_string

let () =
  let references =
    [ summary "page-uuid" "Page target"
    ; summary "block-uuid" "Block target"
    ]
  in
  let tags = [ summary "tag-uuid" "Project" ] in
  let actual =
    parse
      ~references
      ~tags
      "Hello **bold** `code` [[page-uuid]] [[Block target]] #[[tag-uuid]]"
  in
  let expected =
    [ Markup.Markup_text "Hello "
    ; Markup.Markup_emphasis (":bold", Rrbvec.of_list [ Markup.Markup_text "bold" ])
    ; Markup.Markup_text " "
    ; Markup.Markup_code "code"
    ; Markup.Markup_text " "
    ; Markup.Markup_node_ref ("page-uuid", "Page target")
    ; Markup.Markup_text " "
    ; Markup.Markup_node_ref ("block-uuid", "Block target")
    ; Markup.Markup_text " "
    ; Markup.Markup_tag_ref ("tag-uuid", "Project")
    ]
  in
  if actual <> expected
  then
    failwith
      ("mldoc inline AST did not preserve rich node semantics: "
       ^ String.concat "; " (List.map debug_string actual))
;;

let () =
  match parse ~references:[] ~tags:[] "Legacy ((block-uuid)) stays text" with
  | [ Markup.Markup_text "Legacy ((block-uuid)) stays text" ] -> ()
  | _ -> failwith "removed block-reference syntax must not create a typed node reference"
;;

let () =
  let actual = parse ~references:[] ~tags:[] "Unknown [[missing]]" in
  match actual with
  | [ Markup.Markup_text "Unknown [[missing]]" ] -> ()
  | _ ->
    failwith
      ("an unresolved node reference must preserve its raw source: "
       ^ String.concat "; " (List.map debug_string actual))
;;

let () =
  let actual = parse ~references:[] ~tags:[] "Unknown #[[missing]]" in
  match actual with
  | [ Markup.Markup_text "Unknown #[[missing]]" ] -> ()
  | _ ->
    failwith
      ("an unresolved inline tag must preserve its raw source: "
       ^ String.concat "; " (List.map debug_string actual))
;;

let () =
  let tags = [ summary "tag-uuid" "Project" ] in
  match parse ~references:[] ~tags "Inline #[[Project]] tag" with
  | [ Markup.Markup_text "Inline "
    ; Markup.Markup_tag_ref ("tag-uuid", "Project")
    ; Markup.Markup_text " tag"
    ] -> ()
  | actual ->
    failwith
      ("an inline tag title must resolve to its canonical tag entity: "
       ^ String.concat "; " (List.map debug_string actual))
;;

let () =
  let json =
    to_yojson
      [ Markup.Markup_text "Open "
      ; Markup.Markup_node_ref ("block-uuid", "Target")
      ; Markup.Markup_tag_ref ("tag-uuid", "Project")
      ]
  in
  match json with
  | `List
      [ `Assoc [ "type", `String "text"; "text", `String "Open " ]
      ; `Assoc
          [ "type", `String "nodeReference"
          ; "uuid", `String "block-uuid"
          ; "title", `String "Target"
          ]
      ; `Assoc
          [ "type", `String "tagReference"
          ; "uuid", `String "tag-uuid"
          ; "title", `String "Project"
          ]
      ] -> ()
  | _ -> failwith "typed mldoc nodes must have a stable Swift-facing JSON contract"
;;

let markup_json source =
  let nodes = Markup.logseq_chat_markup_parse [] [] source in
  Markup.logseq_chat_markup_to_yojson (Rrbvec.to_seq, nodes)

let () =
  assert_bool "inline math retains surrounding text"
    (parse ~references:[] ~tags:[] "Inline $x^2$ math"
     = [Markup.Markup_text "Inline "; Markup.Markup_math ("x^2", false); Markup.Markup_text " math"]);
  assert_bool "unknown macros preserve their raw source"
    (parse ~references:[] ~tags:[] "{{unknown value}}" = [Markup.Markup_text "{{unknown value}}"]);
  assert_bool "cloze joins its arguments"
    (parse ~references:[] ~tags:[] "{{cloze first, second}}" = [Markup.Markup_cloze "first, second"]);
  assert_bool "cloze permits empty content"
    (parse ~references:[] ~tags:[] "{{cloze}}" = [Markup.Markup_cloze ""])
;;

let () =
  let module LG = Logseq_chat_lg_core_native in
  List.iter (fun source ->
    assert_bool "non-fenced input must not create a code block"
      (LG.logseq_chat_markup_fenced_code source = None)) ["```"; "plain"];
  let nodes = LG.logseq_chat_markup_append_node
    (Rrbvec.of_list [LG.Markup_text "first"])
    (LG.Markup_text " second") |> Rrbvec.to_list in
  assert_bool "LG coalesces adjacent text in forward order"
    (nodes = [LG.Markup_text "first second"])
;;

let () =
  List.iter (fun (source, seconds, label) ->
    match Markup.logseq_chat_markup_youtube_timestamp source with
    | Some (Markup.Markup_youtube_timestamp (actual_seconds, actual_label)) ->
      assert_bool ("timestamp seconds: " ^ source) (actual_seconds = seconds);
      assert_bool ("timestamp label: " ^ source) (actual_label = label)
    | _ -> failwith ("valid timestamp was rejected: " ^ source))
    [ "0", 0, "00:00"
    ; " 83 ", 83, "01:23"
    ; "59:59", 3599, "59:59"
    ; "25:01:02", 90062, "25:01:02"
    ];
  List.iter (fun source ->
    assert_bool ("invalid timestamp: " ^ source) (Markup.logseq_chat_markup_youtube_timestamp source = None))
    [ ""; "-1"; "60:00"; "00:60"; "1:60:00"; "1:00:60"
    ; "1:2:3:4"; "words"; "999999999999999999999999999999"
    ];
  assert_bool "invalid timestamp emits no node"
    (markup_json "{{youtube-timestamp 60:00}}" = `List [])
;;

let () =
  let refs = [ summary "target-id" "Canonical Title" ] in
  assert_bool "reference titles match case-insensitively"
    (parse ~references:refs ~tags:[] "[[canonical title]]"
     = [Markup.Markup_node_ref ("target-id", "Canonical Title")]);
  let source = "\240\159\152\128 Unknown [[missing]] and #[[missing]]" in
  assert_bool "unknown references preserve UTF-8 source and merge adjacent text"
    (parse ~references:[] ~tags:[] source = [Markup.Markup_text source]);
  assert_bool "empty source emits no nodes" (markup_json "" = `List []);
  assert_bool "fenced code preserves content and an empty language"
    (markup_json "```\nline 1\nline 2\n```"
     = `List [`Assoc ["type", `String "codeBlock";
                     "text", `String "line 1\nline 2\n";
                     "style", `String ""]]);
  assert_bool "empty display math remains display math"
    (markup_json "$$$$"
     = `List [`Assoc ["type", `String "math"; "text", `String "";
                     "style", `String "display"]]);
  assert_bool "tweet URLs lose query strings before extracting ids"
    (Markup.logseq_chat_markup_tweet_id " https://x.com/logseq/status/123/?tracking=true " = "123")
;;

let () =
  assert_bool "markdown quote is exposed as a quote node"
    (match markup_json "> quoted text" with
     | `List [ `Assoc fields ] -> List.assoc_opt "type" fields = Some (`String "quote")
     | _ -> false);
  assert_bool "display math is exposed as a native math node"
    (match markup_json "$$x^2 + y^2$$" with
     | `List [ `Assoc fields ] ->
       List.assoc_opt "type" fields = Some (`String "math")
       && List.assoc_opt "text" fields = Some (`String "x^2 + y^2")
     | _ -> false);
  assert_bool "fenced source is exposed as a code block with its language"
    (match markup_json "```swift\nlet value = 1\n```" with
     | `List [ `Assoc fields ] ->
       List.assoc_opt "type" fields = Some (`String "codeBlock")
       && List.assoc_opt "style" fields = Some (`String "swift")
     | _ -> false)
;;

let () =
  let embed source expected_type expected_url =
    match markup_json source with
    | `List [ `Assoc fields ] ->
      List.assoc_opt "type" fields = Some (`String expected_type)
      && List.assoc_opt "url" fields = Some (`String expected_url)
    | _ -> false
  in
  assert_bool "video macro becomes a playable video node"
    (embed
       "{{video https://cdn.example.com/demo.mp4}}"
       "video"
       "https://cdn.example.com/demo.mp4");
  assert_bool "iframe macro becomes an embedded web node"
    (embed
       "{{iframe https://example.com/embed}}"
       "iframe"
       "https://example.com/embed");
  assert_bool "YouTube video macros become YouTube embeds"
    (embed
       "{{video https://www.youtube.com/watch?v=dQw4w9WgXcQ}}"
       "video"
       "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
  assert_bool "YouTube id macros become playable embeds"
    (embed "{{youtube dQw4w9WgXcQ}}" "video" "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
  assert_bool "Vimeo macros become playable embeds"
    (embed "{{vimeo 76979871}}" "video" "https://player.vimeo.com/video/76979871");
  assert_bool "Bilibili macros become playable embeds"
    (embed
       "{{bilibili BV1xx411c7mD}}"
       "iframe"
       "https://player.bilibili.com/player.html?bvid=BV1xx411c7mD");
  assert_bool "Twitter macros preserve an embeddable status id"
    (embed
       "{{twitter https://x.com/logseq/status/1234567890}}"
       "iframe"
       "https://platform.twitter.com/embed/Tweet.html?id=1234567890");
  let timestamp source expected_label expected_seconds =
    match markup_json source with
    | `List [ `Assoc fields ] ->
      List.assoc_opt "type" fields = Some (`String "youtubeTimestamp")
      && List.assoc_opt "text" fields = Some (`String expected_label)
      && List.assoc_opt "style" fields = Some (`String expected_seconds)
    | _ -> false
  in
  assert_bool "YouTube timestamp seconds are rendered"
    (timestamp "{{youtube-timestamp 83}}" "01:23" "83");
  assert_bool "YouTube timestamp clock values are rendered"
    (timestamp "{{youtube-timestamp 01:01:23}}" "01:01:23" "3683")
;;

let () =
  match markup_json "Before {{video https://cdn.example.com/demo.mp4}} after" with
  | `List [ `Assoc before; `Assoc video; `Assoc after ] ->
    assert_bool "mixed rich markup keeps leading text"
      (List.assoc_opt "text" before = Some (`String "Before "));
    assert_bool "mixed rich markup keeps the embedded node"
      (List.assoc_opt "type" video = Some (`String "video"));
    assert_bool "mixed rich markup keeps trailing text"
      (List.assoc_opt "text" after = Some (`String " after"))
  | _ -> failwith "mixed rich markup must preserve text around embedded nodes"
;;

let () =
  match markup_json "{{cloze Remember this}}" with
  | `List [ `Assoc fields ] ->
    assert_bool "cloze macro is typed"
      (List.assoc_opt "type" fields = Some (`String "cloze"));
    assert_bool "cloze content is preserved"
      (List.assoc_opt "text" fields = Some (`String "Remember this"))
  | _ -> failwith "cloze macro must be represented as interactive rich content"
;;
