type row = Logseq_chat_snapshot.row

external prepare_staging : string -> unit = "logseq_chat_graph_store_prepare"
external append_staging : string -> row list -> unit = "logseq_chat_graph_store_append"

external read_stored_row
  :  string
  -> int
  -> (string * string option) option
  = "logseq_chat_graph_store_read_row"

let staging_path active_path = active_path ^ ".import"

let protect operation f =
  try
    f ();
    Ok ()
  with
  | error -> Error (operation ^ ": " ^ Printexc.to_string error)
;;

let begin_import ~active_path =
  let staging = staging_path active_path in
  protect "prepare graph snapshot staging database" (fun () ->
    if Sys.file_exists staging then Sys.remove staging;
    prepare_staging staging)
;;

let append_rows ~active_path rows =
  protect "append graph snapshot rows" (fun () ->
    if rows <> [] then append_staging (staging_path active_path) rows)
;;

let activate ~active_path =
  let staging = staging_path active_path in
  protect "activate graph snapshot" (fun () ->
    if not (Sys.file_exists staging) then invalid_arg "snapshot staging database is missing";
    Unix.rename staging active_path)
;;

let read_row ~path ~addr =
  try Ok (read_stored_row path addr) with
  | error -> Error ("read graph snapshot row: " ^ Printexc.to_string error)
;;
