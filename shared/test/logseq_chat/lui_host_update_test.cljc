(ns logseq-chat.lui-host-update-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.host-update :as host]))

(deftest settings-fields
  (match (host/decode "settings" "{\"appearance\":\"dark\",\"language\":\"zh-CN\",\"spellCheck\":false,\"autoCorrection\":true,\"sidebarTabs\":[\"journals\",\"graphs\"],\"baseURL\":\"https://example.com\",\"version\":\"1.2.3\",\"revision\":\"abc123\"}")
    (Ok (host/Settings settings))
    (do (is (= "dark" (:appearance settings)))
        (is (= "zh-CN" (:language settings)))
        (is (not (:spell-check settings)))
        (is (:auto-correction settings))
        (is (= ["journals" "graphs"] (:sidebar-tabs settings)))
        (is (= "https://example.com" (:base-url settings)))
        (is (= "1.2.3" (:version settings)))
        (is (= "abc123" (:revision settings))))
    _ (is false "settings update rejected")))

(deftest runtime-log-preserves-unicode-and-newlines
  (match (host/decode "runtime-log" "[{\"id\":\"7\",\"level\":\"ERROR\",\"source\":\"ui\",\"timestamp\":\"12:34\",\"message\":\"第一行\\nsecond line\"}]")
    (Ok (host/Runtime_log entries))
    (let [entry (nth entries 0)]
      (is (= 1 (count entries)))
      (is (= "7" (:id entry)))
      (is (= "ERROR" (:level entry)))
      (is (= "ui" (:source entry)))
      (is (= "12:34" (:timestamp entry)))
      (is (= "第一行\nsecond line" (:message entry))))
    _ (is false "runtime log update rejected")))

(deftest simple-host-updates
  (is (= (Ok (host/Local_graph_ids ["a" "b"])) (host/decode "local-graph-ids" "[\"a\",\"b\"]")))
  (is (= (Ok host/Open_capture) (host/decode "open-capture" "{}")))
  (is (= (Ok (host/Composer_draft "稍后处理\nsecond line"))
         (host/decode "composer-draft" "\"稍后处理\\nsecond line\"")))
  (is (= (Ok (host/Graph_loading true)) (host/decode "graph-loading" "true")))
  (is (= (Ok host/Save_ui_session) (host/decode "save-ui-session" "null")))
  (is (= (Ok (host/Open_quick_action "capture")) (host/decode "open-quick-action" "\"capture\""))))

(deftest authentication-preserves-nullable-error
  (match (host/decode "authentication" "{\"state\":\"signedOut\",\"errorMessage\":\"Authorization was cancelled\"}")
    (Ok (host/Authentication authentication))
    (do (is (= "signedOut" (:state authentication)))
        (is (= (Some "Authorization was cancelled") (:error-message authentication))))
    _ (is false "signed-out authentication rejected"))
  (match (host/decode "authentication" "{\"state\":\"signedIn\",\"errorMessage\":null}")
    (Ok (host/Authentication authentication))
    (do (is (= "signedIn" (:state authentication)))
        (is (nil? (:error-message authentication))))
    _ (is false "signed-in authentication rejected")))

(deftest session-restoration-preserves-every-field
  (match (host/decode "restore-ui-session" "{\"graphId\":null,\"destination\":\"graphs\",\"draft\":\"draft\",\"assets\":[{\"uuid\":\"a\",\"title\":\"image\",\"localPath\":\"/tmp/a\",\"payload\":\"raw\"}],\"composerExpanded\":true,\"searchOpen\":false,\"query\":\"q\",\"appPath\":[\"p1\",\"p2\"],\"searchPath\":[],\"selectedPageId\":\"p2\",\"settingsOpen\":true}")
    (Ok (host/Restore_ui_session session))
    (do (is (nil? (:graph-id session)))
        (is (= "graphs" (:destination session)))
        (is (= "draft" (:draft session)))
        (is (:composer-expanded session))
        (is (not (:search-open session)))
        (is (:settings-open session))
        (is (= "q" (:query session)))
        (is (= (Some "p2") (:selected-page-id session)))
        (is (= ["p1" "p2"] (:app-path session)))
        (is (empty? (:search-path session)))
        (is (= 1 (count (:assets session))))
        (let [asset (nth (:assets session) 0)]
          (is (= "a" (:uuid asset)))
          (is (= "image" (:title asset)))
          (is (= "/tmp/a" (:local-path asset)))
          (is (= "raw" (:payload asset)))))
    _ (is false "session restoration rejected")))

(deftest asset-preserves-original-payload
  (let [payload "{\"uuid\":\"a\",\"title\":\"image\",\"localPath\":\"/tmp/a\"}"]
    (match (host/decode "composer-asset" payload)
      (Ok (host/Composer_asset asset)) (is (= payload (:payload asset)))
      _ (is false "composer asset rejected"))))

(deftest invalid-updates-are-classified
  (run! (fn [[kind payload prefix]]
          (match (host/decode kind payload)
            (Error message) (is (string/starts-with? message prefix))
            (Ok _) (is false (str "invalid update accepted: " kind))))
    [["open-capture" "{" "Invalid host update JSON: "]
     ["graph-loading" "\"yes\"" "Invalid graph-loading host update: "]
     ["settings" "{}" "Invalid settings host update: "]
     ["local-graph-ids" "[\"a\",1]" "Invalid local-graph-ids host update: "]
     ["unknown" "{}" "Unsupported host update: unknown"]]))

