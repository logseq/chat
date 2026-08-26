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
    let rich =
      decode_response
        {|{"apiVersion":1,"ok":true,"result":{"outlinerState":{"editing":null},"outlinerRows":[{"block":{"uuid":"video","title":"{{youtube dQw4w9WgXcQ}}","markup":[{"type":"video","url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}]},"depth":0,"hasChildren":false,"isCollapsed":false},{"block":{"uuid":"timestamp","title":"{{youtube-timestamp 01:23}}","markup":[{"type":"youtubeTimestamp","text":"01:23","style":"83"}]},"depth":0,"hasChildren":false,"isCollapsed":false,"youtubeTargetURL":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}],"syncConnected":true}}|}
    in
    (match rich with
     | Ok { outliner_rows = [ video; timestamp ]; _ } ->
       equal
         {|[{"type":"video","url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}]|}
         video.markup_json
         "rich markup JSON";
       equal
         "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
         (Option.value ~default:"" timestamp.youtube_target_url)
         "cross-block YouTube timestamp target"
     | Ok _ -> failwith "rich outliner rows were not projected"
     | Error message -> failwith message);
    let related =
      decode_response
        {|{"apiVersion":1,"ok":true,"result":{"outlinerState":{"editing":null},"nodeRoutes":[{"uuid":"tag-a","isTag":true,"isProperty":false,"page":{"uuid":"tag-a","title":"Project"},"blocks":[],"relatedBlocks":[{"uuid":"page-object","title":"Tagged page","pageId":"page-object","breadcrumbs":[{"uuid":"journal","title":"Journal"}],"markup":[]}],"linkedReferenceBlocks":[{"uuid":"linked","title":"Linked block","pageId":"journal","breadcrumbs":[],"markup":[]}],"outlinerState":{"editing":null},"outlinerRows":[],"outlinerAutocompleteCandidates":[]}],"syncConnected":true}}|}
    in
    (match related with
     | Ok { node_routes = [ route ]; _ } ->
       (match route.related_rows, route.linked_reference_rows with
        | [ related_row ], [ linked_row ] ->
          if not related_row.opens_as_page
          then failwith "whole-page related rows must navigate";
          equal "Journal" related_row.breadcrumb "related breadcrumb";
          equal "linked" linked_row.uuid "linked reference row"
        | _ -> failwith "related node rows were not projected")
     | Ok _ -> failwith "related node route was not projected"
     | Error message -> failwith message);
    let sidebar =
      decode_response
        {|{"apiVersion":1,"ok":true,"result":{"favorites":[{"uuid":"page-a","title":"Favorite page"}],"recentPages":[{"uuid":"page-b","title":"Recent page"}],"selectedPage":{"uuid":"page-a","title":"Favorite page"},"selectedPageIsTag":false,"selectedPageIsProperty":false,"relatedBlocks":[{"uuid":"reference","title":"Linked from journal","pageId":"journal","breadcrumbs":[{"uuid":"journal","title":"Journal"}],"markup":[]}],"linkedReferenceBlocks":[],"outlinerState":{"editing":null},"outlinerRows":[],"syncConnected":true}}|}
    in
    (match sidebar with
     | Ok snapshot ->
       (match snapshot.favorites, snapshot.recent_pages, snapshot.selected_page with
        | [ { uuid = "page-a"; _ } ], [ { uuid = "page-b"; _ } ],
          Some { uuid = "page-a"; _ } -> ()
        | _ -> failwith "sidebar pages were not projected");
       (match snapshot.related_rows with
        | [ { uuid = "reference"; breadcrumb = "Journal"; _ } ] -> ()
        | _ -> failwith "selected-page related rows were not projected")
     | Error message -> failwith message);
    let flashcards =
      decode_response
        {|{"apiVersion":1,"ok":true,"result":{"flashcards":[{"block":{"uuid":"card-a","title":"Remember {{cloze this}}","markup":[{"type":"text","text":"Remember "},{"type":"cloze","text":"this"}]},"children":[{"uuid":"answer-a","title":"Child answer","markup":[{"type":"text","text":"Child answer"}]}],"due":1,"repetitions":0,"lapses":0,"state":"new"}],"outlinerState":{"editing":null},"outlinerRows":[],"syncConnected":true}}|}
    in
    (match flashcards with
     | Ok { flashcards = [ card ]; _ } ->
       equal "card-a" card.uuid "flashcard uuid";
       equal "Remember […]" card.question_hidden "hidden cloze";
       equal "Remember this" card.question_revealed "revealed cloze";
       if not card.has_cloze then failwith "flashcard cloze metadata was lost";
       (match card.answer_rows with
        | [ { uuid = "answer-a"; text = "Child answer" } ] -> ()
        | _ -> failwith "flashcard answer rows were not projected")
     | Ok _ -> failwith "flashcards were not projected"
     | Error message -> failwith message);
    let legacy_flashcards =
      decode_response
        {|{"apiVersion":1,"ok":true,"result":{"flashcards":[{"block":{"uuid":"legacy-card","title":"Remember {{cloze this}}"},"children":[],"due":1,"repetitions":0,"lapses":0,"state":"new"}],"outlinerState":{"editing":null},"outlinerRows":[],"syncConnected":true}}|}
    in
    (match legacy_flashcards with
     | Ok { flashcards = [ card ]; _ } ->
       equal "Remember […]" card.question_hidden "legacy hidden cloze";
       equal "Remember this" card.question_revealed "legacy revealed cloze";
       if not card.has_cloze then failwith "legacy flashcard cloze metadata was lost"
     | Ok _ -> failwith "legacy flashcard was not projected"
     | Error message -> failwith message);
    let graph_catalog =
      decode_response
        {|{"apiVersion":1,"ok":true,"result":{"graphName":"Local graph","selectedGraphId":"local","graphs":[{"id":"local","name":"Local graph","schemaVersion":"65.33","isEncrypted":false,"isReady":true},{"id":"remote","name":"Remote graph","schemaVersion":null,"isEncrypted":true,"isReady":false}],"isGraphEncrypted":false,"isGraphUnlocked":true,"outlinerState":{"editing":null},"outlinerRows":[],"syncConnected":true}}|}
    in
    (match graph_catalog with
     | Ok
         { selected_graph_id = Some "local"
         ; graphs = [ local; remote ]
         ; is_graph_encrypted = false
         ; is_graph_unlocked = true
         ; _
         } ->
       equal "local" local.id "local graph id";
       equal "Local graph" local.name "local graph name";
       if local.is_encrypted || not local.is_ready
       then failwith "local graph flags were not projected";
       if not remote.is_encrypted || remote.is_ready
       then failwith "remote graph flags were not projected"
     | Ok _ -> failwith "graph catalog was not projected"
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
