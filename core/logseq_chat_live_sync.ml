(* Live verification of graph create/download, outliner tx/batch, and asset
   upload against a local db-sync server. Not part of the default test alias. *)

module Api = Logseq_chat_api
module Http = Logseq_chat_http
module Bootstrap = Logseq_chat_graph_bootstrap
module Session = Logseq_chat_sync_session
module Store = Logseq_chat_graph_store
module Runtime = Logseq_chat_graph_runtime
module Ops = Logseq_chat_pending_ops
module LG = Logseq_chat_lg_core_native

let contents_page_uuid = "00000004-1690-2597-3200-000000000000"

let env name =
  match Sys.getenv_opt name with
  | Some value when not (String.equal (String.trim value) "") -> String.trim value
  | Some _ | None -> failwith ("missing required environment variable " ^ name)
;;

let env_default name default = Option.value (Sys.getenv_opt name) ~default

let fail step message =
  failwith (Printf.sprintf "%s: %s" step message)
;;

let require step = function
  | Ok value -> value
  | Error message -> fail step message
;;

let json_assoc body =
  match Yojson.Basic.from_string body with
  | `Assoc fields -> fields
  | _ -> failwith ("expected a JSON object: " ^ body)
  | exception Yojson.Json_error message -> failwith ("invalid JSON: " ^ message)
;;

let json_string name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | _ -> None
;;

let json_int name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Some value
  | Some (`Float value) -> Some (int_of_float value)
  | _ -> None
;;

let send request =
  match Http.send request with
  | Error message -> Error message
  | Ok response -> Ok response
;;

let expect step ?(ok = [ 200 ]) request =
  match send request with
  | Error message -> fail step message
  | Ok response when List.mem response.Api.status ok -> response
  | Ok response ->
    fail
      step
      (Printf.sprintf "HTTP %d %s" response.status response.body)
;;

let config ~base_url ~token ~graph_id =
  Api.{ base_url; graph_id; graph_name = None; token }
;;

let write_temp prefix contents =
  let path = Filename.temp_file prefix ".bin" in
  let channel = open_out_bin path in
  output_string channel contents;
  close_out channel;
  path
;;

let rm_tree path =
  let rec loop path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> loop (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  try loop path with
  | _ -> ()
;;

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> rm_tree path) (fun () -> f path)
;;

let fresh_uuid () =
  match Datascript.squuid () with
  | Datascript.Uuid uuid -> uuid
  | _ -> failwith "Datascript.squuid returned a non-UUID value"
;;

let absolute_url ~base_url url =
  if String.length url >= 7
     && (String.equal (String.sub url 0 7) "http://"
         || (String.length url >= 8 && String.equal (String.sub url 0 8) "https://"))
  then url
  else if String.length url > 0 && url.[0] = '/'
  then Api.api_root { Api.base_url; graph_id = ""; graph_name = None; token = "" } ^ url
  else url
;;

let merge_pull_cursor metadata pull_body =
  try
    match Yojson.Basic.from_string pull_body with
    | `Assoc fields ->
      (match json_string "type" fields, json_int "t" fields with
       | Some "pull/ok", Some t -> { metadata with Session.baseline_t = t }
       | _ -> metadata)
    | _ -> metadata
  with
  | _ -> metadata
;;

let download_snapshot cfg =
  let graph_config = cfg in
  let metadata_response =
    expect
      "snapshot metadata"
      { Api.method_ = "GET"
      ; url =
          Printf.sprintf
            "%s/sync/%s/snapshot/download"
            (Api.api_root graph_config)
            (Api.url_encode graph_config.graph_id)
      ; body = None
      ; token = graph_config.token
      }
  in
  let metadata = require "decode snapshot metadata" (Session.decode_snapshot_metadata metadata_response.body) in
  let pull_response =
    expect
      "snapshot pull"
      { Api.method_ = "GET"
      ; url =
          Printf.sprintf
            "%s/sync/%s/pull"
            (Api.api_root graph_config)
            (Api.url_encode graph_config.graph_id)
      ; body = None
      ; token = graph_config.token
      }
  in
  let metadata = merge_pull_cursor metadata pull_response.body in
  let stream_url = absolute_url ~base_url:graph_config.base_url metadata.url in
  let stream =
    expect
      "snapshot stream"
      { Api.method_ = "GET"; url = stream_url; body = None; token = graph_config.token }
  in
  if String.equal stream.body "" then fail "snapshot stream" "empty snapshot body";
  metadata, write_temp "logseq-chat-live-snapshot" stream.body
;;

let import_downloaded ~graph_id ~decrypt ~dir metadata download_path =
  let active_path = Filename.concat dir "graph.sqlite" in
  let checkpoint_path = Filename.concat dir "sync.checkpoint" in
  let completed =
    require
      "import snapshot"
      (Session.import_snapshot_file
         ?decrypt_protected:decrypt
         ~graph_id
         ~active_path
         ~checkpoint_path
         ~metadata
         ~download_path
         ())
  in
  ignore completed;
  active_path
;;

let titles db ~decrypt =
  Datascript.datoms db Datascript.Aevt ~a:"block/title" ()
  |> List.of_seq
  |> List.filter_map (fun datom ->
    match datom.Datascript.v with
    | Datascript.String value ->
      (match decrypt value with
       | Ok title -> Some title
       | Error _ -> Some value)
    | _ -> None)
;;

let has_title db ~decrypt expected =
  List.exists (String.equal expected) (titles db ~decrypt)
;;

let rec submit_tx ~cfg runtime operation attempts =
  if attempts <= 0 then fail "tx/batch" "exhausted retries after stale cursor";
  match Runtime.prepare_sync runtime operation with
  | Error message -> fail "prepare outliner op" message
  | Ok (outliner_op, tx) ->
    let request =
      Api.tx_batch_request
        cfg
        ~t_before:runtime.Runtime.server_t
        ~tx_id:operation.Ops.operation_id
        ~outliner_op
        ~tx
    in
    let response = expect "tx/batch" ~ok:[ 200; 409 ] request in
    let fields = json_assoc response.body in
    (match json_string "type" fields, json_int "t" fields, json_string "reason" fields with
     | Some "tx/batch/ok", Some t, _ ->
       Runtime.rebase runtime ~server_t:t ~operation_ids:[ operation.operation_id ];
       t
     | Some "tx/reject", Some t, Some "stale" ->
       Runtime.rebase runtime ~server_t:t ~operation_ids:[];
       submit_tx ~cfg runtime operation (attempts - 1)
     | _ ->
       fail
         "tx/batch"
         (Printf.sprintf "unexpected response HTTP %d %s" response.status response.body))
;;

let stage_insert runtime ~page_uuid ~title =
  let created_at = Api.epoch_ms () in
  let order = require "fractional order" (LG.logseq_chat_fractional_order_between None None) in
  let operation =
    Ops.
      { operation_id = fresh_uuid ()
      ; base_t = runtime.Runtime.server_t
      ; state = Queued
      ; intent =
          Insert_block
            { uuid = fresh_uuid ()
            ; title
            ; page_uuid
            ; parent_uuid = page_uuid
            ; order
            ; created_at
            }
      }
  in
  require "stage insert" (Runtime.stage runtime operation);
  operation
;;

let stage_asset runtime ~page_uuid ~title ~asset_type ~asset_size ~asset_checksum =
  let created_at = Api.epoch_ms () in
  let order = require "asset order" (LG.logseq_chat_fractional_order_between (Some "a0") None) in
  let uuid = fresh_uuid () in
  let operation =
    Ops.
      { operation_id = fresh_uuid ()
      ; base_t = runtime.Runtime.server_t
      ; state = Queued
      ; intent =
          Create_asset
            { uuid
            ; title
            ; page_uuid
            ; parent_uuid = page_uuid
            ; order
            ; created_at
            ; asset_type
            ; asset_size
            ; asset_checksum
            }
      }
  in
  require "stage asset" (Runtime.stage runtime operation);
  uuid, operation
;;

let ensure_user_keys cfg =
  let request =
    { Api.method_ = "POST"
    ; url = Printf.sprintf "%s/e2ee/user-keys" (Api.api_root cfg)
    ; body =
        Some
          (Yojson.Basic.to_string
             (`Assoc
               [ "public-key", `String "live-sync-public-key"
               ; "encrypted-private-key", `String "live-sync-encrypted-private-key"
               ]))
    ; token = cfg.token
    }
  in
  ignore (expect "e2ee user keys" ~ok:[ 200; 201 ] request)
;;

let provision_graph_key cfg =
  let request = Api.upsert_graph_key_request cfg ~encrypted_key:"live-sync-encrypted-aes-key" in
  ignore (expect "e2ee graph aes key" ~ok:[ 200; 201 ] request)
;;

let create_and_upload cfg ~name ~e2ee ~encrypt_text =
  let create = Api.create_graph_request cfg ~name ~schema_version:Bootstrap.schema_version ~e2ee in
  let response = expect "create graph" ~ok:[ 200; 201 ] create in
  let graph_id =
    match json_string "graph-id" (json_assoc response.body) with
    | Some graph_id -> graph_id
    | None -> fail "create graph" ("missing graph-id in " ^ response.body)
  in
  let graph_cfg = { cfg with graph_id } in
  if e2ee then provision_graph_key graph_cfg;
  let prepared = require "prepare initial snapshot" (Bootstrap.prepare ~graph_id ~e2ee ~encrypt_text) in
  let upload =
    Api.initial_snapshot_upload_request graph_cfg ~file_path:prepared.file_path ~checksum:prepared.checksum
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove prepared.file_path with _ -> ())
    (fun () ->
      match Http.upload_file upload with
      | Error message -> fail "initial snapshot upload" message
      | Ok response when response.status >= 200 && response.status < 300 -> ()
      | Ok response ->
        fail
          "initial snapshot upload"
          (Printf.sprintf "HTTP %d %s" response.status response.body));
  let listed = expect "list graphs" (Api.graphs_request graph_cfg) in
  let graphs = Api.graphs_from_graphs_body listed.body in
  (match List.find_opt (fun (graph : Api.graph) -> String.equal graph.id graph_id) graphs with
   | None -> fail "list graphs" ("created graph is missing from GET /graphs: " ^ listed.body)
   | Some graph ->
     if graph.e2ee <> e2ee then fail "list graphs" "created graph encryption flag mismatch";
     if not graph.ready then fail "list graphs" "created graph is not ready after snapshot upload");
  graph_cfg
;;

let upload_asset_file cfg ~uuid ~asset_type ~checksum ~bytes ~content_type =
  let path = write_temp "logseq-chat-live-asset" bytes in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      let upload =
        Api.raw_asset_upload_request
          cfg
          ~uuid
          ~asset_type
          ~checksum
          ~file_path:path
          ~content_type
      in
      match Http.upload_file upload with
      | Error message -> fail "asset upload" message
      | Ok response when response.status >= 200 && response.status < 300 -> ()
      | Ok response ->
        fail "asset upload" (Printf.sprintf "HTTP %d %s" response.status response.body))
;;

let download_asset cfg ~uuid ~asset_type =
  expect
    "asset download"
    { Api.method_ = "GET"
    ; url =
        Printf.sprintf
          "%s/assets/%s/%s.%s"
          (Api.api_root cfg)
          (Api.url_encode cfg.graph_id)
          (Api.url_encode uuid)
          (Api.url_encode asset_type)
    ; body = None
    ; token = cfg.token
    }
;;

let run_mode ~base_url ~token ~e2ee =
  let label = if e2ee then "encrypted" else "unencrypted" in
  Printf.printf "==> %s graph create / download / outliner / asset\n%!" label;
  let encrypt_text value = if e2ee then Ok ("enc:" ^ value) else Ok value in
  let decrypt value =
    if e2ee
    then
      let prefix = "enc:" in
      if String.length value >= 4 && String.equal (String.sub value 0 4) prefix
      then Ok (String.sub value 4 (String.length value - 4))
      else Ok value
    else Ok value
  in
  let cfg = config ~base_url ~token ~graph_id:"" in
  if e2ee then ensure_user_keys cfg;
  let name =
    Printf.sprintf
      "live-%s-%d"
      (if e2ee then "enc" else "plain")
      (int_of_float (Unix.gettimeofday () *. 1000.0))
  in
  let cfg = create_and_upload cfg ~name ~e2ee ~encrypt_text in
  let metadata, download_path = download_snapshot cfg in
  Fun.protect
    ~finally:(fun () -> try Sys.remove download_path with _ -> ())
    (fun () ->
      with_temp_dir "logseq-chat-live-import" (fun dir ->
        let decrypt_protected = if e2ee then Some decrypt else None in
        let active_path =
          import_downloaded
            ~graph_id:cfg.graph_id
            ~decrypt:decrypt_protected
            ~dir
            metadata
            download_path
        in
        let conn = require "restore graph" (Store.restore_conn ~path:active_path) in
        let runtime =
          Runtime.create
            ~encrypt_title:encrypt_text
            ~path:active_path
            ~server_t:metadata.baseline_t
            conn
        in
        let db = Datascript.conn_db conn in
        if Option.is_none (Datascript.entid db "block/uuid" (Datascript.Uuid contents_page_uuid))
        then fail "import snapshot" "Contents page is missing after snapshot import";
        let block_title = "live-outliner-" ^ label in
        let insert = stage_insert runtime ~page_uuid:contents_page_uuid ~title:block_title in
        ignore (submit_tx ~cfg runtime insert 4);
        let asset_bytes = "live-asset-" ^ label in
        let asset_type = "png" in
        let checksum = Digest.to_hex (Digest.string asset_bytes) in
        let asset_title = "live-asset-" ^ label ^ ".png" in
        let asset_uuid, asset_op =
          stage_asset
            runtime
            ~page_uuid:contents_page_uuid
            ~title:asset_title
            ~asset_type
            ~asset_size:(String.length asset_bytes)
            ~asset_checksum:checksum
        in
        upload_asset_file
          cfg
          ~uuid:asset_uuid
          ~asset_type
          ~checksum
          ~bytes:asset_bytes
          ~content_type:(if e2ee then "text/plain" else Api.content_type_for_asset_type asset_type);
        ignore (submit_tx ~cfg runtime asset_op 4);
        let downloaded = download_asset cfg ~uuid:asset_uuid ~asset_type in
        if not (String.equal downloaded.body asset_bytes)
        then
          fail
            "asset download"
            (Printf.sprintf "expected %S, got %S" asset_bytes downloaded.body);
        let capture_title = "live-capture-" ^ label in
        let capture =
          Api.capture_request
            ~page_id:contents_page_uuid
            cfg
            ~uuid:(fresh_uuid ())
            (if e2ee then require "encrypt capture" (encrypt_text capture_title) else capture_title)
        in
        ignore (expect "semantic capture" ~ok:[ 200; 201 ] capture);
        let metadata, second_path = download_snapshot cfg in
        Fun.protect
          ~finally:(fun () -> try Sys.remove second_path with _ -> ())
          (fun () ->
            with_temp_dir "logseq-chat-live-verify" (fun verify_dir ->
              let verify_path =
                import_downloaded
                  ~graph_id:cfg.graph_id
                  ~decrypt:decrypt_protected
                  ~dir:verify_dir
                  metadata
                  second_path
              in
              let verify_db = require "restore verified graph" (Store.restore_db ~path:verify_path) in
              if not (has_title verify_db ~decrypt block_title)
              then fail "verify outliner sync" ("missing block title after re-download: " ^ block_title);
              if not (has_title verify_db ~decrypt asset_title)
              then fail "verify asset block" ("missing asset title after re-download: " ^ asset_title);
              if not (has_title verify_db ~decrypt capture_title)
              then fail "verify capture sync" ("missing capture title after re-download: " ^ capture_title);
              Printf.printf
                "ok %s graph_id=%s t=%d\n%!"
                label
                cfg.graph_id
                metadata.baseline_t))))
;;

let () =
  let token = env "LOGSEQ_CHAT_LIVE_TOKEN" in
  let base_url = env_default "LOGSEQ_CHAT_LIVE_BASE_URL" "http://127.0.0.1:8787" in
  run_mode ~base_url ~token ~e2ee:false;
  run_mode ~base_url ~token ~e2ee:true;
  print_endline "live sync flows passed"
;;
