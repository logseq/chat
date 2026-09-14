module LG = Logseq_chat_lg_core_native

module Order = struct
  let integer_length value =
    LG.logseq_chat_fractional_order_integer_length (String.make 1 value)
  ;;

  let integer_part = LG.logseq_chat_fractional_order_integer_part
  let suffix = LG.logseq_chat_fractional_order_suffix

  let validate_integer value =
    match LG.logseq_chat_fractional_order_validate_integer_error value with
    | None -> Ok ()
    | Some message -> Error message
  ;;

  let validate value =
    match LG.logseq_chat_fractional_order_validate_error value with
    | None -> Ok ()
    | Some message -> Error message
  ;;

  let increment = LG.logseq_chat_fractional_order_increment
  let decrement = LG.logseq_chat_fractional_order_decrement
  let midpoint = LG.logseq_chat_fractional_order_midpoint
  let between = LG.logseq_chat_fractional_order_between

  let n_between lower upper count =
    Result.map Rrbvec.to_list (LG.logseq_chat_fractional_order_n_between lower upper count)
  ;;
end

let assert_equal label expected actual =
  if not (String.equal expected actual)
  then failwith (Printf.sprintf "%s: expected %s, got %s" label expected actual)
;;

let assert_list label expected actual =
  if expected <> actual then failwith (label ^ ": order keys differ")
;;

let assert_bool label value = if not value then failwith label

let expect_ok label = function Ok value -> value | Error message -> failwith (label ^ ": " ^ message)
let expect_error label = function Error _ -> () | Ok _ -> failwith (label ^ ": expected an error")

let () =
  assert_equal "midpoint pads an empty lower fraction" "0G"
    (expect_ok "zero-prefix midpoint" (Order.midpoint "" (Some "0V")));
  List.iter (fun lower ->
    let rec insert count upper =
      if count > 0 then (
        let key = expect_ok "repeated insertion" (Order.between (Some lower) (Some upper)) in
        assert_bool "each insertion remains valid" (Order.validate key = Ok ());
        assert_bool "each insertion stays between adjacent blocks"
          (String.compare lower key < 0 && String.compare key upper < 0);
        insert (count - 1) key)
    in
    insert 100 (expect_ok "upper bound" (Order.between (Some lower) None)))
    [ "a0"; "a0V"; "Zz" ]
;;

let () =
  assert_equal "empty bounds" "a0" (expect_ok "empty bounds" (Order.between None None));
  assert_equal "append" "a1" (expect_ok "append" (Order.between (Some "a0") None));
  assert_equal "middle" "a0V" (expect_ok "middle" (Order.between (Some "a0") (Some "a1")));
  assert_equal "prepend" "Zz" (expect_ok "prepend" (Order.between None (Some "a0")));
  assert_list
    "three keys"
    [ "a0G"; "a0V"; "a0l" ]
    (expect_ok "three keys" (Order.n_between (Some "a0") (Some "a1") 3));
  (match Order.between (Some "a1") (Some "a0") with
   | Error _ -> ()
   | Ok _ -> failwith "reversed bounds must fail");
  (match Order.between (Some "a00") None with
   | Error _ -> ()
   | Ok _ -> failwith "trailing zero must fail")
;;

let () =
  expect_error "integer characters must use the base-62 alphabet"
    (Order.validate_integer "a!")
;;

let assert_option label expected actual =
  if expected <> actual then failwith (label ^ ": unexpected optional order key")
;;

let () =
  assert_bool "lowercase integer heads grow to the right"
    (Order.integer_length 'a' = Ok 2 && Order.integer_length 'z' = Ok 27);
  assert_bool "uppercase integer heads grow to the left"
    (Order.integer_length 'Z' = Ok 2 && Order.integer_length 'A' = Ok 27);
  expect_error "invalid integer head" (Order.integer_length '0');
  expect_error "empty integer key" (Order.integer_part "");
  expect_error "truncated integer key" (Order.integer_part "b0");
  assert_equal "integer part" "a0" (expect_ok "integer part" (Order.integer_part "a0V"));
  assert_equal "suffix at end" "" (Order.suffix "abc" 3);
  assert_equal "suffix after end" "" (Order.suffix "abc" 4);
  assert_equal "suffix middle" "bc" (Order.suffix "abc" 1);
  expect_error "integer key cannot contain a fraction" (Order.validate_integer "a0V");
  expect_error "minimum sentinel is not a user key"
    (Order.validate ("A" ^ String.make 26 '0'));
  expect_error "fraction cannot end in zero" (Order.validate "a0V0")
;;

let () =
  assert_option "increment digit" (Ok (Some "a1")) (Order.increment "a0");
  assert_option "increment alphabet transition" (Ok (Some "aa")) (Order.increment "aZ");
  assert_option "increment integer width" (Ok (Some "b00")) (Order.increment "az");
  assert_option "increment uppercase width" (Ok (Some "Z0")) (Order.increment "Yzz");
  assert_option "increment uppercase boundary" (Ok (Some "a0")) (Order.increment "Zz");
  assert_option "increment maximum" (Ok None) (Order.increment (String.make 27 'z'));
  expect_error "increment rejects invalid digits" (Order.increment "a!");
  assert_option "decrement digit" (Ok (Some "a0")) (Order.decrement "a1");
  assert_option "decrement lowercase boundary" (Ok (Some "Zz")) (Order.decrement "a0");
  assert_option "decrement uppercase width" (Ok (Some "Yzz")) (Order.decrement "Z0");
  assert_option "decrement lowercase width" (Ok (Some "az")) (Order.decrement "b00");
  assert_option "decrement minimum" (Ok None)
    (Order.decrement ("A" ^ String.make 26 '0'));
  expect_error "decrement rejects invalid digits" (Order.decrement "a!")
;;

let () =
  assert_equal "unbounded midpoint" "V" (expect_ok "midpoint" (Order.midpoint "" None));
  assert_equal "shared midpoint" "a2"
    (expect_ok "shared midpoint" (Order.midpoint "a1" (Some "a3")));
  assert_equal "prefix midpoint" "a0V"
    (expect_ok "prefix midpoint" (Order.midpoint "a" (Some "a1")));
  assert_equal "adjacent midpoint" "1V"
    (expect_ok "adjacent midpoint" (Order.midpoint "1" (Some "2")));
  assert_equal "upper prefix midpoint" "1"
    (expect_ok "upper prefix midpoint" (Order.midpoint "" (Some "1x")));
  expect_error "midpoint bounds must increase" (Order.midpoint "a" (Some "a"));
  expect_error "midpoint lower cannot trail zero" (Order.midpoint "0" None);
  expect_error "midpoint upper cannot trail zero" (Order.midpoint "" (Some "10"));
  expect_error "midpoint rejects invalid digits" (Order.midpoint "!" None)
;;

let () =
  assert_equal "prepend before a fractional key" "a0G"
    (expect_ok "prepend fraction" (Order.between None (Some "a0V")));
  let minimum = "A" ^ String.make 26 '0' in
  let before_minimum_fraction =
    expect_ok "prepend minimum fraction" (Order.between None (Some (minimum ^ "V")))
  in
  assert_bool "prepend before a minimum fraction stays valid"
    (String.compare before_minimum_fraction (minimum ^ "V") < 0
     && Order.validate before_minimum_fraction = Ok ());
  assert_equal "advance to the next integer" "a1"
    (expect_ok "integer gap" (Order.between (Some "a0") (Some "b00")));
  let maximum = String.make 27 'z' in
  let after_maximum = expect_ok "append maximum" (Order.between (Some maximum) None) in
  assert_bool "append after maximum uses a valid fraction"
    (String.compare maximum after_maximum < 0 && Order.validate after_maximum = Ok ());
  let first_integer = "A" ^ String.make 25 '0' ^ "1" in
  let before_first = expect_ok "prepend first integer" (Order.between None (Some first_integer)) in
  assert_equal "prepend minimum integer matches Logseq's boundary behavior"
    minimum before_first;
  expect_error "Logseq rejects reusing the minimum sentinel"
    (Order.n_between None (Some first_integer) 2)
;;

let () =
  expect_error "negative key count" (Order.n_between None None (-1));
  assert_list "zero keys" [] (expect_ok "zero keys" (Order.n_between None None 0));
  assert_list "one key" [ "a0" ] (expect_ok "one key" (Order.n_between None None 1));
  let appended = expect_ok "append keys" (Order.n_between (Some "a0") None 3) in
  assert_bool "append keys are ordered" (appended = List.sort String.compare appended);
  let prepended = expect_ok "prepend keys" (Order.n_between None (Some "a0") 3) in
  assert_bool "prepend keys are ordered" (prepended = List.sort String.compare prepended)
;;

let () =
  let minimum = "A" ^ String.make 26 '0' in
  let samples =
    [ minimum ^ "V"
    ; "Zz"
    ; "a0"
    ; "a0V"
    ; "a1"
    ; "b00"
    ; String.make 27 'z'
    ]
  in
  List.iter
    (fun lower ->
      List.iter
        (fun upper ->
          if String.compare lower upper < 0
          then (
            let result = expect_ok "sample bounds" (Order.between (Some lower) (Some upper)) in
            assert_bool "generated sample key stays strictly inside bounds"
              (String.compare lower result < 0
               && String.compare result upper < 0
               && Order.validate result = Ok ())))
        samples)
    samples
;;

(* Golden vectors from the exact clj-fractional-indexing revision pinned by Logseq. *)
let () =
  assert_list "Logseq batch vector 0"
    [ "a0"; "a1"; "a2"; "a3"; "a4"; "a5"; "a6"; "a7"; "a8"; "a9"; "aA"; "aB"; "aC"; "aD"; "aE"; "aF"; "aG"; "aH"; "aI"; "aJ" ]
    (expect_ok "Logseq batch parity" (Order.n_between None None 20));
  assert_list "Logseq batch vector 1"
    [ "c0Zj"; "c0Zk"; "c0Zl"; "c0Zm"; "c0Zn"; "c0Zo"; "c0Zp"; "c0Zq"; "c0Zr"; "c0Zs"; "c0Zt"; "c0Zu"; "c0Zv"; "c0Zw"; "c0Zx"; "c0Zy"; "c0Zz"; "c0a0"; "c0a1"; "c0a2" ]
    (expect_ok "Logseq batch parity" (Order.n_between None (Some "c0a3") 20));
  assert_list "Logseq batch vector 2"
    [ "ZxX"; "ZxZ"; "Zxd"; "Zxf"; "Zxh"; "Zxl"; "Zxn"; "Zxp"; "Zxt"; "Zxx"; "Zy"; "Zy0V"; "Zy1"; "Zy2"; "Zy3"; "Zy4"; "Zy4V"; "Zy5"; "Zy6"; "Zy6V" ]
    (expect_ok "Logseq batch parity" (Order.n_between (Some "ZxV") (Some "Zy7") 20));
  assert_list "Logseq batch vector 3"
    [ "ZyB"; "ZyE"; "ZyL"; "ZyP"; "ZyS"; "ZyZ"; "Zyd"; "Zyg"; "Zyn"; "Zyu"; "Zz"; "Zz8"; "ZzG"; "ZzV"; "Zzl"; "a0"; "a0G"; "a0V"; "a1"; "a2" ]
    (expect_ok "Logseq batch parity" (Order.n_between (Some "Zy7") (Some "axV") 20));
  assert_list "Logseq batch vector 4"
    [ "c0a4"; "c0a5"; "c0a6"; "c0a7"; "c0a8"; "c0a9"; "c0aA"; "c0aB"; "c0aC"; "c0aD"; "c0aE"; "c0aF"; "c0aG"; "c0aH"; "c0aI"; "c0aJ"; "c0aK"; "c0aL"; "c0aM"; "c0aN" ]
    (expect_ok "Logseq batch parity" (Order.n_between (Some "c0a3") None 20))
;;
