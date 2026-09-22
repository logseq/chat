open Lui_protocol
open Lui_elements

let attachment_menu send : t =
  context_menu
    [
      menu_item ~icon:"app:toolbar-attachment"
        ~accessibility_identifier:"button.attachment.files"
        ~text:"File"
        ~on_press:(fun _ ->
          ignore (send (Model.ChooseAttachment "files")))
        [];
      menu_item ~icon:"app:toolbar-camera"
        ~accessibility_identifier:"button.attachment.camera"
        ~text:"Camera"
        ~on_press:(fun _ ->
          ignore (send (Model.ChooseAttachment "camera")))
        [];
      menu_item ~icon:"app:composer-photo"
        ~accessibility_identifier:"button.attachment.photos"
        ~text:"Photo"
        ~on_press:(fun _ ->
          ignore (send (Model.ChooseAttachment "photos")))
        [];
      menu_item ~icon:"app:toolbar-audio"
        ~accessibility_identifier:"button.attachment.audio"
        ~text:"Audio recording"
        ~on_press:(fun _ ->
          ignore (send (Model.ChooseAttachment "audio")))
        [];
    ]

let composer_attachment_button (context : Lui_ui.ui_context) send : t =
  if Lui_ui.platform context = AndroidOS then
    button ~icon:"app:add" ~variant:"ghost" ~label:"Add attachment"
      ~accessibility_identifier:"button.attachment"
      ~on_press:(press send Model.OpenAttachmentPicker)
      [ text ~value:"Attach" []; attachment_menu send ]
  else
    button ~icon:"app:composer-add" ~variant:"ghost" ~width:32 ~height:32
      ~label:"Add attachment" ~accessibility_identifier:"button.attachment"
      ~on_press:(press send Model.OpenAttachmentPicker)
      [ attachment_menu send ]

let composer_task_status_button (context : Lui_ui.ui_context) send : t =
  if Lui_ui.platform context = AndroidOS then
    button ~icon:"app:task-todo" ~variant:"ghost" ~foreground:"border"
      ~label:"Task status" ~accessibility_identifier:"button.task-status"
      ~on_press:(press send Model.OpenTaskStatusPicker)
      [ text ~value:"Task" [] ]
  else
    button ~icon:"app:task-todo" ~variant:"ghost" ~size:"icon" ~width:32
      ~height:32 ~foreground:"border" ~label:"Task status"
      ~accessibility_identifier:"button.task-status"
      ~on_press:(press send Model.OpenTaskStatusPicker)
      []

let android_composer_send_button (context : Lui_ui.ui_context)
    disabled_source send : t =
  if Lui_ui.host context = FlutterHost then
    button ~icon:"app:send" ~variant:"primary" ~size:"icon" ~width:48
      ~height:48 ~label:"Send" ~accessibility_identifier:"button.send"
      ~disabled_signal:disabled_source
      ~on_press:(press send Model.SendComposer)
      []
  else
    button ~icon:"app:send" ~variant:"primary" ~label:"Send"
      ~accessibility_identifier:"button.send"
      ~disabled_signal:disabled_source
      ~on_press:(press send Model.SendComposer)
      [ text ~value:"Send" [] ]

let apple_composer_send_button disabled_source send : t =
  button ~icon:"app:arrow-up" ~variant:"ghost" ~width:36 ~height:36
    ~background:"black" ~foreground:"white" ~corner_radius:18 ~label:"Send"
    ~accessibility_identifier:"button.send" ~disabled_signal:disabled_source
    ~on_press:(press send Model.SendComposer)
    []

let composer_send_button (context : Lui_ui.ui_context) disabled_source send
    : t =
  if Lui_ui.platform context = AndroidOS then
    android_composer_send_button context disabled_source send
  else apple_composer_send_button disabled_source send

let collapsed_composer_button (context : Lui_ui.ui_context) send : t =
  if Lui_ui.platform context = AndroidOS then
    if Lui_ui.host context = FlutterHost then
      button ~icon:"app:add" ~variant:"secondary" ~grow:1.0 ~height:58
        ~padding_horizontal:20 ~label:"Capture a thought"
        ~accessibility_identifier:"button.composer.expand"
        ~on_press:(press send Model.ExpandComposer)
        [ text ~value:"Capture a thought" [] ]
    else
      button ~variant:"ghost" ~height:58 ~padding_horizontal:30
        ~foreground:"muted-foreground"
        ~accessibility_identifier:"button.composer.expand"
        ~on_press:(press send Model.ExpandComposer)
        [ text ~value:"Capture" [] ]
  else
    button ~variant:"ghost" ~grow:1.0 ~height:58 ~padding_horizontal:30
      ~foreground:"muted-foreground"
      ~accessibility_identifier:"button.composer.expand"
      ~on_press:(press send Model.ExpandComposer)
      [ text ~value:"Capture" [] ]

let composer_asset_preview asset_source : t =
 fun context parent ->
   let node = Lui_ui.extension context "composer-asset" in
   attach context parent node;
   Lui_ui.extension_property_signal context node "title"
     (Signal.map
        (fun (asset : Model.composer_asset) ->
          View_base.string_wire_value (View_base.composer_asset_title asset))
        asset_source);
   Lui_ui.extension_property_signal context node "local-path"
     (Signal.map
        (fun (asset : Model.composer_asset) ->
          View_base.string_wire_value (View_base.composer_asset_path asset))
        asset_source);
   node

let composer_asset_view asset_source send : t =
  let asset = Signal.sample asset_source in
  stack ~width:128 ~height:128
    ~accessibility_identifier:(View_base.composer_asset_identifier asset)
    [
      composer_asset_preview asset_source;
      column ~width:128 ~height:128 ~padding:4 ~main:"start"
        [
          row ~main:"end" ~height:24
            [
              button ~icon:"app:close" ~variant:"ghost" ~size:"sm" ~width:24
                ~height:24 ~corner_radius:12 ~background:"muted-foreground"
                ~foreground:"white" ~label:"Remove attachment"
                ~accessibility_identifier:"composer.asset.remove"
                ~on_press:(fun _ ->
                  ignore
                    (send
                       (Model.RemoveComposerAsset
                          (Signal.sample asset_source).uuid)))
                [];
            ];
          spacer ~grow:1.0 [];
        ];
    ]

let task_status_row status_source send : t =
  let status = Signal.sample status_source in
  menu_item
    ~text_signal:(reactive View_base.task_status_title status_source)
    ~icon:(View_base.task_status_icon_name status)
    ~foreground:(View_base.task_status_foreground status)
    ~accessibility_identifier:(View_base.task_status_identifier status)
    ~on_press:(fun _ ->
      ignore
        (send
           (Model.ChooseTaskStatus
              (Signal.sample status_source).uuid)))
    []

let task_status_picker_dialog model_source send : t =
  dropdown_menu ~anchor:"above" ~anchor_alignment:"start" ~min_width:220
    ~on_dismiss:(press send Model.CloseTaskStatusPicker)
    [
      keyed
        ~source:(Signal.map View_base.model_task_statuses model_source)
        ~key:View_base.task_status_identifier ~compare:compare
        ~mount:(fun status_source -> task_status_row status_source send);
      if_
        ~test:(Signal.map View_base.task_status_selected_ model_source)
        (menu_item ~accessibility_identifier:"button.task-status.clear"
           ~text:"Clear task status"
           ~on_press:(press send Model.ClearTaskStatus)
           []);
    ]

let composer_view (context : Lui_ui.ui_context) model_source send : t =
  box ~accessibility_identifier:"surface.composer.root" ~grow:1.0
    ~min_height:58
    [
      if_
        ~test:(Signal.map View_base.composer_expanded_ model_source)
        (column ~grow:1.0 ~main:"end" ~gap:0
           ~padding_horizontal:
             (if Lui_ui.host context = FlutterHost then 12 else 16)
           ~padding_vertical:
             (if Lui_ui.host context = FlutterHost then 12 else 8)
           ~background:
             (if Lui_ui.host context = FlutterHost then
                "surface-container-high"
              else "glass-fallback")
           ~corner_radius:24
           [
             box ~height:6 ~accessibility_identifier:"spacer.composer.top"
               [];
             if_
               ~test:(Signal.map View_base.composer_assets_present_
                        model_source)
               (View_base.with_string_prop OrientationValue "horizontal"
                  (scroll ~height:140
                     [
                       row ~gap:8
                         [
                           keyed
                             ~source:
                               (Signal.map View_base.model_composer_assets
                                  model_source)
                             ~key:View_base.composer_asset_identifier
                             ~compare:compare
                             ~mount:(fun asset_source ->
                               composer_asset_view asset_source send);
                         ];
                     ]));
             textarea
               ~text_signal:(reactive View_base.composer_draft model_source)
               ~min_height:36 ~style_class:"composer-input"
               ~placeholder:"Capture" ~label:"Capture"
               ~accessibility_identifier:"field.composer"
               ~on_input:(on_input send (fun text ->
                            Model.ChangeComposerDraft text))
               ~on_submit:(press send Model.SendComposer)
               [];
             box ~height:8
               ~accessibility_identifier:"spacer.composer.field-controls"
               [];
             row ~gap:8 ~height:44 ~cross:"center"
               ~accessibility_identifier:"row.composer.controls"
               [
                 composer_attachment_button context send;
                 stack
                   [
                     composer_task_status_button context send;
                     if_
                       ~test:
                         (Signal.map View_base.model_task_status_picker_open_
                            model_source)
                       (task_status_picker_dialog model_source send);
                   ];
                 spacer ~grow:1.0
                   ~accessibility_identifier:"spacer.composer.controls" [];
                 composer_send_button context
                   (reactive View_base.composer_send_disabled_ model_source)
                   send;
               ];
           ]);
      if_
        ~test:(Signal.map View_base.composer_collapsed_ model_source)
        (collapsed_composer_button context send);
    ]

let outliner_task_status_row block_id status_source send : t =
  let status = Signal.sample status_source in
  menu_item
    ~text_signal:(reactive View_base.task_status_title status_source)
    ~icon:(View_base.task_status_icon_name status)
    ~foreground:"secondary"
    ~accessibility_identifier:
      (View_base.outliner_task_status_option_identifier status)
    ~on_press:(fun _ ->
      ignore
        (send
           (Model.SetOutlinerTaskStatus
              (block_id, (Signal.sample status_source).uuid))))
    []
