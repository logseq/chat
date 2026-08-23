module Ds = Datascript
module PSet = Persistent_sorted_set
module Transit = Transit_native.Transit.Json

open Ds

type index_metadata =
  { count : int
  ; shift : int
  }

type root_index_metadata =
  { eavt : index_metadata
  ; aevt : index_metadata
  ; avet : index_metadata
  }

let default_schema_attr =
  { cardinality = One
  ; unique = None
  ; indexed = false
  ; is_component = false
  ; no_history = false
  ; doc = None
  ; value_type = None
  ; tuple_attrs = None
  ; tuple_types = None
  }
;;

let string_of_key = function
  | Transit.Keyword value | Transit.String value -> Some value
  | _ -> None
;;

let keyword = function
  | Transit.Keyword value -> Some value
  | _ -> None
;;

let lookup key entries =
  List.find_map
    (fun (entry_key, value) ->
      match string_of_key entry_key with
      | Some entry_key when String.equal entry_key key -> Some value
      | Some _ | None -> None)
    entries
;;

let int_value = function
  | Transit.Int value -> Some value
  | Transit.Int64 value
    when value >= Int64.of_int min_int && value <= Int64.of_int max_int ->
    Some (Int64.to_int value)
  | _ -> None
;;

let required key entries =
  match lookup key entries with
  | Some value -> value
  | None -> invalid_arg ("Logseq storage payload is missing :" ^ key)
;;

let required_int label value =
  match int_value value with
  | Some value -> value
  | None -> invalid_arg (label ^ " must be a Transit integer")
;;

let cardinality_of_transit = function
  | Transit.Keyword "db.cardinality/many" -> Many
  | Transit.Keyword "db.cardinality/one" | _ -> One
;;

let unique_of_transit = function
  | Transit.Keyword "db.unique/value" -> Some Value
  | Transit.Keyword "db.unique/identity" -> Some Identity
  | _ -> None
;;

let value_type_of_transit = function
  | Transit.Keyword "db.type/ref" -> Some RefType
  | Transit.Keyword "db.type/tuple" -> Some TupleType
  | Transit.Keyword "db.type/string" -> Some StringType
  | Transit.Keyword "db.type/keyword" -> Some KeywordType
  | Transit.Keyword "db.type/number" -> Some NumberType
  | Transit.Keyword "db.type/uuid" -> Some UuidType
  | Transit.Keyword "db.type/instant" -> Some InstantType
  | _ -> None
;;

let value_type_to_transit = function
  | RefType -> Transit.Keyword "db.type/ref"
  | TupleType -> Transit.Keyword "db.type/tuple"
  | StringType -> Transit.Keyword "db.type/string"
  | KeywordType -> Transit.Keyword "db.type/keyword"
  | NumberType -> Transit.Keyword "db.type/number"
  | UuidType -> Transit.Keyword "db.type/uuid"
  | InstantType -> Transit.Keyword "db.type/instant"
;;

let schema_attr_of_transit = function
  | Transit.Map props ->
    List.fold_left
      (fun attr (key, value) ->
        match keyword key with
        | Some "db/cardinality" ->
          { attr with cardinality = cardinality_of_transit value }
        | Some "db/unique" -> { attr with unique = unique_of_transit value }
        | Some "db/index" ->
          { attr with
            indexed =
              (match value with
               | Transit.Bool value -> value
               | _ -> false)
          }
        | Some "db/isComponent" ->
          { attr with
            is_component =
              (match value with
               | Transit.Bool value -> value
               | _ -> false)
          }
        | Some "db/noHistory" ->
          { attr with
            no_history =
              (match value with
               | Transit.Bool value -> value
               | _ -> false)
          }
        | Some "db/doc" ->
          { attr with
            doc =
              (match value with
               | Transit.String value -> Some value
               | _ -> None)
          }
        | Some "db/valueType" -> { attr with value_type = value_type_of_transit value }
        | Some "db/tupleAttrs" ->
          { attr with
            tuple_attrs =
              (match value with
               | Transit.Array values | Transit.List values ->
                 Some (List.filter_map keyword values)
               | _ -> None)
          }
        | Some "db/tupleTypes" ->
          { attr with
            tuple_types =
              (match value with
               | Transit.Array values | Transit.List values ->
                 let types = List.filter_map value_type_of_transit values in
                 if List.length types = List.length values then Some types else None
               | _ -> None)
          }
        | Some _ | None -> attr)
      default_schema_attr
      props
  | _ -> default_schema_attr
;;

let schema_of_transit = function
  | Transit.Map entries ->
    List.filter_map
      (fun (name, attr) ->
        match keyword name with
        | Some name -> Some (name, schema_attr_of_transit attr)
        | None -> None)
      entries
  | _ -> []
;;

let transit_of_cardinality = function
  | One -> Transit.Keyword "db.cardinality/one"
  | Many -> Transit.Keyword "db.cardinality/many"
;;

let transit_of_unique = function
  | Value -> Transit.Keyword "db.unique/value"
  | Identity -> Transit.Keyword "db.unique/identity"
;;

let schema_attr_to_transit attr =
  let entries = ref [] in
  let add key value = entries := (Transit.Keyword key, value) :: !entries in
  if attr.cardinality <> One
  then add "db/cardinality" (transit_of_cardinality attr.cardinality);
  Option.iter (fun value -> add "db/unique" (transit_of_unique value)) attr.unique;
  if attr.indexed then add "db/index" (Transit.Bool true);
  if attr.is_component then add "db/isComponent" (Transit.Bool true);
  if attr.no_history then add "db/noHistory" (Transit.Bool true);
  Option.iter (fun value -> add "db/doc" (Transit.String value)) attr.doc;
  Option.iter (fun value -> add "db/valueType" (value_type_to_transit value)) attr.value_type;
  Option.iter
    (fun values ->
      add "db/tupleAttrs" (Transit.Array (List.map (fun value -> Transit.Keyword value) values)))
    attr.tuple_attrs;
  Option.iter
    (fun values -> add "db/tupleTypes" (Transit.Array (List.map value_type_to_transit values)))
    attr.tuple_types;
  Transit.Map (List.rev !entries)
;;

let schema_to_transit schema =
  Transit.Map
    (List.map
       (fun (name, attr) -> Transit.Keyword name, schema_attr_to_transit attr)
       schema)
;;

let rec value_of_transit = function
  | Transit.Null -> Nil
  | Transit.Bool value -> Bool value
  | Transit.String value -> String value
  | Transit.Int value -> Int value
  | Transit.Int64 value -> Int (Int64.to_int value)
  | Transit.Float value -> Float value
  | Transit.Binary value -> String value
  | Transit.Big_decimal value -> Float (float_of_string value)
  | Transit.Big_int value -> Int (Int64.to_int (Int64.of_string value))
  | Transit.Date value -> Instant (Int64.to_int value)
  | Transit.Uuid value -> Uuid value
  | Transit.Uri value -> String value
  | Transit.Keyword value -> Keyword value
  | Transit.Symbol value -> Symbol value
  | Transit.Array values -> Vector (List.map value_of_transit values)
  | Transit.Map entries ->
    Map (List.map (fun (key, value) -> value_of_transit key, value_of_transit value) entries)
  | Transit.Set values -> Set (List.map value_of_transit values)
  | Transit.List values -> List (List.map value_of_transit values)
  | Transit.Tagged ("u", Transit.String value) -> Uuid value
  | Transit.Tagged ("m", Transit.Int value) -> Instant value
  | Transit.Tagged ("m", Transit.Int64 value) -> Instant (Int64.to_int value)
  | Transit.Tagged ("regex", Transit.String value) -> Regex value
  | Transit.Tagged (tag, value) -> Vector [ String tag; value_of_transit value ]
;;

let rec value_to_transit = function
  | Nil -> Transit.Null
  | Int value -> Transit.Int value
  | Float value -> Transit.Float value
  | String value -> Transit.String value
  | Symbol value -> Transit.Symbol value
  | Bool value -> Transit.Bool value
  | Keyword value -> Transit.Keyword value
  | Uuid value -> Transit.Tagged ("u", Transit.String value)
  | Instant value -> Transit.Tagged ("m", Transit.Int value)
  | Regex value -> Transit.Tagged ("regex", Transit.String value)
  | Ref value -> Transit.Int value
  | List values -> Transit.List (List.map value_to_transit values)
  | Vector values -> Transit.Array (List.map value_to_transit values)
  | Map entries ->
    Transit.Map
      (List.map (fun (key, value) -> value_to_transit key, value_to_transit value) entries)
  | Set values -> Transit.Set (List.map value_to_transit values)
  | Tuple values ->
    Transit.Array
      (List.map
         (function
           | None -> Transit.Null
           | Some value -> value_to_transit value)
         values)
  | TxRef -> Transit.Keyword "db/current-tx"
  | Ref_to _ -> invalid_arg "storage payload cannot contain unresolved refs"
;;

let datom_of_transit = function
  | Transit.Array [ entity; attr; value; tx ] ->
    let e = required_int "datom entity" entity in
    let a =
      match keyword attr with
      | Some attr -> attr
      | None -> invalid_arg "storage datom attr must be a Transit keyword"
    in
    let tx = required_int "datom tx" tx in
    { e; a; v = value_of_transit value; tx = abs tx; added = tx >= 0 }
  | _ -> invalid_arg "storage datom must be [e a v tx]"
;;

let datom_to_transit datom =
  let tx = if datom.added then datom.tx else -datom.tx in
  Transit.Array
    [ Transit.Int datom.e
    ; Transit.Keyword datom.a
    ; value_to_transit datom.v
    ; Transit.Int tx
    ]
;;

let datoms_of_transit = function
  | Transit.Array values | Transit.List values -> List.map datom_of_transit values
  | _ -> invalid_arg "storage datoms must be a Transit array"
;;

let address_of_transit label value =
  match value with
  | Transit.Int value -> string_of_int value
  | Transit.Int64 value -> Int64.to_string value
  | Transit.String value -> value
  | _ -> invalid_arg (label ^ " must be a storage address")
;;

let address_to_transit address =
  match int_of_string_opt address with
  | Some address -> Transit.Int address
  | None -> invalid_arg ("Logseq SQLite storage address is not an integer: " ^ address)
;;

let addresses_of_json = function
  | None -> []
  | Some addresses ->
    (match Yojson.Safe.from_string addresses with
     | `List values ->
       List.map
         (function
           | `Int value -> string_of_int value
           | `Intlit value -> value
           | _ -> invalid_arg "Logseq storage addresses must be integers")
         values
     | _ -> invalid_arg "Logseq storage addresses must be a JSON array")
;;

let addresses_to_json addresses =
  Yojson.Safe.to_string
    (`List
      (List.map
         (fun address ->
           match int_of_string_opt address with
           | Some address -> `Int address
           | None -> invalid_arg "Logseq storage child address is not an integer")
         addresses))
;;

let root_of_transit entries =
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
  ; storage_max_addr = required_int "root :max-addr" (required "max-addr" entries)
  ; storage_branching_factor =
      required_int "root :branching-factor" (required "branching-factor" entries)
  ; storage_ref_type =
      (match required "ref-type" entries with
       | Transit.Keyword "soft" | Transit.Keyword "weak" -> PSet.Weak
       | Transit.Keyword "strong" | _ -> PSet.Strong)
  }
;;

let index_metadata_to_transit metadata =
  Transit.Map
    [ Transit.Keyword "count", Transit.Int metadata.count
    ; Transit.Keyword "shift", Transit.Int metadata.shift
    ]
;;

let root_to_transit ?index_metadata root =
  let persisted_index_metadata =
    match index_metadata with
    | None -> []
    | Some metadata ->
      [ Transit.Keyword "eavt-metadata", index_metadata_to_transit metadata.eavt
      ; Transit.Keyword "aevt-metadata", index_metadata_to_transit metadata.aevt
      ; Transit.Keyword "avet-metadata", index_metadata_to_transit metadata.avet
      ]
  in
  Transit.Map
    ([ Transit.Keyword "schema", schema_to_transit root.storage_schema
     ; Transit.Keyword "max-eid", Transit.Int root.storage_max_eid
     ; Transit.Keyword "max-tx", Transit.Int root.storage_max_tx
     ; Transit.Keyword "eavt", address_to_transit root.storage_eavt
     ; Transit.Keyword "aevt", address_to_transit root.storage_aevt
     ; Transit.Keyword "avet", address_to_transit root.storage_avet
     ]
     @ persisted_index_metadata
     @ [ ( Transit.Keyword "duplicate-datoms"
         , Transit.Array (List.map datom_to_transit root.storage_duplicate_datoms) )
       ; Transit.Keyword "max-addr", Transit.Int root.storage_max_addr
       ; Transit.Keyword "branching-factor", Transit.Int root.storage_branching_factor
       ; ( Transit.Keyword "ref-type"
         , Transit.Keyword
             (match root.storage_ref_type with
              | PSet.Weak -> "soft"
              | PSet.Strong -> "strong") )
       ])
;;

let decode ?addresses content =
  match Transit.of_string content with
  | Transit.Map entries when Option.is_some (lookup "schema" entries) ->
    Storage_root (root_of_transit entries)
  | Transit.Map entries when Option.is_some (lookup "keys" entries) ->
    let keys = datoms_of_transit (required "keys" entries) in
    (match addresses_of_json addresses with
     | [] -> Storage_node (PSet.Leaf keys)
     | children -> Storage_node (PSet.Branch (keys, children)))
  | Transit.Array groups | Transit.List groups ->
    Storage_tail (List.map datoms_of_transit groups)
  | _ -> invalid_arg "unknown Logseq storage payload"
;;

let encode ?root_index_metadata = function
  | Storage_root root ->
    Transit.to_string
      ~mode:Transit.Verbose
      (root_to_transit ?index_metadata:root_index_metadata root),
    None
  | Storage_node (PSet.Leaf datoms) ->
    ( Transit.to_string
        ~mode:Transit.Verbose
        (Transit.Map
           [ Transit.Keyword "keys", Transit.Array (List.map datom_to_transit datoms) ])
    , None )
  | Storage_node (PSet.Branch (keys, children)) ->
    ( Transit.to_string
        ~mode:Transit.Verbose
        (Transit.Map
           [ Transit.Keyword "keys", Transit.Array (List.map datom_to_transit keys) ])
    , Some (addresses_to_json children) )
  | Storage_tail groups ->
    ( Transit.to_string
        ~mode:Transit.Verbose
        (Transit.Array
           (List.map
              (fun datoms -> Transit.Array (List.map datom_to_transit datoms))
              groups))
    , None )
;;
