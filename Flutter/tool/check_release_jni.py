#!/usr/bin/env python3
"""Verify that the release shrinker preserves the native JNI entry points."""
import re
from pathlib import Path

mapping = Path(__file__).resolve().parents[1] / "build/app/outputs/mapping/release/mapping.txt"
text = mapping.read_text()
for class_name, methods in {
    "logseq.chat.AndroidHttpTransport": ["send", "uploadFile"],
    "logseq.chat.AndroidE2EECrypto": ["call"],
}.items():
    match = re.search(r"^" + re.escape(class_name) + r" -> " + re.escape(class_name) + r":\n(.*?)(?=^[^ #\n]|\Z)", text, re.MULTILINE | re.DOTALL)
    assert match, f"JNI class was removed or renamed: {class_name}"
    for method in methods:
        assert re.search(r"\b" + method + r"\([^\n]* -> " + method + r"$", match[1], re.MULTILINE), f"JNI method was removed or renamed: {class_name}.{method}"
print("PASS: release JNI transport and crypto entry points retain their names")
