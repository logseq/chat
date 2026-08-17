open Datascript

let built_in_ref_attrs =
  [ "block/parent"
  ; "block/page"
  ; "block/refs"
  ; "block/tags"
  ; "block/link"
  ; "block/alias"
  ; "block/closed-value-property"
  ]
;;

let value_type_is_ref db = function
  | Keyword "db.type/ref" -> true
  | Ref eid | Int eid ->
    Datascript.datoms db Eavt ~e:eid ~a:"db/ident" ()
    |> Seq.exists (fun datom -> datom.v = Keyword "db.type/ref")
  | _ -> false
;;

let entity_declares_ref db attr =
  Datascript.entid db "db/ident" (Keyword attr)
  |> Option.exists (fun eid ->
    Datascript.datoms db Eavt ~e:eid ~a:"db/valueType" ()
    |> Seq.exists (fun datom -> value_type_is_ref db datom.v))
;;

let is_ref_attr db attr =
  List.mem attr built_in_ref_attrs
  || Datascript.Schema.schema_attr_is_ref db.schema attr
  || entity_declares_ref db attr
;;

let ref_eid db attr = function
  | Ref eid -> Some eid
  | Int eid when is_ref_attr db attr -> Some eid
  | _ -> None
;;

let optional_ref_eid db attr = function
  | Some value -> ref_eid db attr value
  | None -> None
;;

let datoms_by_ref db index attr eid =
  let seen_entities = Hashtbl.create 8 in
  Seq.append
    (Datascript.datoms db index ~a:attr ~v:(Ref eid) ())
    (Datascript.datoms db index ~a:attr ~v:(Int eid) ())
  |> Seq.filter (fun datom ->
    ref_eid db attr datom.v = Some eid
    && not (Hashtbl.mem seen_entities datom.e)
    && (Hashtbl.add seen_entities datom.e (); true))
;;
