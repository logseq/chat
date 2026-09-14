(ns logseq-chat.edn
  (:require [ocaml.package/melange-edn-native]
            [ocaml.Melange_edn_native :as edn]))

(defn ^:result<Melange_edn_native.any;string> decode [^string source]
  (try
    (Ok (edn/of-edn-string source))
    (catch (edn/Parse_error message)
      (Error message))
    (catch (Failure message)
      (Error message))
    (catch (Invalid_argument message)
      (Error message))))

(defn ^string encode [^:Melange_edn_native.any value]
  (edn/to-edn-string value))
