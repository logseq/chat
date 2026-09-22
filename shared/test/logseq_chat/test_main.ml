let () =
  Alcotest.run "logseq-chat"
    [
      "asset_files", Asset_files_test.cases;
      "edn", Edn_test.cases;
      "live_sync", Live_sync_test.cases;
      "lui_projection", Lui_projection_test.cases;
      "snapshot", Snapshot_test.cases;
      "sync_checkpoint", Sync_checkpoint_test.cases;
      "sync_state", Sync_state_test.cases;
    ]
