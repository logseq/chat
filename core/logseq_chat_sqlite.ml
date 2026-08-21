module Ds = Datascript
module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

type session =
  { path : string
  ; mutable closed : bool
  }

external sqlite_open : string -> unit = "datascript_sqlite_open"
external sqlite_close : string -> unit = "datascript_sqlite_close"
external sqlite_store : string -> (string * string) list -> unit = "datascript_sqlite_store"
external sqlite_restore : string -> string -> string option = "datascript_sqlite_restore"
external sqlite_list_addresses : string -> string list = "datascript_sqlite_list_addresses"
external sqlite_delete : string -> string list -> unit = "datascript_sqlite_delete"

let ensure_open session =
  if session.closed then invalid_arg "SQLite session is closed"
;;

let open_session path =
  sqlite_open path;
  { path; closed = false }
;;

let close session =
  if not session.closed
  then (
    sqlite_close session.path;
    session.closed <- true)
;;

let envelope ~value_type value =
  Codec.to_string
    (Value.Map
       [ Value.Keyword "format-version", Value.Int 1
       ; Value.Keyword "value-type", Value.Keyword value_type
       ; Value.Keyword "value", Value.String value
       ])
;;

let field key entries = List.assoc_opt (Value.Keyword key) entries

let decode_envelope ~value_type source =
  let decoded =
    try Some (Codec.of_string source) with
    | Value.Decode_error _
    | Yojson.Json_error _
    | Failure _
    | Invalid_argument _ -> None
  in
  match decoded with
  | Some (Value.Map entries) ->
    (match field "format-version" entries, field "value-type" entries, field "value" entries with
     | Some (Value.Int 1), Some (Value.Keyword actual_type), Some (Value.String value)
       when String.equal actual_type value_type -> Some value
     | _ -> None)
  | Some _ | None -> None
;;

let encode payload =
  payload
  |> Datascript_sqlite_codec.encode
  |> envelope ~value_type:"datascript-storage"
;;

let decode payload =
  match decode_envelope ~value_type:"datascript-storage" payload with
  | None -> None
  | Some encoded ->
    (try Some (Datascript_sqlite_codec.decode encoded) with
     | Value.Decode_error _
     | Yojson.Json_error _
     | Failure _
     | Invalid_argument _ -> None)
;;

let store_string session ~address value =
  ensure_open session;
  sqlite_store session.path [ address, envelope ~value_type:"string" value ]
;;

let restore_string session ~address =
  ensure_open session;
  Option.bind
    (sqlite_restore session.path address)
    (decode_envelope ~value_type:"string")
;;

let storage session : Ds.storage =
  { storage_store =
      (fun entries ->
        ensure_open session;
        sqlite_store session.path
          (List.map (fun (address, payload) -> address, encode payload) entries))
  ; storage_restore =
      (fun address ->
        ensure_open session;
        Option.bind (sqlite_restore session.path address) decode)
  ; storage_list_addresses =
      (fun () ->
        ensure_open session;
        sqlite_list_addresses session.path)
  ; storage_delete =
      (fun addresses ->
        ensure_open session;
        sqlite_delete session.path addresses)
  }
;;

let migrate_datascript_storage ~source ~destination =
  let source_storage = storage source in
  let destination_storage = storage destination in
  let entries =
    source_storage.storage_list_addresses ()
    |> List.filter_map (fun address ->
      Option.map
        (fun payload -> address, payload)
        (source_storage.storage_restore address))
  in
  match entries with
  | [] -> ()
  | _ ->
    destination_storage.storage_store entries;
    source_storage.storage_delete (List.map fst entries)
;;
