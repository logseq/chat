open Logseq_chat_lg_core_native

let decode = logseq_chat_host_update_decode

let fail message = raise (Failure message)

let () =
  let settings_json =
    {|{"appearance":"dark","language":"zh-CN","spellCheck":false,"autoCorrection":true,"sidebarTabs":["journals","graphs"],"baseURL":"https://example.com","version":"1.2.3","revision":"abc123"}|}
  in
  (match decode "settings" settings_json with
   | Ok
       (Settings
         { appearance = "dark"
         ; language = "zh-CN"
         ; spell_check = false
         ; auto_correction = true
         ; sidebar_tabs
         ; base_url = "https://example.com"
         ; version = "1.2.3"
         ; revision = "abc123"
         }) when Rrbvec.to_list sidebar_tabs = [ "journals"; "graphs" ] -> ()
   | _ -> fail "settings host update was not decoded");
  let logs_json =
    {|[{"id":"7","level":"ERROR","source":"ui","timestamp":"12:34","message":"第一行\nsecond line"}]|}
  in
  (match decode "runtime-log" logs_json with
   | Ok
       (Runtime_log records) when Rrbvec.to_list records =
         [ { id = "7"
           ; level = "ERROR"
           ; source = "ui"
           ; timestamp = "12:34"
           ; message = "第一行\nsecond line"
           }
         ] -> ()
   | _ -> fail "runtime log host update lost Unicode or newlines");
  (match decode "local-graph-ids" {|["a","b"]|} with
   | Ok (Local_graph_ids ids) when Rrbvec.to_list ids = [ "a"; "b" ] -> ()
   | _ -> fail "local graph identifiers were not decoded");
  (match decode "open-capture" {|{}|} with
   | Ok Open_capture -> ()
   | _ -> fail "capture presentation host updates were not decoded");
  (match decode "composer-draft" {|"稍后处理\nsecond line"|} with
   | Ok (Composer_draft "稍后处理\nsecond line") -> ()
   | _ -> fail "composer draft host updates lost Unicode or newlines");
  (match decode "graph-loading" {|true|} with
   | Ok (Graph_loading true) -> ()
   | _ -> fail "graph loading host updates were not decoded");
  (match
     decode
       "authentication"
       {|{"state":"signedOut","errorMessage":"Authorization was cancelled"}|}
   with
   | Ok
       (Authentication
         { state = "signedOut"; error_message = Some "Authorization was cancelled" }) ->
     ()
   | Error message -> fail ("authentication host update was rejected: " ^ message)
   | Ok _ -> fail "authentication host update lost its state or error");
  (match decode "authentication" {|{"state":"signedIn","errorMessage":null}|} with
   | Ok (Authentication { state = "signedIn"; error_message = None }) -> ()
   | Error message -> fail ("nullable authentication errors were rejected: " ^ message)
   | Ok _ -> fail "signed-in authentication did not preserve a null error");
  (match decode "unknown" {|{}|} with
   | Error _ -> ()
   | Ok _ -> fail "unknown host updates must be rejected")
;;

let () =
  let session =
    {|{"graphId":null,"destination":"graphs","draft":"draft","assets":[{"uuid":"a","title":"image","localPath":"/tmp/a","payload":"raw"}],"composerExpanded":true,"searchOpen":false,"query":"q","appPath":["p1","p2"],"searchPath":[],"selectedPageId":"p2","settingsOpen":true}|}
  in
  (match decode "restore-ui-session" session with
   | Ok (Restore_ui_session state) ->
     assert (state.graph_id = None);
     assert (state.destination = "graphs" && state.draft = "draft");
     assert (state.composer_expanded && not state.search_open && state.settings_open);
     assert (state.query = "q" && state.selected_page_id = Some "p2");
     assert (Rrbvec.to_list state.app_path = ["p1"; "p2"]);
     assert (Rrbvec.to_list state.search_path = []);
     assert (Rrbvec.to_list state.assets =
       [{uuid = "a"; title = "image"; local_path = "/tmp/a"; payload = "raw"}])
   | _ -> fail "UI session restoration lost state");
  let asset = {|{"uuid":"a","title":"image","localPath":"/tmp/a"}|} in
  (match decode "composer-asset" asset with
   | Ok (Composer_asset value) -> assert (value.payload = asset)
   | _ -> fail "composer asset must preserve its original payload");
  (match decode "save-ui-session" "null" with
   | Ok Save_ui_session -> ()
   | _ -> fail "save UI session was rejected");
  (match decode "open-quick-action" {|"capture"|} with
   | Ok (Open_quick_action "capture") -> ()
   | _ -> fail "quick action was rejected");
  List.iter
    (fun (kind, payload, prefix) ->
      match decode kind payload with
      | Error message when String.starts_with ~prefix message -> ()
      | _ -> fail ("invalid host update was not classified: " ^ kind))
    ["open-capture", "{", "Invalid host update JSON: ";
     "graph-loading", {|"yes"|}, "Invalid graph-loading host update: ";
     "settings", "{}", "Invalid settings host update: ";
     "local-graph-ids", {|["a",1]|}, "Invalid local-graph-ids host update: ";
     "unknown", "{}", "Unsupported host update: unknown"]
;;
