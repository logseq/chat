module LG = Logseq_chat_lui_native
module Projection = Logseq_chat_lui_projection
module Snapshot = Logseq_chat_lui_snapshot

let () =
  let encoded =
    {|{"apiVersion":1,"ok":true,"result":{"outlinerRows":[{"block":{"uuid":"journal","title":"Journal"},"depth":0,"hasChildren":false,"isCollapsed":false}],"nodeRoutes":[{"uuid":"node-a","isTag":false,"isProperty":false,"page":{"uuid":"page-a","title":"Project"},"outlinerState":{"editing":{"uuid":"child","title":"Child","caretUTF16Offset":5},"selectedBlockIds":["child"],"autocomplete":null},"outlinerAutocompleteCandidates":[],"outlinerRows":[{"block":{"uuid":"child","title":"Child"},"depth":1,"hasChildren":false,"isCollapsed":false}]}]}}|}
  in
  match Snapshot.decode_response encoded with
  | Error message -> failwith message
  | Ok ({ node_routes = [ route ]; _ } as snapshot) ->
    let projected = Projection.node_projection route in
    (match Rrbvec.to_list projected.outliner_rows with
     | [ row ] when String.equal row.uuid "child" -> ()
     | _ -> failwith "node route rows were not retained in the LG projection");
    (match projected.outliner_editing with
     | Some editing when String.equal editing.uuid "child" -> ()
     | _ -> failwith "node route editor state was not retained in the LG projection");
    if Rrbvec.to_list projected.outliner_selected_block_ids <> [ "child" ]
    then failwith "node route selection was not retained in the LG projection";
    (match Rrbvec.to_list (Projection.core_projection snapshot).journal_outliner_rows with
     | [ row ] when String.equal row.uuid "journal" -> ()
     | _ -> failwith "journal rows were not retained behind node navigation")
  | Ok _ -> failwith "expected one node route"
;;

let () =
  ignore (LG.logseq_chat_native_bridge_initialize 2 1 0);
  let patch =
    Projection.apply_response
      {|{"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Local graph","selectedGraphId":"local","graphs":[{"id":"local","name":"Local graph","schemaVersion":"65.33","isEncrypted":false,"isReady":true}]}}|}
  in
  if String.equal patch "" then
    failwith "applying the first authoritative graph snapshot must publish a retained patch";
  ignore (LG.logseq_chat_native_bridge_dispose ())
;;
