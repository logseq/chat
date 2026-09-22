module S = String_kit

let digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
let zero = "0"
let lowercase = "abcdefghijklmnopqrstuvwxyz"
let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

type digit_run =
  { digit_run_value : string
  ; digit_run_carried : bool
  }

let char_at value index = String.sub value index 1

let suffix value offset =
  if offset >= String.length value then ""
  else String.sub value offset (String.length value - offset)

let repeat_string value times =
  let rec loop index result =
    if index = times then result else loop (index + 1) (result ^ value)
  in
  loop 0 ""

let minimum = "A00000000000000000000000000"

let index_of_in values target =
  let rec loop index =
    if index = String.length values then None
    else if char_at values index = target then Some index
    else loop (index + 1)
  in
  loop 0

let index_of character = index_of_in digits character
let digit_at index = char_at digits index

let adjacent_head head offset =
  match index_of head with
  | Some index ->
    let next = index + offset in
    if next >= 0 && next < String.length digits then Some (digit_at next)
    else None
  | None -> None

let integer_length head =
  match index_of_in lowercase head with
  | Some index -> Ok (index + 2)
  | None ->
    (match index_of_in uppercase head with
     | Some index ->
       Ok (String.length uppercase - 1 - index + 2)
     | None -> Error "invalid order key head")

let integer_part key =
  let ( let* ) = Result.bind in
  if key = "" then Error "empty order key"
  else
    let* length = integer_length (char_at key 0) in
    if String.length key < length then Error "invalid integer part of order key"
    else Ok (String.sub key 0 length)

let validate_integer_error value =
  match integer_part value with
  | Ok integer ->
    let all_digits =
      let rec loop index =
        if index = String.length integer then true
        else
          match index_of (char_at integer index) with
          | Some _ -> loop (index + 1)
          | None -> false
      in
      loop 1
    in
    if String.length integer = String.length value && all_digits then None
    else Some "invalid integer part of order key"
  | Error message -> Some message

let validate_error key =
  match integer_part key with
  | Ok integer ->
    let fraction = suffix key (String.length integer) in
    if
      key = minimum
      || (fraction <> "" && char_at fraction (String.length fraction - 1) = zero)
    then Some "invalid order key"
    else None
  | Error message -> Some message

let set_char value index character =
  String.sub value 0 index ^ character ^ suffix value (index + 1)

let digit_run value carried = { digit_run_value = value; digit_run_carried = carried }

let rec increment_digit_run value index =
  if index = 0 then digit_run value true
  else
    match index_of (char_at value index) with
    | Some digit ->
      if digit + 1 = String.length digits then
        increment_digit_run (set_char value index zero) (index - 1)
      else digit_run (set_char value index (digit_at (digit + 1))) false
    | None -> digit_run value true

let increment value =
  match validate_integer_error value with
  | Some message -> Error message
  | None ->
    let run = increment_digit_run value (String.length value - 1) in
    let head = char_at value 0 in
    if not run.digit_run_carried then Ok (Some run.digit_run_value)
    else if head = "Z" then Ok (Some "a0")
    else if head = "z" then Ok None
    else
      (match adjacent_head head 1 with
       | Some next_head ->
         let tail = suffix run.digit_run_value 1 in
         let new_tail =
           if index_of_in lowercase next_head = None then
             String.sub tail 0 (String.length tail - 1)
           else tail ^ zero
         in
         Ok (Some (next_head ^ new_tail))
       | None -> Error "invalid order key head")

let rec decrement_digit_run value index =
  if index = 0 then digit_run value true
  else
    match index_of (char_at value index) with
    | Some digit ->
      if digit = 0 then
        decrement_digit_run
          (set_char value index (digit_at (String.length digits - 1)))
          (index - 1)
      else digit_run (set_char value index (digit_at (digit - 1))) false
    | None -> digit_run value true

let decrement value =
  match validate_integer_error value with
  | Some message -> Error message
  | None ->
    let run = decrement_digit_run value (String.length value - 1) in
    let head = char_at value 0 in
    if not run.digit_run_carried then Ok (Some run.digit_run_value)
    else if head = "a" then Ok (Some "Zz")
    else if head = "A" then Ok None
    else
      (match adjacent_head head (-1) with
       | Some next_head ->
         let tail = suffix run.digit_run_value 1 in
         let new_tail =
           if index_of_in uppercase next_head = None then
             String.sub tail 0 (String.length tail - 1)
           else tail ^ digit_at (String.length digits - 1)
         in
         Ok (Some (next_head ^ new_tail))
       | None -> Error "invalid order key head")

let invalid_lower_upper lower upper =
  match upper with
  | Some upper -> String.compare lower upper >= 0
  | None -> false

let trailing_zero value =
  value <> "" && char_at value (String.length value - 1) = zero

let midpoint_shared_prefix lower upper =
  let rec loop index =
    if index = String.length upper then index
    else
      let lower_character =
        if index < String.length lower then char_at lower index else zero
      in
      if lower_character = char_at upper index then loop (index + 1)
      else index
  in
  loop 0

let string_less lower upper = String.compare lower upper < 0

let rec midpoint lower upper =
  if invalid_lower_upper lower upper then Error "invalid midpoint bounds"
  else if
    trailing_zero lower
    || (match upper with Some u -> trailing_zero u | None -> false)
  then Error "midpoint has trailing zero"
  else
    let shared =
      match upper with
      | Some upper -> midpoint_shared_prefix lower upper
      | None -> 0
    in
    if shared > 0 then
      match upper with
      | Some upper ->
        let ( let* ) = Result.bind in
        let* rest =
          midpoint (suffix lower shared) (Some (suffix upper shared))
        in
        Ok (String.sub upper 0 shared ^ rest)
      | None -> Error "invalid midpoint bounds"
    else
      match
        ( (if lower = "" then Some 0 else index_of (char_at lower 0))
        , (match upper with
           | Some upper -> index_of (char_at upper 0)
           | None -> Some (String.length digits)) )
      with
      | Some lower_digit, Some upper_digit ->
        if upper_digit - lower_digit > 1 then
          Ok (digit_at ((lower_digit + upper_digit + 1) / 2))
        else if
          (match upper with Some u -> String.length u | None -> 0) > 1
        then
          Ok (String.sub (match upper with Some u -> u | None -> "") 0 1)
        else
          let ( let* ) = Result.bind in
          let* rest = midpoint (suffix lower 1) None in
          Ok (digit_at lower_digit ^ rest)
      | _ -> Error "invalid fractional digit"

let validate_optional_error value =
  match value with Some value -> validate_error value | None -> None

let optional_lower_fails lower value =
  match lower with
  | Some lower_value -> not (string_less lower_value value)
  | None -> false

let optional_upper_fails value upper =
  match upper with
  | Some upper_value -> not (string_less value upper_value)
  | None -> false

let optional_string_or_error value fallback =
  let ( let* ) = Result.bind in
  let* value = value in
  match value with Some value -> Ok value | None -> Error fallback

let optional_string_or_midpoint value integer fraction =
  let ( let* ) = Result.bind in
  let* value = value in
  match value with
  | Some value -> Ok value
  | None ->
    let* middle = midpoint fraction None in
    Ok (integer ^ middle)

let prepend_string_result prefix result =
  let ( let* ) = Result.bind in
  let* value = result in
  Ok (prefix ^ value)

let before_upper_or_midpoint value upper_value lower_integer lower_fraction =
  let ( let* ) = Result.bind in
  let* value = value in
  match
    match value with
    | Some value when string_less value upper_value -> Some value
    | _ -> None
  with
  | Some value -> Ok value
  | None -> prepend_string_result lower_integer (midpoint lower_fraction None)

let between_before_upper upper_value integer =
  let fraction = suffix upper_value (String.length integer) in
  if integer = minimum || string_less integer upper_value then
    prepend_string_result integer (midpoint "" (Some fraction))
  else optional_string_or_error (decrement integer) "cannot decrement order key"

let between_after_lower lower_value integer =
  let fraction = suffix lower_value (String.length integer) in
  optional_string_or_midpoint (increment integer) integer fraction

let between_shared_integers lower_integer lower_fraction upper_fraction =
  prepend_string_result lower_integer
    (midpoint lower_fraction (Some upper_fraction))

let between_different_integers upper_value lower_integer lower_fraction =
  before_upper_or_midpoint (increment lower_integer) upper_value lower_integer
    lower_fraction

let between_core lower upper =
  let ( let* ) = Result.bind in
  match (lower, upper) with
  | None, None -> Ok "a0"
  | None, Some upper ->
    let* integer = integer_part upper in
    between_before_upper upper integer
  | Some lower, None ->
    let* integer = integer_part lower in
    between_after_lower lower integer
  | Some lower, Some upper ->
    let* lower_integer = integer_part lower in
    let* upper_integer = integer_part upper in
    let lower_fraction = suffix lower (String.length lower_integer) in
    let upper_fraction = suffix upper (String.length upper_integer) in
    if lower_integer = upper_integer then
      between_shared_integers lower_integer lower_fraction upper_fraction
    else between_different_integers upper lower_integer lower_fraction

let between lower upper =
  match
    match validate_optional_error lower with
    | Some message -> Some message
    | None -> validate_optional_error upper
  with
  | Some message -> Error message
  | None ->
    if
      (match lower with
       | Some lower -> invalid_lower_upper lower upper
       | None -> false)
    then Error "invalid order bounds"
    else
      let ( let* ) = Result.bind in
      let* value = between_core lower upper in
      if optional_lower_fails lower value || optional_upper_fails value upper
      then Error "generate-key-between failed"
      else Ok value

let n_after lower count =
  let ( let* ) = Result.bind in
  let rec loop lower remaining result =
    if remaining = 0 then Ok (List.rev result)
    else
      let* value = between lower None in
      loop (Some value) (remaining - 1) (value :: result)
  in
  loop lower count []

let n_before upper count =
  let ( let* ) = Result.bind in
  let rec loop upper remaining result =
    if remaining = 0 then Ok result
    else
      let* value = between None upper in
      loop (Some value) (remaining - 1) (value :: result)
  in
  loop upper count []

let rec n_between lower upper count =
  let ( let* ) = Result.bind in
  if count < 0 then Error "order key count must not be negative"
  else if count = 0 then Ok []
  else if count = 1 then
    let* value = between lower upper in
    Ok [ value ]
  else
    match upper with
    | None -> n_after lower count
    | Some _ ->
      (match lower with
       | None -> n_before upper count
       | Some _ ->
         let left_count = count / 2 in
         let* middle = between lower upper in
         let* left = n_between lower (Some middle) left_count in
         let* right = n_between (Some middle) upper (count - left_count - 1) in
         Ok (left @ [ middle ] @ right))
