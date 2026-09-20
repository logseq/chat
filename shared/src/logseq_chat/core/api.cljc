(ns logseq-chat.api
  (:require [ocaml.package/yojson]
            [ocaml.package/unix]
            [clojure.string :as string]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [logseq-chat.cache-model :as model]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.String :as bytes]
            [ocaml.Char :as char]
            [ocaml.Buffer :as buffer]
            [ocaml.Filename :as filename]
            [ocaml.Unix :as unix]
            [ocaml.Stdlib :as stdlib]))

(type-record api-config
  (base-url :string) (graph-id :string) (graph-name :option<string>) (token :string))

(type-record api-request
  (method_ :string) (url :string) (body :option<string>) (token :string))

(type-record api-response (status :int) (body :string))

(type-record api-file-upload
  (request :api-request) (file-path :string) (content-type :string)
  (headers :list<tuple<string;string>>))

(type-record api-journal (uuid :string) (title :string) (journal-day :int))

(type-record api-graph
  (id :string) (name :string) (schema-version :option<string>) (e2ee :bool) (ready :bool))

(type-record api-user-keys (public-key :string) (encrypted-private-key :string))

(defn response [status body]
  (record api-response (status status) (body body)))

(defn epoch-ms [] (stdlib/int-of-float (* (unix/gettimeofday) 1000.0)))

(defn trim-slash [value]
  (if (string/ends-with? value "/") (subs value 0 (dec (count value))) value))

(defn api-root [config]
  (let [base (trim-slash (:base-url config))]
    (if (string/ends-with? base "/api") (subs base 0 (- (count base) 4)) base)))

(defn unreserved? [ch]
  (let [code (char/code ch)]
    (or (and (>= code 65) (<= code 90))
        (and (>= code 97) (<= code 122))
        (and (>= code 48) (<= code 57))
        (contains? #{45 95 46 126} code))))

(defn url-encode [value]
  (let [result (buffer/create (count value))
        hex "0123456789ABCDEF"]
    (dotimes [index (count value)]
      (let [ch (bytes/get value index)]
        (if (unreserved? ch)
          (buffer/add-char result ch)
          (let [code (char/code ch)]
            (buffer/add-string result "%")
            (buffer/add-char result (bytes/get hex (quot code 16)))
            (buffer/add-char result (bytes/get hex (mod code 16)))))))
    (buffer/contents result)))

(defn request [config method path body]
  (record api-request (method_ method) (url (str (api-root config) path))
    (body body) (token (:token config))))

(defn graph-path [config suffix]
  (str "/api/v1/graphs/" (url-encode (:graph-id config)) suffix))

(defn json-body [fields]
  (Some (json/to-string (tag Assoc (rrbvec/to-list fields)))))

(defn recent-blocks-request [config journal-day]
  (request config "GET"
    (graph-path config (str "/blocks?journal-only=true&journal-day-at-most=" journal-day
                            "&sort=created-at-desc&limit=100")) None))

(defn task-statuses-request [config]
  (request config "GET" (graph-path config "/search?q=Status&types=properties&limit=100") None))

(defn graphs-request [config] (request config "GET" "/graphs" None))

(defn create-graph-request [config name schema-version e2ee]
  (request config "POST" "/graphs"
    (json-body [(tuple "graph-name" (tag String name))
                (tuple "schema-version" (tag String schema-version))
                (tuple "graph-e2ee?" (tag Bool e2ee))
                (tuple "graph-ready-for-use?" (tag Bool false))])))

(defn initial-snapshot-upload-request [config file-path checksum]
  (record api-file-upload
    (request (request config "POST"
               (str "/sync/" (url-encode (:graph-id config))
                    "/snapshot/upload?reset=true&finished=true&checksum=" (url-encode checksum)) None))
    (file-path file-path) (content-type "application/transit+json") (headers (list))))

(defn user-keys-request [config] (request config "GET" "/e2ee/user-keys" None))

(defn graph-key-path [config] (str "/e2ee/graphs/" (url-encode (:graph-id config)) "/aes-key"))

(defn graph-key-request [config] (request config "GET" (graph-key-path config) None))

(defn upsert-graph-key-request [config encrypted-key]
  (request config "POST" (graph-key-path config)
    (json-body [(tuple "encrypted-aes-key" (tag String encrypted-key))])))

(defn encrypted-journal-page-request [config uuid title name journal-day]
  (request config "POST" (graph-path config "/pages")
    (json-body [(tuple "uuid" (tag String uuid)) (tuple "title" (tag String title))
                (tuple "name" (tag String name)) (tuple "journal-day" (tag Int journal-day))])))

(defn related-request [config resource uuid collection]
  (request config "GET"
    (graph-path config (str "/" resource "/" (url-encode uuid) "/" collection "?limit=100")) None))

(defn block-references-request [config uuid] (related-request config "blocks" uuid "references"))

(defn page-references-request [config uuid] (related-request config "pages" uuid "references"))

(defn tag-objects-request [config uuid] (related-request config "tags" uuid "objects"))

(defn page-fields [page-id]
  (match page-id None [] (Some id) [(tuple "page-id" (tag String id))]))

(defn block-json [uuid text]
  (tag Assoc (list (tuple "uuid" (tag String uuid)) (tuple "title" (tag String text)))))

(defn capture-request [page-id config uuid text]
  (request config "POST" (graph-path config "/capture")
    (json-body (conj (page-fields page-id) (tuple "blocks" (tag List (list (block-json uuid text))))))))

(defn child-block-request [config parent-uuid uuid text]
  (request config "POST" (graph-path config (str "/blocks/" (url-encode parent-uuid) "/children"))
    (json-body [(tuple "position" (tag String "append"))
                (tuple "blocks" (tag List (list (block-json uuid text))))])))

(defn task-request [page-id config uuid status text]
  (request config "POST" (graph-path config "/tasks")
    (json-body (into [(tuple "uuid" (tag String uuid)) (tuple "title" (tag String text))
                      (tuple "status" (tag String status))] (page-fields page-id)))))

(defn asset-upload-request [page-id config uuid file-name size checksum file-path content-type]
  (record api-file-upload
    (request (request config "POST"
               (graph-path config
                 (str "/assets?uuid=" (url-encode uuid) "&file-name=" (url-encode file-name)
                      "&size=" size "&checksum=" (url-encode checksum)
                      (match page-id None "" (Some id) (str "&page-id=" (url-encode id))))) None))
    (file-path file-path) (content-type content-type) (headers (list))))

(defn move-block-request [config uuid target-uuid]
  (request config "POST" (graph-path config "/block-moves")
    (json-body [(tuple "block-ids" (tag List (list (tag String uuid))))
                (tuple "target-id" (tag String target-uuid)) (tuple "position" (tag String "last-child"))])))

(defn encrypted-asset-upload-request [config uuid file-name title page-id size upload-size checksum file-path]
  (record api-file-upload
    (request (request config "POST"
               (graph-path config
                 (str "/assets?uuid=" (url-encode uuid) "&file-name=" (url-encode file-name)
                      "&size=" size "&upload-size=" upload-size "&checksum=" (url-encode checksum)
                      "&title=" (url-encode title) "&page-id=" (url-encode page-id))) None))
    (file-path file-path) (content-type "text/plain") (headers (list))))

(defn member [name input]
  (match input (tag Assoc _) (json-util/member name input) _ (tag Null)))

(defn option-string-member [name input]
  (match (member name input) (tag String value) (Some value) _ None))

(defn string-member [name input]
  (match (option-string-member name input) (Some value) value None ""))

(defn int-member [name input]
  (match (member name input) (tag Int value) value _ 0))

(defn list-member [name input]
  (match (member name input) (tag List values) values _ (list)))

(defn created-block-uuid-from-body [body]
  (let [input (json/from-string body)]
    (match input
      (tag Assoc _)
      (let [uuid (string-member "uuid" input)]
        (if (not (empty? (string/trim uuid)))
          uuid
          (match (list-member "blocks" input)
            [(tag Assoc fields) & _]
            (let [uuid (string-member "uuid" (tag Assoc fields))]
              (if (empty? (string/trim uuid))
                (stdlib/failwith "creation response block is missing uuid") uuid))
            _ (stdlib/failwith "creation response is missing uuid"))))
      _ (stdlib/failwith "creation response must be an object"))))

(defn normalize-asset-type [value]
  (let [value (string/lower-case (string/trim value))]
    (case value
      "image/jpeg" "jpeg" "image/jpg" "jpg" "image/png" "png" "image/gif" "gif"
      "image/heic" "heic" "image/webp" "webp"
      "audio/mp4" "m4a" "audio/m4a" "m4a" "audio/x-m4a" "m4a"
      "audio/mpeg" "mp3" "audio/wav" "wav" "audio/x-wav" "wav"
      "application/pdf" "pdf" "application/octet-stream" "bin"
      (match (bytes/index-opt value \/)
        (Some index)
        (if (< (inc index) (count value))
          (let [suffix (subs value (inc index))]
            (if (string/starts-with? suffix "x-") (subs suffix 2) suffix))
          value)
        None value))))

(defn asset-file-name [file-name asset-type]
  (let [extension (normalize-asset-type asset-type)]
    (if (or (not (empty? (filename/extension file-name))) (empty? extension))
      file-name (str file-name "." extension))))

(defn content-type-for-asset-type [asset-type]
  (case (normalize-asset-type asset-type)
    "jpg" "image/jpeg" "jpeg" "image/jpeg" "png" "image/png" "gif" "image/gif"
    "heic" "image/heic" "webp" "image/webp" "m4a" "audio/mp4" "mp3" "audio/mpeg"
    "wav" "audio/wav" "pdf" "application/pdf" "application/octet-stream"))

(defn raw-asset-upload-request [config uuid asset-type checksum file-path content-type]
  (let [asset-type (normalize-asset-type asset-type)]
    (record api-file-upload
      (request (request config "PUT"
                 (str "/assets/" (url-encode (:graph-id config)) "/" (url-encode uuid)
                      "." (url-encode asset-type)) None))
      (file-path file-path) (content-type content-type)
      (headers (list (tuple "x-amz-meta-checksum" checksum) (tuple "x-amz-meta-type" asset-type))))))

(defn update-block-request [config uuid title]
  (request config "PATCH" (graph-path config (str "/blocks/" (url-encode uuid)))
    (json-body [(tuple "title" (tag String title))])))

(defn tx-batch-request [config t-before tx-id outliner-op tx]
  (request config "POST" (str "/sync/" (url-encode (:graph-id config)) "/tx/batch")
    (json-body [(tuple "t-before" (tag Int t-before))
                (tuple "txs" (tag List (list (tag Assoc (list (tuple "tx-id" (tag String tx-id))
                                                             (tuple "tx" (tag String tx))
                                                             (tuple "outliner-op" (tag String outliner-op)))))))])))

(defn update-block-status-request [config uuid status]
  (request config "PUT" (graph-path config (str "/blocks/" (url-encode uuid) "/properties/Status"))
    (json-body [(tuple "value" (tag String status))])))

(defn summary-of-json [input]
  (let [uuid (string-member "uuid" input) title (string-member "title" input)]
    (when (and (not (empty? uuid)) (not (empty? title)))
      (record model/entity-summary (uuid uuid) (title title)))))

(defn summaries-member [name input]
  (rrbvec/to-list (vec (keep summary-of-json (list-member name input)))))

(defn status-of-json [input]
  (let [uuid (string-member "uuid" input) title (string-member "title" input)
        icon (member "icon" input)]
    (when (and (not (empty? uuid)) (not (empty? title)))
      (record model/status
        (uuid uuid) (title title) (ident (option-string-member "ident" input))
        (icon-type (option-string-member "type" icon)) (icon-id (option-string-member "id" icon))
        (icon-color (option-string-member "color" icon))))))

(defn status-choices [input]
  (rrbvec/to-list (vec (keep status-of-json (list-member "choices" input)))))

(defn statuses-from-property-body [body]
  (let [input (json/from-string body)]
    (match (member "results" input)
      (tag List properties)
      (match (some (fn [property]
                     (when (= (string-member "ident" property) "logseq.property/status")
                       (status-choices property))) properties)
        (Some choices) choices None (list))
      _ (status-choices input))))

(defn block-of-json [fallback-time input]
  (let [uuid (string-member "uuid" input) title (string-member "title" input)]
    (when (and (not (empty? uuid)) (not (empty? title)))
      (record model/block
        (uuid uuid) (title title) (page-id (string-member "page-id" input))
        (parent-id (option-string-member "parent-id" input)) (order (option-string-member "order" input))
        (created-at (let [value (int-member "created-at" input)] (if (= value 0) fallback-time value)))
        (updated-at (let [value (int-member "updated-at" input)] (if (= value 0) fallback-time value)))
        (sync-status "synced") (tags (summaries-member "tags" input))
        (references (summaries-member "references" input)) (breadcrumbs (summaries-member "breadcrumbs" input))
        (status (status-of-json (member "status" input))) (is-asset false)
        (asset-type (option-string-member "asset-type" input))
        (asset-size (match (member "asset-size" input) (tag Int value) (Some value) _ None))
        (asset-checksum (option-string-member "asset-checksum" input)) (local-path None) (journal None)))))

(defn blocks-member [key input]
  (rrbvec/to-list (vec (keep (fn [value] (block-of-json 0 value)) (list-member key input)))))

(defn blocks-from-list-body [key body] (blocks-member key (json/from-string body)))

(defn journal-of-json [input]
  (let [uuid (string-member "uuid" input) day (int-member "journal-day" input)]
    (when (and (not (empty? uuid)) (> day 0))
      (record api-journal (uuid uuid) (title (string-member "title" input)) (journal-day day)))))

(defn feed-from-body [body]
  (let [input (json/from-string body)]
    (tuple (blocks-member "blocks" input)
           (rrbvec/to-list (vec (keep journal-of-json (list-member "journals" input)))))))

(defn bool-member [default name input]
  (match (member name input) (tag Bool value) value _ default))

(defn nonempty-string-member [name input]
  (match (option-string-member name input)
    (Some value) (if (empty? value) None (Some value)) None None))

(defn graph-of-json [input]
  (match (nonempty-string-member "graph-id" input)
    None None
    (Some id)
    (Some (record api-graph
            (id id) (name (match (nonempty-string-member "graph-name" input) (Some name) name None id))
            (schema-version (nonempty-string-member "schema-version" input))
            (e2ee (bool-member true "graph-e2ee?" input))
            (ready (bool-member false "graph-ready-for-use?" input))))))

(defn graphs-from-graphs-body [body]
  (rrbvec/to-list (vec (keep graph-of-json (list-member "graphs" (json/from-string body))))))

(defn graph-from-graphs-body [body]
  (match (graphs-from-graphs-body body)
    [graph & _] (Some (tuple (:id graph) (Some (:name graph)))) _ None))

(defn user-keys-from-body [body]
  (let [input (json/from-string body)]
    (match input
      (tag Assoc _)
      (let [required (fn [name]
                       (match (nonempty-string-member name input)
                         (Some value) value
                         None (stdlib/failwith (str "user keys response is missing " name))))]
        (record api-user-keys (public-key (required "public-key"))
          (encrypted-private-key (required "encrypted-private-key"))))
      _ (stdlib/failwith "user keys response must be an object"))))

(defn graph-key-from-body [body]
  (let [input (json/from-string body)]
    (match input
      (tag Assoc _)
      (match (nonempty-string-member "encrypted-aes-key" input)
        (Some value) value None (stdlib/failwith "graph key response is missing encrypted-aes-key"))
      _ (stdlib/failwith "graph key response must be an object"))))
