module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

let expect_ok result =
  match result with
  | Ok value -> value
  | Error message -> failwith message

let frame value =
  let payload = Codec.to_string value in
  let length = String.length payload in
  let header = Bytes.create 4 in
  for index = 0 to 3 do
    Bytes.set header index
      (Char.chr ((length lsr ((3 - index) * 8)) land 255))
  done;
  Bytes.to_string header ^ payload

let row addr content addresses =
  Value.Array
    [
      Value.Int addr;
      Value.String content;
      (match addresses with
       | None -> Value.Null
       | Some text -> Value.String text);
    ]

let root =
  "[\"^ \",\"~:schema\",[\"^ \",\"~:block/title\",[\"^ \
   \",\"~:db/valueType\",\"~:db.type/string\"]]]"

let wire =
  frame
    (Value.Array
       [ row 0 root None; row 1 "[]" None; row 7 "[\"^ \",\"~:keys\",[]]" (Some "[3,4]") ])

let partial_prefix_payload_and_import_metadata () =
  let parser = Snapshot.create_parser 4096 in
  Test_util.check
    (expect_ok (Snapshot.feed parser (String.sub wire 0 3)) = []);
  Test_util.check
    (expect_ok (Snapshot.feed parser (String.sub wire 3 11)) = []);
  let rows = expect_ok (Snapshot.feed parser (String.sub wire 14
      (String.length wire - 14)))
  in
  let importer = Snapshot.create_import "graph-1" "65.33" 48192 3 in
  Test_util.check_eq
    (List.map (fun row -> row.Snapshot.addr) rows)
    [ 0; 1; 7 ];
  Test_util.check_eq (List.nth rows 0).Snapshot.content root;
  Test_util.check_eq (List.nth rows 2).Snapshot.addresses
    (Some "[3,4]");
  ignore (expect_ok (Snapshot.finish_parser parser));
  ignore (expect_ok (Snapshot.accept_rows importer rows));
  let completed = expect_ok (Snapshot.finish_import importer) in
  Test_util.check_eq completed.applied_server_t 48192;
  Test_util.check_eq completed.schema_version "65.33";
  Test_util.check_eq completed.graph_id "graph-1";
  Test_util.check_eq completed.row_count 3

let incomplete_oversized_and_unsigned_frames () =
  let parser = Snapshot.create_parser 4096 in
  ignore (expect_ok (Snapshot.feed parser (String.sub wire 0 3)));
  Test_util.check_eq (Snapshot.finish_parser parser)
    (Error "incomplete framed snapshot stream");
  List.iter
    (fun (limit, input) ->
       Test_util.check_eq
         (Snapshot.feed (Snapshot.create_parser limit) input)
         (Error "snapshot frame exceeds configured size limit"))
    [
      (2, wire);
      ( 4096,
        String.init 4 (fun i -> if i = 0 then Char.chr 128 else '\000')
      );
    ]

let multiple_frames_preserve_row_order () =
  let parser = Snapshot.create_parser 4096 in
  let combined =
    frame (Value.Array [])
    ^ wire
    ^ frame (Value.Array [ row 9 "last" None ])
  in
  Test_util.check_eq
    (List.map (fun row -> row.Snapshot.addr)
       (expect_ok (Snapshot.feed parser combined)))
    [ 0; 1; 7; 9 ];
  ignore (expect_ok (Snapshot.finish_parser parser))

let rejected_import_batches_do_not_mutate_progress () =
  let rows =
    expect_ok (Snapshot.feed (Snapshot.create_parser 4096) wire)
  in
  let valid = [ List.nth rows 0; List.nth rows 1 ] in
  let unordered = Snapshot.create_import "graph-1" "65.33" 0 2 in
  let bounded = Snapshot.create_import "g" "s" 0 2 in
  Test_util.check_eq
    (Snapshot.accept_rows unordered [ List.nth rows 1; List.nth rows 0 ])
    (Error "snapshot row addresses must be strictly increasing");
  ignore (expect_ok (Snapshot.accept_rows unordered valid));
  Test_util.check_eq
    (expect_ok (Snapshot.finish_import unordered)).row_count 2;
  Test_util.check_eq (Snapshot.accept_rows bounded rows)
    (Error "snapshot contains more rows than advertised");
  ignore (expect_ok (Snapshot.accept_rows bounded valid));
  Test_util.check_eq
    (expect_ok (Snapshot.finish_import bounded)).row_count 2

let malformed_snapshot_rows_are_rejected () =
  List.iter
    (fun payload ->
       match
         Snapshot.feed (Snapshot.create_parser 4096) (frame payload)
       with
       | Error _ -> ()
       | Ok _ -> failwith "malformed snapshot accepted")
    [
      Value.Null;
      Value.Array [ Value.Int 0 ];
      Value.Array
        [ Value.Array [ Value.Int 0; Value.String "x"; Value.Bool true ] ];
    ]

let cases =
  [ Test_util.case "partial prefix payload and import metadata"
      partial_prefix_payload_and_import_metadata;
    Test_util.case "incomplete oversized and unsigned frames"
      incomplete_oversized_and_unsigned_frames;
    Test_util.case "multiple frames preserve row order"
      multiple_frames_preserve_row_order;
    Test_util.case "rejected import batches do not mutate progress"
      rejected_import_batches_do_not_mutate_progress;
    Test_util.case "malformed snapshot rows are rejected"
      malformed_snapshot_rows_are_rejected ]
