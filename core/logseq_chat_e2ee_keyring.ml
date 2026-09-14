module Api = Logseq_chat_lg_core_native
module E2ee = Logseq_chat_lg_core_native
module Transit = Transit_core.Json

type t =
  { crypto : E2ee.e2ee_crypto
  ; load : graph_id:string -> (string option, string) result
  ; save : graph_id:string -> key:string -> (unit, string) result
  ; load_password : unit -> (string option, string) result
  ; save_password : password:string -> (unit, string) result
  ; fetch : Api.api_request -> (Api.api_response, string) result
  ; keys : (string, string) Hashtbl.t
  ; mutable private_key : string option
  }

let create ~crypto ~load ~save ~load_password ~save_password ~fetch =
  { crypto
  ; load
  ; save
  ; load_password
  ; save_password
  ; fetch
  ; keys = Hashtbl.create 4
  ; private_key = None
  }
;;

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let response_body operation = function
  | Error message -> Error message
  | Ok (response : Api.api_response) when response.status >= 200 && response.status < 300 -> Ok response.body
  | Ok response -> Error (operation ^ " returned HTTP " ^ string_of_int response.status)
;;

let protect operation f =
  try Ok (f ()) with
  | Failure message -> Error (operation ^ ": " ^ message)
  | Yojson.Json_error message -> Error (operation ^ ": " ^ message)
  | error -> Error (operation ^ ": " ^ Printexc.to_string error)
;;

let remember t ~graph_id key =
  Hashtbl.replace t.keys graph_id key;
  key
;;

let fetch_graph_key t config =
  bind
    (response_body "fetch graph E2EE key" (t.fetch (Api.logseq_chat_api_graph_key_request config)))
    (fun body -> protect "decode graph E2EE key" (fun () -> Api.logseq_chat_api_graph_key_from_body body))
;;

let remember_graph_key t (config : Api.api_config) key =
  bind (t.save ~graph_id:config.Api.graph_id ~key) (fun () ->
    Ok (remember t ~graph_id:config.graph_id key))
;;

let unlock_with_private_key t config ~private_key =
  bind (fetch_graph_key t config) (fun encrypted_graph_key ->
    bind
      (E2ee.logseq_chat_e2ee_decrypt_graph_key t.crypto private_key encrypted_graph_key)
      (remember_graph_key t config))
;;

let unlock_with_password t config ~password ~persist_password =
  bind
    (response_body "fetch user E2EE keys" (t.fetch (Api.logseq_chat_api_user_keys_request config)))
    (fun user_keys_body ->
      bind
        (protect "decode user E2EE keys" (fun () -> Api.logseq_chat_api_user_keys_from_body user_keys_body))
        (fun user_keys ->
          bind
            (E2ee.logseq_chat_e2ee_decrypt_private_key
               t.crypto password user_keys.Api.encrypted_private_key)
            (fun private_key ->
              bind (fetch_graph_key t config) (fun encrypted_graph_key ->
                bind
                  (E2ee.logseq_chat_e2ee_decrypt_graph_key t.crypto private_key encrypted_graph_key)
                  (fun key ->
                    let save_password =
                      if persist_password then t.save_password ~password else Ok ()
                    in
                    bind save_password (fun () ->
                      bind (remember_graph_key t config key) (fun key ->
                        t.private_key <- Some private_key;
                        Ok key)))))))
;;

let load_cached t (config : Api.api_config) =
  let graph_id = config.Api.graph_id in
  match Hashtbl.find_opt t.keys graph_id with
  | Some key -> Ok key
  | None ->
    bind (t.load ~graph_id) (function
      | Some key -> Ok (remember t ~graph_id key)
      | None ->
        (match t.private_key with
         | Some private_key -> unlock_with_private_key t config ~private_key
         | None ->
           bind (t.load_password ()) (function
             | Some password -> unlock_with_password t config ~password ~persist_password:false
             | None -> Error "E2EE password is not cached")))
;;

let unlock t config ~password =
  unlock_with_password t config ~password ~persist_password:true
;;

let provision t config =
  bind
    (response_body "fetch user E2EE keys" (t.fetch (Api.logseq_chat_api_user_keys_request config)))
    (fun user_keys_body ->
      bind
        (protect "decode user E2EE keys" (fun () -> Api.logseq_chat_api_user_keys_from_body user_keys_body))
        (fun user_keys ->
          bind
            (E2ee.logseq_chat_e2ee_prepare_graph_key t.crypto user_keys.Api.public_key)
            (fun (key, encrypted_key) ->
              bind
                (response_body
                   "upload graph E2EE key"
                   (t.fetch (Api.logseq_chat_api_upsert_graph_key_request config encrypted_key)))
                (fun _ ->
                  bind (t.save ~graph_id:config.Api.graph_id ~key) (fun () ->
                    Ok (remember t ~graph_id:config.graph_id key))))))
;;

let graph_key t ~graph_id =
  match Hashtbl.find_opt t.keys graph_id with
  | Some key -> Ok key
  | None -> Error "encrypted graph is locked"
;;

let encrypt_title t ~graph_id title =
  bind (graph_key t ~graph_id) (fun graph_key ->
    E2ee.logseq_chat_e2ee_encrypt_value t.crypto graph_key (Transit.String title))
;;

let encrypt_asset t ~graph_id bytes =
  bind (graph_key t ~graph_id) (fun graph_key ->
    E2ee.logseq_chat_e2ee_encrypt_value t.crypto graph_key (Transit.Binary bytes))
;;

let decrypt_title t ~graph_id ciphertext =
  bind (graph_key t ~graph_id) (fun graph_key ->
    E2ee.logseq_chat_e2ee_decrypt_string t.crypto graph_key ciphertext)
;;
