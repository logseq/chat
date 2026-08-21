#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

CAMLprim value logseq_chat_crypto_call(value request) {
  CAMLparam1(request);
  (void)request;
  CAMLreturn(caml_copy_string("{\"ok\":false,\"error\":\"Android crypto is not implemented\"}"));
}
