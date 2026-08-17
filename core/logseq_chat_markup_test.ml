module Markup = Logseq_chat_markup
module Model = Logseq_chat_model

let summary uuid title = Model.{ uuid; title }

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
