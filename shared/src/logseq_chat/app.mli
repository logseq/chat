val create :
  Lui_protocol.backend -> (Model.chat_model, Model.chat_action) Lui_app.reducer_app

val create_with_authentication :
  Lui_protocol.backend ->
  string -> (Model.chat_model, Model.chat_action) Lui_app.reducer_app

val model :
  (Model.chat_model, Model.chat_action) Lui_app.reducer_app -> Model.chat_model
