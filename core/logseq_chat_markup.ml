module Inline = Mldoc.Inline
module Model = Logseq_chat_model

type emphasis =
  | Bold
  | Italic
  | Underline
  | Strike_through
  | Highlight

type node_target =
  { uuid : string
  ; title : string
  }

type tag_target =
  { uuid : string
  ; title : string
  }

type t =
  | Text of string
  | Emphasis of emphasis * t list
  | Code of string
  | Code_block of
      { language : string option
      ; code : string
      }
  | Quote of t list
  | Math of
      { expression : string
      ; display : bool
      }
  | Video of string
  | Iframe of string
  | Cloze of string
  | Link of
      { url : string
      ; children : t list
      }
  | Node_ref of node_target
  | Tag_ref of tag_target

let rec debug_string = function
  | Text value -> Printf.sprintf "Text(%S)" value
  | Code value -> Printf.sprintf "Code(%S)" value
  | Code_block { language; code } ->
    Printf.sprintf "CodeBlock(%S,%S)" (Option.value language ~default:"") code
  | Quote children ->
    Printf.sprintf "Quote([%s])" (String.concat ";" (List.map debug_string children))
  | Math { expression; display } -> Printf.sprintf "Math(%b,%S)" display expression
  | Video url -> Printf.sprintf "Video(%S)" url
  | Iframe url -> Printf.sprintf "Iframe(%S)" url
  | Cloze text -> Printf.sprintf "Cloze(%S)" text
  | Node_ref target ->
    Printf.sprintf "Node(%S,%S)" target.uuid target.title
  | Tag_ref target -> Printf.sprintf "Tag(%S,%S)" target.uuid target.title
  | Emphasis (_, children) ->
    Printf.sprintf "Emphasis([%s])" (String.concat ";" (List.map debug_string children))
  | Link { url; children } ->
    Printf.sprintf "Link(%S,[%s])" url (String.concat ";" (List.map debug_string children))
;;

let emphasis_string = function
  | Bold -> "bold"
  | Italic -> "italic"
  | Underline -> "underline"
  | Strike_through -> "strikeThrough"
  | Highlight -> "highlight"
;;

let rec node_to_yojson = function
  | Text text -> `Assoc [ "type", `String "text"; "text", `String text ]
  | Code text -> `Assoc [ "type", `String "code"; "text", `String text ]
  | Code_block { language; code } ->
    `Assoc
      [ "type", `String "codeBlock"
      ; "text", `String code
      ; "style", `String (Option.value language ~default:"")
      ]
  | Quote children ->
    `Assoc
      [ "type", `String "quote"
      ; "children", `List (List.map node_to_yojson children)
      ]
  | Math { expression; display } ->
    `Assoc
      [ "type", `String "math"
      ; "text", `String expression
      ; "style", `String (if display then "display" else "inline")
      ]
  | Video url -> `Assoc [ "type", `String "video"; "url", `String url ]
  | Iframe url -> `Assoc [ "type", `String "iframe"; "url", `String url ]
  | Cloze text -> `Assoc [ "type", `String "cloze"; "text", `String text ]
  | Emphasis (style, children) ->
    `Assoc
      [ "type", `String "emphasis"
      ; "style", `String (emphasis_string style)
      ; "children", `List (List.map node_to_yojson children)
      ]
  | Link { url; children } ->
    `Assoc
      [ "type", `String "link"
      ; "url", `String url
      ; "children", `List (List.map node_to_yojson children)
      ]
  | Node_ref target ->
    `Assoc
      [ "type", `String "nodeReference"
      ; "uuid", `String target.uuid
      ; "title", `String target.title
      ]
  | Tag_ref target ->
    `Assoc
      [ "type", `String "tagReference"
      ; "uuid", `String target.uuid
      ; "title", `String target.title
      ]
;;

let to_yojson nodes = `List (List.map node_to_yojson nodes)

let config : Mldoc.Conf.t =
  { toc = false
  ; parse_outline_only = false
  ; heading_number = false
  ; keep_line_break = true
  ; format = Markdown
  ; heading_to_list = false
  ; exporting_keep_properties = false
  ; inline_type_with_pos = true
  ; inline_skip_macro = false
  ; export_md_indent_style = Dashes
  ; export_md_remove_options = []
  ; hiccup_in_block = true
  ; enable_drawers = true
  ; parse_marker = true
  ; parse_priority = true
  }
;;

let strip_wrapped ~left ~right value =
  let left_length = String.length left in
  let right_length = String.length right in
  let value_length = String.length value in
  if value_length >= left_length + right_length
     && String.starts_with ~prefix:left value
     && String.ends_with ~suffix:right value
  then String.sub value left_length (value_length - left_length - right_length)
  else value
;;

let node_name (link : Mldoc.Nested_link.t) =
  strip_wrapped ~left:"[[" ~right:"]]" link.content |> String.trim
;;

let same_identity value (summary : Model.entity_summary) =
  String.equal value summary.uuid
  || String.equal (String.lowercase_ascii value) (String.lowercase_ascii summary.title)
;;

let find_summary summaries value = List.find_opt (same_identity value) summaries

let source_slice source = function
  | Some (position : Mldoc.Pos.pos_meta)
    when position.start_pos >= 0
         && position.end_pos >= position.start_pos
         && position.end_pos <= String.length source ->
    String.sub source position.start_pos (position.end_pos - position.start_pos)
  | Some _ | None -> ""
;;

let emphasis = function
  | `Bold -> Bold
  | `Italic -> Italic
  | `Underline -> Underline
  | `Strike_through -> Strike_through
  | `Highlight -> Highlight
;;

let append node nodes =
  match node, nodes with
  | Text "", _ -> nodes
  | Text text, Text previous :: rest -> Text (previous ^ text) :: rest
  | _ -> node :: nodes
;;

let last_path_component value =
  match
    value
    |> String.split_on_char '/'
    |> List.filter (fun part -> not (String.equal part ""))
    |> List.rev
  with
  | first :: _ -> Some first
  | [] -> None
;;

let youtube_url value =
  let value = String.trim value in
  if String.starts_with ~prefix:"http://" value
     || String.starts_with ~prefix:"https://" value
  then value
  else "https://www.youtube.com/watch?v=" ^ value
;;

let tweet_id value =
  let value = String.trim value in
  let without_query =
    match String.split_on_char '?' value with first :: _ -> Some first | [] -> None
  in
  match Option.bind without_query last_path_component with
  | Some id -> id
  | None -> value
;;

let rec convert_nodes ~source ~references ~tags nodes =
  List.fold_left
    (fun converted (node, position) ->
      convert_node ~source ~references ~tags node position
      |> List.fold_left (fun converted node -> append node converted) converted)
    []
    nodes
  |> List.rev

and convert_node ~source ~references ~tags node position =
  let raw () = [ Text (source_slice source position) ] in
  match node with
  | Inline.Plain value | Spaces value -> [ Text value ]
  | Break_Line | Hard_Break_Line -> [ Text "\n" ]
  | Code value | Verbatim value -> [ Code value ]
  | Latex_Fragment (Inline expression) -> [ Math { expression; display = false } ]
  | Latex_Fragment (Displayed expression) -> [ Math { expression; display = true } ]
  | Macro { name; arguments = url :: _ } when String.equal (String.lowercase_ascii name) "video" ->
    [ Video (String.trim url) ]
  | Macro { name; arguments = url :: _ } when String.equal (String.lowercase_ascii name) "iframe" ->
    [ Iframe (String.trim url) ]
  | Macro { name; arguments = value :: _ } when String.equal (String.lowercase_ascii name) "youtube" ->
    [ Video (youtube_url value) ]
  | Macro { name; arguments = value :: _ } when String.equal (String.lowercase_ascii name) "vimeo" ->
    [ Video ("https://player.vimeo.com/video/" ^ String.trim value) ]
  | Macro { name; arguments = value :: _ } when String.equal (String.lowercase_ascii name) "bilibili" ->
    [ Iframe ("https://player.bilibili.com/player.html?bvid=" ^ String.trim value) ]
  | Macro { name; arguments = value :: _ }
    when List.mem (String.lowercase_ascii name) [ "tweet"; "twitter" ] ->
    [ Iframe ("https://platform.twitter.com/embed/Tweet.html?id=" ^ tweet_id value) ]
  | Macro { name; arguments }
    when String.equal (String.lowercase_ascii name) "cloze" ->
    [ Cloze (String.concat ", " arguments |> String.trim) ]
  | Emphasis (style, children) ->
    [ Emphasis
        ( emphasis style
        , convert_nodes
            ~source
            ~references
            ~tags
            (List.map (fun child -> child, None) children) )
    ]
  | Nested_link link ->
    let value = node_name link in
    (match find_summary references value with
     | Some summary ->
       [ Node_ref { uuid = summary.uuid; title = summary.title } ]
     | None -> raw ())
  | Tag children ->
    let value =
      children
      |> List.map (function
        | Inline.Nested_link link -> node_name link
        | Link { url = Page_ref value; _ } -> value
        | Plain value | Spaces value -> value
        | child -> Inline.ascii child)
      |> String.concat ""
      |> String.trim
    in
    (match find_summary tags value with
     | Some summary -> [ Tag_ref { uuid = summary.uuid; title = summary.title } ]
     | None -> raw ())
  | Link link ->
    (match link.url with
     | Block_ref _ -> raw ()
     | Page_ref value ->
       (match find_summary references value with
        | Some summary ->
          [ Node_ref { uuid = summary.uuid; title = summary.title } ]
        | None -> raw ())
     | _ ->
       [ Link
           { url = Inline.string_of_url link.url
           ; children =
               convert_nodes
                 ~source
                 ~references
                 ~tags
                 (List.map (fun child -> child, None) link.label)
           }
       ])
  | _ -> raw ()
;;

let parse_inline ~references ~tags source =
  match Angstrom.parse_string ~consume:All (Inline.parse config) source with
  | Ok nodes -> convert_nodes ~source ~references ~tags nodes
  | Error _ -> [ Text source ]
;;

let fenced_code source =
  if not (String.starts_with ~prefix:"```" source && String.ends_with ~suffix:"```" source)
  then None
  else
    match String.index_opt source '\n' with
    | None -> None
    | Some newline ->
      let language =
        String.sub source 3 (newline - 3) |> String.trim |> function
        | "" -> None
        | value -> Some value
      in
      let code_length = String.length source - newline - 4 in
      if code_length < 0
      then None
      else Some (Code_block { language; code = String.sub source (newline + 1) code_length })
;;

let parse ~references ~tags source =
  if String.equal source ""
  then []
  else
    match fenced_code source with
    | Some node -> [ node ]
    | None when String.starts_with ~prefix:"$$" source && String.ends_with ~suffix:"$$" source ->
      [ Math
          { expression = strip_wrapped ~left:"$$" ~right:"$$" source
          ; display = true
          }
      ]
    | None when String.starts_with ~prefix:">" source ->
      let content = String.sub source 1 (String.length source - 1) |> String.trim in
      [ Quote (parse_inline ~references ~tags content) ]
    | None -> parse_inline ~references ~tags source
;;
