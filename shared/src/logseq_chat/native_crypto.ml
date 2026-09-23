let call_raw =
  let impl =
    lazy
      (Foreign.foreign "logseq_chat_crypto_call"
         Ctypes.(string @-> returning string))
  in
  fun request -> Lazy.force impl request
