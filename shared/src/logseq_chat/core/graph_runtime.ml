module Ops = Pending_ops
module Projection = Pending_projection
module Read = Graph_read
module Index = Search_index
module Model = Cache_model
module Cards = Flashcards
module Order = Fractional_order
module Journal = Journal
module Ds = Datascript

type runtime_options =
  { encrypt_title : string -> (string, string) result
  ; search_index_path : string option
  ; auto_create_today : bool
  }

type read_caches =
  { blocks : (int, Model.block list) Hashtbl.t
  ; page_blocks : (string, Model.block list) Hashtbl.t
  ; node_blocks : (string, Model.block list) Hashtbl.t
  ; node_destinations :
      (string, (Model.entity_summary * bool) option) Hashtbl.t
  ; node_kind : (string, bool * bool) Hashtbl.t
  ; journal_page_uuids : (int, string option) Hashtbl.t
  ; tag_pages : Model.entity_summary list option ref
  ; journal_page_count : int option ref
  }

type runtime_state =
  { server_t : int
  ; snapshot : Projection.pending_projection_snapshot
  ; sidebar_cache : (Ds.db * Read.sidebar_pages) option
  ; read_cache : (Ds.db * read_caches) option
  ; prepared : (string, Ops.pending_operation) Hashtbl.t
  ; journal_limit : int
  ; search_index_is_fresh : bool
  }

type graph_runtime =
  { path : string
  ; conn : Ds.conn
  ; encrypt_title : string -> (string, string) result
  ; search_index : Index.search_index option
  ; state : runtime_state ref
  }

let default_options =
  {
    encrypt_title = (fun value -> Ok value);
    search_index_path = None;
    auto_create_today = false;
  }

let state runtime = !(runtime.state)
let db runtime = (state runtime).snapshot.db

let new_read_caches () =
  {
    blocks = Hashtbl.create 16;
    page_blocks = Hashtbl.create 64;
    node_blocks = Hashtbl.create 64;
    node_destinations = Hashtbl.create 64;
    node_kind = Hashtbl.create 64;
    journal_page_uuids = Hashtbl.create 64;
    tag_pages = ref None;
    journal_page_count = ref None;
  }

let caches_for_db runtime database =
  match (state runtime).read_cache with
  | Some (cached, caches) when cached == database -> caches
  | _ ->
    let caches = new_read_caches () in
    runtime.state :=
      { !(runtime.state) with read_cache = Some (database, caches) };
    caches

let operation_statuses runtime = (state runtime).snapshot.statuses

let trace_stage metric started stage =
  if Sys.getenv_opt "LOGSEQ_CHAT_TRACE_STARTUP" = Some "1" then
    prerr_endline
      (metric ^ " stage=" ^ stage
       ^ Printf.sprintf " elapsed_ms=%.3f"
           ((Unix.gettimeofday () -. started) *. 1000.0))

let search_error stage error =
  prerr_endline
    ("LOGSEQ_SEARCH_INDEX_ERROR stage=" ^ stage ^ " error="
     ^ Printexc.to_string error)

let refresh_search runtime =
  match runtime.search_index with
  | Some search_index ->
    (try
       Index.refresh search_index (db runtime);
       runtime.state :=
         { !(runtime.state) with search_index_is_fresh = true }
     with error ->
       search_error "refresh" error;
       runtime.state :=
         { !(runtime.state) with search_index_is_fresh = false })
  | None -> ()

let refresh_search_affected runtime before intent =
  if (state runtime).search_index_is_fresh then
    match runtime.search_index with
    | Some search_index ->
      (try
         Index.refresh_uuids search_index before (db runtime)
           (Ops.affected_uuids before intent)
       with Failure _ ->
         runtime.state :=
           { !(runtime.state) with search_index_is_fresh = false })
    | None -> ()

let refresh_search_after_rebase runtime before operations changed_uuids =
  if (state runtime).search_index_is_fresh then
    match runtime.search_index with
    | Some search_index ->
      let after = db runtime in
      let affected =
        changed_uuids
        @ List.concat_map
            (fun (operation : Ops.pending_operation) ->
              Ops.affected_uuids before operation.intent
              @ Ops.affected_uuids after operation.intent)
            operations
      in
      (try Index.refresh_uuids search_index before after affected
       with Failure _ ->
         runtime.state :=
           { !(runtime.state) with search_index_is_fresh = false })
    | None -> ()

let confirmed_operation confirmed server_t authoritative
    (operation : Ops.pending_operation) =
  (List.mem operation.operation_id confirmed
   && Projection.satisfied authoritative operation.intent)
  || ((match operation.state with
       | Ops.Submitted -> true
       | Ops.Accepted _ -> true
       | _ -> false)
      && Projection.satisfied authoritative operation.intent)
  || Ops.committed_despite_later_changes server_t authoritative
       operation

let rebase_operation runtime server_t projected operation =
  let persist_conflict (operation : Ops.pending_operation) message =
    Ops.save runtime.path { operation with Ops.state = Conflicted message };
    Ops.Conflicted message
  in
  let apply_tx tx =
    projected := Ds.db_with tx !projected;
    Ops.Applied
  in
  match operation.Ops.state with
  | Ops.Conflicted message -> Ops.Conflicted message
  | Ops.Accepted _ | Ops.Applied ->
    (match Projection.compile !projected operation.intent with
     | Ok tx -> apply_tx tx
     | Error message -> persist_conflict operation message)
  | _ ->
    Hashtbl.remove (state runtime).prepared operation.operation_id;
    (match
       if
         operation.base_t <> server_t
         && not (Ops.safe_to_rebase operation.intent)
       then
         Error
           "the server changed while the structural operation was pending"
       else Projection.compile !projected operation.intent
     with
     | Error message ->
       persist_conflict { operation with Ops.base_t = server_t } message
     | Ok tx ->
       ignore (apply_tx tx);
       if operation.base_t <> server_t then
         Ops.save runtime.path
           { operation with Ops.base_t = server_t; state = Queued };
       Ops.Applied)

let rebase runtime server_t operation_ids changed_uuids =
  let started = Unix.gettimeofday () in
  let before = db runtime in
  let authoritative = Ds.conn_db runtime.conn in
  List.iter
    (fun id -> Hashtbl.remove (state runtime).prepared id)
    operation_ids;
  let operations =
    List.filter
      (fun (operation : Ops.pending_operation) ->
        if
          confirmed_operation operation_ids server_t authoritative
            operation
        then begin
          Ops.remove runtime.path operation.operation_id;
          false
        end
        else true)
      (Ops.list runtime.path)
  in
  let projected = ref authoritative in
  trace_stage "LOGSEQ_REBASE_METRIC" started "confirmed";
  runtime.state := { !(runtime.state) with server_t };
  let statuses =
    List.map
      (fun (operation : Ops.pending_operation) ->
        ( operation.operation_id
        , rebase_operation runtime server_t projected operation ))
      operations
  in
  (* Publish the projection already built during reconciliation, without
     replaying it. *)
  runtime.state :=
    {
      !(runtime.state) with
      snapshot =
        {
          Projection.db = !projected;
          server_t;
          statuses;
        };
    };
  trace_stage "LOGSEQ_REBASE_METRIC" started "projected";
  refresh_search_after_rebase runtime before operations changed_uuids;
  trace_stage "LOGSEQ_REBASE_METRIC" started "complete"

let create_base path server_t conn options =
  let started = Unix.gettimeofday () in
  let search_index =
    match options.search_index_path with
    | Some path ->
      (try Some (Index.create path)
       with error ->
         search_error "open" error;
         None)
    | None -> None
  in
  let runtime =
    {
      path;
      conn;
      encrypt_title = options.encrypt_title;
      search_index;
      state =
        ref
          {
            server_t;
            snapshot =
              {
                Projection.db = Ds.conn_db conn;
                server_t;
                statuses = [];
              };
            sidebar_cache = None;
            read_cache = None;
            prepared = Hashtbl.create 64;
            journal_limit = 1;
            search_index_is_fresh = false;
          };
    }
  in
  trace_stage "LOGSEQ_RUNTIME_METRIC" started "search";
  rebase runtime server_t [] [];
  runtime

let fresh_uuid () =
  match Ds.squuid () with
  | Ds.Uuid uuid -> uuid
  | _ -> failwith "Datascript.squuid returned a non-UUID value"

let pending_operations runtime =
  let projected_states = operation_statuses runtime in
  List.filter
    (fun (operation : Ops.pending_operation) ->
      (match operation.state with
       | Ops.Queued -> true
       | Ops.Retryable -> true
       | Ops.Submitted -> true
       | _ -> false)
      &&
      match List.assoc_opt operation.operation_id projected_states with
      | Some (Ops.Conflicted _) -> false
      | _ -> true)
    (Ops.list runtime.path)

let db_before_operation runtime operation_id =
  let authoritative = Ds.conn_db runtime.conn in
  let operations = Ops.list runtime.path in
  let rec take_while acc ops =
    match ops with
    | (op : Ops.pending_operation) :: rest
      when op.operation_id <> operation_id ->
      take_while (op :: acc) rest
    | _ -> List.rev acc
  in
  let previous = take_while [] operations in
  if List.length previous = List.length operations then authoritative
  else
    (Projection.build (state runtime).server_t authoritative previous)
      .db

let prepare_sync runtime operation =
  let operation =
    match
      List.find_opt
        (fun (op : Ops.pending_operation) ->
          op.operation_id = operation.Ops.operation_id)
        (Ops.list runtime.path)
    with
    | Some op -> op
    | None -> operation
  in
  if operation.base_t <> (state runtime).server_t then
    Error "operation was created against a stale server cursor"
  else begin
    let before = db_before_operation runtime operation.operation_id in
    let ( let* ) = Result.bind in
    let* normalized = Ops.normalize_operation before operation in
    let* tx = Projection.compile before normalized.intent in
    let* wire =
      Sync_tx.encode runtime.encrypt_title before tx
    in
    Hashtbl.replace (state runtime).prepared operation.operation_id
      normalized;
    Ok (Ops.outliner_op normalized.intent, wire)
  end

let transport_state (value : Ops.pending_state) =
  match value with
  | Ops.Submitted -> true
  | Ops.Accepted _ -> true
  | Ops.Retryable -> true
  | _ -> false

let stage runtime (operation : Ops.pending_operation) =
  let s = state runtime in
  let snapshot = s.snapshot in
  let operation_id = operation.operation_id in
  let known =
    List.exists
      (fun (id, _) -> id = operation_id)
      snapshot.statuses
  in
  let existing = if known then Ops.list runtime.path else [] in
  let replacing =
    List.find_opt
      (fun (op : Ops.pending_operation) -> op.operation_id = operation_id)
      existing
  in
  let prepared = Hashtbl.find_opt s.prepared operation_id in
  let operation =
    match prepared with
    | Some normalized ->
      { normalized with Ops.state = operation.state }
    | None -> operation
  in
  let state_only =
    match replacing with
    | Some previous
      when transport_state operation.state
           &&
           (match previous.Ops.state with
            | Ops.Conflicted _ -> false
            | _ -> true) ->
      Some
        {
          previous with
          Ops.state = operation.state;
          intent =
            (match prepared with
             | Some normalized -> normalized.intent
             | None -> previous.intent);
        }
    | _ -> None
  in
  match state_only with
  | Some operation ->
    Ops.save runtime.path operation;
    Ok ()
  | None ->
    (match replacing with
     | None ->
       if operation.base_t <> s.server_t then
         Error "operation was created against a stale server cursor"
       else
         (match Projection.compile snapshot.db operation.intent with
          | Error message -> Error message
          | Ok tx ->
            Ops.save runtime.path operation;
            runtime.state :=
              {
                !(runtime.state) with
                snapshot =
                  {
                    snapshot with
                    Projection.db = Ds.db_with tx snapshot.db;
                    statuses =
                      snapshot.statuses @ [ (operation_id, Ops.Applied) ];
                  };
              };
            refresh_search_affected runtime snapshot.db operation.intent;
            Ok ())
     | Some _ ->
       let candidates =
         List.filter
           (fun (op : Ops.pending_operation) ->
             op.operation_id <> operation_id)
           existing
         @ [ operation ]
       in
       let candidate =
         Projection.build s.server_t (Ds.conn_db runtime.conn) candidates
       in
       (match List.assoc_opt operation_id candidate.statuses with
        | Some Ops.Applied ->
          Ops.save runtime.path operation;
          runtime.state :=
            { !(runtime.state) with snapshot = candidate };
          refresh_search_affected runtime snapshot.db operation.intent;
          Ok ()
        | Some (Ops.Conflicted message) -> Error message
        | _ -> Error "operation could not be projected"))

let queued_operation runtime operation_id intent =
  {
    Ops.operation_id;
    base_t = (state runtime).server_t;
    state = Ops.Queued;
    intent;
  }

let ensure_today_journal runtime =
  let created_at = int_of_float (Unix.gettimeofday () *. 1000.0) in
  let day = Model.journal_day_for_ms created_at in
  if Read.journal_page_uuid (db runtime) day <> None then Ok ()
  else
    stage runtime
      (queued_operation runtime (fresh_uuid ())
         (Ops.Create_journal
            {
              Ops.page_uuid =
                Printf.sprintf "00000001-%04d-%04d-0000-000000000000"
                  (day / 10000) (day mod 10000);
              block_uuid = fresh_uuid ();
              title = Journal.day_title day;
              journal_day = day;
              created_at;
            }))

let create path server_t conn options =
  let started = Unix.gettimeofday () in
  let runtime = create_base path server_t conn options in
  trace_stage "LOGSEQ_RUNTIME_METRIC" started "base";
  if options.auto_create_today then
    (match ensure_today_journal runtime with
     | Ok () -> ()
     | Error message ->
       failwith ("create today's journal: " ^ message));
  runtime

let blocks runtime =
  let caches = caches_for_db runtime (db runtime) in
  let limit = (state runtime).journal_limit in
  match Hashtbl.find_opt caches.blocks limit with
  | Some blocks -> blocks
  | None ->
    let blocks = Read.blocks (fun v -> Ok v) limit (db runtime) in
    Hashtbl.replace caches.blocks limit blocks;
    blocks

let due_flashcards runtime now = Cards.due_cards (db runtime) now

let semantic_option value =
  match value with
  | Some value ->
    let ( let* ) = Result.bind in
    let* value = Ops.semantic_value_from_datascript value in
    Ok (Some value)
  | None -> Ok None

let review_flashcard runtime uuid rating now operation_id =
  let database = db runtime in
  match Cards.card_for_uuid database now uuid with
  | Some card ->
    let repeated = Cards.repeat now card.card rating in
    let eid = Ds.entid database "block/uuid" (Ds.Uuid uuid) in
    let current attr =
      match eid with
      | Some eid -> Read.value database eid attr
      | None -> None
    in
    let ( let* ) = Result.bind in
    let* expected_state =
      semantic_option (current "logseq.property.fsrs/state")
    in
    let* expected_due =
      semantic_option (current "logseq.property.fsrs/due")
    in
    let* value =
      Ops.semantic_value_from_datascript (Cards.state_value repeated)
    in
    stage runtime
      (queued_operation runtime operation_id
         (Ops.Set_properties
            {
              Ops.uuid;
              changes =
                [
                  {
                    Ops.attr = "logseq.property.fsrs/state";
                    expected = expected_state;
                    value = Some value;
                  };
                  {
                    Ops.attr = "logseq.property.fsrs/due";
                    expected = expected_due;
                    value = Some (Ops.Int_value repeated.due);
                  };
                ];
            }))
  | None -> Error "block is not a flashcard"

let has_older_journals runtime =
  let caches = caches_for_db runtime (db runtime) in
  match !(caches.journal_page_count) with
  | Some count -> (state runtime).journal_limit < count
  | None ->
    let count = Read.journal_page_count (db runtime) in
    caches.journal_page_count := Some count;
    (state runtime).journal_limit < count

let load_older_journals runtime =
  runtime.state :=
    {
      !(runtime.state) with
      journal_limit = (state runtime).journal_limit + 2;
    }

let blocks_for_page runtime page_uuid =
  let caches = caches_for_db runtime (db runtime) in
  match Hashtbl.find_opt caches.page_blocks page_uuid with
  | Some blocks -> blocks
  | None ->
    let blocks =
      Read.blocks_for_page (fun v -> Ok v) (db runtime) page_uuid
    in
    Hashtbl.replace caches.page_blocks page_uuid blocks;
    blocks

let sidebar_pages runtime =
  let database = db runtime in
  match (state runtime).sidebar_cache with
  | Some (cached, pages) when cached == database -> pages
  | _ ->
    let pages = Read.sidebar_pages (fun v -> Ok v) database in
    runtime.state :=
      {
        !(runtime.state) with
        sidebar_cache = Some (database, pages);
      };
    pages

let set_page_favorite runtime page_uuid favorite operation_id now =
  let database = db runtime in
  let save favorite_uuid order =
    stage runtime
      (queued_operation runtime operation_id
         (Ops.Set_favorite
            {
              Ops.page_uuid;
              favorite_uuid;
              favorite;
              order;
              created_at = now;
            }))
  in
  if Read.page_is_favorite database page_uuid = favorite then Ok ()
  else if favorite then
    let ( let* ) = Result.bind in
    let* value = Order.between (Read.last_favorite_order database) None in
    save (fresh_uuid ()) value
  else
    match Read.favorite_block_uuid database page_uuid with
    | Some uuid -> save uuid ""
    | None -> Ok ()

let delete_page runtime page_uuid operation_id now =
  let ( let* ) = Result.bind in
  let* order = Order.between (Read.last_recycle_order (db runtime)) None in
  stage runtime
    (queued_operation runtime operation_id
       (Ops.Delete_page
          { Ops.page_uuid; order; deleted_at = now }))

let node_destination runtime uuid =
  let caches = caches_for_db runtime (db runtime) in
  match Hashtbl.find_opt caches.node_destinations uuid with
  | Some destination -> destination
  | None ->
    let destination =
      Read.node_destination (fun v -> Ok v) (db runtime) uuid
    in
    Hashtbl.replace caches.node_destinations uuid destination;
    destination

let node_blocks_for runtime kind uuid =
  let caches = caches_for_db runtime (db runtime) in
  let key = kind ^ uuid in
  match Hashtbl.find_opt caches.node_blocks key with
  | Some blocks -> blocks
  | None ->
    let blocks =
      match kind with
      | "tag:" -> Read.objects_for_tag (fun v -> Ok v) (db runtime) uuid
      | "refs:" ->
        Read.references_for_node (fun v -> Ok v) (db runtime) uuid
      | _ -> Read.blocks_for_page (fun v -> Ok v) (db runtime) uuid
    in
    Hashtbl.replace caches.node_blocks key blocks;
    blocks

let objects_for_tag runtime uuid = node_blocks_for runtime "tag:" uuid
let references_for_node runtime uuid = node_blocks_for runtime "refs:" uuid

let tag_pages runtime =
  let caches = caches_for_db runtime (db runtime) in
  match !(caches.tag_pages) with
  | Some pages -> pages
  | None ->
    let pages = Read.tag_pages (fun v -> Ok v) (db runtime) in
    caches.tag_pages := Some pages;
    pages

let node_kind runtime uuid =
  let caches = caches_for_db runtime (db runtime) in
  match Hashtbl.find_opt caches.node_kind uuid with
  | Some kind -> kind
  | None ->
    let kind =
      ( Read.node_is_tag (db runtime) uuid
      , Read.node_is_property (db runtime) uuid )
    in
    Hashtbl.replace caches.node_kind uuid kind;
    kind

let node_is_tag runtime uuid = fst (node_kind runtime uuid)
let node_is_property runtime uuid = snd (node_kind runtime uuid)

let journal_page_uuid runtime journal_day =
  let caches = caches_for_db runtime (db runtime) in
  match Hashtbl.find_opt caches.journal_page_uuids journal_day with
  | Some uuid -> uuid
  | None ->
    let uuid = Read.journal_page_uuid (db runtime) journal_day in
    Hashtbl.replace caches.journal_page_uuids journal_day uuid;
    uuid

let normalize_titles runtime uuid titles =
  Read.normalize_titles_creating_tags (db runtime) fresh_uuid uuid titles

let search runtime query =
  match runtime.search_index with
  | Some search_index ->
    if not (state runtime).search_index_is_fresh then
      refresh_search runtime;
    (try
       let hits = Index.search_hits 100 search_index (db runtime) query in
       prerr_endline
         (Printf.sprintf
            "LOGSEQ_SEARCH_INDEX_QUERY query=%S fresh=%b hits=%d" query
            (state runtime).search_index_is_fresh
            (List.length hits));
       hits
     with error ->
       prerr_endline
         (Printf.sprintf
            "LOGSEQ_SEARCH_INDEX_ERROR stage=query query=%S error=%s"
            query (Printexc.to_string error));
       [])
  | None -> []
