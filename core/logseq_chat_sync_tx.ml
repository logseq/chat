open Datascript

module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json

let lookup_value entity attr =
  match Datascript.Entity.entity_attr_raw entity attr with
  | Some (One_value value) -> Some value
  | _ -> None
;;

let stable_entity_ref db eid =
  match entity db (Entity_id eid) with
  | Some entity ->
    (match lookup_value entity "block/uuid", lookup_value entity "db/ident" with
     | Some (Uuid uuid), _ -> Lookup_ref ("block/uuid", Uuid uuid)
     | _, Some (Keyword ident) -> Lookup_ref ("db/ident", Keyword ident)
     | _ -> Entity_id eid)
  | None -> Entity_id eid
;;

let rec transit_of_entity_ref db = function
  | Entity_id eid ->
    (match stable_entity_ref db eid with
     | Entity_id stable_eid -> Transit.Int stable_eid
     | stable_ref -> transit_of_entity_ref db stable_ref)
  | Temp_id temp_id -> Transit.String temp_id
  | CurrentTx -> Transit.Keyword "db/current-tx"
  | Ident ident -> Transit.Keyword ident
  | Lookup_ref (attr, value) ->
    Transit.Array [ Transit.Keyword attr; transit_of_value db value ]

and transit_of_value db = function
  | Nil -> Transit.Null
  | Int value -> Transit.Int value
  | Float value -> Transit.Float value
  | String value -> Transit.String value
  | Symbol value -> Transit.Symbol value
  | Bool value -> Transit.Bool value
  | Keyword value -> Transit.Keyword value
  | Uuid value -> Transit.Uuid value
  | Instant value -> Transit.Date (Int64.of_int value)
  | Regex value -> Transit.Tagged ("regex", Transit.String value)
  | Ref eid -> transit_of_entity_ref db (stable_entity_ref db eid)
  | List values -> Transit.List (List.map (transit_of_value db) values)
  | Vector values -> Transit.Array (List.map (transit_of_value db) values)
  | Map entries ->
    Transit.Map
      (List.map
         (fun (key, value) -> transit_of_value db key, transit_of_value db value)
         entries)
  | Set values -> Transit.Set (List.map (transit_of_value db) values)
  | Tuple values ->
    Transit.Array
      (List.map
         (Option.fold ~none:Transit.Null ~some:(transit_of_value db))
         values)
  | TxRef -> Transit.Keyword "db/current-tx"
  | Ref_to entity_ref -> transit_of_entity_ref db entity_ref
;;

let rec transit_of_tx_value db = function
  | One_value value -> transit_of_value db value
  | Many_values values -> Transit.Array (List.map (transit_of_value db) values)
  | One_entity entity -> transit_of_entity db entity
  | Many_entities entities -> Transit.Array (List.map (transit_of_entity db) entities)

and transit_of_entity db entity =
  let id =
    match entity.db_id with
    | Some entity_ref -> [ Transit.Keyword "db/id", transit_of_entity_ref db entity_ref ]
    | None -> []
  in
  Transit.Map
    (id
     @ List.map
         (fun (attr, value) -> Transit.Keyword attr, transit_of_tx_value db value)
         entity.attrs)
;;

let protected_attr attr =
  String.equal attr "block/title" || String.equal attr "block/name"
;;

let encrypt_value encrypt attr value =
  if protected_attr attr
  then
    match value with
    | String plaintext -> Result.map (fun ciphertext -> String ciphertext) (encrypt plaintext)
    | _ -> Error ("protected attribute " ^ attr ^ " must be a string")
  else Ok value
;;

let rec encrypt_tx_value encrypt attr = function
  | One_value value -> Result.map (fun value -> One_value value) (encrypt_value encrypt attr value)
  | Many_values values ->
    let rec loop encrypted = function
      | [] -> Ok (Many_values (List.rev encrypted))
      | value :: rest ->
        Result.bind (encrypt_value encrypt attr value) (fun value ->
          loop (value :: encrypted) rest)
    in
    loop [] values
  | One_entity entity ->
    Result.map (fun entity -> One_entity entity) (encrypt_entity encrypt entity)
  | Many_entities entities ->
    let rec loop encrypted = function
      | [] -> Ok (Many_entities (List.rev encrypted))
      | entity :: rest ->
        Result.bind (encrypt_entity encrypt entity) (fun entity ->
          loop (entity :: encrypted) rest)
    in
    loop [] entities

and encrypt_entity encrypt (entity : tx_entity) =
  let rec loop attrs = function
    | [] -> Ok { entity with attrs = List.rev attrs }
    | (attr, value) :: rest ->
      Result.bind (encrypt_tx_value encrypt attr value) (fun value ->
        loop ((attr, value) :: attrs) rest)
  in
  loop [] entity.attrs
;;

let encrypt_tx_op encrypt = function
  | Add (entity_ref, attr, value) ->
    Result.map (fun value -> Add (entity_ref, attr, value)) (encrypt_value encrypt attr value)
  | Retract (entity_ref, attr, Some value) ->
    Result.map
      (fun value -> Retract (entity_ref, attr, Some value))
      (encrypt_value encrypt attr value)
  | CompareAndSet (entity_ref, attr, expected, value) ->
    let expected =
      match expected with
      | None -> Ok None
      | Some value -> Result.map Option.some (encrypt_value encrypt attr value)
    in
    Result.bind expected (fun expected ->
      Result.map
        (fun value -> CompareAndSet (entity_ref, attr, expected, value))
        (encrypt_value encrypt attr value))
  | Entity entity -> Result.map (fun entity -> Entity entity) (encrypt_entity encrypt entity)
  | Raw_datom datom ->
    Result.map
      (fun value -> Raw_datom { datom with v = value })
      (encrypt_value encrypt datom.a datom.v)
  | (Retract (_, _, None) | RetractAttr _ | RetractEntity _ | CallIdent _ | InstallTxFn _ | Call _) as operation ->
    Ok operation
;;

let transit_of_tx_op db = function
  | Add (entity_ref, attr, value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/add"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; transit_of_value db value
         ])
  | Retract (entity_ref, attr, Some value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/retract"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; transit_of_value db value
         ])
  | Retract (entity_ref, attr, None) | RetractAttr (entity_ref, attr) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db.fn/retractAttribute"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ])
  | RetractEntity entity_ref ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/retractEntity"; transit_of_entity_ref db entity_ref ])
  | CompareAndSet (entity_ref, attr, expected, value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db.fn/cas"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; Option.fold
             ~none:Transit.Null
             ~some:(transit_of_value db)
             expected
         ; transit_of_value db value
         ])
  | Entity entity -> Ok (transit_of_entity db entity)
  | Raw_datom datom ->
    Ok
      (Transit.Array
         [ Transit.Keyword (if datom.added then "db/add" else "db/retract")
         ; transit_of_entity_ref db (stable_entity_ref db datom.e)
         ; Transit.Keyword datom.a
         ; transit_of_value db datom.v
         ])
  | CallIdent (entity_ref, values) ->
    Ok
      (Transit.Array
         (transit_of_entity_ref db entity_ref
          :: List.map (transit_of_value db) values))
  | InstallTxFn _ | Call _ -> Error "transaction functions cannot be sent over sync"
;;

let encode ?(encrypt_protected = fun value -> Ok value) db tx =
  let rec loop encoded = function
    | [] -> Ok (List.rev encoded)
    | operation :: rest ->
      Result.bind (encrypt_tx_op encrypt_protected operation) (fun operation ->
        match transit_of_tx_op db operation with
        | Ok value -> loop (value :: encoded) rest
        | Error _ as error -> error)
  in
  Result.map
    (fun values -> Codec.to_string ~mode:Codec.Verbose (Transit.Array values))
    (loop [] tx)
;;
