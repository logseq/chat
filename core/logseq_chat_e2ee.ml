module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json

type crypto =
  { decrypt_private_key :
      password:string
      -> iterations:int
      -> salt:string
      -> iv:string
      -> ciphertext:string
      -> (string, string) result
  ; decrypt_graph_key :
      private_key:string -> ciphertext:string -> (string, string) result
  ; encrypt_graph_key :
      public_key:string -> plaintext:string -> (string, string) result
  ; random_bytes : int -> (string, string) result
  ; encrypt_aes_gcm :
      key:string -> plaintext:string -> (string * string, string) result
  ; decrypt_aes_gcm :
      key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

type private_key_package =
  { iterations : int
  ; salt : string
  ; iv : string
  ; ciphertext : string
  }

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let protect operation f =
  try Ok (f ()) with
  | Transit.Decode_error message -> Error (operation ^ ": " ^ message)
  | Failure message -> Error (operation ^ ": " ^ message)
  | Invalid_argument message -> Error (operation ^ ": " ^ message)
  | error -> Error (operation ^ ": " ^ Printexc.to_string error)
;;

let private_key_package source =
  bind (protect "decode encrypted private key" (fun () -> Codec.of_string source)) (function
    | Transit.Array
        [ Transit.String version
        ; Transit.Binary salt
        ; Transit.Binary iv
        ; Transit.Binary ciphertext
        ] ->
      let iterations =
        if String.compare version "20251210" >= 0 then 600_000 else 100_000
      in
      Ok { iterations; salt; iv; ciphertext }
    | Transit.Array
        [ Transit.Binary salt; Transit.Binary iv; Transit.Binary ciphertext ] ->
      Ok { iterations = 100_000; salt; iv; ciphertext }
    | _ -> Error "encrypted private key has an invalid Transit envelope")
;;

let binary source =
  bind (protect "decode encrypted graph key" (fun () -> Codec.of_string source)) (function
    | Transit.Binary value -> Ok value
    | _ -> Error "encrypted graph key is not Transit binary")
;;

let prepare_graph_key ~crypto ~public_key_package =
  bind (binary public_key_package) (fun public_key ->
    bind (crypto.random_bytes 32) (fun graph_key ->
      bind (crypto.encrypt_graph_key ~public_key ~plaintext:graph_key) (fun encrypted ->
        Ok (graph_key, Codec.to_string (Transit.Binary encrypted)))))
;;

let decrypt_private_key ~crypto ~password ~private_key_package:private_source =
  bind (private_key_package private_source) (fun package ->
    crypto.decrypt_private_key
      ~password
      ~iterations:package.iterations
      ~salt:package.salt
      ~iv:package.iv
      ~ciphertext:package.ciphertext)
;;

let decrypt_graph_key ~crypto ~private_key ~encrypted_graph_key =
  bind (binary encrypted_graph_key) (fun ciphertext ->
    crypto.decrypt_graph_key ~private_key ~ciphertext)
;;

let unlock_graph_key ~crypto ~password ~private_key_package ~encrypted_graph_key =
  bind (decrypt_private_key ~crypto ~password ~private_key_package) (fun private_key ->
    decrypt_graph_key ~crypto ~private_key ~encrypted_graph_key)
;;

let encrypt_value ~crypto ~graph_key value =
  let plaintext = Codec.to_string value in
  bind (crypto.encrypt_aes_gcm ~key:graph_key ~plaintext) (fun (iv, ciphertext) ->
    Ok (Codec.to_string (Transit.Array [ Transit.Binary iv; Transit.Binary ciphertext ])))
;;

let decrypt_value ~crypto ~graph_key source =
  let decoded =
    try Some (Codec.of_string source) with
    | _ -> None
  in
  match decoded with
  | None -> Ok (Transit.String source)
  | Some (Transit.Array [ Transit.Binary iv; Transit.Binary ciphertext ]) ->
    bind (crypto.decrypt_aes_gcm ~key:graph_key ~iv ~ciphertext) (fun plaintext ->
      protect "decode decrypted value" (fun () -> Codec.of_string plaintext))
  | Some (Transit.Array (_ :: _ :: _)) ->
    Error "encrypted value has an invalid Transit AES-GCM envelope"
  | Some (Transit.String value) ->
    (try Ok (Codec.of_string value) with
     | _ -> Ok (Transit.String value))
  | Some value -> Ok value
;;

let decrypt_string ~crypto ~graph_key source =
  bind (decrypt_value ~crypto ~graph_key source) (function
    | Transit.String value -> Ok value
    | _ -> Error "decrypted protected value is not a string")
;;
