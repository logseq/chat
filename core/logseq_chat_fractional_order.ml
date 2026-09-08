(* Base-62 port of logseq/clj-fractional-indexing at
   1087f0fb18aa8e25ee3bbbb0db983b7a29bce270, as pinned by Logseq. *)
let digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
let zero = digits.[0]
let option_exists predicate = function Some value -> predicate value | None -> false

let index_of character =
  let rec loop index =
    if index = String.length digits
    then None
    else if Char.equal digits.[index] character
    then Some index
    else loop (index + 1)
  in
  loop 0
;;

let integer_length = function
  | head when head >= 'a' && head <= 'z' -> Ok (Char.code head - Char.code 'a' + 2)
  | head when head >= 'A' && head <= 'Z' -> Ok (Char.code 'Z' - Char.code head + 2)
  | _ -> Error "invalid order key head"
;;

let integer_part key =
  if String.equal key ""
  then Error "empty order key"
  else
    Result.bind (integer_length key.[0]) (fun length ->
      if String.length key < length
      then Error "invalid integer part of order key"
      else Ok (String.sub key 0 length))
;;

let suffix value offset =
  if offset >= String.length value
  then ""
  else String.sub value offset (String.length value - offset)
;;

let validate_integer value =
  Result.bind (integer_part value) (fun integer ->
    let digits_are_valid =
      String.sub integer 1 (String.length integer - 1)
      |> String.for_all (fun character -> Option.is_some (index_of character))
    in
    if String.length integer <> String.length value || not digits_are_valid
    then Error "invalid integer part of order key"
    else Ok ())
;;

let validate key =
  Result.bind (integer_part key) (fun integer ->
    let fraction = suffix key (String.length integer) in
    let minimum = "A" ^ String.make 26 zero in
    if String.equal key minimum
       || (not (String.equal fraction "") && Char.equal fraction.[String.length fraction - 1] zero)
    then Error "invalid order key"
    else Ok ())
;;

let increment value =
  Result.bind (validate_integer value) (fun () ->
    let bytes = Bytes.of_string value in
    let rec carry index =
      if index = 0
      then true
      else
        let digit = Option.get (index_of (Bytes.get bytes index)) in
        if digit + 1 = String.length digits
        then (
          Bytes.set bytes index zero;
          carry (index - 1))
        else (
          Bytes.set bytes index digits.[digit + 1];
          false)
    in
    if not (carry (Bytes.length bytes - 1))
    then Ok (Some (Bytes.to_string bytes))
    else
      let head = Bytes.get bytes 0 in
      if Char.equal head 'Z'
      then Ok (Some ("a" ^ String.make 1 zero))
      else if Char.equal head 'z'
      then Ok None
      else
        let next = Char.chr (Char.code head + 1) in
        let tail = suffix (Bytes.to_string bytes) 1 in
        let tail =
          if next > 'a'
          then tail ^ String.make 1 zero
          else String.sub tail 0 (String.length tail - 1)
        in
        Ok (Some (String.make 1 next ^ tail)))
;;

let decrement value =
  Result.bind (validate_integer value) (fun () ->
    let bytes = Bytes.of_string value in
    let rec borrow index =
      if index = 0
      then true
      else
        let digit = Option.get (index_of (Bytes.get bytes index)) in
        if digit = 0
        then (
          Bytes.set bytes index digits.[String.length digits - 1];
          borrow (index - 1))
        else (
          Bytes.set bytes index digits.[digit - 1];
          false)
    in
    if not (borrow (Bytes.length bytes - 1))
    then Ok (Some (Bytes.to_string bytes))
    else
      let head = Bytes.get bytes 0 in
      if Char.equal head 'a'
      then Ok (Some ("Z" ^ String.make 1 digits.[String.length digits - 1]))
      else if Char.equal head 'A'
      then Ok None
      else
        let previous = Char.chr (Char.code head - 1) in
        let tail = suffix (Bytes.to_string bytes) 1 in
        let tail =
          if previous < 'Z'
          then tail ^ String.make 1 digits.[String.length digits - 1]
          else String.sub tail 0 (String.length tail - 1)
        in
        Ok (Some (String.make 1 previous ^ tail)))
;;

let rec midpoint lower upper =
  if option_exists (fun upper -> String.compare lower upper >= 0) upper
  then Error "invalid midpoint bounds"
  else if (not (String.equal lower "") && Char.equal lower.[String.length lower - 1] zero)
          || option_exists
               (fun upper ->
                 not (String.equal upper "") && Char.equal upper.[String.length upper - 1] zero)
               upper
  then Error "midpoint has trailing zero"
  else
    let shared =
      match upper with
      | None -> 0
      | Some upper ->
        let rec loop index =
          if index = String.length upper
          then index
          else
            let lower_character =
              if index < String.length lower then lower.[index] else zero
            in
            if Char.equal lower_character upper.[index] then loop (index + 1) else index
        in
        loop 0
    in
    if shared > 0
    then
      let upper = Option.get upper in
      Result.map
        (fun rest -> String.sub upper 0 shared ^ rest)
        (midpoint (suffix lower shared) (Some (suffix upper shared)))
    else
      let lower_digit =
        if String.equal lower "" then Some 0 else index_of lower.[0]
      in
      let upper_digit =
        match upper with None -> Some (String.length digits) | Some value -> index_of value.[0]
      in
      (match lower_digit, upper_digit with
       | Some lower_digit, Some upper_digit when upper_digit - lower_digit > 1 ->
         let middle = Float.round (float_of_int (lower_digit + upper_digit) *. 0.5) |> int_of_float in
         Ok (String.make 1 digits.[middle])
       | Some _, Some _ when option_exists (fun upper -> String.length upper > 1) upper ->
         Ok (String.sub (Option.get upper) 0 1)
       | Some lower_digit, Some _ ->
         Result.map
           (fun rest -> String.make 1 digits.[lower_digit] ^ rest)
           (midpoint (suffix lower 1) None)
       | _ -> Error "invalid fractional digit")
;;

let between lower upper =
  let validate_optional = function None -> Ok () | Some value -> validate value in
  Result.bind (validate_optional lower) (fun () ->
    Result.bind (validate_optional upper) (fun () ->
      if Option.is_some lower
         && Option.is_some upper
         && String.compare (Option.get lower) (Option.get upper) >= 0
      then Error "invalid order bounds"
      else
        let result =
          match lower, upper with
          | None, None -> Ok "a0"
          | None, Some upper ->
            Result.bind (integer_part upper) (fun integer ->
              let fraction = suffix upper (String.length integer) in
              if String.equal integer ("A" ^ String.make 26 zero) || String.compare integer upper < 0
              then Result.map (fun value -> integer ^ value) (midpoint "" (Some fraction))
              else
                Result.bind (decrement integer) (function
                  | Some value -> Ok value
                  | None -> (Error "cannot decrement order key" [@coverage off])))
          | Some lower, None ->
            Result.bind (integer_part lower) (fun integer ->
              let fraction = suffix lower (String.length integer) in
              Result.bind (increment integer) (function
                | Some value -> Ok value
                | None -> Result.map (fun value -> integer ^ value) (midpoint fraction None)))
          | Some lower, Some upper ->
            Result.bind (integer_part lower) (fun lower_integer ->
              Result.bind (integer_part upper) (fun upper_integer ->
                let lower_fraction = suffix lower (String.length lower_integer) in
                let upper_fraction = suffix upper (String.length upper_integer) in
                if String.equal lower_integer upper_integer
                then
                  Result.map
                    (fun value -> lower_integer ^ value)
                    (midpoint lower_fraction (Some upper_fraction))
                else
                  Result.bind (increment lower_integer) (function
                    | Some value when String.compare value upper < 0 -> Ok value
                    | _ ->
                      Result.map
                        (fun value -> lower_integer ^ value)
                        (midpoint lower_fraction None))))
        in
        Result.bind result (fun value ->
          if option_exists (fun lower -> String.compare lower value >= 0) lower
             || option_exists (fun upper -> String.compare value upper >= 0) upper
          then Error "generate-key-between failed"
          else Ok value)))
;;

let rec n_between lower upper count =
  if count < 0
  then Error "order key count must not be negative"
  else if count = 0
  then Ok []
  else if count = 1
  then Result.map (fun value -> [ value ]) (between lower upper)
  else
    match lower, upper with
    | _, None ->
      let rec loop lower count result =
        if count = 0
        then Ok (List.rev result)
        else
          Result.bind (between lower None) (fun value ->
            loop (Some value) (count - 1) (value :: result))
      in
      loop lower count []
    | None, _ ->
      let rec loop upper count result =
        if count = 0
        then Ok result
        else
          Result.bind (between None upper) (fun value ->
            loop (Some value) (count - 1) (value :: result))
      in
      loop upper count []
    | Some _, Some _ ->
      let left_count = count / 2 in
      Result.bind (between lower upper) (fun middle ->
        Result.bind (n_between lower (Some middle) left_count) (fun left ->
          Result.map
            (fun right -> left @ (middle :: right))
            (n_between (Some middle) upper (count - left_count - 1))))
;;
