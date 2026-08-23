module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json
module E2ee = Logseq_chat_e2ee

let fail expected actual =
  failwith (Printf.sprintf "expected %s, got %s" expected actual)
;;

let expect_ok = function
  | Ok value -> value
  | Error message -> failwith message
;;

let expect_equal expected actual =
  if not (String.equal expected actual) then fail expected actual
;;

let private_key_package ?version () =
  let values =
    match version with
    | Some version ->
      [ Transit.String version
      ; Transit.Binary "salt"
      ; Transit.Binary "private-iv"
      ; Transit.Binary "encrypted-private-key"
      ]
    | None ->
      [ Transit.Binary "salt"
      ; Transit.Binary "private-iv"
      ; Transit.Binary "encrypted-private-key"
      ]
  in
  Codec.to_string (Transit.Array values)
;;

let encrypted_graph_key = Codec.to_string (Transit.Binary "encrypted-graph-key")

let crypto calls =
  E2ee.
    { decrypt_private_key =
        (fun ~password ~iterations ~salt ~iv ~ciphertext ->
          calls :=
            (Printf.sprintf
               "private:%s:%d:%s:%s:%s"
               password
               iterations
               salt
               iv
               ciphertext)
            :: !calls;
          Ok "private-key")
    ; decrypt_graph_key =
        (fun ~private_key ~ciphertext ->
          calls := ("graph:" ^ private_key ^ ":" ^ ciphertext) :: !calls;
          Ok "graph-key")
    ; encrypt_graph_key =
        (fun ~public_key ~plaintext ->
          calls := ("wrap:" ^ public_key ^ ":" ^ plaintext) :: !calls;
          Ok "encrypted-graph-key")
    ; random_bytes = (fun count -> Ok (String.make count 'k'))
    ; encrypt_aes_gcm =
        (fun ~key ~plaintext ->
          calls := ("seal:" ^ key ^ ":" ^ plaintext) :: !calls;
          Ok ("value-iv", "encrypted-value"))
    ; decrypt_aes_gcm =
        (fun ~key ~iv ~ciphertext ->
          calls := ("open:" ^ key ^ ":" ^ iv ^ ":" ^ ciphertext) :: !calls;
          Ok (Codec.to_string (Transit.Keyword "logseq.property/status.todo")))
    }
;;

let test_unlock_current_private_key_package () =
  let calls = ref [] in
  let key =
    E2ee.unlock_graph_key
      ~crypto:(crypto calls)
      ~password:"e2etest"
      ~private_key_package:(private_key_package ~version:"20251210" ())
      ~encrypted_graph_key
    |> expect_ok
  in
  expect_equal "graph-key" key;
  match List.rev !calls with
  | [ private_call; graph_call ] ->
    expect_equal
      "private:e2etest:600000:salt:private-iv:encrypted-private-key"
      private_call;
    expect_equal "graph:private-key:encrypted-graph-key" graph_call
  | _ -> failwith "unexpected crypto call count"
;;

let test_unlock_legacy_private_key_package () =
  let calls = ref [] in
  ignore
    (E2ee.unlock_graph_key
       ~crypto:(crypto calls)
       ~password:"e2etest"
       ~private_key_package:(private_key_package ())
       ~encrypted_graph_key
     |> expect_ok);
  match List.rev !calls with
  | private_call :: _ ->
    expect_equal
      "private:e2etest:100000:salt:private-iv:encrypted-private-key"
      private_call
  | [] -> failwith "private key decrypt was not called"
;;

let test_protected_value_round_trip_keeps_transit_type () =
  let calls = ref [] in
  let encrypted =
    E2ee.encrypt_value
      ~crypto:(crypto calls)
      ~graph_key:"graph-key"
      (Transit.Keyword "logseq.property/status.todo")
    |> expect_ok
  in
  (match Codec.of_string encrypted with
   | Transit.Array [ Transit.Binary "value-iv"; Transit.Binary "encrypted-value" ] -> ()
   | _ -> failwith "encrypted value is not the Logseq Transit AES-GCM envelope");
  let decrypted =
    E2ee.decrypt_value ~crypto:(crypto calls) ~graph_key:"graph-key" encrypted
    |> expect_ok
  in
  match decrypted with
  | Transit.Keyword "logseq.property/status.todo" -> ()
  | _ -> failwith "protected value lost its Transit type"
;;

let test_prepare_graph_key_uses_logseq_transit_binary_envelopes () =
  let calls = ref [] in
  let public_key = Codec.to_string (Transit.Binary "public-key") in
  let graph_key, encrypted =
    E2ee.prepare_graph_key ~crypto:(crypto calls) ~public_key_package:public_key
    |> expect_ok
  in
  expect_equal (String.make 32 'k') graph_key;
  (match Codec.of_string encrypted with
   | Transit.Binary "encrypted-graph-key" -> ()
   | _ -> failwith "encrypted graph key is not Transit binary");
  if not (List.mem ("wrap:public-key:" ^ String.make 32 'k') !calls)
  then failwith "graph key was not RSA encrypted"
;;

let test_invalid_envelope_fails_closed () =
  match
    E2ee.decrypt_value
      ~crypto:(crypto (ref []))
      ~graph_key:"graph-key"
      (Codec.to_string (Transit.Array [ Transit.String "iv"; Transit.String "ciphertext" ]))
  with
  | Error _ -> ()
  | Ok _ -> failwith "invalid encrypted value must not be treated as plaintext"
;;

let test_plaintext_protected_values_follow_logseq_compatibility () =
  let calls = ref [] in
  let decrypt source =
    E2ee.decrypt_string ~crypto:(crypto calls) ~graph_key:"graph-key" source
    |> expect_ok
  in
  expect_equal "Card" (decrypt "Card");
  expect_equal "Card" (decrypt (Codec.to_string (Transit.String "Card")));
  if !calls <> [] then failwith "plaintext protected values must not invoke AES-GCM"
;;

let () =
  test_unlock_current_private_key_package ();
  test_unlock_legacy_private_key_package ();
  test_prepare_graph_key_uses_logseq_transit_binary_envelopes ();
  test_protected_value_round_trip_keeps_transit_type ();
  test_invalid_envelope_fails_closed ();
  test_plaintext_protected_values_follow_logseq_compatibility ()
;;
