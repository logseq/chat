open Datascript

module Bootstrap = Logseq_chat_graph_bootstrap
module Ops = Logseq_chat_pending_ops
module Projection = Logseq_chat_pending_projection
module Snapshot = Logseq_chat_lg_core_native
module Transit = Transit_native.Transit.Json

let fail label message = failwith (label ^ ": " ^ message)
let assert_bool label value = if not value then fail label "expected true"

let expect_ok label = function
  | Ok value -> value
  | Error message -> fail label message
;;

let one_value db entity_ref attr =
  match entity db entity_ref with
  | None -> None
  | Some entity ->
    (match Datascript.Entity.entity_attr_raw entity attr with
     | Some (One_value value) -> Some value
     | _ -> None)
;;

let kv_value db ident =
  match entid db "db/ident" (Keyword ident) with
  | Some eid -> one_value db (Entity_id eid) "kv/value"
  | None -> None
;;

let transit_field name = function
  | Transit.Map entries ->
    List.find_map
      (fun (key, value) ->
        match key with
        | Transit.Keyword key when String.equal key name -> Some value
        | _ -> None)
      entries
  | _ -> None
;;

let index_metadata label root =
  match transit_field (label ^ "-metadata") root with
  | Some (Transit.Map metadata) ->
    let int_field name =
      match
        List.find_map
          (fun (key, value) ->
            match key, value with
            | Transit.Keyword key, Transit.Int value when String.equal key name -> Some value
            | _ -> None)
          metadata
      with
      | Some value -> value
      | None -> fail (label ^ " metadata") ("missing " ^ name)
    in
    int_field "count", int_field "shift"
  | _ -> fail (label ^ " metadata") "missing index metadata"
;;

let canonical_db ?(e2ee = false) () =
  Bootstrap.database
    ~graph_id:"625e5ba9-fa25-4385-ad8b-f47d0f844387"
    ~e2ee
    ~encrypt_text:(fun value -> Ok ("encrypted:" ^ value))
  |> expect_ok "canonical database"
;;

let assert_many_ref_schema label db attr =
  match List.assoc_opt attr (Datascript.schema db) with
  | Some { cardinality = Many; value_type = Some RefType; _ } -> ()
  | Some _ -> fail label (attr ^ " is not a cardinality-many reference")
  | None -> fail label (attr ^ " is missing")
;;

let assert_one_ref_schema label db attr =
  match List.assoc_opt attr (Datascript.schema db) with
  | Some { cardinality = One; value_type = Some RefType; _ } -> ()
  | Some _ -> fail label (attr ^ " is not a cardinality-one reference")
  | None -> fail label (attr ^ " is missing")
;;

let () =
  let started_at = int_of_float (Unix.gettimeofday () *. 1000.) in
  let db = canonical_db () in
  let ident_count =
    datoms db Aevt ~a:"db/ident" () |> Seq.fold_left (fun count _ -> count + 1) 0
  in
  assert_bool "complete built-in catalog" (ident_count > 45);
  List.iter
    (fun ident ->
      match entid db "db/ident" (Keyword ident) with
      | None -> fail "canonical built-in" ("missing " ^ ident)
      | Some eid ->
        assert_bool
          ("built-in marker for " ^ ident)
          (one_value db (Entity_id eid) "logseq.property/built-in?" = Some (Bool true)))
    [ "logseq.class/Root"
    ; "logseq.class/Tag"
    ; "logseq.class/Property"
    ; "logseq.class/Page"
    ; "logseq.class/Journal"
    ; "logseq.class/Task"
    ; "logseq.class/Card"
    ; "logseq.class/Asset"
    ; "logseq.class/Code-block"
    ; "logseq.class/Quote-block"
    ; "logseq.class/Math-block"
    ];
  List.iter
    (fun page_name ->
      assert_bool
        ("canonical hidden page " ^ page_name)
        (Seq.is_empty (datoms db Aevt ~a:"block/name" ~v:(String page_name) ()) |> not))
    [ "$$$favorites"; "$$$views"; "recycle" ]
  ;
  assert_bool
    "remote graph UUID metadata"
    (kv_value db "logseq.kv/graph-uuid"
     = Some (Uuid "625e5ba9-fa25-4385-ad8b-f47d0f844387"));
  assert_bool
    "remote graph marker"
    (kv_value db "logseq.kv/graph-remote?" = Some (Bool true));
  assert_bool
    "plain graph encryption metadata"
    (kv_value db "logseq.kv/graph-rtc-e2ee?" = Some (Bool false));
  (match kv_value db "logseq.kv/graph-created-at" with
   | Some (Int value) -> assert_bool "fresh graph creation time" (value >= started_at)
   | _ -> fail "fresh graph creation time" "missing timestamp");
  let another = canonical_db () in
  assert_bool
    "local graph UUID is unique per graph"
    (kv_value db "logseq.kv/local-graph-uuid"
     <> kv_value another "logseq.kv/local-graph-uuid")
;;

let () =
  let plain = canonical_db () in
  let encrypted = canonical_db ~e2ee:true () in
  List.iter
    (fun attr ->
      assert_many_ref_schema "plain canonical schema" plain attr;
      assert_many_ref_schema "encrypted canonical schema" encrypted attr)
    [ "block/tags"; "logseq.property.class/extends" ];
  assert_one_ref_schema "plain canonical schema" plain "logseq.property/status";
  assert_one_ref_schema "encrypted canonical schema" encrypted "logseq.property/status";
  assert_bool
    "E2EE reconstruction preserves every installed schema attribute"
    (Datascript.schema encrypted = Datascript.schema plain)
;;

let () =
  let authoritative = canonical_db () in
  let operation =
    Ops.
      { operation_id = "create-tag"
      ; base_t = 0
      ; state = Queued
      ; intent = Create_tag { uuid = "10000000-0000-0000-0000-000000000001"; title = "Card"; created_at = 1 }
      }
  in
  let projected = Projection.build ~server_t:0 authoritative [ operation ] in
  (match List.assoc_opt operation.operation_id projected.statuses with
   | Some Ops.Applied -> ()
   | Some (Ops.Conflicted message) -> fail "fresh graph tag" message
   | Some Ops.Queued
   | Some Ops.Submitted
   | Some (Ops.Accepted _)
   | Some Ops.Retryable
   | None -> fail "fresh graph tag" "operation was not applied");
  assert_bool
    "created tag exists"
    (Option.is_some
       (entid
          projected.db
          "block/uuid"
          (Uuid "10000000-0000-0000-0000-000000000001")))
;;

let () =
  let encrypted = canonical_db ~e2ee:true () in
  datoms encrypted Aevt ~a:"block/title" ()
  |> Seq.iter (fun datom ->
    match datom.v with
    | String value ->
      assert_bool "encrypted initial title" (String.starts_with ~prefix:"encrypted:" value)
    | _ -> fail "encrypted initial title" "title was not stored as encrypted text");
  datoms encrypted Aevt ~a:"block/name" ()
  |> Seq.iter (fun datom ->
    match datom.v with
    | String value ->
      assert_bool "encrypted initial name" (String.starts_with ~prefix:"encrypted:" value)
    | _ -> fail "encrypted initial name" "name was not stored as encrypted text")
;;

let () =
  let db = canonical_db () in
  let rows = db |> Bootstrap.snapshot_rows |> expect_ok "snapshot rows" in
  assert_bool "snapshot has root" (List.exists (fun row -> row.Snapshot.addr = 0) rows);
  assert_bool "snapshot has tail" (List.exists (fun row -> row.Snapshot.addr = 1) rows);
  let root_row = List.find (fun row -> row.Snapshot.addr = 0) rows in
  let root = Transit.of_string root_row.content in
  let eavt_count, eavt_shift = index_metadata "eavt" root in
  let aevt_count, aevt_shift = index_metadata "aevt" root in
  let avet_count, avet_shift = index_metadata "avet" root in
  let datom_count = Datascript.datoms db Eavt () |> Seq.length in
  assert_bool "snapshot eavt metadata count" (eavt_count = datom_count);
  assert_bool "snapshot aevt metadata count" (aevt_count = datom_count);
  assert_bool "snapshot avet metadata count" (avet_count > 0 && avet_count <= datom_count);
  assert_bool "snapshot eavt metadata shift" (eavt_shift > 0);
  assert_bool "snapshot aevt metadata shift" (aevt_shift > 0);
  assert_bool "snapshot avet metadata shift" (avet_shift >= 0);
  let wire = Bootstrap.frame_rows rows in
  let parser = Snapshot.logseq_chat_snapshot_create_parser (2 * 1024 * 1024) in
  let decoded = Snapshot.logseq_chat_snapshot_feed parser wire |> expect_ok "framed snapshot" in
  Snapshot.logseq_chat_snapshot_finish_parser parser |> expect_ok "complete framed snapshot";
  if List.length decoded <> List.length rows
  then fail "snapshot row count" "framing did not preserve every KVS row"
;;

let () =
  let empty = empty_db ~schema:Bootstrap.schema ~storage:(memory_storage ()) () in
  let rows = Bootstrap.snapshot_rows empty |> expect_ok "empty snapshot rows" in
  let root_row = List.find (fun row -> row.Snapshot.addr = 0) rows in
  let root = Transit.of_string root_row.content in
  List.iter
    (fun index ->
      let count, shift = index_metadata index root in
      assert_bool (index ^ " empty metadata count") (count = 0);
      assert_bool (index ^ " empty metadata shift") (shift = 0))
    [ "eavt"; "aevt"; "avet" ]
;;
