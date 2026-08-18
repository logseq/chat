open Logseq_chat_pending_ops

let fail label = failwith label
let assert_bool label value = if not value then fail label

let assert_invalid label operation =
  match operation () with
  | _ -> fail (label ^ ": expected Invalid_argument")
  | exception Invalid_argument _ -> ()
;;

let move uuid = { uuid; page_uuid = "page"; parent_uuid = "parent"; order = "a0" }

let intents =
  [ Save_title { uuid = "block"; expected_title = "Old"; title = "New" }
  ; Set_property
      { uuid = "block"
      ; attr = "user.property/effort"
      ; expected = Some (Int_value 1)
      ; value = Some (Int_value 2)
      }
  ; Set_property
      { uuid = "block"; attr = "user.property/flag"; expected = None; value = None }
  ; Insert_block
      { uuid = "new"
      ; title = "New"
      ; page_uuid = "page"
      ; parent_uuid = "parent"
      ; order = "a1"
      ; created_at = 42
      }
  ; Move_block (move "block")
  ; Move_blocks { moves = [ move "first"; move "second" ] }
  ; Split_block
      { uuid = "block"
      ; expected_title = "Old"
      ; before = "O"
      ; after = "ld"
      ; new_uuid = "new"
      ; new_order = "a1"
      ; created_at = 42
      }
  ; Merge_backward
      { uuid = "source"
      ; expected_title = "Source"
      ; title = "Source"
      ; previous_uuid = "previous"
      ; expected_previous_title = "Previous"
      ; merged_title = Some "PreviousSource"
      }
  ; Merge_backward
      { uuid = "source"
      ; expected_title = "Source"
      ; title = "Source"
      ; previous_uuid = "previous"
      ; expected_previous_title = "Previous"
      ; merged_title = None
      }
  ; Delete_blocks { uuids = [ "first"; "second" ] }
  ; Create_tag { uuid = "tag"; title = "Project"; created_at = 42 }
  ]
;;

let () =
  List.iter
    (fun intent ->
      assert_bool "every pending intent survives JSON round-trip"
        (intent_of_json (intent_json intent) = intent))
    intents;
  assert_bool "every outliner intent maps to the expected server operation"
    (List.map outliner_op intents
     = [ "save-block"
       ; "save-block"
       ; "save-block"
       ; "insert-blocks"
       ; "move-blocks"
       ; "move-blocks"
       ; "split-block"
       ; "merge-blocks"
       ; "merge-blocks"
       ; "delete-blocks"
       ; "save-block"
       ])
;;

let () =
  let values =
    [ String_value "text"
    ; Int_value 42
    ; Bool_value true
    ; Ref_uuid "uuid"
    ; Ref_ident "db/ident"
    ]
  in
  List.iter
    (fun value ->
      assert_bool "every semantic value survives JSON round-trip"
        (semantic_value_of_json (semantic_value_json value) = value))
    values;
  assert_invalid "invalid semantic value"
    (fun () -> semantic_value_of_json (`String "invalid"));
  assert_bool "optional semantic values preserve null"
    (option_value semantic_value_of_json (option_json semantic_value_json None) = None);
  assert_bool "optional semantic values preserve values"
    (option_value semantic_value_of_json
       (option_json semantic_value_json (Some (String_value "value")))
     = Some (String_value "value"))
;;

let () =
  let states =
    [ Queued
    ; Submitted
    ; Accepted 42
    ; Retryable
    ; Applied
    ; Conflicted "changed"
    ]
  in
  List.iter
    (fun state ->
      assert_bool "every pending state survives storage round-trip"
        (state_of_string (state_string state) = state))
    states;
  assert_bool "legacy accepted state remains submitted" (state_of_string "accepted" = Submitted);
  assert_bool "invalid accepted cursor retries" (state_of_string "accepted:nope" = Retryable);
  assert_bool "unknown state retries" (state_of_string "unknown" = Retryable)
;;

let assoc fields = `Assoc fields

let () =
  assert_invalid "intent must be an object" (fun () -> intent_of_json (`String "invalid"));
  assert_invalid "intent type must be a string"
    (fun () -> intent_of_json (assoc [ "type", `Int 1 ]));
  assert_invalid "unknown intent"
    (fun () -> intent_of_json (assoc [ "type", `String "unknown" ]));
  assert_invalid "insert createdAt must be an integer"
    (fun () ->
      intent_of_json
        (assoc
           [ "type", `String "insert-block"
           ; "uuid", `String "new"
           ; "title", `String "New"
           ; "pageUuid", `String "page"
           ; "parentUuid", `String "page"
           ; "order", `String "a0"
           ; "createdAt", `String "invalid"
           ]));
  assert_invalid "move batch must be a list"
    (fun () -> intent_of_json (assoc [ "type", `String "move-blocks"; "moves", `Null ]));
  assert_invalid "move batch entries must be objects"
    (fun () ->
      intent_of_json
        (assoc [ "type", `String "move-blocks"; "moves", `List [ `Null ] ]));
  assert_invalid "split createdAt must be an integer"
    (fun () ->
      let fields =
        match intent_json (List.nth intents 6) with
        | `Assoc fields ->
          ("createdAt", `String "invalid") :: List.remove_assoc "createdAt" fields
        | _ -> assert false
      in
      intent_of_json (assoc fields));
  assert_invalid "merged title must be a string or null"
    (fun () ->
      let fields =
        match intent_json (List.nth intents 7) with
        | `Assoc fields ->
          ("mergedTitle", `Int 1) :: List.remove_assoc "mergedTitle" fields
        | _ -> assert false
      in
      intent_of_json (assoc fields));
  assert_bool "missing merged title remains compatible with older pending rows"
    (match intent_json (List.nth intents 7) with
     | `Assoc fields ->
       (match intent_of_json (assoc (List.remove_assoc "mergedTitle" fields)) with
        | Merge_backward { merged_title = None; _ } -> true
        | _ -> false)
     | _ -> false);
  assert_invalid "delete UUIDs must be a list"
    (fun () -> intent_of_json (assoc [ "type", `String "delete-blocks"; "uuids", `Null ]));
  assert_invalid "delete UUID entries must be strings"
    (fun () ->
      intent_of_json
        (assoc [ "type", `String "delete-blocks"; "uuids", `List [ `Int 1 ] ]))
;;
