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
  ; mutable search_index_is_fresh : bool
  }

let refresh_search runtime =
  Option.iter
    (fun index ->
      try
        Logseq_chat_search_index.refresh index runtime.snapshot.Projection.db;
        runtime.search_index_is_fresh <- true
      with
      | Failure _ -> runtime.search_index_is_fresh <- false)
    runtime.search_index
;;

let persist_projected_conflicts ~path operations statuses =
  let persisted = Hashtbl.create (List.length operations) in
  List.iter
    (fun operation ->
      Hashtbl.replace persisted operation.Ops.operation_id operation.Ops.state)
    operations;
  List.iter
    (function
      | operation_id, Ops.Conflicted message ->
        (match Hashtbl.find_opt persisted operation_id with
         | Some (Ops.Queued | Ops.Retryable | Ops.Submitted) ->
           Ops.set_state ~path ~operation_id (Ops.Conflicted message)
         | Some (Ops.Accepted _ | Ops.Applied | Ops.Conflicted _) | None -> ())
      | _, (Ops.Queued | Ops.Submitted | Ops.Accepted _ | Ops.Retryable | Ops.Applied) -> ())
    statuses
;;

let rebuild runtime =
  let operations = Ops.list ~path:runtime.path in
  let snapshot =
    Projection.build
      ~server_t:runtime.server_t
      (Datascript.conn_db runtime.conn)
      operations
  in
  persist_projected_conflicts
    ~path:runtime.path
    operations
    snapshot.statuses;
  runtime.snapshot <- snapshot;
  refresh_search runtime
;;

let create_base
      ?(encrypt_title = fun value -> Ok value)
      ?search_index_path
      ~path
      ~server_t
      conn
  =
  let operations = Ops.list ~path in
  let snapshot =
    Projection.build ~server_t (Datascript.conn_db conn) operations
  in
  persist_projected_conflicts ~path operations snapshot.statuses;
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
    ; journal_limit = 1
    ; search_index
    ; search_index_is_fresh = false
    }
  in
  runtime
;;

let fresh_uuid () =
  match Datascript.squuid () with
  | Datascript.Uuid uuid -> uuid
  | _ -> failwith "Datascript.squuid returned a non-UUID value"
;;

let journal_day_title journal_day =
  let month_names =
    [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"
     ; "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec"
    |]
  in
  let year = journal_day / 10_000 in
  let month = (journal_day / 100) mod 100 in
  let day = journal_day mod 100 in
  let suffix =
    if day mod 100 >= 11 && day mod 100 <= 13
    then "th"
    else
      match day mod 10 with
      | 1 -> "st"
      | 2 -> "nd"
      | 3 -> "rd"
      | _ -> "th"
  in
  Printf.sprintf "%s %d%s, %04d" month_names.(month - 1) day suffix year
;;

let db runtime = runtime.snapshot.db
let operation_statuses runtime = runtime.snapshot.statuses

let pending_operations runtime =
  let projected_states = Hashtbl.create (List.length runtime.snapshot.statuses) in
  List.iter
    (fun (operation_id, state) -> Hashtbl.replace projected_states operation_id state)
    runtime.snapshot.statuses;
  Ops.list ~path:runtime.path
  |> List.filter (fun operation ->
    match operation.Ops.state with
    | Ops.Queued | Ops.Retryable | Ops.Submitted ->
      (match Hashtbl.find_opt projected_states operation.operation_id with
       | Some (Ops.Conflicted _) -> false
       | Some _ | None -> true)
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
    | (Ops.Set_property _ | Ops.Move_block _ | Ops.Move_blocks _ | Ops.Delete_blocks _
      | Ops.Create_tag _ | Ops.Create_journal _ | Ops.Add_tag _) as intent -> Ok intent
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
  let requested_operation = operation in
  let existing = Ops.list ~path:runtime.path in
  let replacing =
    List.find_opt
      (fun pending ->
        String.equal pending.Ops.operation_id requested_operation.Ops.operation_id)
      existing
  in
  let operation =
    match Hashtbl.find_opt runtime.prepared operation.Ops.operation_id with
    | Some normalized -> { normalized with state = operation.state }
    | None -> operation
  in
  let transport_state = function
    | Ops.Submitted | Ops.Accepted _ | Ops.Retryable -> true
    | Ops.Queued | Ops.Applied | Ops.Conflicted _ -> false
  in
  let state_only_update =
    match replacing with
    | Some existing ->
      existing.base_t = requested_operation.base_t
      && existing.intent = requested_operation.intent
      && transport_state operation.state
      && (match existing.state with Ops.Conflicted _ -> false | _ -> true)
    | None -> false
  in
  if state_only_update
  then (
    Ops.save ~path:runtime.path operation;
    Ok ())
  else if Option.is_none replacing
  then
    if operation.base_t <> runtime.server_t
    then Error "operation was created against a stale server cursor"
    else
      (match Projection.compile runtime.snapshot.db operation.intent with
       | Error message -> Error message
       | Ok tx ->
         Ops.save ~path:runtime.path operation;
         runtime.snapshot <-
           { runtime.snapshot with
             db = Datascript.db_with tx runtime.snapshot.db
           ; statuses =
               runtime.snapshot.statuses
               @ [ operation.operation_id, Ops.Applied ]
           };
         refresh_search runtime;
         Ok ())
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

let ensure_today_journal runtime =
  let created_at = int_of_float (Unix.gettimeofday () *. 1000.0) in
  let journal_day = Logseq_chat_model.journal_day_for_ms created_at in
  match Logseq_chat_graph_read.journal_page_uuid runtime.snapshot.db ~journal_day with
  | Some _ -> Ok ()
  | None ->
    let operation =
      Ops.
        { operation_id = fresh_uuid ()
        ; base_t = runtime.server_t
        ; state = Queued
        ; intent =
            Create_journal
              { page_uuid =
                  Printf.sprintf
                    "00000001-%04d-%04d-0000-000000000000"
                    (journal_day / 10_000)
                    (journal_day mod 10_000)
              ; block_uuid = fresh_uuid ()
              ; title = journal_day_title journal_day
              ; journal_day
              ; created_at
              }
        }
    in
    stage runtime operation
;;

let create
      ?(encrypt_title = fun value -> Ok value)
      ?search_index_path
      ?(auto_create_today = false)
      ~path
      ~server_t
      conn
  =
  let runtime = create_base ~encrypt_title ?search_index_path ~path ~server_t conn in
  if auto_create_today
  then (
    match ensure_today_journal runtime with
    | Ok () -> ()
    | Error message -> failwith ("create today's journal: " ^ message));
  runtime
;;

let safe_to_rebase = function
  | Ops.Save_title _ | Ops.Set_property _ | Ops.Split_block _ | Ops.Merge_backward _
  | Ops.Create_tag _ | Ops.Create_journal _ | Ops.Add_tag _ | Ops.Insert_block _
  | Ops.Move_block _ | Ops.Move_blocks _ -> true
  | Ops.Delete_blocks _ -> false
;;

let rebase runtime ~server_t ~operation_ids =
  let confirmed = Hashtbl.create (List.length operation_ids) in
  List.iter (fun operation_id -> Hashtbl.replace confirmed operation_id ()) operation_ids;
  List.iter (Hashtbl.remove runtime.prepared) operation_ids;
  let authoritative = Datascript.conn_db runtime.conn in
  Ops.list ~path:runtime.path
  |> List.iter (fun operation ->
    match operation.Ops.state with
    | _ when
        Hashtbl.mem confirmed operation.operation_id
        && Projection.satisfied authoritative operation.intent ->
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
       | Error message ->
         Ops.save
           ~path:runtime.path
           { operation with state = Ops.Conflicted message })
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

let node_is_property runtime uuid =
  Logseq_chat_graph_read.node_is_property runtime.snapshot.db uuid
;;

let references_for_node runtime uuid =
  Logseq_chat_graph_read.references_for_node
    runtime.snapshot.db
    uuid
;;

let journal_page_uuid runtime ~journal_day =
  Logseq_chat_graph_read.journal_page_uuid runtime.snapshot.db ~journal_day
;;

let normalize_titles runtime ~uuid titles =
  Logseq_chat_graph_read.normalize_titles_creating_tags
    runtime.snapshot.db
    ~fresh_uuid
    ~uuid
    titles
;;

let search runtime query =
  match runtime.search_index with
  | None -> []
  | Some index ->
    if not runtime.search_index_is_fresh then refresh_search runtime;
    (try Logseq_chat_search_index.search_hits index runtime.snapshot.db query with
     | Failure _ -> [])
;;
