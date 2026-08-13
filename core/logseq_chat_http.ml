module Api = Logseq_chat_api

type endpoint =
  { host : string
  ; port : int
  ; path : string
  }

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal (String.sub value 0 prefix_len) prefix
;;

let parse_http_url url =
  let scheme = "http://" in
  if not (starts_with ~prefix:scheme url)
  then Error "only http:// Logseq API URLs are supported"
  else (
    let rest = String.sub url (String.length scheme) (String.length url - String.length scheme) in
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
      | None -> authority, 80
    in
    if String.equal host "" then Error "Logseq API URL host is empty" else Ok { host; port; path })
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

let split_response response =
  let marker = "\r\n\r\n" in
  let marker_len = String.length marker in
  let rec find index =
    if index + marker_len > String.length response
    then None
    else if String.equal (String.sub response index marker_len) marker
    then Some index
    else find (index + 1)
  in
  match find 0 with
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
  let rec try_addresses = function
    | [] -> Error ("could not resolve " ^ endpoint.host ^ ":" ^ service)
    | address :: rest ->
      let fd = Unix.socket address.Unix.ai_family address.Unix.ai_socktype address.Unix.ai_protocol in
      (match Unix.connect fd address.Unix.ai_addr with
       | () -> Ok fd
       | exception exn ->
         Unix.close fd;
         (match try_addresses rest with
          | Ok fd -> Ok fd
          | Error _ -> Error (Printexc.to_string exn)))
  in
  try_addresses addresses
;;

let send request =
  match parse_http_url request.Api.url with
  | Error message -> Error message
  | Ok endpoint ->
    (match connect endpoint with
     | Error message -> Error message
     | Ok fd ->
       Fun.protect
         ~finally:(fun () -> Unix.close fd)
         (fun () ->
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
           match read_all fd |> split_response with
           | Error message -> Error message
           | Ok (headers, body) ->
             (match status_of_headers headers with
              | Ok status -> Ok { Api.status; body }
              | Error message -> Error message)))
;;
