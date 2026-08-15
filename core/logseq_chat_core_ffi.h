#ifndef LOGSEQ_CHAT_CORE_FFI_H
#define LOGSEQ_CHAT_CORE_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

const char *logseq_chat_call(const char *request_json);
void logseq_chat_initialize(void);

#ifdef __cplusplus
}
#endif

#endif
