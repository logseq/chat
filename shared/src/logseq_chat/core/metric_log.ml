let impl =
  lazy
    (Foreign.foreign "logseq_chat_metric_log"
       Ctypes.(string @-> returning void))

let available () =
  try
    Lazy.force impl "";
    true
  with _ -> false

let line message =
  (try Lazy.force impl message with _ -> ());
  prerr_endline message
