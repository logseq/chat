open Logseq_chat_lui_snapshot

let equal expected actual message =
  if expected <> actual
  then failwith (Printf.sprintf "%s: expected %S, got %S" message expected actual)
;;

let () =
  let response =
    {|{"apiVersion":1,"ok":true,"result":{"graphName":"Work","searchQuery":"project","searchResults":[{"uuid":"page-a","title":"Project Alpha","isPage":true,"page":null,"breadcrumbs":[]},{"uuid":"block-a","title":"Project note","isPage":false,"page":{"uuid":"page-a","title":"Project Alpha"},"breadcrumbs":[{"uuid":"parent-a","title":"Parent"}]}],"outlinerState":{"editing":{"uuid":"outline-a","title":"Nested note","caretUTF16Offset":6}},"outlinerRows":[{"block":{"uuid":"outline-a","title":"Nested note"},"depth":2,"hasChildren":true,"isCollapsed":false}],"syncConnected":true}}|}
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
