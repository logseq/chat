let create backend =
  Lui_app.create_with_extensions backend (View.extension_registry ())
    (Model.initial ()) Model.update View.chat_view

let create_with_authentication backend authentication_state =
  Lui_app.create_with_extensions backend (View.extension_registry ())
    (Model.update (Model.initial ())
       (Model.ApplyAuthentication (authentication_state, None)))
    Model.update View.chat_view

let model application = Lui_app.model application
