module Codec = Logseq_chat_logseq_storage_codec
module PSet = Persistent_sorted_set
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

let () = test_compact_map_key_cache_is_not_shifted ()
