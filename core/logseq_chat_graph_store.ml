type row = Logseq_chat_snapshot.row

external prepare_staging : string -> unit = "logseq_chat_graph_store_prepare"
external append_staging : string -> row list -> unit = "logseq_chat_graph_store_append"
external copy_app_tables : string -> string -> unit = "logseq_chat_graph_store_copy_app_tables"

external read_stored_row
  :  string
  -> int
  -> (string * string option) option
  = "logseq_chat_graph_store_read_row"

external list_stored_addresses : string -> int list = "logseq_chat_graph_store_list_addresses"
external delete_stored_addresses : string -> int list -> unit = "logseq_chat_graph_store_delete"

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
    prepare_staging staging;
    if Sys.file_exists active_path then copy_app_tables active_path staging)
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

let int_of_address address =
  match int_of_string_opt address with
  | Some address -> address
  | None -> invalid_arg ("Logseq graph storage address is not an integer: " ^ address)
;;

let storage_with_paths ~read_path ~write_path : Datascript.storage =
  let storage_store entries =
    entries
    |> List.map (fun (address, payload) ->
      let content, addresses = Logseq_chat_logseq_storage_codec.encode payload in
      { Logseq_chat_snapshot.addr = int_of_address address; content; addresses })
    |> append_staging write_path
  in
  { storage_store
  ; storage_restore =
      (fun address ->
        match read_stored_row read_path (int_of_address address) with
        | None -> None
        | Some (content, addresses) ->
          Some (Logseq_chat_logseq_storage_codec.decode ?addresses content))
  ; storage_list_addresses =
      (fun () -> List.map string_of_int (list_stored_addresses read_path))
  ; storage_delete =
      (fun addresses ->
        delete_stored_addresses write_path (List.map int_of_address addresses))
  }
;;

let storage ~path =
  storage_with_paths ~read_path:path ~write_path:path
;;

let import_storage ~active_path =
  let path = staging_path active_path in
  storage_with_paths ~read_path:path ~write_path:path
;;

let restore_db ~path =
  try
    match Datascript.restore (storage ~path) with
    | Some db -> Ok db
    | None -> Error "graph storage has no DataScript root"
  with
  | error -> Error ("restore graph DataScript db: " ^ Printexc.to_string error)
;;

let restore_conn ~path =
  try
    match Datascript.restore_conn (storage ~path) with
    | Some conn -> Ok conn
    | None -> Error "graph storage has no DataScript root"
  with
  | error -> Error ("restore graph DataScript connection: " ^ Printexc.to_string error)
;;
