module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json
module E2ee = Logseq_chat_e2ee
module Keyring = Logseq_chat_e2ee_keyring
module Api = Logseq_chat_api

let expect_ok = function
  | Ok value -> value
  | Error message -> failwith message
;;

let expect_equal expected actual =
  if not (String.equal expected actual)
  then failwith (Printf.sprintf "expected %S, got %S" expected actual)
;;

let crypto ?(private_result = Ok "private-key") () =
  E2ee.
    { decrypt_private_key = (fun ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext:_ -> private_result)
    ; decrypt_graph_key = (fun ~private_key:_ ~ciphertext:_ -> Ok "remote-graph-key")
    ; encrypt_aes_gcm =
        (fun ~key:_ ~plaintext:_ -> Ok ("iv", "ciphertext"))
    ; decrypt_aes_gcm =
        (fun ~key:_ ~iv:_ ~ciphertext:_ ->
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
  let keyring =
    Keyring.create
      ~crypto:(crypto ())
      ~load:(fun ~graph_id:_ -> Ok None)
      ~save:(fun ~graph_id ~key ->
        saved := (graph_id, key) :: !saved;
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
  if List.length !requests <> 2 then failwith "unlock must fetch both E2EE key packages"
;;

let test_cached_key_opens_offline () =
  let fetch_count = ref 0 in
  let keyring =
    Keyring.create
      ~crypto:(crypto ())
      ~load:(fun ~graph_id ->
        if String.equal graph_id "encrypted-graph" then Ok (Some "cached-key") else Ok None)
      ~save:(fun ~graph_id:_ ~key:_ -> Ok ())
      ~fetch:(fun _ ->
        incr fetch_count;
        Error "offline")
  in
  expect_equal
    "cached-key"
    (Keyring.load_cached keyring ~graph_id:"encrypted-graph" |> expect_ok);
  if !fetch_count <> 0 then failwith "offline cached-key restore must not fetch"
;;

let test_wrong_password_does_not_save_key () =
  let save_count = ref 0 in
  let keyring =
    Keyring.create
      ~crypto:(crypto ~private_result:(Error "wrong password") ())
      ~load:(fun ~graph_id:_ -> Ok None)
      ~save:(fun ~graph_id:_ ~key:_ ->
        incr save_count;
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
;;

let test_title_codec_uses_loaded_graph_key () =
  let keyring =
    Keyring.create
      ~crypto:(crypto ())
      ~load:(fun ~graph_id:_ -> Ok (Some "cached-key"))
      ~save:(fun ~graph_id:_ ~key:_ -> Ok ())
      ~fetch:(fun _ -> Error "unused")
  in
  ignore (Keyring.load_cached keyring ~graph_id:"encrypted-graph" |> expect_ok);
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
      { decrypt_private_key = (fun ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext:_ -> Error "unused")
      ; decrypt_graph_key = (fun ~private_key:_ ~ciphertext:_ -> Error "unused")
      ; encrypt_aes_gcm =
          (fun ~key ~plaintext ->
            expect_equal "cached-key" key;
            encrypted_plaintext := Some plaintext;
            Ok ("asset-iv", "asset-ciphertext"))
      ; decrypt_aes_gcm = (fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "unused")
      }
  in
  let keyring =
    Keyring.create
      ~crypto:asset_crypto
      ~load:(fun ~graph_id:_ -> Ok (Some "cached-key"))
      ~save:(fun ~graph_id:_ ~key:_ -> Ok ())
      ~fetch:(fun _ -> Error "unused")
  in
  ignore (Keyring.load_cached keyring ~graph_id:"encrypted-graph" |> expect_ok);
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

let () =
  test_unlock_fetches_and_saves_graph_key ();
  test_cached_key_opens_offline ();
  test_wrong_password_does_not_save_key ();
  test_title_codec_uses_loaded_graph_key ();
  test_asset_codec_encrypts_binary_transit ()
;;
