open Logseq_chat_lui_snapshot

let equal expected actual message =
  if expected <> actual
  then failwith (Printf.sprintf "%s: expected %S, got %S" message expected actual)
;;

let () =
  let response =
    {|{"apiVersion":1,"ok":true,"result":{"graphName":"Work","searchQuery":"project","searchResults":[{"uuid":"page-a","title":"Project Alpha","isPage":true,"page":null,"breadcrumbs":[]},{"uuid":"block-a","title":"Project note","isPage":false,"page":{"uuid":"page-a","title":"Project Alpha"},"breadcrumbs":[{"uuid":"parent-a","title":"Parent"}]}],"syncConnected":true}}|}
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
     | _ -> failwith "search results were not projected")
;;
