(ns logseq-chat.app
  (:require [lui.app :as app]
            [logseq-chat.model :as model]
            [logseq-chat.view :as view]))

(defn create [backend]
  (app/create backend (model/initial) model/update view/chat-view))

(defn model [application]
  (app/model application))
