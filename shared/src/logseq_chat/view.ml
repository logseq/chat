type retained_outline_row = View_rows.retained_row

let chat_view = View_screens.chat_view

let composer_asset_schema () =
  Lui_extension.component "composer-asset"
    [ Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost ]
    false []
    [
      Lui_extension.property "title" Lui_extension.StringScalar true None;
      Lui_extension.property "local-path" Lui_extension.StringScalar true
        None;
    ]
    []

let outliner_editor_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.component "outliner-editor"
    [ profile IOS SwiftUIHost; profile AndroidOS FlutterHost ]
    false []
    [
      Lui_extension.property "block-id" StringScalar true None;
      Lui_extension.property "title" StringScalar true None;
      Lui_extension.property "caret-utf16-offset" IntScalar true None;
    ]
    [
      Lui_extension.event "text-change"
        [
          Lui_extension.event_field "title" StringScalar true;
          Lui_extension.event_field "caret-utf16-offset" IntScalar true;
        ];
      Lui_extension.event "return"
        [
          Lui_extension.event_field "title" StringScalar true;
          Lui_extension.event_field "caret-utf16-offset" IntScalar true;
        ];
      Lui_extension.event "backspace"
        [
          Lui_extension.event_field "title" StringScalar true;
          Lui_extension.event_field "selection-length" IntScalar true;
        ];
      Lui_extension.event "caret-change"
        [ Lui_extension.event_field "caret-utf16-offset" IntScalar true ];
    ]

let outliner_block_content_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.component "outliner-block-content"
    [ profile IOS SwiftUIHost; profile AndroidOS FlutterHost ]
    false []
    [
      Lui_extension.property "title" StringScalar true None;
      Lui_extension.property "block-id" StringScalar true None;
      Lui_extension.property "markup-json" StringScalar true None;
      Lui_extension.property "youtube-target-url" StringScalar true None;
      Lui_extension.property "is-asset" BoolScalar true None;
      Lui_extension.property "is-completed" BoolScalar true None;
      Lui_extension.property "asset-type" StringScalar true None;
      Lui_extension.property "local-path" StringScalar true None;
    ]
    [
      Lui_extension.event "drag-start"
        [ Lui_extension.event_field "uuid" StringScalar true ];
      Lui_extension.event "drop"
        [
          Lui_extension.event_field "uuid" StringScalar true;
          Lui_extension.event_field "placement" StringScalar true;
        ];
      Lui_extension.event "edit"
        [ Lui_extension.event_field "uuid" StringScalar true ];
      Lui_extension.event "open-node"
        [ Lui_extension.event_field "uuid" StringScalar true ];
    ]

let native_navigation_stack_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.component "native-navigation-stack"
    [ profile IOS SwiftUIHost; profile AndroidOS FlutterHost ]
    true []
    [
      Lui_extension.property "depth" IntScalar true None;
      Lui_extension.property "bottom-occupies-layout-space" BoolScalar true
        None;
      Lui_extension.property "composer-dismissal-enabled" BoolScalar true
        None;
      Lui_extension.property "title" StringScalar true None;
    ]
    [
      Lui_extension.event "back"
        [ Lui_extension.event_field "count" IntScalar true ];
      Lui_extension.event "dismiss-composer" [];
    ]

let native_search_presentation_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.component "native-search-presentation"
    [ profile IOS SwiftUIHost; profile AndroidOS FlutterHost ]
    true []
    [
      Lui_extension.property "presented" BoolScalar true None;
      Lui_extension.property "depth" IntScalar true None;
      Lui_extension.property "query" StringScalar true None;
      Lui_extension.property "title" StringScalar true None;
    ]
    [
      Lui_extension.event "back"
        [ Lui_extension.event_field "count" IntScalar true ];
      Lui_extension.event "dismiss" [];
      Lui_extension.event "query-changed"
        [ Lui_extension.event_field "query" StringScalar true ];
    ]

let native_overflow_menu_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.component "native-overflow-menu"
    [ profile IOS SwiftUIHost; profile AndroidOS FlutterHost ]
    false []
    [
      Lui_extension.property "page-actions-visible" BoolScalar true None;
      Lui_extension.property "favorite-label" StringScalar true None;
      Lui_extension.property "settings-visible" BoolScalar true None;
    ]
    [
      Lui_extension.event "favorite" [];
      Lui_extension.event "share" [];
      Lui_extension.event "delete" [];
      Lui_extension.event "settings" [];
    ]

let liquid_glass_schema () =
  let open Lui_protocol in
  let open Lui_extension in
  Lui_extension.tweak "liquid-glass" [ profile IOS SwiftUIHost ]
    [ Lui_extension.property "shape" StringScalar true None ]

let extension_registry () =
  let registry = Lui_extension.registry () in
  Lui_extension.register_component registry (outliner_editor_schema ());
  Lui_extension.register_component registry
    (outliner_block_content_schema ());
  Lui_extension.register_component registry (composer_asset_schema ());
  Lui_extension.register_component registry
    (native_navigation_stack_schema ());
  Lui_extension.register_component registry
    (native_search_presentation_schema ());
  Lui_extension.register_component registry
    (native_overflow_menu_schema ());
  Lui_extension.register_tweak registry (liquid_glass_schema ());
  registry
