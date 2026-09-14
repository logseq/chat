module Api = Logseq_chat_lg_core_native

type endpoint =
  { scheme : string
  ; host : string
  ; port : int
  ; path : string
  }

let request_timeout_seconds = 30.0

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal (String.sub value 0 prefix_len) prefix
;;

let unix_error_message = function
  | Unix.Unix_error (error, function_name, argument) ->
    Printf.sprintf
      "%s(%s): %s"
      function_name
      argument
      (Unix.error_message error)
  | exn -> Printexc.to_string exn
;;

external https_send_raw
  :  string
  -> string
  -> string
  -> string
  -> string
  = "logseq_chat_https_send"

external https_upload_file_raw
  :  string
  -> string
  -> string
  -> string
  -> string
  -> string
  = "logseq_chat_https_upload_file"

let split_first_line value =
  match String.index_opt value '\n' with
  | None -> value, ""
  | Some index ->
    ( String.sub value 0 index
    , String.sub value (index + 1) (String.length value - index - 1) )
;;

let response_of_native raw =
  let first, body = split_first_line raw in
  if String.equal first "ERROR" then Error body
  else
    match int_of_string_opt first with
    | Some status -> Ok Api.{ status; body }
    | None -> Error "invalid native HTTP response"
;;

let parse_url url =
  let scheme, rest, default_port =
    if starts_with ~prefix:"http://" url
    then "http", String.sub url 7 (String.length url - 7), 80
    else if starts_with ~prefix:"https://" url
    then "https", String.sub url 8 (String.length url - 8), 443
    else "", "", 0
  in
  if String.equal scheme ""
  then Error "only http:// and https:// Logseq API URLs are supported"
  else (
    let slash =
      match String.index_opt rest '/' with
      | Some index -> index
      | None -> String.length rest
    in
    let authority = String.sub rest 0 slash in
    let path =
      if slash = String.length rest
      then "/"
      else String.sub rest slash (String.length rest - slash)
    in
    let host, port =
      match String.rindex_opt authority ':' with
      | Some colon ->
        ( String.sub authority 0 colon
        , int_of_string
            (String.sub authority (colon + 1) (String.length authority - colon - 1)) )
      | None -> authority, default_port
    in
    if String.equal host ""
    then Error "Logseq API URL host is empty"
    else Ok { scheme; host; port; path })
;;

let write_all fd payload =
  let length = Bytes.length payload in
  let rec loop offset =
    if offset < length
    then (
      let written = Unix.write fd payload offset (length - offset) in
      if written = 0 then failwith "socket write returned 0";
      loop (offset + written))
  in
  loop 0
;;

let read_all fd =
  let buffer = Buffer.create 4096 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents buffer
    | read_count ->
      Buffer.add_subbytes buffer chunk 0 read_count;
      loop ()
  in
  loop ()
;;

let find_substring ~needle value =
  let needle_len = String.length needle in
  let rec find index =
    if index + needle_len > String.length value
    then None
    else if String.equal (String.sub value index needle_len) needle
    then Some index
    else find (index + 1)
  in
  find 0
;;

let split_response response =
  let marker = "\r\n\r\n" in
  let marker_len = String.length marker in
  match find_substring ~needle:marker response with
  | None -> Error "HTTP response did not contain headers"
  | Some index ->
    let headers = String.sub response 0 index in
    let body =
      String.sub
        response
        (index + marker_len)
        (String.length response - index - marker_len)
    in
    Ok (headers, body)
;;

let header_field ~name headers =
  let name = String.lowercase_ascii name in
  headers
  |> String.split_on_char '\n'
  |> List.find_map (fun line ->
    match String.index_opt line ':' with
    | None -> None
    | Some colon ->
      let field = String.sub line 0 colon |> String.trim |> String.lowercase_ascii in
      if not (String.equal field name)
      then None
      else
        Some
          (String.sub line (colon + 1) (String.length line - colon - 1)
           |> String.trim
           |> String.lowercase_ascii))
;;

let content_length_of_headers headers =
  match header_field ~name:"content-length" headers with
  | None -> None
  | Some raw_value ->
    (match int_of_string raw_value with
     | length -> Some length
     | exception _ -> None)
;;

let transfer_encoding_is_chunked headers =
  match header_field ~name:"transfer-encoding" headers with
  | None -> false
  | Some value ->
    value
    |> String.split_on_char ','
    |> List.exists (fun part -> String.equal (String.trim part) "chunked")
;;

let host_header endpoint =
  let default_port = if String.equal endpoint.scheme "https" then 443 else 80 in
  if endpoint.port = default_port
  then endpoint.host
  else Printf.sprintf "%s:%d" endpoint.host endpoint.port
;;

let hex_length value =
  match int_of_string_opt ("0x" ^ String.trim value) with
  | Some length when length >= 0 -> Ok length
  | Some _ | None -> Error ("invalid HTTP chunk size: " ^ value)
;;

let read_chunked_body fd initial =
  let buffer = Buffer.create (String.length initial + 4096) in
  Buffer.add_string buffer initial;
  let chunk = Bytes.create 4096 in
  let rec ensure needed =
    if Buffer.length buffer >= needed
    then Ok ()
    else (
      match Unix.read fd chunk 0 (Bytes.length chunk) with
      | 0 -> Error "HTTP chunked body ended early"
      | read_count ->
        Buffer.add_subbytes buffer chunk 0 read_count;
        ensure needed)
  in
  let rec line_end offset =
    let contents = Buffer.contents buffer in
    match find_substring ~needle:"\r\n" (String.sub contents offset (String.length contents - offset)) with
    | Some relative -> Ok (offset + relative)
    | None ->
      (match ensure (Buffer.length buffer + 1) with
       | Error _ as error -> error
       | Ok () -> line_end offset)
  in
  let rec loop offset acc =
    match line_end offset with
    | Error _ as error -> error
    | Ok crlf ->
      let contents = Buffer.contents buffer in
      let size_line = String.sub contents offset (crlf - offset) in
      let size_line =
        match String.index_opt size_line ';' with
        | None -> size_line
        | Some index -> String.sub size_line 0 index
      in
      (match hex_length size_line with
       | Error _ as error -> error
       | Ok 0 -> Ok (String.concat "" (List.rev acc))
       | Ok size ->
         let data_start = crlf + 2 in
         (match ensure (data_start + size + 2) with
          | Error _ as error -> error
          | Ok () ->
            let contents = Buffer.contents buffer in
            let data = String.sub contents data_start size in
            loop (data_start + size + 2) (data :: acc)))
  in
  loop 0 []
;;

let read_response fd =
  let marker = "\r\n\r\n" in
  let marker_len = String.length marker in
  let buffer = Buffer.create 4096 in
  let chunk = Bytes.create 4096 in
  let rec read_headers () =
    match find_substring ~needle:marker (Buffer.contents buffer) with
    | Some index -> Ok index
    | None ->
      (match Unix.read fd chunk 0 (Bytes.length chunk) with
       | 0 -> Error "HTTP response did not contain headers"
       | read_count ->
         Buffer.add_subbytes buffer chunk 0 read_count;
         read_headers ())
  in
  match read_headers () with
  | Error message -> Error message
  | Ok header_end ->
    let response = Buffer.contents buffer in
    let body_start = header_end + marker_len in
    let headers = String.sub response 0 header_end in
    let initial_body =
      String.sub response body_start (String.length response - body_start)
    in
    (match content_length_of_headers headers with
     | Some body_length ->
       let body_buffer = Buffer.create body_length in
       Buffer.add_string body_buffer initial_body;
       let rec read_body () =
         let current_length = Buffer.length body_buffer in
         if current_length >= body_length
         then (
           let body = Buffer.contents body_buffer in
           Ok (headers, String.sub body 0 body_length))
         else (
           let remaining = body_length - current_length in
           let read_count = Unix.read fd chunk 0 (min remaining (Bytes.length chunk)) in
           if read_count = 0
           then Error "HTTP response ended before Content-Length bytes were read"
           else (
             Buffer.add_subbytes body_buffer chunk 0 read_count;
             read_body ()))
       in
       read_body ()
     | None when transfer_encoding_is_chunked headers ->
       (match read_chunked_body fd initial_body with
        | Error _ as error -> error
        | Ok body -> Ok (headers, body))
     | None -> Ok (headers, initial_body ^ read_all fd))
;;

let status_of_headers headers =
  match String.index_opt headers '\r' with
  | None -> Error "HTTP status line is missing"
  | Some line_end ->
    let status_line = String.sub headers 0 line_end in
    (match String.split_on_char ' ' status_line with
     | _version :: code :: _ -> Ok (int_of_string code)
     | _ -> Error ("invalid HTTP status line: " ^ status_line))
;;

let connect endpoint =
  let service = string_of_int endpoint.port in
  let addresses =
    Unix.getaddrinfo
      endpoint.host
      service
      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  in
  let configure_socket fd =
    Unix.clear_nonblock fd;
    Unix.setsockopt_float fd Unix.SO_RCVTIMEO request_timeout_seconds;
    Unix.setsockopt_float fd Unix.SO_SNDTIMEO request_timeout_seconds
  in
  let finish_nonblocking_connect fd =
    match Unix.select [] [ fd ] [] request_timeout_seconds with
    | _, [], _ -> Error "HTTP connect timed out after 30s"
    | _ ->
      (match Unix.getsockopt_error fd with
       | None ->
         configure_socket fd;
         Ok fd
       | Some error -> Error (Unix.error_message error))
  in
  let rec try_addresses = function
    | [] -> Error ("could not resolve " ^ endpoint.host ^ ":" ^ service)
    | address :: rest ->
      let fd = Unix.socket address.Unix.ai_family address.Unix.ai_socktype address.Unix.ai_protocol in
      Unix.set_nonblock fd;
      (match Unix.connect fd address.Unix.ai_addr with
       | () ->
         configure_socket fd;
         Ok fd
       | exception Unix.Unix_error ((Unix.EINPROGRESS | Unix.EWOULDBLOCK | Unix.EAGAIN), _, _) ->
         (match finish_nonblocking_connect fd with
          | Ok fd -> Ok fd
          | Error message ->
            Unix.close fd;
            (match try_addresses rest with
             | Ok fd -> Ok fd
             | Error _ -> Error message))
       | exception exn ->
         Unix.close fd;
         (match try_addresses rest with
          | Ok fd -> Ok fd
          | Error _ -> Error (unix_error_message exn)))
  in
  try_addresses addresses
;;

let send_http (request : Api.api_request) endpoint extra_headers body =
  match connect endpoint with
  | Error message -> Error message
  | Ok fd ->
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        try
          let extra_header_lines =
            List.map (fun (name, value) -> name ^ ": " ^ value) extra_headers
          in
          let headers =
            [ Printf.sprintf "%s %s HTTP/1.0" request.Api.method_ endpoint.path
            ; "Host: " ^ host_header endpoint
            ; "Authorization: Bearer " ^ request.Api.token
            ; "Accept: application/json"
            ; "Content-Type: application/json"
            ; "Connection: close"
            ; "Content-Length: " ^ string_of_int (String.length body)
            ]
            @ extra_header_lines
            @ [ ""; body ]
            |> String.concat "\r\n"
          in
          write_all fd (Bytes.of_string headers);
          match read_response fd with
          | Error message -> Error message
          | Ok (headers, body) ->
            (match status_of_headers headers with
             | Ok status -> Ok (Api.logseq_chat_api_response status body)
             | Error message -> Error message)
        with
        | exn -> Error (unix_error_message exn))
;;

let send_https (request : Api.api_request) =
  let body = Option.value request.Api.body ~default:"" in
  let response = https_send_raw request.Api.method_ request.Api.url body request.Api.token in
  match split_first_line response with
  | "ERROR", message -> Error message
  | status, body ->
    (match int_of_string status with
     | status -> Ok (Api.logseq_chat_api_response status body)
     | exception _ -> Error ("invalid HTTPS status: " ^ status))
;;

let send (request : Api.api_request) =
  match parse_url request.Api.url with
  | Error message -> Error message
  | Ok endpoint ->
    if String.equal endpoint.scheme "https"
    then send_https request
    else send_http request endpoint [] (Option.value request.Api.body ~default:"")
;;

let read_file_bytes path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> Ok (really_input_string channel (in_channel_length channel)))
  with
  | exn -> Error ("could not read upload file: " ^ unix_error_message exn)
;;

let upload_http (upload : Api.api_file_upload) endpoint =
  match read_file_bytes upload.file_path with
  | Error _ as error -> error
  | Ok body ->
    match connect endpoint with
    | Error message -> Error message
    | Ok fd ->
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () ->
          try
            let extra_header_lines =
              List.map (fun (name, value) -> name ^ ": " ^ value) upload.headers
            in
            let headers =
              [ Printf.sprintf "%s %s HTTP/1.0" upload.request.Api.method_ endpoint.path
              ; "Host: " ^ host_header endpoint
              ; "Authorization: Bearer " ^ upload.request.token
              ; "Accept: application/json"
              ; "Content-Type: " ^ upload.content_type
              ; "Connection: close"
              ; "Content-Length: " ^ string_of_int (String.length body)
              ]
              @ extra_header_lines
              @ [ ""; body ]
              |> String.concat "\r\n"
            in
            write_all fd (Bytes.of_string headers);
            match read_response fd with
            | Error message -> Error message
            | Ok (response_headers, response_body) ->
              (match status_of_headers response_headers with
               | Ok status -> Ok (Api.logseq_chat_api_response status response_body)
               | Error message -> Error message)
          with
          | exn -> Error (unix_error_message exn))
;;

let upload_file (upload : Api.api_file_upload) =
  match parse_url upload.request.Api.url with
  | Error message -> Error message
  | Ok endpoint ->
    if String.equal endpoint.scheme "https"
    then
      https_upload_file_raw
        upload.request.method_
        upload.request.url
        upload.file_path
        upload.content_type
        upload.request.token
      |> response_of_native
    else upload_http upload endpoint
;;
