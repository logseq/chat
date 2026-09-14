module Ops = Logseq_chat_pending_ops
module Projection = Logseq_chat_pending_projection
module LG = Logseq_chat_lg_core_native

let ( >>= ) = Result.bind
let ( >>| ) result f = Result.map f result

type t =
  { path : string
  ; conn : Datascript.conn
  ; encrypt_title : string -> (string, string) result
  ; mutable server_t : int
  ; mutable snapshot : Projection.snapshot
  ; mutable sidebar_cache : (Datascript.db * Logseq_chat_graph_read.sidebar_pages) option
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
      | error ->
        Printf.eprintf
          "LOGSEQ_SEARCH_INDEX_ERROR stage=refresh error=%s\n%!"
          (Printexc.to_string error);
        runtime.search_index_is_fresh <- false)
    runtime.search_index
;;

let rec subtree_uuids db roots =
  match roots with
  | [] -> []
  | uuid :: rest ->
    (match Datascript.entid db "block/uuid" (Datascript.Uuid uuid) with
     | None -> uuid :: subtree_uuids db rest
     | Some eid ->
       let children =
         Datascript.datoms db Datascript.Aevt ~a:"block/parent" ~v:(Datascript.Ref eid) ()
         |> Seq.filter_map (fun datom ->
           match
             Datascript.datoms db Datascript.Eavt ~e:datom.Datascript.e ~a:"block/uuid" ()
             |> Seq.uncons
           with
           | Some ({ Datascript.v = Datascript.Uuid child; _ }, _) -> Some child
           | _ -> None)
         |> List.of_seq
       in
       uuid :: subtree_uuids db (children @ rest))
;;

let search_visible_property = function
  | "block/title" | "block/name" | "block/page" | "block/parent"
  | "block/journal-day" | "block/refs" | "logseq.property/built-in?"
  | "block/closed-value-property" | "logseq.property/hide?"
  | "logseq.property/deleted-at" -> true
  | _ -> false
;;

let affected_uuids db = function
  | Ops.Set_property { uuid; attr; _ } ->
    if search_visible_property attr then [ uuid ] else []
  | Ops.Set_properties { uuid; changes } ->
    if List.exists (fun change -> search_visible_property change.Ops.attr) changes
    then [ uuid ]
    else []
  | Ops.Save_title { uuid; _ }
  | Ops.Insert_block { uuid; _ } | Ops.Create_asset { uuid; _ }
  | Ops.Move_block { uuid; _ }
  | Ops.Add_tag { uuid; _ } | Ops.Create_tag { uuid; _ } | Ops.Create_page { uuid; _ } -> [ uuid ]
  | Ops.Move_blocks { moves } -> List.map (fun (move : Ops.move) -> move.uuid) moves
  | Ops.Split_block { uuid; new_uuid; _ } -> [ uuid; new_uuid ]
  | Ops.Merge_backward { uuid; previous_uuid; _ } -> [ uuid; previous_uuid ]
  | Ops.Delete_blocks { uuids } -> subtree_uuids db uuids
  | Ops.Create_journal { page_uuid; block_uuid; _ } -> [ page_uuid; block_uuid ]
  | Ops.Set_favorite { page_uuid; favorite_uuid; _ } -> [ page_uuid; favorite_uuid ]
  | Ops.Delete_page { page_uuid; _ } -> [ page_uuid ]
;;

let rec semantic_value = function
  | Datascript.String value -> Ok (Ops.String_value value)
  | Datascript.Int value -> Ok (Ops.Int_value value)
  | Datascript.Instant value -> Ok (Ops.Instant_value value)
  | Datascript.Float value -> Ok (Ops.Float_value value)
  | Datascript.Bool value -> Ok (Ops.Bool_value value)
  | Datascript.Keyword value -> Ok (Ops.Keyword_value value)
  | Datascript.Map entries ->
    List.fold_left
      (fun result (key, value) ->
        result >>= fun converted ->
        match key with
        | Datascript.Keyword key ->
          semantic_value value >>| fun value -> (key, value) :: converted
        | _ -> Error "flashcard state contains a non-keyword key")
      (Ok [])
      entries
    >>| fun entries -> Ops.Map_value (List.rev entries)
  | _ -> Error "flashcard state contains an unsupported value"
;;

let refresh_search_affected runtime ~before intent =
  match runtime.search_index with
  | None -> ()
  | Some index when runtime.search_index_is_fresh ->
    (try
       Logseq_chat_search_index.refresh_uuids
         index
         ~before
         ~after:runtime.snapshot.Projection.db
         (affected_uuids before intent)
     with
     | Failure _ -> runtime.search_index_is_fresh <- false)
  | Some _ -> ()
;;

let refresh_search_after_rebase ~changed_uuids runtime ~before ~operations =
  let snapshot = runtime.snapshot in
  match runtime.search_index with
  | Some index when runtime.search_index_is_fresh ->
    let pending_uuids =
      operations
      |> List.concat_map (fun operation ->
        affected_uuids before operation.Ops.intent
        @ affected_uuids snapshot.db operation.intent)
    in
    (try
       Logseq_chat_search_index.refresh_uuids
         index
         ~before
         ~after:snapshot.db
         (changed_uuids @ pending_uuids)
     with
     | Failure _ -> runtime.search_index_is_fresh <- false)
  | Some _ | None -> ()
;;

let safe_to_rebase = function
  | Ops.Save_title _ | Ops.Set_property _ | Ops.Set_properties _
  | Ops.Split_block _ | Ops.Merge_backward _
  | Ops.Create_tag _ | Ops.Create_page _ | Ops.Create_journal _ | Ops.Add_tag _ | Ops.Insert_block _
  | Ops.Create_asset _
  | Ops.Move_block _ | Ops.Move_blocks _ | Ops.Set_favorite _ | Ops.Delete_page _ -> true
  | Ops.Delete_blocks _ -> false
;;

let inserted_result_exists db = function
  | Ops.Insert_block { uuid; _ } | Ops.Create_asset { uuid; _ } ->
    Option.is_some (Datascript.entid db "block/uuid" (Datascript.Uuid uuid))
  | _ -> false
;;

let split_result_exists db = function
  | Ops.Split_block { new_uuid; _ } ->
    Option.is_some (Datascript.entid db "block/uuid" (Datascript.Uuid new_uuid))
  | _ -> false
;;

let committed_despite_later_changes ~server_t authoritative (operation : Ops.t) =
  if inserted_result_exists authoritative operation.intent
  then true
  else match operation.state with
  | Ops.Accepted accepted_t ->
    accepted_t <= server_t && split_result_exists authoritative operation.intent
  | Ops.Submitted -> split_result_exists authoritative operation.intent
  | Ops.Conflicted "split block UUID already exists" ->
    split_result_exists authoritative operation.intent
  | Ops.Queued | Ops.Retryable | Ops.Applied | Ops.Conflicted _ -> false
;;

let rebase_operations ?(changed_uuids = []) runtime ~server_t ~operation_ids =
  let started = Unix.gettimeofday () in
  let report stage =
    if Sys.getenv_opt "LOGSEQ_CHAT_TRACE_STARTUP" = Some "1" then
      Printf.eprintf "LOGSEQ_REBASE_METRIC stage=%s elapsed_ms=%.3f\n%!"
        stage ((Unix.gettimeofday () -. started) *. 1000.)
  in
  let confirmed = Hashtbl.create (List.length operation_ids) in
  List.iter (fun operation_id -> Hashtbl.replace confirmed operation_id ()) operation_ids;
  List.iter (Hashtbl.remove runtime.prepared) operation_ids;
  let before = runtime.snapshot.Projection.db in
  let authoritative = Datascript.conn_db runtime.conn in
  let operations = Ops.list ~path:runtime.path |> List.filter (fun operation ->
    let is_confirmed = match operation.Ops.state with
    | _ when Hashtbl.mem confirmed operation.operation_id
             && Projection.satisfied authoritative operation.intent -> true
    | (Ops.Submitted | Ops.Accepted _) when Projection.satisfied authoritative operation.intent -> true
    | _ -> committed_despite_later_changes ~server_t authoritative operation
    in
    if is_confirmed then
      Ops.remove ~path:runtime.path ~operation_id:operation.operation_id;
    not is_confirmed) in
  report "confirmed";
  runtime.server_t <- server_t;
  let projected = ref authoritative in
  let statuses = List.map (fun (operation : Ops.t) ->
    let status = match operation.state with
    | Ops.Conflicted message -> Ops.Conflicted message
    | Ops.Accepted _ | Ops.Applied ->
      (match Projection.compile !projected operation.intent with
       | Ok tx ->
         projected := Datascript.db_with tx !projected;
         Ops.Applied
       | Error message ->
         Ops.save ~path:runtime.path { operation with state = Ops.Conflicted message };
         Ops.Conflicted message)
    | Ops.Queued | Ops.Retryable | Ops.Submitted ->
      Hashtbl.remove runtime.prepared operation.operation_id;
      (match
         if operation.base_t <> server_t && not (safe_to_rebase operation.intent)
         then Error "the server changed while the structural operation was pending"
         else Projection.compile !projected operation.intent
       with
       | Error message ->
         Ops.save ~path:runtime.path
           { operation with base_t = server_t; state = Ops.Conflicted message };
         Ops.Conflicted message
       | Ok tx ->
         projected := Datascript.db_with tx !projected;
         if operation.base_t <> server_t then
           Ops.save ~path:runtime.path
             { operation with base_t = server_t; state = Ops.Queued };
         Ops.Applied)
    in
    operation.operation_id, status) operations in
  (* Reconciliation already built the complete ordered projection. Publishing
     that same value avoids replaying every pending transaction a second time. *)
  runtime.snapshot <- Projection.{ db = !projected; server_t; statuses };
  report "projected";
  refresh_search_after_rebase ~changed_uuids runtime ~before ~operations;
  report "complete"
;;

let create_base
      ?(encrypt_title = fun value -> Ok value)
      ?search_index_path
      ~path
      ~server_t
      conn
  =
  let started = Unix.gettimeofday () in
  let report stage =
    if Sys.getenv_opt "LOGSEQ_CHAT_TRACE_STARTUP" = Some "1" then
      Printf.eprintf "LOGSEQ_RUNTIME_METRIC stage=%s elapsed_ms=%.3f\n%!"
        stage ((Unix.gettimeofday () -. started) *. 1000.)
  in
  (* Rebase below constructs the pending projection once the operation states
     have been reconciled with the authoritative graph. *)
  let snapshot = Projection.{ db = Datascript.conn_db conn; server_t; statuses = [] } in
  let search_index =
    Option.bind search_index_path (fun path ->
      try Some (Logseq_chat_search_index.create ~path) with
      | error ->
        Printf.eprintf
          "LOGSEQ_SEARCH_INDEX_ERROR stage=open error=%s\n%!"
          (Printexc.to_string error);
        None)
  in
  report "search";
  let runtime =
    { path
    ; conn
    ; encrypt_title
    ; server_t
    ; snapshot
    ; sidebar_cache = None
    ; prepared = Hashtbl.create 16
    ; journal_limit = 1
    ; search_index
    ; search_index_is_fresh = false
    }
  in
  rebase_operations runtime ~server_t ~operation_ids:[];
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

let normalize_fsrs_value attr = function
  | Ops.Instant_value value when String.equal attr "logseq.property.fsrs/due" ->
    Ops.Int_value value
  | Ops.Map_value entries when String.equal attr "logseq.property.fsrs/state" ->
    Ops.Map_value
      (List.map
         (function
           | "last-repeat", Ops.Instant_value value -> "last-repeat", Ops.Int_value value
           | entry -> entry)
         entries)
  | value -> value
;;

let normalize_property_change (change : Ops.property_change) =
  { change with
    expected = Option.map (normalize_fsrs_value change.attr) change.expected
  ; value = Option.map (normalize_fsrs_value change.attr) change.value
  }
;;

let normalize_operation_against runtime db operation =
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
    | Ops.Set_property ({ attr; expected; value; _ } as property) ->
      Ok
        (Ops.Set_property
           { property with
             expected = Option.map (normalize_fsrs_value attr) expected
           ; value = Option.map (normalize_fsrs_value attr) value
           })
    | Ops.Set_properties { uuid; changes } ->
      Ok (Ops.Set_properties { uuid; changes = List.map normalize_property_change changes })
    | (Ops.Move_block _ | Ops.Move_blocks _ | Ops.Delete_blocks _
      | Ops.Create_tag _ | Ops.Create_page _ | Ops.Create_journal _ | Ops.Create_asset _ | Ops.Add_tag _
      | Ops.Set_favorite _ | Ops.Delete_page _) as intent -> Ok intent
  in
  intent >>| fun intent -> { operation with Ops.intent }
;;

let normalize_operation runtime operation =
  normalize_operation_against runtime (Datascript.conn_db runtime.conn) operation
;;

let db_before_operation runtime operation_id =
  let authoritative = Datascript.conn_db runtime.conn in
  let rec collect_previous reversed = function
    | [] -> authoritative
    | operation :: _ when String.equal operation.Ops.operation_id operation_id ->
      (Projection.build
         ~server_t:runtime.server_t
         authoritative
         (List.rev reversed)).db
    | operation :: rest -> collect_previous (operation :: reversed) rest
  in
  collect_previous [] (Ops.list ~path:runtime.path)
;;

let prepare_sync runtime operation =
  let operation =
    Ops.list ~path:runtime.path
    |> List.find_opt (fun persisted ->
      String.equal persisted.Ops.operation_id operation.Ops.operation_id)
    |> Option.value ~default:operation
  in
  if operation.Ops.base_t <> runtime.server_t
  then Error "operation was created against a stale server cursor"
  else
    let db = db_before_operation runtime operation.operation_id in
    normalize_operation_against runtime db operation
    >>= fun normalized ->
    Projection.compile db normalized.intent
    >>= fun tx ->
    Logseq_chat_lg_core_native.logseq_chat_sync_tx_encode
      runtime.encrypt_title
      db
      tx
    >>| fun wire ->
    Hashtbl.replace runtime.prepared operation.operation_id normalized;
    Ops.outliner_op normalized.intent, wire
;;

let stage runtime operation =
  let operation_is_known =
    List.exists
      (fun (operation_id, _) -> String.equal operation_id operation.Ops.operation_id)
      runtime.snapshot.statuses
  in
  let existing = if operation_is_known then Ops.list ~path:runtime.path else [] in
  let replacing =
    List.find_opt
      (fun pending ->
        String.equal pending.Ops.operation_id operation.Ops.operation_id)
      existing
  in
  let prepared = Hashtbl.find_opt runtime.prepared operation.Ops.operation_id in
  let operation =
    match prepared with
    | Some normalized -> { normalized with state = operation.state }
    | None -> operation
  in
  let transport_state = function
    | Ops.Submitted | Ops.Accepted _ | Ops.Retryable -> true
    | Ops.Queued | Ops.Applied | Ops.Conflicted _ -> false
  in
  let state_only_update =
    match replacing with
    | Some existing
      when transport_state operation.state
           && (match existing.state with Ops.Conflicted _ -> false | _ -> true) ->
      let intent =
        match prepared with Some normalized -> normalized.intent | None -> existing.intent
      in
      Some { existing with state = operation.state; intent }
    | Some _ | None -> None
  in
  match state_only_update with
  | Some operation ->
    Ops.save ~path:runtime.path operation;
    Ok ()
  | None when Option.is_none replacing ->
    if operation.base_t <> runtime.server_t
    then Error "operation was created against a stale server cursor"
    else
      (match Projection.compile runtime.snapshot.db operation.intent with
       | Error message -> Error message
       | Ok tx ->
         let before = runtime.snapshot.db in
         Ops.save ~path:runtime.path operation;
         runtime.snapshot <-
           { runtime.snapshot with
             db = Datascript.db_with tx runtime.snapshot.db
           ; statuses =
               runtime.snapshot.statuses
               @ [ operation.operation_id, Ops.Applied ]
           };
         refresh_search_affected runtime ~before operation.intent;
         Ok ())
  | None ->
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
       let before = runtime.snapshot.db in
       Ops.save ~path:runtime.path operation;
       runtime.snapshot <- candidate;
       refresh_search_affected runtime ~before operation.intent;
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
  let started = Unix.gettimeofday () in
  let runtime = create_base ~encrypt_title ?search_index_path ~path ~server_t conn in
  if Sys.getenv_opt "LOGSEQ_CHAT_TRACE_STARTUP" = Some "1" then
    Printf.eprintf "LOGSEQ_RUNTIME_METRIC stage=base elapsed_ms=%.3f\n%!" ((Unix.gettimeofday () -. started) *. 1000.);
  if auto_create_today
  then (
    match ensure_today_journal runtime with
    | Ok () -> ()
    | Error message -> failwith ("create today's journal: " ^ message));
  runtime
;;

let rebase = rebase_operations
;;

let blocks runtime =
  Logseq_chat_graph_read.blocks
    ~journal_limit:runtime.journal_limit
    runtime.snapshot.db
;;

let due_flashcards runtime ~now =
  Logseq_chat_lg_core_native.logseq_chat_flashcards_due_cards runtime.snapshot.db now
;;

let review_flashcard runtime ~uuid ~rating ~now ~operation_id =
  let db = runtime.snapshot.db in
  match Logseq_chat_lg_core_native.logseq_chat_flashcards_card_for_uuid db now uuid with
  | None -> Error "block is not a flashcard"
  | Some due_card ->
    let repeated = Logseq_chat_lg_core_native.logseq_chat_flashcards_repeat now due_card.card rating in
    let eid = Datascript.entid db "block/uuid" (Datascript.Uuid uuid) in
    let current attr =
      Option.bind eid (fun eid -> Logseq_chat_graph_read.value db eid attr)
    in
    let semantic_option value =
      match value with
      | None -> Ok None
      | Some value -> semantic_value value >>| Option.some
    in
    semantic_option (current "logseq.property.fsrs/state") >>= fun expected_state ->
    semantic_option (current "logseq.property.fsrs/due") >>= fun expected_due ->
    semantic_value (Logseq_chat_lg_core_native.logseq_chat_flashcards_state_value repeated)
    >>= fun state ->
    stage
      runtime
      Ops.
        { operation_id
        ; base_t = runtime.server_t
        ; state = Queued
        ; intent =
            Set_properties
              { uuid
              ; changes =
                  [ { attr = "logseq.property.fsrs/state"
                    ; expected = expected_state
                    ; value = Some state
                    }
                  ; { attr = "logseq.property.fsrs/due"
                    ; expected = expected_due
                    ; value = Some (Int_value repeated.due)
                    }
                  ]
              }
        }
;;

let has_older_journals runtime =
  runtime.journal_limit < Logseq_chat_graph_read.journal_page_count runtime.snapshot.db
;;

let load_older_journals runtime =
  runtime.journal_limit <- runtime.journal_limit + 2
;;

let blocks_for_page runtime page_uuid =
  Logseq_chat_graph_read.blocks_for_page
    runtime.snapshot.db
    page_uuid
;;

let sidebar_pages runtime =
  let db = runtime.snapshot.db in
  match runtime.sidebar_cache with
  | Some (cached_db, pages) when cached_db == db -> pages
  | _ ->
    let pages = Logseq_chat_graph_read.sidebar_pages db in
    runtime.sidebar_cache <- Some (db, pages);
    pages
;;

let set_page_favorite runtime ~page_uuid ~favorite ~operation_id ~now =
  let db = runtime.snapshot.db in
  let current = Logseq_chat_graph_read.page_is_favorite db page_uuid in
  if current = favorite
  then Ok ()
  else if favorite
  then
    LG.logseq_chat_fractional_order_between (Logseq_chat_graph_read.last_favorite_order db) None
    >>= fun order ->
    stage
      runtime
      Ops.
        { operation_id
        ; base_t = runtime.server_t
        ; state = Queued
        ; intent =
            Set_favorite
              { page_uuid
              ; favorite_uuid = fresh_uuid ()
              ; favorite
              ; order
              ; created_at = now
              }
        }
  else
    match Logseq_chat_graph_read.favorite_block_uuid db page_uuid with
    | None -> Ok ()
    | Some favorite_uuid ->
      stage
        runtime
        Ops.
          { operation_id
          ; base_t = runtime.server_t
          ; state = Queued
          ; intent =
              Set_favorite
                { page_uuid
                ; favorite_uuid
                ; favorite
                ; order = ""
                ; created_at = now
                }
          }
;;

let delete_page runtime ~page_uuid ~operation_id ~now =
  LG.logseq_chat_fractional_order_between (Logseq_chat_graph_read.last_recycle_order runtime.snapshot.db) None
  >>= fun order ->
  stage
    runtime
    Ops.
      { operation_id
      ; base_t = runtime.server_t
      ; state = Queued
      ; intent = Delete_page { page_uuid; order; deleted_at = now }
      }
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
    (try
       let hits = Logseq_chat_search_index.search_hits index runtime.snapshot.db query in
       Printf.eprintf
         "LOGSEQ_SEARCH_INDEX_QUERY query=%S fresh=%b hits=%d\n%!"
         query
         runtime.search_index_is_fresh
         (List.length hits);
       hits
     with
     | error ->
       Printf.eprintf
         "LOGSEQ_SEARCH_INDEX_ERROR stage=query query=%S error=%s\n%!"
         query
         (Printexc.to_string error);
       [])
;;
