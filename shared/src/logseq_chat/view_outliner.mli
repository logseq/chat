val outliner_editor_view :
  string Signal.signal ->
  string Signal.signal ->
  int Signal.signal -> (Model.chat_action -> bool) -> Lui_elements.t
val outliner_rich_block_view :
  Model.chat_model Signal.signal ->
  string Signal.signal ->
  string Signal.signal ->
  string Signal.signal ->
  bool Signal.signal ->
  Model.outline_row Signal.signal ->
  string Signal.signal ->
  string Signal.signal -> (Model.chat_action -> bool) -> Lui_elements.t
val outliner_collapse_button :
  Lui_ui.ui_context ->
  Model.outline_row Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val outliner_indent_view : int Signal.signal -> Lui_elements.t
val breadcrumb_button :
  Model.sidebar_page Signal.signal ->
  bool -> (Model.chat_action -> 'a) -> Lui_elements.t
val node_breadcrumb_button :
  Model.chat_model Signal.signal ->
  Model.sidebar_page Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val node_breadcrumbs :
  Model.chat_model Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val related_row_breadcrumbs :
  Model.outline_row Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val outliner_tag :
  Model.sidebar_page Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val outliner_zoom_control :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.chat_action -> 'a) -> bool -> Lui_elements.t
val outliner_status_icon :
  string -> ('a -> bool) -> string -> 'a Signal.signal -> Lui_elements.t
val outliner_status_control :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val outliner_row_main_content :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  View_rows.retained_row Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val outliner_row_content :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  View_rows.retained_row Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.chat_action -> bool) -> bool -> Lui_elements.t
val outliner_row :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  View_rows.retained_row Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val outliner_entry :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  View_rows.retained_row Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val outliner_first_journal_section :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val toolbar_button :
  string ->
  string -> string -> string -> (Model.chat_action -> 'a) -> Lui_elements.t
val outliner_selection_toolbar :
  Lui_ui.ui_context -> (Model.chat_action -> 'a) -> Lui_elements.t
val outliner_autocomplete_row :
  Lui_ui.ui_context ->
  Model.outliner_autocomplete_candidate Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val outliner_autocomplete_bar :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val outliner_editor_toolbar :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val node_related_row :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val related_section_heading : string -> Lui_elements.t
val node_related_section :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val node_tagged_section :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val node_linked_reference_section :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val add_first_block_button :
  Model.chat_model Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val node_screen :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
