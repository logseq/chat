module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

type sync_entity =
  { id : Value.value
  ; attrs : (Value.value * Value.value) list
  }

type sync_change_set =
  { format_version : int
  ; graph_id : string
  ; schema_version : string
  ; t_before : int
  ; t : int
  ; upserts : sync_entity list
  ; deleted : Value.value list
  ; operation_ids : string list
  }

type sync_reset =
  { reason : string
  ; snapshot_required : bool
  }

type sync_event =
  | Graph_changes of sync_change_set
  | Reset of sync_reset

let identity_uuid identity =
  match identity with
  | Value.Array [ Value.Keyword "block/uuid"; Value.Uuid uuid ] -> Some uuid
  | _ -> None

let changed_block_uuids change =
  let seen = Hashtbl.create 16 in
  List.filter_map identity_uuid
    (List.map (fun entity -> entity.id) change.upserts @ change.deleted)
  |> List.filter (fun uuid ->
    if Hashtbl.mem seen uuid then false
    else begin
      Hashtbl.add seen uuid ();
      true
    end)

let field key fields =
  List.find_map
    (fun (k, v) -> if k = Value.Keyword key then Some v else None)
    fields

let required key decode fields =
  match field key fields with
  | Some value -> decode value
  | None -> Error ("missing Transit field: " ^ key)

let as_int input =
  match input with
  | Value.Int number -> Ok number
  | Value.Int64 number ->
    if
      Int64.compare number (Int64.of_int min_int) >= 0
      && Int64.compare number (Int64.of_int max_int) <= 0
    then Ok (Int64.to_int number)
    else Error "expected Transit integer"
  | _ -> Error "expected Transit integer"

let as_string input =
  match input with
  | Value.String text -> Ok text
  | _ -> Error "expected Transit string"

let as_bool input =
  match input with
  | Value.Bool value -> Ok value
  | _ -> Error "expected Transit boolean"

let as_array input =
  match input with
  | Value.Array values -> Ok values
  | _ -> Error "expected Transit array"

let as_map input =
  match input with
  | Value.Map fields -> Ok fields
  | _ -> Error "expected Transit map"

let as_identity input =
  match input with
  | Value.Array [ Value.Keyword "block/uuid"; Value.Uuid uuid ] ->
    Ok (Value.Array [ Value.Keyword "block/uuid"; Value.Uuid uuid ])
  | Value.Array [ Value.Keyword "db/ident"; Value.Keyword ident ] ->
    Ok (Value.Array [ Value.Keyword "db/ident"; Value.Keyword ident ])
  | Value.Array [ Value.Keyword "file/path"; Value.String path ] ->
    Ok (Value.Array [ Value.Keyword "file/path"; Value.String path ])
  | _ -> Error "expected stable Transit lookup identity"

let keyword_key (entry_key, _) =
  match entry_key with Value.Keyword _ -> true | _ -> false

let all_keyword_keys fields = List.for_all keyword_key fields

let as_attrs input =
  match input with
  | Value.Map fields ->
    if all_keyword_keys fields then Ok fields
    else Error "expected Transit keyword attribute keys"
  | _ -> Error "expected Transit attribute map"

let decode_entity input =
  match as_map input with
  | Ok fields ->
    (match
       (required "id" as_identity fields, required "attrs" as_attrs fields)
     with
     | Ok id, Ok attrs -> Ok { id; attrs }
     | Error message, _ | _, Error message -> Error message)
  | Error _ as error -> error

let decode_entity_list values =
  let rec loop decoded remaining =
    match remaining with
    | [] -> Ok (List.rev decoded)
    | input :: rest ->
      (match decode_entity input with
       | Ok entity -> loop (entity :: decoded) rest
       | Error _ as error -> error)
  in
  loop [] values

let decode_identity_list values =
  let rec loop decoded remaining =
    match remaining with
    | [] -> Ok (List.rev decoded)
    | input :: rest ->
      (match as_identity input with
       | Ok identity -> loop (identity :: decoded) rest
       | Error _ as error -> error)
  in
  loop [] values

let decode_string_list values =
  let rec loop decoded remaining =
    match remaining with
    | [] -> Ok (List.rev decoded)
    | input :: rest ->
      (match as_string input with
       | Ok text -> loop (text :: decoded) rest
       | Error _ as error -> error)
  in
  loop [] values

let optional_string_list key fields =
  match field key fields with
  | None -> Ok []
  | Some input ->
    (match as_array input with
     | Ok values -> decode_string_list values
     | Error _ as error -> error)

let required_entity_list key fields =
  match required key as_array fields with
  | Ok values -> decode_entity_list values
  | Error _ as error -> error

let required_identity_list key fields =
  match required key as_array fields with
  | Ok values -> decode_identity_list values
  | Error _ as error -> error

let decode_change_value input =
  let ( let* ) = Result.bind in
  let* fields = as_map input in
  let* format_version = required "format-version" as_int fields in
  let* graph_id = required "graph-id" as_string fields in
  let* schema_version = required "schema-version" as_string fields in
  let* t_before = required "t-before" as_int fields in
  let* t = required "t" as_int fields in
  let* upserts = required_entity_list "upserts" fields in
  let* deleted = required_identity_list "deleted" fields in
  let* operation_ids = optional_string_list "operation-ids" fields in
  Ok
    {
      format_version;
      graph_id;
      schema_version;
      t_before;
      t;
      upserts;
      deleted;
      operation_ids;
    }

let decode_change_set wire =
  try decode_change_value (Codec.of_string wire)
  with error -> Error (Printexc.to_string error)

let decode_reset_value input =
  match as_map input with
  | Ok fields ->
    (match
       (required "reason" as_string fields, required "snapshot-required" as_bool fields)
     with
     | Ok reason, Ok snapshot_required -> Ok { reason; snapshot_required }
     | Error message, _ | _, Error message -> Error message)
  | Error _ as error -> error

let decode_event event_name wire =
  if event_name = "graph-changes" then
    match decode_change_set wire with
    | Ok change -> Ok (Graph_changes change)
    | Error _ as error -> error
  else if event_name = "reset" then
    try
      match decode_reset_value (Codec.of_string wire) with
      | Ok reset -> Ok (Reset reset)
      | Error _ as error -> error
    with error -> Error (Printexc.to_string error)
  else Error ("unsupported sync event: " ^ event_name)
