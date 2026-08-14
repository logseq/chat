module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

type t =
  { graph_id : string
  ; schema_version : string
  ; applied_server_t : int
  }

let create ~graph_id ~schema_version ~applied_server_t =
  { graph_id; schema_version; applied_server_t }
;;

let encode checkpoint =
  Codec.to_string
    (Value.Map
       [ Value.Keyword "format-version", Value.Int 1
       ; Value.Keyword "graph-id", Value.String checkpoint.graph_id
       ; Value.Keyword "schema-version", Value.String checkpoint.schema_version
       ; Value.Keyword "applied-server-t", Value.Int checkpoint.applied_server_t
       ])
;;

let field key entries = List.assoc_opt (Value.Keyword key) entries

let decode source =
  let decoded =
    try Ok (Codec.of_string source) with
    | Value.Decode_error message -> Error message
    | Yojson.Json_error message -> Error message
    | Failure message -> Error message
    | Invalid_argument message -> Error message
  in
  match decoded with
  | Error _ as error -> error
  | Ok (Value.Map entries) ->
    (match
       field "format-version" entries,
       field "graph-id" entries,
       field "schema-version" entries,
       field "applied-server-t" entries
     with
     | Some (Value.Int 1),
       Some (Value.String graph_id),
       Some (Value.String schema_version),
       Some (Value.Int applied_server_t)
       when applied_server_t >= 0 ->
       Ok { graph_id; schema_version; applied_server_t }
     | Some (Value.Int 1),
       Some (Value.String graph_id),
       Some (Value.String schema_version),
       Some (Value.Int64 applied_server_t)
       when applied_server_t >= 0L && applied_server_t <= Int64.of_int max_int ->
       Ok
         { graph_id
         ; schema_version
         ; applied_server_t = Int64.to_int applied_server_t
         }
     | _ -> Error "invalid graph sync checkpoint")
  | Ok _ -> Error "graph sync checkpoint must be a Transit map"
;;

let error_message operation path error =
  Printf.sprintf "%s %s: %s" operation path (Printexc.to_string error)
;;

let load path =
  if not (Sys.file_exists path)
  then Ok None
  else
    try
      let channel = open_in_bin path in
      let source =
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () -> really_input_string channel (in_channel_length channel))
      in
      Result.map Option.some (decode source)
    with
    | error -> Error (error_message "read checkpoint" path error)
;;

let save_atomic path checkpoint =
  let temporary = path ^ ".tmp" in
  try
    let channel = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600 temporary in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () ->
        output_string channel (encode checkpoint);
        flush channel;
        Unix.fsync (Unix.descr_of_out_channel channel));
    Unix.rename temporary path;
    Ok ()
  with
  | error ->
    (try if Sys.file_exists temporary then Sys.remove temporary with
     | _ -> ());
    Error (error_message "write checkpoint" path error)
;;
