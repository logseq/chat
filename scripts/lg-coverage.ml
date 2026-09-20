open Parsetree

let with_input path f =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr input) (fun () -> f input)

let integer input =
  if input_char input <> ' ' then failwith "invalid coverage separator";
  let buffer = Buffer.create 16 in
  let rec digits () =
    match input_char input with
    | '0' .. '9' as digit -> Buffer.add_char buffer digit; digits ()
    | ' ' -> seek_in input (pos_in input - 1)
    | _ -> failwith "invalid coverage integer"
    | exception End_of_file -> ()
  in
  digits ();
  int_of_string (Buffer.contents buffer)

let string input =
  let length = integer input in
  if input_char input <> ' ' then failwith "invalid filename separator";
  really_input_string input length

let array input =
  let length = integer input in
  Array.init length (fun _ -> integer input)

let production_ranges source prefix =
  with_input source (fun input ->
    let lexer = Lexing.from_channel input in
    Location.init lexer source;
    Parse.implementation lexer
    |> List.concat_map (fun item ->
         match item.pstr_desc with
         | Pstr_value (_, bindings) ->
             List.filter_map (fun binding ->
               match binding.pvb_pat.ppat_desc with
               | Ppat_var { txt = name; _ }
                 when String.starts_with ~prefix name
                      && not (String.starts_with ~prefix:(prefix ^ "test_") name) ->
                   Some (binding.pvb_loc.loc_start.pos_cnum,
                         binding.pvb_loc.loc_end.pos_cnum)
               | _ -> None) bindings
         | _ -> []))

let check source filename prefix floor coverage =
  if floor < 0 || floor > 10000 then failwith "invalid coverage floor";
  let ranges = production_ranges source prefix in
  if ranges = [] then failwith "no matching production definitions";
  let visited = ref 0 and total = ref 0 and found = ref false in
  with_input coverage (fun input ->
    let magic = "BISECT-COVERAGE-4" in
    if really_input_string input (String.length magic) <> magic then
      failwith "unsupported Bisect coverage format";
    let files = integer input in
    for _ = 1 to files do
      let current = string input in
      let points = array input in
      let counts = array input in
      if Array.length points <> Array.length counts then
        failwith "inconsistent coverage point/count arrays";
      if current = filename then begin
        if !found then failwith "coverage must be merged before checking";
        found := true;
        Array.iteri (fun index point ->
          if List.exists (fun (first, last) -> first <= point && point < last) ranges then begin
            incr total;
            if counts.(index) > 0 then incr visited
          end) points
      end
    done);
  if not !found then failwith ("missing coverage for " ^ filename);
  if !total = 0 then failwith "no production instrumentation points";
  Printf.printf "%s generated execution points: %d/%d (%.2f%%), floor %.2f%%\n%!"
    prefix !visited !total (100. *. float !visited /. float !total)
    (float floor /. 100.);
  if !visited * 10000 < floor * !total then failwith "coverage below floor"

let () =
  try
    if Array.length Sys.argv <> 6 then
      failwith "usage: lg-coverage SOURCE COVERAGE_FILENAME PREFIX BASIS_POINTS COVERAGE";
    check Sys.argv.(1) Sys.argv.(2) Sys.argv.(3)
      (int_of_string Sys.argv.(4)) Sys.argv.(5)
  with error ->
    Printf.eprintf "error: %s\n" (Printexc.to_string error);
    exit 1
