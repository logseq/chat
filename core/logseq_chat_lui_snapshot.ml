type sidebar_page =
  { uuid : string
  ; title : string
  }

type search_hit =
  { uuid : string
  ; title : string
  ; breadcrumb : string
  ; breadcrumbs : sidebar_page list
  ; is_page : bool
  }

type graph =
  { id : string
  ; name : string
  ; is_encrypted : bool
  ; is_ready : bool
  }

type task_status =
  { uuid : string
  ; ident : string option
  ; title : string
  ; icon_type : string option
  ; icon_id : string option
  ; icon_color : string option
  }

type flashcard_answer =
  { uuid : string
  ; text : string
  }

type flashcard =
  { uuid : string
  ; question_hidden : string
  ; question_revealed : string
  ; answer_rows : flashcard_answer list
  ; has_cloze : bool
  }

type outline_row =
  { uuid : string
  ; title : string
  ; markup_json : string
  ; youtube_target_url : string option
  ; breadcrumb : string
  ; breadcrumbs : sidebar_page list
  ; opens_as_page : bool
  ; depth : int
  ; has_children : bool
  ; is_collapsed : bool
  ; is_asset : bool
  ; asset_type : string option
  ; local_path : string option
  ; status : task_status option
  ; tags : sidebar_page list
  ; sync_status : string option
  ; page_id : string
  ; journal_title : string option
  ; journal_day : int option
  }

type outliner_editing =
  { uuid : string
  ; title : string
  ; caret_utf16_offset : int
  }

type outliner_autocomplete_kind =
  | Node
  | Tag
  | Property

type outliner_autocomplete =
  { kind : outliner_autocomplete_kind
  ; query : string
  }

type outliner_autocomplete_candidate =
  { label : string
  ; value : string
  }

type node_route =
  { uuid : string
  ; page_uuid : string
  ; title : string
  ; is_tag : bool
  ; is_property : bool
  ; outliner_rows : outline_row list
  ; related_rows : outline_row list
  ; linked_reference_rows : outline_row list
  ; outliner_editing : outliner_editing option
  ; outliner_autocomplete : outliner_autocomplete option
  ; outliner_autocomplete_candidates : outliner_autocomplete_candidate list
  ; outliner_selected_block_ids : string list
  }

type outliner_row_splice =
  { start : int option
  ; after_block_id : string option
  ; before_block_id : string option
  ; delete_count : int
  ; rows : outline_row list
  }

type t =
  { graph_name : string option
  ; selected_graph_id : string option
  ; graphs : graph list
  ; is_graph_encrypted : bool
  ; is_graph_unlocked : bool
  ; favorites : sidebar_page list
  ; recent_pages : sidebar_page list
  ; selected_page : sidebar_page option
  ; selected_page_is_tag : bool
  ; selected_page_is_property : bool
  ; related_rows : outline_row list
  ; linked_reference_rows : outline_row list
  ; task_statuses : task_status list
  ; flashcards : flashcard list
  ; search_query : string
  ; search_results : search_hit list
  ; node_routes : node_route list
  ; journal_outliner_rows : outline_row list
  ; outliner_rows : outline_row list
  ; outliner_row_splices : outliner_row_splice list
  ; outliner_editing : outliner_editing option
  ; outliner_autocomplete : outliner_autocomplete option
  ; outliner_autocomplete_candidates : outliner_autocomplete_candidate list
  ; outliner_selected_block_ids : string list
  ; has_older_journals : bool
  ; is_outliner_patch : bool
  ; sync_connected : bool
  ; applied_server_t : int option
  ; has_pending_semantic_operations : bool
  ; has_pending_sync_request : bool
  ; is_pending_sync_patch : bool
  }

let member name fields = List.assoc_opt name fields

let string_member name fields =
  match member name fields with
  | Some (`String value) -> Some value
  | _ -> None
;;

let bool_member name fields =
  match member name fields with
  | Some (`Bool value) -> value
  | _ -> false
;;

let int_member name fields =
  match member name fields with
  | Some (`Int value) -> Some value
  | _ -> None
;;

let sidebar_page = function
  | `Assoc fields ->
    (match string_member "uuid" fields, string_member "title" fields with
     | Some uuid, Some title -> Some { uuid; title }
     | _ -> None)
  | _ -> None
;;

let breadcrumbs fields =
  match member "breadcrumbs" fields with
  | Some (`List values) -> List.filter_map sidebar_page values
  | _ -> []
;;

let breadcrumb fields =
  let titles =
    List.map (fun (summary : sidebar_page) -> summary.title) (breadcrumbs fields)
  in
  match titles with
  | _ :: _ -> String.concat " › " titles
  | [] ->
    (match member "page" fields with
     | Some (`Assoc page_fields) -> Option.value ~default:"" (string_member "title" page_fields)
     | _ -> "")
;;

let search_hit = function
  | `Assoc fields ->
    (match string_member "uuid" fields, string_member "title" fields with
     | Some uuid, Some title ->
       Some
         { uuid
         ; title
         ; breadcrumb = breadcrumb fields
         ; breadcrumbs = breadcrumbs fields
         ; is_page = bool_member "isPage" fields
         }
     | _ -> None)
  | _ -> None
;;

let graph = function
  | `Assoc fields ->
    (match string_member "id" fields, string_member "name" fields with
     | Some id, Some name ->
       Some
         { id
         ; name
         ; is_encrypted = bool_member "isEncrypted" fields
         ; is_ready = bool_member "isReady" fields
         }
     | _ -> None)
  | _ -> None
;;

let task_status = function
  | `Assoc fields ->
    (match string_member "uuid" fields, string_member "title" fields with
     | Some uuid, Some title ->
       let icon_fields =
         match member "icon" fields with
         | Some (`Assoc values) -> values
         | _ -> []
       in
       Some
         { uuid
         ; ident = string_member "ident" fields
         ; title
         ; icon_type = string_member "type" icon_fields
         ; icon_id = string_member "id" icon_fields
         ; icon_color = string_member "color" icon_fields
         }
     | _ -> None)
  | _ -> None
;;

let markup_children fields =
  match member "children" fields with
  | Some (`List values) -> values
  | _ -> []
;;

let rec markup_text ~reveal_cloze = function
  | `Assoc fields ->
    let children =
      markup_children fields
      |> List.map (markup_text ~reveal_cloze)
      |> String.concat ""
    in
    (match string_member "type" fields with
     | Some "cloze" ->
       if reveal_cloze
       then Option.value ~default:"" (string_member "text" fields)
       else "[…]"
     | Some "nodeReference" -> Option.value ~default:"" (string_member "title" fields)
     | Some "tagReference" ->
       "#" ^ Option.value ~default:"" (string_member "title" fields)
     | Some "link" when not (String.equal children "") -> children
     | Some "link" | Some "video" | Some "iframe" ->
       Option.value ~default:"" (string_member "url" fields)
     | Some "emphasis" | Some "quote" -> children
     | _ -> Option.value ~default:children (string_member "text" fields))
  | _ -> ""
;;

let rec markup_has_cloze = function
  | `Assoc fields ->
    Option.equal String.equal (string_member "type" fields) (Some "cloze")
    || List.exists markup_has_cloze (markup_children fields)
  | _ -> false
;;

let find_substring value pattern start =
  let value_length = String.length value in
  let pattern_length = String.length pattern in
  let rec loop index =
    if index + pattern_length > value_length
    then None
    else if String.equal (String.sub value index pattern_length) pattern
    then Some index
    else loop (index + 1)
  in
  loop start
;;

let legacy_cloze_text ~reveal value =
  let prefix = "cloze " in
  let buffer = Buffer.create (String.length value) in
  let rec loop offset has_cloze =
    match find_substring value "{{" offset with
    | None ->
      Buffer.add_substring buffer value offset (String.length value - offset);
      Buffer.contents buffer, has_cloze
    | Some opening ->
      Buffer.add_substring buffer value offset (opening - offset);
      (match find_substring value "}}" (opening + 2) with
       | None ->
         Buffer.add_substring buffer value opening (String.length value - opening);
         Buffer.contents buffer, has_cloze
       | Some closing ->
         let body = String.sub value (opening + 2) (closing - opening - 2) in
         let lowercase = String.lowercase_ascii body in
         if String.length lowercase >= String.length prefix
            && String.equal (String.sub lowercase 0 (String.length prefix)) prefix
         then (
           let answer =
             String.sub body (String.length prefix) (String.length body - String.length prefix)
             |> String.trim
           in
           Buffer.add_string buffer (if reveal then answer else "[…]");
           loop (closing + 2) true)
         else (
           Buffer.add_substring buffer value opening (closing + 2 - opening);
           loop (closing + 2) has_cloze))
  in
  loop 0 false
;;

let block_markup_text ~reveal_cloze fields =
  match member "markup" fields with
  | Some (`List (_ :: _ as values)) ->
    values |> List.map (markup_text ~reveal_cloze) |> String.concat ""
  | _ ->
    Option.value ~default:"" (string_member "title" fields)
    |> legacy_cloze_text ~reveal:reveal_cloze
    |> fst
;;

let flashcard_answer = function
  | `Assoc fields ->
    Option.map
      (fun uuid -> { uuid; text = block_markup_text ~reveal_cloze:true fields })
      (string_member "uuid" fields)
  | _ -> None
;;

let flashcard = function
  | `Assoc fields ->
    (match member "block" fields with
     | Some (`Assoc block_fields) ->
       Option.map
         (fun uuid ->
            let markup =
              match member "markup" block_fields with
              | Some (`List values) -> values
              | _ -> []
            in
            let answer_rows =
              match member "children" fields with
              | Some (`List values) -> List.filter_map flashcard_answer values
              | _ -> []
            in
            { uuid
            ; question_hidden = block_markup_text ~reveal_cloze:false block_fields
            ; question_revealed = block_markup_text ~reveal_cloze:true block_fields
            ; answer_rows
            ; has_cloze =
                (List.exists markup_has_cloze markup
                 || (Option.value ~default:"" (string_member "title" block_fields)
                     |> legacy_cloze_text ~reveal:false
                     |> snd))
            })
         (string_member "uuid" block_fields)
     | _ -> None)
  | _ -> None
;;

let outline_row_from_block
      ?youtube_target_url
      ?(opens_as_page = false)
      ~depth
      ~has_children
      ~is_collapsed
      block_fields
  =
  match string_member "uuid" block_fields, string_member "title" block_fields with
  | Some uuid, Some title ->
    Some
      { uuid
      ; title
      ; markup_json =
          (match member "markup" block_fields with
           | Some markup -> Yojson.Basic.to_string markup
           | None -> "[]")
      ; youtube_target_url
      ; breadcrumb = breadcrumb block_fields
      ; breadcrumbs = breadcrumbs block_fields
      ; opens_as_page
      ; depth
      ; has_children
      ; is_collapsed
      ; is_asset = bool_member "isAsset" block_fields
      ; asset_type = string_member "assetType" block_fields
      ; local_path = string_member "localPath" block_fields
      ; status = Option.bind (member "status" block_fields) task_status
      ; tags =
          (match member "tags" block_fields with
           | Some (`List values) -> List.filter_map sidebar_page values
           | _ -> [])
      ; sync_status = string_member "syncStatus" block_fields
      ; page_id = Option.value ~default:"" (string_member "pageId" block_fields)
      ; journal_title = string_member "journalTitle" block_fields
      ; journal_day = int_member "journalDay" block_fields
      }
  | _ -> None
;;

let outline_row = function
  | `Assoc fields ->
    (match member "block" fields, int_member "depth" fields with
     | Some (`Assoc block_fields), Some depth ->
       outline_row_from_block
         ?youtube_target_url:(string_member "youtubeTargetURL" fields)
         ~depth
         ~has_children:(bool_member "hasChildren" fields)
         ~is_collapsed:(bool_member "isCollapsed" fields)
         block_fields
     | _ -> None)
  | _ -> None
;;

let related_row = function
  | `Assoc block_fields ->
    let opens_as_page =
      match string_member "uuid" block_fields, string_member "pageId" block_fields with
      | Some uuid, Some page_id -> String.equal uuid page_id
      | _ -> false
    in
    outline_row_from_block
      ?youtube_target_url:(string_member "youtubeTargetURL" block_fields)
      ~opens_as_page
      ~depth:0
      ~has_children:false
      ~is_collapsed:false
      block_fields
  | _ -> None
;;

let outliner_editing = function
  | `Assoc fields ->
    (match
       string_member "uuid" fields,
       string_member "title" fields,
       int_member "caretUTF16Offset" fields
     with
     | Some uuid, Some title, Some caret_utf16_offset ->
       Some { uuid; title; caret_utf16_offset }
     | _ -> None)
  | _ -> None
;;

let outliner_autocomplete_kind = function
  | "node" -> Some Node
  | "tag" -> Some Tag
  | "property" -> Some Property
  | _ -> None
;;

let outliner_autocomplete = function
  | `Assoc fields ->
    (match string_member "kind" fields, string_member "query" fields with
     | Some kind, Some query ->
       Option.map (fun kind -> { kind; query }) (outliner_autocomplete_kind kind)
     | _ -> None)
  | _ -> None
;;

let outliner_autocomplete_candidate = function
  | `Assoc fields ->
    (match string_member "label" fields, string_member "value" fields with
     | Some label, Some value -> Some { label; value }
     | _ -> None)
  | _ -> None
;;

let outliner_row_splice = function
  | `Assoc fields ->
    (match int_member "deleteCount" fields with
     | Some delete_count ->
       let rows =
         match member "rows" fields with
         | Some (`List values) -> List.filter_map outline_row values
         | _ -> []
       in
       Some
         { start = int_member "start" fields
         ; after_block_id = string_member "afterBlockId" fields
         ; before_block_id = string_member "beforeBlockId" fields
         ; delete_count
         ; rows
         }
     | None -> None)
  | _ -> None
;;

let current_outliner_editing result_fields =
  match member "outlinerState" result_fields with
  | Some (`Assoc state_fields) ->
    (match member "editing" state_fields with
     | Some value -> outliner_editing value
     | None -> None)
  | _ -> None
;;

let current_outliner_autocomplete result_fields =
  match member "outlinerState" result_fields with
  | Some (`Assoc state_fields) ->
    (match member "autocomplete" state_fields with
     | Some value -> outliner_autocomplete value
     | None -> None)
  | _ -> None
;;

let current_outliner_selected_block_ids result_fields =
  match member "outlinerState" result_fields with
  | Some (`Assoc state_fields) ->
    (match member "selectedBlockIds" state_fields with
     | Some (`List values) ->
       List.filter_map (function
         | `String value -> Some value
         | _ -> None)
         values
     | _ -> [])
  | _ -> []
;;

let string_list_member name fields =
  match member name fields with
  | Some (`List values) ->
    List.filter_map (function
      | `String value -> Some value
      | _ -> None)
      values
  | _ -> []
;;

let outliner_rows_member name fields =
  match member name fields with
  | Some (`List values) -> List.filter_map outline_row values
  | _ -> []
;;

let related_rows_member name fields =
  match member name fields with
  | Some (`List values) -> List.filter_map related_row values
  | _ -> []
;;

let sidebar_pages_member name fields =
  match member name fields with
  | Some (`List values) -> List.filter_map sidebar_page values
  | _ -> []
;;

let flashcards_member fields =
  match member "flashcards" fields with
  | Some (`List values) -> List.filter_map flashcard values
  | _ -> []
;;

let task_statuses_member fields =
  match member "taskStatuses" fields with
  | Some (`List values) -> List.filter_map task_status values
  | _ -> []
;;

let autocomplete_candidates_member name fields =
  match member name fields with
  | Some (`List values) -> List.filter_map outliner_autocomplete_candidate values
  | _ -> []
;;

let node_title uuid is_tag fields =
  let page_title =
    match member "page" fields with
    | Some (`Assoc page_fields) -> Option.value ~default:"Untitled" (string_member "title" page_fields)
    | _ -> "Untitled"
  in
  if is_tag
  then "#" ^ page_title
  else
    match member "blocks" fields with
    | Some (`List blocks) ->
      List.find_map
        (function
          | `Assoc block_fields
            when Option.equal String.equal (string_member "uuid" block_fields) (Some uuid) ->
            string_member "title" block_fields
          | _ -> None)
        blocks
      |> Option.value ~default:page_title
    | _ -> page_title
;;

let node_page_uuid uuid fields =
  match member "page" fields with
  | Some (`Assoc page_fields) -> Option.value ~default:uuid (string_member "uuid" page_fields)
  | _ -> uuid
;;

let node_route = function
  | `Assoc fields ->
    (match string_member "uuid" fields with
     | None -> None
     | Some uuid ->
       let is_tag = bool_member "isTag" fields in
       let state_fields =
         match member "outlinerState" fields with
         | Some (`Assoc values) -> values
         | _ -> []
       in
       Some
         { uuid
         ; page_uuid = node_page_uuid uuid fields
         ; title = node_title uuid is_tag fields
         ; is_tag
         ; is_property = bool_member "isProperty" fields
         ; outliner_rows = outliner_rows_member "outlinerRows" fields
         ; related_rows = related_rows_member "relatedBlocks" fields
         ; linked_reference_rows =
             related_rows_member "linkedReferenceBlocks" fields
         ; outliner_editing =
             Option.bind (member "editing" state_fields) outliner_editing
         ; outliner_autocomplete =
             Option.bind (member "autocomplete" state_fields) outliner_autocomplete
         ; outliner_autocomplete_candidates =
             autocomplete_candidates_member "outlinerAutocompleteCandidates" fields
         ; outliner_selected_block_ids = string_list_member "selectedBlockIds" state_fields
         })
  | _ -> None
;;

let error_message fields =
  match member "error" fields with
  | Some (`Assoc error_fields) ->
    Option.value ~default:"Core request failed" (string_member "message" error_fields)
  | _ -> "Core request failed"
;;

let decode_response encoded =
  try
    match Yojson.Basic.from_string encoded with
    | `Assoc response_fields when bool_member "ok" response_fields ->
      (match member "result" response_fields with
       | Some (`Assoc result_fields) ->
         let search_results =
           match member "searchResults" result_fields with
           | Some (`List values) -> List.filter_map search_hit values
           | _ -> []
         in
         let base_outliner_rows = outliner_rows_member "outlinerRows" result_fields in
         let outliner_row_splices =
           match member "outlinerRowSplices" result_fields with
           | Some (`List values) -> List.filter_map outliner_row_splice values
           | _ -> []
         in
         let base_outliner_autocomplete_candidates =
           autocomplete_candidates_member "outlinerAutocompleteCandidates" result_fields
         in
         let node_routes =
           match member "nodeRoutes" result_fields with
           | Some (`List values) -> List.filter_map node_route values
           | _ -> []
         in
         let active_node_route =
           match List.rev node_routes with route :: _ -> Some route | [] -> None
         in
         let outliner_rows =
           Option.fold
             ~none:base_outliner_rows
             ~some:(fun (route : node_route) -> route.outliner_rows)
             active_node_route
         in
         let outliner_editing =
           Option.fold
             ~none:(current_outliner_editing result_fields)
             ~some:(fun (route : node_route) -> route.outliner_editing)
             active_node_route
         in
         let outliner_autocomplete =
           Option.fold
             ~none:(current_outliner_autocomplete result_fields)
             ~some:(fun (route : node_route) -> route.outliner_autocomplete)
             active_node_route
         in
         let outliner_autocomplete_candidates =
           Option.fold
             ~none:base_outliner_autocomplete_candidates
             ~some:(fun (route : node_route) -> route.outliner_autocomplete_candidates)
             active_node_route
         in
         let outliner_selected_block_ids =
           Option.fold
             ~none:(current_outliner_selected_block_ids result_fields)
             ~some:(fun (route : node_route) -> route.outliner_selected_block_ids)
             active_node_route
         in
         Ok
           { graph_name = string_member "graphName" result_fields
           ; selected_graph_id = string_member "selectedGraphId" result_fields
           ; graphs =
               (match member "graphs" result_fields with
                | Some (`List values) -> List.filter_map graph values
                | _ -> [])
           ; is_graph_encrypted = bool_member "isGraphEncrypted" result_fields
           ; is_graph_unlocked = bool_member "isGraphUnlocked" result_fields
           ; favorites = sidebar_pages_member "favorites" result_fields
           ; recent_pages = sidebar_pages_member "recentPages" result_fields
           ; selected_page = Option.bind (member "selectedPage" result_fields) sidebar_page
           ; selected_page_is_tag = bool_member "selectedPageIsTag" result_fields
           ; selected_page_is_property = bool_member "selectedPageIsProperty" result_fields
           ; related_rows = related_rows_member "relatedBlocks" result_fields
           ; linked_reference_rows =
               related_rows_member "linkedReferenceBlocks" result_fields
           ; task_statuses = task_statuses_member result_fields
           ; flashcards = flashcards_member result_fields
           ; search_query = Option.value ~default:"" (string_member "searchQuery" result_fields)
           ; search_results
           ; node_routes
           ; journal_outliner_rows = base_outliner_rows
           ; outliner_rows
           ; outliner_row_splices
           ; outliner_editing
           ; outliner_autocomplete
           ; outliner_autocomplete_candidates
           ; outliner_selected_block_ids
           ; has_older_journals = bool_member "hasOlderJournals" result_fields
           ; is_outliner_patch = bool_member "isOutlinerPatch" result_fields
           ; sync_connected = bool_member "syncConnected" result_fields
           ; applied_server_t = int_member "appliedServerT" result_fields
           ; has_pending_semantic_operations =
               bool_member "hasPendingSemanticOperations" result_fields
           ; has_pending_sync_request =
               (match member "pendingSyncRequest" result_fields with
                | Some `Null | None -> false
                | Some _ -> true)
           ; is_pending_sync_patch = bool_member "isPendingSyncPatch" result_fields
           }
       | _ -> Error "Core response did not contain a snapshot")
    | `Assoc response_fields -> Error (error_message response_fields)
    | _ -> Error "Core response must be a JSON object"
  with
  | Yojson.Json_error message -> Error ("Invalid core response: " ^ message)
;;
