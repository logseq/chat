let session = ref (Logseq_chat_rpc.create ())
let sqlite_session : Logseq_chat_sqlite.session option ref = ref None

let assoc name fields = List.assoc_opt name fields

let open_database request =
  match Yojson.Basic.from_string request with
  | `Assoc fields ->
    (match assoc "method" fields, assoc "params" fields with
     | Some (`String "open"), Some (`Assoc params) ->
       (match assoc "path" params with
        | Some (`String path) ->
          Option.iter Logseq_chat_sqlite.close !sqlite_session;
          let opened = Logseq_chat_sqlite.open_session path in
          sqlite_session := Some opened;
          session :=
            Logseq_chat_rpc.create ~storage:(Logseq_chat_sqlite.storage opened) ();
          Some (Logseq_chat_rpc.call !session {|{"apiVersion":1,"method":"snapshot","params":{}}|})
        | _ -> None)
     | _ -> None)
  | _ -> None
  | exception _ -> None
;;

let call request =
  match open_database request with
  | Some response -> response
  | None -> Logseq_chat_rpc.call !session request
;;

let () = Callback.register "logseq_chat_mobile_call" call
