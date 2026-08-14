#ifndef LOGSEQ_CHAT_CORE_ABI_H
#define LOGSEQ_CHAT_CORE_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *logseq_chat_call(const char *request_json);
int32_t logseq_chat_gunzip_file(const char *input_path, const char *output_path);

#ifdef __cplusplus
}
#endif

#endif
