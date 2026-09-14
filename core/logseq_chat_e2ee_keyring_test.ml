module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json
module E2ee = Logseq_chat_lg_core_native
module Keyring = Logseq_chat_e2ee_keyring
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
    Keyring.create
      ~crypto:(crypto ())
      ~load:(fun ~graph_id:_ -> Ok None)
      ~save:(fun ~graph_id ~key ->
        saved := (graph_id, key) :: !saved;
        Ok ())
      ~load_password:(fun () -> Ok None)
      ~save_password:(fun ~password ->
        saved_passwords := password :: !saved_passwords;
        Ok ())
      ~fetch:(fun request ->
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
  let key = Keyring.unlock keyring config ~password:"e2etest" |> expect_ok in
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
    Keyring.create
      ~crypto:(crypto ())
      ~load:(fun ~graph_id:_ -> Ok None)
      ~save:(fun ~graph_id:_ ~key:_ -> Ok ())
      ~load_password:(fun () ->
        incr password_load_count;
        Ok (Some "e2etest"))
      ~save_password:(fun ~password:_ ->
        incr password_save_count;
        Ok ())
      ~fetch:(fun request ->
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
  expect_equal "remote-graph-key" (Keyring.load_cached keyring config |> expect_ok);
  if !password_load_count <> 1 then failwith "uncached graph must load the account password once";
  if !password_save_count <> 0 then failwith "automatic unlock must not rewrite the account password"
;;

let test_account_private_key_is_decrypted_once_for_multiple_graphs () =
  let private_decrypt_count = ref 0 in
  let keyring =
    Keyring.create
      ~crypto:(crypto ~on_private:(fun () -> incr private_decrypt_count) ())
      ~load:(fun ~graph_id:_ -> Ok None)
      ~save:(fun ~graph_id:_ ~key:_ -> Ok ())
      ~load_password:(fun () -> Ok (Some "e2etest"))
      ~save_password:(fun ~password:_ -> Ok ())
      ~fetch:(fun request ->
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
  ignore (Keyring.load_cached keyring config |> expect_ok);
  let second_config = Api.{ config with graph_id = "second-encrypted-graph" } in
  ignore (Keyring.load_cached keyring second_config |> expect_ok);
  if !private_decrypt_count <> 1
  then failwith "the account private key must only be decrypted once per process"
;;

let test_cached_key_opens_offline () =
  let fetch_count = ref 0 in
  let keyring =
    Keyring.create
      ~crypto:(crypto ())
      ~load:(fun ~graph_id ->
        if String.equal graph_id "encrypted-graph" then Ok (Some "cached-key") else Ok None)
      ~save:(fun ~graph_id:_ ~key:_ -> Ok ())
      ~load_password:(fun () -> Ok None)
      ~save_password:(fun ~password:_ -> Ok ())
      ~fetch:(fun _ ->
        incr fetch_count;
        Error "offline")
  in
  expect_equal
    "cached-key"
    (Keyring.load_cached keyring config |> expect_ok);
  if !fetch_count <> 0 then failwith "offline cached-key restore must not fetch"
;;

let test_wrong_password_does_not_save_key () =
  let save_count = ref 0 in
  let password_save_count = ref 0 in
  let keyring =
    Keyring.create
      ~crypto:(crypto ~private_result:(Error "wrong password") ())
      ~load:(fun ~graph_id:_ -> Ok None)
      ~save:(fun ~graph_id:_ ~key:_ ->
        incr save_count;
        Ok ())
      ~load_password:(fun () -> Ok None)
      ~save_password:(fun ~password:_ ->
        incr password_save_count;
        Ok ())
      ~fetch:(fun request ->
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
  (match Keyring.unlock keyring config ~password:"wrong" with
   | Error _ -> ()
   | Ok _ -> failwith "wrong E2EE password must fail closed");
  if !save_count <> 0 then failwith "failed unlock must not persist a graph key"
  else if !password_save_count <> 0 then failwith "failed unlock must not persist the account password"
;;

let test_title_codec_uses_loaded_graph_key () =
  let keyring =
    Keyring.create
      ~crypto:(crypto ())
      ~load:(fun ~graph_id:_ -> Ok (Some "cached-key"))
      ~save:(fun ~graph_id:_ ~key:_ -> Ok ())
      ~load_password:(fun () -> Ok None)
      ~save_password:(fun ~password:_ -> Ok ())
      ~fetch:(fun _ -> Error "unused")
  in
  ignore (Keyring.load_cached keyring config |> expect_ok);
  let encrypted =
    Keyring.encrypt_title keyring ~graph_id:"encrypted-graph" "plain title" |> expect_ok
  in
  (match Codec.of_string encrypted with
   | Transit.Array [ Transit.Binary "iv"; Transit.Binary "ciphertext" ] -> ()
   | _ -> failwith "title encryption does not match Logseq Transit");
  expect_equal
    "decrypted title"
    (Keyring.decrypt_title keyring ~graph_id:"encrypted-graph" encrypted |> expect_ok)
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
    Keyring.create
      ~crypto:asset_crypto
      ~load:(fun ~graph_id:_ -> Ok (Some "cached-key"))
      ~save:(fun ~graph_id:_ ~key:_ -> Ok ())
      ~load_password:(fun () -> Ok None)
      ~save_password:(fun ~password:_ -> Ok ())
      ~fetch:(fun _ -> Error "unused")
  in
  ignore (Keyring.load_cached keyring config |> expect_ok);
  let encrypted =
    Keyring.encrypt_asset keyring ~graph_id:"encrypted-graph" "raw-image-bytes" |> expect_ok
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
    Keyring.create
      ~crypto
      ~load:(fun ~graph_id:_ -> Ok None)
      ~save:(fun ~graph_id:_ ~key -> saved := Some key; Ok ())
      ~load_password:(fun () -> Ok None)
      ~save_password:(fun ~password:_ -> Ok ())
      ~fetch:(fun request ->
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
  let key = Keyring.provision keyring provision_config |> expect_ok in
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

let () =
  test_unlock_fetches_and_saves_graph_key ();
  test_account_password_unlocks_an_uncached_graph ();
  test_account_private_key_is_decrypted_once_for_multiple_graphs ();
  test_cached_key_opens_offline ();
  test_wrong_password_does_not_save_key ();
  test_title_codec_uses_loaded_graph_key ();
  test_asset_codec_encrypts_binary_transit ();
  test_provision_graph_key_uploads_and_caches_key ()
;;
