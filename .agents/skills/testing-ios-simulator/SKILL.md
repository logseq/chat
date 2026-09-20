---
name: testing-ios-simulator
description: Build and launch the Logseq Chat iOS app in an iOS simulator on macOS arm64 (Xcode + cross OCaml toolchain), including the iOS SDK function-detection pitfalls in bootstrap-ios-ocaml.sh.
---

# Logseq Chat iOS Simulator Build & Launch

## Prerequisites
- macOS arm64 with Xcode installed (`xcodebuild -version` works).
- opam switch `5.5.0` with dune (`opam exec --switch=5.5.0 -- dune --version`).
- An iOS simulator: `xcrun simctl list devices available | grep iPhone`; boot one with
  `xcrun simctl boot <UDID>`.

## Build steps
1. `scripts/bootstrap-ios-ocaml.sh simulator` — builds host + cross OCaml 5.5.0 under
   `_build/apple-toolchains/ios/` (long first run; stamps skip rebuilds).
2. `scripts/build-mobile-ios-simulator.sh` — builds `core/logseq_chat_mobile_entry.exe.o`
   via dune context `ios_simulator`, then `swift build` (product `LogseqChatShell`),
   xcodebuild for the share/widget extensions, and assembles+codesigns
   `.build/LogseqChat.app`. Note: the script can exit non-zero at the end even when all
   artifacts are produced correctly — re-running it (incremental) and checking for
   `.build/LogseqChat.app/LogseqChat` is the practical check.
3. `xcrun simctl install booted .build/LogseqChat.app`
4. `xcrun simctl launch booted com.logseq.chat` → prints `com.logseq.chat: <pid>`;
   verify the process stays alive via
   `xcrun simctl spawn booted launchctl list | grep logseq`.
5. Screenshot: `xcrun simctl io booted screenshot out.png`.

## Pitfalls
- `bootstrap-ios-ocaml.sh` host `./configure` must pass `--without-zstd`, else
  zstd-compressed .cmi files break the LG toolchain later (LG2000 errors).
- Cross-compiling OCaml for iOS: configure's link-only `AC_CHECK_FUNC` detects symbols
  (pipe2, dup3, accept4, execvpe, prctl, secure_getenv, __secure_getenv) that link but
  are NOT declared in the iOS SDK headers → "call to undeclared function" errors under
  modern clang. Fix by passing `ac_cv_func_<name>=no` to the target configure. Check for
  more with a compile probe:
  `xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot <sdk> -c t.c`
  where t.c calls the function after including the SDK headers.
- First launch may show a local-network permission alert; dismiss it via Simulator UI.
- The app opens to a "Logseq Chat / Sign in" screen (Cognito hosted UI); going past it
  requires credentials.

## Devin Secrets Needed
- none for build/launch/screenshot.
