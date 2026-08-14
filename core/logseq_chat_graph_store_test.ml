module Snapshot = Logseq_chat_snapshot
module Store = Logseq_chat_graph_store
module Transit = Transit_native.Transit.Json
open Datascript

let fail label message = failwith (label ^ ": " ^ message)

let expect_ok label = function
  | Ok value -> value
  | Error message -> fail label message
;;

let transit_map entries = Transit.Map entries

let schema_attr ?value_type ?(many = false) () =
  let entries =
    (if many
     then [ Transit.Keyword "db/cardinality", Transit.Keyword "db.cardinality/many" ]
     else [])
    @
    match value_type with
    | None -> []
    | Some value_type -> [ Transit.Keyword "db/valueType", Transit.Keyword value_type ]
  in
  transit_map entries
;;

let datom e attr value tx =
  Transit.Array [ Transit.Int e; Transit.Keyword attr; value; Transit.Int tx ]
;;

let fixture_rows () : Snapshot.row list =
  let schema =
    transit_map
      [ Transit.Keyword "block/uuid", schema_attr ~value_type:"db.type/uuid" ()
      ; Transit.Keyword "block/parent", schema_attr ~value_type:"db.type/ref" ()
      ; Transit.Keyword "block/tags", schema_attr ~value_type:"db.type/ref" ~many:true ()
      ; Transit.Keyword "block/type", schema_attr ~value_type:"db.type/keyword" ()
      ; Transit.Keyword "block/created-at", schema_attr ()
      ; Transit.Keyword "block/properties", schema_attr ()
      ]
  in
  let root =
    transit_map
      [ Transit.Keyword "schema", schema
      ; Transit.Keyword "max-eid", Transit.Int 12
      ; Transit.Keyword "max-tx", Transit.Int 536870930
      ; Transit.Keyword "eavt", Transit.Int 2
      ; Transit.Keyword "aevt", Transit.Int 3
      ; Transit.Keyword "avet", Transit.Int 4
      ; Transit.Keyword "max-addr", Transit.Int 4
      ; Transit.Keyword "branching-factor", Transit.Int 512
      ; Transit.Keyword "ref-type", Transit.Keyword "soft"
      ]
  in
  let datoms =
    [ datom 10 "block/created-at" (Transit.Int64 1723012345678L) 536870930
    ; datom 10 "block/parent" (Transit.Int 11) 536870930
    ; datom
        10
        "block/properties"
        (transit_map [ Transit.Keyword "priority", Transit.Keyword "A" ])
        536870930
    ; datom 10 "block/tags" (Transit.Int 11) 536870930
    ; datom 10 "block/tags" (Transit.Int 12) 536870930
    ; datom 10 "block/type" (Transit.Keyword "whiteboard") 536870930
    ; datom
        10
        "block/uuid"
        (Transit.Tagged
           ("u", Transit.String "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8"))
        536870930
    ]
  in
  let node = transit_map [ Transit.Keyword "keys", Transit.Array datoms ] in
  let encode value = Transit.to_string ~mode:Transit.Verbose value in
  [ { addr = 0; content = encode root; addresses = None }
  ; { addr = 1; content = encode (Transit.Array []); addresses = None }
  ; { addr = 2; content = encode node; addresses = None }
  ; { addr = 3; content = encode node; addresses = None }
  ; { addr = 4; content = encode node; addresses = None }
  ]
;;

let require_datom label predicate datoms =
  match List.find_opt predicate datoms with
  | Some datom -> datom
  | None -> fail label "datom is missing"
;;

let show_value = function
  | Keyword value -> ":" ^ value
  | String value -> Printf.sprintf "%S" value
  | Int value -> string_of_int value
  | _ -> "<other>"
;;

let () =
  let active_path = Filename.temp_file "logseq-chat-graph" ".sqlite" in
  Sys.remove active_path;
  let staging_path = Store.staging_path active_path in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> if Sys.file_exists path then Sys.remove path)
        [ active_path; staging_path ])
    (fun () ->
      expect_ok "begin import" (Store.begin_import ~active_path);
      let rows : Snapshot.row list =
        [ { addr = 0
          ; content = {|["^ ","~:schema",["^ ","~:block/title",["^ ","~:db/valueType","~:db.type/string"]]]|}
          ; addresses = None
          }
        ; { addr = 1; content = "[]"; addresses = None }
        ; { addr = 7
          ; content = {|["^ ","~:keys",[]]|}
          ; addresses = Some "[3,4]"
          }
        ]
      in
      expect_ok "append rows" (Store.append_rows ~active_path rows);
      expect_ok "activate" (Store.activate ~active_path);
      if Sys.file_exists staging_path then fail "activate" "staging file remains";
      (match expect_ok "read root" (Store.read_row ~path:active_path ~addr:0) with
       | Some (content, None) when String.equal content (List.hd rows).content -> ()
       | _ -> fail "root" "content or SQL null changed");
      (match expect_ok "read node" (Store.read_row ~path:active_path ~addr:7) with
       | Some (content, Some addresses)
         when String.equal content (List.nth rows 2).content
              && String.equal addresses "[3,4]" -> ()
       | _ -> fail "node" "content or addresses changed");

      expect_ok "begin typed fixture import" (Store.begin_import ~active_path);
      expect_ok "append typed fixture" (Store.append_rows ~active_path (fixture_rows ()));
      expect_ok "activate typed fixture" (Store.activate ~active_path);
      let db = expect_ok "restore DataScript db" (Store.restore_db ~path:active_path) in
      let datoms = Datascript.datoms db Eavt () |> List.of_seq in
      let value attr =
        (require_datom attr (fun datom -> datom.e = 10 && String.equal datom.a attr) datoms).v
      in
      (match value "block/uuid" with
       | Uuid "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" -> ()
       | _ -> fail "uuid type" "UUID was coerced");
      (match value "block/parent" with
       | Ref 11 -> ()
       | _ -> fail "ref type" "reference was coerced");
      (match value "block/type" with
       | Keyword "whiteboard" -> ()
       | _ -> fail "keyword type" "keyword was coerced");
      (match value "block/created-at" with
       | Int 1723012345678 -> ()
       | _ -> fail "integer type" "integer was coerced");
      (match value "block/properties" with
       | Map [ Keyword "priority", Keyword "A" ] -> ()
       | _ -> fail "map type" "map was coerced");
      let tag_values =
        datoms
        |> List.filter_map (fun datom ->
          if datom.e = 10 && String.equal datom.a "block/tags" then Some datom.v else None)
      in
      if tag_values <> [ Ref 11; Ref 12 ]
      then fail "cardinality many" "reference set was not preserved";
      (match List.assoc_opt "block/tags" db.schema with
       | Some { cardinality = Many; value_type = Some RefType; _ } -> ()
       | _ -> fail "schema" "server schema changed during restore");

      let conn = expect_ok "restore writable connection" (Store.restore_conn ~path:active_path) in
      ignore
        (Datascript.transact_conn
           conn
           [ Add (Entity_id 10, "block/type", Keyword "page") ]);
      let persisted = expect_ok "restore transacted db" (Store.restore_db ~path:active_path) in
      let persisted_values =
        Datascript.datoms persisted Eavt ()
        |> List.of_seq
        |> List.filter_map (fun datom ->
          if datom.e = 10 && String.equal datom.a "block/type"
          then Some datom.v
          else None)
      in
      if persisted_values <> [ Keyword "page" ]
      then
        fail
          "native persistence"
          ("transaction did not persist in Logseq storage format: "
           ^ String.concat ", " (List.map show_value persisted_values)))
;;
