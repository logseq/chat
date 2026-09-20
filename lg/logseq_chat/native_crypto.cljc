(ns logseq-chat.native-crypto)

(ffi call-raw [:string] :string {:ocaml "logseq_chat_crypto_call"})
