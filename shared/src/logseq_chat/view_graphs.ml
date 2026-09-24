open Lui_protocol
open Lui_elements

let graph_row (context : Lui_ui.ui_context) model_source graph_source
    _local send : t =
  let graph = (Signal.sample graph_source : Model.graph) in
  let graph_id = graph.id in
  list_item
    ~accessibility_identifier:(View_base.graph_identifier graph)
    ~padding:16 ~corner_radius:16
    ~background:
      (if Lui_ui.host context = FlutterHost then "surface-container-low"
       else "surface")
    ~disabled_signal:
      (Signal.map2 View_base.graph_row_disabled_ model_source
         graph_source)
    ~on_press:(fun _ ->
      ignore
        (send
           (Model.RequestOpenGraph
              graph.id)))
    [
      column ~gap:4 ~grow:1.0
        [
          text ~style_class:"semibold"
            ~value_signal:(Signal.map View_base.graph_title graph_source)
            [];
          if_
            ~test:(Signal.map View_base.graph_status_visible_ graph_source)
            (text
               ~value_signal:
                 (Signal.map View_base.graph_status_title graph_source)
               ~style_class:"caption" ~foreground:"muted-foreground"
               ~accessibility_identifier:
                 (View_base.graph_status_identifier graph)
               []);
        ];
      context_menu
        ~accessibility_identifier:(View_base.graph_delete_identifier graph)
        [
          if_
            ~test:
              (Signal.map2 View_base.graph_row_local_ model_source
                 graph_source)
            (View_base.with_string_prop VariantValue "destructive"
              (menu_item ~icon:(`app "trash")
               ~disabled_signal:
                 (Signal.map2 View_base.graph_delete_active_ model_source
                    graph_source)
               ~text:"Delete local graph"
               ~on_press:(fun _ ->
                 ignore (send (Model.RequestDeleteGraph graph_id)))
               []));
        ];
    ]

let graph_list_row (context : Lui_ui.ui_context) model_source graph_source
    local send : t =
  let graph = (Signal.sample graph_source : Model.graph) in
  let graph_id = graph.id in
  View_base.with_string_prop_signal InlineIconName
    (Signal.map
       (fun (current_graph : Model.graph) ->
         if
           Lui_ui.host context <> FlutterHost
           && (not local) && current_graph.is_encrypted
         then "app:graph-locked"
         else View_base.graph_icon_name local current_graph)
       graph_source)
    (list_item
       ~min_height:(if Lui_ui.host context = FlutterHost then 56 else 44)
       ~accessibility_identifier:(View_base.graph_identifier graph)
       ~disabled_signal:
         (if local then
            Signal.map2 View_base.graph_delete_active_ model_source
              graph_source
          else
            Signal.map2 View_base.graph_row_disabled_ model_source
              graph_source)
       ~on_press:(fun _ ->
         ignore
           (send
              (Model.RequestOpenGraph
                 graph.id)))
       [
         column ~gap:4
           [
             text
               ~value_signal:
                 (Signal.map View_base.graph_title graph_source)
               [];
             if_
               ~test:
                 (Signal.map View_base.graph_not_ready_ graph_source)
               (text ~style_class:"caption" ~foreground:"muted-foreground"
                  ~accessibility_identifier:
                    (View_base.graph_status_identifier graph)
                  ~value:"Preparing" []);
             if_
               ~test:
                 (Signal.map
                    (fun (current_graph : Model.graph) ->
                      Lui_ui.host context = FlutterHost
                      && current_graph.is_encrypted)
                    graph_source)
               (text ~style_class:"caption"
                  ~foreground:"muted-foreground" ~value:"Encrypted" []);
           ];
         context_menu
           ~accessibility_identifier:
             (View_base.graph_delete_identifier graph)
           [
             if_
               ~test:
                 (Signal.map2 View_base.graph_row_local_ model_source
                    graph_source)
               (View_base.with_string_prop VariantValue "destructive"
              (menu_item
                  ~disabled_signal:
                    (Signal.map2 View_base.graph_delete_active_
                       model_source graph_source)
                  ~text:"Delete local graph"
                  ~on_press:(fun _ ->
                    ignore (send (Model.RequestDeleteGraph graph_id)))
                  []));
           ];
       ])

let graph_create_sheet (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = FlutterHost then
    sheet ~text:"Add sync graph" ~height:480
      ~accessibility_identifier:"sheet.graph-create"
      ~on_dismiss:(press send Model.DismissCreateGraph)
      [
        column ~grow:1.0 ~gap:24
          ~accessibility_identifier:"layout.graph-create.sheet"
          [
            column ~gap:20 ~cross:`stretch ~style_class:"form"
              ~accessibility_identifier:"form.graph-create"
              [
                text_field
                  ~text_signal:
                    (Signal.map View_base.model_new_graph_name
                       model_source)
                  ~placeholder:"Graph name" ~label:"Graph name"
                  ~accessibility_identifier:"field.graph-name"
                  ~on_input:
                    (on_input send (fun text ->
                         Model.ChangeNewGraphName text))
                  [];
                switch_
                  ~checked_signal:
                    (Signal.map View_base.model_new_graph_encrypted_
                       model_source)
                  ~label:"End-to-end encryption"
                  ~accessibility_identifier:"toggle.graph-encryption"
                  ~on_toggle:(fun event ->
                    match event with
                    | ToggleChanged (_node, enabled) ->
                      ignore
                        (send (Model.ToggleNewGraphEncrypted enabled))
                    | _ -> ())
                  ~text:"End-to-end encryption" [];
                text ~style_class:"footnote" ~foreground:"muted-foreground"
                  ~value:
                    "Encryption cannot be changed after the sync graph \
                     is created."
                  [];
                if_
                  ~test:
                    (Signal.map View_base.effect_error_present_
                       model_source)
                  (text
                     ~value_signal:
                       (Signal.map View_base.effect_error_message
                          model_source)
                     ~style_class:"footnote" ~foreground:"destructive"
                     ~accessibility_identifier:"text.graph-create.error"
                     []);
              ];
            spacer ~grow:1.0 [];
            row ~main:`end_ ~cross:`center
              [
                toolbar ~orientation:`horizontal ~toolbar_gap:12
                  ~label:"Graph creation actions"
                  ~accessibility_identifier:"toolbar.graph-create"
                  [
                    button ~variant:`ghost
                      ~accessibility_identifier:"button.graph-add.cancel"
                      ~on_press:(press send Model.DismissCreateGraph)
                      ~text:"Cancel" [];
                    button ~variant:`primary
                      ~accessibility_identifier:"button.graph-add.confirm"
                      ~disabled_signal:
                        (Signal.map View_base.graph_create_disabled_
                           model_source)
                      ~on_press:(press send Model.SubmitCreateGraph)
                      ~text:"Add" [];
                  ];
              ];
          ];
      ]
  else
    sheet ~text:"Add sync graph" ~style_class:"navigation-form"
      ~accessibility_identifier:"sheet.graph-create"
      ~on_dismiss:(press send Model.DismissCreateGraph)
      [
        column ~style_class:"form"
          ~accessibility_identifier:"form.graph-create"
          [
            text_field
              ~text_signal:
                (Signal.map View_base.model_new_graph_name model_source)
              ~placeholder:"Graph name" ~label:"Graph name"
              ~accessibility_identifier:"field.graph-name"
              ~on_input:
                (on_input send (fun text -> Model.ChangeNewGraphName text))
              [];
            list_item ~padding:0
              ~accessibility_identifier:"row.graph-encryption"
              ~on_press:(fun _ ->
                ignore
                  (send
                     (Model.ToggleNewGraphEncrypted
                        (not
                           (Signal.sample
                              (Signal.map
                                 View_base.model_new_graph_encrypted_
                                 model_source))))))
              [
                toggle
                  ~checked_signal:
                    (Signal.map View_base.model_new_graph_encrypted_
                       model_source)
                  ~label:"End-to-end encryption"
                  ~accessibility_identifier:"toggle.graph-encryption"
                  ~on_toggle:(fun event ->
                    match event with
                    | ToggleChanged (_node, enabled) ->
                      ignore
                        (send (Model.ToggleNewGraphEncrypted enabled))
                    | _ -> ())
                  ~text:"End-to-end encryption" [];
              ];
            text ~style_class:"footnote" ~foreground:"muted-foreground"
              ~value:
                "Encryption cannot be changed after the sync graph is \
                 created."
              [];
            if_
              ~test:(Signal.map View_base.effect_error_present_
                       model_source)
              (text
                 ~value_signal:
                   (Signal.map View_base.effect_error_message
                      model_source)
                 ~style_class:"footnote" ~foreground:"destructive"
                 ~accessibility_identifier:"text.graph-create.error" []);
          ];
        toolbar ~orientation:`horizontal ~label:"Graph creation actions"
          ~style_class:"navigation-actions"
          ~accessibility_identifier:"toolbar.graph-create"
          [
            button ~style_class:"cancellation-action"
              ~accessibility_identifier:"button.graph-add.cancel"
              ~on_press:(press send Model.DismissCreateGraph)
              ~text:"Cancel" [];
            button ~style_class:"confirmation-action"
              ~accessibility_identifier:"button.graph-add.confirm"
              ~disabled_signal:
                (Signal.map View_base.graph_create_disabled_ model_source)
              ~on_press:(press send Model.SubmitCreateGraph)
              ~text:"Add" [];
          ];
      ]

let graph_delete_dialog (context : Lui_ui.ui_context) model_source send : t
    =
  if Lui_ui.host context = FlutterHost then
    dialog ~text:"Delete local graph" ~height:320
      ~accessibility_identifier:"dialog.graph-delete"
      ~on_dismiss:(press send Model.CancelDeleteGraph)
      [
        column ~gap:16 ~cross:`stretch
          [
            row ~gap:12 ~cross:`center
              [
                icon ~name:(`app "warning") ~width:28 ~height:28
                  ~foreground:"destructive"
                  ~accessibility_identifier:"icon.graph-delete-warning" [];
                text
                  ~value_signal:
                    (Signal.map View_base.graph_deletion_message
                       model_source)
                  ~grow:1.0
                  ~accessibility_identifier:"text.graph-delete-warning"
                  [];
              ];
            text ~foreground:"muted-foreground"
              ~value:
                "This graph cannot be recovered after deletion. Make \
                 sure you have a backup."
              [];
            spacer ~grow:1.0 [];
            row ~main:`end_
              [
                toolbar ~orientation:`horizontal ~toolbar_gap:12
                  ~label:"Graph deletion actions"
                  ~accessibility_identifier:"toolbar.graph-delete"
                  [
                    button ~variant:`ghost
                      ~accessibility_identifier:
                        "button.graph-delete.cancel"
                      ~on_press:(press send Model.CancelDeleteGraph)
                      ~text:"Cancel" [];
                    button ~variant:`destructive
                      ~accessibility_identifier:
                        "button.graph-delete.confirm"
                      ~on_press:(press send Model.ConfirmDeleteGraph)
                      ~text:"Delete" [];
                  ];
              ];
          ];
      ]
  else
    dialog ~text:"Delete local graph"
      ~on_dismiss:(press send Model.CancelDeleteGraph)
      [
        column
          [
            text
              ~value_signal:
                (Signal.map View_base.graph_deletion_message model_source)
              ~accessibility_identifier:"text.graph-delete-warning" [];
            text
              ~value:
                "\xE2\x9A\xA0\xEF\xB8\x8F Notice that we can't recover \
                 this graph after being deleted. Make sure you have \
                 backups before deleting it."
              [];
            button ~on_press:(press send Model.CancelDeleteGraph)
              ~text:"Cancel" [];
            button ~on_press:(press send Model.ConfirmDeleteGraph)
              ~text:"Confirm" [];
          ];
      ]

let graph_picker_overflow_menu send : t =
 fun context parent ->
   let node = Lui_ui.extension context "native-overflow-menu" in
   attach context parent node;
   Lui_ui.extension_property context node "page-actions-visible"
     (BoolValue false);
   Lui_ui.extension_property context node "favorite-label"
     (StringValue "Favorite");
   Lui_ui.extension_property context node "settings-visible"
     (BoolValue true);
   Lui_ui.on_event context node (fun input_event ->
       ignore
         (View_base.handle_native_overflow_menu_event input_event send));
   node

let graph_picker_error_banner model_source : t =
  alert ~variant:`destructive ~accessibility_identifier:"error.banner"
    ~padding:14 ~corner_radius:16 ~border_width:0
    [
      column ~gap:4
        [
          heading ~level:5
            ~value_signal:
              (Signal.map View_base.graph_picker_error_title model_source)
            ~accessibility_identifier:"error.banner.code" [];
          text
            ~value_signal:
              (Signal.map View_base.graph_picker_error_message
                 model_source)
            ~accessibility_identifier:"error.banner.message" [];
        ];
    ]

let graph_password_sheet model_source send : t =
  sheet ~text:"Unlock encrypted graphs" ~style_class:"navigation-form"
    ~accessibility_identifier:"sheet.graph-unlock"
    ~on_dismiss:(press send Model.CancelGraphUnlock)
    [
      column ~style_class:"form"
        ~accessibility_identifier:"form.graph-unlock"
        [
          secure_field
            ~text_signal:
              (Signal.map View_base.model_graph_password model_source)
            ~placeholder:"E2EE password" ~label:"E2EE password"
            ~accessibility_identifier:"field.graph-password"
            ~on_input:
              (on_input send (fun text -> Model.ChangeGraphPassword text))
            [];
          text ~style_class:"footnote" ~foreground:"muted-foreground"
            ~value:"Enter your E2EE password to unlock this graph." [];
          if_
            ~test:
              (Signal.map View_base.graph_unlock_error_present_
                 model_source)
            (text
               ~value_signal:
                 (Signal.map View_base.graph_unlock_error_message
                    model_source)
               ~style_class:"footnote" ~foreground:"destructive"
               ~accessibility_identifier:"text.graph-unlock-error" []);
        ];
      toolbar ~orientation:`horizontal ~label:"Graph unlock actions"
        ~style_class:"navigation-actions"
        ~accessibility_identifier:"toolbar.graph-unlock"
        [
          button ~style_class:"cancellation-action"
            ~accessibility_identifier:"button.graph-unlock.cancel"
            ~on_press:(press send Model.CancelGraphUnlock)
            ~text:"Cancel" [];
          button ~style_class:"confirmation-action"
            ~accessibility_identifier:"button.graph-unlock"
            ~disabled_signal:
              (Signal.map View_base.graph_unlock_disabled_ model_source)
            ~on_press:(press send Model.SubmitGraphPassword)
            ~text:"Unlock" [];
        ];
    ]

let graphs_screen (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = FlutterHost then
    list ~accessibility_identifier:"screen.graphs" ~gap:0
      [
        row ~gap:12 ~padding:16
          ~accessibility_identifier:"row.graphs.actions"
          [
            button ~icon:(`app "sync-status") ~variant:`secondary ~grow:1.0
              ~accessibility_identifier:"button.graphs.refresh"
              ~disabled_signal:
                (Signal.map Model.graph_refresh_active_ model_source)
              ~on_press:(press send Model.RefreshGraphs)
              ~text:"Refresh" [];
            button ~icon:(`app "add") ~variant:`primary ~grow:1.0
              ~accessibility_identifier:"button.graph-add"
              ~on_press:(press send Model.OpenCreateGraph)
              ~text:"Add graph" [];
          ];
        if_
          ~test:
            (Signal.map View_base.graphs_screen_error_visible_
               model_source)
          (box ~padding:16
             [ graph_picker_error_banner model_source ]);
        if_
          ~test:(Signal.map Model.graph_refresh_active_ model_source)
          (box ~padding:16
             [ spinner ~accessibility_identifier:"graphs.loading" [] ]);
        box ~padding:16
          [ heading ~level:5 ~value:"Local graphs" [] ];
        if_
          ~test:(Signal.map View_base.local_graphs_empty_ model_source)
          (box ~padding:16
             [
               text ~foreground:"muted-foreground"
                 ~value:"No local graphs" [];
             ]);
        keyed
          ~source:(Signal.map View_base.local_graphs model_source)
          ~key:View_base.graph_identifier ~cmp:compare
          ~mount:(fun graph_source ->
            graph_list_row context model_source graph_source true send);
        if_
          ~test:(Signal.map View_base.remote_graphs_present_ model_source)
          (box ~padding:16
             [ heading ~level:5 ~value:"Remote graphs" [] ]);
        keyed
          ~source:(Signal.map View_base.remote_graphs model_source)
          ~key:View_base.graph_identifier ~cmp:compare
          ~mount:(fun graph_source ->
            graph_list_row context model_source graph_source false send);
      ]
  else
    list ~accessibility_identifier:"screen.graphs" ~gap:4
      [
        list_item ~icon:(`app "refresh") ~min_height:44
          ~accessibility_identifier:"button.graphs.refresh"
          ~disabled_signal:
            (Signal.map Model.graph_refresh_active_ model_source)
          ~on_press:(press send Model.RefreshGraphs)
          ~text:"Refresh" [];
        if_
          ~test:(Signal.map Model.graph_refresh_active_ model_source)
          (spinner ~accessibility_identifier:"graphs.loading" []);
        list_item ~min_height:44
          ~accessibility_identifier:"button.graph-add"
          ~on_press:(press send Model.OpenCreateGraph)
          ~text:"Add sync graph" [];
        if_
          ~test:
            (Signal.map View_base.graphs_screen_error_visible_
               model_source)
          (graph_picker_error_banner model_source);
        heading ~level:5
          ~accessibility_identifier:"heading.graphs.local"
          ~value:"Local graphs" [];
        if_
          ~test:(Signal.map View_base.local_graphs_empty_ model_source)
          (text ~foreground:"secondary" ~value:"No local graphs" []);
        keyed
          ~source:(Signal.map View_base.local_graphs model_source)
          ~key:View_base.graph_identifier ~cmp:compare
          ~mount:(fun graph_source ->
            graph_list_row context model_source graph_source true send);
        if_
          ~test:(Signal.map View_base.remote_graphs_present_ model_source)
          (heading ~level:5
             ~accessibility_identifier:"heading.graphs.remote"
             ~value:"Remote graphs" []);
        keyed
          ~source:(Signal.map View_base.remote_graphs model_source)
          ~key:View_base.graph_identifier ~cmp:compare
          ~mount:(fun graph_source ->
            graph_list_row context model_source graph_source false send);
      ]

let flutter_graph_picker_loading_state () : t =
  column ~grow:1.0 ~main:`center ~cross:`center ~gap:12
    ~accessibility_identifier:"loading.graph-picker"
    [
      spinner ~accessibility_identifier:"graphs.loading" [];
      text ~foreground:"muted-foreground"
        ~value:"Loading sync graphs\xE2\x80\xA6" [];
    ]

let flutter_graph_picker_empty_state send : t =
  column ~grow:1.0 ~main:`center ~cross:`stretch
    [
      column ~cross:`center ~gap:16
        ~accessibility_identifier:"empty.graph-picker"
        [
          icon ~name:(`app "graph-remote") ~width:48 ~height:48
            ~foreground:"primary" [];
          heading ~level:3 ~value:"No sync graphs yet" [];
          text ~foreground:"muted-foreground" ~text_alignment:`center
            ~value:
              "Create a graph to start capturing and syncing notes on \
               this device."
            [];
          button ~icon:(`app "add") ~variant:`primary
            ~accessibility_identifier:"button.graph-add"
            ~on_press:(press send Model.OpenCreateGraph)
            ~text:"Add sync graph" [];
          button ~icon:(`app "sync-status") ~variant:`ghost
            ~foreground:"foreground"
            ~accessibility_identifier:"button.graphs.refresh"
            ~on_press:(press send Model.RefreshGraphs)
            ~text:"Refresh" [];
        ];
    ]

let flutter_graph_picker_catalog (context : Lui_ui.ui_context) model_source
    send : t =
  column ~grow:1.0 ~gap:16
    [
      button ~icon:(`app "add") ~variant:`primary
        ~accessibility_identifier:"button.graph-add"
        ~on_press:(press send Model.OpenCreateGraph)
        ~text:"Add sync graph" [];
      scroll ~grow:1.0
        [
          column ~gap:12
            [
              keyed
                ~source:(Signal.map View_base.model_graphs model_source)
                ~key:View_base.graph_identifier ~cmp:compare
                ~mount:(fun graph_source ->
                  graph_row context model_source graph_source false send);
            ];
        ];
    ]

let graph_picker_screen (context : Lui_ui.ui_context) model_source send : t
    =
  if Lui_ui.host context = FlutterHost then
    column ~accessibility_identifier:"screen.graph-picker" ~main:`start
      ~cross:`stretch ~grow:1.0 ~gap:16 ~padding:24
      [
        row ~main:`space_between ~cross:`center
          [
            heading ~level:3 ~value:"Choose a graph"
              ~accessibility_identifier:"title.graph-picker" [];
            graph_picker_overflow_menu send;
          ];
        text ~foreground:"muted-foreground"
          ~value:
            "Select a Logseq graph to download and sync on this device."
          [];
        if_
          ~test:
            (Signal.map View_base.graph_picker_error_present_ model_source)
          (graph_picker_error_banner model_source);
        if_
          ~test:(Signal.map View_base.empty_graphs_loading_ model_source)
          (flutter_graph_picker_loading_state ());
        if_
          ~test:
            (Signal.map View_base.empty_graphs_refreshable_ model_source)
          (flutter_graph_picker_empty_state send);
        if_
          ~test:(Signal.map View_base.graphs_present_ model_source)
          (flutter_graph_picker_catalog context model_source send);
      ]
  else
    column ~accessibility_identifier:"screen.graph-picker" ~main:`start
      ~grow:1.0 ~container_relative_frame:`vertical ~gap:20 ~padding:24
      [
        row ~main:`space_between ~cross:`center
          [
            heading ~level:3 ~value:"Choose a graph" [];
            graph_picker_overflow_menu send;
          ];
        text ~foreground:"muted-foreground"
          ~value:
            "Select a Logseq graph to download and sync on this device."
          [];
        button ~variant:`ghost ~foreground:"foreground"
          ~accessibility_identifier:"button.graph-add"
          ~on_press:(press send Model.OpenCreateGraph)
          ~text:"Add sync graph" [];
        if_
          ~test:
            (Signal.map View_base.graph_picker_error_present_ model_source)
          (graph_picker_error_banner model_source);
        if_
          ~test:(Signal.map View_base.empty_graphs_loading_ model_source)
          (spinner ~accessibility_identifier:"graphs.loading" []);
        if_
          ~test:
            (Signal.map View_base.empty_graphs_refreshable_ model_source)
          (button ~variant:`ghost ~foreground:"foreground"
             ~accessibility_identifier:"button.graphs.refresh"
             ~on_press:(press send Model.RefreshGraphs)
             ~text:"Refresh graphs" []);
        scroll ~grow:1.0
          [
            column ~gap:12
              [
                keyed
                  ~source:(Signal.map View_base.model_graphs model_source)
                  ~key:View_base.graph_identifier ~cmp:compare
                  ~mount:(fun graph_source ->
                    graph_row context model_source graph_source false
                      send);
              ];
          ];
      ]
