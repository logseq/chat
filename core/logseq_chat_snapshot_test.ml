module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json
module Snapshot = Logseq_chat_snapshot

let fail label message = failwith (label ^ ": " ^ message)

let expect_ok label = function
  | Ok value -> value
  | Error message -> fail label message
;;

let frame value =
  let payload = Codec.to_string value in
  let length = String.length payload in
  let prefix =
    String.init 4 (fun index ->
      Char.chr ((length lsr ((3 - index) * 8)) land 0xff))
  in
  prefix ^ payload
;;

let row addr content addresses =
  Value.Array
    [ Value.Int addr
    ; Value.String content
    ; (match addresses with
       | None -> Value.Null
       | Some value -> Value.String value)
    ]
;;

let () =
  let root = {|["^ ","~:schema",["^ ","~:block/title",["^ ","~:db/valueType","~:db.type/string"]]]|} in
  let wire =
    frame
      (Value.Array
         [ row 0 root None
         ; row 1 "[]" None
         ; row 7 {|["^ ","~:keys",[]]|} (Some "[3,4]")
         ])
  in
  let parser = Snapshot.create_parser ~max_frame_bytes:4096 in
  let first = String.sub wire 0 3 in
  let second = String.sub wire 3 11 in
  let rest = String.sub wire 14 (String.length wire - 14) in
  if expect_ok "partial prefix" (Snapshot.feed parser first) <> []
  then fail "partial prefix" "unexpected rows";
  if expect_ok "partial payload" (Snapshot.feed parser second) <> []
  then fail "partial payload" "unexpected rows";
  let rows = expect_ok "complete frame" (Snapshot.feed parser rest) in
  (match rows with
   | [ root_row; tail_row; node_row ] ->
     if root_row.addr <> 0 || not (String.equal root_row.content root)
     then fail "root row" "content or address changed";
     if tail_row.addr <> 1 then fail "tail row" "missing tail";
     if node_row.addresses <> Some "[3,4]"
     then fail "addresses" "JSON text was not preserved"
   | _ -> fail "row count" (string_of_int (List.length rows)));
  expect_ok "complete stream" (Snapshot.finish_parser parser);

  let importer =
    Snapshot.create_import
      ~graph_id:"graph-1"
      ~schema_version:"65.33"
      ~baseline_t:48192
      ~expected_rows:3
  in
  expect_ok "accept rows" (Snapshot.accept_rows importer rows);
  let completed = expect_ok "finish import" (Snapshot.finish_import importer) in
  if completed.applied_server_t <> 48192
  then fail "baseline cursor" "cursor changed during snapshot import";
  if not (String.equal completed.schema_version "65.33")
  then fail "schema version" "schema version changed";

  let unordered =
    Snapshot.create_import
      ~graph_id:"graph-1"
      ~schema_version:"65.33"
      ~baseline_t:0
      ~expected_rows:2
  in
  (match Snapshot.accept_rows unordered [ List.nth rows 1; List.hd rows ] with
   | Error _ -> ()
   | Ok () -> fail "row order" "accepted non-increasing addresses");

  let incomplete = Snapshot.create_parser ~max_frame_bytes:4096 in
  ignore (expect_ok "incomplete feed" (Snapshot.feed incomplete first));
  (match Snapshot.finish_parser incomplete with
   | Error _ -> ()
   | Ok () -> fail "incomplete stream" "accepted trailing bytes");

  let oversized = Snapshot.create_parser ~max_frame_bytes:2 in
  (match Snapshot.feed oversized wire with
   | Error _ -> ()
   | Ok _ -> fail "frame bound" "accepted oversized frame")
;;
