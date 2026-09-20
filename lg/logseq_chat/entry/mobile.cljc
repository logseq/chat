(ns logseq-chat.entry.mobile
  (:require [logseq-chat.native-bridge :as bridge]
            [logseq-chat.native-crypto :as crypto]
            [logseq-chat.mobile-session :as mobile]))

(when-not (bridge/linked)
  (throw (Failure "LG/LUI native bridge failed to link")))

(mobile/start! crypto/call-raw)
