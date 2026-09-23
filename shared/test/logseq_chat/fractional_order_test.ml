open Test_util

let value result =
  match result with
  | Ok value -> value
  | Error message -> failwith message

let is_error result = Result.is_error result

let minimum = "A" ^ String.concat "" (List.init 26 (fun _ -> "0"))

let maximum = String.concat "" (List.init 27 (fun _ -> "z"))

let inside lower key upper =
  String.compare lower key < 0
  && String.compare key upper < 0
  && Fractional_order.validate_error key = None

let repeated_insertion () =
  check_eq "0G" (value (Fractional_order.midpoint "" (Some "0V")));
  List.iter
    (fun lower ->
       let rec loop remaining upper =
         if remaining > 0 then begin
           let key =
             value (Fractional_order.between (Some lower) (Some upper))
           in
           check (inside lower key upper);
           loop (remaining - 1) key
         end
       in
       loop 100 (value (Fractional_order.between (Some lower) None)))
    [ "a0"; "a0V"; "Zz" ]

let basic_boundaries () =
  check_eq "a0" (value (Fractional_order.between None None));
  check_eq "a1" (value (Fractional_order.between (Some "a0") None));
  check_eq "a0V"
    (value (Fractional_order.between (Some "a0") (Some "a1")));
  check_eq "Zz" (value (Fractional_order.between None (Some "a0")));
  check_eq [ "a0G"; "a0V"; "a0l" ]
    (value (Fractional_order.n_between (Some "a0") (Some "a1") 3));
  check (is_error (Fractional_order.between (Some "a1") (Some "a0")));
  check (is_error (Fractional_order.between (Some "a00") None))

let integer_validation_and_suffix () =
  check_eq (Ok 2) (Fractional_order.integer_length "a");
  check_eq (Ok 27) (Fractional_order.integer_length "z");
  check_eq (Ok 2) (Fractional_order.integer_length "Z");
  check_eq (Ok 27) (Fractional_order.integer_length "A");
  check (is_error (Fractional_order.integer_length "0"));
  check (is_error (Fractional_order.integer_part ""));
  check (is_error (Fractional_order.integer_part "b0"));
  check_eq "a0" (value (Fractional_order.integer_part "a0V"));
  check_eq "" (Fractional_order.suffix "abc" 3);
  check_eq "" (Fractional_order.suffix "abc" 4);
  check_eq "bc" (Fractional_order.suffix "abc" 1);
  check (Fractional_order.validate_integer_error "a!" <> None);
  check (Fractional_order.validate_integer_error "a0V" <> None);
  check (Fractional_order.validate_error minimum <> None);
  check (Fractional_order.validate_error "a0V0" <> None)

let integer_increment_and_decrement () =
  List.iter
    (fun (input, expected) ->
       check_eq (Ok (Some expected)) (Fractional_order.increment input))
    [
      ("a0", "a1");
      ("aZ", "aa");
      ("az", "b00");
      ("Yzz", "Z0");
      ("Zz", "a0");
    ];
  check_eq (Ok None) (Fractional_order.increment maximum);
  check (is_error (Fractional_order.increment "a!"));
  List.iter
    (fun (input, expected) ->
       check_eq (Ok (Some expected)) (Fractional_order.decrement input))
    [ ("a1", "a0"); ("a0", "Zz"); ("Z0", "Yzz"); ("b00", "az") ];
  check_eq (Ok None) (Fractional_order.decrement minimum);
  check (is_error (Fractional_order.decrement "a!"))

let midpoint_cases () =
  check_eq "V" (value (Fractional_order.midpoint "" None));
  List.iter
    (fun (lower, upper, expected) ->
       check_eq expected
         (value (Fractional_order.midpoint lower (Some upper))))
    [ ("a1", "a3", "a2"); ("a", "a1", "a0V"); ("1", "2", "1V"); ("", "1x", "1") ];
  check (is_error (Fractional_order.midpoint "a" (Some "a")));
  check (is_error (Fractional_order.midpoint "0" None));
  check (is_error (Fractional_order.midpoint "" (Some "10")));
  check (is_error (Fractional_order.midpoint "!" None))

let sentinel_and_fraction_boundaries () =
  check_eq "a0G" (value (Fractional_order.between None (Some "a0V")));
  let upper = minimum ^ "V" in
  let key = value (Fractional_order.between None (Some upper)) in
  check (String.compare key upper < 0);
  check (Fractional_order.validate_error key = None);
  check_eq "a1" (value (Fractional_order.between (Some "a0") (Some "b00")));
  let key = value (Fractional_order.between (Some maximum) None) in
  check (String.compare maximum key < 0);
  check (Fractional_order.validate_error key = None);
  let first_integer = "A" ^ String.concat "" (List.init 25 (fun _ -> "0")) ^ "1" in
  check_eq minimum (value (Fractional_order.between None (Some first_integer)));
  check (is_error (Fractional_order.n_between None (Some first_integer) 2))

let batch_counts_and_order () =
  check (is_error (Fractional_order.n_between None None (-1)));
  check_eq [] (value (Fractional_order.n_between None None 0));
  check_eq [ "a0" ] (value (Fractional_order.n_between None None 1));
  let appended = value (Fractional_order.n_between (Some "a0") None 3) in
  let prepended = value (Fractional_order.n_between None (Some "a0") 3) in
  check_eq appended (List.sort String.compare appended);
  check_eq prepended (List.sort String.compare prepended)

let sampled_bounds () =
  let samples = [ minimum ^ "V"; "Zz"; "a0"; "a0V"; "a1"; "b00"; maximum ] in
  List.iter
    (fun lower ->
       List.iter
         (fun upper ->
            if String.compare lower upper < 0 then
              check
                (inside lower
                   (value
                      (Fractional_order.between (Some lower) (Some upper)))
                   upper))
         samples)
    samples

let logseq_pinned_golden_vectors () =
  check_eq
    [
      "a0"; "a1"; "a2"; "a3"; "a4"; "a5"; "a6"; "a7"; "a8"; "a9";
      "aA"; "aB"; "aC"; "aD"; "aE"; "aF"; "aG"; "aH"; "aI"; "aJ";
    ]
    (value (Fractional_order.n_between None None 20));
  check_eq
    [
      "c0Zj"; "c0Zk"; "c0Zl"; "c0Zm"; "c0Zn"; "c0Zo"; "c0Zp"; "c0Zq";
      "c0Zr"; "c0Zs"; "c0Zt"; "c0Zu"; "c0Zv"; "c0Zw"; "c0Zx"; "c0Zy";
      "c0Zz"; "c0a0"; "c0a1"; "c0a2";
    ]
    (value (Fractional_order.n_between None (Some "c0a3") 20));
  check_eq
    [
      "ZxX"; "ZxZ"; "Zxd"; "Zxf"; "Zxh"; "Zxl"; "Zxn"; "Zxp"; "Zxt";
      "Zxx"; "Zy"; "Zy0V"; "Zy1"; "Zy2"; "Zy3"; "Zy4"; "Zy4V"; "Zy5";
      "Zy6"; "Zy6V";
    ]
    (value (Fractional_order.n_between (Some "ZxV") (Some "Zy7") 20));
  check_eq
    [
      "ZyB"; "ZyE"; "ZyL"; "ZyP"; "ZyS"; "ZyZ"; "Zyd"; "Zyg"; "Zyn";
      "Zyu"; "Zz"; "Zz8"; "ZzG"; "ZzV"; "Zzl"; "a0"; "a0G"; "a0V";
      "a1"; "a2";
    ]
    (value (Fractional_order.n_between (Some "Zy7") (Some "axV") 20));
  check_eq
    [
      "c0a4"; "c0a5"; "c0a6"; "c0a7"; "c0a8"; "c0a9"; "c0aA"; "c0aB";
      "c0aC"; "c0aD"; "c0aE"; "c0aF"; "c0aG"; "c0aH"; "c0aI"; "c0aJ";
      "c0aK"; "c0aL"; "c0aM"; "c0aN";
    ]
    (value (Fractional_order.n_between (Some "c0a3") None 20))

let cases =
  [
    case "repeated insertion" repeated_insertion;
    case "basic boundaries" basic_boundaries;
    case "integer validation and suffix" integer_validation_and_suffix;
    case "integer increment and decrement" integer_increment_and_decrement;
    case "midpoint cases" midpoint_cases;
    case "sentinel and fraction boundaries" sentinel_and_fraction_boundaries;
    case "batch counts and order" batch_counts_and_order;
    case "sampled bounds" sampled_bounds;
    case "logseq pinned golden vectors" logseq_pinned_golden_vectors;
  ]
