module Graph_read = Logseq_chat_graph_read
module Model = Logseq_chat_model
module Protocol = Logseq_chat_lg_core_native

module Ds_value = struct
  let optional_ref_eid = Logseq_chat_lg_graph_support_native.logseq_chat_datascript_value_optional_ref_eid
end

type t =
  { decrypt_title : string -> (string, string) result
  ; mutable recent_pages : Graph_read.Int_set.t
  ; blocks_by_uuid : (string, Model.block) Hashtbl.t
  }

let recent_pages db =
  Graph_read.recent_journal_page_ids db
  |> List.fold_left (fun pages eid -> Graph_read.Int_set.add eid pages) Graph_read.Int_set.empty
;;

let rebuild projection db =
  projection.recent_pages <- recent_pages db;
  Hashtbl.clear projection.blocks_by_uuid;
  Graph_read.blocks ~decrypt_title:projection.decrypt_title db
  |> List.iter (fun (block : Model.block) ->
    Hashtbl.replace projection.blocks_by_uuid block.uuid block)
;;

let create ?(decrypt_title = fun value -> Ok value) db =
  let projection =
    { decrypt_title
    ; recent_pages = Graph_read.Int_set.empty
    ; blocks_by_uuid = Hashtbl.create 128
    }
  in
  rebuild projection db;
  projection
;;

let blocks projection =
  Hashtbl.to_seq_values projection.blocks_by_uuid
  |> List.of_seq
  |> List.sort Graph_read.compare_journal_blocks
;;

let identity = function
  | Transit_core.Json.Array
      [ Transit_core.Json.Keyword "block/uuid"; Transit_core.Json.Uuid uuid ] ->
    Some (`Uuid uuid)
  | Transit_core.Json.Array
      [ Transit_core.Json.Keyword "db/ident"; Transit_core.Json.Keyword ident ] ->
    Some (`Ident ident)
  | _ -> None
;;

let refresh_block projection db uuid =
  match Datascript.entid db "block/uuid" (Datascript.Uuid uuid) with
  | None -> Hashtbl.remove projection.blocks_by_uuid uuid
  | Some eid ->
    let page_is_recent =
      match
        Ds_value.optional_ref_eid
          db
          "block/page"
          (Graph_read.value db eid "block/page")
      with
      | Some page_eid -> Graph_read.Int_set.mem page_eid projection.recent_pages
      | None -> false
    in
    if page_is_recent
    then
      (match Graph_read.block projection.decrypt_title db eid with
       | Some block -> Hashtbl.replace projection.blocks_by_uuid uuid block
       | None -> Hashtbl.remove projection.blocks_by_uuid uuid)
    else Hashtbl.remove projection.blocks_by_uuid uuid
;;

let update projection db (change : Protocol.sync_change_set) =
  let changed_uuids, changed_idents =
    List.fold_left
      (fun (uuids, idents) (entity : Protocol.sync_entity) ->
        match identity entity.id with
        | Some (`Uuid uuid) -> Graph_read.String_set.add uuid uuids, idents
        | Some (`Ident ident) -> uuids, Graph_read.String_set.add ident idents
        | None -> uuids, idents)
      (Graph_read.String_set.empty, Graph_read.String_set.empty)
      change.upserts
  in
  let changed_uuids, changed_idents =
    List.fold_left
      (fun (uuids, idents) identity_value ->
        match identity identity_value with
        | Some (`Uuid uuid) -> Graph_read.String_set.add uuid uuids, idents
        | Some (`Ident ident) -> uuids, Graph_read.String_set.add ident idents
        | None -> uuids, idents)
      (changed_uuids, changed_idents)
      change.deleted
  in
  if not (Graph_read.Int_set.equal projection.recent_pages (recent_pages db))
  then rebuild projection db
  else (
    let affected = ref changed_uuids in
    Hashtbl.iter
      (fun uuid (block : Model.block) ->
        let related_entity_changed =
          List.exists
            (fun (summary : Model.entity_summary) ->
              Graph_read.String_set.mem summary.uuid changed_uuids)
            (block.tags @ block.references)
        in
        let status_changed =
          match block.status with
          | None -> false
          | Some status ->
            Graph_read.String_set.mem status.uuid changed_uuids
            || Option.fold
                 ~none:false
                 ~some:(fun ident -> Graph_read.String_set.mem ident changed_idents)
                 status.ident
        in
        if Graph_read.String_set.mem block.page_id changed_uuids
           || related_entity_changed
           || status_changed
        then affected := Graph_read.String_set.add uuid !affected)
      projection.blocks_by_uuid;
    Graph_read.String_set.iter (refresh_block projection db) !affected)
;;
