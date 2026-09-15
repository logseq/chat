let assert_equal label expected actual =
  if not (String.equal expected actual)
  then
    failwith
      (Printf.sprintf "%s: expected %S, got %S" label expected actual)
;;

let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()
;;

let write_string fd value =
  let length = String.length value in
  let rec loop offset =
    if offset < length
    then (
      let written = Unix.write_substring fd value offset (length - offset) in
      if written = 0 then failwith "pipe write returned 0";
      loop (offset + written))
  in
  loop 0
;;

let with_timeout seconds f =
  let previous =
    Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> failwith "timed out"))
  in
  ignore (Unix.alarm seconds);
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.alarm 0);
      Sys.set_signal Sys.sigalrm previous)
    f
;;

let () =
  let read_fd, write_fd = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      close_quietly read_fd;
      close_quietly write_fd)
    (fun () ->
      write_string
        write_fd
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n{}";
      match
        with_timeout 1 (fun () -> Logseq_chat_lg_core_native.logseq_chat_http_read_response read_fd)
      with
      | Error message -> failwith message
	 | Ok (headers, body) ->
	   assert_equal "response body" "{}" body;
	   assert_equal "status headers" "HTTP/1.1 200 OK" (String.sub headers 0 15))
;;

let find_sub needle value =
  let needle_len = String.length needle in
  let rec loop index =
    if index + needle_len > String.length value
    then None
    else if String.equal (String.sub value index needle_len) needle
    then Some index
    else loop (index + 1)
  in
  loop 0
;;

let response_from_parts parts =
  let read_fd, write_fd = Unix.pipe () in
  let writer = Thread.create (fun () ->
    Fun.protect ~finally:(fun () -> close_quietly write_fd) (fun () ->
      List.iter (fun part -> write_string write_fd part; Thread.delay 0.001) parts)) () in
  Fun.protect ~finally:(fun () -> close_quietly read_fd; Thread.join writer)
    (fun () -> with_timeout 2 (fun () -> Logseq_chat_lg_core_native.logseq_chat_http_read_response read_fd))
;;

let () =
  List.iter (fun (label, parts, expected) ->
    match response_from_parts parts, expected with
    | Ok (_, body), Ok wanted -> assert_equal label wanted body
    | Error message, Error wanted -> assert_equal label wanted message
    | _ -> failwith (label ^ ": unexpected response"))
    [ "fragmented content length",
      ["HTTP/1.1 200 OK\r\nContent-Len"; "gth: 5\r\n\r"; "\nhe"; "llo"], Ok "hello"
    ; "fragmented chunks and extensions",
      ["HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, Chunked\r\n\r\n";
       "2;test=yes\r"; "\nhe\r\n3\r\nllo\r\n0\r\n\r\n"], Ok "hello"
    ; "connection close body", ["HTTP/1.0 200 OK\r\nX-Test: yes\r\n\r\nhi"; " there"], Ok "hi there"
    ; "empty body", ["HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"], Ok ""
    ; "body clipped to length", ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhello"], Ok "he"
    ; "missing headers", ["HTTP/1.1 200 OK"], Error "HTTP response did not contain headers"
    ; "truncated body", ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi"],
      Error "HTTP response ended before Content-Length bytes were read"
    ; "truncated chunk", ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhi"],
      Error "HTTP chunked body ended early"
    ; "invalid chunk", ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nnope\r\n"],
      Error "invalid HTTP chunk size: nope"
    ];
  (match Logseq_chat_lg_core_native.logseq_chat_http_response_of_native "201\nhello\nworld" with
   | Ok response when response.status = 201 -> assert_equal "native body" "hello\nworld" response.body
   | _ -> failwith "native response decode failed");
  List.iter (fun (raw, expected) ->
    match Logseq_chat_lg_core_native.logseq_chat_http_response_of_native raw with
    | Error message -> assert_equal "native error" expected message
    | Ok _ -> failwith "expected native response error")
    ["ERROR\ntransport failed", "transport failed"; "bad\nbody", "invalid native HTTP response"];
  List.iter (fun (url, scheme, host, port, path) ->
    match Logseq_chat_lg_core_native.logseq_chat_http_parse_url url with
    | Ok endpoint when endpoint.scheme = scheme && endpoint.host = host && endpoint.port = port ->
      assert_equal "endpoint path" path endpoint.request_path
    | _ -> failwith ("URL parse failed: " ^ url))
    ["http://localhost", "http", "localhost", 80, "/";
     "https://example.test/a?q=1", "https", "example.test", 443, "/a?q=1";
     "http://localhost:8123/a", "http", "localhost", 8123, "/a"]
;;

let () =
  match
    Logseq_chat_lg_core_native.logseq_chat_http_send
      { Logseq_chat_lg_core_native.method_ = "GET"
      ; url = "https://api-staging.logseq.io/api/v1/graphs"
      ; body = None
      ; token = "token"
      }
  with
  | Ok _ -> ()
  | Error message ->
    if String.equal message "only http:// Logseq API URLs are supported"
    then failwith "https URLs should be routed to the HTTPS transport"
;;

let () =
  let server = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt server Unix.SO_REUSEADDR true;
  Unix.bind server (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen server 1;
  let port =
    match Unix.getsockname server with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> failwith "expected an inet listen socket"
  in
  let file_path = Filename.temp_file "logseq-chat-upload" ".bin" in
  let payload = "\000" ^ String.make 5000 'x' ^ "asset-bytes\255\228\184\173" in
  let channel = open_out_bin file_path in
  output_string channel payload;
  close_out channel;
  let result = ref (Error "upload thread did not finish") in
  let worker =
    Thread.create
      (fun () ->
        result :=
          Logseq_chat_lg_core_native.logseq_chat_http_upload_file
            { request =
                { method_ = "PUT"
                ; url = Printf.sprintf "http://127.0.0.1:%d/assets/graph/file.png" port
                ; body = None
                ; token = "access-token"
                }
            ; file_path
            ; content_type = "image/png"
            ; headers = [ "x-amz-meta-checksum", "abc123"; "x-amz-meta-type", "png" ]
            })
      ()
  in
  let client, _ = Unix.accept server in
  Fun.protect
    ~finally:(fun () ->
      close_quietly client;
      close_quietly server;
      try Sys.remove file_path with _ -> ())
    (fun () ->
      let buffer = Buffer.create 256 in
      let chunk = Bytes.create 1024 in
      let rec read_request () =
        let raw = Buffer.contents buffer in
        if
          find_sub payload raw <> None
          && find_sub "x-amz-meta-checksum: abc123" raw <> None
          && find_sub "PUT /assets/graph/file.png" raw <> None
        then raw
        else (
          match Unix.read client chunk 0 (Bytes.length chunk) with
          | 0 -> raw
          | count ->
            Buffer.add_subbytes buffer chunk 0 count;
            read_request ())
      in
      let request = with_timeout 2 read_request in
      if find_sub payload request = None
      then failwith ("http upload missing body: " ^ request);
      if find_sub ("Content-Length: " ^ string_of_int (String.length payload)) request = None
      then failwith "http upload must report the binary byte length";
      if find_sub "x-amz-meta-checksum: abc123" request = None
      then failwith ("http upload missing checksum header: " ^ request);
      if find_sub "Content-Type: image/png" request = None
      then failwith ("http upload missing content type: " ^ request);
      if find_sub (Printf.sprintf "Host: 127.0.0.1:%d" port) request = None
      then failwith ("http upload missing host port: " ^ request);
      write_string client "HTTP/1.0 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}";
      Thread.join worker;
      match !result with
      | Error message -> failwith ("http upload failed: " ^ message)
      | Ok response ->
        if response.status <> 200
        then failwith ("http upload status: " ^ string_of_int response.status);
        assert_equal "http upload body" "{\"ok\":true}" response.body)
;;

let () =
  let read_fd, write_fd = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      close_quietly read_fd;
      close_quietly write_fd)
    (fun () ->
      write_string
        write_fd
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
      match
        with_timeout 1 (fun () -> Logseq_chat_lg_core_native.logseq_chat_http_read_response read_fd)
      with
      | Error message -> failwith ("chunked decode failed: " ^ message)
      | Ok (_headers, body) -> assert_equal "chunked body" "hello world" body)
;;
