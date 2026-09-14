(ns logseq-chat.snapshot
  (:require [ocaml.package/melange-transit-core]
            [ocaml.package/melange-transit-native]
            [ocaml.package/yojson]
            [ocaml.Int64 :as int64]
            [ocaml.Char :as char]
            [ocaml.String :as byte-string]
            [ocaml.Stdlib :as stdlib]
            [ocaml.Rrbvec :as rrbvec]
            [ocaml.Transit_core.Json :as value]
            [ocaml.Transit_native.Transit.Json :as codec]))

(type-record snapshot-row
  (addr :int)
  (content :string)
  (addresses :option<string>))

(type-record snapshot-parser
  (max-frame-bytes :int)
  (buffer :ref<string>))

(type-record snapshot-progress
  (accepted-rows :int)
  (last-addr :option<int>)
  (has-root :bool)
  (has-tail :bool))

(type-record snapshot-import
  (graph-id :string)
  (schema-version :string)
  (baseline-t :int)
  (expected-rows :int)
  (progress :ref<snapshot-progress>))

(type-record snapshot-completed-import
  (graph-id :string)
  (schema-version :string)
  (applied-server-t :int)
  (row-count :int))

(defn create-parser [max-frame-bytes]
  (if (<= max-frame-bytes 0)
    (stdlib/invalid-arg "max_frame_bytes must be positive")
    (record snapshot-parser
      (max-frame-bytes max-frame-bytes)
      (buffer (atom "")))))

(defn uint32-be [source offset]
  (loop [index 0 length int64/zero]
    (if (= index 4)
      length
      (recur (inc index)
             (int64/logor (int64/shift-left length 8)
                          (int64/of-int (char/code (byte-string/get source (+ offset index)))))))))

(defn int-of-value [input]
  (match input
    (value/Int number) (Ok number)
    (value/Int64 number)
    (if (and (>= number int64/zero) (<= number (int64/of-int stdlib/max-int)))
      (Ok (int64/to-int number))
      (Error "snapshot row address must be a non-negative Transit integer"))
    _ (Error "snapshot row address must be a non-negative Transit integer")))

(defn optional-string [input]
  (match input
    value/Null (Ok None)
    (value/String text) (Ok (Some text))
    _ (Error "snapshot row addresses must be JSON text or nil")))

(defn decode-row [input]
  (match input
    (value/Array [addr (value/String content) addresses])
    (let* [addr (int-of-value addr)
           addresses (optional-string addresses)]
      (Ok (record snapshot-row (addr addr) (content content) (addresses addresses))))
    _ (Error "snapshot row must be [addr, content, addresses]")))

(defn decode-rows [payload]
  (try
    (match (codec/of-string payload)
      (value/Array values)
      (let [values (rrbvec/of-list values)]
        (loop [index 0 rows []]
          (if (= index (count values))
            (Ok rows)
            (let* [row (decode-row (nth values index))]
              (recur (inc index) (conj rows row))))))
      _ (Error "snapshot frame payload must be a Transit row array"))
    (catch (value/Decode_error message) (Error message))
    (catch (Yojson/Json_error message) (Error message))
    (catch (Failure message) (Error message))
    (catch (Invalid_argument message) (Error message))))

(defn consume [source max-frame-bytes]
  (loop [offset 0 rows []]
    (let [remaining (- (count source) offset)]
      (if (< remaining 4)
        (Ok (tuple offset rows))
        (let [length64 (uint32-be source offset)]
          (if (> length64 (int64/of-int max-frame-bytes))
            (Error "snapshot frame exceeds configured size limit")
            (let [length (int64/to-int length64)
                  end (+ offset 4 length)]
              (if (< (- remaining 4) length)
                (Ok (tuple offset rows))
                (let* [decoded (decode-rows (subs source (+ offset 4) end))]
                  (recur end (into rows decoded)))))))))))

(defn feed [parser chunk]
  (let [source (byte-string/cat @(:buffer parser) chunk)]
    (reset! (:buffer parser) source)
    (let* [[consumed rows] (consume source (:max-frame-bytes parser))]
      (reset! (:buffer parser) (subs source consumed))
      (Ok (rrbvec/to-list rows)))))

(defn finish-parser [parser]
  (if (empty? @(:buffer parser))
    (Ok (stdlib/ignore 0))
    (Error "incomplete framed snapshot stream")))

(defn create-import [graph-id schema-version baseline-t expected-rows]
  (record snapshot-import
    (graph-id graph-id)
    (schema-version schema-version)
    (baseline-t baseline-t)
    (expected-rows expected-rows)
    (progress (atom (record snapshot-progress
                      (accepted-rows 0) (last-addr None) (has-root false) (has-tail false))))))

(defn validate-rows [state rows]
  (loop [index 0 progress @(:progress state)]
    (if (= index (count rows))
      (Ok progress)
      (let [addr (:addr (nth rows index))
            ordered (match (:last-addr progress)
                      (Some previous) (> addr previous)
                      None true)]
        (if ordered
          (recur (inc index)
                 (record snapshot-progress
                   (accepted-rows (inc (:accepted-rows progress)))
                   (last-addr (Some addr))
                   (has-root (or (:has-root progress) (= addr 0)))
                   (has-tail (or (:has-tail progress) (= addr 1)))))
          (Error "snapshot row addresses must be strictly increasing"))))))

(defn accept-rows [state rows]
  (let* [progress (validate-rows state (rrbvec/of-list rows))]
    (if (> (:accepted-rows progress) (:expected-rows state))
      (Error "snapshot contains more rows than advertised")
      (do
        (reset! (:progress state) progress)
        (Ok (stdlib/ignore 0))))))

(defn finish-import [state]
  (let [progress @(:progress state)]
    (cond
      (< (:baseline-t state) 0) (Error "snapshot baseline cursor must be non-negative")
      (< (:expected-rows state) 0) (Error "snapshot expected row count must be non-negative")
      (not= (:accepted-rows progress) (:expected-rows state))
      (Error "snapshot row count does not match server metadata")
      (not (:has-root progress)) (Error "snapshot is missing DataScript root row 0")
      (not (:has-tail progress)) (Error "snapshot is missing DataScript tail row 1")
      :else (Ok (record snapshot-completed-import
                  (graph-id (:graph-id state))
                  (schema-version (:schema-version state))
                  (applied-server-t (:baseline-t state))
                  (row-count (:accepted-rows progress)))))))
