module Codec = struct
  include Logseq_chat_lg_core_native
  let decode ?addresses content = logseq_chat_storage_codec_decode addresses content
  let encode ?root_index_metadata payload = logseq_chat_storage_codec_encode root_index_metadata payload
end
module PSet = Persistent_sorted_set
module Transit = Transit_native.Transit.Json
open Datascript

let fail label message = failwith (label ^ ": " ^ message)

let test_compact_map_key_cache_is_not_shifted () =
  let content =
    {|{"~:keys":[[1,"~:block/title","One",1],[2,"^1","Two",1]]}|}
  in
  match Codec.decode content with
  | Storage_node (PSet.Leaf [ first; second ])
    when String.equal first.a "block/title" && String.equal second.a "block/title" ->
    ()
  | Storage_node (PSet.Leaf [ first; second ]) ->
    fail
      "compact map-key cache"
      (Printf.sprintf "decoded attributes %S and %S" first.a second.a)
  | _ -> fail "compact map-key cache" "decoded an unexpected storage node"
;;

let roundtrip label payload =
  let content, addresses = Codec.encode payload in
  if Codec.decode ?addresses content <> payload then fail label "roundtrip changed payload"
;;

let rejects label f =
  match f () with
  | _ -> fail label "accepted invalid payload"
  | exception Invalid_argument _ -> ()
;;

let test_roundtrips () =
  let datom value added = {e = 7; a = "block/title"; v = value; tx = 42; added} in
  let values =
    [ Nil; Bool false; String "text"; Int 12; Float 1.5; Keyword "block/page"
    ; Uuid "00000000-0000-0000-0000-000000000007"; Instant 123; Regex "a+"
    ; Symbol "x"; Vector [Int 1; Nil]; List [String "item"]
    ; Map [Keyword "x", Set [Int 2]]
    ]
  in
  let datoms = List.map (fun value -> datom value false) values in
  roundtrip "leaf" (Storage_node (PSet.Leaf datoms));
  roundtrip "branch" (Storage_node (PSet.Branch (datoms, ["3"; "4"])));
  roundtrip "tail" (Storage_tail [datoms; []; [datom (String "added") true]]);
  let schema_attr =
    {cardinality = Many; unique = Some Identity; indexed = true; is_component = true
    ; no_history = true; doc = Some "description"; value_type = Some TupleType
    ; tuple_attrs = Some ["block/page"; "block/title"]
    ; tuple_types = Some [RefType; StringType; KeywordType; NumberType; UuidType; InstantType; TupleType]}
  in
  let root =
    {storage_schema = ["user/tuple", schema_attr]; storage_max_eid = 7; storage_max_tx = 42
    ; storage_eavt = "3"; storage_aevt = "4"; storage_avet = "5"
    ; storage_duplicate_datoms = [datom (String "duplicate") false]
    ; storage_max_addr = 6; storage_branching_factor = 32; storage_ref_type = PSet.Weak}
  in
  roundtrip "root" (Storage_root root);
  roundtrip "strong root" (Storage_root {root with storage_ref_type = PSet.Strong});
  let index : Codec.storage_index_metadata = {count = 4; shift = 1} in
  let metadata : Codec.storage_root_index_metadata = {eavt = index; aevt = index; avet = index} in
  let content, addresses = Codec.encode ~root_index_metadata:metadata (Storage_root root) in
  if addresses <> None || Codec.decode content <> Storage_root root then fail "metadata" "root changed";
  (match Transit.of_string content with
   | Transit.Map entries ->
     List.iter (fun key ->
       match List.assoc_opt (Transit.Keyword key) entries with
       | Some (Transit.Map fields) when List.assoc (Transit.Keyword "count") fields = Transit.Int 4
                                       && List.assoc (Transit.Keyword "shift") fields = Transit.Int 1 -> ()
       | _ -> fail "metadata" key)
       ["eavt-metadata"; "aevt-metadata"; "avet-metadata"]
   | _ -> fail "metadata" "root is not a map");
  let normalized = datom (Vector [Int 9; Nil]) true in
  let content, _ = Codec.encode (Storage_node (PSet.Leaf [datom (Tuple [Some (Ref 9); None]) true])) in
  if Codec.decode content <> Storage_node (PSet.Leaf [normalized]) then fail "tuple refs" "normalization changed";
  rejects "unresolved ref" (fun () -> Codec.encode (Storage_node (PSet.Leaf [datom (Ref_to (Entity_id 1)) true])));
  rejects "invalid child address" (fun () -> Codec.encode (Storage_node (PSet.Branch ([], ["invalid"]))));
  rejects "invalid address json" (fun () -> Codec.decode ~addresses:"{}" {|{"~:keys":[]}|});
  rejects "invalid datom" (fun () -> Codec.decode {|{"~:keys":[[1,"block/title","x",1]]}|});
  rejects "missing root fields" (fun () -> Codec.decode {|{"~:schema":{}}|});
  rejects "unknown payload" (fun () -> Codec.decode "null")
;;

let () =
  test_compact_map_key_cache_is_not_shifted ();
  test_roundtrips ()
