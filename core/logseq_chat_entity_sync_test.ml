open Datascript
module Protocol = Logseq_chat_sync_protocol
module Value = Transit_core.Json

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

let many_ref = { (one ~value_type:RefType ()) with cardinality = Many }

let identity uuid =
  Value.Array [ Value.Keyword "block/uuid"; Value.Uuid uuid ]
;;

let entity uuid attrs : Protocol.entity = { id = identity uuid; attrs }

let block uuid title =
  [ Value.Keyword "block/uuid", Value.Uuid uuid
  ; Value.Keyword "block/title", Value.String title
  ]
;;

let fail message = failwith message

let () =
  let schema =
    [ "block/uuid", one ~value_type:UuidType ~unique:(Some Identity) ()
    ; "block/title", one ~value_type:StringType ()
    ; "block/collapsed?", one ()
    ; "block/parent", one ~value_type:RefType ()
    ; "block/tags", many_ref
    ; "block/properties", one ()
    ]
  in
  let old_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" in
  let parent_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec9" in
  let tag_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4eca" in
  let new_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ecb" in
  let doomed_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ecc" in
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity { db_id = None; attrs = [ "block/uuid", One_value (Uuid old_uuid); "block/title", One_value (String "Before"); "block/collapsed?", One_value (Bool true) ] }
       ; Entity { db_id = None; attrs = [ "block/uuid", One_value (Uuid parent_uuid); "block/title", One_value (String "Parent") ] }
       ; Entity { db_id = None; attrs = [ "block/uuid", One_value (Uuid tag_uuid); "block/title", One_value (String "Tag") ] }
       ; Entity { db_id = None; attrs = [ "block/uuid", One_value (Uuid doomed_uuid); "block/title", One_value (String "Delete me") ] }
       ]);
  let changes : Protocol.change_set =
    { format_version = 1
    ; graph_id = "graph-1"
    ; schema_version = "65.33"
    ; t_before = 7
    ; t = 8
    ; upserts =
        [ entity
            old_uuid
            (block old_uuid "After"
             @ [ Value.Keyword "block/parent", identity parent_uuid
               ; Value.Keyword "block/tags", Value.Set [ identity tag_uuid ]
               ; ( Value.Keyword "block/properties"
                 , Value.Map [ Value.Keyword "priority", Value.Keyword "A" ] )
               ])
        ; entity new_uuid (block new_uuid "Created")
        ]
    ; deleted = [ identity doomed_uuid ]
    }
  in
  (match Logseq_chat_entity_sync.apply_change_set conn changes with
   | Ok () -> ()
   | Error message -> fail message);
  let db = conn_db conn in
  let old_eid = Option.get (entid db "block/uuid" (Uuid old_uuid)) in
  let values attr =
    datoms db Eavt ~e:old_eid ~a:attr () |> List.of_seq |> List.map (fun datom -> datom.v)
  in
  if values "block/title" <> [ String "After" ] then fail "title was not replaced";
  if values "block/collapsed?" <> [] then fail "omitted attribute was not retracted";
  (match values "block/parent" with
   | [ Ref eid ] when eid = Option.get (entid db "block/uuid" (Uuid parent_uuid)) -> ()
   | _ -> fail "reference identity was not resolved");
  (match values "block/tags" with
   | [ Ref eid ] when eid = Option.get (entid db "block/uuid" (Uuid tag_uuid)) -> ()
   | _ -> fail "cardinality-many reference was not preserved");
  (match values "block/properties" with
   | [ Map [ Keyword "priority", Keyword "A" ] ] -> ()
   | _ -> fail "nested property value changed type");
  if Option.is_none (entid db "block/uuid" (Uuid new_uuid))
  then fail "new entity was not created";
  if Option.is_some (entid db "block/uuid" (Uuid doomed_uuid))
  then fail "authoritative remote deletion was not applied"
;;
