let () =
  if Array.length Sys.argv < 2 || Array.length Sys.argv > 3
  then (
    prerr_endline
      "usage: logseq_chat_e2e_seed <graph.sqlite> [--inspect|--header-navigation|--composer|--outliner|--fixture|--performance]";
    exit 2);
  let path = Sys.argv.(1) in
  let seed =
    if Array.length Sys.argv = 3
    then
      match Sys.argv.(2) with
      | "--inspect" -> (fun _conn -> Ok ())
      | "--header-navigation" -> Logseq_chat_e2e_seed_data.seed_header_navigation
      | "--composer" ->
        (fun conn ->
          Logseq_chat_e2e_seed_data.seed_composer
            conn
            ~now:(int_of_float (Unix.gettimeofday () *. 1000.0)))
      | "--outliner" ->
        (fun conn ->
          Logseq_chat_e2e_seed_data.seed_outliner
            conn
            ~now:(int_of_float (Unix.gettimeofday () *. 1000.0)))
      | "--fixture" -> Logseq_chat_e2e_seed_data.seed_fixture
      | "--performance" ->
        (fun conn ->
          Logseq_chat_e2e_seed_data.seed_performance
            conn
            ~now:(int_of_float (Unix.gettimeofday () *. 1000.0)))
      | mode ->
        prerr_endline ("unknown seed mode: " ^ mode);
        exit 2
    else Logseq_chat_e2e_seed_data.seed
  in
  match Logseq_chat_graph_store.restore_conn ~path with
  | Error message ->
    prerr_endline message;
    exit 1
  | Ok conn ->
    (match seed conn with
     | Ok () ->
       (match Logseq_chat_graph_store.restore_db ~path with
        | Error message ->
          prerr_endline message;
          exit 1
        | Ok db ->
          let blocks = Logseq_chat_graph_read.blocks db in
          let favorites = (Logseq_chat_graph_read.sidebar_pages db).favorites in
          let due_flashcards =
            Logseq_chat_flashcards.due_cards db ~now:(Int64.to_int (Int64.of_float (Unix.gettimeofday () *. 1000.)))
          in
          let projected_due_flashcards =
            if Array.length Sys.argv = 3 && String.equal Sys.argv.(2) "--inspect"
            then
              let snapshot =
                Logseq_chat_pending_projection.build
                  ~server_t:1
                  db
                  (Logseq_chat_pending_ops.list ~path)
              in
              Logseq_chat_flashcards.due_cards
                snapshot.db
                ~now:(Int64.to_int (Int64.of_float (Unix.gettimeofday () *. 1000.)))
            else due_flashcards
          in
          Printf.printf
            "Seeded iOS E2E graph: %s journals=%d visible-blocks=%d favorites=%d due-flashcards=%d projected-due-flashcards=%d\n"
            path
            (Logseq_chat_graph_read.journal_page_count db)
            (List.length blocks)
            (List.length favorites)
            (List.length due_flashcards)
            (List.length projected_due_flashcards))
     | Error message ->
       prerr_endline message;
       exit 1)
;;
