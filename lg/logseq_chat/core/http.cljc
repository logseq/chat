(ns logseq-chat.http
  (:refer-clojure :exclude [send write-all])
  (:require [clojure.string :as string]
            [logseq-chat.api :as api]
            [ocaml.Unix :as unix]
            [ocaml.String :as text]
            [ocaml.Bytes :as bytes]
            [ocaml.Buffer :as buffer]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Printexc :as printexc]))

(type-record http-endpoint (scheme :string) (host :string) (port :int) (request-path :string))

(ffi https-send-raw [:string :string :string :string] :string
  {:ocaml "logseq_chat_https_send"})
(ffi https-upload-file-raw [:string :string :string :string :string] :string
  {:ocaml "logseq_chat_https_upload_file"})

(def request-timeout-seconds 30.0)

(defn unix-error-message [error]
  (match error
    (unix/Unix_error code operation argument)
    (str operation "(" argument "): " (unix/error-message code))
    _ (printexc/to-string error)))

(defn split-first-line [value]
  (if-some [index (text/index-opt value \newline)]
    (tuple (subs value 0 index) (subs value (inc index))) (tuple value "")))

(defn response-of-native [raw]
  (let [[status body] (split-first-line raw)]
    (if (= status "ERROR") (Error body)
        (if-some [code (stdlib/int-of-string-opt status)]
          (Ok (api/response code body)) (Error "invalid native HTTP response")))))

(defn parse-url [url]
  (let [[scheme rest default-port]
        (cond (string/starts-with? url "http://") (tuple "http" (subs url 7) 80)
              (string/starts-with? url "https://") (tuple "https" (subs url 8) 443)
              :else (tuple "" "" 0))]
    (if (= scheme "") (Error "only http:// and https:// Logseq API URLs are supported")
        (let [slash (or (text/index-opt rest \/) (count rest))
              authority (subs rest 0 slash)
              path (if (= slash (count rest)) "/" (subs rest slash))
              [host port] (if-some [colon (text/rindex-opt authority \:)]
                            (tuple (subs authority 0 colon)
                                   (stdlib/int-of-string (subs authority (inc colon))))
                            (tuple authority default-port))]
          (if (= host "") (Error "Logseq API URL host is empty")
              (Ok (record http-endpoint (scheme scheme) (host host) (port port) (request-path path))))))))

(defn write-all [fd payload]
  (loop [offset 0]
    (if (< offset (bytes/length payload))
      (let [written (unix/write fd payload offset (- (bytes/length payload) offset))]
        (if (= written 0) (stdlib/failwith "socket write returned 0")
            (recur (+ offset written))))
      (stdlib/ignore offset))))

(defn read-all [fd]
  (let [result (buffer/create 4096) chunk (bytes/create 4096)]
    (loop []
      (let [size (unix/read fd chunk 0 (bytes/length chunk))]
        (if (= size 0) (buffer/contents result)
            (do (buffer/add-subbytes result chunk 0 size) (recur)))))))

(defn find-substring [needle value]
  (loop [index 0]
    (cond (> (+ index (count needle)) (count value)) nil
          (= (subs value index (+ index (count needle))) needle) (Some index)
          :else (recur (inc index)))))

(defn split-response [response]
  (if-some [index (find-substring "\r\n\r\n" response)]
    (Ok (tuple (subs response 0 index) (subs response (+ index 4))))
    (Error "HTTP response did not contain headers")))

(defn header-field [name headers]
  (let [name (text/lowercase-ascii name)]
    (some (fn [line]
            (when-some [colon (text/index-opt line \:)]
              (when (= (text/lowercase-ascii (string/trim (subs line 0 colon))) name)
                (text/lowercase-ascii (string/trim (subs line (inc colon)))))))
          (text/split-on-char \newline headers))))

(defn content-length-of-headers [headers]
  (when-some [value (header-field "content-length" headers)]
    (stdlib/int-of-string-opt value)))

(defn transfer-encoding-is-chunked [headers]
  (if-some [value (header-field "transfer-encoding" headers)]
    (some (fn [part] (= (string/trim part) "chunked")) (text/split-on-char \, value)) false))

(defn host-header [endpoint]
  (if (= (:port endpoint) (if (= (:scheme endpoint) "https") 443 80))
    (:host endpoint) (str (:host endpoint) ":" (:port endpoint))))

(defn hex-length [value]
  (if-some [length (stdlib/int-of-string-opt (str "0x" (string/trim value)))]
    (if (>= length 0) (Ok length) (Error (str "invalid HTTP chunk size: " value)))
    (Error (str "invalid HTTP chunk size: " value))))

(defn ensure-buffer [fd result chunk needed]
  (loop []
    (if (>= (buffer/length result) needed) (Ok nil)
        (let [size (unix/read fd chunk 0 (bytes/length chunk))]
          (if (= size 0) (Error "HTTP chunked body ended early")
              (do (buffer/add-subbytes result chunk 0 size) (recur)))))))

(defn chunk-line-end [fd result chunk offset]
  (loop []
    (if-some [relative (find-substring "\r\n" (subs (buffer/contents result) offset))]
      (Ok (+ offset relative))
      (let* [_ (ensure-buffer fd result chunk (inc (buffer/length result)))] (recur)))))

(defn read-chunked-body [fd initial]
  (let [result (buffer/create (+ (count initial) 4096)) chunk (bytes/create 4096)]
    (buffer/add-string result initial)
    (loop [offset 0 parts []]
      (let* [crlf (chunk-line-end fd result chunk offset)]
        (let [line (subs (buffer/contents result) offset crlf)
              line (if-some [index (text/index-opt line \;)] (subs line 0 index) line)]
          (let* [size (hex-length line)]
            (if (= size 0) (Ok (string/join "" parts))
                (let [start (+ crlf 2) end (+ start size)]
                  (let* [_ (ensure-buffer fd result chunk (+ end 2))]
                    (recur (+ end 2) (conj parts (subs (buffer/contents result) start end))))))))))))

(defn read-header-end [fd result chunk]
  (loop []
    (if-some [index (find-substring "\r\n\r\n" (buffer/contents result))] (Ok index)
      (let [size (unix/read fd chunk 0 (bytes/length chunk))]
        (if (= size 0) (Error "HTTP response did not contain headers")
            (do (buffer/add-subbytes result chunk 0 size) (recur)))))))

(defn read-length-body [fd chunk initial length]
  (let [result (buffer/create length)]
    (buffer/add-string result initial)
    (loop []
      (let [current (buffer/length result)]
        (if (>= current length) (Ok (subs (buffer/contents result) 0 length))
            (let [size (unix/read fd chunk 0 (min (- length current) (bytes/length chunk)))]
              (if (= size 0) (Error "HTTP response ended before Content-Length bytes were read")
                  (do (buffer/add-subbytes result chunk 0 size) (recur)))))))))

(defn read-response [fd]
  (let [result (buffer/create 4096) chunk (bytes/create 4096)]
    (let* [end (read-header-end fd result chunk)]
      (let [raw (buffer/contents result) headers (subs raw 0 end) initial (subs raw (+ end 4))]
        (let* [body (if-some [length (content-length-of-headers headers)]
                     (read-length-body fd chunk initial length)
                     (if (transfer-encoding-is-chunked headers) (read-chunked-body fd initial)
                         (Ok (str initial (read-all fd)))))]
          (Ok (tuple headers body)))))))

(defn status-of-headers [headers]
  (if-some [end (text/index-opt headers \return)]
    (let [line (subs headers 0 end)]
      (match (text/split-on-char \space line)
        [_ code & _] (Ok (stdlib/int-of-string code))
        _ (Error (str "invalid HTTP status line: " line))))
    (Error "HTTP status line is missing")))

(defn configure-socket [fd]
  (unix/clear-nonblock fd)
  (unix/setsockopt-float fd (unix/SO_RCVTIMEO) request-timeout-seconds)
  (unix/setsockopt-float fd (unix/SO_SNDTIMEO) request-timeout-seconds))

(defn finish-nonblocking-connect [fd]
  (let [[_ writable _] (unix/select (list) (list fd) (list) request-timeout-seconds)]
    (if (empty? writable) (Error "HTTP connect timed out after 30s")
        (if-some [error (unix/getsockopt-error fd)] (Error (unix/error-message error))
          (do (configure-socket fd) (Ok fd))))))

(defn connect-address [fd address]
  (try
    (unix/connect fd (:ai-addr address))
    (configure-socket fd)
    (Ok fd)
    (catch (unix/Unix_error code operation argument)
      (if (or (= code (unix/EINPROGRESS)) (= code (unix/EWOULDBLOCK)) (= code (unix/EAGAIN)))
        (finish-nonblocking-connect fd)
        (Error (unix-error-message (unix/Unix_error code operation argument)))))
    (catch error (Error (unix-error-message error)))))

(defn try-addresses [addresses unresolved]
  (let [addresses (vec addresses)]
    (loop [index 0 first-error nil]
      (if (= index (count addresses)) (Error (or first-error unresolved))
          (let [address (nth addresses index)
                fd (unix/socket (:ai-family address) (:ai-socktype address) (:ai-protocol address))]
            (unix/set-nonblock fd)
            (match (connect-address fd address)
              (Ok fd) (Ok fd)
              (Error message)
              (do (unix/close fd)
                  (recur (inc index) (Some (or first-error message))))))))))

(defn connect [endpoint]
  (let [service (str (:port endpoint))
        addresses (unix/getaddrinfo (:host endpoint) service (list (unix/AI_SOCKTYPE (unix/SOCK_STREAM))))]
    (try-addresses (vec addresses) (str "could not resolve " (:host endpoint) ":" service))))

(defn send-http-body [request endpoint content-type extra-headers body]
  (let* [fd (connect endpoint)]
    (try
      (let [headers (string/join "\r\n"
                      (concat [(str (:method_ request) " " (:request-path endpoint) " HTTP/1.0")
                               (str "Host: " (host-header endpoint))
                               (str "Authorization: Bearer " (:token request))
                               "Accept: application/json" (str "Content-Type: " content-type)
                               "Connection: close" (str "Content-Length: " (text/length body))]
                              (map (fn [header]
                                     (match header (tuple name value) (str name ": " value)))
                                   extra-headers) ["" body]))]
        (write-all fd (bytes/of-string headers))
        (let* [[headers body] (read-response fd) status (status-of-headers headers)]
          (Ok (api/response status body))))
      (catch error (Error (unix-error-message error)))
      (finally (unix/close fd)))))

(defn send-http [request endpoint extra-headers body]
  (send-http-body request endpoint "application/json" extra-headers body))

(defn send-https [request]
  (let [[status body] (split-first-line (https-send-raw (:method_ request) (:url request)
                                                       (or (:body request) "") (:token request)))]
    (if (= status "ERROR") (Error body)
        (if-some [code (stdlib/int-of-string-opt status)]
          (Ok (api/response code body)) (Error (str "invalid HTTPS status: " status))))))

(defn send [request]
  (let* [endpoint (parse-url (:url request))]
    (if (= (:scheme endpoint) "https") (send-https request)
        (send-http request endpoint [] (or (:body request) "")))))

(defn read-file-bytes [path]
  (try
    (let [channel (stdlib/open-in-bin path)]
      (try (Ok (stdlib/really-input-string channel (stdlib/in-channel-length channel)))
           (finally (stdlib/close-in-noerr channel))))
    (catch error (Error (str "could not read upload file: " (unix-error-message error))))))

(defn upload-http [upload endpoint]
  (let* [body (read-file-bytes (:file-path upload))]
    (send-http-body (:request upload) endpoint (:content-type upload) (:headers upload) body)))

(defn upload-file [upload]
  (let* [endpoint (parse-url (:url (:request upload)))]
    (if (= (:scheme endpoint) "https")
      (response-of-native (https-upload-file-raw (:method_ (:request upload)) (:url (:request upload))
                                                (:file-path upload) (:content-type upload) (:token (:request upload))))
      (upload-http upload endpoint))))
