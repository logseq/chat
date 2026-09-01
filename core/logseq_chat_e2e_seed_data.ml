open Datascript

let tag_uuid = "e2e00000-0000-4000-8000-000000000001"
let source_uuid = "e2e00000-0000-4000-8000-000000000002"
let older_block_uuid = "e2e00000-0000-4000-8000-000000000003"
let trailing_tag_uuid = "e2e00000-0000-4000-8000-000000000004"
let child_tag_uuid = "e2e00000-0000-4000-8000-000000000005"
let flashcard_uuid = "e2e00000-0000-4000-8000-000000000020"
let flashcard_answer_uuid = "e2e00000-0000-4000-8000-000000000021"
let header_navigation_page_uuid = "e2e00000-0000-4000-8000-000000000030"
let header_navigation_block_uuid = "e2e00000-0000-4000-8000-000000000031"
let composer_page_uuid = "e2e30000-0000-4000-8000-000000000001"
let composer_block_uuid = "e2e30000-0000-4000-8000-000000000002"
let outliner_page_uuid = "e2e30000-0000-4000-8000-000000000003"
let outliner_block_uuid = "e2e30000-0000-4000-8000-000000000004"
let outliner_tag_uuid = "e2e30000-0000-4000-8000-000000000005"

let entity_has_attr db eid attr =
  Datascript.datoms db Eavt ~e:eid ~a:attr () |> Seq.uncons |> Option.is_some
;;

let entity_is_built_in db eid =
  Datascript.datoms db Eavt ~e:eid ~a:"logseq.property/built-in?" ()
  |> Seq.exists (fun datom -> datom.v = Bool true)
;;

let reset_user_page_entities conn =
  let db = conn_db conn in
  let operations =
    Datascript.datoms db Aevt ~a:"block/uuid" ()
    |> Seq.filter_map (fun datom ->
      let is_composer_content =
        entity_has_attr db datom.e "block/journal-day"
        || entity_has_attr db datom.e "block/page"
      in
      if is_composer_content && not (entity_is_built_in db datom.e)
      then Some (RetractEntity (Entity_id datom.e))
      else None)
    |> List.of_seq
  in
  if not (List.is_empty operations) then ignore (transact_conn conn operations)
;;

let seed_current_journal conn ~now ~page_uuid ~block_uuid ~block_title =
  let journal_day = Logseq_chat_model.journal_day_for_ms now in
  let journal_title = Logseq_chat_graph_runtime.journal_day_title journal_day in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "e2e-current-page")
           ; attrs =
               [ "block/uuid", One_value (Uuid page_uuid)
               ; "block/name", One_value (String (String.lowercase_ascii journal_title))
               ; "block/title", One_value (String journal_title)
               ; "block/journal-day", One_value (Int journal_day)
               ; "block/created-at", One_value (Int now)
               ; "block/updated-at", One_value (Int now)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid block_uuid)
               ; "block/title", One_value (String block_title)
               ; "block/page", One_value (Ref_to (Temp_id "e2e-current-page"))
               ; "block/parent", One_value (Ref_to (Temp_id "e2e-current-page"))
               ; "block/order", One_value (String "a0")
               ; "block/created-at", One_value (Int now)
               ; "block/updated-at", One_value (Int now)
               ]
           }
       ])
;;

let seed_composer conn ~now =
  try
    reset_user_page_entities conn;
    seed_current_journal
      conn
      ~now
      ~page_uuid:composer_page_uuid
      ~block_uuid:composer_block_uuid
      ~block_title:"E2E Composer Fixture";
    Ok ()
  with
  | error -> Error ("Seed iOS composer graph: " ^ Printexc.to_string error)
;;

let page_uuid index =
  Printf.sprintf "e2e10000-0000-4000-8000-%012d" index
;;

let block_uuid index =
  Printf.sprintf "e2e20000-0000-4000-8000-%012d" index
;;

let seed_header_navigation conn =
  try
    ignore
      (transact_conn
         conn
         [ Entity
             { db_id = Some (Temp_id "e2e-header-navigation-page")
             ; attrs =
                 [ "block/uuid", One_value (Uuid header_navigation_page_uuid)
                 ; "block/name", One_value (String "aug 24th, 2026")
                 ; "block/title", One_value (String "Aug 24th, 2026")
                 ; "block/journal-day", One_value (Int 20260824)
                 ; "block/created-at", One_value (Int 50_000)
                 ; "block/updated-at", One_value (Int 50_000)
                 ]
             }
         ; Entity
             { db_id = None
             ; attrs =
                 [ "block/uuid", One_value (Uuid header_navigation_block_uuid)
                 ; "block/title", One_value (String "E2E Header Navigation")
                 ; "block/page", One_value (Ref_to (Temp_id "e2e-header-navigation-page"))
                 ; "block/parent", One_value (Ref_to (Temp_id "e2e-header-navigation-page"))
                 ; "block/order", One_value (String "a0")
                 ; "block/created-at", One_value (Int 50_001)
                 ; "block/updated-at", One_value (Int 50_001)
                 ]
             }
         ]);
    Ok ()
  with
  | error -> Error ("Seed iOS header-navigation graph: " ^ Printexc.to_string error)
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

let seed_outliner conn ~now =
  try
    reset_user_page_entities conn;
    seed_current_journal
      conn
      ~now
      ~page_uuid:outliner_page_uuid
      ~block_uuid:outliner_block_uuid
      ~block_title:"E2E Outliner Fixture";
    ignore
      (transact_conn
         conn
         [ Entity
             { db_id = Some (Temp_id "e2e-outliner-tag-class")
             ; attrs = [ "db/ident", One_value (Keyword "logseq.class/Tag") ]
             }
         ; Entity
             { db_id = None
             ; attrs =
                 [ "block/uuid", One_value (Uuid outliner_tag_uuid)
                 ; "block/name", One_value (String "e2e-outliner-tag")
                 ; "block/title", One_value (String "E2E Outliner Tag")
                 ; ( "block/tags"
                   , Many_values [ Ref_to (Temp_id "e2e-outliner-tag-class") ] )
                 ]
             }
         ]);
    Ok ()
  with
  | error -> Error ("Seed iOS outliner graph: " ^ Printexc.to_string error)
;;

let seed_fixture conn =
  reset_user_page_entities conn;
  seed conn
;;

let performance_page_uuid index =
  Printf.sprintf "e2f10000-0000-4000-8000-%012x" (index + 1)
;;

let performance_block_uuid page_index block_index =
  Printf.sprintf
    "e2f20000-0000-4000-8000-%012x"
    (((page_index + 1) * 100) + block_index + 1)
;;

let performance_block_title page_index block_index =
  let row = Printf.sprintf "%03d-%02d" (page_index + 1) (block_index + 1) in
  match block_index mod 4 with
  | 0 -> Printf.sprintf "Performance row %s with **bold text** and `inline code`" row
  | 1 -> Printf.sprintf "> Performance quote %s with enough text to exercise wrapping" row
  | 2 -> Printf.sprintf "$$x_%d + y_%d = z_%d$$" page_index block_index (page_index + block_index)
  | _ -> Printf.sprintf "```swift\nlet performanceRow = \"%s\"\n```" row
;;

let seed_performance conn ~now =
  try
    reset_user_page_entities conn;
    let entities =
      List.init 100 (fun page_index ->
        let page_temp_id = "performance-page-" ^ string_of_int page_index in
        let page_time = now - (page_index * 86_400_000) in
        let journal_day = Logseq_chat_model.journal_day_for_ms page_time in
        let journal_title = Logseq_chat_graph_runtime.journal_day_title journal_day in
        let page =
          Entity
            { db_id = Some (Temp_id page_temp_id)
            ; attrs =
                [ "block/uuid", One_value (Uuid (performance_page_uuid page_index))
                ; "block/name", One_value (String (String.lowercase_ascii journal_title))
                ; "block/title", One_value (String journal_title)
                ; "block/journal-day", One_value (Int journal_day)
                ; "block/created-at", One_value (Int page_time)
                ; "block/updated-at", One_value (Int page_time)
                ]
            }
        in
        let blocks =
          List.init 8 (fun block_index ->
            Entity
              { db_id = None
              ; attrs =
                  [ ( "block/uuid"
                    , One_value
                        (Uuid (performance_block_uuid page_index block_index)) )
                  ; ( "block/title"
                    , One_value
                        (String (performance_block_title page_index block_index)) )
                  ; "block/page", One_value (Ref_to (Temp_id page_temp_id))
                  ; "block/parent", One_value (Ref_to (Temp_id page_temp_id))
                  ; "block/order", One_value (String (Printf.sprintf "a%02d" block_index))
                  ; "block/created-at", One_value (Int (page_time + block_index + 1))
                  ; "block/updated-at", One_value (Int (page_time + block_index + 1))
                  ]
              })
        in
        page :: blocks)
      |> List.concat
    in
    ignore (transact_conn conn entities);
    Ok ()
  with
  | error -> Error ("Seed iOS performance graph: " ^ Printexc.to_string error)
;;
