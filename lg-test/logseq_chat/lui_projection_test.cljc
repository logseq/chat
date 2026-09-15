(ns logseq-chat.lui-projection-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.snapshot :as snapshot]
            [logseq-chat.native-bridge :as bridge]
            [logseq-chat.model :as model]
            [ocaml.Yojson.Basic :as json]))

(def graph-response "{\"apiVersion\":1,\"ok\":true,\"result\":{\"revision\":1,\"blocks\":[],\"selectedBlock\":null,\"lastRefreshAt\":null,\"graphName\":\"Local graph\",\"selectedGraphId\":\"local\",\"graphs\":[{\"id\":\"local\",\"name\":\"Local graph\",\"schemaVersion\":\"65.33\",\"isEncrypted\":false,\"isReady\":true}]}}")

(defn take-effect []
  (snapshot/object-member "effect"
    (snapshot/object-fields (json/from-string (bridge/take-effect)))))

(defn persisted-session [remaining]
  (if (zero? remaining)
    (throw (Failure "restored session did not emit persistence effect"))
    (let [effect (take-effect)]
      (if (= (snapshot/string-member "kind" effect) (Some "persist-ui-session"))
        (or (snapshot/string-member "text" effect) "")
        (do
          (bridge/resolve-effect (or (snapshot/int-member "id" effect) 0) true "")
          (persisted-session (dec remaining)))))))

(deftest node-route-projection-retains-journal-and-editor-state
  (match (snapshot/decode-response "{\"apiVersion\":1,\"ok\":true,\"result\":{\"outlinerRows\":[{\"block\":{\"uuid\":\"journal\",\"title\":\"Journal\"},\"depth\":0,\"hasChildren\":false,\"isCollapsed\":false}],\"nodeRoutes\":[{\"uuid\":\"node-a\",\"isTag\":false,\"isProperty\":false,\"page\":{\"uuid\":\"page-a\",\"title\":\"Project\"},\"outlinerState\":{\"editing\":{\"uuid\":\"child\",\"title\":\"Child\",\"caretUTF16Offset\":5},\"selectedBlockIds\":[\"child\"],\"autocomplete\":null},\"outlinerAutocompleteCandidates\":[],\"outlinerRows\":[{\"block\":{\"uuid\":\"child\",\"title\":\"Child\"},\"depth\":1,\"hasChildren\":false,\"isCollapsed\":false}]}]}}")
    (Error message) (is false message)
    (Ok projection)
    (let [routes (:node-routes projection)
          route (nth routes 0)]
      (is (= 1 (count routes)))
      (is (= ["child"] (mapv :uuid (:outliner-rows route))))
      (is (= (Some "child") (when-some [editing (:outliner-editing route)] (:uuid editing))))
      (is (= ["child"] (:outliner-selected-block-ids route)))
      (is (= ["journal"] (mapv :uuid (:journal-outliner-rows projection)))))))

(deftest first-authoritative-snapshot-publishes-retained-patch
  (bridge/initialize 2 1 0)
  (try
    (is (not= "" (bridge/apply-response graph-response)))
    (finally (bridge/dispose))))

(deftest native-session-roundtrip-preserves-draft-assets-and-navigation
  (let [asset (record model/composer-asset
                (uuid "pending-photo") (title "照片.jpg")
                (local-path "/tmp/photo.jpg") (payload "{\"uuid\":\"pending-photo\"}"))
        original (assoc (model/initial)
                   :selected-graph-id (Some "local")
                   :composer-draft "Unsent\n草稿"
                   :composer-expanded true
                   :composer-assets [asset]
                   :search-open true :search-query "hello"
                   :app-navigation-path [(model/NodeRoute "page-a")]
                   :search-navigation-path [(model/NodeRoute "block-b")])
        saved (bridge/encode-ui-session (model/ui-session original))]
    (bridge/initialize 2 1 3)
    (try
      (bridge/apply-response graph-response)
      (bridge/apply-host-update "restore-ui-session" saved)
      (bridge/apply-host-update "save-ui-session" "null")
      (is (= (json/from-string saved) (json/from-string (persisted-session 8))))
      (finally (bridge/dispose)))))

(deftest quick-actions-clear-selection-before-opening-native-recorder
  (run! (fn [kind]
          (bridge/initialize 2 1 3)
          (try
            (bridge/apply-host-update "open-quick-action" (json/to-string (tag String kind)))
            (let [clear (take-effect)]
              (is (= (Some "clear-selected-page") (snapshot/string-member "kind" clear)))
              (bridge/resolve-effect (or (snapshot/int-member "id" clear) 0) true "")
              (when (= kind "audio")
                (let [recorder (take-effect)]
                  (is (= (Some "present-attachment") (snapshot/string-member "kind" recorder)))
                  (is (= (Some "audio") (snapshot/string-member "text" recorder))))))
            (finally (bridge/dispose))))
        ["capture" "journal" "audio"]))

