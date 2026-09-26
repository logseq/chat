module Ds = Datascript
module Value = Transit_core.Json

type pending_temp_id =
  { identity_attr : string
  ; identity_value : Ds.value
  ; entity_ref : Ds.entity_ref
  }

type entity_identity =
  { identity_attr : string
  ; identity_value : Ds.value
  ; identity_ref : Ds.entity_ref
  }

let identity_parts input =
  match input with
  | Value.Array [ Value.Keyword "block/uuid"; Value.Uuid uuid ] ->
    Ok
      {
        identity_attr = "block/uuid";
        identity_value = Ds.Uuid uuid;
        identity_ref = Ds.Lookup_ref ("block/uuid", Ds.Uuid uuid);
      }
  | Value.Array [ Value.Keyword "db/ident"; Value.Keyword ident ] ->
    Ok
      {
        identity_attr = "db/ident";
        identity_value = Ds.Keyword ident;
        identity_ref = Ds.Ident ident;
      }
  | Value.Array [ Value.Keyword "file/path"; Value.String path ] ->
    Ok
      {
        identity_attr = "file/path";
        identity_value = Ds.String path;
        identity_ref = Ds.Lookup_ref ("file/path", Ds.String path);
      }
  | _ -> Error "unsupported server entity identity"

let rec generic_value (input : Value.value) : Ds.value =
  match input with
  | Value.Null -> Ds.Nil
  | Value.Bool value -> Ds.Bool value
  | Value.String value -> Ds.String value
  | Value.Int value -> Ds.Int64 (Int64.of_int value)
  | Value.Int64 value -> Ds.Int64 value
  | Value.Float value -> Ds.Float value
  | Value.Binary value -> Ds.String value
  | Value.Big_decimal value -> Ds.Float (float_of_string value)
  | Value.Big_int value -> Ds.Int64 (Int64.of_string value)
  | Value.Date value -> Ds.Instant value
  | Value.Uuid value -> Ds.Uuid value
  | Value.Uri value -> Ds.String value
  | Value.Keyword value -> Ds.Keyword value
  | Value.Symbol value -> Ds.Symbol value
  | Value.Array values -> Ds.Vector (List.map generic_value values)
  | Value.Map entries ->
    Ds.Map (List.map (fun (k, v) -> (generic_value k, generic_value v)) entries)
  | Value.Set values -> Ds.Set (List.map generic_value values)
  | Value.List values -> Ds.List (List.map generic_value values)
  | Value.Tagged ("u", Value.String value) -> Ds.Uuid value
  | Value.Tagged ("m", Value.Int value) -> Ds.Instant (Int64.of_int value)
  | Value.Tagged ("m", Value.Int64 value) -> Ds.Instant value
  | Value.Tagged ("regex", Value.String value) -> Ds.Regex value
  | Value.Tagged (tag, value) ->
    Ds.Vector [ Ds.String tag; generic_value value ]

let schema_attr db attr = List.assoc_opt attr (Ds.schema db)

let temp_id identity_attr identity_value =
  let suffix =
    match identity_value with
    | Ds.Uuid value | Ds.String value | Ds.Keyword value -> value
    | _ -> string_of_int (Hashtbl.hash identity_value)
  in
  Ds.Temp_id ("remote:" ^ identity_attr ^ ":" ^ suffix)

let pending_temp_id_ref identity_attr identity_value pending_temp_ids =
  List.find_map
    (fun (pending : pending_temp_id) ->
      if
        pending.identity_attr = identity_attr
        && pending.identity_value = identity_value
      then Some pending.entity_ref
      else None)
    pending_temp_ids

let rec value_for_attr db pending_temp_ids attr value =
  match schema_attr db attr with
  | Some schema ->
    (match schema.Ds.value_type with
     | Some Ds.RefType ->
       let ( let* ) = Result.bind in
       let* parts = identity_parts value in
       let entity_ref =
         match
           pending_temp_id_ref parts.identity_attr parts.identity_value
             pending_temp_ids
         with
         | Some pending -> pending
         | None -> parts.identity_ref
       in
       Ok (Ds.Ref_to entity_ref)
     | Some Ds.TupleType ->
       (match value with
        | Value.Array values | Value.List values ->
          Ok
            (Ds.Tuple
               (List.map
                  (fun item ->
                    match item with Value.Null -> None | _ -> Some (generic_value item))
                  values))
        | _ -> Error ("tuple attribute " ^ attr ^ " is not a Transit array"))
     | _ -> Ok (generic_value value))
  | None -> Ok (generic_value value)

let rec values_for_attr db pending_temp_ids attr value =
  match schema_attr db attr with
  | Some schema ->
    (match schema.Ds.cardinality with
     | Ds.Many ->
       let values =
         match value with
         | Value.Set values | Value.Array values | Value.List values -> values
         | _ -> [ value ]
       in
       let rec loop converted remaining =
         match remaining with
         | [] -> Ok (List.rev converted)
         | input :: rest ->
           (match value_for_attr db pending_temp_ids attr input with
            | Ok value -> loop (value :: converted) rest
            | Error _ as error -> error)
       in
       loop [] values
     | Ds.One ->
       (match value_for_attr db pending_temp_ids attr value with
        | Ok value -> Ok [ value ]
        | Error _ as error -> error))
  | None ->
    (match value_for_attr db pending_temp_ids attr value with
     | Ok value -> Ok [ value ]
     | Error _ as error -> error)

let protected_attr attr = attr = "block/title" || attr = "block/name"

let decrypt_attr decrypt attr value =
  if protected_attr attr then
    match value with
    | Value.String ciphertext ->
      (match decrypt ciphertext with
       | Ok plaintext -> Ok (Value.String plaintext)
       | Error _ as error -> error)
    | _ -> Error ("protected server attribute " ^ attr ^ " must be a string")
  else Ok value

let decoded_attrs decrypt db pending_temp_ids attrs =
  let rec loop decoded remaining =
    match remaining with
    | [] -> Ok (List.rev decoded)
    | (key, value) :: rest ->
      (match key with
       | Value.Keyword attr ->
         (match decrypt_attr decrypt attr value with
          | Error _ as error -> error
          | Ok value ->
            (match values_for_attr db pending_temp_ids attr value with
             | Error _ as error -> error
             | Ok values -> loop ((attr, values) :: decoded) rest))
       | _ -> Error "server entity attribute name is not a keyword")
  in
  loop [] attrs

let add_ops_for_attr entity_ref identity_attr (attr, values) =
  if attr = identity_attr then []
  else List.map (fun value -> Ds.Add (entity_ref, attr, value)) values

let pending_temp_ids db entities =
  let rec loop pending remaining =
    match remaining with
    | [] -> Ok pending
    | (entity : Sync_protocol.sync_entity) :: rest ->
      (match identity_parts entity.Sync_protocol.id with
       | Error _ as error -> error
       | Ok parts ->
         let pending =
           match Ds.entid_ref db parts.identity_ref with
           | Some _ -> pending
           | None ->
             {
               identity_attr = parts.identity_attr;
               identity_value = parts.identity_value;
               entity_ref = temp_id parts.identity_attr parts.identity_value;
             }
             :: pending
         in
         loop pending rest)
  in
  loop [] entities

let upsert_ops decrypt db pending_temp_ids (entity : Sync_protocol.sync_entity)
    =
  match identity_parts entity.Sync_protocol.id with
  | Error _ as error -> error
  | Ok parts ->
    (match decoded_attrs decrypt db pending_temp_ids entity.Sync_protocol.attrs with
     | Error _ as error -> error
     | Ok attrs ->
       (match Ds.entid_ref db parts.identity_ref with
        | Some eid ->
          let retractions =
            List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:eid ())
            |> List.filter (fun (datom : Ds.datom) -> datom.a <> parts.identity_attr)
            |> List.map (fun (datom : Ds.datom) ->
              Ds.Retract (Ds.Entity_id eid, datom.a, Some datom.v))
          in
          Ok
            (retractions
            @ List.concat_map
                (add_ops_for_attr (Ds.Entity_id eid) parts.identity_attr)
                attrs)
        | None ->
          let entity_ref = temp_id parts.identity_attr parts.identity_value in
          Ok
            (Ds.Add (entity_ref, parts.identity_attr, parts.identity_value)
            :: List.concat_map
                 (add_ops_for_attr entity_ref parts.identity_attr)
                 attrs)))

let delete_ops db identities =
  let rec loop operations remaining =
    match remaining with
    | [] -> Ok (List.rev operations)
    | identity :: rest ->
      (match identity_parts identity with
       | Error _ as error -> error
       | Ok parts ->
         let operations =
           match Ds.entid_ref db parts.identity_ref with
           | Some eid -> Ds.RetractEntity (Ds.Entity_id eid) :: operations
           | None -> operations
         in
         loop operations rest)
  in
  loop [] identities

let collect_upserts decrypt db pending_temp_ids entities =
  let rec loop operations remaining =
    match remaining with
    | [] -> Ok (List.concat (List.rev operations))
    | entity :: rest ->
      (match upsert_ops decrypt db pending_temp_ids entity with
       | Ok entity_ops -> loop (entity_ops :: operations) rest
       | Error _ as error -> error)
  in
  loop [] entities

let apply_change_set decrypt conn change =
  try
    let db = Ds.conn_db conn in
    let ( let* ) = Result.bind in
    let* pending_temp_ids = pending_temp_ids db change.Sync_protocol.upserts in
    let* upserts =
      collect_upserts decrypt db pending_temp_ids change.Sync_protocol.upserts
    in
    let* deletions = delete_ops db change.Sync_protocol.deleted in
    if upserts <> [] || deletions <> [] then
      ignore (Ds.transact_conn conn (upserts @ deletions));
    Ok ()
  with error -> Error (Printexc.to_string error)
