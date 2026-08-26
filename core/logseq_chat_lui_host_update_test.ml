open Logseq_chat_lui_host_update

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
         ; sidebar_tabs = [ "journals"; "graphs" ]
         ; base_url = "https://example.com"
         ; version = "1.2.3"
         ; revision = "abc123"
         }) -> ()
   | _ -> fail "settings host update was not decoded");
  let logs_json =
    {|[{"id":"7","level":"ERROR","source":"ui","timestamp":"12:34","message":"第一行\nsecond line"}]|}
  in
  (match decode "runtime-log" logs_json with
   | Ok
       (Runtime_log
         [ { id = "7"
           ; level = "ERROR"
           ; source = "ui"
           ; timestamp = "12:34"
           ; message = "第一行\nsecond line"
           }
         ]) -> ()
   | _ -> fail "runtime log host update lost Unicode or newlines");
  (match decode "local-graph-ids" {|["a","b"]|} with
   | Ok (Local_graph_ids [ "a"; "b" ]) -> ()
   | _ -> fail "local graph identifiers were not decoded");
  (match decode "unknown" {|{}|} with
   | Error _ -> ()
   | Ok _ -> fail "unknown host updates must be rejected")
;;
