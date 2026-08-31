(ns logseq-chat.app
  (:require [lui.app :as app]
            [logseq-chat.model :as model]
            [logseq-chat.view :as view]))

(defn create [backend]
  (app/create-with-extensions
   backend (view/extension-registry)
   (model/initial) model/update view/chat-view))

(defn create-with-authentication [backend authentication-state]
  (app/create-with-extensions
   backend (view/extension-registry)
   (model/update
    (model/initial)
    (model/ApplyAuthentication authentication-state None))
   model/update view/chat-view))

(defn model [application]
  (app/model application))
