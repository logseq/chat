#include "logseq_chat_core_ffi.h"

#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <caml/mlvalues.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t logseq_chat_runtime_once = PTHREAD_ONCE_INIT;
static pthread_t logseq_chat_runtime_thread;
static _Thread_local char *logseq_chat_response = NULL;

static void start_ocaml_runtime(void) {
  static char program_name[] = "logseq_chat_mobile";
  char *argv[] = {program_name, NULL};
  caml_startup(argv);
  logseq_chat_runtime_thread = pthread_self();
  caml_release_runtime_system();
}

static void ensure_ocaml_runtime(void) {
  pthread_once(&logseq_chat_runtime_once, start_ocaml_runtime);
}

void logseq_chat_initialize(void) {
  ensure_ocaml_runtime();
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

  ensure_ocaml_runtime();

  if (!pthread_equal(pthread_self(), logseq_chat_runtime_thread)) {
    if (!caml_c_thread_register()) {
      response = replace_response(
        "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":"
        "\"ocaml_thread_registration_failed\",\"message\":\"Could not register the calling thread with the OCaml runtime\"}}");
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
  return response;
}

static int acquire_ocaml_runtime(void) {
  ensure_ocaml_runtime();
  if (pthread_equal(pthread_self(), logseq_chat_runtime_thread)) {
    caml_acquire_runtime_system();
    return 0;
  }
  if (!caml_c_thread_register()) {
    return -1;
  }
  caml_acquire_runtime_system();
  return 1;
}

static void release_ocaml_runtime(int registration) {
  caml_release_runtime_system();
  if (registration == 1) {
    caml_c_thread_unregister();
  }
}

static const char *missing_lui_callback(void) {
  return replace_response("");
}

static const char *call_lui0(const char *name) {
  const char *response;
  CAMLparam0();
  CAMLlocal1(result);
  const value *callback = caml_named_value(name);
  if (callback == NULL) {
    response = missing_lui_callback();
  } else {
    result = caml_callback_exn(*callback, Val_unit);
    response = Is_exception_result(result)
      ? missing_lui_callback()
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_int(const char *name, int64_t number) {
  const char *response;
  CAMLparam0();
  CAMLlocal1(result);
  const value *callback = caml_named_value(name);
  if (callback == NULL) {
    response = missing_lui_callback();
  } else {
    result = caml_callback_exn(*callback, Val_long(number));
    response = Is_exception_result(result)
      ? missing_lui_callback()
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_initialize(int32_t platform_code, int32_t host_code) {
  const char *response;
  CAMLparam0();
  CAMLlocal1(result);
  const value *callback = caml_named_value("logseq_chat_lui_init");
  if (callback == NULL) {
    response = missing_lui_callback();
  } else {
    result = caml_callback2_exn(
      *callback,
      Val_long(platform_code),
      Val_long(host_code));
    response = Is_exception_result(result)
      ? missing_lui_callback()
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_text(int64_t node, const char *text) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(text_value, result);
  const value *callback = caml_named_value("logseq_chat_lui_text_changed");
  if (callback == NULL || text == NULL) {
    response = missing_lui_callback();
  } else {
    text_value = caml_copy_string(text);
    result = caml_callback2_exn(*callback, Val_long(node), text_value);
    response = Is_exception_result(result)
      ? missing_lui_callback()
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_string(const char *name, const char *text) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(text_value, result);
  const value *callback = caml_named_value(name);
  if (callback == NULL || text == NULL) {
    response = missing_lui_callback();
  } else {
    text_value = caml_copy_string(text);
    result = caml_callback_exn(*callback, text_value);
    response = Is_exception_result(result)
      ? missing_lui_callback()
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_two_strings(const char *name, const char *left,
                                        const char *right) {
  const char *response;
  CAMLparam0();
  CAMLlocal3(left_value, right_value, result);
  const value *callback = caml_named_value(name);
  if (callback == NULL || left == NULL || right == NULL) {
    response = missing_lui_callback();
  } else {
    left_value = caml_copy_string(left);
    right_value = caml_copy_string(right);
    result = caml_callback2_exn(*callback, left_value, right_value);
    response = Is_exception_result(result)
      ? missing_lui_callback()
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_bool(int64_t node, int32_t checked) {
  const char *response;
  CAMLparam0();
  CAMLlocal1(result);
  const value *callback = caml_named_value("logseq_chat_lui_toggle_changed");
  if (callback == NULL) {
    response = missing_lui_callback();
  } else {
    result = caml_callback2_exn(*callback, Val_long(node), Val_bool(checked != 0));
    response = Is_exception_result(result)
      ? missing_lui_callback()
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_double(int64_t node, double number) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(number_value, result);
  const value *callback = caml_named_value("logseq_chat_lui_value_changed");
  if (callback == NULL) {
    response = missing_lui_callback();
  } else {
    number_value = caml_copy_double(number);
    result = caml_callback2_exn(*callback, Val_long(node), number_value);
    response = Is_exception_result(result)
      ? missing_lui_callback()
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_resolve_effect(int64_t effect_id, int32_t succeeded,
                                           const char *message) {
  const char *response;
  CAMLparam0();
  CAMLlocal2(message_value, result);
  const value *callback = caml_named_value("logseq_chat_lui_resolve_effect");
  if (callback == NULL) {
    response = missing_lui_callback();
  } else {
    message_value = caml_copy_string(message == NULL ? "" : message);
    result = caml_callback3_exn(
      *callback,
      Val_long(effect_id),
      Val_bool(succeeded != 0),
      message_value);
    response = Is_exception_result(result)
      ? missing_lui_callback()
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

static const char *call_lui_extension_event(
    int64_t node, const char *identifier, const char *name, const char *text,
    int64_t number) {
  const char *response;
  CAMLparam0();
  CAMLlocal4(identifier_value, name_value, text_value, result);
  value arguments[5];
  const value *callback = caml_named_value("logseq_chat_lui_extension_event");
  if (callback == NULL || identifier == NULL || name == NULL || text == NULL) {
    response = missing_lui_callback();
  } else {
    identifier_value = caml_copy_string(identifier);
    name_value = caml_copy_string(name);
    text_value = caml_copy_string(text);
    arguments[0] = Val_long(node);
    arguments[1] = identifier_value;
    arguments[2] = name_value;
    arguments[3] = text_value;
    arguments[4] = Val_long(number);
    result = caml_callbackN_exn(*callback, 5, arguments);
    response = Is_exception_result(result)
      ? missing_lui_callback()
      : replace_response(String_val(result));
  }
  CAMLreturnT(const char *, response);
}

#define LUI_RUNTIME_CALL(expression) \
  int registration = acquire_ocaml_runtime(); \
  if (registration < 0) { return missing_lui_callback(); } \
  const char *response = (expression); \
  release_ocaml_runtime(registration); \
  return response

const char *logseq_chat_lui_initialize(int32_t platform_code, int32_t host_code) {
  LUI_RUNTIME_CALL(call_lui_initialize(platform_code, host_code));
}

const char *logseq_chat_lui_press(int64_t node) {
  LUI_RUNTIME_CALL(call_lui_int("logseq_chat_lui_press", node));
}

const char *logseq_chat_lui_long_press(int64_t node) {
  LUI_RUNTIME_CALL(call_lui_int("logseq_chat_lui_long_press", node));
}

const char *logseq_chat_lui_text_changed(int64_t node, const char *text) {
  LUI_RUNTIME_CALL(call_lui_text(node, text));
}

const char *logseq_chat_lui_submit(int64_t node) {
  LUI_RUNTIME_CALL(call_lui_int("logseq_chat_lui_submit", node));
}

const char *logseq_chat_lui_toggle_changed(int64_t node, int32_t checked) {
  LUI_RUNTIME_CALL(call_lui_bool(node, checked));
}

const char *logseq_chat_lui_change(int64_t node) {
  LUI_RUNTIME_CALL(call_lui_int("logseq_chat_lui_change", node));
}

const char *logseq_chat_lui_value_changed(int64_t node, double value) {
  LUI_RUNTIME_CALL(call_lui_double(node, value));
}

const char *logseq_chat_lui_dismiss(int64_t node) {
  LUI_RUNTIME_CALL(call_lui_int("logseq_chat_lui_dismiss", node));
}

const char *logseq_chat_lui_double_press(int64_t node) {
  LUI_RUNTIME_CALL(call_lui_int("logseq_chat_lui_double_press", node));
}

const char *logseq_chat_lui_extension_event(
    int64_t node, const char *identifier, const char *name, const char *text,
    int64_t value) {
  LUI_RUNTIME_CALL(
      call_lui_extension_event(node, identifier, name, text, value));
}

const char *logseq_chat_lui_dispose(void) {
  LUI_RUNTIME_CALL(call_lui0("logseq_chat_lui_dispose"));
}

const char *logseq_chat_lui_take_effect(void) {
  LUI_RUNTIME_CALL(call_lui0("logseq_chat_lui_take_effect"));
}

const char *logseq_chat_lui_resolve_effect(int64_t effect_id, int32_t succeeded,
                                           const char *message) {
  LUI_RUNTIME_CALL(call_lui_resolve_effect(effect_id, succeeded, message));
}

const char *logseq_chat_lui_apply_snapshot(const char *response_json) {
  LUI_RUNTIME_CALL(call_lui_string("logseq_chat_lui_apply_snapshot", response_json));
}

const char *logseq_chat_lui_apply_host_update(const char *kind,
                                              const char *payload_json) {
  LUI_RUNTIME_CALL(call_lui_two_strings(
      "logseq_chat_lui_apply_host_update", kind, payload_json));
}
