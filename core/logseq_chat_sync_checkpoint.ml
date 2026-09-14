module LG = Logseq_chat_lg_core_native

type t = LG.sync_checkpoint =
  { graph_id : string
  ; schema_version : string
  ; applied_server_t : int
  }

let create ~graph_id ~schema_version ~applied_server_t =
  LG.logseq_chat_sync_checkpoint_create graph_id schema_version applied_server_t
;;

let encode = LG.logseq_chat_sync_checkpoint_encode

let decode = LG.logseq_chat_sync_checkpoint_decode

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
