let () =
  if Array.length Sys.argv <> 2
  then (
    prerr_endline "usage: logseq_chat_e2e_seed <graph.sqlite>";
    exit 2);
  let path = Sys.argv.(1) in
  match Logseq_chat_graph_store.restore_conn ~path with
  | Error message ->
    prerr_endline message;
    exit 1
  | Ok conn ->
    (match Logseq_chat_e2e_seed_data.seed conn with
     | Ok () ->
       (match Logseq_chat_graph_store.restore_db ~path with
        | Error message ->
          prerr_endline message;
          exit 1
        | Ok db ->
          let blocks = Logseq_chat_graph_read.blocks db in
          Printf.printf
            "Seeded iOS E2E graph: %s journals=%d visible-blocks=%d\n"
            path
            (Logseq_chat_graph_read.journal_page_count db)
            (List.length blocks))
     | Error message ->
       prerr_endline message;
       exit 1)
;;
