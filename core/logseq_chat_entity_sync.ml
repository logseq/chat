open Datascript
module Protocol = Logseq_chat_sync_protocol
module Value = Transit_core.Json

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let identity_parts = function
  | Value.Array [ Value.Keyword "block/uuid"; Value.Uuid uuid ] ->
    Ok ("block/uuid", Uuid uuid, Lookup_ref ("block/uuid", Uuid uuid))
  | Value.Array [ Value.Keyword "db/ident"; Value.Keyword ident ] ->
    Ok ("db/ident", Keyword ident, Ident ident)
  | Value.Array [ Value.Keyword "file/path"; Value.String path ] ->
    Ok ("file/path", String path, Lookup_ref ("file/path", String path))
  | _ -> Error "unsupported server entity identity"
;;

let rec generic_value = function
  | Value.Null -> Nil
  | Value.Bool value -> Bool value
  | Value.String value -> String value
  | Value.Int value -> Int value
  | Value.Int64 value -> Int (Int64.to_int value)
  | Value.Float value -> Float value
  | Value.Binary value -> String value
  | Value.Big_decimal value -> Float (float_of_string value)
  | Value.Big_int value -> Int (Int64.to_int (Int64.of_string value))
  | Value.Date value -> Instant (Int64.to_int value)
  | Value.Uuid value -> Uuid value
  | Value.Uri value -> String value
  | Value.Keyword value -> Keyword value
  | Value.Symbol value -> Symbol value
  | Value.Array values -> Vector (List.map generic_value values)
  | Value.Map entries ->
    Map (List.map (fun (key, value) -> generic_value key, generic_value value) entries)
  | Value.Set values -> Set (List.map generic_value values)
  | Value.List values -> List (List.map generic_value values)
  | Value.Tagged ("u", Value.String value) -> Uuid value
  | Value.Tagged ("m", Value.Int value) -> Instant value
  | Value.Tagged ("m", Value.Int64 value) -> Instant (Int64.to_int value)
  | Value.Tagged ("regex", Value.String value) -> Regex value
  | Value.Tagged (tag, value) -> Vector [ String tag; generic_value value ]
;;

let schema_attr db attr = List.assoc_opt attr (Datascript.schema db)

let value_for_attr db attr value =
  match schema_attr db attr with
  | Some { value_type = Some RefType; _ } ->
    bind (identity_parts value) (fun (_identity_attr, _identity_value, entity_ref) ->
      Ok (Ref_to entity_ref))
  | Some { value_type = Some TupleType; _ } ->
    (match value with
     | Value.Array values | Value.List values ->
       Ok
         (Tuple
            (List.map
               (function
                 | Value.Null -> None
                 | value -> Some (generic_value value))
               values))
     | _ -> Error ("tuple attribute " ^ attr ^ " is not a Transit array"))
  | Some _ | None -> Ok (generic_value value)
;;

let values_for_attr db attr value =
  match schema_attr db attr with
  | Some { cardinality = Many; _ } ->
    let values =
      match value with
      | Value.Set values | Value.Array values | Value.List values -> values
      | value -> [ value ]
    in
    let rec convert converted = function
      | [] -> Ok (List.rev converted)
      | value :: rest ->
        bind (value_for_attr db attr value) (fun value ->
          convert (value :: converted) rest)
    in
    convert [] values
  | Some { cardinality = One; _ } | None ->
    bind (value_for_attr db attr value) (fun value -> Ok [ value ])
;;

let decoded_attrs db attrs =
  let rec decode decoded = function
    | [] -> Ok (List.rev decoded)
    | (Value.Keyword attr, value) :: rest ->
      bind (values_for_attr db attr value) (fun values ->
        decode ((attr, values) :: decoded) rest)
    | _ -> Error "server entity attribute name is not a keyword"
  in
  decode [] attrs
;;

let temp_id identity_attr identity_value =
  let suffix =
    match identity_value with
    | Uuid value | String value | Keyword value -> value
    | _ -> string_of_int (Hashtbl.hash identity_value)
  in
  Temp_id ("remote:" ^ identity_attr ^ ":" ^ suffix)
;;

let upsert_ops db (entity : Protocol.entity) =
  bind (identity_parts entity.id) (fun (identity_attr, identity_value, identity_ref) ->
    bind (decoded_attrs db entity.attrs) (fun attrs ->
      match Datascript.entid_ref db identity_ref with
      | Some eid ->
        let retractions =
          Datascript.datoms db Eavt ~e:eid ()
          |> List.of_seq
          |> List.filter_map (fun datom ->
            if String.equal datom.a identity_attr
            then None
            else Some (Retract (Entity_id eid, datom.a, Some datom.v)))
        in
        let additions =
          attrs
          |> List.concat_map (fun (attr, values) ->
            if String.equal attr identity_attr
            then []
            else List.map (fun value -> Add (Entity_id eid, attr, value)) values)
        in
        Ok (retractions @ additions)
      | None ->
        let entity_ref = temp_id identity_attr identity_value in
        let identity = Add (entity_ref, identity_attr, identity_value) in
        let additions =
          attrs
          |> List.concat_map (fun (attr, values) ->
            if String.equal attr identity_attr
            then []
            else List.map (fun value -> Add (entity_ref, attr, value)) values)
        in
        Ok (identity :: additions)))
;;

let delete_ops db identities =
  let rec collect operations = function
    | [] -> Ok (List.rev operations)
    | identity :: rest ->
      bind (identity_parts identity) (fun (_attr, _value, entity_ref) ->
        let operations =
          match Datascript.entid_ref db entity_ref with
          | Some eid -> RetractEntity (Entity_id eid) :: operations
          | None -> operations
        in
        collect operations rest)
  in
  collect [] identities
;;

let apply_change_set conn (change : Protocol.change_set) =
  try
    let db = Datascript.conn_db conn in
    let rec collect_upserts operations = function
      | [] -> Ok (List.rev operations |> List.concat)
      | entity :: rest ->
        bind (upsert_ops db entity) (fun entity_operations ->
          collect_upserts (entity_operations :: operations) rest)
    in
    bind (collect_upserts [] change.upserts) (fun upserts ->
      bind (delete_ops db change.deleted) (fun deletions ->
        if upserts <> [] || deletions <> []
        then ignore (Datascript.transact_conn conn (upserts @ deletions));
        Ok ()))
  with
  | error -> Error (Printexc.to_string error)
;;
