val sidebar_page_row :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  Model.sidebar_page Signal.signal ->
  (Model.chat_action -> 'a) -> Lui_elements.t
val sidebar_graph_menu_item :
  Model.chat_model Signal.signal ->
  Model.graph Signal.signal -> (Model.chat_action -> 'a) -> Lui_elements.t
val sidebar_section_heading : string -> string -> Lui_elements.t
val sidebar_empty_section_label : string -> Lui_elements.t
val sidebar_graph_switch_content :
  Model.chat_model Signal.signal -> Lui_elements.t
val sidebar_graph_switch :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val sidebar_journals_row :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val sidebar_flashcards_row :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val sidebar_graphs_row :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val sidebar_view :
  Lui_ui.ui_context ->
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
