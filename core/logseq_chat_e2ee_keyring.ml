module Api = Logseq_chat_api
module E2ee = Logseq_chat_e2ee
module Transit = Transit_core.Json

type t =
  { crypto : E2ee.crypto
  ; load : graph_id:string -> (string option, string) result
  ; save : graph_id:string -> key:string -> (unit, string) result
  ; fetch : Api.request -> (Api.response, string) result
  ; keys : (string, string) Hashtbl.t
  }

let create ~crypto ~load ~save ~fetch =
  { crypto; load; save; fetch; keys = Hashtbl.create 4 }
;;

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let response_body operation = function
  | Error message -> Error message
  | Ok response when response.Api.status >= 200 && response.status < 300 -> Ok response.body
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

let load_cached t ~graph_id =
  match Hashtbl.find_opt t.keys graph_id with
  | Some key -> Ok key
  | None ->
    bind (t.load ~graph_id) (function
      | Some key -> Ok (remember t ~graph_id key)
      | None -> Error "encrypted graph key is not cached")
;;

let unlock t config ~password =
  bind
    (response_body "fetch user E2EE keys" (t.fetch (Api.user_keys_request config)))
    (fun user_keys_body ->
      bind
        (protect "decode user E2EE keys" (fun () -> Api.user_keys_from_body user_keys_body))
        (fun user_keys ->
          bind
            (response_body "fetch graph E2EE key" (t.fetch (Api.graph_key_request config)))
            (fun graph_key_body ->
              bind
                (protect "decode graph E2EE key" (fun () -> Api.graph_key_from_body graph_key_body))
                (fun encrypted_graph_key ->
                  bind
                    (E2ee.unlock_graph_key
                       ~crypto:t.crypto
                       ~password
                       ~private_key_package:user_keys.Api.encrypted_private_key
                       ~encrypted_graph_key)
                    (fun key ->
                      bind (t.save ~graph_id:config.Api.graph_id ~key) (fun () ->
                        Ok (remember t ~graph_id:config.graph_id key)))))))
;;

let provision t config =
  bind
    (response_body "fetch user E2EE keys" (t.fetch (Api.user_keys_request config)))
    (fun user_keys_body ->
      bind
        (protect "decode user E2EE keys" (fun () -> Api.user_keys_from_body user_keys_body))
        (fun user_keys ->
          bind
            (E2ee.prepare_graph_key
               ~crypto:t.crypto
               ~public_key_package:user_keys.Api.public_key)
            (fun (key, encrypted_key) ->
              bind
                (response_body
                   "upload graph E2EE key"
                   (t.fetch (Api.upsert_graph_key_request config ~encrypted_key)))
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
    E2ee.encrypt_value ~crypto:t.crypto ~graph_key (Transit.String title))
;;

let encrypt_asset t ~graph_id bytes =
  bind (graph_key t ~graph_id) (fun graph_key ->
    E2ee.encrypt_value ~crypto:t.crypto ~graph_key (Transit.Binary bytes))
;;

let decrypt_title t ~graph_id ciphertext =
  bind (graph_key t ~graph_id) (fun graph_key ->
    E2ee.decrypt_string ~crypto:t.crypto ~graph_key ciphertext)
;;
