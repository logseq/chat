open Datascript

module Data = Logseq_chat_graph_bootstrap_data
module Codec = Logseq_chat_lg_core_native
module Snapshot = Logseq_chat_lg_core_native
module Transit = Transit_native.Transit.Json

type prepared_snapshot =
  { file_path : string
  ; row_count : int
  ; checksum : string
  }

let schema_version = Data.schema_version
let initial_checksum = "0000000000000000"
let epoch_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

let fresh_local_graph_uuid () =
  match Datascript.squuid () with
  | Uuid uuid -> "00000000" ^ String.sub uuid 8 (String.length uuid - 8)
  | _ -> failwith "Datascript.squuid returned a non-UUID value"
;;

let one ?unique ?value_type ?(indexed = false) () =
  { cardinality = One
  ; unique
  ; indexed
  ; is_component = false
  ; no_history = false
  ; doc = None
  ; value_type
  ; tuple_attrs = None
  ; tuple_types = None
  }
;;

let many ?value_type ?(indexed = false) () =
  { (one ?value_type ~indexed ()) with cardinality = Many }
;;

(* This is logseq.db.frontend.schema/schema at schema version 65.33. *)
let schema =
  [ "db/ident", one ~unique:Identity ()
  ; "kv/value", one ()
  ; "block/uuid", one ~unique:Identity ()
  ; "block/parent", one ~value_type:RefType ~indexed:true ()
  ; "block/order", one ~indexed:true ()
  ; "block/collapsed?", one ()
  ; "block/page", one ~value_type:RefType ~indexed:true ()
  ; "block/refs", many ~value_type:RefType ()
  ; "block/tags", many ~value_type:RefType ()
  ; "block/link", one ~value_type:RefType ~indexed:true ()
  ; "block/alias", many ~value_type:RefType ~indexed:true ()
  ; "block/created-at", one ~indexed:true ()
  ; "block/updated-at", one ~indexed:true ()
  ; "block/name", one ~indexed:true ()
  ; "block/title", one ~indexed:true ()
  ; "block/journal-day", one ~indexed:true ()
  ; "block/tx-id", one ()
  ; "block/closed-value-property", many ~value_type:RefType ()
  ; "file/path", one ~unique:Identity ()
  ; "file/content", one ()
  ; "file/created-at", one ()
  ; "file/last-modified-at", one ()
  ; "file/size", one ()
  ]
;;

let kv ident value =
  Entity
    { db_id = None
    ; attrs =
        [ "db/ident", One_value (Keyword ident)
        ; "kv/value", One_value value
        ]
    }
;;

let graph_metadata ~graph_id ~e2ee ~now =
  [ kv "logseq.kv/graph-uuid" (Uuid graph_id)
  ; kv "logseq.kv/graph-remote?" (Bool true)
  ; kv "logseq.kv/graph-rtc-e2ee?" (Bool e2ee)
  ; kv "logseq.kv/graph-created-at" (Int now)
  ; kv "logseq.kv/local-graph-uuid" (Uuid (fresh_local_graph_uuid ()))
  ]
;;

let rec value_of_nested_entity (entity : tx_entity) =
  let value_of_tx_value = function
    | One_value value -> value
    | Many_values values -> Set values
    | One_entity entity -> value_of_nested_entity entity
    | Many_entities entities -> Vector (List.map value_of_nested_entity entities)
  in
  Map
    (List.map
       (fun (attr, value) -> Keyword attr, value_of_tx_value value)
       entity.attrs)
;;

let normalize_scalar_maps tx =
  let normalize_entity (entity : tx_entity) =
    let attrs =
      List.map
        (fun (attr, value) ->
          if String.equal attr "kv/value" || String.equal attr "logseq.property/icon"
          then
            match value with
            | One_entity nested -> attr, One_value (value_of_nested_entity nested)
            | Many_entities nested ->
              attr, One_value (Vector (List.map value_of_nested_entity nested))
            | One_value _ | Many_values _ -> attr, value
          else attr, value)
        entity.attrs
    in
    Entity { entity with attrs }
  in
  match tx with
  | Entity entity -> normalize_entity entity
  | _ -> tx
;;

let valid_ref_value = function
  | TxRef | Ref _ | Ref_to _ | Int _ | String _ | Keyword _ -> true
  | Symbol "db/current-tx" | Symbol "datomic.tx" | Symbol "datascript.tx" -> true
  | List [ (Keyword _ | String _ | Symbol _); _ ]
  | Vector [ (Keyword _ | String _ | Symbol _); _ ] -> true
  | _ -> false
;;

let validate_ref_values tx =
  let validate attr value =
    if not (valid_ref_value value)
    then
      invalid_arg
        (Printf.sprintf
           "invalid initial reference for %s: %s"
           attr
           (Datascript.Built_ins.print_query_value ~readably:true value))
  in
  match tx with
  | Entity entity ->
    List.iter
      (fun (attr, value) ->
        match List.assoc_opt attr schema with
        | Some { value_type = Some RefType; cardinality; _ } ->
          (match value with
           | One_value (List values | Vector values | Set values) when cardinality = Many ->
             List.iter (validate attr) values
           | One_value value -> validate attr value
           | Many_values values -> List.iter (validate attr) values
           | One_entity _ | Many_entities _ -> ())
        | _ -> ())
      entity.attrs
  | _ -> ()
;;

let unique_identity_attr attr =
  match List.assoc_opt attr schema with
  | Some { unique = Some Identity; _ } -> true
  | _ -> false
;;

let identity_only = function
  | Entity entity ->
    let attrs = List.filter (fun (attr, _) -> unique_identity_attr attr) entity.attrs in
    if attrs = [] then None else Some (Entity { db_id = None; attrs })
  | _ -> None
;;

let schema_definition_attr = function
  | "db/valueType"
  | "db/cardinality"
  | "db/index"
  | "db/unique"
  | "db/isComponent"
  | "db/noHistory"
  | "db/tupleAttrs"
  | "db/tupleTypes"
  | "db/doc" -> true
  | _ -> false
;;

let schema_definition_only = function
  | Entity entity ->
    let attrs =
      List.filter
        (fun (attr, _) -> unique_identity_attr attr || schema_definition_attr attr)
        entity.attrs
    in
    if List.exists (fun (attr, _) -> schema_definition_attr attr) attrs
    then Some (Entity { db_id = None; attrs })
    else None
  | _ -> None
;;

let lookup_ref_collection schema = function
  | [ (Keyword attr | String attr | Symbol attr); _ ] ->
    (match List.assoc_opt attr schema with
     | Some { unique = Some _; _ } -> true
     | _ -> false)
  | _ -> false
;;

let normalize_many_attributes schema = function
  | Entity entity ->
    let attrs =
      List.map
        (fun (attr, value) ->
          match List.assoc_opt attr schema, value with
          | Some { cardinality = Many; _ }, One_value (Set values) ->
            attr, Many_values values
          | Some { cardinality = Many; _ }, One_value (List values | Vector values)
            when not (lookup_ref_collection schema values) ->
            attr, Many_values values
          | _ -> attr, value)
        entity.attrs
    in
    Entity { entity with attrs }
  | tx -> tx
;;

let refresh_initial_timestamps now = function
  | Entity entity ->
    let attrs =
      List.map
        (fun (attr, value) ->
          match attr with
          | "block/created-at" | "block/updated-at" -> attr, One_value (Int now)
          | "file/created-at" | "file/last-modified-at" -> attr, One_value (Instant now)
          | _ -> attr, value)
        entity.attrs
    in
    Entity { entity with attrs }
  | tx -> tx
;;

let encrypt_database ~encrypt_text db =
  let rec loop encrypted = function
    | [] -> Ok (List.rev encrypted)
    | datom :: rest ->
      if (String.equal datom.a "block/title" || String.equal datom.a "block/name")
         && datom.added
      then
        (match datom.v with
         | String value ->
           (match encrypt_text value with
            | Ok value -> loop ({ datom with v = String value } :: encrypted) rest
            | Error _ as error -> error)
         | _ -> loop (datom :: encrypted) rest)
      else loop (datom :: encrypted) rest
  in
  loop [] (datoms db Eavt () |> List.of_seq)
;;

let database ~graph_id ~e2ee ~encrypt_text =
  try
    let now = epoch_ms () in
    let storage = memory_storage () in
    let initial_tx =
      parse_tx_data_string Data.transaction_edn
      |> List.map normalize_scalar_maps
      |> List.map (refresh_initial_timestamps now)
    in
    List.iter validate_ref_values initial_tx;
    let initial =
      try
        let identities = List.filter_map identity_only initial_tx in
        let definitions = List.filter_map schema_definition_only initial_tx in
        let identified = empty_db ~schema ~storage () |> db_with identities in
        let schematized = db_with definitions identified in
        let installed_schema = Datascript.schema schematized in
        db_with (List.map (normalize_many_attributes installed_schema) initial_tx) schematized
      with
      | error -> failwith ("transact canonical entities: " ^ Printexc.to_string error)
    in
    let plain =
      try db_with (graph_metadata ~graph_id ~e2ee ~now) initial with
      | error -> failwith ("transact graph metadata: " ^ Printexc.to_string error)
    in
    if not e2ee
    then Ok plain
    else
      (match encrypt_database ~encrypt_text plain with
       | Error _ as error -> error
       | Ok encrypted_datoms ->
         let storage = memory_storage () in
         let installed_schema = Datascript.schema plain in
         let encrypted = init_db ~schema:installed_schema ~storage encrypted_datoms in
         store encrypted;
         Ok encrypted)
  with
  | error -> Error ("prepare canonical graph: " ^ Printexc.to_string error)
;;

let snapshot_rows db =
  try
    store db;
    match storage db with
    | None -> Error "canonical graph has no DataScript storage"
    | Some storage ->
      let rec index_shift address =
        match storage.storage_restore address with
        | Some (Storage_node (Persistent_sorted_set.Leaf _)) -> 0
        | Some (Storage_node (Persistent_sorted_set.Branch (_, children))) ->
          (match List.map index_shift children with
           | [] -> invalid_arg "DataScript storage branch has no children"
           | first :: rest ->
             if not (List.for_all (Int.equal first) rest)
             then invalid_arg "DataScript storage index is not balanced";
             first + 1)
        | Some _ -> invalid_arg ("DataScript index address is not a node: " ^ address)
        | None -> invalid_arg ("missing DataScript storage address " ^ address)
      in
      let root_index_metadata root =
        Codec.
          { eavt = { count = Persistent_sorted_set.count db.eavt_index; shift = index_shift root.storage_eavt }
          ; aevt = { count = Persistent_sorted_set.count db.aevt_index; shift = index_shift root.storage_aevt }
          ; avet = { count = Persistent_sorted_set.count db.avet_index; shift = index_shift root.storage_avet }
          }
      in
      let rows =
        storage.storage_list_addresses ()
        |> List.map (fun address ->
          let addr = int_of_string address in
          match storage.storage_restore address with
          | None -> invalid_arg ("missing DataScript storage address " ^ address)
          | Some payload ->
            let content, addresses =
              match payload with
              | Storage_root root -> Codec.logseq_chat_storage_codec_encode (Some (root_index_metadata root)) payload
              | Storage_node _ | Storage_tail _ -> Codec.logseq_chat_storage_codec_encode None payload
            in
            Snapshot.{ addr; content; addresses })
        |> List.sort (fun left right -> Int.compare left.Snapshot.addr right.Snapshot.addr)
      in
      Ok rows
  with
  | error -> Error ("encode canonical graph snapshot: " ^ Printexc.to_string error)
;;

let frame_rows rows =
  let row (row : Snapshot.snapshot_row) =
    Transit.Array
      [ Transit.Int row.addr
      ; Transit.String row.content
      ; Option.fold ~none:Transit.Null ~some:(fun value -> Transit.String value) row.addresses
      ]
  in
  let payload = Transit.to_string (Transit.Array (List.map row rows)) in
  let length = String.length payload in
  let prefix =
    String.init 4 (fun index ->
      Char.chr ((length lsr ((3 - index) * 8)) land 0xff))
  in
  prefix ^ payload
;;

let prepare ~graph_id ~e2ee ~encrypt_text =
  match database ~graph_id ~e2ee ~encrypt_text with
  | Error _ as error -> error
  | Ok db ->
    (match snapshot_rows db with
     | Error _ as error -> error
     | Ok rows ->
       let path = Filename.temp_file "logseq-chat-initial-" ".snapshot" in
       (try
          let channel = open_out_bin path in
          Fun.protect
            ~finally:(fun () -> close_out_noerr channel)
            (fun () -> output_string channel (frame_rows rows));
          Ok { file_path = path; row_count = List.length rows; checksum = initial_checksum }
        with
        | error ->
          (try Sys.remove path with _ -> ());
          Error ("write canonical graph snapshot: " ^ Printexc.to_string error)))
;;
