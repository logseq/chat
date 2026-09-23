let () =
  Alcotest.run "logseq-chat"
    [
      "asset_files", Asset_files_test.cases;
      "edn", Edn_test.cases;
      "fractional_order", Fractional_order_test.cases;
      "live_sync", Live_sync_test.cases;
      "lui_host_update", Lui_host_update_test.cases;
      "lui_projection", Lui_projection_test.cases;
      "lui_snapshot", Lui_snapshot_test.cases;
      "markup", Markup_test.cases;
      "flashcards", Flashcards_test.cases;
      "mobile_session", Mobile_session_test.cases;
      "outliner", Outliner_test.cases;
      "snapshot", Snapshot_test.cases;
      "sync_checkpoint", Sync_checkpoint_test.cases;
      "sync_state", Sync_state_test.cases;
    ]
