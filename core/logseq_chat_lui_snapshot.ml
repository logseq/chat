type search_hit =
  { uuid : string
  ; title : string
  ; breadcrumb : string
  ; is_page : bool
  }

type outline_row =
  { uuid : string
  ; title : string
  ; depth : int
  ; has_children : bool
  ; is_collapsed : bool
  }

type outliner_editing =
  { uuid : string
  ; title : string
  ; caret_utf16_offset : int
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
  ; search_query : string
  ; search_results : search_hit list
  ; outliner_rows : outline_row list
  ; outliner_row_splices : outliner_row_splice list
  ; outliner_editing : outliner_editing option
  ; is_outliner_patch : bool
  ; sync_connected : bool
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

let title_from_summary = function
  | `Assoc fields -> string_member "title" fields
  | _ -> None
;;

let breadcrumb fields =
  let titles =
    match member "breadcrumbs" fields with
    | Some (`List values) -> List.filter_map title_from_summary values
    | _ -> []
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
       Some { uuid; title; breadcrumb = breadcrumb fields; is_page = bool_member "isPage" fields }
     | _ -> None)
  | _ -> None
;;

let outline_row = function
  | `Assoc fields ->
    (match member "block" fields, int_member "depth" fields with
     | Some (`Assoc block_fields), Some depth ->
       (match string_member "uuid" block_fields, string_member "title" block_fields with
        | Some uuid, Some title ->
          Some
            { uuid
            ; title
            ; depth
            ; has_children = bool_member "hasChildren" fields
            ; is_collapsed = bool_member "isCollapsed" fields
            }
        | _ -> None)
     | _ -> None)
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
         let outliner_rows =
           match member "outlinerRows" result_fields with
           | Some (`List values) -> List.filter_map outline_row values
           | _ -> []
         in
         let outliner_row_splices =
           match member "outlinerRowSplices" result_fields with
           | Some (`List values) -> List.filter_map outliner_row_splice values
           | _ -> []
         in
         Ok
           { graph_name = string_member "graphName" result_fields
           ; search_query = Option.value ~default:"" (string_member "searchQuery" result_fields)
           ; search_results
           ; outliner_rows
           ; outliner_row_splices
           ; outliner_editing = current_outliner_editing result_fields
           ; is_outliner_patch = bool_member "isOutlinerPatch" result_fields
           ; sync_connected = bool_member "syncConnected" result_fields
           }
       | _ -> Error "Core response did not contain a snapshot")
    | `Assoc response_fields -> Error (error_message response_fields)
    | _ -> Error "Core response must be a JSON object"
  with
  | Yojson.Json_error message -> Error ("Invalid core response: " ^ message)
;;
