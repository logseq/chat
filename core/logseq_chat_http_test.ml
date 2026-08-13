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
        with_timeout 1 (fun () -> Logseq_chat_http.read_response read_fd)
      with
      | Error message -> failwith message
	 | Ok (headers, body) ->
	   assert_equal "response body" "{}" body;
	   assert_equal "status headers" "HTTP/1.1 200 OK" (String.sub headers 0 15))
;;

let () =
  match
    Logseq_chat_http.send
      { Logseq_chat_api.method_ = "GET"
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
