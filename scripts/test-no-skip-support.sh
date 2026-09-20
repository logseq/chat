#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

die() {
  echo "error: $*" >&2
  exit 1
}

[[ ! -e "$repo_root/Vendor/LUIAppleBackend" ]] \
  || die "Apple backend must come from the LUI package, not a local copy"

for path in \
  "$repo_root/Skip.env" \
  "$repo_root/Android/settings.gradle.kts" \
  "$repo_root/Android/app/build.gradle.kts" \
  "$repo_root/Sources/LogseqChat/Skip" \
  "$repo_root/Sources/LogseqChatModel/Skip" \
  "$repo_root/Tests/LogseqChatTests/Skip" \
  "$repo_root/Tests/LogseqChatModelTests/Skip"; do
  [[ ! -e "$path" ]] || die "legacy Skip artifact remains: ${path#"$repo_root/"}"
done

if grep -Eq 'source\.skip\.tools|Skip(UI|Foundation|Model|FFI|Test)|skipstone' "$repo_root/Package.swift"; then
  die "Package.swift still depends on Skip"
fi

if grep -REn '#(if|elseif).*(^|[^A-Za-z])!?SKIP([^A-Za-z]|$)' \
  "$repo_root/Sources" "$repo_root/Tests" \
  --include='*.swift' >/dev/null; then
  die "Swift sources still contain Skip conditional compilation"
fi

if grep -Fq '(proto/profile proto/AndroidOS proto/SwiftUIHost)' \
  "$repo_root/lg/logseq_chat/view.cljc"; then
  die "LG still registers the removed Android SwiftUI host"
fi

if grep -Eq 'SkipStone|Run skip gradle|Skip\.env|skip gradle' \
  "$repo_root/Darwin/LogseqChat.xcodeproj/project.pbxproj" \
  "$repo_root/Darwin/LogseqChat.xcconfig"; then
  die "the Apple project still invokes Skip"
fi

manifest="$repo_root/Flutter/android/app/src/main/AndroidManifest.xml"
shortcuts="$repo_root/Flutter/android/app/src/main/res/xml/shortcuts.xml"
widgets="$repo_root/Flutter/android/app/src/main/kotlin/com/logseq/chat/AndroidWidgets.kt"

grep -Fq 'android.app.shortcuts' "$manifest" \
  || die "Flutter Android manifest lost app shortcuts"
grep -Fq '.TodayJournalWidgetProvider' "$manifest" \
  || die "Flutter Android manifest lost the journal widget"
grep -Fq '.CaptureWidgetProvider' "$manifest" \
  || die "Flutter Android manifest lost the capture widget"
grep -Fq 'logseqchat://capture' "$shortcuts" \
  || die "Flutter Android shortcuts lost Capture"
grep -Fq 'logseqchat://journal' "$shortcuts" \
  || die "Flutter Android shortcuts lost Journal"
grep -Fq 'class TodayJournalWidgetProvider' "$widgets" \
  || die "Flutter Android journal widget provider is missing"
grep -Fq 'class CaptureWidgetProvider' "$widgets" \
  || die "Flutter Android capture widget provider is missing"

echo "No-Skip Flutter Android contract passed"
