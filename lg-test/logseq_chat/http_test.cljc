(ns logseq-chat.http-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as string]
            [logseq-chat.http :as http]
            [logseq-chat.api :as api]
            [ocaml.package/threads.posix]
            [ocaml.Thread :as thread]
            [ocaml.Unix :as unix]
            [ocaml.Sys :as sys]
            [ocaml.Stdlib :as stdlib]
            [ocaml.String :as text]
            [ocaml.Bytes :as bytes]
            [ocaml.Buffer :as buffer]
            [ocaml.Filename :as filename]))

(defn close-quietly [fd]
  (try (unix/close fd) (catch (unix/Unix_error _ _ _) (stdlib/ignore fd))))

(defn write-string [fd value]
  (loop [offset 0]
    (when (< offset (text/length value))
      (let [written (unix/write-substring fd value offset (- (text/length value) offset))]
        (when (= written 0) (stdlib/failwith "pipe write returned 0"))
        (recur (+ offset written))))))

(defn with-timeout [seconds f]
  (let [previous (sys/signal sys/sigalrm (sys/Signal_handle (fn [_] (stdlib/failwith "timed out"))))]
    (unix/alarm seconds)
    (try (f)
         (finally (unix/alarm 0) (sys/set-signal sys/sigalrm previous)))))

(defn read-keep-alive [response]
  (let [[read-fd write-fd] (unix/pipe)]
    (try
      (write-string write-fd response)
      (with-timeout 1 (fn [] (http/read-response read-fd)))
      (finally (close-quietly read-fd) (close-quietly write-fd)))))

(defn response-from-parts [parts]
  (let [[read-fd write-fd] (unix/pipe)
        writer (thread/create
                 (fn [_]
                   (try
                     (run! (fn [part] (write-string write-fd part) (thread/delay 0.001)) parts)
                     (finally (close-quietly write-fd))))
                 (stdlib/ignore 0))]
    (try (with-timeout 2 (fn [] (let* [[_ body] (http/read-response read-fd)] (Ok body))))
         (finally (close-quietly read-fd) (thread/join writer)))))

(deftest keep-alive-does-not-wait-for-eof
  (let [response (read-keep-alive "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n{}")]
    (is (= (Ok (tuple "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive" "{}")) response))))

(deftest chunked-keep-alive-does-not-wait-for-eof
  (is (= (Ok (tuple "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive" "hello world"))
         (read-keep-alive "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"))))

(deftest fragmented-and-invalid-responses
  (run!
    (fn [[parts expected]] (is (= expected (response-from-parts parts))))
    [(tuple ["HTTP/1.1 200 OK\r\nContent-Len" "gth: 5\r\n\r" "\nhe" "llo"] (Ok "hello"))
     (tuple ["HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, Chunked\r\n\r\n"
             "2;test=yes\r" "\nhe\r\n3\r\nllo\r\n0\r\n\r\n"] (Ok "hello"))
     (tuple ["HTTP/1.0 200 OK\r\nX-Test: yes\r\n\r\nhi" " there"] (Ok "hi there"))
     (tuple ["HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"] (Ok ""))
     (tuple ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhello"] (Ok "he"))
     (tuple ["HTTP/1.1 200 OK"] (Error "HTTP response did not contain headers"))
     (tuple ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi"]
            (Error "HTTP response ended before Content-Length bytes were read"))
     (tuple ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhi"]
            (Error "HTTP chunked body ended early"))
     (tuple ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nnope\r\n"]
            (Error "invalid HTTP chunk size: nope"))]))

(deftest native-response-and-endpoint-parsing
  (match (http/response-of-native "201\nhello\nworld")
    (Ok response) (do (is (= 201 (:status response))) (is (= "hello\nworld" (:body response))))
    (Error message) (stdlib/failwith message))
  (is (= (Error "transport failed") (http/response-of-native "ERROR\ntransport failed")))
  (is (= (Error "invalid native HTTP response") (http/response-of-native "bad\nbody")))
  (run! (fn [[url scheme host port path]]
          (match (http/parse-url url)
            (Ok endpoint)
            (do (is (= scheme (:scheme endpoint))) (is (= host (:host endpoint)))
                (is (= port (:port endpoint))) (is (= path (:request-path endpoint))))
            (Error message) (stdlib/failwith message)))
        [(tuple "http://localhost" "http" "localhost" 80 "/")
         (tuple "https://example.test/a?q=1" "https" "example.test" 443 "/a?q=1")
         (tuple "http://localhost:8123/a" "http" "localhost" 8123 "/a")]))

(deftest https-routes-to-native-transport
  (match (http/send (record api/api-request
                     (method_ "GET") (url "https://api-staging.logseq.io/api/v1/graphs")
                     (body None) (token "token")))
    (Ok _) (is true)
    (Error message) (is (not= "only http:// Logseq API URLs are supported" message))))

(deftest binary-upload-over-real-socket
  (let [server (unix/socket (unix/PF_INET) (unix/SOCK_STREAM) 0)
        path (filename/temp-file "logseq-chat-upload" ".bin")
        payload (str "\u0000" (text/make 5000 \x) "asset-bytes" (text/make 1 (Char/chr 255)) "中")]
    (try
      (unix/setsockopt server (unix/SO_REUSEADDR) true)
      (unix/bind server (unix/ADDR_INET unix/inet-addr-loopback 0))
      (unix/listen server 1)
      (let [port (match (unix/getsockname server) (unix/ADDR_INET _ port) port
                   _ (stdlib/failwith "expected an inet listen socket"))
            channel (stdlib/open-out-bin path)]
        (try (stdlib/output-string channel payload) (finally (stdlib/close-out channel)))
        (let [result (atom (Error "upload thread did not finish"))
              worker (thread/create
                       (fn [_]
                         (reset! result (http/upload-file
                           (record api/api-file-upload
                             (request (record api/api-request
                                        (method_ "PUT") (url (str "http://127.0.0.1:" port "/assets/graph/file.png"))
                                        (body None) (token "access-token")))
                             (file-path path) (content-type "image/png")
                             (headers (list (tuple "x-amz-meta-checksum" "abc123") (tuple "x-amz-meta-type" "png")))))))
                       (stdlib/ignore 0))
              [client _] (with-timeout 2 (fn [] (unix/accept server)))]
          (try
            (let [received (buffer/create 256)
                  chunk (bytes/create 1024)
                  request (with-timeout 2
                            (fn []
                              (loop []
                                (let [raw (buffer/contents received)]
                                  (if (and (string/includes? raw payload)
                                           (string/includes? raw "x-amz-meta-checksum: abc123")
                                           (string/includes? raw "PUT /assets/graph/file.png"))
                                    raw
                                    (let [size (unix/read client chunk 0 (bytes/length chunk))]
                                      (if (= size 0) raw
                                        (do (buffer/add-subbytes received chunk 0 size) (recur)))))))))]
              (is (string/includes? request payload))
              (is (string/includes? request (str "Content-Length: " (text/length payload))))
              (is (string/includes? request "x-amz-meta-checksum: abc123"))
              (is (string/includes? request "Content-Type: image/png"))
              (is (string/includes? request (str "Host: 127.0.0.1:" port)))
              (write-string client "HTTP/1.0 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
              (thread/join worker)
              (is (= (Ok (api/response 200 "{\"ok\":true}")) @result)))
            (finally (close-quietly client)))))
      (finally (close-quietly server) (when (sys/file-exists path) (sys/remove path))))))
