#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

CAMLprim value logseq_chat_https_send(value method, value url, value body, value token) {
  CAMLparam4(method, url, body, token);
  CAMLreturn(caml_copy_string("ERROR\nHTTPS transport is only available in Darwin mobile builds"));
}

CAMLprim value logseq_chat_https_upload_file(value method, value url, value file_path,
                                              value content_type, value token) {
  CAMLparam5(method, url, file_path, content_type, token);
  CAMLreturn(caml_copy_string("ERROR\nHTTPS file upload is only available in Darwin mobile builds"));
}
