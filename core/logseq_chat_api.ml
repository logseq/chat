open Yojson.Basic

type config =
  { base_url : string
  ; graph_id : string
  ; graph_name : string option
  ; token : string
  }

type request =
  { method_ : string
  ; url : string
  ; body : string option
  ; token : string
  }

type response =
  { status : int
  ; body : string
  }

type file_upload =
  { request : request
  ; file_path : string
  ; content_type : string
  }

type journal =
  { uuid : string
  ; title : string
  ; journal_day : int
  }

type graph =
  { id : string
  ; name : string
  ; e2ee : bool
  ; ready : bool
  }

let epoch_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let trim_slash value =
  if String.length value > 0 && value.[String.length value - 1] = '/'
  then String.sub value 0 (String.length value - 1)
  else value
;;

let ends_with ~suffix value =
  let suffix_len = String.length suffix in
  let value_len = String.length value in
  value_len >= suffix_len
  && String.equal
       (String.sub value (value_len - suffix_len) suffix_len)
       suffix
;;

let api_root config =
  let base_url = trim_slash config.base_url in
  if ends_with ~suffix:"/api" base_url
  then String.sub base_url 0 (String.length base_url - 4)
  else base_url
;;

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' -> true
  | _ -> false
;;

let url_encode value =
  let buffer = Buffer.create (String.length value) in
  String.iter
    (fun ch ->
      if is_unreserved ch
      then Buffer.add_char buffer ch
      else Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code ch)))
    value;
  Buffer.contents buffer
;;

let recent_blocks_request config ~journal_day =
  { method_ = "GET"
  ; url =
      Printf.sprintf
        "%s/api/v1/graphs/%s/blocks?journal-only=true&journal-day-at-most=%d&sort=created-at-desc&limit=100"
        (api_root config)
        (url_encode config.graph_id)
        journal_day
  ; body = None
  ; token = config.token
  }
;;

let task_statuses_request config =
  { method_ = "GET"
  ; url =
      Printf.sprintf
        "%s/api/v1/graphs/%s/search?q=Status&types=properties&limit=100"
        (api_root config)
        (url_encode config.graph_id)
  ; body = None
  ; token = config.token
  }
;;

let graphs_request config =
  { method_ = "GET"
  ; url = Printf.sprintf "%s/graphs" (api_root config)
  ; body = None
  ; token = config.token
  }
;;

let search_request config query =
  { method_ = "GET"
  ; url =
      Printf.sprintf
        "%s/api/v1/graphs/%s/search?q=%s&types=blocks,assets&limit=100"
        (api_root config)
        (url_encode config.graph_id)
        (url_encode query)
  ; body = None
  ; token = config.token
  }
;;

let related_request config resource uuid collection =
  { method_ = "GET"
  ; url = Printf.sprintf "%s/api/v1/graphs/%s/%s/%s/%s?limit=100"
      (api_root config) (url_encode config.graph_id) resource (url_encode uuid) collection
  ; body = None
  ; token = config.token
  }
;;

let block_references_request config uuid = related_request config "blocks" uuid "references"
let page_references_request config uuid = related_request config "pages" uuid "references"
let tag_objects_request config uuid = related_request config "tags" uuid "objects"

let capture_request config ~uuid text =
  { method_ = "POST"
  ; url =
      Printf.sprintf
        "%s/api/v1/graphs/%s/capture"
        (api_root config)
        (url_encode config.graph_id)
  ; body =
      Some
        (to_string
           (`Assoc
             [ "blocks",
               `List [ `Assoc [ "uuid", `String uuid; "title", `String text ] ]
             ]))
  ; token = config.token
  }
;;

let chat_tx_batch_request config ~client_revision ~t_before ~outliner_op ~tx =
  { method_ = "POST"
  ; url =
      Printf.sprintf
        "%s/sync/%s/chat/tx/batch"
        (api_root config)
        (url_encode config.graph_id)
  ; body =
      Some
        (to_string
           (`Assoc
             [ "client-revision", `String client_revision
             ; "t-before", `Int t_before
             ; ( "txs"
               , `List
                   [ `Assoc
                       [ "tx", `String tx
                       ; "outliner-op", `String outliner_op
                       ]
                   ] )
             ]))
  ; token = config.token
  }
;;

let task_request config ~uuid ~status text =
  { method_ = "POST"
  ; url = Printf.sprintf "%s/api/v1/graphs/%s/tasks" (api_root config) (url_encode config.graph_id)
  ; body = Some (to_string (`Assoc [ "uuid", `String uuid; "title", `String text; "status", `String status ]))
  ; token = config.token
  }
;;

let asset_upload_request config ~uuid ~file_name ~size ~checksum ~file_path ~content_type =
  { request =
      { method_ = "POST"
      ; url =
          Printf.sprintf
            "%s/api/v1/graphs/%s/assets?uuid=%s&file-name=%s&size=%d&checksum=%s"
            (api_root config) (url_encode config.graph_id) (url_encode uuid)
            (url_encode file_name) size (url_encode checksum)
      ; body = None
      ; token = config.token
      }
  ; file_path
  ; content_type
  }
;;

let created_block_uuid_from_body body =
  match from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "uuid" fields with
     | Some (`String uuid) when not (String.equal (String.trim uuid) "") -> uuid
     | _ ->
       (match List.assoc_opt "blocks" fields with
        | Some (`List (`Assoc block_fields :: _)) ->
          (match List.assoc_opt "uuid" block_fields with
           | Some (`String uuid) when not (String.equal (String.trim uuid) "") -> uuid
           | _ -> failwith "creation response block is missing uuid")
        | _ -> failwith "creation response is missing uuid"))
  | _ -> failwith "creation response must be an object"
;;

let content_type_for_asset_type = function
  | "jpg" | "jpeg" -> "image/jpeg"
  | "png" -> "image/png"
  | "gif" -> "image/gif"
  | "heic" -> "image/heic"
  | "m4a" -> "audio/mp4"
  | "mp3" -> "audio/mpeg"
  | "wav" -> "audio/wav"
  | _ -> "application/octet-stream"
;;

let update_block_request config ~uuid ~title =
  { method_ = "PATCH"
  ; url =
      Printf.sprintf
        "%s/api/v1/graphs/%s/blocks/%s"
        (api_root config)
        (url_encode config.graph_id)
        (url_encode uuid)
  ; body = Some (to_string (`Assoc [ "title", `String title ]))
  ; token = config.token
  }
;;

let update_block_status_request config ~uuid ~status =
  { method_ = "PUT"
  ; url =
      Printf.sprintf
        "%s/api/v1/graphs/%s/blocks/%s/properties/Status"
        (api_root config)
        (url_encode config.graph_id)
        (url_encode uuid)
  ; body = Some (to_string (`Assoc [ "value", `String status ]))
  ; token = config.token
  }
;;

let int_member name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> value
  | _ -> 0
;;

let string_member name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> value
  | _ -> ""
;;

let option_string_member name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | _ -> None
;;

let summaries_member name fields =
  match List.assoc_opt name fields with
  | Some (`List values) ->
    List.filter_map
      (function
        | `Assoc summary ->
          let uuid = string_member "uuid" summary in
          let kind = string_member "kind" summary in
          let title = string_member "title" summary in
          if uuid = "" || title = "" then None
          else Some Logseq_chat_model.{ uuid; kind; title }
        | _ -> None)
      values
  | _ -> []
;;

let status_from_fields status =
    let uuid = string_member "uuid" status in
    let title = string_member "title" status in
    let icon_type, icon_id, icon_color =
      match List.assoc_opt "icon" status with
      | Some (`Assoc icon) ->
        option_string_member "type" icon,
        option_string_member "id" icon,
        option_string_member "color" icon
      | _ -> None, None, None
    in
    if uuid = "" || title = "" then None
    else Some Logseq_chat_model.{
      uuid; ident = option_string_member "ident" status; title; icon_type; icon_id; icon_color
    }
;;

let status_member fields =
  match List.assoc_opt "status" fields with
  | Some (`Assoc status) -> status_from_fields status
  | _ -> None
;;

let statuses_from_property_body body =
  let choices fields =
    match List.assoc_opt "choices" fields with
    | Some (`List values) ->
      List.filter_map (function `Assoc status -> status_from_fields status | _ -> None) values
    | _ -> []
  in
  match from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "results" fields with
     | Some (`List properties) ->
       properties
       |> List.find_map (function
         | `Assoc property when
             String.equal (string_member "ident" property) "logseq.property/status" ->
           Some (choices property)
         | _ -> None)
       |> Option.value ~default:[]
     | _ -> choices fields)
  | _ -> []
;;

let block_of_json ?(fallback_time = 0) json =
  match json with
  | `Assoc fields ->
    let uuid = string_member "uuid" fields in
    let title = string_member "title" fields in
    if String.equal uuid "" || String.equal title ""
    then None
    else
      Some
        Logseq_chat_model.
          { uuid
          ; kind =
              (match string_member "kind" fields with
               | "" -> "block"
               | value -> value)
          ; title
          ; page_id = string_member "page-id" fields
          ; parent_id = option_string_member "parent-id" fields
          ; created_at =
              (match int_member "created-at" fields with
               | 0 -> fallback_time
               | value -> value)
	          ; updated_at =
	              (match int_member "updated-at" fields with
	               | 0 -> fallback_time
	               | value -> value)
	          ; sync_status = "synced"
	          ; tags = summaries_member "tags" fields
	          ; references = summaries_member "references" fields
	          ; status = status_member fields
	          ; asset_type = option_string_member "asset-type" fields
	          ; asset_size = (match List.assoc_opt "asset-size" fields with Some (`Int value) -> Some value | _ -> None)
	          ; asset_checksum = option_string_member "asset-checksum" fields
	          ; local_path = None
	          }
  | _ -> None
;;

let blocks_from_search_body body =
  match from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "results" fields with
     | Some (`List results) ->
       results
       |> List.filter_map (block_of_json ~fallback_time:0)
     | _ -> [])
  | _ -> []
;;

let blocks_from_list_body key body =
  match from_string body with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`List values) -> List.filter_map block_of_json values
     | _ -> [])
  | _ -> []
;;

let journals_from_search_body body =
  match from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "results" fields with
     | Some (`List results) ->
       results
       |> List.filter_map (function
         | `Assoc result_fields ->
           let uuid = string_member "page-id" result_fields in
           let title = string_member "journal-title" result_fields in
           let journal_day = int_member "journal-day" result_fields in
           if String.equal uuid "" || journal_day <= 0
           then None
           else Some { uuid; title; journal_day }
         | _ -> None)
       |> List.sort_uniq (fun left right -> String.compare left.uuid right.uuid)
     | _ -> [])
  | _ -> []
;;

let feed_from_body body =
  match from_string body with
  | `Assoc fields ->
    let blocks =
      match List.assoc_opt "blocks" fields with
      | Some (`List values) -> List.filter_map block_of_json values
      | _ -> []
    in
    let journals =
      match List.assoc_opt "journals" fields with
      | Some (`List values) ->
        values
        |> List.filter_map (function
         | `Assoc page_fields ->
           let uuid = string_member "uuid" page_fields in
           let title = string_member "title" page_fields in
           let journal_day = int_member "journal-day" page_fields in
           if String.equal uuid "" || journal_day <= 0
           then None
           else Some { uuid; title; journal_day }
         | _ -> None)
      | _ -> []
    in
    blocks, journals
  | _ -> [], []
;;

let graphs_from_graphs_body body =
  match from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "graphs" fields with
     | Some (`List graphs) ->
       graphs
       |> List.filter_map (function
         | `Assoc graph_fields ->
           (match List.assoc_opt "graph-id" graph_fields with
            | Some (`String graph_id) when not (String.equal graph_id "") ->
              let graph_name =
                match List.assoc_opt "graph-name" graph_fields with
                | Some (`String value) when not (String.equal value "") -> value
                | _ -> graph_id
              in
              let bool_field ~safe_default name =
                match List.assoc_opt name graph_fields with
                | Some (`Bool value) -> value
                | _ -> safe_default
              in
              Some
                { id = graph_id
                ; name = graph_name
                ; e2ee = bool_field ~safe_default:true "graph-e2ee?"
                ; ready = bool_field ~safe_default:false "graph-ready-for-use?"
                }
            | _ -> None)
         | _ -> None)
     | _ -> [])
  | _ -> []
;;

let graph_from_graphs_body body =
  match graphs_from_graphs_body body with
  | graph :: _ -> Some (graph.id, Some graph.name)
  | [] -> None
;;
