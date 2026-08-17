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
  ; kind : string
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
  | Link of
      { url : string
      ; children : t list
      }
  | Node_ref of node_target
  | Tag_ref of tag_target

let rec debug_string = function
  | Text value -> Printf.sprintf "Text(%S)" value
  | Code value -> Printf.sprintf "Code(%S)" value
  | Node_ref target ->
    Printf.sprintf "Node(%S,%S,%S)" target.uuid target.kind target.title
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
      ; "kind", `String target.kind
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
       [ Node_ref { uuid = summary.uuid; kind = summary.kind; title = summary.title } ]
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
          [ Node_ref { uuid = summary.uuid; kind = summary.kind; title = summary.title } ]
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

let parse ~references ~tags source =
  if String.equal source ""
  then []
  else
    match Angstrom.parse_string ~consume:All (Inline.parse config) source with
    | Ok nodes -> convert_nodes ~source ~references ~tags nodes
    | Error _ -> [ Text source ]
;;
