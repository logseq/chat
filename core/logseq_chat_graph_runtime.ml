module Ops = Logseq_chat_pending_ops
module Projection = Logseq_chat_pending_projection

let ( >>= ) = Result.bind
let ( >>| ) result f = Result.map f result

type t =
  { path : string
  ; conn : Datascript.conn
  ; encrypt_title : string -> (string, string) result
  ; mutable server_t : int
  ; mutable snapshot : Projection.snapshot
  ; prepared : (string, Ops.t) Hashtbl.t
  ; mutable journal_limit : int
  ; search_index : Logseq_chat_search_index.t option
  }

let refresh_search runtime =
  Option.iter
    (fun index ->
      try Logseq_chat_search_index.refresh index runtime.snapshot.Projection.db with
      | Failure _ -> ())
    runtime.search_index
;;

let rebuild runtime =
  runtime.snapshot <-
    Projection.build
      ~server_t:runtime.server_t
      (Datascript.conn_db runtime.conn)
      (Ops.list ~path:runtime.path);
  refresh_search runtime
;;

let create
      ?(encrypt_title = fun value -> Ok value)
      ?search_index_path
      ~path
      ~server_t
      conn
  =
  let snapshot =
    Projection.build ~server_t (Datascript.conn_db conn) (Ops.list ~path)
  in
  let search_index =
    Option.bind search_index_path (fun path ->
      try Some (Logseq_chat_search_index.create ~path) with
      | Failure _ -> None)
  in
  let runtime =
    { path
    ; conn
    ; encrypt_title
    ; server_t
    ; snapshot
    ; prepared = Hashtbl.create 16
    ; journal_limit = 7
    ; search_index
    }
  in
  refresh_search runtime;
  runtime
;;

let db runtime = runtime.snapshot.db
let operation_statuses runtime = runtime.snapshot.statuses

let pending_operations runtime =
  Ops.list ~path:runtime.path
  |> List.filter (fun operation ->
    match operation.Ops.state with
    | Ops.Queued | Ops.Retryable | Ops.Submitted -> true
    | Ops.Accepted _ | Ops.Applied | Ops.Conflicted _ -> false)
;;

let raw_title db uuid =
  match Datascript.entity db (Datascript.Lookup_ref ("block/uuid", Datascript.Uuid uuid)) with
  | Some entity ->
    (match Datascript.Entity.entity_attr_raw entity "block/title" with
     | Some (Datascript.One_value (Datascript.String value)) -> Ok value
     | _ -> Error "block title is missing")
  | None -> Error "block no longer exists"
;;

let normalize_expected_title _runtime db ~uuid ~expected =
  raw_title db uuid
  >>= fun current ->
  if String.equal current expected then Ok current else Error "title changed on the server"
;;

let normalize_operation runtime operation =
  let db = Datascript.conn_db runtime.conn in
  let intent =
    match operation.Ops.intent with
    | Ops.Save_title { uuid; expected_title; title } ->
      normalize_expected_title runtime db ~uuid ~expected:expected_title
      >>= fun expected_title ->
      Ok (Ops.Save_title { uuid; expected_title; title })
    | Ops.Insert_block { uuid; title; page_uuid; parent_uuid; order; created_at } ->
      Ok (Ops.Insert_block { uuid; title; page_uuid; parent_uuid; order; created_at })
    | Ops.Split_block
        { uuid; expected_title; before; after; new_uuid; new_order; created_at }
      ->
      normalize_expected_title runtime db ~uuid ~expected:expected_title
      >>= fun expected_title ->
      Ok (Ops.Split_block
        { uuid; expected_title; before; after; new_uuid; new_order; created_at }
      )
    | Ops.Merge_backward
        { uuid; expected_title; title; previous_uuid; expected_previous_title; _ }
      ->
      let source_title = title in
      normalize_expected_title runtime db ~uuid ~expected:expected_title
      >>= fun expected_title ->
      normalize_expected_title runtime db ~uuid:previous_uuid ~expected:expected_previous_title
      >>= fun expected_previous_title ->
      Ok (Ops.Merge_backward
        { uuid
        ; expected_title
        ; title = source_title
        ; previous_uuid
        ; expected_previous_title
        ; merged_title = Some (expected_previous_title ^ source_title)
        }
      )
    | (Ops.Set_property _ | Ops.Move_block _ | Ops.Move_blocks _ | Ops.Delete_blocks _) as intent ->
      Ok intent
  in
  intent >>| fun intent -> { operation with Ops.intent }
;;

let prepare_sync runtime operation =
  if operation.Ops.base_t <> runtime.server_t
  then Error "operation was created against a stale server cursor"
  else
    normalize_operation runtime operation
    >>= fun normalized ->
    Projection.compile (Datascript.conn_db runtime.conn) normalized.intent
    >>= fun tx ->
    Logseq_chat_sync_tx.encode
      ~encrypt_protected:runtime.encrypt_title
      (Datascript.conn_db runtime.conn)
      tx
    >>| fun wire ->
    Hashtbl.replace runtime.prepared operation.operation_id normalized;
    Ops.outliner_op normalized.intent, wire
;;

let stage runtime operation =
  let operation =
    match Hashtbl.find_opt runtime.prepared operation.Ops.operation_id with
    | Some normalized -> { normalized with state = operation.state }
    | None -> operation
  in
  let existing = Ops.list ~path:runtime.path in
  let replacing =
    List.exists
      (fun pending -> String.equal pending.Ops.operation_id operation.Ops.operation_id)
      existing
  in
  if not replacing && operation.base_t <> runtime.server_t
  then Error "operation was created against a stale server cursor"
  else
    let candidate_ops =
      List.filter
        (fun pending -> not (String.equal pending.Ops.operation_id operation.operation_id))
        existing
      @ [ operation ]
    in
    let candidate =
      Projection.build
        ~server_t:runtime.server_t
        (Datascript.conn_db runtime.conn)
        candidate_ops
    in
    (match List.assoc operation.operation_id candidate.statuses with
     | Ops.Applied ->
       Ops.save ~path:runtime.path operation;
       runtime.snapshot <- candidate;
       refresh_search runtime;
       Ok ()
     | Ops.Conflicted message -> Error message
     | Ops.Queued | Ops.Retryable | Ops.Submitted | Ops.Accepted _ ->
       (Error "operation could not be projected" [@coverage off]))
;;

let safe_to_rebase = function
  | Ops.Save_title _ | Ops.Set_property _ | Ops.Split_block _ | Ops.Merge_backward _ -> true
  | Ops.Insert_block _ | Ops.Move_block _ | Ops.Move_blocks _ | Ops.Delete_blocks _ -> false
;;

let rebase runtime ~server_t ~operation_ids =
  Ops.confirm ~path:runtime.path ~operation_ids;
  List.iter (Hashtbl.remove runtime.prepared) operation_ids;
  let authoritative = Datascript.conn_db runtime.conn in
  Ops.list ~path:runtime.path
  |> List.iter (fun operation ->
    match operation.Ops.state with
    | Ops.Accepted accepted_t when accepted_t <= server_t ->
      Ops.remove ~path:runtime.path ~operation_id:operation.operation_id
    | (Ops.Submitted | Ops.Accepted _) when Projection.satisfied authoritative operation.intent ->
      Ops.remove ~path:runtime.path ~operation_id:operation.operation_id
    | _ -> ());
  runtime.server_t <- server_t;
  let projected = ref authoritative in
  Ops.list ~path:runtime.path
  |> List.iter (fun (operation : Ops.t) ->
    match operation.state with
    | Ops.Conflicted _ -> ()
    | Ops.Accepted _ | Ops.Applied ->
      (match Projection.compile !projected operation.intent with
       | Ok tx -> projected := Datascript.db_with tx !projected
       | Error _ -> ())
    | Ops.Queued | Ops.Retryable | Ops.Submitted ->
      Hashtbl.remove runtime.prepared operation.operation_id;
      (match
         if operation.base_t <> server_t && not (safe_to_rebase operation.intent)
         then Error "the server changed while the structural operation was pending"
         else Projection.compile !projected operation.intent
       with
       | Error message ->
         Ops.save
           ~path:runtime.path
           { operation with base_t = server_t; state = Ops.Conflicted message }
       | Ok tx ->
         projected := Datascript.db_with tx !projected;
         if operation.base_t <> server_t
         then
           Ops.save
             ~path:runtime.path
             { operation with base_t = server_t; state = Ops.Queued }));
  rebuild runtime
;;

let blocks runtime =
  Logseq_chat_graph_read.blocks
    ~journal_limit:runtime.journal_limit
    runtime.snapshot.db
;;

let has_older_journals runtime =
  runtime.journal_limit < Logseq_chat_graph_read.journal_page_count runtime.snapshot.db
;;

let load_older_journals runtime =
  runtime.journal_limit <- runtime.journal_limit + 7
;;

let blocks_for_page runtime page_uuid =
  Logseq_chat_graph_read.blocks_for_page
    runtime.snapshot.db
    page_uuid
;;

let sidebar_pages runtime =
  Logseq_chat_graph_read.sidebar_pages
    runtime.snapshot.db
;;

let node_destination runtime uuid =
  Logseq_chat_graph_read.node_destination
    runtime.snapshot.db
    uuid
;;

let objects_for_tag runtime uuid =
  Logseq_chat_graph_read.objects_for_tag
    runtime.snapshot.db
    uuid
;;

let tag_pages runtime =
  Logseq_chat_graph_read.tag_pages runtime.snapshot.db
;;

let node_is_tag runtime uuid =
  Logseq_chat_graph_read.node_is_tag runtime.snapshot.db uuid
;;

let references_for_node runtime uuid =
  Logseq_chat_graph_read.references_for_node
    runtime.snapshot.db
    uuid
;;

let journal_page_uuid runtime ~journal_day =
  Logseq_chat_graph_read.journal_page_uuid runtime.snapshot.db ~journal_day
;;

let normalize_title runtime ~uuid title =
  Logseq_chat_graph_read.normalize_title_text runtime.snapshot.db ~uuid title
;;

let search runtime query =
  match runtime.search_index with
  | None -> []
  | Some index ->
    (try Logseq_chat_search_index.search_hits index runtime.snapshot.db query with
     | Failure _ -> [])
;;
