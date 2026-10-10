module Native = Melange_edn_native

let typed_map_set_and_keyword_roundtrip () =
  match Edn.decode "{:block/tags #{:logseq.class/Task}}" with
  | Error message -> Alcotest.fail message
  | Ok value ->
    (match value with
     | Native.(Any (Map entries)) ->
       Test_util.check ~msg:"map has one entry" (Array.length entries = 1);
       (match entries.(0) with
        | Native.(Any (Keyword keyword)), Native.(Any (Set values)) ->
          Test_util.check_eq (Native.keyword_to_string keyword)
            "block/tags";
          Test_util.check ~msg:"set has one member"
            (Array.length values = 1);
          (match values.(0) with
           | Native.(Any (Keyword keyword)) ->
             Test_util.check_eq (Native.keyword_to_string keyword)
               "logseq.class/Task"
           | _ -> Alcotest.fail "expected a keyword set member")
        | _ -> Alcotest.fail "expected a typed EDN map entry")
     | _ -> Alcotest.fail "expected a typed EDN map");
    (match Edn.decode (Edn.encode value) with
     | Ok _ -> ()
     | Error message -> Alcotest.fail message)

let cases =
  [ Test_util.case "typed map/set/keyword roundtrip"
      typed_map_set_and_keyword_roundtrip ]
