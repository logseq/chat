let () =
  let code, message =
    Logseq_chat_lg_core_native.logseq_chat_e2e_seed_cli_run (Array.to_seq, Sys.argv)
  in
  if code = 0 then print_endline message else prerr_endline message;
  exit code
