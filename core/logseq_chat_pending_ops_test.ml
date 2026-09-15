open Logseq_chat_pending_ops

let fail label = failwith label
let assert_bool label value = if not value then fail label

module LG = Logseq_chat_lg_core_native

let decode_outcome decode input =
  try Ok (decode input) with
  | Invalid_argument _ -> Error `Invalid
  | Not_found -> Error `Missing
;;

let intent_of_json input =
  let legacy = decode_outcome Logseq_chat_pending_ops.intent_of_json input in
  let migrated = decode_outcome LG.logseq_chat_pending_ops_intent_of_json input in
  match legacy, migrated with
  | Ok legacy, Ok migrated ->
    assert_bool "LG preserves canonical intent JSON"
      (intent_json legacy = LG.logseq_chat_pending_ops_intent_json migrated);
    legacy
  | Error `Invalid, Error `Invalid -> invalid_arg "invalid pending intent"
  | Error `Missing, Error `Missing -> raise Not_found
  | _ -> fail "LG and legacy intent decoders disagree"
;;

let semantic_value_of_json input =
  let legacy = decode_outcome Logseq_chat_pending_ops.semantic_value_of_json input in
  let migrated = decode_outcome LG.logseq_chat_pending_ops_semantic_value_of_json input in
  match legacy, migrated with
  | Ok legacy, Ok migrated ->
    assert_bool "LG preserves canonical semantic JSON"
      (semantic_value_json legacy = LG.logseq_chat_pending_ops_semantic_value_json migrated);
    legacy
  | Error `Invalid, Error `Invalid -> invalid_arg "invalid semantic value"
  | _ -> fail "LG and legacy semantic decoders disagree"
;;

let state_of_string input =
  let legacy = Logseq_chat_pending_ops.state_of_string input in
  assert_bool "LG preserves persisted state normalization"
    (state_string legacy =
     LG.logseq_chat_pending_ops_state_string
       (LG.logseq_chat_pending_ops_state_of_string input));
  legacy
;;

let assert_invalid label operation =
  match operation () with
  | _ -> fail (label ^ ": expected Invalid_argument")
  | exception Invalid_argument _ -> ()
;;

let move uuid = { uuid; page_uuid = "page"; parent_uuid = "parent"; order = "a0" }

let assert_lg_intent intent =
  let module LG = Logseq_chat_lg_core_native in
  let encoded = intent_json intent in
  let decoded = LG.logseq_chat_pending_ops_intent_of_json encoded in
  assert_bool "LG preserves the exact persisted intent encoding"
    (LG.logseq_chat_pending_ops_intent_json decoded = encoded);
  assert_bool "LG preserves server operation names"
    (LG.logseq_chat_pending_ops_outliner_op decoded = outliner_op intent)
;;

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
  ; Set_properties
      { uuid = "block"
      ; changes =
          [ { attr = "logseq.property.fsrs/due"
            ; expected = None
            ; value = Some (Int_value 86_400_000)
            }
          ; { attr = "logseq.property.fsrs/state"
            ; expected = None
            ; value =
                Some
                  (Map_value
                     [ "state", Keyword_value "learning"
                     ; "stability", Float_value 0.4
                     ; "reps", Int_value 1
                     ])
            }
          ]
      }
  ; Insert_block
      { uuid = "new"
      ; title = "New"
      ; page_uuid = "page"
      ; parent_uuid = "parent"
      ; order = "a1"
      ; created_at = 42
      }
  ; Create_asset
      { uuid = "asset"
      ; title = "photo.png"
      ; page_uuid = "page"
      ; parent_uuid = "parent"
      ; order = "a2"
      ; created_at = 43
      ; asset_type = "png"
      ; asset_size = 2048
      ; asset_checksum = "abc123"
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
      assert_lg_intent intent;
      assert_bool "every pending intent survives JSON round-trip"
        (intent_of_json (intent_json intent) = intent))
    intents;
  assert_bool "every outliner intent maps to the expected server operation"
    (List.map outliner_op intents
     = [ "save-block"
       ; "save-block"
       ; "save-block"
       ; "save-block"
       ; "insert-blocks"
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
    ; Instant_value 1_776_000_000_000
    ; Bool_value true
    ; Ref_uuid "uuid"
    ; Ref_ident "db/ident"
    ; Float_value 0.4
    ; Keyword_value "learning"
    ; Map_value
        [ "state", Keyword_value "learning"
        ; "stability", Float_value 0.4
        ; "nested", Map_value [ "reps", Int_value 1 ]
        ; "last-repeat", Instant_value 1_776_000_000_000
        ]
    ; Map_value [ "duplicate", Int_value 1; "duplicate", Int_value 2 ]
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

let () =
  List.iter (fun value -> ignore (state_of_string value))
    [ ""; "accepted:"; "accepted:-1"; "accepted:0x2a"; "accepted:1_000"
    ; "accepted:99999999999999999999999"; "conflicted:"; "conflicted:one:two" ];
  List.iter
    (fun input -> assert_invalid "invalid semantic shape" (fun () -> semantic_value_of_json input))
    [ `Assoc [ "value", `Int 1; "type", `String "int" ]
    ; `Assoc [ "type", `String "int"; "value", `Int 1; "extra", `Null ]
    ; `Assoc [ "type", `String "map"; "value", `List [ `Null ] ]
    ];
  assert_bool "integer JSON remains accepted for float semantic values"
    (semantic_value_of_json (`Assoc [ "type", `String "float"; "value", `Int 1 ])
     = Float_value 1.)
;;

let assoc fields = `Assoc fields

let () =
  List.iter
    (fun fields ->
      match intent_of_json (assoc fields) with
      | _ -> fail "missing semantic fields must retain Not_found"
      | exception Not_found -> ())
    [ [ "type", `String "set-property"; "uuid", `String "block"; "attr", `String "flag" ]
    ; [ "type", `String "set-property"; "uuid", `String "block"; "attr", `String "flag"
      ; "expected", `Null ]
    ];
  assert_lg_intent
    (Save_title { uuid = "duplicate"; expected_title = ""; title = "first" });
  assert_bool "duplicate intent fields still select the first value"
    (intent_of_json
       (assoc [ "type", `String "save-title"; "uuid", `String "duplicate"
              ; "expectedTitle", `String ""; "title", `String "first"; "title", `String "second" ])
     = Save_title { uuid = "duplicate"; expected_title = ""; title = "first" })
;;

let () =
  let cases =
    [ (Create_page { uuid = "page"; title = "Page"; created_at = 42 }, "save-block")
    ; (Create_journal
         { page_uuid = "page"; block_uuid = "block"; title = "Journal"
         ; journal_day = 20260915; created_at = 43 }, "insert-blocks")
    ; (Add_tag { uuid = "block"; tag_uuid = "tag" }, "save-block")
    ; (Set_favorite
         { page_uuid = "page"; favorite_uuid = "favorite"; favorite = true
         ; order = "a0"; created_at = 44 }, "insert-blocks")
    ; (Set_favorite
         { page_uuid = "page"; favorite_uuid = "favorite"; favorite = false
         ; order = "a0"; created_at = 44 }, "delete-blocks")
    ; (Delete_page { page_uuid = "page"; order = "a0"; deleted_at = 45 }, "delete-page")
    ]
  in
  List.iter
    (fun (intent, expected_op) ->
      assert_lg_intent intent;
      assert_bool "page and journal intents preserve their persisted form"
        (intent_of_json (intent_json intent) = intent);
      assert_bool "page and journal intents preserve the server operation"
        (outliner_op intent = expected_op))
    cases
;;

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
        match intent_json (List.nth intents 8) with
        | `Assoc fields ->
          ("createdAt", `String "invalid") :: List.remove_assoc "createdAt" fields
        | _ -> assert false
      in
      intent_of_json (assoc fields));
  assert_invalid "merged title must be a string or null"
    (fun () ->
      let fields =
        match intent_json (List.nth intents 9) with
        | `Assoc fields ->
          ("mergedTitle", `Int 1) :: List.remove_assoc "mergedTitle" fields
        | _ -> assert false
      in
      intent_of_json (assoc fields));
  assert_bool "missing merged title remains compatible with older pending rows"
    (match intent_json (List.nth intents 9) with
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
