open Datascript
module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

let page_uuid db =
  let page = Datascript.datoms db Avet ~a:"block/name" () |> Seq.uncons in
  match page with
  | None -> Error "graph has no page for a new block"
  | Some (page_name, _rest) ->
    let uuid =
      Datascript.datoms db Eavt ~e:page_name.e ~a:"block/uuid" () |> Seq.uncons
    in
    (match uuid with
     | Some ({ v = Uuid uuid; _ }, _rest) -> Ok uuid
     | _ -> Error "graph page has no UUID identity")
;;

let insert_block_tx db ~uuid ~title ~now =
  match page_uuid db with
  | Error _ as error -> error
  | Ok page_uuid ->
    let page_identity =
      Value.Array [ Value.Keyword "block/uuid"; Value.Uuid page_uuid ]
    in
    let order = Printf.sprintf "a%d-%s" now uuid in
    Codec.to_string
      ~mode:Verbose
      (Value.Array
         [ Value.Map
             [ Value.Keyword "db/id", Value.Int (-1)
             ; Value.Keyword "block/uuid", Value.Uuid uuid
             ; Value.Keyword "block/title", Value.String title
             ; Value.Keyword "block/parent", page_identity
             ; Value.Keyword "block/page", page_identity
             ; Value.Keyword "block/order", Value.String order
             ; Value.Keyword "block/created-at", Value.Date (Int64.of_int now)
             ; Value.Keyword "block/updated-at", Value.Date (Int64.of_int now)
             ]
         ])
    |> Result.ok
;;

let save_block_tx ~uuid ~title ~status_ident =
  let identity = Value.Array [ Value.Keyword "block/uuid"; Value.Uuid uuid ] in
  let title_op =
    Value.Array
      [ Value.Keyword "db/add"
      ; identity
      ; Value.Keyword "block/title"
      ; Value.String title
      ]
  in
  let status_ops =
    match status_ident with
    | None -> []
    | Some ident ->
      [ Value.Array
          [ Value.Keyword "db/add"
          ; identity
          ; Value.Keyword "logseq.property/status"
          ; Value.Array [ Value.Keyword "db/ident"; Value.Keyword ident ]
          ]
      ]
  in
  Codec.to_string ~mode:Verbose (Value.Array (title_op :: status_ops))
;;
