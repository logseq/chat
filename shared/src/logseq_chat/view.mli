type retained_outline_row = View_rows.retained_row

val chat_view :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t

val composer_asset_schema :
  unit -> Lui_extension.extension_component_schema

val outliner_editor_schema :
  unit -> Lui_extension.extension_component_schema

val outliner_block_content_schema :
  unit -> Lui_extension.extension_component_schema

val native_navigation_stack_schema :
  unit -> Lui_extension.extension_component_schema

val native_search_presentation_schema :
  unit -> Lui_extension.extension_component_schema

val native_overflow_menu_schema :
  unit -> Lui_extension.extension_component_schema

val liquid_glass_schema :
  unit -> Lui_extension.extension_component_schema

val extension_registry : unit -> Lui_extension.extension_registry
