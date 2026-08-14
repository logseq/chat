let () =
  let open Melange_edn_native in
  match Logseq_chat_edn.decode "{:block/tags #{:logseq.class/Task}}" with
  | Error message -> failwith message
  | Ok (Any (Map entries) as value) ->
    (match Array.to_list entries with
     | [ Any (Keyword key), Any (Set values) ]
       when String.equal (keyword_to_string key) "block/tags" ->
       (match Array.to_list values with
        | [ Any (Keyword tag) ]
          when String.equal (keyword_to_string tag) "logseq.class/Task" -> ()
        | _ -> failwith "EDN set/keyword value changed")
     | _ -> failwith "EDN map/keyword key changed");
    let encoded = Logseq_chat_edn.encode value in
    (match Logseq_chat_edn.decode encoded with
     | Ok _ -> ()
     | Error message -> failwith message)
  | Ok _ -> failwith "expected typed EDN map"
;;
