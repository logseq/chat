open Yojson.Basic

type state =
  | Queued
  | Submitted
  | Accepted of int
  | Retryable
  | Applied
  | Conflicted of string

type semantic_value =
  | String_value of string
  | Int_value of int
  | Instant_value of int
  | Float_value of float
  | Bool_value of bool
  | Keyword_value of string
  | Map_value of (string * semantic_value) list
  | Ref_uuid of string
  | Ref_ident of string

type property_change =
  { attr : string
  ; expected : semantic_value option
  ; value : semantic_value option
  }

type move =
  { uuid : string
  ; page_uuid : string
  ; parent_uuid : string
  ; order : string
  }

type intent =
  | Save_title of
      { uuid : string
      ; expected_title : string
      ; title : string
      }
  | Set_property of
      { uuid : string
      ; attr : string
      ; expected : semantic_value option
      ; value : semantic_value option
      }
  | Set_properties of
      { uuid : string
      ; changes : property_change list
      }
  | Insert_block of
      { uuid : string
      ; title : string
      ; page_uuid : string
      ; parent_uuid : string
      ; order : string
      ; created_at : int
      }
  | Create_asset of
      { uuid : string
      ; title : string
      ; page_uuid : string
      ; parent_uuid : string
      ; order : string
      ; created_at : int
      ; asset_type : string
      ; asset_size : int
      ; asset_checksum : string
      }
  | Move_block of
      move
  | Move_blocks of { moves : move list }
  | Split_block of
      { uuid : string
      ; expected_title : string
      ; before : string
      ; after : string
      ; new_uuid : string
      ; new_order : string
      ; created_at : int
      }
  | Merge_backward of
      { uuid : string
      ; expected_title : string
      ; title : string
      ; previous_uuid : string
      ; expected_previous_title : string
      ; merged_title : string option
      }
  | Delete_blocks of { uuids : string list }
  | Create_tag of
      { uuid : string
      ; title : string
      ; created_at : int
      }
  | Create_journal of
      { page_uuid : string
      ; block_uuid : string
      ; title : string
      ; journal_day : int
      ; created_at : int
      }
  | Add_tag of
      { uuid : string
      ; tag_uuid : string
      }
  | Set_favorite of
      { page_uuid : string
      ; favorite_uuid : string
      ; favorite : bool
      ; order : string
      ; created_at : int
      }
  | Delete_page of
      { page_uuid : string
      ; order : string
      ; deleted_at : int
      }

type t =
  { operation_id : string
  ; base_t : int
  ; state : state
  ; intent : intent
  }

let outliner_op = function
  | Save_title _ | Set_property _ | Set_properties _ | Create_tag _ | Add_tag _ -> "save-block"
  | Insert_block _ | Create_asset _ | Create_journal _ -> "insert-blocks"
  | Set_favorite { favorite = true; _ } -> "insert-blocks"
  | Set_favorite { favorite = false; _ } -> "delete-blocks"
  | Move_block _ | Move_blocks _ -> "move-blocks"
  | Split_block _ -> "split-block"
  | Merge_backward _ -> "merge-blocks"
  | Delete_blocks _ -> "delete-blocks"
  | Delete_page _ -> "delete-page"
;;

external store_raw
  :  string
  -> string
  -> int
  -> string
  -> string
  -> unit
  = "logseq_chat_pending_ops_store"

external list_raw
  :  string
  -> (string * int * string * string) list
  = "logseq_chat_pending_ops_list"

external set_state_raw
  :  string
  -> string
  -> string
  -> unit
  = "logseq_chat_pending_ops_set_state"

external remove_raw : string -> string -> unit = "logseq_chat_pending_ops_remove"

let state_string = function
  | Queued -> "queued"
  | Submitted -> "submitted"
  | Accepted accepted_t -> "accepted:" ^ string_of_int accepted_t
  | Retryable -> "retryable"
  | Applied -> "applied"
  | Conflicted message -> "conflicted:" ^ message
;;

let state_of_string value =
  match value with
  | "queued" -> Queued
  | "submitted" -> Submitted
  | value when String.starts_with ~prefix:"accepted:" value ->
    (match int_of_string_opt (String.sub value 9 (String.length value - 9)) with
     | Some accepted_t -> Accepted accepted_t
     | None -> Retryable)
  | "accepted" -> Submitted
  | "retryable" -> Retryable
  | "applied" -> Applied
  | value when String.starts_with ~prefix:"conflicted:" value ->
    Conflicted (String.sub value 11 (String.length value - 11))
  | _ -> Retryable
;;

let rec semantic_value_json = function
  | String_value value -> `Assoc [ "type", `String "string"; "value", `String value ]
  | Int_value value -> `Assoc [ "type", `String "int"; "value", `Int value ]
  | Instant_value value -> `Assoc [ "type", `String "instant"; "value", `Int value ]
  | Float_value value -> `Assoc [ "type", `String "float"; "value", `Float value ]
  | Bool_value value -> `Assoc [ "type", `String "bool"; "value", `Bool value ]
  | Keyword_value value -> `Assoc [ "type", `String "keyword"; "value", `String value ]
  | Map_value entries ->
    `Assoc
      [ "type", `String "map"
      ; ( "value"
        , `List
            (List.map
               (fun (key, value) ->
                 `Assoc [ "key", `String key; "value", semantic_value_json value ])
               entries) )
      ]
  | Ref_uuid value -> `Assoc [ "type", `String "ref-uuid"; "value", `String value ]
  | Ref_ident value -> `Assoc [ "type", `String "ref-ident"; "value", `String value ]
;;

let rec semantic_value_of_json = function
  | `Assoc [ "type", `String "string"; "value", `String value ] -> String_value value
  | `Assoc [ "type", `String "int"; "value", `Int value ] -> Int_value value
  | `Assoc [ "type", `String "instant"; "value", `Int value ] -> Instant_value value
  | `Assoc [ "type", `String "float"; "value", `Float value ] -> Float_value value
  | `Assoc [ "type", `String "float"; "value", `Int value ] -> Float_value (Float.of_int value)
  | `Assoc [ "type", `String "bool"; "value", `Bool value ] -> Bool_value value
  | `Assoc [ "type", `String "keyword"; "value", `String value ] -> Keyword_value value
  | `Assoc [ "type", `String "map"; "value", `List entries ] ->
    Map_value
      (List.map
         (function
           | `Assoc [ "key", `String key; "value", value ] -> key, semantic_value_of_json value
           | _ -> invalid_arg "invalid pending semantic map entry")
         entries)
  | `Assoc [ "type", `String "ref-uuid"; "value", `String value ] -> Ref_uuid value
  | `Assoc [ "type", `String "ref-ident"; "value", `String value ] -> Ref_ident value
  | _ -> invalid_arg "invalid pending semantic value"
;;

let option_json f = function Some value -> f value | None -> `Null
let option_value f = function `Null -> None | value -> Some (f value)

let intent_json = function
  | Save_title { uuid; expected_title; title } ->
    `Assoc
      [ "type", `String "save-title"
      ; "uuid", `String uuid
      ; "expectedTitle", `String expected_title
      ; "title", `String title
      ]
  | Set_property { uuid; attr; expected; value } ->
    `Assoc
      [ "type", `String "set-property"
      ; "uuid", `String uuid
      ; "attr", `String attr
      ; "expected", option_json semantic_value_json expected
      ; "value", option_json semantic_value_json value
      ]
  | Set_properties { uuid; changes } ->
    `Assoc
      [ "type", `String "set-properties"
      ; "uuid", `String uuid
      ; ( "changes"
        , `List
            (List.map
               (fun { attr; expected; value } ->
                 `Assoc
                   [ "attr", `String attr
                   ; "expected", option_json semantic_value_json expected
                   ; "value", option_json semantic_value_json value
                   ])
               changes) )
      ]
  | Insert_block { uuid; title; page_uuid; parent_uuid; order; created_at } ->
    `Assoc
      [ "type", `String "insert-block"
      ; "uuid", `String uuid
      ; "title", `String title
      ; "pageUuid", `String page_uuid
      ; "parentUuid", `String parent_uuid
      ; "order", `String order
      ; "createdAt", `Int created_at
      ]
  | Create_asset
      { uuid; title; page_uuid; parent_uuid; order; created_at; asset_type;
        asset_size; asset_checksum }
    ->
    `Assoc
      [ "type", `String "create-asset"
      ; "uuid", `String uuid
      ; "title", `String title
      ; "pageUuid", `String page_uuid
      ; "parentUuid", `String parent_uuid
      ; "order", `String order
      ; "createdAt", `Int created_at
      ; "assetType", `String asset_type
      ; "assetSize", `Int asset_size
      ; "assetChecksum", `String asset_checksum
      ]
  | Move_block { uuid; page_uuid; parent_uuid; order } ->
    `Assoc
      [ "type", `String "move-block"
      ; "uuid", `String uuid
      ; "pageUuid", `String page_uuid
      ; "parentUuid", `String parent_uuid
      ; "order", `String order
      ]
  | Move_blocks { moves } ->
    `Assoc
      [ "type", `String "move-blocks"
      ; ( "moves"
        , `List
            (List.map
               (fun { uuid; page_uuid; parent_uuid; order } ->
                 `Assoc
                   [ "uuid", `String uuid
                   ; "pageUuid", `String page_uuid
                   ; "parentUuid", `String parent_uuid
                   ; "order", `String order
                   ])
               moves) )
      ]
  | Split_block { uuid; expected_title; before; after; new_uuid; new_order; created_at } ->
    `Assoc
      [ "type", `String "split-block"
      ; "uuid", `String uuid
      ; "expectedTitle", `String expected_title
      ; "before", `String before
      ; "after", `String after
      ; "newUuid", `String new_uuid
      ; "newOrder", `String new_order
      ; "createdAt", `Int created_at
      ]
  | Merge_backward
      { uuid; expected_title; title; previous_uuid; expected_previous_title; merged_title }
    ->
    `Assoc
      [ "type", `String "merge-backward"
      ; "uuid", `String uuid
      ; "expectedTitle", `String expected_title
      ; "title", `String title
      ; "previousUuid", `String previous_uuid
      ; "expectedPreviousTitle", `String expected_previous_title
      ; "mergedTitle", option_json (fun value -> `String value) merged_title
      ]
  | Delete_blocks { uuids } ->
    `Assoc [ "type", `String "delete-blocks"; "uuids", `List (List.map (fun uuid -> `String uuid) uuids) ]
  | Create_tag { uuid; title; created_at } ->
    `Assoc
      [ "type", `String "create-tag"
      ; "uuid", `String uuid
      ; "title", `String title
      ; "createdAt", `Int created_at
      ]
  | Create_journal { page_uuid; block_uuid; title; journal_day; created_at } ->
    `Assoc
      [ "type", `String "create-journal"
      ; "pageUuid", `String page_uuid
      ; "blockUuid", `String block_uuid
      ; "title", `String title
      ; "journalDay", `Int journal_day
      ; "createdAt", `Int created_at
      ]
  | Add_tag { uuid; tag_uuid } ->
    `Assoc
      [ "type", `String "add-tag"
      ; "uuid", `String uuid
      ; "tagUuid", `String tag_uuid
      ]
  | Set_favorite { page_uuid; favorite_uuid; favorite; order; created_at } ->
    `Assoc
      [ "type", `String "set-favorite"
      ; "pageUuid", `String page_uuid
      ; "favoriteUuid", `String favorite_uuid
      ; "favorite", `Bool favorite
      ; "order", `String order
      ; "createdAt", `Int created_at
      ]
  | Delete_page { page_uuid; order; deleted_at } ->
    `Assoc
      [ "type", `String "delete-page"
      ; "pageUuid", `String page_uuid
      ; "order", `String order
      ; "deletedAt", `Int deleted_at
      ]
;;

let string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> value
  | _ -> invalid_arg ("invalid pending intent field: " ^ name)
;;

let intent_of_json = function
  | `Assoc fields ->
    (match string fields "type" with
     | "save-title" ->
       Save_title
         { uuid = string fields "uuid"
         ; expected_title = string fields "expectedTitle"
         ; title = string fields "title"
         }
     | "set-property" ->
       Set_property
         { uuid = string fields "uuid"
         ; attr = string fields "attr"
         ; expected = option_value semantic_value_of_json (List.assoc "expected" fields)
         ; value = option_value semantic_value_of_json (List.assoc "value" fields)
         }
     | "set-properties" ->
       Set_properties
         { uuid = string fields "uuid"
         ; changes =
             (match List.assoc_opt "changes" fields with
              | Some (`List changes) ->
                List.map
                  (function
                    | `Assoc change_fields ->
                      { attr = string change_fields "attr"
                      ; expected =
                          option_value
                            semantic_value_of_json
                            (List.assoc "expected" change_fields)
                      ; value =
                          option_value
                            semantic_value_of_json
                            (List.assoc "value" change_fields)
                      }
                    | _ -> invalid_arg "invalid pending property change")
                  changes
              | _ -> invalid_arg "invalid pending intent field: changes")
         }
     | "insert-block" ->
       Insert_block
         { uuid = string fields "uuid"
         ; title = string fields "title"
         ; page_uuid = string fields "pageUuid"
         ; parent_uuid = string fields "parentUuid"
         ; order = string fields "order"
         ; created_at =
             (match List.assoc_opt "createdAt" fields with
              | Some (`Int value) -> value
              | _ -> (invalid_arg "invalid pending intent field: createdAt" [@coverage off]))
         }
     | "create-asset" ->
       Create_asset
         { uuid = string fields "uuid"
         ; title = string fields "title"
         ; page_uuid = string fields "pageUuid"
         ; parent_uuid = string fields "parentUuid"
         ; order = string fields "order"
         ; created_at =
             (match List.assoc_opt "createdAt" fields with
              | Some (`Int value) -> value
              | _ -> invalid_arg "invalid pending intent field: createdAt")
         ; asset_type = string fields "assetType"
         ; asset_size =
             (match List.assoc_opt "assetSize" fields with
              | Some (`Int value) -> value
              | _ -> invalid_arg "invalid pending intent field: assetSize")
         ; asset_checksum = string fields "assetChecksum"
         }
     | "move-block" ->
       Move_block
         { uuid = string fields "uuid"
         ; page_uuid = string fields "pageUuid"
         ; parent_uuid = string fields "parentUuid"
         ; order = string fields "order"
         }
     | "move-blocks" ->
       Move_blocks
         { moves =
             (match List.assoc_opt "moves" fields with
              | Some (`List moves) ->
                List.map
                  (function
                    | `Assoc move_fields ->
                      { uuid = string move_fields "uuid"
                      ; page_uuid = string move_fields "pageUuid"
                      ; parent_uuid = string move_fields "parentUuid"
                      ; order = string move_fields "order"
                      }
                    | _ -> (invalid_arg "invalid pending move" [@coverage off]))
                  moves
              | _ -> (invalid_arg "invalid pending intent field: moves" [@coverage off]))
         }
     | "split-block" ->
       Split_block
         { uuid = string fields "uuid"
         ; expected_title = string fields "expectedTitle"
         ; before = string fields "before"
         ; after = string fields "after"
         ; new_uuid = string fields "newUuid"
         ; new_order = string fields "newOrder"
         ; created_at =
             (match List.assoc_opt "createdAt" fields with
              | Some (`Int value) -> value
              | _ -> (invalid_arg "invalid pending intent field: createdAt" [@coverage off]))
         }
     | "merge-backward" ->
       Merge_backward
         { uuid = string fields "uuid"
         ; expected_title = string fields "expectedTitle"
         ; title = string fields "title"
         ; previous_uuid = string fields "previousUuid"
         ; expected_previous_title = string fields "expectedPreviousTitle"
         ; merged_title =
             (match List.assoc_opt "mergedTitle" fields with
              | Some (`String value) -> Some value
              | Some `Null | None -> None
              | Some _ ->
                (invalid_arg "invalid pending intent field: mergedTitle" [@coverage off]))
         }
     | "delete-blocks" ->
       Delete_blocks
         { uuids =
             (match List.assoc_opt "uuids" fields with
              | Some (`List values) ->
                List.map
                  (function
                    | `String value -> value
                    | _ -> (invalid_arg "invalid pending delete uuid" [@coverage off]))
                  values
              | _ -> (invalid_arg "invalid pending intent field: uuids" [@coverage off]))
         }
     | "create-tag" ->
       Create_tag
         { uuid = string fields "uuid"
         ; title = string fields "title"
         ; created_at =
             (match List.assoc_opt "createdAt" fields with
              | Some (`Int value) -> value
              | _ -> (invalid_arg "invalid pending intent field: createdAt" [@coverage off]))
         }
     | "create-journal" ->
       Create_journal
         { page_uuid = string fields "pageUuid"
         ; block_uuid = string fields "blockUuid"
         ; title = string fields "title"
         ; journal_day =
             (match List.assoc_opt "journalDay" fields with
              | Some (`Int value) -> value
              | _ -> invalid_arg "invalid pending intent field: journalDay")
         ; created_at =
             (match List.assoc_opt "createdAt" fields with
              | Some (`Int value) -> value
              | _ -> invalid_arg "invalid pending intent field: createdAt")
         }
     | "add-tag" ->
       Add_tag
         { uuid = string fields "uuid"
         ; tag_uuid = string fields "tagUuid"
         }
     | "set-favorite" ->
       Set_favorite
         { page_uuid = string fields "pageUuid"
         ; favorite_uuid = string fields "favoriteUuid"
         ; favorite =
             (match List.assoc_opt "favorite" fields with
              | Some (`Bool value) -> value
              | _ -> invalid_arg "invalid pending intent field: favorite")
         ; order = string fields "order"
         ; created_at =
             (match List.assoc_opt "createdAt" fields with
              | Some (`Int value) -> value
              | _ -> invalid_arg "invalid pending intent field: createdAt")
         }
     | "delete-page" ->
       Delete_page
         { page_uuid = string fields "pageUuid"
         ; order = string fields "order"
         ; deleted_at =
             (match List.assoc_opt "deletedAt" fields with
              | Some (`Int value) -> value
              | _ -> invalid_arg "invalid pending intent field: deletedAt")
         }
     | kind -> invalid_arg ("unknown pending intent: " ^ kind))
  | _ -> invalid_arg "pending intent must be an object"
;;

let save ~path operation =
  store_raw
    path
    operation.operation_id
    operation.base_t
    (state_string operation.state)
    (to_string (intent_json operation.intent))
;;

let list ~path =
  list_raw path
  |> List.map (fun (operation_id, base_t, state, intent) ->
    { operation_id
    ; base_t
    ; state = state_of_string state
    ; intent = intent_of_json (from_string intent)
    })
;;

let set_state ~path ~operation_id state =
  set_state_raw path operation_id (state_string state)
;;

let remove ~path ~operation_id = remove_raw path operation_id

let confirm ~path ~operation_ids =
  List.iter (fun operation_id -> remove ~path ~operation_id) operation_ids
