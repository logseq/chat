module Markup = Logseq_chat_markup
module Model = Logseq_chat_model

let summary uuid title = Model.{ uuid; title }
let assert_bool label value = if not value then failwith label

let () =
  let references =
    [ summary "page-uuid" "Page target"
    ; summary "block-uuid" "Block target"
    ]
  in
  let tags = [ summary "tag-uuid" "Project" ] in
  let actual =
    Markup.parse
      ~references
      ~tags
      "Hello **bold** `code` [[page-uuid]] [[Block target]] #[[tag-uuid]]"
  in
  let expected =
    [ Markup.Text "Hello "
    ; Markup.Emphasis (Markup.Bold, [ Markup.Text "bold" ])
    ; Markup.Text " "
    ; Markup.Code "code"
    ; Markup.Text " "
    ; Markup.Node_ref
        { uuid = "page-uuid"; title = "Page target" }
    ; Markup.Text " "
    ; Markup.Node_ref
        { uuid = "block-uuid"; title = "Block target" }
    ; Markup.Text " "
    ; Markup.Tag_ref { uuid = "tag-uuid"; title = "Project" }
    ]
  in
  if actual <> expected
  then
    failwith
      ("mldoc inline AST did not preserve rich node semantics: "
       ^ String.concat "; " (List.map Markup.debug_string actual))
;;

let () =
  match Markup.parse ~references:[] ~tags:[] "Legacy ((block-uuid)) stays text" with
  | [ Markup.Text "Legacy ((block-uuid)) stays text" ] -> ()
  | _ -> failwith "removed block-reference syntax must not create a typed node reference"
;;

let () =
  let actual = Markup.parse ~references:[] ~tags:[] "Unknown [[missing]]" in
  match actual with
  | [ Markup.Text "Unknown [[missing]]" ] -> ()
  | _ ->
    failwith
      ("an unresolved node reference must preserve its raw source: "
       ^ String.concat "; " (List.map Markup.debug_string actual))
;;

let () =
  let actual = Markup.parse ~references:[] ~tags:[] "Unknown #[[missing]]" in
  match actual with
  | [ Markup.Text "Unknown #[[missing]]" ] -> ()
  | _ ->
    failwith
      ("an unresolved inline tag must preserve its raw source: "
       ^ String.concat "; " (List.map Markup.debug_string actual))
;;

let () =
  let tags = [ summary "tag-uuid" "Project" ] in
  match Markup.parse ~references:[] ~tags "Inline #[[Project]] tag" with
  | [ Markup.Text "Inline "
    ; Markup.Tag_ref { uuid = "tag-uuid"; title = "Project" }
    ; Markup.Text " tag"
    ] -> ()
  | actual ->
    failwith
      ("an inline tag title must resolve to its canonical tag entity: "
       ^ String.concat "; " (List.map Markup.debug_string actual))
;;

let () =
  let json =
    Markup.to_yojson
      [ Markup.Text "Open "
      ; Markup.Node_ref { uuid = "block-uuid"; title = "Target" }
      ; Markup.Tag_ref { uuid = "tag-uuid"; title = "Project" }
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

let markup_json source = Markup.parse ~references:[] ~tags:[] source |> Markup.to_yojson

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
       "https://platform.twitter.com/embed/Tweet.html?id=1234567890")
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
