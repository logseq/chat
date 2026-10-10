module Ds = Datascript

let staging_path active_path = active_path ^ ".import"

let protect operation f =
  try
    f ();
    Ok ()
  with error -> Error (operation ^ ": " ^ Printexc.to_string error)

let begin_import active_path =
  let staging = staging_path active_path in
  protect "prepare graph snapshot staging database" (fun () ->
      if Sys.file_exists staging then Sys.remove staging;
      Graph_sqlite.prepare_staging staging;
      if Sys.file_exists active_path then
        Graph_sqlite.copy_app_tables active_path staging)

let append_rows active_path rows =
  try
    if rows <> [] then
      Graph_sqlite.append_staging (staging_path active_path) rows;
    Ok ()
  with error ->
    Error ("append graph snapshot rows: " ^ Printexc.to_string error)

let activate active_path =
  let staging = staging_path active_path in
  protect "activate graph snapshot" (fun () ->
      if not (Sys.file_exists staging) then
        invalid_arg "snapshot staging database is missing";
      Unix.rename staging active_path)

let read_row path addr =
  try Ok (Graph_sqlite.read_stored_row path addr)
  with error ->
    Error ("read graph snapshot row: " ^ Printexc.to_string error)

let int_of_address address =
  match int_of_string_opt address with
  | Some number -> number
  | None ->
    invalid_arg
      ("Logseq graph storage address is not an integer: " ^ address)

let storage_with_paths read_path write_path =
  (* Retain one lazy reader so replacement snapshots cannot mix index nodes. *)
  let reader = lazy (Graph_sqlite.open_reader read_path) in
  {
    Ds.storage_store =
      (fun entries ->
        Graph_sqlite.append_staging write_path
          (List.map
             (fun (address, payload) ->
               let content, addresses = Storage_codec.encode None payload in
               {
                 Snapshot.addr = int_of_address address;
                 content;
                 addresses;
               })
             entries));
    storage_restore =
      (fun address ->
        match Graph_sqlite.reader_row (Lazy.force reader) (int_of_address address) with
        | None -> None
        | Some (content, addresses) ->
          Some (Storage_codec.decode addresses content));
    storage_list_addresses =
      (fun () ->
        List.map string_of_int
          (Graph_sqlite.list_stored_addresses read_path));
    storage_delete =
      (fun addresses ->
        Graph_sqlite.delete_stored_addresses write_path
          (List.map int_of_address addresses));
  }

let storage path = storage_with_paths path path

let import_storage active_path = storage (staging_path active_path)

let restore_db path =
  try
    match Ds.restore (storage path) with
    | Some db -> Ok db
    | None -> Error "graph storage has no DataScript root"
  with error ->
    Error ("restore graph DataScript db: " ^ Printexc.to_string error)

let restore_conn path =
  try
    match Ds.restore_conn (storage path) with
    | Some conn -> Ok conn
    | None -> Error "graph storage has no DataScript root"
  with error ->
    Error
      ("restore graph DataScript connection: " ^ Printexc.to_string error)
