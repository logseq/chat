module Storage_codec = Datascript_sqlite_codec
module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

type session =
  { connection : Sqlite3.db
  ; closed : bool ref
  }

let ensure_open session =
  if !(session.closed) then invalid_arg "SQLite session is closed"

let check_result session context result =
  if not (Sqlite3.Rc.is_success result) then
    failwith
      ("SQLite error while running " ^ context ^ ": "
      ^ Sqlite3.errmsg session.connection)

let execute session sql =
  ensure_open session;
  check_result session sql (Sqlite3.exec session.connection sql)

let close session =
  if not !(session.closed) then
    if Sqlite3.db_close session.connection then session.closed := true
    else failwith "SQLite connection is busy"

let open_session path =
  let session =
    { connection =
        (try Sqlite3.db_open path with
         | Sqlite3.Error message ->
           failwith
             ("SQLite error while running open database: " ^ message))
    ; closed = ref false
    }
  in
  try
    execute session
      "CREATE TABLE IF NOT EXISTS kvs (address TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL)";
    session
  with error ->
    close session;
    raise error

let with_statement session sql f =
  ensure_open session;
  let statement =
    try Sqlite3.prepare session.connection sql with
    | Sqlite3.Error message ->
      failwith ("SQLite error while running " ^ sql ^ ": " ^ message)
  in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize statement))
    (fun () -> f statement)

let transaction session f =
  execute session "BEGIN IMMEDIATE";
  try
    f ();
    execute session "COMMIT"
  with error ->
    execute session "ROLLBACK";
    raise error

let store_raw session entries =
  transaction session (fun () ->
    with_statement session
      "INSERT OR REPLACE INTO kvs (address, payload) VALUES (?, ?)"
      (fun statement ->
        List.iter
          (fun (address, payload) ->
            check_result session "bind address"
              (Sqlite3.bind_text statement 1 address);
            check_result session "bind payload"
              (Sqlite3.bind_text statement 2 payload);
            check_result session "store value" (Sqlite3.step statement);
            check_result session "reset store" (Sqlite3.reset statement))
          entries))

let restore_raw session address =
  with_statement session "SELECT payload FROM kvs WHERE address = ?"
    (fun statement ->
      check_result session "bind address"
        (Sqlite3.bind_text statement 1 address);
      match Sqlite3.step statement with
      | Sqlite3.Rc.ROW -> Some (Sqlite3.column_text statement 0)
      | Sqlite3.Rc.DONE -> None
      | code ->
        check_result session "restore value" code;
        None)

let envelope value_type text =
  Codec.to_string
    (Value.Map
       [
         (Value.Keyword "format-version", Value.Int 1);
         (Value.Keyword "value-type", Value.Keyword value_type);
         (Value.Keyword "value", Value.String text);
       ])

let decode_envelope value_type source =
  try
    match Codec.of_string source with
    | Value.Map entries ->
      let field key =
        List.find_map
          (fun (k, v) -> if k = Value.Keyword key then Some v else None)
          entries
      in
      (match
         (field "format-version", field "value-type", field "value")
       with
       | ( Some (Value.Int 1)
         , Some (Value.Keyword actual_type)
         , Some (Value.String text) )
         when actual_type = value_type ->
         Some text
       | _ -> None)
    | _ -> None
  with
  | Value.Decode_error _ -> None
  | Yojson.Json_error _ -> None
  | Failure _ -> None
  | Invalid_argument _ -> None

let store_string session address text =
  store_raw session [ (address, envelope "string" text) ]

let restore_string session address =
  match restore_raw session address with
  | Some source -> decode_envelope "string" source
  | None -> None

let list_addresses session =
  with_statement session "SELECT address FROM kvs ORDER BY address DESC"
    (fun statement ->
      let rec loop addresses =
        match Sqlite3.step statement with
        | Sqlite3.Rc.ROW ->
          loop (Sqlite3.column_text statement 0 :: addresses)
        | Sqlite3.Rc.DONE -> List.rev addresses
        | code ->
          check_result session "list addresses" code;
          List.rev addresses
      in
      loop [])

let delete_addresses session addresses =
  transaction session (fun () ->
    with_statement session "DELETE FROM kvs WHERE address = ?"
      (fun statement ->
        List.iter
          (fun address ->
            check_result session "bind address"
              (Sqlite3.bind_text statement 1 address);
            check_result session "delete value" (Sqlite3.step statement);
            check_result session "reset delete" (Sqlite3.reset statement))
          addresses))

let decode_payload source =
  match decode_envelope "datascript-storage" source with
  | Some encoded ->
    (try Some (Storage_codec.decode encoded) with
     | Value.Decode_error _ -> None
     | Yojson.Json_error _ -> None
     | Failure _ -> None
     | Invalid_argument _ -> None)
  | None -> None

let storage session : Datascript.storage =
  { Datascript.storage_store =
      (fun entries ->
        store_raw session
          (List.map
             (fun (address, payload) ->
               ( address
               , envelope "datascript-storage" (Storage_codec.encode payload)
               ))
             entries))
  ; storage_restore =
      (fun address ->
        match restore_raw session address with
        | Some source -> decode_payload source
        | None -> None)
  ; storage_list_addresses = (fun () -> list_addresses session)
  ; storage_delete = (fun addresses -> delete_addresses session addresses)
  }

let migrate_datascript_storage source destination =
  let entries =
    List.filter_map
      (fun address ->
        match restore_raw source address with
        | Some raw ->
          (match decode_payload raw with
           | Some _ -> Some (address, raw)
           | None -> None)
        | None -> None)
      (list_addresses source)
  in
  if entries <> [] then begin
    store_raw destination entries;
    delete_addresses source (List.map fst entries)
  end
