open Test_util
open Outliner

let block uuid title : outliner_block =
  {
    uuid;
    title;
    page_uuid = "page";
    parent_uuid = "page";
    order = "a0";
  }

let split_request () : split_command =
  {
    source_uuid = "source";
    expected_title = "title";
    before = "before";
    after = "after";
    new_uuid = "new";
    new_order = "a1";
    created_at = 42;
  }

let merge_request () : merge_backward_command =
  {
    source_uuid = "source";
    expected_source_title = "source title";
    source_title = "source title";
    previous_uuid = "previous";
    expected_previous_title = "previous title";
    merged_title = None;
  }

let plan blocks children command =
  Outliner.plan
    (fun uuid ->
       List.find_opt
         (fun (block : outliner_block) -> block.uuid = uuid)
         blocks)
    (fun _ -> children)
    command

let split_plans_an_atomic_title_update_and_sibling_insert () =
  let request =
    { (split_request ()) with expected_title = "hello world"; before = "hello"; after = " world" }
  in
  check_eq
    (Ok
       [
         Set_title { uuid = "source"; title = "hello" };
         Insert
           {
             insert_block =
               { (block "new" " world") with order = "a1" };
             created_at = 42;
           };
       ])
    (plan [ block "source" "hello world" ] [] (Split request))

let split_saves_edited_text_while_checking_the_original_title () =
  let request =
    { (split_request ()) with expected_title = "old title"; before = "edited"; after = " title" }
  in
  check
    (match plan [ block "source" "old title" ] [] (Split request) with
     | Ok _ -> true
     | Error _ -> false)

let committed_splits_are_idempotent () =
  let request =
    { (split_request ()) with expected_title = "hello world"; before = "hello"; after = " world" }
  in
  check_eq (Ok [])
    (plan
       [ block "source" "hello"; { (block "new" " world") with order = "a1" } ]
       [] (Split request))

let merge_updates_title_reparents_children_and_deletes_source_atomically () =
  let source = { (block "source" " world") with parent_uuid = "parent" } in
  let previous = { (block "previous" "hello") with parent_uuid = "parent" } in
  let child = { (block "child" "nested") with parent_uuid = "source" } in
  let request =
    { (merge_request ()) with
      expected_source_title = " world";
      source_title = " world";
      expected_previous_title = "hello";
    }
  in
  check_eq
    (Ok
       [
         Set_title { uuid = "previous"; title = "hello world" };
         Reparent
           { uuid = "child"; page_uuid = "page"; parent_uuid = "previous" };
         Delete { uuid = "source" };
       ])
    (plan [ source; previous; child ] [ child ] (Merge_backward request))

let split_rejects_conflicts_and_invalid_identities () =
  let request = split_request () in
  let source = block "source" "title" in
  check_eq (Error "split source no longer exists")
    (plan [] [] (Split request));
  List.iter
    (fun uuid ->
       check_eq (Error "split requires a distinct new block UUID")
         (plan [ source ] [] (Split { request with new_uuid = uuid })))
    [ "source"; "  " ];
  check_eq (Error "split block UUID already exists")
    (plan [ source; block "new" "existing" ] [] (Split request));
  check_eq (Error "split source title changed on the server")
    (plan [ block "source" "local" ] []
       (Split
          { request with expected_title = "remote"; before = "re"; after = "mote" }))

let merge_rejects_missing_changed_and_structurally_invalid_blocks () =
  let source = block "source" "source title" in
  let previous = block "previous" "previous title" in
  let request = merge_request () in
  check_eq (Error "merge source no longer exists")
    (plan [ previous ] [] (Merge_backward request));
  check_eq (Error "merge target no longer exists")
    (plan [ source ] [] (Merge_backward request));
  check_eq (Error "merge source and target must be different blocks")
    (plan [ source; previous ] []
       (Merge_backward { request with previous_uuid = "source" }));
  check_eq (Error "merge source title changed on the server")
    (plan [ source; previous ] []
       (Merge_backward { request with expected_source_title = "stale" }));
  check_eq (Error "merge target title changed on the server")
    (plan [ source; previous ] []
       (Merge_backward { request with expected_previous_title = "stale" }));
  check_eq (Error "merge source and target must belong to the same page")
    (plan [ source; { previous with page_uuid = "other" } ] []
       (Merge_backward request));
  check_eq (Error "merge target cannot be a child of the source")
    (plan [ source; previous ] [ previous ] (Merge_backward request));
  check_eq
    (Ok
       [
         Set_title { uuid = "previous"; title = "explicit" };
         Delete { uuid = "source" };
       ])
    (plan [ source; previous ] []
       (Merge_backward { request with merged_title = Some "explicit" }))

let cases =
  [
    case "split plans an atomic title update and sibling insert"
      split_plans_an_atomic_title_update_and_sibling_insert;
    case "split saves edited text while checking the original title"
      split_saves_edited_text_while_checking_the_original_title;
    case "committed splits are idempotent" committed_splits_are_idempotent;
    case "merge updates title reparents children and deletes source atomically"
      merge_updates_title_reparents_children_and_deletes_source_atomically;
    case "split rejects conflicts and invalid identities"
      split_rejects_conflicts_and_invalid_identities;
    case "merge rejects missing changed and structurally invalid blocks"
      merge_rejects_missing_changed_and_structurally_invalid_blocks;
  ]
