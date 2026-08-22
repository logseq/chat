open Datascript

let tag_uuid = "e2e00000-0000-4000-8000-000000000001"
let source_uuid = "e2e00000-0000-4000-8000-000000000002"
let older_block_uuid = "e2e00000-0000-4000-8000-000000000003"
let trailing_tag_uuid = "e2e00000-0000-4000-8000-000000000004"
let child_tag_uuid = "e2e00000-0000-4000-8000-000000000005"
let flashcard_uuid = "e2e00000-0000-4000-8000-000000000020"
let flashcard_answer_uuid = "e2e00000-0000-4000-8000-000000000021"

let page_uuid index =
  Printf.sprintf "e2e10000-0000-4000-8000-%012d" index
;;

let block_uuid index =
  Printf.sprintf "e2e20000-0000-4000-8000-%012d" index
;;

let journal_entities =
  List.init 8 (fun index ->
    let number = index + 1 in
    let page_temp_id = "e2e-journal-" ^ string_of_int number in
    let page_title =
      if number = 7 then "E2E Page Target" else Printf.sprintf "E2E Journal %02d" number
    in
    let block_title =
      if number = 7 then "E2E Block Target"
      else if number = 1 then "E2E Earlier Journal Block"
      else if number = 6 then "E2E Child Tag Object"
      else Printf.sprintf "E2E Journal Block %02d" number
    in
    [ Entity
        { db_id = Some (Temp_id page_temp_id)
        ; attrs =
            [ "block/uuid", One_value (Uuid (page_uuid number))
            ; "block/name", One_value (String ("e2e-journal-" ^ string_of_int number))
            ; "block/title", One_value (String page_title)
            ; "block/journal-day", One_value (Int (20260809 + number))
            ; "block/created-at", One_value (Int (10_000 + number))
            ; ( "block/updated-at"
              , One_value (Int (if number = 8 then 2_000_000_000_001 else 10_000 + number)) )
            ]
        }
    ; Entity
        { db_id = Some (Temp_id ("e2e-block-" ^ string_of_int number))
        ; attrs =
            [ ( "block/uuid"
              , One_value
                  (Uuid (if number = 1 then older_block_uuid else block_uuid number)) )
            ; "block/title", One_value (String block_title)
            ; "block/page", One_value (Ref_to (Temp_id page_temp_id))
            ; "block/parent", One_value (Ref_to (Temp_id page_temp_id))
            ; "block/order", One_value (String "a0")
            ; "block/created-at", One_value (Int (20_000 + number))
            ; "block/updated-at", One_value (Int (20_000 + number))
            ]
            @ (if number = 6
               then [ "block/tags", Many_values [ Ref_to (Temp_id "e2e-child-tag") ] ]
               else [])
        }
    ])
  |> List.concat
;;

let rich_block_titles =
  [ "> E2E Rich Quote"
  ; "$$E = mc^2$$"
  ; "```swift\nlet answer = 42\n```"
  ; "{{video https://www.youtube.com/watch?v=dQw4w9WgXcQ}}"
  ; "{{iframe https://example.com}}"
  ; "E2E before {{video https://www.youtube.com/watch?v=dQw4w9WgXcQ}} E2E after"
  ; "{{youtube-timestamp 01:23}}"
  ]
;;

let rich_block_entities =
  List.mapi
    (fun index title ->
      Entity
        { db_id = Some (Temp_id ("e2e-rich-block-" ^ string_of_int index))
        ; attrs =
            [ "block/uuid", One_value (Uuid (block_uuid (100 + index)))
            ; "block/title", One_value (String title)
            ; "block/page", One_value (Ref_to (Temp_id "e2e-journal-8"))
            ; "block/parent", One_value (Ref_to (Temp_id "e2e-journal-8"))
            ; "block/order", One_value (String (Printf.sprintf "a%d" (index + 2)))
            ; "block/created-at", One_value (Int (30_000 + index))
            ; "block/updated-at", One_value (Int (30_000 + index))
            ]
        })
    rich_block_titles
;;

let seed conn =
  try
    let tag_class_temp_id = "e2e-tag-class" in
    let tag_temp_id = "e2e-tag" in
    let trailing_tag_temp_id = "e2e-trailing-tag" in
    let existing_favorites_page_eid =
      Datascript.datoms
        (conn_db conn)
        Aevt
        ~a:"block/name"
        ~v:(String "$$$favorites")
        ()
      |> Seq.uncons
      |> Option.map (fun (datom, _rest) -> datom.e)
    in
    let favorites_page_entities, favorites_page_reference =
      match existing_favorites_page_eid with
      | Some eid -> [], Ref eid
      | None ->
        ( [ Entity
              { db_id = Some (Temp_id "e2e-favorites-page")
              ; attrs =
                  [ "block/uuid", One_value (Uuid "e2e00000-0000-4000-8000-000000000010")
                  ; "block/name", One_value (String "$$$favorites")
                  ; "block/title", One_value (String "Favorites")
                  ]
              }
          ]
        , Ref_to (Temp_id "e2e-favorites-page") )
    in
    let source_title =
      Printf.sprintf
        "E2E links [[%s]] [[%s]] #[[%s]] and ((plain text))"
        (page_uuid 7)
        (block_uuid 7)
        tag_uuid
    in
    let entities =
      journal_entities
      @ rich_block_entities
      @ favorites_page_entities
      @ [ Entity
            { db_id = Some (Temp_id "e2e-favorite-page-target")
            ; attrs =
                [ "block/uuid", One_value (Uuid "e2e00000-0000-4000-8000-000000000011")
                ; "block/title", One_value (String "")
                ; "block/page", One_value favorites_page_reference
                ; "block/link", One_value (Ref_to (Temp_id "e2e-journal-7"))
                ; "block/order", One_value (String "a0")
                ]
            }
        ; Entity
            { db_id = Some (Temp_id tag_class_temp_id)
            ; attrs = [ "db/ident", One_value (Keyword "logseq.class/Tag") ]
            }
        ; Entity
            { db_id = Some (Temp_id tag_temp_id)
            ; attrs =
                [ "block/uuid", One_value (Uuid tag_uuid)
                ; "block/name", One_value (String "e2e-project")
                ; "block/title", One_value (String "E2E Project")
                ; "block/tags", Many_values [ Ref_to (Temp_id tag_class_temp_id) ]
                ]
            }
        ; Entity
            { db_id = Some (Temp_id trailing_tag_temp_id)
            ; attrs =
                [ "block/uuid", One_value (Uuid trailing_tag_uuid)
                ; "block/name", One_value (String "e2e-trailing")
                ; "block/title", One_value (String "E2E Trailing")
                ; "block/tags", Many_values [ Ref_to (Temp_id tag_class_temp_id) ]
                ]
            }
        ; Entity
            { db_id = Some (Temp_id "e2e-child-tag")
            ; attrs =
                [ "block/uuid", One_value (Uuid child_tag_uuid)
                ; "block/name", One_value (String "e2e-child-project")
                ; "block/title", One_value (String "E2E Child Project")
                ; "block/tags", Many_values [ Ref_to (Temp_id tag_class_temp_id) ]
                ; ( "logseq.property.class/extends"
                  , Many_values [ Ref_to (Temp_id tag_temp_id) ] )
                ]
            }
        ; Entity
            { db_id = None
            ; attrs =
                [ "block/uuid", One_value (Uuid source_uuid)
                ; "block/title", One_value (String source_title)
                ; "block/page", One_value (Ref_to (Temp_id "e2e-journal-8"))
                ; "block/parent", One_value (Ref_to (Temp_id "e2e-journal-8"))
                ; "block/order", One_value (String "a1")
                ; "block/created-at", One_value (Int 2_000_000_000_000)
                ; "block/updated-at", One_value (Int 2_000_000_000_000)
                ; ( "block/refs"
                  , Many_values
                      [ Ref_to (Temp_id "e2e-journal-7")
                      ; Ref_to (Temp_id "e2e-block-7")
                      ] )
                ; ( "block/tags"
                  , Many_values
                      [ Ref_to (Temp_id tag_temp_id)
                      ; Ref_to (Temp_id trailing_tag_temp_id)
                      ] )
                ]
            }
        ; Entity
            { db_id = None
            ; attrs =
                [ "block/uuid", One_value (Uuid "e2e00000-0000-4000-8000-000000000006")
                ; "block/title", One_value (String "E2E explicit tag page reference")
                ; "block/page", One_value (Ref_to (Temp_id "e2e-journal-8"))
                ; "block/parent", One_value (Ref_to (Temp_id "e2e-journal-8"))
                ; "block/order", One_value (String "a8")
                ; "block/created-at", One_value (Int 2_000_000_000_002)
                ; "block/updated-at", One_value (Int 2_000_000_000_002)
                ; "block/refs", Many_values [ Ref_to (Temp_id tag_temp_id) ]
                ]
            }
        ; Entity
            { db_id = Some (Temp_id "e2e-card-class")
            ; attrs = [ "db/ident", One_value (Keyword "logseq.class/Card") ]
            }
        ; Entity
            { db_id = Some (Temp_id "e2e-flashcard")
            ; attrs =
                [ "block/uuid", One_value (Uuid flashcard_uuid)
                ; ( "block/title"
                  , One_value (String "The capital of France is {{cloze Paris}}") )
                ; "block/page", One_value (Ref_to (Temp_id "e2e-journal-8"))
                ; "block/parent", One_value (Ref_to (Temp_id "e2e-journal-8"))
                ; "block/order", One_value (String "a9")
                ; "block/created-at", One_value (Int 40_000)
                ; "block/updated-at", One_value (Int 40_000)
                ; "block/tags", Many_values [ Ref_to (Temp_id "e2e-card-class") ]
                ]
            }
        ; Entity
            { db_id = None
            ; attrs =
                [ "block/uuid", One_value (Uuid flashcard_answer_uuid)
                ; "block/title", One_value (String "Paris is the answer")
                ; "block/page", One_value (Ref_to (Temp_id "e2e-journal-8"))
                ; "block/parent", One_value (Ref_to (Temp_id "e2e-flashcard"))
                ; "block/order", One_value (String "a0")
                ; "block/created-at", One_value (Int 40_001)
                ; "block/updated-at", One_value (Int 40_001)
                ]
            }
        ]
    in
    ignore (transact_conn conn entities);
    Ok ()
  with
  | error -> Error ("Seed iOS E2E graph: " ^ Printexc.to_string error)
;;
