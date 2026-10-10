val flashcard_answer_row :
  Model.flashcard_answer_row Signal.signal -> Lui_elements.t
val flashcard_rating_button :
  string ->
  string -> string -> string -> (Model.logseq_action -> bool) -> Lui_elements.t
val flashcard_review_content :
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val flashcard_screen :
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
