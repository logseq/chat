module Ds = Datascript
module Pset = Persistent_sorted_set
module Transit = Transit_native.Transit.Json
module Value = Transit_core.Json

type storage_index_metadata =
  { count : int
  ; shift : int
  }

type storage_root_index_metadata =
  { eavt : storage_index_metadata
  ; aevt : storage_index_metadata
  ; avet : storage_index_metadata
  }

let default_schema_attr : Ds.schema_attr =
  { cardinality = Ds.One
  ; unique = None
  ; indexed = false
  ; is_component = false
  ; no_history = false
  ; doc = None
  ; value_type = None
  ; tuple_attrs = None
  ; tuple_types = None
  }

let string_of_key input =
  match input with
  | Value.Keyword text | Value.String text -> Some text
  | _ -> None

let keyword_value input =
  match input with Value.Keyword text -> Some text | _ -> None

let rec lookup key entries =
  match entries with
  | [] -> None
  | (entry_key, value) :: rest ->
    if string_of_key entry_key = Some key then Some value
    else lookup key rest

let int_value input =
  match input with
  | Value.Int number -> Some number
  | Value.Int64 number ->
    if
      Int64.compare number (Int64.of_int min_int) >= 0
      && Int64.compare number (Int64.of_int max_int) <= 0
    then Some (Int64.to_int number)
    else None
  | _ -> None

let required key entries =
  match lookup key entries with
  | Some value -> value
  | None -> invalid_arg ("Logseq storage payload is missing :" ^ key)

let required_int label input =
  match int_value input with
  | Some number -> number
  | None -> invalid_arg (label ^ " must be a Transit integer")

let cardinality_of_transit input =
  match input with
  | Value.Keyword "db.cardinality/many" -> Ds.Many
  | _ -> Ds.One

let unique_of_transit input =
  match input with
  | Value.Keyword "db.unique/value" -> Some Ds.Value
  | Value.Keyword "db.unique/identity" -> Some Ds.Identity
  | _ -> None

let value_type_of_transit input =
  match input with
  | Value.Keyword "db.type/ref" -> Some Ds.RefType
  | Value.Keyword "db.type/tuple" -> Some Ds.TupleType
  | Value.Keyword "db.type/string" -> Some Ds.StringType
  | Value.Keyword "db.type/keyword" -> Some Ds.KeywordType
  | Value.Keyword "db.type/number" -> Some Ds.NumberType
  | Value.Keyword "db.type/uuid" -> Some Ds.UuidType
  | Value.Keyword "db.type/instant" -> Some Ds.InstantType
  | _ -> None

let value_type_to_transit input =
  match input with
  | Ds.RefType -> Value.Keyword "db.type/ref"
  | Ds.TupleType -> Value.Keyword "db.type/tuple"
  | Ds.StringType -> Value.Keyword "db.type/string"
  | Ds.KeywordType -> Value.Keyword "db.type/keyword"
  | Ds.NumberType -> Value.Keyword "db.type/number"
  | Ds.UuidType -> Value.Keyword "db.type/uuid"
  | Ds.InstantType -> Value.Keyword "db.type/instant"

let tuple_attrs input =
  match input with
  | Value.Array values | Value.List values ->
    Some (List.filter_map keyword_value values)
  | _ -> None

let valid_tuple_types values =
  let types = List.filter_map value_type_of_transit values in
  if List.length types = List.length values then Some types else None

let tuple_types input =
  match input with
  | Value.Array values | Value.List values -> valid_tuple_types values
  | _ -> None

let schema_attr_of_transit input =
  match input with
  | Value.Map props ->
    List.fold_left
      (fun (attr : Ds.schema_attr) (key, value) ->
        match keyword_value key with
        | Some "db/cardinality" ->
          { attr with cardinality = cardinality_of_transit value }
        | Some "db/unique" -> { attr with unique = unique_of_transit value }
        | Some "db/index" ->
          { attr with indexed = value = Value.Bool true }
        | Some "db/isComponent" ->
          { attr with is_component = value = Value.Bool true }
        | Some "db/noHistory" ->
          { attr with no_history = value = Value.Bool true }
        | Some "db/doc" ->
          { attr with
            doc = (match value with Value.String text -> Some text | _ -> None)
          }
        | Some "db/valueType" ->
          { attr with value_type = value_type_of_transit value }
        | Some "db/tupleAttrs" ->
          { attr with tuple_attrs = tuple_attrs value }
        | Some "db/tupleTypes" ->
          { attr with tuple_types = tuple_types value }
        | _ -> attr)
      default_schema_attr props
  | _ -> default_schema_attr

let schema_of_transit input =
  match input with
  | Value.Map entries ->
    List.filter_map
      (fun (name, attr) ->
        match keyword_value name with
        | Some name -> Some (name, schema_attr_of_transit attr)
        | None -> None)
      entries
  | _ -> []

let transit_of_cardinality input =
  match input with
  | Ds.One -> Value.Keyword "db.cardinality/one"
  | Ds.Many -> Value.Keyword "db.cardinality/many"

let transit_of_unique input =
  match input with
  | Ds.Value -> Value.Keyword "db.unique/value"
  | Ds.Identity -> Value.Keyword "db.unique/identity"

let schema_attr_to_transit (attr : Ds.schema_attr) =
  let entries = [] in
  let entries =
    if attr.cardinality <> Ds.One then
      ( Value.Keyword "db/cardinality"
      , transit_of_cardinality attr.cardinality )
      :: entries
    else entries
  in
  let entries =
    match attr.unique with
    | Some value ->
      (Value.Keyword "db/unique", transit_of_unique value) :: entries
    | None -> entries
  in
  let entries =
    if attr.indexed then (Value.Keyword "db/index", Value.Bool true) :: entries
    else entries
  in
  let entries =
    if attr.is_component then
      (Value.Keyword "db/isComponent", Value.Bool true) :: entries
    else entries
  in
  let entries =
    if attr.no_history then
      (Value.Keyword "db/noHistory", Value.Bool true) :: entries
    else entries
  in
  let entries =
    match attr.doc with
    | Some text -> (Value.Keyword "db/doc", Value.String text) :: entries
    | None -> entries
  in
  let entries =
    match attr.value_type with
    | Some value ->
      (Value.Keyword "db/valueType", value_type_to_transit value) :: entries
    | None -> entries
  in
  let entries =
    match attr.tuple_attrs with
    | Some values ->
      ( Value.Keyword "db/tupleAttrs"
      , Value.Array (List.map (fun text -> Value.Keyword text) values) )
      :: entries
    | None -> entries
  in
  let entries =
    match attr.tuple_types with
    | Some values ->
      ( Value.Keyword "db/tupleTypes"
      , Value.Array (List.map value_type_to_transit values) )
      :: entries
    | None -> entries
  in
  Value.Map (List.rev entries)

let schema_to_transit (schema : Ds.schema) =
  Value.Map
    (List.map
       (fun (name, attr) -> (Value.Keyword name, schema_attr_to_transit attr))
       schema)

let rec value_of_transit input : Ds.value =
  match input with
  | Value.Null -> Ds.Nil
  | Value.Bool value -> Ds.Bool value
  | Value.String value -> Ds.String value
  | Value.Int value -> Ds.Int value
  | Value.Int64 value -> Ds.Int (Int64.to_int value)
  | Value.Float value -> Ds.Float value
  | Value.Binary value -> Ds.String value
  | Value.Big_decimal value -> Ds.Float (float_of_string value)
  | Value.Big_int value -> Ds.Int (Int64.to_int (Int64.of_string value))
  | Value.Date value -> Ds.Instant (Int64.to_int value)
  | Value.Uuid value -> Ds.Uuid value
  | Value.Uri value -> Ds.String value
  | Value.Keyword value -> Ds.Keyword value
  | Value.Symbol value -> Ds.Symbol value
  | Value.Array values -> Ds.Vector (List.map value_of_transit values)
  | Value.Map entries ->
    Ds.Map
      (List.map
         (fun (key, value) -> (value_of_transit key, value_of_transit value))
         entries)
  | Value.Set values -> Ds.Set (List.map value_of_transit values)
  | Value.List values -> Ds.List (List.map value_of_transit values)
  | Value.Tagged ("u", Value.String value) -> Ds.Uuid value
  | Value.Tagged ("m", Value.Int value) -> Ds.Instant value
  | Value.Tagged ("m", Value.Int64 value) -> Ds.Instant (Int64.to_int value)
  | Value.Tagged ("regex", Value.String value) -> Ds.Regex value
  | Value.Tagged (tag, value) ->
    Ds.Vector [ Ds.String tag; value_of_transit value ]

let rec value_to_transit input : Value.value =
  match input with
  | Ds.Nil -> Value.Null
  | Ds.Int value -> Value.Int value
  | Ds.Float value -> Value.Float value
  | Ds.String value -> Value.String value
  | Ds.Symbol value -> Value.Symbol value
  | Ds.Bool value -> Value.Bool value
  | Ds.Keyword value -> Value.Keyword value
  | Ds.Uuid value -> Value.Tagged ("u", Value.String value)
  | Ds.Instant value -> Value.Tagged ("m", Value.Int value)
  | Ds.Regex value -> Value.Tagged ("regex", Value.String value)
  | Ds.Ref value -> Value.Int value
  | Ds.List values -> Value.List (List.map value_to_transit values)
  | Ds.Vector values -> Value.Array (List.map value_to_transit values)
  | Ds.Map entries ->
    Value.Map
      (List.map
         (fun (key, value) -> (value_to_transit key, value_to_transit value))
         entries)
  | Ds.Set values -> Value.Set (List.map value_to_transit values)
  | Ds.Tuple values ->
    Value.Array
      (List.map
         (fun value ->
           match value with
           | None -> Value.Null
           | Some value -> value_to_transit value)
         values)
  | Ds.TxRef -> Value.Keyword "db/current-tx"
  | Ds.Ref_to _ -> invalid_arg "storage payload cannot contain unresolved refs"

let datom_of_transit input : Ds.datom =
  match input with
  | Value.Array [ entity; attr; value; tx ] ->
    let e = required_int "datom entity" entity in
    let a =
      match keyword_value attr with
      | Some attr -> attr
      | None -> invalid_arg "storage datom attr must be a Transit keyword"
    in
    let tx = required_int "datom tx" tx in
    { e; a; v = value_of_transit value; tx = abs tx; added = tx >= 0 }
  | _ -> invalid_arg "storage datom must be [e a v tx]"

let datom_to_transit (datom : Ds.datom) =
  Value.Array
    [
      Value.Int datom.e;
      Value.Keyword datom.a;
      value_to_transit datom.v;
      Value.Int (if datom.added then datom.tx else -datom.tx);
    ]

let datoms_of_transit input =
  match input with
  | Value.Array values | Value.List values ->
    List.map datom_of_transit values
  | _ -> invalid_arg "storage datoms must be a Transit array"

let address_of_transit label input =
  match input with
  | Value.Int value -> string_of_int value
  | Value.Int64 value -> Int64.to_string value
  | Value.String value -> value
  | _ -> invalid_arg (label ^ " must be a storage address")

let address_to_transit address =
  match int_of_string_opt address with
  | Some number -> Value.Int number
  | None ->
    invalid_arg ("Logseq SQLite storage address is not an integer: " ^ address)

let address_of_json input =
  match input with
  | `Int number -> string_of_int number
  | `Intlit text -> text
  | _ -> invalid_arg "Logseq storage addresses must be integers"

let addresses_of_json addresses =
  match addresses with
  | None -> []
  | Some source ->
    (match Yojson.Safe.from_string source with
     | `List values -> List.map address_of_json values
     | _ -> invalid_arg "Logseq storage addresses must be a JSON array")

let address_to_json address =
  match int_of_string_opt address with
  | Some number -> `Int number
  | None -> invalid_arg "Logseq storage child address is not an integer"

let addresses_to_json addresses =
  Yojson.Safe.to_string (`List (List.map address_to_json addresses))

let root_of_transit entries : Ds.storage_root =
  { storage_schema = schema_of_transit (required "schema" entries)
  ; storage_max_eid = required_int "root :max-eid" (required "max-eid" entries)
  ; storage_max_tx = required_int "root :max-tx" (required "max-tx" entries)
  ; storage_eavt = address_of_transit "root :eavt" (required "eavt" entries)
  ; storage_aevt = address_of_transit "root :aevt" (required "aevt" entries)
  ; storage_avet = address_of_transit "root :avet" (required "avet" entries)
  ; storage_duplicate_datoms =
      (match lookup "duplicate-datoms" entries with
       | None -> []
       | Some value -> datoms_of_transit value)
  ; storage_max_addr =
      required_int "root :max-addr" (required "max-addr" entries)
  ; storage_branching_factor =
      required_int "root :branching-factor" (required "branching-factor" entries)
  ; storage_ref_type =
      (match required "ref-type" entries with
       | Value.Keyword "soft" | Value.Keyword "weak" -> Pset.Weak
       | _ -> Pset.Strong)
  }

let index_metadata_to_transit metadata =
  Value.Map
    [
      (Value.Keyword "count", Value.Int metadata.count);
      (Value.Keyword "shift", Value.Int metadata.shift);
    ]

let root_to_transit index_metadata (root : Ds.storage_root) =
  let metadata =
    match index_metadata with
    | None -> []
    | Some metadata ->
      [
        ( Value.Keyword "eavt-metadata"
        , index_metadata_to_transit metadata.eavt );
        ( Value.Keyword "aevt-metadata"
        , index_metadata_to_transit metadata.aevt );
        ( Value.Keyword "avet-metadata"
        , index_metadata_to_transit metadata.avet );
      ]
  in
  Value.Map
    ([
       (Value.Keyword "schema", schema_to_transit root.storage_schema);
       (Value.Keyword "max-eid", Value.Int root.storage_max_eid);
       (Value.Keyword "max-tx", Value.Int root.storage_max_tx);
       (Value.Keyword "eavt", address_to_transit root.storage_eavt);
       (Value.Keyword "aevt", address_to_transit root.storage_aevt);
       (Value.Keyword "avet", address_to_transit root.storage_avet);
     ]
    @ metadata
    @ [
        ( Value.Keyword "duplicate-datoms"
        , Value.Array (List.map datom_to_transit root.storage_duplicate_datoms)
        );
        (Value.Keyword "max-addr", Value.Int root.storage_max_addr);
        ( Value.Keyword "branching-factor"
        , Value.Int root.storage_branching_factor );
        ( Value.Keyword "ref-type"
        , Value.Keyword
            (match root.storage_ref_type with
             | Pset.Weak -> "soft"
             | Pset.Strong -> "strong") );
      ])

let decode addresses content : Ds.storage_payload =
  match Transit.of_string content with
  | Value.Map entries ->
    if Option.is_some (lookup "schema" entries) then
      Ds.Storage_root (root_of_transit entries)
    else if Option.is_some (lookup "keys" entries) then begin
      let keys = datoms_of_transit (required "keys" entries) in
      let children = addresses_of_json addresses in
      Ds.Storage_node
        (if children = [] then Pset.Leaf keys else Pset.Branch (keys, children))
    end
    else invalid_arg "unknown Logseq storage payload"
  | Value.Array groups | Value.List groups ->
    Ds.Storage_tail (List.map datoms_of_transit groups)
  | _ -> invalid_arg "unknown Logseq storage payload"

let encode_node datoms =
  Transit.to_string ~mode:Transit.Verbose
    (Value.Map
       [ (Value.Keyword "keys", Value.Array (List.map datom_to_transit datoms)) ])

let encode root_index_metadata payload =
  match payload with
  | Ds.Storage_root root ->
    ( Transit.to_string ~mode:Transit.Verbose
        (root_to_transit root_index_metadata root)
    , None )
  | Ds.Storage_node (Pset.Leaf datoms) -> (encode_node datoms, None)
  | Ds.Storage_node (Pset.Branch (keys, children)) ->
    (encode_node keys, Some (addresses_to_json children))
  | Ds.Storage_tail groups ->
    ( Transit.to_string ~mode:Transit.Verbose
        (Value.Array
           (List.map
              (fun datoms -> Value.Array (List.map datom_to_transit datoms))
              groups))
    , None )
