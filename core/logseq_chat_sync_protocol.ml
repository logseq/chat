module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

type entity =
  { id : Value.value
  ; attrs : (Value.value * Value.value) list
  }

type change_set =
  { format_version : int
  ; graph_id : string
  ; schema_version : string
  ; t_before : int
  ; t : int
  ; upserts : entity list
  ; deleted : Value.value list
  ; operation_ids : string list
  }

type reset =
  { reason : string
  ; snapshot_required : bool
  }

type event =
  | Graph_changes of change_set
  | Reset of reset

let changed_block_uuids change =
  let seen = Hashtbl.create (List.length change.upserts + List.length change.deleted) in
  let collect identity =
    match identity with
    | Value.Array [ Value.Keyword "block/uuid"; Value.Uuid uuid ] ->
      Hashtbl.replace seen uuid ()
    | _ -> ()
  in
  List.iter (fun (entity : entity) -> collect entity.id) change.upserts;
  List.iter collect change.deleted;
  Hashtbl.to_seq_keys seen |> List.of_seq
;;

let map_value key fields = List.assoc_opt (Value.Keyword key) fields

let required key decode fields =
  match map_value key fields with
  | Some value -> decode value
  | None -> Error ("missing Transit field: " ^ key)
;;

let as_int = function
  | Value.Int value -> Ok value
  | Value.Int64 value when value <= Int64.of_int max_int && value >= Int64.of_int min_int ->
    Ok (Int64.to_int value)
  | _ -> Error "expected Transit integer"
;;

let as_string = function
  | Value.String value -> Ok value
  | _ -> Error "expected Transit string"
;;

let as_bool = function
  | Value.Bool value -> Ok value
  | _ -> Error "expected Transit boolean"
;;

let as_array = function
  | Value.Array values -> Ok values
  | _ -> Error "expected Transit array"
;;

let as_map = function
  | Value.Map fields -> Ok fields
  | _ -> Error "expected Transit map"
;;

let as_identity = function
  | Value.Array [ Value.Keyword "block/uuid"; Value.Uuid _ ] as identity -> Ok identity
  | Value.Array [ Value.Keyword "db/ident"; Value.Keyword _ ] as identity -> Ok identity
  | Value.Array [ Value.Keyword "file/path"; Value.String _ ] as identity -> Ok identity
  | _ -> Error "expected stable Transit lookup identity"
;;

let as_attrs = function
  | Value.Map fields
    when List.for_all
           (fun (key, _value) ->
             match key with
             | Value.Keyword _ -> true
             | _ -> false)
           fields -> Ok fields
  | Value.Map _ -> Error "expected Transit keyword attribute keys"
  | _ -> Error "expected Transit attribute map"
;;

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let decode_entity value =
  bind (as_map value) (fun fields ->
    bind (required "id" as_identity fields) (fun id ->
      bind (required "attrs" as_attrs fields) (fun attrs -> Ok { id; attrs })))
;;

let decode_list decode values =
  let rec loop decoded = function
    | [] -> Ok (List.rev decoded)
    | value :: rest -> bind (decode value) (fun item -> loop (item :: decoded) rest)
  in
  loop [] values
;;

let optional_list key decode fields =
  match map_value key fields with
  | None -> Ok []
  | Some value -> bind (as_array value) (decode_list decode)
;;

let decode_change_value value =
  bind (as_map value) (fun fields ->
    bind (required "format-version" as_int fields) (fun format_version ->
      bind (required "graph-id" as_string fields) (fun graph_id ->
        bind (required "schema-version" as_string fields) (fun schema_version ->
          bind (required "t-before" as_int fields) (fun t_before ->
            bind (required "t" as_int fields) (fun t ->
              bind (required "upserts" as_array fields) (fun upsert_values ->
                bind (decode_list decode_entity upsert_values) (fun upserts ->
                  bind (required "deleted" as_array fields) (fun deleted_values ->
                    bind (decode_list as_identity deleted_values) (fun deleted ->
                      bind (optional_list "operation-ids" as_string fields) (fun operation_ids ->
                        Ok
                          { format_version
                          ; graph_id
                          ; schema_version
                          ; t_before
                          ; t
                          ; upserts
                          ; deleted
                          ; operation_ids
                          })))))))))))
;;

let protect decode wire =
  try decode (Codec.of_string wire) with
  | Value.Decode_error message -> Error message
  | Failure message -> Error message
  | Invalid_argument message -> Error message
;;

let decode_change_set wire = protect decode_change_value wire

let decode_reset_value value =
  bind (as_map value) (fun fields ->
    bind (required "reason" as_string fields) (fun reason ->
      bind (required "snapshot-required" as_bool fields) (fun snapshot_required ->
        Ok { reason; snapshot_required })))
;;

let decode_event ~event_name wire =
  match event_name with
  | "graph-changes" ->
    bind (decode_change_set wire) (fun change -> Ok (Graph_changes change))
  | "reset" -> protect decode_reset_value wire |> Result.map (fun reset -> Reset reset)
  | name -> Error ("unsupported SSE event: " ^ name)
;;
