let () =
  let code, message = E2e_seed_cli.run (Array.to_list Sys.argv) in
  if code = 0 then print_endline message else prerr_endline message;
  exit code
