(ns logseq-chat.host-update
  (:require [ocaml.package/yojson]
            [ocaml.Yojson :as yojson]
            [ocaml.Yojson.Safe :as json]
            [ocaml.Yojson.Safe.Util :as util]))

(type-record host-composer-asset
  (uuid :string)
  (title :string)
  (local-path :string)
  (payload :string))

(type-record host-ui-session
  (graph-id :option<string>)
  (destination :string)
  (draft :string)
  (assets :vector<host-composer-asset>)
  (composer-expanded :bool)
  (search-open :bool)
  (query :string)
  (app-path :vector<string>)
  (search-path :vector<string>)
  (selected-page-id :option<string>)
  (settings-open :bool))

(type-record host-settings
  (appearance :string)
  (language :string)
  (spell-check :bool)
  (auto-correction :bool)
  (sidebar-tabs :vector<string>)
  (base-url :string)
  (version :string)
  (revision :string))

(type-record host-runtime-log-record
  (id :string)
  (level :string)
  (source :string)
  (timestamp :string)
  (message :string))

(type-record host-authentication
  (state :string)
  (error-message :option<string>))

(type-variant host-update
  (Settings :host-settings)
  (Runtime_log :vector<host-runtime-log-record>)
  (Local_graph_ids :vector<string>)
  Save_ui_session
  (Restore_ui_session :host-ui-session)
  (Composer_draft :string)
  (Composer_asset :host-composer-asset)
  (Graph_loading :bool)
  (Authentication :host-authentication)
  (Open_quick_action :string)
  Open_capture)

(defn string-field [name value]
  (util/to-string (util/member name value)))

(defn bool-field [name value]
  (util/to-bool (util/member name value)))

(defn string-vector [value]
  (mapv util/to-string (util/to-list value)))

(defn settings [value]
  (Settings
   (record host-settings
     (appearance (string-field "appearance" value))
     (language (string-field "language" value))
     (spell-check (bool-field "spellCheck" value))
     (auto-correction (bool-field "autoCorrection" value))
     (sidebar-tabs (string-vector (util/member "sidebarTabs" value)))
     (base-url (string-field "baseURL" value))
     (version (string-field "version" value))
     (revision (string-field "revision" value)))))

(defn runtime-log-record [value]
  (record host-runtime-log-record
    (id (string-field "id" value))
    (level (string-field "level" value))
    (source (string-field "source" value))
    (timestamp (string-field "timestamp" value))
    (message (string-field "message" value))))

(defn composer-asset [value payload]
  (record host-composer-asset
    (uuid (string-field "uuid" value))
    (title (string-field "title" value))
    (local-path (string-field "localPath" value))
    (payload payload)))

(defn ui-session [value]
  (record host-ui-session
    (graph-id (util/to-string-option (util/member "graphId" value)))
    (destination (string-field "destination" value))
    (draft (string-field "draft" value))
    (assets (mapv (fn [asset] (composer-asset asset (string-field "payload" asset)))
                  (util/to-list (util/member "assets" value))))
    (composer-expanded (bool-field "composerExpanded" value))
    (search-open (bool-field "searchOpen" value))
    (query (string-field "query" value))
    (app-path (string-vector (util/member "appPath" value)))
    (search-path (string-vector (util/member "searchPath" value)))
    (selected-page-id (util/to-string-option (util/member "selectedPageId" value)))
    (settings-open (bool-field "settingsOpen" value))))

(defn decode [kind payload]
  (try
    (let [value (json/from-string payload)]
      (match kind
        "settings" (Ok (settings value))
        "runtime-log" (Ok (Runtime_log (mapv runtime-log-record (util/to-list value))))
        "local-graph-ids" (Ok (Local_graph_ids (string-vector value)))
        "composer-asset" (Ok (Composer_asset (composer-asset value payload)))
        "save-ui-session" (Ok Save_ui_session)
        "restore-ui-session" (Ok (Restore_ui_session (ui-session value)))
        "composer-draft" (Ok (Composer_draft (util/to-string value)))
        "graph-loading" (Ok (Graph_loading (util/to-bool value)))
        "authentication"
        (Ok (Authentication
             (record host-authentication
               (state (string-field "state" value))
               (error-message (util/to-string-option (util/member "errorMessage" value))))))
        "open-quick-action" (Ok (Open_quick_action (util/to-string value)))
        "open-capture" (Ok Open_capture)
        _ (Error (str "Unsupported host update: " kind))))
    (catch (yojson/Json_error message)
      (Error (str "Invalid host update JSON: " message)))
    (catch (util/Type_error message _)
      (Error (str "Invalid " kind " host update: " message)))))
