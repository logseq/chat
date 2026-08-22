open Datascript

module Ops = Logseq_chat_pending_ops
module Runtime = Logseq_chat_graph_runtime
module Transit = Transit_native.Transit.Json

let fail label = failwith label
let assert_bool label value = if not value then fail label

let one ?unique ?value_type ?(indexed = false) () =
  { cardinality = One; unique; indexed; is_component = false; no_history = false
  ; doc = None; value_type; tuple_attrs = None; tuple_types = None }
;;

let many ?value_type ?(indexed = false) () =
  { (one ?value_type ~indexed ()) with cardinality = Many }
;;

let schema =
  [ "block/uuid", one ~unique:Identity ~value_type:UuidType ~indexed:true ()
  ; "db/ident", one ~unique:Identity ~value_type:KeywordType ~indexed:true ()
  ; "block/title", one ~value_type:StringType ~indexed:true ()
  ; "block/name", one ~value_type:StringType ~indexed:true ()
  ; "block/page", one ~value_type:RefType ~indexed:true ()
  ; "block/parent", one ~value_type:RefType ~indexed:true ()
  ; "block/order", one ~value_type:StringType ~indexed:true ()
  ; "block/refs", many ~value_type:RefType ~indexed:true ()
  ; "block/journal-day", one ~value_type:NumberType ~indexed:true ()
  ; "block/created-at", one ~value_type:NumberType ~indexed:true ()
  ; "block/updated-at", one ~value_type:NumberType ~indexed:true () ]
  @ [ "logseq.property/status", one ~value_type:RefType ~indexed:true () ]
;;

let base_db title =
  empty_db ~schema ()
  |> db_with
       [ Add (Entity_id 1, "block/uuid", Uuid "page")
       ; Add (Entity_id 1, "block/title", String "Page")
       ; Add (Entity_id 1, "block/name", String "page")
       ; Add (Entity_id 1, "block/journal-day", Int 20260816)
       ; Add (Entity_id 10, "block/uuid", Uuid "block")
       ; Add (Entity_id 10, "block/title", String title)
       ; Add (Entity_id 10, "block/page", Ref 1)
       ; Add (Entity_id 10, "block/parent", Ref 1)
       ; Add (Entity_id 10, "block/order", String "a0")
       ; Add (Entity_id 10, "block/created-at", Int 1)
       ; Add (Entity_id 10, "block/updated-at", Int 1) ]
;;

let title db =
  match entity db (Lookup_ref ("block/uuid", Uuid "block")) with
  | Some entity ->
    (match entity_attr entity "block/title" with
     | Some (One_value (String value)) -> value
     | _ -> fail "projected block title is missing")
  | None -> fail "projected block is missing"
;;

let with_runtime f =
  let path = Filename.temp_file "logseq-chat-runtime" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      let conn = conn_from_db (base_db "Old") in
      f path conn (Runtime.create ~path ~server_t:42 conn))
;;

let save_title id expected title =
  Ops.
    { operation_id = id
    ; base_t = 42
    ; state = Queued
    ; intent = Save_title { uuid = "block"; expected_title = expected; title }
    }
;;

let () =
  with_runtime (fun path conn runtime ->
    assert_bool "valid operation stages" (Runtime.stage runtime (save_title "op-title" "Old" "Pending") = Ok ());
    assert_bool "read snapshot uses projected DB" (String.equal (title (Runtime.db runtime)) "Pending");
    assert_bool "authoritative conn remains unchanged" (String.equal (title (conn_db conn)) "Old");
    assert_bool "page block reader uses projected DB"
      (match Runtime.blocks_for_page runtime "page" with
       | [ block ] -> String.equal block.Logseq_chat_model.title "Pending"
       | _ -> false);
    assert_bool "journal reader uses projected DB"
      (match Runtime.blocks runtime with
       | [ block ] -> String.equal block.Logseq_chat_model.title "Pending"
       | _ -> false);
    assert_bool "missing node destinations stay absent in the projected DB"
      (Runtime.node_destination runtime "missing" = None);
    assert_bool "missing tags have no projected objects"
      (Runtime.objects_for_tag runtime "missing" = []);
    assert_bool "a graph without Tag entities has no tag autocomplete pages"
      (Runtime.tag_pages runtime = []);
    assert_bool "a missing graph node is not a tag"
      (not (Runtime.node_is_tag runtime "missing"));
    assert_bool "missing nodes have no projected references"
      (Runtime.references_for_node runtime "missing" = []);
    assert_bool "pending op is stored beside graph kvs"
      (List.map (fun op -> op.Ops.operation_id) (Ops.list ~path) = [ "op-title" ]))
;;

let () =
  with_runtime (fun _path _conn runtime ->
    let first = save_title "accepted-title" "Old" "First" in
    assert_bool "first title stages" (Runtime.stage runtime first = Ok ());
    assert_bool "first title becomes accepted"
      (Runtime.stage runtime { first with state = Accepted 43 } = Ok ());
    let second = save_title "next-title" "First" "Second" in
    assert_bool "dependent title stages on the accepted projection"
      (Runtime.stage runtime second = Ok ());
    assert_bool "dependent title prepares without waiting for a snapshot"
      (match Runtime.prepare_sync runtime second with Ok ("save-block", _) -> true | _ -> false))
;;

let () =
  with_runtime (fun path _conn runtime ->
    let first = save_title "in-flight-title" "Old" "First" in
    let stale_second = save_title "queued-during-flight" "First" "Second" in
    assert_bool "in-flight title stages" (Runtime.stage runtime first = Ok ());
    assert_bool "dependent edit stages against the optimistic projection"
      (Runtime.stage runtime stale_second = Ok ());
    assert_bool "in-flight title becomes accepted"
      (Runtime.stage runtime { first with state = Accepted 43 } = Ok ());
    Runtime.rebase runtime ~server_t:43 ~operation_ids:[];
    assert_bool "a stale queue copy prepares from its rebased persisted operation"
      (match Runtime.prepare_sync runtime stale_second with
       | Ok ("save-block", _) -> true
       | _ -> false);
    assert_bool "a stale completion updates only transport state"
      (Runtime.stage runtime { stale_second with state = Retryable } = Ok ());
    assert_bool "a stale completion cannot roll back the persisted cursor"
      (match
         List.find_opt
           (fun operation -> String.equal operation.Ops.operation_id stale_second.operation_id)
           (Ops.list ~path)
       with
       | Some operation -> operation.base_t = 43 && operation.state = Retryable
       | None -> false))
;;

let () =
  let path = Filename.temp_file "logseq-chat-reopen" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      Ops.save
        ~path
        { (save_title "retry-after-reopen" "Old" "New") with
          base_t = 42
        ; state = Retryable
        };
      let runtime = Runtime.create_base ~path ~server_t:43 (conn_from_db (base_db "Old")) in
      assert_bool "reopening rebases a safe retryable operation"
        (match Ops.list ~path with
         | [ { Ops.base_t = 43; state = Queued; _ } ] -> true
         | _ -> false);
      assert_bool "the rebased operation prepares immediately after reopen"
        (match Runtime.pending_operations runtime with
         | [ operation ] ->
           (match Runtime.prepare_sync runtime operation with Ok ("save-block", _) -> true | _ -> false)
         | _ -> false))
;;

let () =
  let path = Filename.temp_file "logseq-chat-reopen-delete" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      Ops.save
        ~path
        Ops.
          { operation_id = "unsafe-delete-after-reopen"
          ; base_t = 42
          ; state = Retryable
          ; intent = Delete_blocks { uuids = [ "block" ] }
          };
      ignore (Runtime.create_base ~path ~server_t:43 (conn_from_db (base_db "Old")));
      assert_bool "reopening conflicts an unsafe stale structural operation"
        (match Ops.list ~path with
         | [ { Ops.base_t = 43; state = Conflicted _; _ } ] -> true
         | _ -> false))
;;

let () =
  let path = Filename.temp_file "logseq-chat-journal-window" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      let tx =
        List.init 8 (fun index ->
          let page_eid = index + 1 in
          let block_eid = index + 101 in
          [ Add (Entity_id page_eid, "block/uuid", Uuid ("page-" ^ string_of_int index))
          ; Add (Entity_id page_eid, "block/title", String ("Page " ^ string_of_int index))
          ; Add (Entity_id page_eid, "block/name", String ("page-" ^ string_of_int index))
          ; Add (Entity_id page_eid, "block/journal-day", Int (20260801 + index))
          ; Add (Entity_id block_eid, "block/uuid", Uuid ("block-" ^ string_of_int index))
          ; Add (Entity_id block_eid, "block/title", String ("Block " ^ string_of_int index))
          ; Add (Entity_id block_eid, "block/page", Ref page_eid)
          ; Add (Entity_id block_eid, "block/parent", Ref page_eid)
          ; Add (Entity_id block_eid, "block/created-at", Int index)
          ])
        |> List.concat
      in
      let conn = conn_from_db (empty_db ~schema () |> db_with tx) in
      let runtime = Runtime.create ~path ~server_t:42 conn in
      assert_bool "journal launch projection contains only today's journal"
        (List.length (Runtime.blocks runtime) = 1 && Runtime.has_older_journals runtime);
      Runtime.load_older_journals runtime;
      assert_bool "journal projection expands only when requested"
        (List.length (Runtime.blocks runtime) = 8 && not (Runtime.has_older_journals runtime)))
;;

let () =
  with_runtime (fun _path conn runtime ->
    let operation =
      Ops.
        { operation_id = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8"
        ; base_t = 42
        ; state = Queued
        ; intent =
            Split_block
              { uuid = "block"
              ; expected_title = "Old"
              ; before = "O"
              ; after = "ld"
              ; new_uuid = "new-block"
              ; new_order = "a1"
              ; created_at = 100
              }
        }
    in
    (match Runtime.prepare_sync runtime operation with
     | Ok ("split-block", wire) ->
       (match Transit.of_string wire with
        | Transit.Array (_ :: _ :: _) -> ()
        | _ -> fail "split must be encoded as one multi-operation transaction")
     | Ok _ -> fail "split must retain its outliner operation metadata"
     | Error message -> fail ("split sync preparation failed: " ^ message));
    assert_bool "sync preparation does not mutate authoritative data"
      (String.equal (title (conn_db conn)) "Old"))
;;

let () =
  with_runtime (fun _path _conn runtime ->
    let operation operation_id intent =
      Ops.{ operation_id; base_t = 42; state = Queued; intent }
    in
    let operations =
      [ operation "split-1"
          (Split_block
             { uuid = "block"; expected_title = "Old"; before = "Old"; after = ""
             ; new_uuid = "empty-1"; new_order = "a1"; created_at = 100 })
      ; operation "split-2"
          (Split_block
             { uuid = "empty-1"; expected_title = ""; before = ""; after = ""
             ; new_uuid = "empty-2"; new_order = "a2"; created_at = 101 })
      ; operation "merge-1"
          (Merge_backward
             { uuid = "empty-2"; expected_title = ""; title = ""
             ; previous_uuid = "empty-1"; expected_previous_title = ""; merged_title = None })
      ; operation "merge-2"
          (Merge_backward
             { uuid = "empty-1"; expected_title = ""; title = ""
             ; previous_uuid = "block"; expected_previous_title = "Old"; merged_title = None })
      ]
    in
    assert_bool "consecutive empty-block deletes stage against the latest projection"
      (List.for_all (fun pending -> Runtime.stage runtime pending = Ok ()) operations);
    assert_bool "consecutive empty-block deletes leave only the original block"
      (Runtime.blocks_for_page runtime "page"
       |> List.map (fun block -> block.Logseq_chat_model.uuid)
       = [ "block" ]))
;;

let () =
  with_runtime (fun _path conn runtime ->
    assert_bool "valid operation stages" (Runtime.stage runtime (save_title "op-title" "Old" "Pending") = Ok ());
    ignore (reset_conn conn (base_db "Remote"));
    Runtime.rebase runtime ~server_t:43 ~operation_ids:[];
    assert_bool "rebase discards stale compiled tx"
      (String.equal (title (Runtime.db runtime)) "Remote");
    assert_bool "semantic conflict is retained"
      (match List.assoc_opt "op-title" (Runtime.operation_statuses runtime) with
       | Some (Ops.Conflicted _) -> true
       | _ -> false))
;;

let () =
  with_runtime (fun path conn runtime ->
    assert_bool "queued save stages"
      (Runtime.stage runtime (save_title "op-rebase" "Old" "Pending") = Ok ());
    ignore (reset_conn conn (base_db "Old"));
    Runtime.rebase runtime ~server_t:43 ~operation_ids:[];
    (match Ops.list ~path with
     | [ { Ops.operation_id = "op-rebase"; base_t = 43; state = Queued; _ } ] -> ()
     | _ -> fail "safe semantic rebase must advance the pending operation cursor");
    assert_bool "rebased save can be prepared"
      (match Runtime.prepare_sync runtime (List.hd (Ops.list ~path)) with
       | Ok _ -> true
       | Error _ -> false))
;;

let () =
  with_runtime (fun path conn runtime ->
    let split =
      Ops.
        { operation_id = "op-dependent-split"
        ; base_t = 42
        ; state = Queued
        ; intent =
            Split_block
              { uuid = "block"
              ; expected_title = "Old"
              ; before = "O"
              ; after = "ld"
              ; new_uuid = "dependent-new"
              ; new_order = "a1"
              ; created_at = 100
              }
        }
    in
    let edit_new =
      Ops.
        { operation_id = "op-dependent-edit"
        ; base_t = 42
        ; state = Queued
        ; intent =
            Save_title
              { uuid = "dependent-new"; expected_title = "ld"; title = "Edited" }
        }
    in
    assert_bool "dependent split stages" (Runtime.stage runtime split = Ok ());
    assert_bool "dependent edit stages" (Runtime.stage runtime edit_new = Ok ());
    ignore (reset_conn conn (base_db "Old"));
    Runtime.rebase runtime ~server_t:43 ~operation_ids:[];
    assert_bool "unrelated cursor advance preserves ordered structural dependency"
      (match entity (Runtime.db runtime) (Lookup_ref ("block/uuid", Uuid "dependent-new")) with
       | Some entity ->
         entity_attr entity "block/title" = Some (One_value (String "Edited"))
       | None -> false);
    assert_bool "both dependent operations advance to the latest cursor"
      (Ops.list ~path
       |> List.for_all (fun operation -> operation.Ops.base_t = 43 && operation.state = Queued)))
;;

let () =
  with_runtime (fun path conn runtime ->
    let insert =
      Ops.
        { operation_id = "offline-insert"
        ; base_t = 42
        ; state = Queued
        ; intent =
            Insert_block
              { uuid = "offline-new"
              ; title = "Created offline"
              ; page_uuid = "page"
              ; parent_uuid = "page"
              ; order = "a1"
              ; created_at = 100
              }
        }
    in
    assert_bool "offline insert stages" (Runtime.stage runtime insert = Ok ());
    ignore (reset_conn conn (base_db "Old"));
    Runtime.rebase runtime ~server_t:43 ~operation_ids:[];
    assert_bool
      "unrelated server progress preserves an offline insert"
      (match Ops.list ~path with
       | [ { Ops.operation_id = "offline-insert"; base_t = 43; state = Queued; _ } ] ->
         Option.is_some
           (entity (Runtime.db runtime) (Lookup_ref ("block/uuid", Uuid "offline-new")))
       | _ -> false))
;;

let () =
  with_runtime (fun path conn runtime ->
    let delete =
      Ops.
        { operation_id = "op-delete-conflict"
        ; base_t = 42
        ; state = Queued
        ; intent = Delete_blocks { uuids = [ "block" ] }
        }
    in
    assert_bool "guarded delete stages" (Runtime.stage runtime delete = Ok ());
    ignore (reset_conn conn (base_db "Remote update"));
    Runtime.rebase runtime ~server_t:43 ~operation_ids:[];
    assert_bool "server movement conflicts a pending delete"
      (match Ops.list ~path with
       | [ { Ops.state = Conflicted _; _ } ] -> true
       | _ -> false);
    assert_bool "conflicted delete restores the authoritative block"
      (String.equal (title (Runtime.db runtime)) "Remote update"))
;;

let () =
  with_runtime (fun path conn runtime ->
    assert_bool "valid operation stages" (Runtime.stage runtime (save_title "op-title" "Old" "Pending") = Ok ());
    ignore (reset_conn conn (base_db "Pending"));
    Runtime.rebase runtime ~server_t:43 ~operation_ids:[ "op-title" ];
    assert_bool "confirmed operation leaves the SQLite log" (Ops.list ~path = []);
    assert_bool "confirmed authoritative value stays visible"
      (String.equal (title (Runtime.db runtime)) "Pending"))
;;

let () =
  with_runtime (fun path conn runtime ->
    assert_bool
      "offline edit stages before confirmation"
      (Runtime.stage runtime (save_title "premature-confirm" "Old" "Pending") = Ok ());
    ignore (reset_conn conn (base_db "Old"));
    Runtime.rebase runtime ~server_t:43 ~operation_ids:[ "premature-confirm" ];
    assert_bool
      "confirmation id cannot discard an edit absent from authoritative state"
      (match Ops.list ~path with
       | [ { Ops.operation_id = "premature-confirm"; _ } ] -> true
       | _ -> false))
;;

let () =
  with_runtime (fun path conn runtime ->
    let submitted = { (save_title "op-echo" "Old" "Pending") with state = Submitted } in
    assert_bool "submitted operation stages" (Runtime.stage runtime submitted = Ok ());
    ignore (reset_conn conn (base_db "Pending"));
    Runtime.rebase runtime ~server_t:43 ~operation_ids:[];
    assert_bool "authoritative semantic echo removes submitted operation" (Ops.list ~path = []);
    assert_bool "authoritative semantic echo stays visible"
      (String.equal (title (Runtime.db runtime)) "Pending"))
;;

let () =
  with_runtime (fun path conn runtime ->
    let accepted = { (save_title "op-accepted" "Old" "Pending") with state = Accepted 44 } in
    assert_bool "accepted operation stages" (Runtime.stage runtime accepted = Ok ());
    ignore (reset_conn conn (base_db "Old"));
    Runtime.rebase runtime ~server_t:43 ~operation_ids:[];
    assert_bool "accepted operation remains projected before accepted cursor"
      (String.equal (title (Runtime.db runtime)) "Pending");
    assert_bool "accepted operation remains persisted before accepted cursor"
      (List.map (fun op -> op.Ops.operation_id) (Ops.list ~path) = [ "op-accepted" ]);
    ignore (reset_conn conn (base_db "Pending"));
    Runtime.rebase runtime ~server_t:44 ~operation_ids:[];
    assert_bool "accepted operation is removed at accepted cursor" (Ops.list ~path = []);
    assert_bool "authoritative accepted value remains visible"
      (String.equal (title (Runtime.db runtime)) "Pending"))
;;

let () =
  with_runtime (fun path _conn runtime ->
    let submitted = save_title "state-only" "Old" "Pending" in
    assert_bool
      "operation stages before transport"
      (Runtime.stage runtime submitted = Ok ());
    Ops.save ~path (save_title "unrelated-late-row" "Old" "Other");
    assert_bool
      "transport state update does not replay the pending log"
      (Runtime.stage runtime { submitted with state = Accepted 44 } = Ok ());
    assert_bool
      "accepted transport state is persisted"
      (match
         Ops.list ~path
         |> List.find_opt (fun operation ->
           String.equal operation.Ops.operation_id "state-only")
       with
       | Some { state = Accepted 44; _ } -> true
       | _ -> false))
;;

let () =
  with_runtime (fun _path _conn runtime ->
    let started_at = Unix.gettimeofday () in
    let previous = ref "Old" in
    for index = 1 to 500 do
      let title = "Offline " ^ string_of_int index in
      let operation =
        save_title
          ("incremental-" ^ string_of_int index)
          !previous
          title
      in
      if Runtime.stage runtime operation <> Ok ()
      then fail "incremental offline edit did not stage";
      previous := title
    done;
    let elapsed = Unix.gettimeofday () -. started_at in
    assert_bool
      "staging a burst of offline edits stays bounded"
      (elapsed < 0.5 && String.equal (title (Runtime.db runtime)) "Offline 500"))
;;

let () =
  with_runtime (fun path _conn runtime ->
    let invalid =
      Ops.
        { operation_id = "op-invalid"
        ; base_t = 42
        ; state = Queued
        ; intent = Move_block { uuid = "block"; page_uuid = "page"; parent_uuid = "block"; order = "a0" }
        }
    in
    assert_bool "invalid operation is rejected before persistence"
      (match Runtime.stage runtime invalid with Error _ -> true | Ok () -> false);
    assert_bool "rejected operation is absent from SQLite" (Ops.list ~path = []);
    assert_bool "rejected operation does not change projection"
      (String.equal (title (Runtime.db runtime)) "Old"))
;;

let () =
  with_runtime (fun path _conn runtime ->
    let save operation = Ops.save ~path operation in
    save (save_title "queued" "Old" "Queued");
    save { (save_title "retryable" "Old" "Retryable") with state = Retryable };
    save { (save_title "submitted" "Old" "Submitted") with state = Submitted };
    save { (save_title "accepted" "Old" "Accepted") with state = Accepted 44 };
    save { (save_title "applied" "Old" "Applied") with state = Applied };
    save
      { (save_title "conflicted" "Old" "Conflicted") with
        state = Conflicted "server changed"
      };
    let ids =
      Runtime.pending_operations runtime
      |> List.map (fun operation -> operation.Ops.operation_id)
    in
    assert_bool
      "only transport-recoverable semantic operations are restored"
      (ids = [ "queued"; "retryable"; "submitted" ]))
;;

let () =
  let path = Filename.temp_file "logseq-chat-runtime-restore" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      Ops.save ~path (save_title "stale" "Remote title" "Stale local edit");
      Ops.save ~path (save_title "valid" "Old" "Valid local edit");
      let runtime =
        Runtime.create ~path ~server_t:42 (conn_from_db (base_db "Old"))
      in
      let ids =
        Runtime.pending_operations runtime
        |> List.map (fun operation -> operation.Ops.operation_id)
      in
      assert_bool
        "startup restores only operations that remain valid against the graph"
        (ids = [ "valid" ]);
      assert_bool
        "startup persists projected conflicts instead of retrying them forever"
        (match
           Ops.list ~path
           |> List.find_opt (fun operation ->
             String.equal operation.Ops.operation_id "stale")
         with
         | Some { state = Conflicted _; _ } -> true
         | _ -> false))
;;

let () =
  with_runtime (fun _path _conn runtime ->
    let db = Runtime.db runtime in
    assert_bool "raw title reports missing entities and missing title attributes"
      (Runtime.raw_title db "missing" = Error "block no longer exists"
       && Runtime.raw_title db "page-without-title" = Error "block no longer exists");
    let without_title =
      db_with [ Add (Entity_id 30, "block/uuid", Uuid "without-title") ] db
    in
    assert_bool "raw title distinguishes an entity without a title"
      (Runtime.raw_title without_title "without-title" = Error "block title is missing");
    assert_bool "expected title normalization detects a server change"
      (Runtime.normalize_expected_title runtime db ~uuid:"block" ~expected:"Wrong"
       = Error "title changed on the server");
    let stale = { (save_title "stale" "Old" "New") with base_t = 41 } in
    assert_bool "sync preparation rejects a stale cursor"
      (Runtime.prepare_sync runtime stale
       = Error "operation was created against a stale server cursor");
    assert_bool "new staging rejects a stale cursor"
      (Runtime.stage runtime stale
       = Error "operation was created against a stale server cursor"))
;;

let () =
  with_runtime (fun _path _conn runtime ->
    let insert =
      Ops.
        { operation_id = "insert"
        ; base_t = 42
        ; state = Queued
        ; intent =
            Insert_block
              { uuid = "inserted"; title = "New"; page_uuid = "page"
              ; parent_uuid = "page"; order = "a1"; created_at = 2 }
        }
    in
    assert_bool "insert normalization follows the title codec"
      (match Runtime.normalize_operation runtime insert with
       | Ok { intent = Insert_block { title = "New"; _ }; _ } -> true
       | _ -> false);
    let move =
      Ops.
        { operation_id = "move"; base_t = 42; state = Queued
        ; intent = Move_block { uuid = "block"; page_uuid = "page"; parent_uuid = "page"; order = "a1" } }
    in
    assert_bool "non-title operations pass normalization unchanged"
      (Runtime.normalize_operation runtime move = Ok move);
    let passthrough_intents =
      [ Ops.Set_property
          { uuid = "block"; attr = "block/title"; expected = None; value = None }
      ; Move_blocks { moves = [] }
      ; Delete_blocks { uuids = [ "block" ] }
      ]
    in
    assert_bool "every non-title intent passes normalization unchanged"
      (List.for_all
         (fun intent ->
           let operation = { move with Ops.intent } in
           Runtime.normalize_operation runtime operation = Ok operation)
         passthrough_intents);
    (match Runtime.prepare_sync runtime insert with
     | Ok ("insert-blocks", _) ->
       assert_bool "prepared insert can be projected" (Runtime.stage runtime insert = Ok ())
     | Ok _ -> fail "insert preparation changed operation metadata"
     | Error message -> fail ("insert preparation failed: " ^ message));
    let sidebar = Runtime.sidebar_pages runtime in
    assert_bool "sidebar and journal readers use the projected DB"
      (List.exists
         (fun page -> String.equal page.Logseq_chat_graph_read.uuid "page")
         sidebar.recent_pages
       && Runtime.journal_page_uuid runtime ~journal_day:20260816 = Some "page")
  )
;;

let () =
  let rebaseable_structural =
    [ Ops.Insert_block
        { uuid = "new"; title = ""; page_uuid = "page"; parent_uuid = "page"
        ; order = "a1"; created_at = 1 }
    ; Move_block { uuid = "block"; page_uuid = "page"; parent_uuid = "page"; order = "a0" }
    ; Move_blocks { moves = [] }
    ]
  in
  let semantic =
    [ Ops.Save_title { uuid = "block"; expected_title = "Old"; title = "New" }
    ; Set_property { uuid = "block"; attr = "block/title"; expected = None; value = None }
    ; Split_block
        { uuid = "block"; expected_title = "Old"; before = ""; after = "Old"
        ; new_uuid = "new"; new_order = "a1"; created_at = 1 }
    ; Merge_backward
        { uuid = "block"; expected_title = "Old"; title = "Old"
        ; previous_uuid = "page"; expected_previous_title = "Page"; merged_title = None }
    ]
  in
  assert_bool "rebase safety is defined for every pending intent"
    (List.for_all Runtime.safe_to_rebase rebaseable_structural
     && List.for_all Runtime.safe_to_rebase semantic
     && not (Runtime.safe_to_rebase (Ops.Delete_blocks { uuids = [ "block" ] })))
;;

let () =
  with_runtime (fun path conn runtime ->
    Ops.save ~path { (save_title "conflicted" "Old" "Ignored") with state = Conflicted "known" };
    Ops.save ~path { (save_title "applied" "Old" "Applied") with state = Applied };
    Ops.save ~path { (save_title "bad-applied" "Wrong" "Bad") with state = Applied };
    ignore (reset_conn conn (base_db "Old"));
    Runtime.rebase runtime ~server_t:42 ~operation_ids:[];
    assert_bool "rebase skips conflicts and replays only valid applied operations"
      (String.equal (title (Runtime.db runtime)) "Applied");
    assert_bool
      "an applied operation that no longer compiles becomes a durable conflict"
      (match
         Ops.list ~path
         |> List.find_opt (fun operation ->
           String.equal operation.Ops.operation_id "bad-applied")
       with
       | Some { state = Conflicted _; _ } -> true
       | _ -> false))
;;

let () =
  with_runtime (fun path conn runtime ->
    Ops.save ~path { (save_title "retryable-rebase" "Old" "Retry") with state = Retryable };
    Ops.save ~path { (save_title "submitted-rebase" "Retry" "Submit") with state = Submitted };
    ignore (reset_conn conn (base_db "Old"));
    Runtime.rebase runtime ~server_t:42 ~operation_ids:[];
    assert_bool "retryable and submitted operations both participate in rebase"
      (String.equal (title (Runtime.db runtime)) "Submit"))
;;

let () =
  let path = Filename.temp_file "logseq-chat-runtime-status" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      let db =
        base_db "Task"
        |> db_with
             [ Add (Entity_id 20, "block/uuid", Uuid "status-todo")
             ; Add (Entity_id 20, "db/ident", Keyword "logseq.property/status.todo")
             ; Add (Entity_id 20, "block/title", String "Todo")
             ; Add (Entity_id 21, "block/uuid", Uuid "status-doing")
             ; Add (Entity_id 21, "db/ident", Keyword "logseq.property/status.doing")
             ; Add (Entity_id 21, "block/title", String "Doing")
             ; Add (Entity_id 10, "logseq.property/status", Ref 20)
             ]
      in
      let block_eid = Option.get (entid db "block/uuid" (Uuid "block")) in
      let todo_eid = Option.get (entid db "block/uuid" (Uuid "status-todo")) in
      assert_bool "authoritative status ref exists"
        (datoms db Eavt ~e:block_eid ~a:"logseq.property/status" ~v:(Ref todo_eid) ()
         |> Seq.exists (fun _ -> true));
      assert_bool "authoritative entity exposes one status ref"
        (match entity db (Lookup_ref ("block/uuid", Uuid "block")) with
         | Some entity ->
           Datascript.Entity.entity_attr_raw entity "logseq.property/status"
           = Some (One_value (Ref todo_eid))
         | None -> false);
      let runtime = Runtime.create ~path ~server_t:42 (conn_from_db db) in
      let operation =
        Ops.
          { operation_id = "op-status"
          ; base_t = 42
          ; state = Queued
          ; intent =
              Set_property
                { uuid = "block"
                ; attr = "logseq.property/status"
                ; expected = Some (Ref_uuid "status-todo")
                ; value = Some (Ref_uuid "status-doing")
                }
          }
      in
      (match Logseq_chat_pending_projection.compile db operation.intent with
       | Ok _ -> ()
       | Error message -> fail ("status projection did not compile: " ^ message));
      (match Runtime.stage runtime operation with
       | Ok () -> ()
       | Error message -> fail ("status operation did not stage: " ^ message));
      assert_bool "projected block immediately exposes the pending status"
        (match Runtime.blocks runtime with
         | [ block ] ->
           Option.map
             (fun (status : Logseq_chat_model.status) -> status.uuid)
             block.status
           = Some "status-doing"
         | _ -> false))
;;

let encrypt_test_title value = Ok ("enc:" ^ value)

let rec transit_strings = function
  | Transit.String value -> [ value ]
  | Transit.Array values | Transit.List values | Transit.Set values ->
    List.concat_map transit_strings values
  | Transit.Map entries ->
    List.concat_map
      (fun (key, value) -> transit_strings key @ transit_strings value)
      entries
  | Transit.Tagged (_, value) -> transit_strings value
  | _ -> []
;;

let () =
  let path = Filename.temp_file "logseq-chat-runtime-encrypted" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      let conn = conn_from_db (base_db "Old") in
      let runtime =
        Runtime.create
          ~encrypt_title:encrypt_test_title
          ~path
          ~server_t:42
          conn
      in
      let operation = save_title "encrypted-title" "Old" "Pending" in
      (match Runtime.prepare_sync runtime operation with
       | Ok ("save-block", wire) ->
         let strings = Transit.of_string wire |> transit_strings in
         assert_bool "wire encrypts protected title values"
           (List.mem "enc:Pending" strings);
         assert_bool "wire does not leak protected plaintext title values"
           (not (List.mem "Old" strings) && not (List.mem "Pending" strings))
       | Ok _ -> fail "encrypted save changed operation metadata"
       | Error message -> fail ("encrypted save preparation failed: " ^ message));
      (match Runtime.stage runtime operation with
       | Ok () -> ()
       | Error message -> fail ("encrypted save stage failed: " ^ message));
      assert_bool "encrypted graph projection remains plaintext"
        (String.equal (title (Runtime.db runtime)) "Pending");
      assert_bool "encrypted graph reader uses local plaintext"
        (match Runtime.blocks runtime with
         | [ block ] -> String.equal block.Logseq_chat_model.title "Pending"
         | _ -> false);
      assert_bool "pending SQLite operation remains plaintext"
        (match Ops.list ~path with
         | [ { intent = Save_title { expected_title; title; _ }; _ } ] ->
           String.equal expected_title "Old" && String.equal title "Pending"
         | _ -> false))
;;

let () =
  let path = Filename.temp_file "logseq-chat-runtime-encrypted-merge" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      let db =
        base_db "Old"
        |> db_with
             [ Add (Entity_id 11, "block/uuid", Uuid "previous")
             ; Add (Entity_id 11, "block/title", String "Hello")
             ; Add (Entity_id 11, "block/page", Ref 1)
             ; Add (Entity_id 11, "block/parent", Ref 1)
             ; Add (Entity_id 11, "block/order", String "Zz")
             ; Add (Entity_id 11, "block/created-at", Int 0)
             ; Add (Entity_id 11, "block/updated-at", Int 0)
             ]
      in
      let runtime =
        Runtime.create
          ~encrypt_title:encrypt_test_title
          ~path
          ~server_t:42
          (conn_from_db db)
      in
      let operation =
        Ops.
          { operation_id = "encrypted-merge"
          ; base_t = 42
          ; state = Queued
          ; intent =
              Merge_backward
                { uuid = "block"
                ; expected_title = "Old"
                ; title = " World"
                ; previous_uuid = "previous"
                ; expected_previous_title = "Hello"
                ; merged_title = None
                }
          }
      in
      (match Runtime.prepare_sync runtime operation with
       | Ok ("merge-blocks", wire) ->
         let strings = Transit.of_string wire |> transit_strings in
         assert_bool "merge wire encrypts the completed title once"
           (List.mem "enc:Hello World" strings)
       | Ok _ -> fail "encrypted merge changed operation metadata"
       | Error message -> fail ("encrypted merge preparation failed: " ^ message));
      (match Runtime.stage runtime operation with
       | Ok () -> ()
       | Error message -> fail ("encrypted merge stage failed: " ^ message));
      let previous_title =
        match entity (Runtime.db runtime) (Lookup_ref ("block/uuid", Uuid "previous")) with
        | Some entity ->
          (match entity_attr entity "block/title" with
           | Some (One_value (String value)) -> value
           | _ -> "")
        | None -> ""
      in
      assert_bool "encrypted merge keeps the completed local title plaintext"
        (String.equal previous_title "Hello World");
      assert_bool "encrypted merge deletes the source in the projection"
        (Option.is_none (entid (Runtime.db runtime) "block/uuid" (Uuid "block"))))
;;

let () =
  let path = Filename.temp_file "logseq-chat-today-journal" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      let conn = conn_from_db (empty_db ~schema ()) in
      let now = int_of_float (Unix.gettimeofday () *. 1000.0) in
      let today = Logseq_chat_model.journal_day_for_ms now in
      let runtime = Runtime.create ~auto_create_today:true ~path ~server_t:42 conn in
      let expected_page =
        match Runtime.journal_page_uuid runtime ~journal_day:today with
        | Some uuid -> uuid
        | None -> fail "opening a graph creates today's journal"
      in
      let expected_journal_uuid =
        Printf.sprintf
          "00000001-%04d-%04d-0000-000000000000"
          (today / 10_000)
          (today mod 10_000)
      in
      assert_bool "today's journal uses Logseq's canonical UUID"
        (String.equal expected_page expected_journal_uuid);
      assert_bool "a new journal contains one editable empty block"
        (match Runtime.blocks_for_page runtime expected_page with
         | [ block ] -> String.equal block.Logseq_chat_model.title ""
         | _ -> false);
      assert_bool "today's journal is one pending atomic operation"
        (List.length (Runtime.pending_operations runtime) = 1);
      let reopened = Runtime.create ~auto_create_today:true ~path ~server_t:42 conn in
      assert_bool "reopening does not duplicate today's journal operation"
        (List.length (Runtime.pending_operations reopened) = 1
         && List.length (Runtime.blocks_for_page reopened expected_page) = 1))
;;

let () =
  let path = Filename.temp_file "logseq-chat-existing-today-journal" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      let now = int_of_float (Unix.gettimeofday () *. 1000.0) in
      let today = Logseq_chat_model.journal_day_for_ms now in
      let db =
        empty_db ~schema ()
        |> db_with
             [ Add (Entity_id 1, "block/uuid", Uuid "existing-today")
             ; Add (Entity_id 1, "block/title", String "Today")
             ; Add (Entity_id 1, "block/name", String "today")
             ; Add (Entity_id 1, "block/journal-day", Int today)
             ]
      in
      let runtime = Runtime.create ~auto_create_today:true ~path ~server_t:42 (conn_from_db db) in
      assert_bool "an authoritative today journal is not recreated"
        (Runtime.journal_page_uuid runtime ~journal_day:today = Some "existing-today"
         && Runtime.pending_operations runtime = []))
;;

let () =
  let path = Filename.temp_file "logseq-chat-partial-today-journal" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Logseq_chat_graph_store.prepare_staging path;
      let conn = conn_from_db (empty_db ~schema ()) in
      let runtime = Runtime.create ~auto_create_today:true ~path ~server_t:42 conn in
      let operation, page_uuid, block_uuid, title, journal_day =
        match Ops.list ~path with
        | [ ({ intent = Create_journal { page_uuid; block_uuid; title; journal_day; _ }; _ }
              as operation) ] ->
          operation, page_uuid, block_uuid, title, journal_day
        | _ -> fail "today journal operation is missing"
      in
      assert_bool "today journal transport is accepted"
        (Runtime.stage runtime { operation with state = Accepted 43 } = Ok ());
      let page_only =
        empty_db ~schema ()
        |> db_with
             [ Add (Entity_id 1, "block/uuid", Uuid page_uuid)
             ; Add (Entity_id 1, "block/title", String title)
             ; Add (Entity_id 1, "block/name", String (String.lowercase_ascii title))
             ; Add (Entity_id 1, "block/journal-day", Int journal_day)
             ]
      in
      ignore (reset_conn conn page_only);
      Runtime.rebase runtime ~server_t:43 ~operation_ids:[];
      assert_bool "accepted partial journal remains pending until its first block arrives"
        (List.length (Ops.list ~path) = 1);
      assert_bool "accepted partial journal keeps its first block visible"
        (match Runtime.blocks_for_page runtime page_uuid with
         | [ block ] -> String.equal block.Logseq_chat_model.uuid block_uuid
         | _ -> false))
;;
