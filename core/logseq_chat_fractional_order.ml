module LG = Logseq_chat_lg_core_native

let digits = LG.logseq_chat_fractional_order_digits
let zero = LG.logseq_chat_fractional_order_zero.[0]
let option_exists predicate = function Some value -> predicate value | None -> false
let char_string character = String.make 1 character
let index_of character = LG.logseq_chat_fractional_order_index_of (char_string character)

let integer_length character =
  match LG.logseq_chat_fractional_order_integer_length (char_string character) with
  | LG.OrderIntOk value -> Ok value
  | LG.OrderIntError message -> Error message
;;

let string_result = function
  | LG.OrderStringOk value -> Ok value
  | LG.OrderStringError message -> Error message
;;

let optional_string_result = function
  | LG.OrderOptionalStringOk value -> Ok value
  | LG.OrderOptionalStringError message -> Error message
;;

let integer_part key = string_result (LG.logseq_chat_fractional_order_integer_part key)
let suffix value offset = LG.logseq_chat_fractional_order_suffix value offset

let validate_integer value =
  match LG.logseq_chat_fractional_order_validate_integer_error value with
  | None -> Ok ()
  | Some message -> Error message
;;

let validate key =
  match LG.logseq_chat_fractional_order_validate_error key with
  | None -> Ok ()
  | Some message -> Error message
;;

let increment value = optional_string_result (LG.logseq_chat_fractional_order_increment value)
let decrement value = optional_string_result (LG.logseq_chat_fractional_order_decrement value)
let midpoint lower upper = string_result (LG.logseq_chat_fractional_order_midpoint lower upper)
let between lower upper = string_result (LG.logseq_chat_fractional_order_between lower upper)

let n_between lower upper count =
  match LG.logseq_chat_fractional_order_n_between lower upper count with
  | LG.OrderStringVectorOk values -> Ok (Rrbvec.to_list values)
  | LG.OrderStringVectorError message -> Error message
;;
