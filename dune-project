(lang dune 3.17)

(name logseq_chat)

(package
 (name logseq_chat)
 (synopsis "Logseq chat mobile core backed by DataScript OCaml")
 (allow_empty)
 (depends
  (ocaml (>= 5.5.0))
  dune
  datascript_ocaml
  datascript-ocaml-native
  melange-edn-native
  melange-transit-native
  mldoc
  ocaml-fsrs
  yojson))
