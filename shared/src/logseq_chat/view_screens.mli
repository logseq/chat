val search_result_row :
  Model.search_hit Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val search_screen :
  Model.chat_model Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val capture_and_search_row :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val main_bottom_chrome :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val root_outliner_view :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  bool Signal.signal -> (Model.chat_action -> bool) -> Lui_elements.t
val retained_journal_pane :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val journal_tree_panes :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val global_effect_error_feedback :
  Lui_ui.ui_context -> Model.chat_model Signal.signal -> Lui_elements.t
val graph_loading_feedback :
  Lui_ui.ui_context -> Model.chat_model Signal.signal -> Lui_elements.t
val chat_main_view :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val main_header_leading :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val main_header_title :
  Lui_ui.ui_context -> Model.chat_model Signal.signal -> Lui_elements.t
val main_header_sync :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val active_overflow_menu :
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val main_header_connection :
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val native_node_screen :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  Model.node_projection Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val native_search_view :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val native_navigation_view :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val authentication_content :
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val authentication_screen :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val application_main_content :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val chat_view :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
