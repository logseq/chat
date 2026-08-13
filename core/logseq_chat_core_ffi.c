#include "logseq_chat_core_ffi.h"

#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <caml/mlvalues.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t logseq_chat_call_mutex = PTHREAD_MUTEX_INITIALIZER;
static int logseq_chat_runtime_started = 0;
static pthread_t logseq_chat_runtime_thread;
static char *logseq_chat_response = NULL;

static void ensure_ocaml_runtime(void) {
  if (!logseq_chat_runtime_started) {
    static char program_name[] = "logseq_chat_mobile";
    char *argv[] = {program_name, NULL};
    caml_startup(argv);
    logseq_chat_runtime_thread = pthread_self();
    logseq_chat_runtime_started = 1;
    caml_release_runtime_system();
  }
}

static const char *replace_response(const char *value) {
  size_t length = strlen(value);
  char *copy = malloc(length + 1);
  if (copy == NULL) {
    return
      "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":"
      "\"allocation_failure\",\"message\":\"Could not allocate the RPC response\"}}";
  }
  memcpy(copy, value, length + 1);
  free(logseq_chat_response);
  logseq_chat_response = copy;
  return logseq_chat_response;
}

static const char *call_ocaml(const char *request_json) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(request, result);
  const value *callback = caml_named_value("logseq_chat_mobile_call");
  if (callback == NULL) {
    response = replace_response(
      "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":"
      "\"missing_callback\",\"message\":\"OCaml RPC callback is not registered\"}}");
  } else {
    request = caml_copy_string(request_json == NULL ? "" : request_json);
    result = caml_callback_exn(*callback, request);
    if (Is_exception_result(result)) {
      response = replace_response(
        "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":"
        "\"ocaml_exception\",\"message\":\"The OCaml core raised an exception\"}}");
    } else {
      response = replace_response(String_val(result));
    }
  }
  CAMLreturnT(const char *, response);
}

const char *logseq_chat_call(const char *request_json) {
  const char *response;
  int needs_unregister = 0;

  pthread_mutex_lock(&logseq_chat_call_mutex);
  ensure_ocaml_runtime();

  if (!pthread_equal(pthread_self(), logseq_chat_runtime_thread)) {
    if (!caml_c_thread_register()) {
      response = replace_response(
        "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":"
        "\"ocaml_thread_registration_failed\",\"message\":\"Could not register the calling thread with the OCaml runtime\"}}");
      pthread_mutex_unlock(&logseq_chat_call_mutex);
      return response;
    }
    needs_unregister = 1;
  }
  caml_acquire_runtime_system();

  response = call_ocaml(request_json);

  caml_release_runtime_system();
  if (needs_unregister) {
    caml_c_thread_unregister();
  }
  pthread_mutex_unlock(&logseq_chat_call_mutex);
  return response;
}
