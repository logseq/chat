#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

CAMLprim value logseq_chat_https_send(value method, value url, value body, value token) {
  CAMLparam4(method, url, body, token);
  CAMLreturn(caml_copy_string("ERROR\nHTTPS transport is only available in Darwin mobile builds"));
}
