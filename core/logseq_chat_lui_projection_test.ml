module LG = Logseq_chat_lui_native

let () =
  let encoded =
    {|{"apiVersion":1,"ok":true,"result":{"outlinerRows":[{"block":{"uuid":"journal","title":"Journal"},"depth":0,"hasChildren":false,"isCollapsed":false}],"nodeRoutes":[{"uuid":"node-a","isTag":false,"isProperty":false,"page":{"uuid":"page-a","title":"Project"},"outlinerState":{"editing":{"uuid":"child","title":"Child","caretUTF16Offset":5},"selectedBlockIds":["child"],"autocomplete":null},"outlinerAutocompleteCandidates":[],"outlinerRows":[{"block":{"uuid":"child","title":"Child"},"depth":1,"hasChildren":false,"isCollapsed":false}]}]}}|}
  in
  match LG.logseq_chat_snapshot_decode_response encoded with
  | Error message -> failwith message
  | Ok snapshot ->
    if Rrbvec.length snapshot.node_routes <> 1 then failwith "expected one node route";
    let projected = Rrbvec.nth snapshot.node_routes 0 in
    (match Rrbvec.to_list projected.outliner_rows with
     | [ row ] when String.equal row.uuid "child" -> ()
     | _ -> failwith "node route rows were not retained in the LG projection");
    (match projected.outliner_editing with
     | Some editing when String.equal editing.uuid "child" -> ()
     | _ -> failwith "node route editor state was not retained in the LG projection");
    if Rrbvec.to_list projected.outliner_selected_block_ids <> [ "child" ]
    then failwith "node route selection was not retained in the LG projection";
    (match Rrbvec.to_list snapshot.journal_outliner_rows with
     | [ row ] when String.equal row.uuid "journal" -> ()
     | _ -> failwith "journal rows were not retained behind node navigation")
;;

let () =
  ignore (LG.logseq_chat_native_bridge_initialize 2 1 0);
  let patch =
    LG.logseq_chat_native_bridge_apply_response
      {|{"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"selectedBlock":null,"lastRefreshAt":null,"graphName":"Local graph","selectedGraphId":"local","graphs":[{"id":"local","name":"Local graph","schemaVersion":"65.33","isEncrypted":false,"isReady":true}]}}|}
  in
  if String.equal patch "" then
    failwith "applying the first authoritative graph snapshot must publish a retained patch";
  ignore (LG.logseq_chat_native_bridge_dispose ())
;;

let () =
  let original = LG.logseq_chat_model_initial () in
  let asset : LG.composer_asset =
    { uuid = "pending-photo"; title = "照片.jpg"; local_path = "/tmp/photo.jpg";
      payload = "{\"uuid\":\"pending-photo\"}" }
  in
  let original = { original with
    selected_graph_id = Some "local";
    composer_draft = "Unsent\n草稿";
    composer_expanded = true;
    composer_assets = Rrbvec.of_list [asset];
    search_open = true; search_query = "hello";
    app_navigation_path = Rrbvec.of_list [LG.NodeRoute "page-a"];
    search_navigation_path = Rrbvec.of_list [LG.NodeRoute "block-b"] }
  in
  let saved = LG.logseq_chat_model_ui_session original
    |> LG.logseq_chat_native_bridge_encode_ui_session in
  ignore (LG.logseq_chat_native_bridge_initialize 2 1 3);
  ignore (LG.logseq_chat_native_bridge_apply_response
    {|{"apiVersion":1,"ok":true,"result":{"revision":1,"blocks":[],"selectedBlock":null,"lastRefreshAt":null,"selectedGraphId":"local","graphName":"Local","graphs":[]}}|});
  ignore (LG.logseq_chat_native_bridge_apply_host_update "restore-ui-session" saved);
  (* Save the restored model through the same native effect used by the host. *)
  ignore (LG.logseq_chat_native_bridge_apply_host_update "save-ui-session" "null");
  let rec drain remaining =
    if remaining = 0 then failwith "restored session did not emit persistence effect";
    let envelope = LG.logseq_chat_native_bridge_take_effect () |> Yojson.Safe.from_string in
    let encoded_effect = Yojson.Safe.Util.(envelope |> member "effect") in
    let kind = Yojson.Safe.Util.(encoded_effect |> member "kind" |> to_string) in
    if String.equal kind "persist-ui-session" then
      Yojson.Safe.Util.(encoded_effect |> member "text" |> to_string)
    else (
      let id = Yojson.Safe.Util.(encoded_effect |> member "id" |> to_int) in
      ignore (LG.logseq_chat_native_bridge_resolve_effect id true "");
      drain (remaining - 1))
  in
  let restored = drain 8 in
  if Yojson.Safe.from_string saved <> Yojson.Safe.from_string restored then
    failwith "native session round trip lost draft, attachment, search, or navigation";
  ignore (LG.logseq_chat_native_bridge_dispose ())
;;

let () =
  List.iter (fun kind ->
    ignore (LG.logseq_chat_native_bridge_initialize 2 1 3);
    ignore (LG.logseq_chat_native_bridge_apply_host_update "open-quick-action" (Yojson.Safe.to_string (`String kind)));
    let take () =
      let json = LG.logseq_chat_native_bridge_take_effect () |> Yojson.Safe.from_string in
      Yojson.Safe.Util.(json |> member "effect")
    in
    let clear = take () in
    if Yojson.Safe.Util.(clear |> member "kind" |> to_string) <> "clear-selected-page" then
      failwith "quick action must first return the core to the journal";
    ignore (LG.logseq_chat_native_bridge_resolve_effect
      Yojson.Safe.Util.(clear |> member "id" |> to_int) true "");
    if kind = "audio" then (
      let recorder = take () in
      if Yojson.Safe.Util.(recorder |> member "kind" |> to_string) <> "present-attachment"
         || Yojson.Safe.Util.(recorder |> member "text" |> to_string) <> "audio" then
        failwith "audio shortcut must invoke the existing native recorder");
    ignore (LG.logseq_chat_native_bridge_dispose ()))
    ["capture"; "journal"; "audio"]
;;
