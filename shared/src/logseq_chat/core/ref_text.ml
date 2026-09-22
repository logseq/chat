type text_step =
  { step_index : int
  ; step_result : string
  }

let char_at value index = String.sub value index 1

let hex_character value =
  match value.[0] with
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let is_uuid value =
  String.length value = 36
  &&
  let rec loop index =
    if index = 36 then true
    else
      let character = char_at value index in
      let hyphen_slot =
        index = 8 || index = 13 || index = 18 || index = 23
      in
      if hyphen_slot then character.[0] = '-' && loop (index + 1)
      else hex_character character && loop (index + 1)
  in
  loop 0

let tag_terminator value =
  match value.[0] with
  | ' ' | '\t' | '\n' | ',' | '.' | '(' | ')' | '[' | ']' | '#' -> true
  | _ -> false

let plain_tag_label label =
  label <> ""
  &&
  let rec loop index =
    if index = String.length label then true
    else if tag_terminator (char_at label index) then false
    else loop (index + 1)
  in
  loop 0

let close_index title start =
  let length = String.length title in
  let rec loop index =
    if index + 1 >= length then None
    else if char_at title index = "]" && char_at title (index + 1) = "]" then
      Some index
    else loop (index + 1)
  in
  loop start

let slice_through_close title index close =
  String.sub title index (close + 2 - index)

let text_step index result = { step_index = index; step_result = result }

let to_text_step tag_title ref_title title length index result =
  if
    index + 2 < length
    && char_at title index = "#"
    && char_at title (index + 1) = "["
    && char_at title (index + 2) = "["
  then
    match close_index title (index + 3) with
    | Some close ->
      let inner = String.sub title (index + 3) (close - (index + 3)) in
      (match tag_title inner with
       | Some label ->
         text_step (close + 2)
           (result
           ^
           if plain_tag_label label then "#" ^ label
           else "#[[" ^ label ^ "]]")
       | None ->
         text_step (close + 2)
           (result ^ slice_through_close title index close))
    | None ->
      text_step (index + 1) (result ^ char_at title index)
  else if
    index + 1 < length
    && char_at title index = "["
    && char_at title (index + 1) = "["
  then
    match close_index title (index + 2) with
    | Some close ->
      let inner = String.sub title (index + 2) (close - (index + 2)) in
      (match ref_title inner with
       | Some label -> text_step (close + 2) (result ^ "[[" ^ label ^ "]]")
       | None ->
         text_step (close + 2)
           (result ^ slice_through_close title index close))
    | None -> text_step (index + 1) (result ^ char_at title index)
  else text_step (index + 1) (result ^ char_at title index)

let to_text tag_title ref_title title =
  let length = String.length title in
  let rec loop index result =
    if index >= length then result
    else
      let step = to_text_step tag_title ref_title title length index result in
      loop step.step_index step.step_result
  in
  loop 0 ""

let hashtag_start title index =
  index = 0
  ||
  let previous = char_at title (index - 1) in
  previous = " " || previous = "\t" || previous = "\n" || previous = "("

let hashtag_end title start =
  let length = String.length title in
  let rec loop index =
    if index < length && not (tag_terminator (char_at title index)) then
      loop (index + 1)
    else index
  in
  loop start

let to_ids_step resolve_ref resolve_tag title length index result =
  if
    index + 2 < length
    && char_at title index = "#"
    && char_at title (index + 1) = "["
    && char_at title (index + 2) = "["
  then
    match close_index title (index + 3) with
    | Some close ->
      let inner = String.sub title (index + 3) (close - (index + 3)) in
      (match if is_uuid inner then None else resolve_tag inner with
       | Some uuid -> text_step (close + 2) (result ^ "#[[" ^ uuid ^ "]]")
       | None ->
         text_step (close + 2)
           (result ^ slice_through_close title index close))
    | None -> text_step (index + 1) (result ^ char_at title index)
  else if
    index + 1 < length
    && char_at title index = "["
    && char_at title (index + 1) = "["
  then
    match close_index title (index + 2) with
    | Some close ->
      let inner = String.sub title (index + 2) (close - (index + 2)) in
      (match if is_uuid inner then None else resolve_ref inner with
       | Some uuid -> text_step (close + 2) (result ^ "[[" ^ uuid ^ "]]")
       | None ->
         text_step (close + 2)
           (result ^ slice_through_close title index close))
    | None -> text_step (index + 1) (result ^ char_at title index)
  else if char_at title index = "#" && hashtag_start title index then begin
    let word_end = hashtag_end title (index + 1) in
    let word = String.sub title (index + 1) (word_end - (index + 1)) in
    match if word = "" then None else resolve_tag word with
    | Some uuid -> text_step word_end (result ^ "#[[" ^ uuid ^ "]]")
    | None -> text_step (index + 1) (result ^ char_at title index)
  end
  else text_step (index + 1) (result ^ char_at title index)

let to_ids resolve_ref resolve_tag title =
  let length = String.length title in
  let rec loop index result =
    if index >= length then result
    else
      let step =
        to_ids_step resolve_ref resolve_tag title length index result
      in
      loop step.step_index step.step_result
  in
  loop 0 ""
