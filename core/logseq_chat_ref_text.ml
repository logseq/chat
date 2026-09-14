let is_uuid value =
  let hex = function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false
  in
  String.length value = 36
  &&
  let valid = ref true in
  String.iteri
    (fun index character ->
      match index with
      | 8 | 13 | 18 | 23 -> if not (Char.equal character '-') then valid := false
      | _ -> if not (hex character) then valid := false)
    value;
  !valid
;;

let tag_terminator = function
  | ' ' | '\t' | '\n' | ',' | '.' | '(' | ')' | '[' | ']' | '#' -> true
  | _ -> false
;;

let plain_tag_label label =
  not (String.equal label "") && not (String.exists tag_terminator label)
;;

let close_index title start =
  let length = String.length title in
  let rec loop index =
    if index + 1 >= length
    then None
    else if Char.equal title.[index] ']' && Char.equal title.[index + 1] ']'
    then Some index
    else loop (index + 1)
  in
  loop start
;;

let to_text ~tag_title ~ref_title title =
  let length = String.length title in
  let buffer = Buffer.create length in
  let rec loop index =
    if index >= length
    then ()
    else if index + 2 < length
            && Char.equal title.[index] '#'
            && Char.equal title.[index + 1] '['
            && Char.equal title.[index + 2] '['
    then (
      match close_index title (index + 3) with
      | Some close ->
        let inner = String.sub title (index + 3) (close - index - 3) in
        (match tag_title inner with
         | Some label when plain_tag_label label -> Buffer.add_string buffer ("#" ^ label)
         | Some label -> Buffer.add_string buffer ("#[[" ^ label ^ "]]")
         | None -> Buffer.add_string buffer (String.sub title index (close + 2 - index)));
        loop (close + 2)
      | None ->
        Buffer.add_char buffer title.[index];
        loop (index + 1))
    else if index + 1 < length
            && Char.equal title.[index] '['
            && Char.equal title.[index + 1] '['
    then (
      match close_index title (index + 2) with
      | Some close ->
        let inner = String.sub title (index + 2) (close - index - 2) in
        (match ref_title inner with
         | Some label -> Buffer.add_string buffer ("[[" ^ label ^ "]]")
         | None -> Buffer.add_string buffer (String.sub title index (close + 2 - index)));
        loop (close + 2)
      | None ->
        Buffer.add_char buffer title.[index];
        loop (index + 1))
    else (
      Buffer.add_char buffer title.[index];
      loop (index + 1))
  in
  loop 0;
  Buffer.contents buffer
;;

let hashtag_start title index =
  index = 0
  ||
  match title.[index - 1] with
  | ' ' | '\t' | '\n' | '(' -> true
  | _ -> false
;;

let to_ids ~resolve_ref ~resolve_tag title =
  let length = String.length title in
  let buffer = Buffer.create length in
  let rec loop index =
    if index >= length
    then ()
    else if index + 2 < length
            && Char.equal title.[index] '#'
            && Char.equal title.[index + 1] '['
            && Char.equal title.[index + 2] '['
    then (
      match close_index title (index + 3) with
      | Some close ->
        let inner = String.sub title (index + 3) (close - index - 3) in
        (match if is_uuid inner then None else resolve_tag inner with
         | Some uuid -> Buffer.add_string buffer ("#[[" ^ uuid ^ "]]")
         | None -> Buffer.add_string buffer (String.sub title index (close + 2 - index)));
        loop (close + 2)
      | None ->
        Buffer.add_char buffer title.[index];
        loop (index + 1))
    else if index + 1 < length
            && Char.equal title.[index] '['
            && Char.equal title.[index + 1] '['
    then (
      match close_index title (index + 2) with
      | Some close ->
        let inner = String.sub title (index + 2) (close - index - 2) in
        (match if is_uuid inner then None else resolve_ref inner with
         | Some uuid -> Buffer.add_string buffer ("[[" ^ uuid ^ "]]")
         | None -> Buffer.add_string buffer (String.sub title index (close + 2 - index)));
        loop (close + 2)
      | None ->
        Buffer.add_char buffer title.[index];
        loop (index + 1))
    else if Char.equal title.[index] '#' && hashtag_start title index
    then (
      let word_end =
        let rec find at =
          if at < length && not (tag_terminator title.[at])
          then find (at + 1)
          else at
        in
        find (index + 1)
      in
      let word = String.sub title (index + 1) (word_end - index - 1) in
      match if String.equal word "" then None else resolve_tag word with
      | Some uuid ->
        Buffer.add_string buffer ("#[[" ^ uuid ^ "]]");
        loop word_end
      | None ->
        Buffer.add_char buffer title.[index];
        loop (index + 1))
    else (
      Buffer.add_char buffer title.[index];
      loop (index + 1))
  in
  loop 0;
  Buffer.contents buffer
;;
