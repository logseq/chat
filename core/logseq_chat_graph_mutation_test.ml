open Datascript
module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

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
    ]
  in
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = None
           ; attrs =
               [ "block/uuid", One_value (Uuid page_uuid)
               ; "block/name", One_value (String "page")
               ]
           }
       ]);
  let wire =
    match
      Logseq_chat_graph_mutation.insert_block_tx
        (conn_db conn)
        ~uuid:block_uuid
        ~title:"Mobile block"
        ~now:1_776_000_000_000
    with
    | Ok wire -> wire
    | Error message -> failwith message
  in
  match Codec.of_string wire with
  | Value.Array [ Value.Map fields ] ->
    let get key = List.assoc_opt (Value.Keyword key) fields in
    if get "block/uuid" <> Some (Value.Uuid block_uuid)
    then failwith "block UUID type changed";
    if get "block/title" <> Some (Value.String "Mobile block")
    then failwith "block title type changed";
    let page_identity =
      Value.Array [ Value.Keyword "block/uuid"; Value.Uuid page_uuid ]
    in
    if get "block/parent" <> Some page_identity || get "block/page" <> Some page_identity
    then failwith "block placement did not use a stable page identity";
    if get "block/created-at" <> Some (Value.Date 1_776_000_000_000L)
    then failwith "created-at type changed"
  | _ -> failwith "insert transaction must contain one entity map"
;;

let () =
  let uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec9" in
  let wire =
    Logseq_chat_graph_mutation.save_block_tx
      ~uuid
      ~title:"Edited"
      ~status_ident:(Some "logseq.property/status.doing")
  in
  match Codec.of_string wire with
  | Value.Array
      [ Value.Array
          [ Value.Keyword "db/add"
          ; Value.Array [ Value.Keyword "block/uuid"; Value.Uuid saved_uuid ]
          ; Value.Keyword "block/title"
          ; Value.String "Edited"
          ]
      ; Value.Array
          [ Value.Keyword "db/add"
          ; Value.Array [ Value.Keyword "block/uuid"; Value.Uuid status_uuid ]
          ; Value.Keyword "logseq.property/status"
          ; Value.Array
              [ Value.Keyword "db/ident"
              ; Value.Keyword "logseq.property/status.doing"
              ]
          ]
      ]
    when String.equal saved_uuid uuid && String.equal status_uuid uuid -> ()
  | _ -> failwith "save transaction changed title or status property types"
;;
