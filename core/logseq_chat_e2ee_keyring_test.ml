module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json
module E2ee = Logseq_chat_lg_core_native
module Keyring = Logseq_chat_lg_core_native
module Api = Logseq_chat_lg_core_native

let expect_ok = function
  | Ok value -> value
  | Error message -> failwith message
;;

let expect_equal expected actual =
  if not (String.equal expected actual)
  then failwith (Printf.sprintf "expected %S, got %S" expected actual)
;;

let crypto ?(private_result = Ok "private-key") ?(on_private = fun () -> ()) () =
  E2ee.
    { decrypt_private_key =
        (fun _ _ _ _ _ ->
          on_private ();
          private_result)
    ; decrypt_graph_key = (fun _ _ -> Ok "remote-graph-key")
    ; encrypt_graph_key = (fun _ _ -> Error "unused")
    ; random_bytes = (fun _ -> Error "unused")
    ; encrypt_aes_gcm =
        (fun _ _ -> Ok ("iv", "ciphertext"))
    ; decrypt_aes_gcm =
        (fun _ _ _ ->
          Ok (Codec.to_string (Transit.String "decrypted title")))
    }
;;

let config =
  Api.
    { base_url = "https://api.example"
    ; graph_id = "encrypted-graph"
    ; graph_name = Some "Private"
    ; token = "access-token"
    }
;;

let private_package =
  Codec.to_string
    (Transit.Array
       [ Transit.String "20251210"
       ; Transit.Binary "salt"
       ; Transit.Binary "private-iv"
       ; Transit.Binary "encrypted-private"
       ])
;;

let graph_package = Codec.to_string (Transit.Binary "encrypted-graph-key")

let test_unlock_fetches_and_saves_graph_key () =
  let requests = ref [] in
  let saved = ref [] in
  let saved_passwords = ref [] in
  let keyring =
    Keyring.logseq_chat_e2ee_keyring_create
      (crypto ())
      (fun _ -> Ok None)
      (fun graph_id key ->
        saved := (graph_id, key) :: !saved;
        Ok ())
      (fun () -> Ok None)
      (fun password ->
        saved_passwords := password :: !saved_passwords;
        Ok ())
      (fun request ->
        requests := request.Api.url :: !requests;
        if String.ends_with ~suffix:"/user-keys" request.url
        then
          Ok
            Api.
              { status = 200
              ; body =
                  Yojson.Basic.to_string
                    (`Assoc
                      [ "public-key", `String "public"
                      ; "encrypted-private-key", `String private_package
                      ])
              }
        else
          Ok
            Api.
              { status = 200
              ; body =
                  Yojson.Basic.to_string
                    (`Assoc [ "encrypted-aes-key", `String graph_package ])
              })
  in
  let key = Keyring.logseq_chat_e2ee_keyring_unlock keyring config "e2etest" |> expect_ok in
  expect_equal "remote-graph-key" key;
  (match !saved with
   | [ "encrypted-graph", "remote-graph-key" ] -> ()
   | _ -> failwith "unlocked graph key was not securely persisted");
  (match !saved_passwords with
   | [ "e2etest" ] -> ()
   | _ -> failwith "unlock must persist the single account E2EE password");
  if List.length !requests <> 2 then failwith "unlock must fetch both E2EE key packages"
;;

let test_account_password_unlocks_an_uncached_graph () =
  let password_load_count = ref 0 in
  let password_save_count = ref 0 in
  let keyring =
    Keyring.logseq_chat_e2ee_keyring_create
      (crypto ())
      (fun _ -> Ok None)
      (fun _ _ -> Ok ())
      (fun () ->
        incr password_load_count;
        Ok (Some "e2etest"))
      (fun _ ->
        incr password_save_count;
        Ok ())
      (fun request ->
        if String.ends_with ~suffix:"/user-keys" request.Api.url
        then
          Ok
            Api.
              { status = 200
              ; body =
                  Yojson.Basic.to_string
                    (`Assoc
                      [ "public-key", `String "public"
                      ; "encrypted-private-key", `String private_package
                      ])
              }
        else
          Ok
            Api.
              { status = 200
              ; body =
                  Yojson.Basic.to_string
                    (`Assoc [ "encrypted-aes-key", `String graph_package ])
              })
  in
  expect_equal "remote-graph-key" (Keyring.logseq_chat_e2ee_keyring_load_cached keyring config |> expect_ok);
  if !password_load_count <> 1 then failwith "uncached graph must load the account password once";
  if !password_save_count <> 0 then failwith "automatic unlock must not rewrite the account password"
;;

let test_account_private_key_is_decrypted_once_for_multiple_graphs () =
  let private_decrypt_count = ref 0 in
  let keyring =
    Keyring.logseq_chat_e2ee_keyring_create
      (crypto ~on_private:(fun () -> incr private_decrypt_count) ())
      (fun _ -> Ok None)
      (fun _ _ -> Ok ())
      (fun () -> Ok (Some "e2etest"))
      (fun _ -> Ok ())
      (fun request ->
        if String.ends_with ~suffix:"/user-keys" request.Api.url
        then
          Ok
            Api.
              { status = 200
              ; body =
                  Yojson.Basic.to_string
                    (`Assoc
                      [ "public-key", `String "public"
                      ; "encrypted-private-key", `String private_package
                      ])
              }
        else
          Ok
            Api.
              { status = 200
              ; body =
                  Yojson.Basic.to_string
                    (`Assoc [ "encrypted-aes-key", `String graph_package ])
              })
  in
  ignore (Keyring.logseq_chat_e2ee_keyring_load_cached keyring config |> expect_ok);
  let second_config = Api.{ config with graph_id = "second-encrypted-graph" } in
  ignore (Keyring.logseq_chat_e2ee_keyring_load_cached keyring second_config |> expect_ok);
  if !private_decrypt_count <> 1
  then failwith "the account private key must only be decrypted once per process"
;;

let test_cached_key_opens_offline () =
  let fetch_count = ref 0 in
  let keyring =
    Keyring.logseq_chat_e2ee_keyring_create
      (crypto ())
      (fun graph_id ->
        if String.equal graph_id "encrypted-graph" then Ok (Some "cached-key") else Ok None)
      (fun _ _ -> Ok ())
      (fun () -> Ok None)
      (fun _ -> Ok ())
      (fun _ ->
        incr fetch_count;
        Error "offline")
  in
  expect_equal
    "cached-key"
    (Keyring.logseq_chat_e2ee_keyring_load_cached keyring config |> expect_ok);
  if !fetch_count <> 0 then failwith "offline cached-key restore must not fetch"
;;

let test_wrong_password_does_not_save_key () =
  let save_count = ref 0 in
  let password_save_count = ref 0 in
  let keyring =
    Keyring.logseq_chat_e2ee_keyring_create
      (crypto ~private_result:(Error "wrong password") ())
      (fun _ -> Ok None)
      (fun _ _ ->
        incr save_count;
        Ok ())
      (fun () -> Ok None)
      (fun _ ->
        incr password_save_count;
        Ok ())
      (fun request ->
        if String.ends_with ~suffix:"/user-keys" request.Api.url
        then
          Ok
            Api.
              { status = 200
              ; body =
                  Yojson.Basic.to_string
                    (`Assoc
                      [ "public-key", `String "public"
                      ; "encrypted-private-key", `String private_package
                      ])
              }
        else
          Ok Api.{ status = 200; body = Yojson.Basic.to_string (`Assoc [ "encrypted-aes-key", `String graph_package ]) })
  in
  (match Keyring.logseq_chat_e2ee_keyring_unlock keyring config "wrong" with
   | Error _ -> ()
   | Ok _ -> failwith "wrong E2EE password must fail closed");
  if !save_count <> 0 then failwith "failed unlock must not persist a graph key"
  else if !password_save_count <> 0 then failwith "failed unlock must not persist the account password"
;;

let test_title_codec_uses_loaded_graph_key () =
  let keyring =
    Keyring.logseq_chat_e2ee_keyring_create
      (crypto ())
      (fun _ -> Ok (Some "cached-key"))
      (fun _ _ -> Ok ())
      (fun () -> Ok None)
      (fun _ -> Ok ())
      (fun _ -> Error "unused")
  in
  ignore (Keyring.logseq_chat_e2ee_keyring_load_cached keyring config |> expect_ok);
  let encrypted =
    Keyring.logseq_chat_e2ee_keyring_encrypt_title keyring "encrypted-graph" "plain title" |> expect_ok
  in
  (match Codec.of_string encrypted with
   | Transit.Array [ Transit.Binary "iv"; Transit.Binary "ciphertext" ] -> ()
   | _ -> failwith "title encryption does not match Logseq Transit");
  expect_equal
    "decrypted title"
    (Keyring.logseq_chat_e2ee_keyring_decrypt_title keyring "encrypted-graph" encrypted |> expect_ok)
;;

let test_asset_codec_encrypts_binary_transit () =
  let encrypted_plaintext = ref None in
  let asset_crypto =
    E2ee.
      { decrypt_private_key = (fun _ _ _ _ _ -> Error "unused")
      ; decrypt_graph_key = (fun _ _ -> Error "unused")
      ; encrypt_graph_key = (fun _ _ -> Error "unused")
      ; random_bytes = (fun _ -> Error "unused")
      ; encrypt_aes_gcm =
          (fun key plaintext ->
            expect_equal "cached-key" key;
            encrypted_plaintext := Some plaintext;
            Ok ("asset-iv", "asset-ciphertext"))
      ; decrypt_aes_gcm = (fun _ _ _ -> Error "unused")
      }
  in
  let keyring =
    Keyring.logseq_chat_e2ee_keyring_create
      asset_crypto
      (fun _ -> Ok (Some "cached-key"))
      (fun _ _ -> Ok ())
      (fun () -> Ok None)
      (fun _ -> Ok ())
      (fun _ -> Error "unused")
  in
  ignore (Keyring.logseq_chat_e2ee_keyring_load_cached keyring config |> expect_ok);
  let encrypted =
    Keyring.logseq_chat_e2ee_keyring_encrypt_asset keyring "encrypted-graph" "raw-image-bytes" |> expect_ok
  in
  (match Option.map Codec.of_string !encrypted_plaintext with
   | Some (Transit.Binary "raw-image-bytes") -> ()
   | _ -> failwith "asset plaintext must be Transit binary");
  (match Codec.of_string encrypted with
   | Transit.Array [ Transit.Binary "asset-iv"; Transit.Binary "asset-ciphertext" ] -> ()
   | _ -> failwith "asset encryption does not match Logseq Transit")
;;

let test_provision_graph_key_uploads_and_caches_key () =
  let requests = ref [] in
  let saved = ref None in
  let crypto =
    E2ee.
      { decrypt_private_key = (fun _ _ _ _ _ -> Error "unused")
      ; decrypt_graph_key = (fun _ _ -> Error "unused")
      ; encrypt_graph_key = (fun public_key plaintext -> Ok (public_key ^ plaintext))
      ; random_bytes = (fun count -> Ok (String.make count 'a'))
      ; encrypt_aes_gcm = (fun _ _ -> Error "unused")
      ; decrypt_aes_gcm = (fun _ _ _ -> Error "unused")
      }
  in
  let public_key = Codec.to_string (Transit.Binary "public") in
  let keyring =
    Keyring.logseq_chat_e2ee_keyring_create
      crypto
      (fun _ -> Ok None)
      (fun _ key -> saved := Some key; Ok ())
      (fun () -> Ok None)
      (fun _ -> Ok ())
      (fun request ->
        requests := request :: !requests;
        if String.ends_with ~suffix:"/user-keys" request.Api.url
        then
          Ok
            Api.
              { status = 200
              ; body =
                  Yojson.Basic.to_string
                    (`Assoc
                      [ "public-key", `String public_key
                      ; "encrypted-private-key", `String "unused"
                      ])
              }
        else Ok Api.{ status = 200; body = "{}" })
  in
  let provision_config =
    Api.
      { base_url = "https://api.example"
      ; graph_id = "new-graph"
      ; graph_name = None
      ; token = "token"
      }
  in
  let key = Keyring.logseq_chat_e2ee_keyring_provision keyring provision_config |> expect_ok in
  expect_equal (String.make 32 'a') key;
  (match !saved with
   | Some value -> expect_equal key value
   | None -> failwith "graph key was not cached");
  let post = List.find (fun request -> String.equal request.Api.method_ "POST") !requests in
  (match post.body with
   | Some body ->
     let encrypted = Api.logseq_chat_api_graph_key_from_body body in
     (match Codec.of_string encrypted with
      | Transit.Binary value -> expect_equal ("public" ^ key) value
      | _ -> failwith "uploaded graph key envelope is invalid")
   | None -> failwith "graph key upload body is missing")
;;

let test_unlock_failures_do_not_cache_keys () =
  List.iter (fun failure ->
    let writes = ref [] in
    let fetch (request : Api.api_request) =
      let user = String.ends_with ~suffix:"/user-keys" request.Api.url in
      if failure = "network" then Error "offline"
      else if failure = "http" then Ok Api.{status = 403; body = "denied"}
      else if failure = "json" then Ok Api.{status = 200; body = "{"}
      else Ok Api.{status = 200; body = Yojson.Basic.to_string (`Assoc
        (if user then ["public-key", `String "public";
                       "encrypted-private-key", `String private_package]
         else ["encrypted-aes-key", `String graph_package]))}
    in
    let keyring = Keyring.logseq_chat_e2ee_keyring_create (crypto ())
      (fun _ -> Ok None)
      (fun _ _ ->
        writes := !writes @ ["key"];
        if failure = "save-key" then Error "key storage failed" else Ok ())
      (fun () -> Ok None)
      (fun _ ->
        writes := !writes @ ["password"];
        if failure = "save-password" then Error "password storage failed" else Ok ())
      fetch in
    (match Keyring.logseq_chat_e2ee_keyring_unlock keyring config "password" with
     | Error message when String.length message > 0 -> ()
     | _ -> failwith ("unlock accepted " ^ failure));
    (match Keyring.logseq_chat_e2ee_keyring_graph_key keyring config.graph_id with
     | Error "encrypted graph is locked" -> ()
     | _ -> failwith ("failed unlock cached a key: " ^ failure));
    (match Keyring.logseq_chat_e2ee_keyring_load_cached keyring config with
     | Error "E2EE password is not cached" -> ()
     | _ -> failwith ("failed unlock cached the account private key: " ^ failure));
    let expected = match failure with
      | "save-password" -> ["password"]
      | "save-key" -> ["password"; "key"]
      | _ -> [] in
    if !writes <> expected then failwith ("incorrect persistence order: " ^ failure))
    ["network"; "http"; "json"; "save-password"; "save-key"]
;;

let test_cache_and_locked_operations () =
  let loads = ref 0 in
  let keyring = Keyring.logseq_chat_e2ee_keyring_create (crypto ())
    (fun graph_id ->
      incr loads;
      if graph_id = config.graph_id then Ok (Some "cached-key") else Error "storage unavailable")
    (fun _ _ -> failwith "unexpected save")
    (fun () -> failwith "unexpected password load")
    (fun _ -> failwith "unexpected password save")
    (fun _ -> failwith "unexpected network request") in
  List.iter (fun result -> match result with
    | Error "encrypted graph is locked" -> ()
    | _ -> failwith "locked operation must fail")
    [Keyring.logseq_chat_e2ee_keyring_encrypt_title keyring "locked" "text";
     Keyring.logseq_chat_e2ee_keyring_encrypt_asset keyring "locked" "bytes";
     Keyring.logseq_chat_e2ee_keyring_decrypt_title keyring "locked" "ciphertext"];
  expect_equal "cached-key" (Keyring.logseq_chat_e2ee_keyring_load_cached keyring config |> expect_ok);
  expect_equal "cached-key" (Keyring.logseq_chat_e2ee_keyring_load_cached keyring config |> expect_ok);
  if !loads <> 1 then failwith "memory cache must avoid repeated secure-storage reads";
  (match Keyring.logseq_chat_e2ee_keyring_load_cached keyring Api.{config with graph_id = "other"} with
   | Error "storage unavailable" -> ()
   | _ -> failwith "secure-storage failure must be propagated")
;;

let test_provision_rejected_upload_does_not_save () =
  let public_key = Codec.to_string (Transit.Binary "public") in
  let keyring = Keyring.logseq_chat_e2ee_keyring_create
    E2ee.{(crypto ()) with
      random_bytes = (fun count -> Ok (String.make count 'a'));
      encrypt_graph_key = (fun _ _ -> Ok "wrapped")}
    (fun _ -> Ok None)
    (fun _ _ -> failwith "rejected upload must not be saved")
    (fun () -> Ok None)
    (fun _ -> failwith "provision must not save a password")
    (fun request ->
      if request.Api.method_ = "POST" then Ok Api.{status = 503; body = "unavailable"}
      else Ok Api.{status = 200; body = Yojson.Basic.to_string (`Assoc
        ["public-key", `String public_key; "encrypted-private-key", `String "unused"])}) in
  (match Keyring.logseq_chat_e2ee_keyring_provision keyring config with
   | Error "upload graph E2EE key returned HTTP 503" -> ()
   | _ -> failwith "provision must report the rejected upload");
  (match Keyring.logseq_chat_e2ee_keyring_graph_key keyring config.graph_id with
   | Error "encrypted graph is locked" -> ()
   | _ -> failwith "rejected upload must not unlock the graph")
;;

let () =
  test_unlock_fetches_and_saves_graph_key ();
  test_account_password_unlocks_an_uncached_graph ();
  test_account_private_key_is_decrypted_once_for_multiple_graphs ();
  test_cached_key_opens_offline ();
  test_wrong_password_does_not_save_key ();
  test_title_codec_uses_loaded_graph_key ();
  test_asset_codec_encrypts_binary_transit ();
  test_provision_graph_key_uploads_and_caches_key ();
  test_unlock_failures_do_not_cache_keys ();
  test_cache_and_locked_operations ();
  test_provision_rejected_upload_does_not_save ()
;;
