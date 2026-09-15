(ns logseq-chat.api-test
  (:require [clojure.test :refer [deftest is]]
            [logseq-chat.api :as api]
            [ocaml.Yojson.Basic :as json]
            [ocaml.Yojson.Basic.Util :as json-util]
            [ocaml.Stdlib :as stdlib]))

(def config (record api/api-config (base-url "https://api.example")
              (graph-id "graph-1") (graph-name None) (token "token")))

(defn single-block [body]
  (let [blocks (vec (api/blocks-from-list-body "results" body))]
    (is (= 1 (count blocks)))
    (nth blocks 0)))

(deftest url-encoding-and-secure-metadata-defaults
  (is (= "a%20b%2F%3F%23%25%2B%C3%A9-_.~" (api/url-encode "a b/?#%+é-_.~")))
  (let [graphs (vec (api/graphs-from-graphs-body "{\"graphs\":[null,{}, {\"graph-id\":\"\"},{\"graph-id\":\"safe\",\"graph-name\":\"\",\"schema-version\":\"\",\"graph-e2ee?\":\"false\",\"graph-ready-for-use?\":1}]}"))]
    (is (= 1 (count graphs)))
    (let [graph (nth graphs 0)]
      (is (= "safe" (:id graph))) (is (= "safe" (:name graph)))
      (is (nil? (:schema-version graph))) (is (:e2ee graph)) (is (not (:ready graph)))))
  (run! (fn [body] (is (thrown? Failure (api/created-block-uuid-from-body body))))
        ["[]" "{\"uuid\":\" \",\"blocks\":[]}" "{\"blocks\":[{\"uuid\":\"\"}]}"]))

(deftest block-timestamps-and-semantics
  (let [explicit (single-block "{\"results\":[{\"uuid\":\"block-explicit\",\"title\":\"Explicit\",\"order\":\"a1\",\"created-at\":1776000000000,\"updated-at\":1776000100000}]}")
        missing (single-block "{\"results\":[{\"uuid\":\"block-missing\",\"title\":\"Missing\"}]}")
        semantic (single-block "{\"results\":[{\"uuid\":\"semantic\",\"title\":\"Review [[Project]]\",\"tags\":[{\"uuid\":\"tag-1\",\"title\":\"Project\"}],\"references\":[{\"uuid\":\"page-1\",\"title\":\"Project\"}],\"status\":{\"uuid\":\"status-1\",\"ident\":\"logseq.property/status.todo\",\"title\":\"Todo\",\"icon\":{\"type\":\"tabler-icon\",\"id\":\"circle\"}},\"asset-type\":\"jpg\",\"asset-size\":2048,\"asset-checksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]}")]
    (is (= (Some "a1") (:order explicit)))
    (is (= 1776000000000 (:created-at explicit))) (is (= 1776000100000 (:updated-at explicit)))
    (is (= 0 (:created-at missing))) (is (= 0 (:updated-at missing)))
    (is (= ["Project"] (mapv :title (:tags semantic))))
    (is (= ["Project"] (mapv :title (:references semantic))))
    (is (= (Some "Todo") (some-> (:status semantic) :title)))
    (is (= (Some "circle") (some-> (:status semantic) :icon-id)))
    (is (= (Some "jpg") (:asset-type semantic))) (is (= (Some 2048) (:asset-size semantic))))
  (let [statuses (vec (api/statuses-from-property-body "{\"results\":[{\"uuid\":\"property-status\",\"ident\":\"logseq.property/status\",\"title\":\"Status\",\"choices\":[{\"uuid\":\"status-waiting\",\"ident\":\"user.status/waiting\",\"title\":\"Waiting\",\"icon\":{\"type\":\"tabler-icon\",\"id\":\"clock\",\"color\":\"#7c3aed\"}}]}]}"))]
    (is (= 1 (count statuses)))
    (let [status (nth statuses 0)]
      (is (= "Waiting" (:title status)))
      (is (= (Some "#7c3aed") (:icon-color status))))))

(deftest read-endpoints
  (is (= "GET" (:method_ (api/recent-blocks-request config 20260813))))
  (run! (fn [[request suffix]] (is (= (str "https://api.example" suffix) (:url request))))
        [(tuple (api/recent-blocks-request config 20260813) "/api/v1/graphs/graph-1/blocks?journal-only=true&journal-day-at-most=20260813&sort=created-at-desc&limit=100")
         (tuple (api/task-statuses-request config) "/api/v1/graphs/graph-1/search?q=Status&types=properties&limit=100")
         (tuple (api/graphs-request config) "/graphs")
         (tuple (api/block-references-request config "block-1") "/api/v1/graphs/graph-1/blocks/block-1/references?limit=100")
         (tuple (api/tag-objects-request config "tag-1") "/api/v1/graphs/graph-1/tags/tag-1/objects?limit=100")
         (tuple (api/page-references-request config "page-1") "/api/v1/graphs/graph-1/pages/page-1/references?limit=100")
         (tuple (api/user-keys-request config) "/e2ee/user-keys")
         (tuple (api/graph-key-request config) "/e2ee/graphs/graph-1/aes-key")])
  (is (= ["backlink"] (mapv :uuid (api/blocks-from-list-body "references" "{\"references\":[{\"uuid\":\"backlink\",\"title\":\"Uses Project\"}]}")))))

(deftest capture-and-task-bodies
  (run! (fn [[request body]] (is (= (Some body) (:body request))))
        [(tuple (api/capture-request None config "client-block" "Offline") "{\"blocks\":[{\"uuid\":\"client-block\",\"title\":\"Offline\"}]}")
         (tuple (api/capture-request (Some "journal-1") config "encrypted-block" "encrypted-title") "{\"page-id\":\"journal-1\",\"blocks\":[{\"uuid\":\"encrypted-block\",\"title\":\"encrypted-title\"}]}")
         (tuple (api/task-request None config "client-task" "waiting" "Follow up") "{\"uuid\":\"client-task\",\"title\":\"Follow up\",\"status\":\"waiting\"}")
         (tuple (api/task-request (Some "journal-1") config "encrypted-task" "waiting" "encrypted-title") "{\"uuid\":\"encrypted-task\",\"title\":\"encrypted-title\",\"status\":\"waiting\",\"page-id\":\"journal-1\"}")])
  (is (= "POST" (:method_ (api/task-request None config "client-task" "waiting" "Follow up")))))

(deftest status-and-transaction-requests
  (let [status (api/update-block-status-request config "task-1" "custom-waiting")
        tx (api/tx-batch-request config 42 "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" "split-block" "[\"~:db/add\"]")]
    (is (= "PUT" (:method_ status)))
    (is (= "https://api.example/api/v1/graphs/graph-1/blocks/task-1/properties/Status" (:url status)))
    (is (= (Some "{\"value\":\"custom-waiting\"}") (:body status)))
    (is (= "POST" (:method_ tx))) (is (= "https://api.example/sync/graph-1/tx/batch" (:url tx)))
    (is (= (Some "{\"t-before\":42,\"txs\":[{\"tx-id\":\"018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8\",\"tx\":\"[\\\"~:db/add\\\"]\",\"outliner-op\":\"split-block\"}]}") (:body tx)))))

(deftest asset-upload-metadata
  (let [upload (api/raw-asset-upload-request config "client-asset" "jpg" "abc123" "/documents/photo.jpg" "image/jpeg")
        encrypted (api/raw-asset-upload-request config "encrypted-asset" "jpg" "abc123" "/documents/encrypted-photo.transit" "text/plain")]
    (is (= "/documents/photo.jpg" (:file-path upload))) (is (= "image/jpeg" (:content-type upload)))
    (is (= "jpeg" (api/normalize-asset-type "image/jpeg")))
    (is (= "IMG_0002.jpeg" (api/asset-file-name "IMG_0002" "image/jpeg")))
    (is (= "image/jpeg" (api/content-type-for-asset-type "image/jpeg")))
    (is (= "PUT" (:method_ (:request upload))))
    (is (= "https://api.example/assets/graph-1/client-asset.jpg" (:url (:request upload))))
    (is (nil? (:body (:request upload))))
    (is (some #(= % (tuple "x-amz-meta-checksum" "abc123")) (:headers upload)))
    (is (some #(= % (tuple "x-amz-meta-type" "jpg")) (:headers upload)))
    (is (= "https://api.example/assets/graph-1/encrypted-asset.jpg" (:url (:request encrypted))))
    (is (= "text/plain" (:content-type encrypted)))))

(deftest creation-responses-and-feed
  (run! (fn [[body expected]] (is (= expected (api/created-block-uuid-from-body body))))
        [["{\"uuid\":\"server-asset\",\"title\":\"photo.jpg\",\"type\":\"jpg\",\"size\":2048,\"checksum\":\"abc123\"}" "server-asset"]
         ["{\"uuid\":\"server-task\",\"title\":\"Follow up\",\"status\":{\"title\":\"Todo\"}}" "server-task"]
         ["{\"page-id\":\"journal\",\"blocks\":[{\"uuid\":\"server-block\",\"title\":\"Offline\"}]}" "server-block"]])
  (let [[blocks journals] (api/feed-from-body "{\"blocks\":[{\"uuid\":\"block-1\",\"title\":\"Message\",\"page-id\":\"journal-new\",\"created-at\":1776000000000}],\"journals\":[{\"uuid\":\"journal-new\",\"title\":\"Aug 13th, 2026\",\"journal-day\":20260813}]}")]
    (is (= ["block-1"] (mapv :uuid blocks)))
    (is (= ["journal-new"] (mapv :uuid journals)))
    (is (= ["Aug 13th, 2026"] (mapv :title journals)))
    (is (= [20260813] (mapv :journal-day journals)))))

(deftest key-packages
  (let [upsert (api/upsert-graph-key-request config "wrapped")
        body (json/from-string (or (:body upsert) ""))]
    (is (= "POST" (:method_ upsert)))
    (is (= "wrapped" (json-util/to-string (json-util/member "encrypted-aes-key" body)))))
  (is (= "private-package" (:encrypted-private-key (api/user-keys-from-body "{\"public-key\":\"public\",\"encrypted-private-key\":\"private-package\"}"))))
  (is (= "graph-package" (api/graph-key-from-body "{\"encrypted-aes-key\":\"graph-package\"}"))))

(deftest graph-creation-and-discovery
  (let [configuration (record api/api-config (base-url "https://api.example.com/api")
                        (graph-id "") (graph-name None) (token "token"))
        request (api/create-graph-request configuration "Private notes" "65.33" true)
        body (json/from-string (or (:body request) ""))]
    (is (= "POST" (:method_ request))) (is (= "https://api.example.com/graphs" (:url request)))
    (is (= "Private notes" (json-util/to-string (json-util/member "graph-name" body))))
    (is (= "65.33" (json-util/to-string (json-util/member "schema-version" body))))
    (is (json-util/to-bool (json-util/member "graph-e2ee?" body)))
    (is (not (json-util/to-bool (json-util/member "graph-ready-for-use?" body)))))
  (let [graphs (vec (api/graphs-from-graphs-body "{\"graphs\":[{\"graph-id\":\"plain-1\",\"graph-name\":\"Plain\",\"schema-version\":\"65.33\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true},{\"graph-id\":\"encrypted-1\",\"graph-name\":\"Encrypted\",\"graph-e2ee?\":true,\"graph-ready-for-use?\":false}]}"))]
    (is (= 2 (count graphs)))
    (let [plain (nth graphs 0) encrypted (nth graphs 1)]
      (is (= (Some "65.33") (:schema-version plain)))
      (is (= "plain-1" (:id plain))) (is (= "Plain" (:name plain)))
      (is (not (:e2ee plain))) (is (:ready plain))
      (is (= "encrypted-1" (:id encrypted))) (is (:e2ee encrypted)) (is (not (:ready encrypted))))))

(deftest initial-snapshot-upload
  (let [configuration (record api/api-config (base-url "https://api.example.com/api")
                        (graph-id "graph id") (graph-name (Some "Fresh graph")) (token "token"))
        upload (api/initial-snapshot-upload-request configuration "/tmp/initial.snapshot" "0000000000000000")]
    (is (= "POST" (:method_ (:request upload))))
    (is (= "https://api.example.com/sync/graph%20id/snapshot/upload?reset=true&finished=true&checksum=0000000000000000" (:url (:request upload))))
    (is (= "application/transit+json" (:content-type upload)))
    (is (= "/tmp/initial.snapshot" (:file-path upload)))))
