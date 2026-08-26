open Logseq_chat_lui_snapshot

let equal expected actual message =
  if expected <> actual
  then failwith (Printf.sprintf "%s: expected %S, got %S" message expected actual)
;;

let () =
  let response =
    {|{"apiVersion":1,"ok":true,"result":{"graphName":"Work","searchQuery":"project","searchResults":[{"uuid":"page-a","title":"Project Alpha","isPage":true,"page":null,"breadcrumbs":[]},{"uuid":"block-a","title":"Project note","isPage":false,"page":{"uuid":"page-a","title":"Project Alpha"},"breadcrumbs":[{"uuid":"parent-a","title":"Parent"}]}],"outlinerState":{"editing":{"uuid":"outline-a","title":"Nested note","caretUTF16Offset":6},"selectedBlockIds":["outline-a"],"autocomplete":{"kind":"node","query":"Pro"}},"outlinerAutocompleteCandidates":[{"label":"Project Alpha","value":"page-a"}],"outlinerRows":[{"block":{"uuid":"outline-a","title":"Nested note"},"depth":2,"hasChildren":true,"isCollapsed":false}],"syncConnected":true}}|}
  in
  match decode_response response with
  | Error message -> failwith message
  | Ok snapshot ->
    equal "Work" (Option.value ~default:"" snapshot.graph_name) "graph name";
    equal "project" snapshot.search_query "search query";
    if not snapshot.sync_connected then failwith "sync state was not projected";
    (match snapshot.search_results with
     | [ page; block ] ->
       equal "page-a" page.uuid "page uuid";
       if not page.is_page then failwith "page result lost its kind";
       equal "Parent" block.breadcrumb "block breadcrumb"
     | _ -> failwith "search results were not projected");
    (match snapshot.outliner_rows with
     | [ row ] ->
       equal "outline-a" row.uuid "outliner uuid";
       equal "Nested note" row.title "outliner title";
       if row.depth <> 2 || not row.has_children || row.is_collapsed
       then failwith "outliner presentation state was not projected"
     | _ -> failwith "outliner rows were not projected")
    ; (match snapshot.outliner_editing with
       | Some editing ->
         equal "outline-a" editing.uuid "editing uuid";
         equal "Nested note" editing.title "editing title";
         if editing.caret_utf16_offset <> 6 then failwith "editing caret was not projected"
       | None -> failwith "outliner editing was not projected")
    ; if snapshot.is_outliner_patch then failwith "launch snapshot was marked as a patch";
    (match snapshot.outliner_selected_block_ids with
     | [ "outline-a" ] -> ()
     | _ -> failwith "selected outliner blocks were not projected");
    (match snapshot.outliner_autocomplete with
     | Some { kind = Node; query = "Pro" } -> ()
     | _ -> failwith "outliner autocomplete state was not projected");
    (match snapshot.outliner_autocomplete_candidates with
     | [ { label = "Project Alpha"; value = "page-a" } ] -> ()
     | _ -> failwith "outliner autocomplete candidates were not projected");
    let routed =
      decode_response
        {|{"apiVersion":1,"ok":true,"result":{"graphName":"Work","outlinerState":{"editing":null},"outlinerRows":[{"block":{"uuid":"base","title":"Base"},"depth":0,"hasChildren":false,"isCollapsed":false}],"nodeRoutes":[{"uuid":"node-a","isTag":false,"isProperty":false,"page":{"uuid":"page-a","title":"Project"},"outlinerState":{"editing":{"uuid":"child","title":"Child","caretUTF16Offset":5},"selectedBlockIds":[],"autocomplete":null},"outlinerAutocompleteCandidates":[],"outlinerRows":[{"block":{"uuid":"child","title":"Child"},"depth":1,"hasChildren":false,"isCollapsed":false}]}],"syncConnected":true}}|}
    in
    (match routed with
     | Ok routed ->
       (match routed.node_routes, routed.outliner_rows, routed.outliner_editing with
        | [ { uuid = "node-a"; title = "Project"; _ } ],
          [ { uuid = "child"; _ } ],
          Some { uuid = "child"; _ } -> ()
        | _ -> failwith "the active node route did not become the outliner surface")
     | Error message -> failwith message);
    let patch_response =
      {|{"apiVersion":1,"ok":true,"result":{"outlinerRows":[],"outlinerRowSplices":[{"start":0,"afterBlockId":null,"beforeBlockId":null,"deleteCount":2,"rows":[{"block":{"uuid":"outline-a","title":"Nested note"},"depth":0,"hasChildren":true,"isCollapsed":true}]}],"outlinerState":{"editing":null},"isOutlinerPatch":true,"syncConnected":false}}|}
    in
    (match decode_response patch_response with
     | Error message -> failwith message
     | Ok patch ->
       if not patch.is_outliner_patch then failwith "outliner patch flag was lost";
       (match patch.outliner_row_splices with
        | [ splice ] ->
          if splice.start <> Some 0 || splice.delete_count <> 2
          then failwith "outliner splice bounds were not projected";
          (match splice.rows with
           | [ row ] when row.uuid = "outline-a" && row.is_collapsed -> ()
           | _ -> failwith "outliner splice rows were not projected")
        | _ -> failwith "outliner row splices were not projected"))
;;
