val attachment_menu : (Model.chat_action -> 'a) -> Lui_elements.t
val composer_attachment_button :
  Lui_ui.ui_context -> (Model.chat_action -> bool) -> Lui_elements.t
val composer_task_status_button :
  Lui_ui.ui_context -> (Model.chat_action -> bool) -> Lui_elements.t
val android_composer_send_button :
  Lui_ui.ui_context ->
  bool Signal.signal -> (Model.chat_action -> bool) -> Lui_elements.t
val apple_composer_send_button :
  bool Signal.signal -> (Model.chat_action -> bool) -> Lui_elements.t
val composer_send_button :
  Lui_ui.ui_context ->
  bool Signal.signal -> (Model.chat_action -> bool) -> Lui_elements.t
val collapsed_composer_button :
  Lui_ui.ui_context -> (Model.chat_action -> bool) -> Lui_elements.t
val composer_asset_preview :
  Model.composer_asset Signal.signal -> Lui_elements.t
val composer_asset_view :
  Model.composer_asset Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val task_status_row :
  Model.task_status Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val task_status_picker_dialog :
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val composer_view :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val outliner_task_status_row :
  string ->
  Model.task_status Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
