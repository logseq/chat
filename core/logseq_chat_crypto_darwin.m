#import <Foundation/Foundation.h>

#include <stdlib.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

extern char *logseq_chat_crypto_json(const char *request);

CAMLprim value logseq_chat_crypto_call(value request) {
  CAMLparam1(request);
  CAMLlocal1(result);
  char *response = NULL;
  caml_enter_blocking_section();
  response = logseq_chat_crypto_json(String_val(request));
  caml_leave_blocking_section();
  if (response == NULL) {
    CAMLreturn(caml_copy_string("{\"ok\":false,\"error\":\"crypto bridge returned null\"}"));
  }
  result = caml_copy_string(response);
  free(response);
  CAMLreturn(result);
}
