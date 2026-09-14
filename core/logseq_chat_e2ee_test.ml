module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json
module E2ee = struct
  include Logseq_chat_lg_core_native
  let unlock_graph_key ~crypto ~password ~private_key_package ~encrypted_graph_key =
    logseq_chat_e2ee_unlock_graph_key crypto password private_key_package encrypted_graph_key
  let prepare_graph_key ~crypto ~public_key_package =
    logseq_chat_e2ee_prepare_graph_key crypto public_key_package
  let encrypt_value ~crypto ~graph_key value = logseq_chat_e2ee_encrypt_value crypto graph_key value
  let decrypt_value ~crypto ~graph_key value = logseq_chat_e2ee_decrypt_value crypto graph_key value
  let decrypt_string ~crypto ~graph_key value = logseq_chat_e2ee_decrypt_string crypto graph_key value
end

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
        (fun password iterations salt iv ciphertext ->
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
        (fun private_key ciphertext ->
          calls := ("graph:" ^ private_key ^ ":" ^ ciphertext) :: !calls;
          Ok "graph-key")
    ; encrypt_graph_key =
        (fun public_key plaintext ->
          calls := ("wrap:" ^ public_key ^ ":" ^ plaintext) :: !calls;
          Ok "encrypted-graph-key")
    ; random_bytes = (fun count -> Ok (String.make count 'k'))
    ; encrypt_aes_gcm =
        (fun key plaintext ->
          calls := ("seal:" ^ key ^ ":" ^ plaintext) :: !calls;
          Ok ("value-iv", "encrypted-value"))
    ; decrypt_aes_gcm =
        (fun key iv ciphertext ->
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

let () =
  let calls = ref [] in
  let base = crypto calls in
  let assert_error expected = function
    | Error actual -> expect_equal expected actual
    | Ok _ -> failwith "expected crypto error"
  in
  let failed_private = {base with decrypt_private_key = (fun _ _ _ _ _ -> Error "private failure")} in
  E2ee.unlock_graph_key ~crypto:failed_private ~password:"p"
    ~private_key_package:(private_key_package ()) ~encrypted_graph_key
  |> assert_error "private failure";
  if !calls <> [] then failwith "graph decrypt ran after private decrypt failure";
  let failed_random = {base with random_bytes = (fun _ -> Error "random failure")} in
  E2ee.prepare_graph_key ~crypto:failed_random
    ~public_key_package:(Codec.to_string (Transit.Binary "public"))
  |> assert_error "random failure";
  if !calls <> [] then failwith "graph encrypt ran after random failure";
  E2ee.prepare_graph_key ~crypto:base ~public_key_package:(Codec.to_string (Transit.String "not binary"))
  |> assert_error "encrypted graph key is not Transit binary";
  if !calls <> [] then failwith "invalid public key reached crypto";
  let bad_aes = {base with decrypt_aes_gcm = (fun _ _ _ -> Error "authentication failure")} in
  E2ee.decrypt_value ~crypto:bad_aes ~graph_key:"g"
    (Codec.to_string (Transit.Array [Transit.Binary "iv"; Transit.Binary "cipher"]))
  |> assert_error "authentication failure";
  List.iter (fun values ->
    E2ee.decrypt_value ~crypto:base ~graph_key:"g" (Codec.to_string (Transit.Array values))
    |> assert_error "encrypted value has an invalid Transit AES-GCM envelope")
    [[Transit.Binary "iv"; Transit.Binary "cipher"; Transit.Int 1];
     [Transit.String "iv"; Transit.Binary "cipher"]];
  E2ee.decrypt_string ~crypto:base ~graph_key:"g" (Codec.to_string (Transit.Int 1))
  |> assert_error "decrypted protected value is not a string";
  let nested = Codec.to_string (Transit.String (Codec.to_string (Transit.String "nested"))) in
  expect_equal "nested" (E2ee.decrypt_string ~crypto:base ~graph_key:"g" nested |> expect_ok);
  let old = E2ee.logseq_chat_e2ee_private_key_package (private_key_package ~version:"20251209" ()) |> expect_ok in
  if old.iterations <> 100_000 then failwith "pre-upgrade key iteration count changed";
  if !calls <> [] then failwith "invalid or plaintext envelopes reached crypto"
;;
