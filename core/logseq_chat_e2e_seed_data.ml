open Datascript

let tag_uuid = "e2e00000-0000-4000-8000-000000000001"
let source_uuid = "e2e00000-0000-4000-8000-000000000002"
let older_block_uuid = "e2e00000-0000-4000-8000-000000000003"
let trailing_tag_uuid = "e2e00000-0000-4000-8000-000000000004"

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
            ; "block/updated-at", One_value (Int (10_000 + number))
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
        }
    ])
  |> List.concat
;;

let seed conn =
  try
    let tag_class_temp_id = "e2e-tag-class" in
    let tag_temp_id = "e2e-tag" in
    let trailing_tag_temp_id = "e2e-trailing-tag" in
    let source_title =
      Printf.sprintf
        "E2E links [[%s]] [[%s]] #[[%s]] and ((plain text))"
        (page_uuid 7)
        (block_uuid 7)
        tag_uuid
    in
    let entities =
      journal_entities
      @ [ Entity
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
        ]
    in
    ignore (transact_conn conn entities);
    Ok ()
  with
  | error -> Error ("Seed iOS E2E graph: " ^ Printexc.to_string error)
;;
