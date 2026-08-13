open Yojson.Basic

type config =
  { base_url : string
  ; graph_id : string
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

let recent_blocks_request config =
  { method_ = "GET"
  ; url =
      Printf.sprintf
        "%s/api/v1/graphs/%s/search?q=%%20&types=blocks&limit=100"
        (api_root config)
        (url_encode config.graph_id)
  ; body = None
  ; token = config.token
  }
;;

let graphs_request config =
  { method_ = "GET"
  ; url = Printf.sprintf "%s/api/v1/graphs" (api_root config)
  ; body = None
  ; token = config.token
  }
;;

let search_request config query =
  { method_ = "GET"
  ; url =
      Printf.sprintf
        "%s/api/v1/graphs/%s/search?q=%s&types=blocks&limit=100"
        (api_root config)
        (url_encode config.graph_id)
        (url_encode query)
  ; body = None
  ; token = config.token
  }
;;

let capture_request config text =
  { method_ = "POST"
  ; url =
      Printf.sprintf
        "%s/api/v1/graphs/%s/capture"
        (api_root config)
        (url_encode config.graph_id)
  ; body =
      Some
        (to_string
           (`Assoc [ "blocks", `List [ `Assoc [ "title", `String text ] ] ]))
  ; token = config.token
  }
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
          }
  | _ -> None
;;

let blocks_from_search_body body =
  let now = epoch_ms () in
  match from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "results" fields with
     | Some (`List results) ->
       results
       |> List.mapi (fun index json ->
         (* The search endpoint does not currently expose created-at. Preserve
            response order with synthetic timestamps so the UI can group and
            scroll consistently while keeping server-owned UUID/title/page ids. *)
         block_of_json ~fallback_time:(now + index) json)
       |> List.filter_map Fun.id
     | _ -> [])
  | _ -> []
;;

let graph_id_from_graphs_body body =
  match from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "graphs" fields with
     | Some (`List graphs) ->
       graphs
       |> List.find_map (function
         | `Assoc graph_fields ->
           (match List.assoc_opt "graph-id" graph_fields with
            | Some (`String graph_id) when not (String.equal graph_id "") -> Some graph_id
            | _ -> None)
         | _ -> None)
     | _ -> None)
  | _ -> None
;;
