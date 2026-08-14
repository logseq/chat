let assert_equal label expected actual =
  if not (String.equal expected actual)
  then failwith (Printf.sprintf "%s: expected %S, got %S" label expected actual)
;;

let () =
  let parser = Logseq_chat_sse.create () in
  let first =
    Logseq_chat_sse.feed parser ": connected\r\nid: 4\r\nevent: graph-cha"
  in
  if first <> [] then failwith "partial SSE input must not emit an event";
  let second =
    Logseq_chat_sse.feed
      parser
      "nges\r\ndata: [\"^ \",\"~:t\",4]\r\n\r\n: heartbeat\n\n"
  in
  match second with
  | [ frame ] ->
    assert_equal "event" "graph-changes" frame.event;
    assert_equal "id" "4" (Option.value ~default:"" frame.id);
    assert_equal "data" "[\"^ \",\"~:t\",4]" frame.data
  | _ -> failwith "expected one complete SSE frame"
;;

let () =
  let parser = Logseq_chat_sse.create () in
  match Logseq_chat_sse.feed parser "event: reset\ndata: first\ndata: second\n\n" with
  | [ frame ] -> assert_equal "multiline data" "first\nsecond" frame.data
  | _ -> failwith "expected one multiline SSE frame"
;;
