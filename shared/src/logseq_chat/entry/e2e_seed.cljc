(ns logseq-chat.entry.e2e-seed
  (:require [ocaml.Logseq_chat_lg_core_native :as core]
            [ocaml.Array :as array]
            [ocaml.Sys :as sys]
            [ocaml.Stdlib :as stdlib]))

(let [[code message] (core/logseq-chat-e2e-seed-cli-run (tuple array/to-seq sys/argv))]
  (if (= code 0) (stdlib/print-endline message) (stdlib/prerr-endline message))
  (stdlib/exit code))
