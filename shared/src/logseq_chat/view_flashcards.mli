val flashcard_answer_row :
  Model.flashcard_answer_row Signal.signal -> Lui_elements.t
val flashcard_rating_button :
  string ->
  string -> string -> string -> (Model.chat_action -> bool) -> Lui_elements.t
val flashcard_review_content :
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
val flashcard_screen :
  Model.chat_model Signal.signal ->
  (Model.chat_action -> bool) -> Lui_elements.t
