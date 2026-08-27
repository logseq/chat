module LG = Logseq_chat_lui_native
module Projection = Logseq_chat_lui_projection
module Snapshot = Logseq_chat_lui_snapshot

let () =
  let encoded =
    {|{"apiVersion":1,"ok":true,"result":{"nodeRoutes":[{"uuid":"node-a","isTag":false,"isProperty":false,"page":{"uuid":"page-a","title":"Project"},"outlinerState":{"editing":{"uuid":"child","title":"Child","caretUTF16Offset":5},"selectedBlockIds":["child"],"autocomplete":null},"outlinerAutocompleteCandidates":[],"outlinerRows":[{"block":{"uuid":"child","title":"Child"},"depth":1,"hasChildren":false,"isCollapsed":false}]}]}}|}
  in
  match Snapshot.decode_response encoded with
  | Error message -> failwith message
  | Ok { node_routes = [ route ]; _ } ->
    let projected = Projection.node_projection route in
    (match Rrbvec.to_list projected.outliner_rows with
     | [ row ] when String.equal row.uuid "child" -> ()
     | _ -> failwith "node route rows were not retained in the LG projection");
    (match projected.outliner_editing with
     | Some editing when String.equal editing.uuid "child" -> ()
     | _ -> failwith "node route editor state was not retained in the LG projection");
    if Rrbvec.to_list projected.outliner_selected_block_ids <> [ "child" ]
    then failwith "node route selection was not retained in the LG projection"
  | Ok _ -> failwith "expected one node route"
;;
