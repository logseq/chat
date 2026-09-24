(* Headless drive scenarios: mount the real chat app (reducer + view)
   against drive's recording backend and replay .drive scripts from
   shared/test/logseq_chat/drive/. A small host stub answers the app's
   pending_effects with canned projections — the same responses the
   native bridge would deliver — so UI-driven flows run end to end on
   Linux in microseconds. *)

let scenarios_dir = "logseq_chat/drive"

let ios_profile () =
  Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost

let graph_entry id name encrypted =
  { Model.id; name; is_encrypted = encrypted; is_ready = true }

let catalog_projection graphs =
  { (App_test.empty_core_projection ()) with Model.graphs }

let journal_rows =
  [
    (App_test.journal_outline_row "journal-block-1" "journal"
       "First seeded block" "Today" 20260828 0
    |> fun (row : Model.outline_row) -> { row with has_children = true });
    App_test.journal_outline_row "journal-block-2" "journal"
      "Second seeded block" "Today" 20260828 1;
  ]

let graph_projection ~graph_id ~graph_name ~encrypted ~unlocked graphs =
  {
    (App_test.empty_core_projection ()) with
    Model.graph_name = Some graph_name;
    selected_graph_id = Some graph_id;
    graphs;
    is_graph_encrypted = encrypted;
    is_graph_unlocked = unlocked;
    journal_outliner_rows = journal_rows;
    outliner_rows = journal_rows;
  }

type host = { mutable graphs : Model.graph list }

let host_responses host model =
  let find_graph id =
    List.find_opt (fun (g : Model.graph) -> g.id = id) host.graphs
  in
  List.concat_map
    (fun eff ->
      let resolved = [ Model.ResolveEffect (Model.effect_id eff, true, "") ] in
      match eff with
      | Model.RefreshGraphsEffect id ->
        Model.DequeueEffect id
        :: Model.ApplyLocalGraphIds
             (List.map (fun (g : Model.graph) -> g.id) host.graphs)
        :: Model.ApplyCoreSnapshot (catalog_projection host.graphs)
        :: resolved
      | Model.CreateGraphEffect (id, name, encrypted) ->
        let graph = graph_entry name name encrypted in
        host.graphs <- host.graphs @ [ graph ];
        Model.DequeueEffect id
        :: Model.ApplyLocalGraphIds
             (List.map (fun (g : Model.graph) -> g.id) host.graphs)
        :: Model.ApplyCoreSnapshot
             (graph_projection ~graph_id:name ~graph_name:name ~encrypted
                ~unlocked:(not encrypted) host.graphs)
        :: resolved
      | Model.SearchNodesEffect (id, query) ->
        Model.DequeueEffect id
        :: Model.ApplySearchResults
             (query
             , [
               {
                 Model.hit_uuid = "page-1";
                 hit_title = "Alpha Doc";
                 breadcrumb = "";
                 breadcrumbs = [];
                 is_page = true;
               };
               {
                 Model.hit_uuid = "block-1";
                 hit_title = "alpha block";
                 breadcrumb = "Alpha Doc";
                 breadcrumbs = [ { Model.uuid = "page-1"; title = "Alpha Doc" } ];
                 is_page = false;
               };
             ])
        :: resolved
      | Model.DeleteLocalGraphEffect (id, graph_id) ->
        host.graphs <-
          List.filter (fun (g : Model.graph) -> g.id <> graph_id) host.graphs;
        Model.DequeueEffect id
        :: Model.ApplyLocalGraphIds
             (List.map (fun (g : Model.graph) -> g.id) host.graphs)
        :: Model.ApplyCoreSnapshot (catalog_projection host.graphs)
        :: resolved
      | Model.TapOutlinerBlockEffect (id, uuid) -> (
        match
          Option.map find_graph model.Model.selected_graph_id |> Option.join
        with
        | Some g ->
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               {
                 (graph_projection ~graph_id:g.id ~graph_name:g.name
                    ~encrypted:g.is_encrypted ~unlocked:(not g.is_encrypted)
                    host.graphs)
                 with
                 projection_outliner_editing =
                   Some
                     {
                       Model.editing_uuid = uuid;
                       editing_title = "";
                       caret_utf16_offset = 0;
                     };
               }
          :: resolved
        | None -> Model.DequeueEffect id :: resolved)
      | Model.OpenGraphEffect (id, graph_id) -> (
        match find_graph graph_id with
        | Some g ->
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               (graph_projection ~graph_id:g.id ~graph_name:g.name
                  ~encrypted:g.is_encrypted ~unlocked:(not g.is_encrypted)
                  host.graphs)
          :: resolved
        | None ->
          [
            Model.DequeueEffect id;
            Model.ResolveEffect (id, false, "unknown graph");
          ])
      | Model.UnlockGraphEffect (id, _) -> (
        match
          Option.map find_graph model.Model.selected_graph_id
          |> Option.join
        with
        | Some g ->
          Model.DequeueEffect id
          :: Model.ApplyCoreSnapshot
               (graph_projection ~graph_id:g.id ~graph_name:g.name
                  ~encrypted:g.is_encrypted ~unlocked:true host.graphs)
          :: resolved
        | None -> Model.DequeueEffect id :: resolved)
      | eff ->
        [
          Model.DequeueEffect (Model.effect_id eff);
          Model.ResolveEffect (Model.effect_id eff, true, "");
        ])
    model.Model.pending_effects

let mount ~profile () =
  let host = { graphs = [] } in
  let self = ref None in
  let drain () =
    match !self with
    | None -> []
    | Some s -> host_responses host (Drive.Session.read_model s)
  in
  let session =
    Drive.Session.mount ~profile ~drain
      ~registry:(View.extension_registry ())
      ~initial:(Model.initial ()) ~reducer:Model.update ~view:View.chat_view
      ()
  in
  self := Some session;
  session

let read_file path =
  let channel = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let scenario_names () =
  Sys.readdir scenarios_dir |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".drive")
  |> List.sort String.compare

let run_scenario name () =
  let session = mount ~profile:(ios_profile ()) () in
  let failures =
    Drive.Scenario.run
      (Drive.Session.driver session)
      (read_file (Filename.concat scenarios_dir name))
  in
  Drive.Session.dispose session;
  let messages =
    List.map
      (fun (f : Drive.Scenario.failure) ->
        Printf.sprintf "line %d: %s" f.line f.message)
      failures
  in
  Alcotest.(check (list string)) name [] messages

let cases =
  List.map
    (fun name -> Alcotest.test_case name `Quick (run_scenario name))
    (scenario_names ())
