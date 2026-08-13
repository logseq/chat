let assert_bool label value =
  if not value then failwith label
;;

let assert_equal label expected actual =
  if not (String.equal expected actual)
  then
    failwith
      (Printf.sprintf "%s: expected %S, got %S" label expected actual)
;;

let with_temp_db f =
  let path = Filename.temp_file "logseq-chat-sqlite-test" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)
;;

let () =
  with_temp_db (fun path ->
    let first_session = Logseq_chat_sqlite.open_session path in
    let first_model =
      Logseq_chat_model.create ~storage:(Logseq_chat_sqlite.storage first_session) ()
    in
    Logseq_chat_model.cache_local_message
      first_model
      ~uuid:"local-persisted"
      ~title:"Persisted offline capture"
      ~now:1_776_000_000_000;
    Logseq_chat_sqlite.close first_session;

    let second_session = Logseq_chat_sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_sqlite.close second_session)
      (fun () ->
        let restored_model =
          Logseq_chat_model.create ~storage:(Logseq_chat_sqlite.storage second_session) ()
        in
        match Logseq_chat_model.read_block restored_model "local-persisted" with
        | None -> failwith "expected persisted block after reopening SQLite storage"
        | Some block ->
          assert_equal "title" "Persisted offline capture" block.title;
          assert_equal "sync status" "pending" block.sync_status;
          assert_bool
            "journal page id should be persisted"
            (String.length block.page_id >= 8
             && String.equal (String.sub block.page_id 0 8) "journal/")))
;;
