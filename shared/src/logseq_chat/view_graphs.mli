val graph_row :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  Model.graph Signal.signal ->
  'a -> (Model.chat_action -> 'b) -> Lui_elements.t
val graph_list_row :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  Model.graph Signal.signal ->
  bool -> (Model.chat_action -> 'a) -> Lui_elements.t
val graph_create_sheet :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val graph_delete_dialog :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val graph_picker_overflow_menu :
  (Model.chat_action -> bool) -> Lui_elements.t
val graph_picker_error_banner :
  Model.chat_model Signal.signal -> Lui_elements.t
val graph_password_sheet :
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val graphs_screen :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val flutter_graph_picker_loading_state : unit -> Lui_elements.t
val flutter_graph_picker_empty_state :
  (Model.chat_action -> bool) -> Lui_elements.t
val flutter_graph_picker_catalog :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val graph_picker_screen :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
