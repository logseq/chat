(ns logseq-chat.edn
  (:require [ocaml.package/melange-edn-native]
            [ocaml.Melange_edn_native :as edn]))

(defn decode [source]
  (try
    (Ok (edn/of-edn-string source))
    (catch (edn/Parse_error message)
      (Error message))
    (catch (Failure message)
      (Error message))
    (catch (Invalid_argument message)
      (Error message))))

(defn encode [value]
  (edn/to-edn-string value))
