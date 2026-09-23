#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

/* ctypes's `string` view passes a plain char* and reads a char* back; an
   OCaml string value is already a pointer to its payload bytes, so the
   test callback's result can be returned directly as char*. */
CAMLprim value logseq_chat_crypto_call(value request) {
  CAMLparam1(request);
  CAMLlocal2(req, resp);
  req = caml_copy_string((const char *)request);
  resp = caml_callback(*caml_named_value("platform_crypto_test_call"), req);
  CAMLreturn(resp);
}
