open Logseq_chat_lg_core_native

external call_raw : string -> string = "logseq_chat_crypto_call"

let response = ref "{\"ok\":true,\"value\":\"00ff\"}"
let requests = ref []
let transport_failure = ref false

let () =
  Callback.register "platform_crypto_test_call" (fun request ->
    if !transport_failure then failwith "native crypto unavailable";
    requests := Yojson.Basic.from_string request :: !requests;
    !response)

let expect expected actual =
  if expected <> actual then failwith "platform crypto protocol mismatch"

let field name =
  match List.hd !requests with
  | `Assoc fields -> List.assoc name fields
  | _ -> failwith "request must be an object"

let () =
  let bytes = String.init 256 Char.chr in
  expect "00ff107f80" (logseq_chat_platform_crypto_hex "\000\255\016\127\128");
  expect (Ok bytes) (logseq_chat_platform_crypto_unhex (logseq_chat_platform_crypto_hex bytes));
  expect (Ok "") (logseq_chat_platform_crypto_unhex "");
  expect (Ok "\171\205") (logseq_chat_platform_crypto_unhex "ABcd");
  List.iter (fun value ->
    expect (Error "platform crypto returned invalid hex") (logseq_chat_platform_crypto_unhex value))
    ["0"; "gg"; "ffffx"; "zz"];
  let crypto = logseq_chat_platform_crypto_crypto call_raw in
  expect (Ok "\000\255") (crypto.decrypt_private_key "secret" 600000 "\000" "\001" "\255");
  expect (`String "decryptPrivateKey") (field "operation");
  expect (`String "secret") (field "password");
  expect (`Int 600000) (field "iterations");
  expect (`String "00") (field "salt");
  expect (`String "01") (field "iv");
  expect (`String "ff") (field "ciphertext");
  expect (Ok "\000\255") (crypto.decrypt_graph_key "\000" "\255");
  expect (`String "decryptGraphKey") (field "operation");
  expect (`String "00") (field "privateKey");
  expect (Ok "\000\255") (crypto.encrypt_graph_key "\000" "\255");
  expect (`String "encryptGraphKey") (field "operation");
  expect (`String "00") (field "publicKey");
  expect (`String "ff") (field "plaintext");
  expect (Ok "\000\255") (crypto.random_bytes 2);
  expect (`String "randomBytes") (field "operation");
  expect (`Int 2) (field "count");
  response := "{\"ok\":true,\"iv\":\"0001\",\"ciphertext\":\"feff\"}";
  expect (Ok ("\000\001", "\254\255")) (crypto.encrypt_aes_gcm "\000" "\255");
  expect (`String "encryptAES") (field "operation");
  expect (`String "00") (field "key");
  response := "{\"ok\":true,\"value\":\"00ff\"}";
  expect (Ok "\000\255") (crypto.decrypt_aes_gcm "\000" "\001" "\255");
  expect (`String "decryptAES") (field "operation");
  expect (`String "01") (field "iv");
  expect (Ok ()) (logseq_chat_platform_crypto_save_graph_key call_raw "graph" bytes);
  expect (`String "saveGraphKey") (field "operation");
  expect (`String "graph") (field "graphID");
  expect (`String (logseq_chat_platform_crypto_hex bytes)) (field "key");
  expect (Ok (Some "\000\255")) (logseq_chat_platform_crypto_load_graph_key call_raw "graph");
  expect (`String "loadGraphKey") (field "operation");
  expect (Ok ()) (logseq_chat_platform_crypto_save_e2ee_password call_raw "\000secret\255");
  expect (`String "saveE2EEPassword") (field "operation");
  expect (`String "00736563726574ff") (field "password");
  expect (Ok (Some "\000\255")) (logseq_chat_platform_crypto_load_e2ee_password call_raw);
  expect (`String "loadE2EEPassword") (field "operation");
  List.iter (fun raw ->
    response := raw;
    expect (Ok None) (logseq_chat_platform_crypto_load_graph_key call_raw "graph");
    expect (Ok None) (logseq_chat_platform_crypto_load_e2ee_password call_raw))
    ["{\"ok\":true}"; "{\"ok\":true,\"value\":null}"];
  response := "{\"ok\":true,\"value\":42}";
  expect (Error "platform crypto returned invalid cached graph key")
    (logseq_chat_platform_crypto_load_graph_key call_raw "graph");
  expect (Error "platform crypto returned invalid cached E2EE password")
    (logseq_chat_platform_crypto_load_e2ee_password call_raw);
  List.iter (fun (raw, message) ->
    response := raw;
    expect (Error message) (crypto.random_bytes 2))
    ["{\"ok\":false,\"error\":\"locked\"}", "locked";
     "{\"ok\":false}", "platform crypto failed";
     "{\"ok\":true}", "platform crypto response is missing value";
     "{\"ok\":true,\"value\":\"xx\"}", "platform crypto returned invalid hex";
     "{\"ok\":true,\"value\":null}", "platform crypto response is missing value";
     "{\"ok\":false,\"ok\":true}", "platform crypto failed";
     "[]", "platform crypto returned invalid JSON"];
  response := "not JSON";
  (match crypto.random_bytes 2 with Error _ -> () | Ok _ -> failwith "invalid JSON accepted");
  response := "{\"ok\":true,\"iv\":\"zz\",\"ciphertext\":\"00\"}";
  expect (Error "platform crypto returned invalid hex") (crypto.encrypt_aes_gcm "" "");
  response := "{\"ok\":true,\"iv\":\"00\"}";
  expect (Error "platform crypto response is missing ciphertext") (crypto.encrypt_aes_gcm "" "");
  transport_failure := true;
  expect (Error "Failure(\"native crypto unavailable\")") (crypto.random_bytes 2)
