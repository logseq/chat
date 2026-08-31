#ifndef LOGSEQ_CHAT_CORE_ABI_H
#define LOGSEQ_CHAT_CORE_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *logseq_chat_call(const char *request_json);
void logseq_chat_initialize(void);
const char *logseq_chat_lui_initialize(
    int32_t platform_code,
    int32_t host_code,
    int32_t authentication_code);
const char *logseq_chat_lui_appear(int64_t node);
const char *logseq_chat_lui_press(int64_t node);
const char *logseq_chat_lui_long_press(int64_t node);
const char *logseq_chat_lui_text_changed(int64_t node, const char *text);
const char *logseq_chat_lui_submit(int64_t node);
const char *logseq_chat_lui_toggle_changed(int64_t node, int32_t checked);
const char *logseq_chat_lui_change(int64_t node);
const char *logseq_chat_lui_value_changed(int64_t node, double value);
const char *logseq_chat_lui_dismiss(int64_t node);
const char *logseq_chat_lui_double_press(int64_t node);
const char *logseq_chat_lui_extension_event(
    int64_t node, const char *identifier, const char *name, const char *text,
    int64_t value);
const char *logseq_chat_lui_dispose(void);
const char *logseq_chat_lui_take_effect(void);
const char *logseq_chat_lui_resolve_effect(int64_t effect_id, int32_t succeeded,
                                           const char *message);
const char *logseq_chat_lui_apply_snapshot(const char *response_json);
const char *logseq_chat_lui_apply_host_update(const char *kind,
                                              const char *payload_json);
int32_t logseq_chat_gunzip_file(const char *input_path, const char *output_path);

#ifdef __cplusplus
}
#endif

#endif
