open Datascript

let one ?value_type ?(unique = None) () =
  { cardinality = One
  ; unique
  ; indexed = Option.is_some unique
  ; is_component = false
  ; no_history = false
  ; doc = None
  ; value_type
  ; tuple_attrs = None
  ; tuple_types = None
  }
;;

let () =
  let page_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" in
  let block_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec9" in
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/name", one ~value_type:StringType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/page", one ~value_type:RefType ()
    ; "block/parent", one ~value_type:RefType ()
    ; "block/order", one ~value_type:StringType ()
    ; "block/created-at", one ~value_type:InstantType ()
    ; "block/updated-at", one ~value_type:InstantType ()
    ; "block/journal-day", one ()
    ]
  in
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "page")
           ; attrs =
               [ "block/uuid", One_value (Uuid page_uuid)
               ; "block/name", One_value (String "page")
               ; "block/title", One_value (String "Page")
               ; "block/journal-day", One_value (Int 20260815)
               ]
           }
       ; Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid block_uuid)
               ; "block/title", One_value (String "Desktop seed")
               ; "block/page", One_value (Ref_to (Temp_id "page"))
               ; "block/parent", One_value (Ref_to (Temp_id "page"))
               ; "block/order", One_value (String "a1")
               ; "block/created-at", One_value (Instant 1_776_000_000_000)
               ; "block/updated-at", One_value (Instant 1_776_000_000_001)
               ]
           }
       ]);
  if Logseq_chat_graph_read.journal_page_uuid (conn_db conn) ~journal_day:20260815
     <> Some page_uuid
  then failwith "journal day must resolve to the graph page UUID";
  if Logseq_chat_graph_read.journal_page_uuid (conn_db conn) ~journal_day:20260816
     <> None
  then failwith "missing journal day must not resolve to a placeholder";
  (match Logseq_chat_graph_read.blocks (conn_db conn) with
  | [ block ] ->
    if not (String.equal block.Logseq_chat_model.uuid block_uuid)
    then failwith "graph block UUID changed";
    if not (String.equal block.title "Desktop seed")
    then failwith "graph block title changed";
    if not (String.equal block.page_id page_uuid)
    then failwith "graph page reference was not projected";
    if block.order <> Some "a1"
    then failwith "graph outliner order was not projected";
    if block.created_at <> 1_776_000_000_000
    then failwith "graph instant timestamp changed";
    if block.journal <> Some ("Page", 20260815)
    then failwith "graph journal metadata was not projected"
  | _ -> failwith "graph reader must return non-page blocks only");
  ignore
    (transact_conn
       conn
       [ Add (Lookup_ref ("block/uuid", Uuid block_uuid), "block/title", String "cipher-block")
       ; Add (Lookup_ref ("block/uuid", Uuid page_uuid), "block/title", String "cipher-page")
       ]);
  let decrypt_title = function
    | "cipher-block" -> Ok "Decrypted block"
    | "cipher-page" -> Ok "Decrypted journal"
    | value -> Ok value
  in
  match Logseq_chat_graph_read.blocks ~decrypt_title (conn_db conn) with
  | [ block ] ->
    if not (String.equal block.Logseq_chat_model.title "Decrypted block")
    then failwith "encrypted block title was not decrypted for the projection";
    if block.journal <> Some ("Decrypted journal", 20260815)
    then failwith "encrypted journal title was not decrypted for the projection"
  | _ -> failwith "encrypted graph reader must return non-page blocks only"
;;
