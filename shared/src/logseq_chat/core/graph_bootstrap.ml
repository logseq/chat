module Ds = Datascript
module Db = Ds.Db
module Built_ins = Ds.Built_ins
module Pset = Persistent_sorted_set
module Transit = Transit_native.Transit.Json
module Codec = Storage_codec
module Snapshot_ = Snapshot

type prepared_snapshot =
  { file_path : string
  ; row_count : int
  ; checksum : string
  }

let schema_version = Graph_bootstrap_data.schema_version
let initial_checksum = "0000000000000000"

let fresh_local_graph_uuid () =
  match Ds.squuid () with
  | Ds.Uuid uuid -> "00000000" ^ String.sub uuid 8 (String.length uuid - 8)
  | _ -> failwith "Datascript.squuid returned a non-UUID value"

let schema : Ds.schema =
  let one = Codec.default_schema_attr in
  let indexed = { one with Ds.indexed = true } in
  let identity = { one with Ds.unique = Some Ds.Identity } in
  let ref_ = { one with Ds.value_type = Some Ds.RefType } in
  let indexed_ref = { ref_ with Ds.indexed = true } in
  let many_ref = { ref_ with Ds.cardinality = Ds.Many } in
  [
    ("db/ident", identity)
  ; ("kv/value", one)
  ; ("block/uuid", identity)
  ; ("block/parent", indexed_ref)
  ; ("block/order", indexed)
  ; ("block/collapsed?", one)
  ; ("block/page", indexed_ref)
  ; ("block/refs", many_ref)
  ; ("block/tags", many_ref)
  ; ("block/link", indexed_ref)
  ; ("block/alias", { many_ref with Ds.indexed = true })
  ; ("block/created-at", indexed)
  ; ("block/updated-at", indexed)
  ; ("block/name", indexed)
  ; ("block/title", indexed)
  ; ("block/journal-day", indexed)
  ; ("block/tx-id", one)
  ; ("block/closed-value-property", many_ref)
  ; ("file/path", identity)
  ; ("file/content", one)
  ; ("file/created-at", one)
  ; ("file/last-modified-at", one)
  ; ("file/size", one)
  ]

let native_schema = schema

let kv ident value =
  Ds.Entity
    {
      Ds.db_id = None;
      attrs =
        [
          ("db/ident", Ds.One_value (Ds.Keyword ident))
        ; ("kv/value", Ds.One_value value)
        ];
    }

let graph_metadata graph_id e2ee now =
  [
    kv "logseq.kv/graph-uuid" (Ds.Uuid graph_id)
  ; kv "logseq.kv/graph-remote?" (Ds.Bool true)
  ; kv "logseq.kv/graph-rtc-e2ee?" (Ds.Bool e2ee)
  ; kv "logseq.kv/graph-created-at" (Ds.Int now)
  ; kv "logseq.kv/local-graph-uuid" (Ds.Uuid (fresh_local_graph_uuid ()))
  ]

let rec scalar_tx_value (value : Ds.tx_value) : Ds.value =
  match value with
  | Ds.One_value value -> value
  | Ds.Many_values values -> Ds.Set values
  | Ds.One_entity entity ->
    Ds.Map
      (List.map
         (fun (attr, value) -> (Ds.Keyword attr, scalar_tx_value value))
         entity.Ds.attrs)
  | Ds.Many_entities entities ->
    Ds.Vector
      (List.map
         (fun entity -> scalar_tx_value (Ds.One_entity entity))
         entities)

let normalize_scalar_maps (tx : Ds.tx_op) =
  match tx with
  | Ds.Entity entity ->
    Ds.Entity
      {
        entity with
        Ds.attrs =
          List.map
            (fun (attr, value) ->
              ( attr
              , if attr = "kv/value" || attr = "logseq.property/icon"
                then
                  match value with
                  | Ds.One_entity _ | Ds.Many_entities _ ->
                    Ds.One_value (scalar_tx_value value)
                  | _ -> value
                else value ))
            entity.Ds.attrs;
      }
  | _ -> tx

let valid_ref_value (value : Ds.value) =
  match value with
  | Ds.TxRef | Ds.Ref _ | Ds.Ref_to _ | Ds.Int _ | Ds.String _
  | Ds.Keyword _ -> true
  | Ds.Symbol value ->
    value = "db/current-tx" || value = "datomic.tx"
    || value = "datascript.tx"
  | Ds.List (key :: _) | Ds.Vector (key :: _) ->
    (match key with
     | Ds.Keyword _ | Ds.String _ | Ds.Symbol _ -> true
     | _ -> false)
  | _ -> false

let validate_ref attr value =
  if not (valid_ref_value value) then
    invalid_arg
      ("invalid initial reference for " ^ attr ^ ": "
       ^ Built_ins.print_query_value ~readably:true value)

let validate_ref_values (tx : Ds.tx_op) =
  match tx with
  | Ds.Entity entity ->
    List.iter
      (fun (attr, value) ->
        match List.assoc_opt attr schema with
        | Some definition
          when definition.Ds.value_type = Some Ds.RefType ->
          let many = definition.Ds.cardinality = Ds.Many in
          (match value with
           | Ds.One_value value ->
             (match value with
              | (Ds.List values | Ds.Vector values | Ds.Set values)
                when many ->
                List.iter (validate_ref attr) values
              | _ -> validate_ref attr value)
           | Ds.Many_values values ->
             List.iter (validate_ref attr) values
           | _ -> ())
        | _ -> ())
      entity.Ds.attrs
  | _ -> ()

let unique_identity_attr attr =
  match List.assoc_opt attr schema with
  | Some definition -> definition.Ds.unique = Some Ds.Identity
  | None -> false

let identity_only (tx : Ds.tx_op) =
  match tx with
  | Ds.Entity entity ->
    let attrs =
      List.filter (fun (attr, _) -> unique_identity_attr attr) entity.Ds.attrs
    in
    if attrs <> [] then
      Some (Ds.Entity { Ds.db_id = None; attrs })
    else None
  | _ -> None

let schema_definition_attr attr =
  List.mem attr
    [
      "db/valueType"; "db/cardinality"; "db/index"; "db/unique"
    ; "db/isComponent"; "db/noHistory"; "db/tupleAttrs"
    ; "db/tupleTypes"; "db/doc"
    ]

let schema_definition_only (tx : Ds.tx_op) =
  match tx with
  | Ds.Entity entity ->
    let attrs =
      List.filter
        (fun (attr, _) ->
          unique_identity_attr attr || schema_definition_attr attr)
        entity.Ds.attrs
    in
    if
      List.exists (fun (attr, _) -> schema_definition_attr attr) attrs
    then Some (Ds.Entity { Ds.db_id = None; attrs })
    else None
  | _ -> None

let unique_ref_key schema (key : Ds.value) =
  let attr =
    match key with
    | Ds.Keyword attr | Ds.String attr | Ds.Symbol attr -> Some attr
    | _ -> None
  in
  match attr with
  | Some attr ->
    (match List.assoc_opt attr schema with
     | Some definition -> definition.Ds.unique <> None
     | None -> false)
  | None -> false

let lookup_ref_collection schema values =
  List.length values = 2
  &&
  match values with
  | key :: _ -> unique_ref_key schema key
  | [] -> false

let normalize_many_attributes (schema : Ds.schema) (tx : Ds.tx_op) =
  match tx with
  | Ds.Entity entity ->
    Ds.Entity
      {
        entity with
        Ds.attrs =
          List.map
            (fun (attr, value) ->
              ( attr
              , match List.assoc_opt attr schema with
                | Some definition
                  when definition.Ds.cardinality = Ds.Many ->
                  (match value with
                   | Ds.One_value (Ds.Set values) ->
                     Ds.Many_values values
                   | Ds.One_value ((Ds.List values | Ds.Vector values) as inner) ->
                     if lookup_ref_collection schema values then
                       Ds.One_value inner
                     else Ds.Many_values values
                   | _ -> value)
                | _ -> value ))
            entity.Ds.attrs;
      }
  | _ -> tx

let refresh_initial_timestamps now (tx : Ds.tx_op) =
  match tx with
  | Ds.Entity entity ->
    Ds.Entity
      {
        entity with
        Ds.attrs =
          List.map
            (fun (attr, value) ->
              ( attr
              , if attr = "block/created-at" || attr = "block/updated-at"
                then Ds.One_value (Ds.Int now)
                else if
                  attr = "file/created-at"
                  || attr = "file/last-modified-at"
                then Ds.One_value (Ds.Instant now)
                else value ))
            entity.Ds.attrs;
      }
  | _ -> tx

let encrypt_database encrypt_text db =
  let datoms = List.of_seq (Db.datoms db Ds.Eavt ()) in
  List.fold_left
    (fun acc (datom : Ds.datom) ->
      let ( let* ) = Result.bind in
      let* encrypted = acc in
      if datom.added && (datom.a = "block/title" || datom.a = "block/name")
      then
        match datom.v with
        | Ds.String value ->
          let* value = encrypt_text value in
          Ok (encrypted @ [ { datom with Ds.v = Ds.String value } ])
        | _ -> Ok (encrypted @ [ datom ])
      else Ok (encrypted @ [ datom ]))
    (Ok []) datoms

let install_canonical_entities initial_tx storage =
  try
    let identities = List.filter_map identity_only initial_tx in
    let definitions = List.filter_map schema_definition_only initial_tx in
    let identified =
      Ds.db_with identities
        (Ds.empty_db ~schema:native_schema ~storage ())
    in
    let schematized = Ds.db_with definitions identified in
    let installed_schema = Ds.schema schematized in
    Ds.db_with
      (List.map (normalize_many_attributes installed_schema) initial_tx)
      schematized
  with error ->
    failwith ("transact canonical entities: " ^ Printexc.to_string error)

let database graph_id e2ee encrypt_text =
  let ( let* ) = Result.bind in
  try
    let now = Api.epoch_ms () in
    let storage = Ds.memory_storage () in
    let initial_tx =
      List.map
        (fun tx ->
          refresh_initial_timestamps now (normalize_scalar_maps tx))
        (Ds.parse_tx_data_string Graph_bootstrap_data.transaction_edn)
    in
    List.iter validate_ref_values initial_tx;
    let initial = install_canonical_entities initial_tx storage in
    let plain =
      try
        Ds.db_with (graph_metadata graph_id e2ee now) initial
      with error ->
        failwith
          ("transact graph metadata: " ^ Printexc.to_string error)
    in
    if e2ee then begin
      let* datoms = encrypt_database encrypt_text plain in
      let encrypted =
        Ds.init_db ~schema:(Ds.schema plain)
          ~storage:(Ds.memory_storage ()) datoms
      in
      Ds.store encrypted;
      Ok encrypted
    end
    else Ok plain
  with error ->
    Error ("prepare canonical graph: " ^ Printexc.to_string error)

let rec index_shift (storage : Ds.storage) (address : string) =
  match storage.Ds.storage_restore address with
  | Some (Ds.Storage_node (Pset.Leaf _)) -> 0
  | Some (Ds.Storage_node (Pset.Branch (_, children))) ->
    let shifts = List.map (index_shift storage) children in
    (match shifts with
     | [] ->
       invalid_arg "DataScript storage branch has no children"
     | first_shift :: rest ->
       if
         List.exists (fun shift -> shift <> first_shift) rest
       then
         invalid_arg "DataScript storage index is not balanced";
       first_shift + 1)
  | Some _ ->
    invalid_arg ("DataScript index address is not a node: " ^ address)
  | None ->
    invalid_arg ("missing DataScript storage address " ^ address)

let root_index_metadata db storage (root : Ds.storage_root) =
  {
    Codec.eavt =
      {
        Codec.count = Pset.count db.Ds.eavt_index;
        shift = index_shift storage root.Ds.storage_eavt;
      };
    aevt =
      {
        Codec.count = Pset.count db.Ds.aevt_index;
        shift = index_shift storage root.Ds.storage_aevt;
      };
    avet =
      {
        Codec.count = Pset.count db.Ds.avet_index;
        shift = index_shift storage root.Ds.storage_avet;
      };
  }

let storage_row db (storage : Ds.storage) address =
  let addr = int_of_string address in
  match storage.Ds.storage_restore address with
  | Some payload ->
    let metadata =
      match payload with
      | Ds.Storage_root root ->
        Some (root_index_metadata db storage root)
      | _ -> None
    in
    let content, addresses = Codec.encode metadata payload in
    { Snapshot_.addr; content; addresses }
  | None ->
    invalid_arg ("missing DataScript storage address " ^ address)

let snapshot_rows db =
  try
    Ds.store db;
    match Ds.storage db with
    | Some storage ->
      Ok
        (List.sort
           (fun (a : Snapshot_.snapshot_row) b -> compare a.addr b.addr)
           (List.map
              (fun address -> storage_row db storage address)
              (storage.Ds.storage_list_addresses ())))
    | None -> Error "canonical graph has no DataScript storage"
  with error ->
    Error
      ("encode canonical graph snapshot: " ^ Printexc.to_string error)

let frame_rows rows =
  let payload =
    Transit.to_string
      (Transit.Array
         (List.map
            (fun (row : Snapshot_.snapshot_row) ->
              Transit.Array
                [
                  Transit.Int row.addr
                ; Transit.String row.content
                ; (match row.addresses with
                   | Some addresses -> Transit.String addresses
                   | None -> Transit.Null)
                ])
            rows))
  in
  let length = String.length payload in
  let prefix =
    Bytes.init 4 (fun index ->
        Char.chr
          ((length lsr ((3 - index) * 8)) land 0xff))
  in
  Bytes.to_string prefix ^ payload

let prepare graph_id e2ee encrypt_text =
  let ( let* ) = Result.bind in
  let* db = database graph_id e2ee encrypt_text in
  let* rows = snapshot_rows db in
  let path = Filename.temp_file "logseq-chat-initial-" ".snapshot" in
  try
    let channel = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () -> output_string channel (frame_rows rows));
    Ok
      {
        file_path = path;
        row_count = List.length rows;
        checksum = initial_checksum;
      }
  with error ->
    (try Sys.remove path with _ -> ());
    Error
      ("write canonical graph snapshot: " ^ Printexc.to_string error)
