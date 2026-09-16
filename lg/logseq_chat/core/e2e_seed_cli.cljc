(ns logseq-chat.e2e-seed-cli
  (:require [logseq-chat.e2e-seed-data :as seed]
            [logseq-chat.graph-store :as store]
            [logseq-chat.graph-read :as graph]
            [logseq-chat.flashcards :as cards]
            [logseq-chat.pending-ops :as ops]
            [logseq-chat.pending-projection :as projection]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]))

(def usage
  "usage: logseq_chat_e2e_seed <graph.sqlite> [--inspect|--header-navigation|--composer|--outliner|--fixture|--performance]")

(defn parse-args [args]
  (cond
    (not (<= 2 (count args) 3)) (Error (tuple 2 usage))
    (= (count args) 2) (Ok (tuple (nth args 1) :default))
    :else
    (let [flag (nth args 2)
          mode (case flag
                 "--inspect" (Some :inspect)
                 "--header-navigation" (Some :header-navigation)
                 "--composer" (Some :composer)
                 "--outliner" (Some :outliner)
                 "--fixture" (Some :fixture)
                 "--performance" (Some :performance)
                 nil)]
      (if-some [mode mode] (Ok (tuple (nth args 1) mode))
               (Error (tuple 2 (str "unknown seed mode: " flag)))))))

(defn now-ms [] (int (* (unix/gettimeofday) 1000.0)))

(defn seed-mode [conn mode]
  (case mode
    :inspect (Ok (stdlib/ignore 0))
    :header-navigation (seed/seed-header-navigation conn)
    :composer (seed/seed-composer conn (now-ms))
    :outliner (seed/seed-outliner conn (now-ms))
    :fixture (seed/seed-fixture conn)
    :performance (seed/seed-performance conn (now-ms))
    :default (seed/seed conn)
    (Error "unknown seed mode")))

(defn execute [path mode]
  (let* [conn (store/restore-conn path)
         _ (seed-mode conn mode)
         db (store/restore-db path)]
    (let [plain (fn [value] (Ok value))
          blocks (graph/blocks plain 7 db)
          tag-pages (graph/tag-pages plain db)
          favorites (:favorites (graph/sidebar-pages plain db))
          due (cards/due-cards db (now-ms))
          projected-due (if (= mode :inspect)
                          (let [snapshot (projection/build 1 db (ops/list path))]
                            (cards/due-cards (:db snapshot) (now-ms)))
                          due)]
      (Ok (format "Seeded iOS E2E graph: %s journals=%d visible-blocks=%d tags=%d favorites=%d due-flashcards=%d projected-due-flashcards=%d"
                  path (graph/journal-page-count db) (count blocks) (count tag-pages)
                  (count favorites) (count due) (count projected-due))))))

(defn run [args]
  (match (parse-args args)
    (Error failure) failure
    (Ok (tuple path mode))
    (match (execute path mode)
      (Ok message) (tuple 0 message)
      (Error message) (tuple 1 message))))
