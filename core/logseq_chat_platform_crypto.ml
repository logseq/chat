open Yojson.Basic

module E2ee = Logseq_chat_e2ee

external call_raw : string -> string = "logseq_chat_crypto_call"

let hex value =
  let buffer = Buffer.create (String.length value * 2) in
  String.iter (fun ch -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code ch))) value;
  Buffer.contents buffer
;;

let unhex value =
  if String.length value mod 2 <> 0
  then Error "platform crypto returned invalid hex"
  else
    try
      let result = Bytes.create (String.length value / 2) in
      for index = 0 to Bytes.length result - 1 do
        Bytes.set result index (Char.chr (int_of_string ("0x" ^ String.sub value (index * 2) 2)))
      done;
      Ok (Bytes.unsafe_to_string result)
    with _ -> Error "platform crypto returned invalid hex"
;;

let invoke operation fields =
  try
    match call_raw (to_string (`Assoc (("operation", `String operation) :: fields))) |> from_string with
    | `Assoc fields ->
      (match List.assoc_opt "ok" fields with
       | Some (`Bool true) -> Ok fields
       | _ ->
         (match List.assoc_opt "error" fields with
          | Some (`String message) -> Error message
          | _ -> Error "platform crypto failed"))
    | _ -> Error "platform crypto returned invalid JSON"
  with
  | error -> Error (Printexc.to_string error)
;;

let binary_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> unhex value
  | _ -> Error ("platform crypto response is missing " ^ name)
;;

let bind result f = match result with Ok value -> f value | Error _ as error -> error

let crypto : Logseq_chat_e2ee.crypto =
  E2ee.
    { decrypt_private_key =
        (fun ~password ~iterations ~salt ~iv ~ciphertext ->
          bind
            (invoke
               "decryptPrivateKey"
               [ "password", `String password
               ; "iterations", `Int iterations
               ; "salt", `String (hex salt)
               ; "iv", `String (hex iv)
               ; "ciphertext", `String (hex ciphertext)
               ])
            (binary_field "value"))
    ; decrypt_graph_key =
        (fun ~private_key ~ciphertext ->
          bind
            (invoke
               "decryptGraphKey"
               [ "privateKey", `String (hex private_key)
               ; "ciphertext", `String (hex ciphertext)
               ])
            (binary_field "value"))
    ; encrypt_graph_key =
        (fun ~public_key ~plaintext ->
          bind
            (invoke
               "encryptGraphKey"
               [ "publicKey", `String (hex public_key)
               ; "plaintext", `String (hex plaintext)
               ])
            (binary_field "value"))
    ; random_bytes =
        (fun count ->
          bind (invoke "randomBytes" [ "count", `Int count ]) (binary_field "value"))
    ; encrypt_aes_gcm =
        (fun ~key ~plaintext ->
          bind
            (invoke
               "encryptAES"
               [ "key", `String (hex key); "plaintext", `String (hex plaintext) ])
            (fun fields ->
              bind (binary_field "iv" fields) (fun iv ->
                bind (binary_field "ciphertext" fields) (fun ciphertext ->
                  Ok (iv, ciphertext)))))
    ; decrypt_aes_gcm =
        (fun ~key ~iv ~ciphertext ->
          bind
            (invoke
               "decryptAES"
               [ "key", `String (hex key)
               ; "iv", `String (hex iv)
               ; "ciphertext", `String (hex ciphertext)
               ])
            (binary_field "value"))
    }
;;

let save_graph_key ~graph_id ~key =
  bind
    (invoke "saveGraphKey" [ "graphID", `String graph_id; "key", `String (hex key) ])
    (fun _ -> Ok ())
;;

let load_graph_key ~graph_id =
  bind (invoke "loadGraphKey" [ "graphID", `String graph_id ]) (fun fields ->
    match List.assoc_opt "value" fields with
    | Some (`String value) -> Result.map Option.some (unhex value)
    | Some `Null | None -> Ok None
    | Some _ -> Error "platform crypto returned invalid cached graph key")
;;

let save_e2ee_password ~password =
  bind
    (invoke "saveE2EEPassword" [ "password", `String (hex password) ])
    (fun _ -> Ok ())
;;

let load_e2ee_password () =
  bind (invoke "loadE2EEPassword" []) (fun fields ->
    match List.assoc_opt "value" fields with
    | Some (`String value) -> Result.map Option.some (unhex value)
    | Some `Null | None -> Ok None
    | Some _ -> Error "platform crypto returned invalid cached E2EE password")
;;
