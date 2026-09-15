#include <caml/callback.h>
#include <caml/memory.h>

CAMLprim value logseq_chat_crypto_call(value request) {
  CAMLparam1(request);
  CAMLreturn(caml_callback(*caml_named_value("platform_crypto_test_call"), request));
}
