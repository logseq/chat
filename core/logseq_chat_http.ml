module Api = Logseq_chat_api

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

let content_length_of_headers headers =
  let parse_line line =
    match String.index_opt line ':' with
    | None -> None
    | Some colon ->
      let name = String.sub line 0 colon |> String.trim |> String.lowercase_ascii in
      if not (String.equal name "content-length")
      then None
      else (
        let raw_value =
          String.sub line (colon + 1) (String.length line - colon - 1) |> String.trim
        in
        match int_of_string raw_value with
        | length -> Some length
        | exception _ -> None)
  in
  headers |> String.split_on_char '\n' |> List.find_map parse_line
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
    let body_buffer = Buffer.create 4096 in
    Buffer.add_substring body_buffer response body_start (String.length response - body_start);
    (match content_length_of_headers headers with
     | Some body_length ->
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
     | None ->
       Buffer.add_string body_buffer (read_all fd);
       Ok (headers, Buffer.contents body_buffer))
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

let send_https (request : Api.request) =
  let body = Option.value request.Api.body ~default:"" in
  let response = https_send_raw request.Api.method_ request.Api.url body request.Api.token in
  match split_first_line response with
  | "ERROR", message -> Error message
  | status, body ->
    (match int_of_string status with
     | status -> Ok { Api.status; body }
     | exception _ -> Error ("invalid HTTPS status: " ^ status))
;;

let send_http (request : Api.request) endpoint =
  match connect endpoint with
  | Error message -> Error message
  | Ok fd ->
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        try
          let body = Option.value request.Api.body ~default:"" in
          let headers =
            [ Printf.sprintf "%s %s HTTP/1.0" request.Api.method_ endpoint.path
            ; "Host: " ^ endpoint.host
            ; "Authorization: Bearer " ^ request.Api.token
            ; "Accept: application/json"
            ; "Content-Type: application/json"
            ; "Connection: close"
            ; "Content-Length: " ^ string_of_int (String.length body)
            ; ""
            ; body
            ]
            |> String.concat "\r\n"
          in
          write_all fd (Bytes.of_string headers);
          match read_response fd with
          | Error message -> Error message
          | Ok (headers, body) ->
            (match status_of_headers headers with
             | Ok status -> Ok { Api.status; body }
             | Error message -> Error message)
        with
        | exn -> Error (unix_error_message exn))
;;

let send request =
  match parse_url request.Api.url with
  | Error message -> Error message
  | Ok endpoint ->
    if String.equal endpoint.scheme "https"
    then send_https request
    else send_http request endpoint
;;

let upload_file (upload : Api.file_upload) =
  match parse_url upload.request.Api.url with
  | Error message -> Error message
  | Ok _ ->
    https_upload_file_raw upload.request.method_ upload.request.url upload.file_path
      upload.content_type upload.request.token
    |> response_of_native
;;
