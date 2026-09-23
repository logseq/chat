module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

type sync_checkpoint =
  { graph_id : string
  ; schema_version : string
  ; applied_server_t : int
  }

let create graph_id schema_version applied_server_t =
  { graph_id; schema_version; applied_server_t }

let encode checkpoint =
  Codec.to_string
    (Value.Map
       [
         (Value.Keyword "format-version", Value.Int 1);
         (Value.Keyword "graph-id", Value.String checkpoint.graph_id);
         ( Value.Keyword "schema-version"
         , Value.String checkpoint.schema_version );
         ( Value.Keyword "applied-server-t"
         , Value.Int checkpoint.applied_server_t );
       ])

let field key entries =
  List.find_map
    (fun (k, v) -> if k = Value.Keyword key then Some v else None)
    entries

let int_value value =
  match value with
  | Value.Int value -> Some value
  | Value.Int64 value ->
    if
      Int64.compare value 0L >= 0
      && Int64.compare value (Int64.of_int max_int) <= 0
    then Some (Int64.to_int value)
    else None
  | _ -> None

let decode_map entries =
  let format = field "format-version" entries in
  let graph_id = field "graph-id" entries in
  let schema_version = field "schema-version" entries in
  let server_t = Option.bind (field "applied-server-t" entries) int_value in
  match (format, graph_id, schema_version, server_t) with
  | ( Some (Value.Int 1)
    , Some (Value.String graph_id)
    , Some (Value.String schema_version)
    , Some server_t ) ->
    if server_t < 0 then Error "invalid graph sync checkpoint"
    else Ok (create graph_id schema_version server_t)
  | _ -> Error "invalid graph sync checkpoint"

let decode source =
  try
    match Codec.of_string source with
    | Value.Map entries -> decode_map entries
    | _ -> Error "graph sync checkpoint must be a Transit map"
  with error -> Error (Printexc.to_string error)

let load_checkpoint path =
  if not (Sys.file_exists path) then Ok None
  else
    try
      let channel = open_in_bin path in
      let source =
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () ->
            really_input_string channel (in_channel_length channel))
      in
      (match decode source with
       | Ok checkpoint -> Ok (Some checkpoint)
       | Error _ as error -> error)
    with error ->
      Error ("read checkpoint " ^ path ^ ": " ^ Printexc.to_string error)

let save_checkpoint_atomic path checkpoint =
  let temporary = path ^ ".tmp" in
  try
    let channel =
      open_out_gen
        [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
        0o600 temporary
    in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () ->
        output_string channel (encode checkpoint);
        flush channel;
        Unix.fsync (Unix.descr_of_out_channel channel));
    Unix.rename temporary path;
    Ok ()
  with error ->
    (try if Sys.file_exists temporary then Sys.remove temporary
     with _ -> ());
    Error ("write checkpoint " ^ path ^ ": " ^ Printexc.to_string error)
