type frame =
  { event : string
  ; id : string option
  ; data : string
  }

type t = { mutable buffer : string }

let create () = { buffer = "" }

let normalize_newlines value =
  let output = Buffer.create (String.length value) in
  let rec loop index =
    if index < String.length value
    then
      match value.[index] with
      | '\r' ->
        Buffer.add_char output '\n';
        loop (if index + 1 < String.length value && value.[index + 1] = '\n'
              then index + 2
              else index + 1)
      | character ->
        Buffer.add_char output character;
        loop (index + 1)
  in
  loop 0;
  Buffer.contents output
;;

let field line =
  match String.index_opt line ':' with
  | None -> line, ""
  | Some index ->
    let name = String.sub line 0 index in
    let value = String.sub line (index + 1) (String.length line - index - 1) in
    let value =
      if String.length value > 0 && value.[0] = ' '
      then String.sub value 1 (String.length value - 1)
      else value
    in
    name, value
;;

let decode_frame raw =
  let event = ref "message" in
  let id = ref None in
  let data = ref [] in
  normalize_newlines raw
  |> String.split_on_char '\n'
  |> List.iter (fun line ->
    if String.length line > 0 && line.[0] <> ':'
    then
      match field line with
      | "event", value -> event := value
      | "id", value when not (String.contains value '\000') -> id := Some value
      | "data", value -> data := value :: !data
      | _ -> ());
  match List.rev !data with
  | [] -> None
  | lines -> Some { event = !event; id = !id; data = String.concat "\n" lines }
;;

let next_boundary value =
  let length = String.length value in
  let rec loop index =
    if index + 1 >= length
    then None
    else if value.[index] = '\n' && value.[index + 1] = '\n'
    then Some (index, 2)
    else if index + 3 < length
            && value.[index] = '\r'
            && value.[index + 1] = '\n'
            && value.[index + 2] = '\r'
            && value.[index + 3] = '\n'
    then Some (index, 4)
    else loop (index + 1)
  in
  loop 0
;;

let feed parser chunk =
  parser.buffer <- parser.buffer ^ chunk;
  let rec collect frames =
    match next_boundary parser.buffer with
    | None -> List.rev frames
    | Some (index, delimiter_length) ->
      let raw = String.sub parser.buffer 0 index in
      let rest_index = index + delimiter_length in
      parser.buffer
      <- String.sub parser.buffer rest_index (String.length parser.buffer - rest_index);
      collect
        (match decode_frame raw with
         | Some frame -> frame :: frames
         | None -> frames)
  in
  collect []
;;
