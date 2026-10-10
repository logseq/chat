module Ds = Datascript
module Transit = Transit_native.Transit.Json

let lookup_value entity attr =
  match Ds.Entity.entity_attr_raw entity attr with
  | Some (Ds.One_value scalar) -> Some scalar
  | _ -> None

let stable_entity_ref db eid =
  match Ds.entity db (Ds.Entity_id eid) with
  | Some entity ->
    (match (lookup_value entity "block/uuid", lookup_value entity "db/ident") with
     | Some (Ds.Uuid uuid), _ ->
       Ds.Lookup_ref ("block/uuid", Ds.Uuid uuid)
     | _, Some (Ds.Keyword ident) ->
       Ds.Lookup_ref ("db/ident", Ds.Keyword ident)
     | _ -> Ds.Entity_id eid)
  | None -> Ds.Entity_id eid

let rec transit_of_entity_ref db entity_ref =
  match entity_ref with
  | Ds.Entity_id eid ->
    (match stable_entity_ref db eid with
     | Ds.Entity_id stable_eid -> Transit.Int stable_eid
     | stable_ref -> transit_of_entity_ref db stable_ref)
  | Ds.Temp_id temp_id -> Transit.String temp_id
  | Ds.CurrentTx -> Transit.Keyword "db/current-tx"
  | Ds.Ident ident -> Transit.Keyword ident
  | Ds.Lookup_ref (attr, value) ->
    Transit.Array
      [ Transit.Keyword attr; transit_of_value db value ]

and transit_of_value db value =
  match value with
  | Ds.Nil -> Transit.Null
  | Ds.Int64 number -> Transit.Int64 number
  | Ds.Float number -> Transit.Float number
  | Ds.String text -> Transit.String text
  | Ds.Symbol symbol -> Transit.Symbol symbol
  | Ds.Bool flag -> Transit.Bool flag
  | Ds.Keyword keyword -> Transit.Keyword keyword
  | Ds.Uuid uuid -> Transit.Uuid uuid
  | Ds.Instant instant -> Transit.Date instant
  | Ds.Regex pattern -> Transit.Tagged ("regex", Transit.String pattern)
  | Ds.Ref eid -> transit_of_entity_ref db (stable_entity_ref db eid)
  | Ds.List values ->
    Transit.List (List.map (transit_of_value db) values)
  | Ds.Vector values ->
    Transit.Array (List.map (transit_of_value db) values)
  | Ds.Map entries ->
    Transit.Map
      (List.map
         (fun (key, value) ->
           (transit_of_value db key, transit_of_value db value))
         entries)
  | Ds.Set values ->
    Transit.Set (List.map (transit_of_value db) values)
  | Ds.Tuple values ->
    Transit.Array
      (List.map
         (fun value ->
           match value with
           | None -> Transit.Null
           | Some item -> transit_of_value db item)
         values)
  | Ds.TxRef -> Transit.Keyword "db/current-tx"
  | Ds.Ref_to entity_ref -> transit_of_entity_ref db entity_ref

let rec transit_of_tx_value db value =
  match value with
  | Ds.One_value value -> transit_of_value db value
  | Ds.Many_values values ->
    Transit.Array (List.map (transit_of_value db) values)
  | Ds.One_entity entity -> transit_of_entity db entity
  | Ds.Many_entities entities ->
    Transit.Array (List.map (transit_of_entity db) entities)

and transit_of_entity db entity =
  let id =
    match entity.Ds.db_id with
    | Some entity_ref ->
      [ ( Transit.Keyword "db/id"
        , transit_of_entity_ref db entity_ref ) ]
    | None -> []
  in
  Transit.Map
    (id
     @ List.map
         (fun (attr, value) ->
           (Transit.Keyword attr, transit_of_tx_value db value))
         entity.Ds.attrs)

let protected_attr attr = attr = "block/title" || attr = "block/name"

let encrypt_value encrypt attr value =
  if protected_attr attr then
    match value with
    | Ds.String plaintext ->
      (match encrypt plaintext with
       | Ok ciphertext -> Ok (Ds.String ciphertext)
       | Error _ as error -> error)
    | _ -> Error ("protected attribute " ^ attr ^ " must be a string")
  else Ok value

let encrypt_values encrypt attr values =
  List.fold_left
    (fun acc value ->
      let ( let* ) = Result.bind in
      let* encrypted = acc in
      let* value = encrypt_value encrypt attr value in
      Ok (encrypted @ [ value ]))
    (Ok []) values

let rec encrypt_entity encrypt (entity : Ds.tx_entity) =
  List.fold_left
    (fun acc (attr, value) ->
      let ( let* ) = Result.bind in
      let* encrypted = acc in
      let* value = encrypt_tx_value encrypt attr value in
      Ok (encrypted @ [ (attr, value) ]))
    (Ok []) entity.Ds.attrs
  |> Result.map (fun attrs -> { entity with Ds.attrs })

and encrypt_tx_value encrypt attr value =
  match value with
  | Ds.One_value value ->
    Result.map
      (fun value -> Ds.One_value value)
      (encrypt_value encrypt attr value)
  | Ds.Many_values values ->
    Result.map
      (fun values -> Ds.Many_values values)
      (encrypt_values encrypt attr values)
  | Ds.One_entity entity ->
    Result.map
      (fun entity -> Ds.One_entity entity)
      (encrypt_entity encrypt entity)
  | Ds.Many_entities entities ->
    let rec loop acc entities =
      match entities with
      | [] -> Ok (Ds.Many_entities (List.rev acc))
      | entity :: rest ->
        (match encrypt_entity encrypt entity with
         | Ok entity -> loop (entity :: acc) rest
         | Error _ as error -> error)
    in
    loop [] entities

let encrypt_entities encrypt entities =
  let rec loop acc entities =
    match entities with
    | [] -> Ok (List.rev acc)
    | entity :: rest ->
      (match encrypt_entity encrypt entity with
       | Ok entity -> loop (entity :: acc) rest
       | Error _ as error -> error)
  in
  loop [] entities

let encrypt_tx_op encrypt operation =
  let ( let* ) = Result.bind in
  match operation with
  | Ds.Add (entity_ref, attr, value) ->
    let* value = encrypt_value encrypt attr value in
    Ok (Ds.Add (entity_ref, attr, value))
  | Ds.Retract (entity_ref, attr, Some value) ->
    let* value = encrypt_value encrypt attr value in
    Ok (Ds.Retract (entity_ref, attr, Some value))
  | Ds.CompareAndSet (entity_ref, attr, expected, value) ->
    let* expected =
      match expected with
      | None -> Ok None
      | Some value ->
        Result.map
          (fun value -> Some value)
          (encrypt_value encrypt attr value)
    in
    let* value = encrypt_value encrypt attr value in
    Ok (Ds.CompareAndSet (entity_ref, attr, expected, value))
  | Ds.Entity entity ->
    Result.map
      (fun entity -> Ds.Entity entity)
      (encrypt_entity encrypt entity)
  | Ds.Raw_datom datom ->
    let* value = encrypt_value encrypt datom.Ds.a datom.Ds.v in
    Ok (Ds.Raw_datom { datom with Ds.v = value })
  | _ -> Ok operation

let transit_of_tx_op db operation =
  match operation with
  | Ds.Add (entity_ref, attr, value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/add"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; transit_of_value db value
         ])
  | Ds.Retract (entity_ref, attr, Some value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/retract"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; transit_of_value db value
         ])
  | Ds.Retract (entity_ref, attr, None) | Ds.RetractAttr (entity_ref, attr) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db.fn/retractAttribute"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ])
  | Ds.RetractEntity entity_ref ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/retractEntity"
         ; transit_of_entity_ref db entity_ref
         ])
  | Ds.CompareAndSet (entity_ref, attr, expected, value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db.fn/cas"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; (match expected with
            | None -> Transit.Null
            | Some value -> transit_of_value db value)
         ; transit_of_value db value
         ])
  | Ds.Entity entity -> Ok (transit_of_entity db entity)
  | Ds.Raw_datom datom ->
    Ok
      (Transit.Array
         [ Transit.Keyword (if datom.Ds.added then "db/add" else "db/retract")
         ; transit_of_entity_ref db (stable_entity_ref db datom.Ds.e)
         ; Transit.Keyword datom.Ds.a
         ; transit_of_value db datom.Ds.v
         ])
  | Ds.CallIdent (entity_ref, values) ->
    Ok
      (Transit.Array
         (transit_of_entity_ref db entity_ref
          :: List.map (transit_of_value db) values))
  | _ -> Error "transaction functions cannot be sent over sync"

let encode encrypt db tx =
  let ( let* ) = Result.bind in
  let* encoded =
    List.fold_left
      (fun acc operation ->
        let* encoded = acc in
        let* operation = encrypt_tx_op encrypt operation in
        let* value = transit_of_tx_op db operation in
        Ok (encoded @ [ value ]))
      (Ok []) tx
  in
  Ok (Transit.to_string (Transit.Array encoded))
