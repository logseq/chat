cmake_minimum_required(VERSION 3.22.1)

project(logseq_chat_jni C)

# Thin JNI shim between com.logseq.chat.NativeCore and the
# liblogseq_chat_core.so C ABI (shared/native/logseq_chat_core_ffi.h).
# The OCaml core is delivered as a prebuilt shared library per ABI; this
# shim forwards every call and converts between jbyteArray (raw UTF-8
# bytes, decoded by Kotlin as Charsets.UTF_8) and the core's const char*
# strings so non-ASCII text survives the round trip — NewStringUTF's
# modified UTF-8 would corrupt 4-byte sequences such as emoji.
add_library(logseq_chat_jni SHARED logseq_chat_jni.c)

find_library(log-lib log)

target_link_libraries(logseq_chat_jni ${log-lib})
