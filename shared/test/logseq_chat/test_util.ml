let check ?(msg = "assertion failed") expected =
  Alcotest.(check bool) msg true expected

let check_eq ?(msg = "values differ") actual expected =
  Alcotest.(check bool) msg true (actual = expected)

let check_error ?(msg = "expected Error") result =
  Alcotest.(check bool) msg true (Result.is_error result)

let fail = Alcotest.fail

let case name f = Alcotest.test_case name `Quick f

let check_ok ?(msg = "expected Ok") result =
  Alcotest.(check bool) msg true (Result.is_ok result)
