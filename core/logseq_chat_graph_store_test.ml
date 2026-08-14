module Snapshot = Logseq_chat_snapshot
module Store = Logseq_chat_graph_store

let fail label message = failwith (label ^ ": " ^ message)

let expect_ok label = function
  | Ok value -> value
  | Error message -> fail label message
;;

let () =
  let active_path = Filename.temp_file "logseq-chat-graph" ".sqlite" in
  Sys.remove active_path;
  let staging_path = Store.staging_path active_path in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> if Sys.file_exists path then Sys.remove path)
        [ active_path; staging_path ])
    (fun () ->
      expect_ok "begin import" (Store.begin_import ~active_path);
      let rows : Snapshot.row list =
        [ { addr = 0
          ; content = {|["^ ","~:schema",["^ ","~:block/title",["^ ","~:db/valueType","~:db.type/string"]]]|}
          ; addresses = None
          }
        ; { addr = 1; content = "[]"; addresses = None }
        ; { addr = 7
          ; content = {|["^ ","~:keys",[]]|}
          ; addresses = Some "[3,4]"
          }
        ]
      in
      expect_ok "append rows" (Store.append_rows ~active_path rows);
      expect_ok "activate" (Store.activate ~active_path);
      if Sys.file_exists staging_path then fail "activate" "staging file remains";
      (match expect_ok "read root" (Store.read_row ~path:active_path ~addr:0) with
       | Some (content, None) when String.equal content (List.hd rows).content -> ()
       | _ -> fail "root" "content or SQL null changed");
      match expect_ok "read node" (Store.read_row ~path:active_path ~addr:7) with
      | Some (content, Some addresses)
        when String.equal content (List.nth rows 2).content
             && String.equal addresses "[3,4]" -> ()
      | _ -> fail "node" "content or addresses changed")
;;
