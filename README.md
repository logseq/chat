# Logseq Chat

Logseq Chat is a native SwiftUI app for iOS and a Flutter Material app for
Android. Both clients share an LG application model and core, compiled to
OCaml and backed by the OCaml DataScript library.

Shared core sources live in `shared/src/logseq_chat/core`, with executable entry points
in `shared/src/logseq_chat/entry`. The `shared/native` directory contains Dune configuration and
native platform bridges; generated OCaml stays under `_build`. Core tests live
in `shared/test/logseq_chat`, retaining one LG test module for each original OCaml
test module. The core test gate also builds the seed and live-sync executables.

## Repository layout

- `apple/`: Swift package, app, extensions, Xcode workspace, and Apple tests.
- `flutter/`: Flutter Android app and its platform integration.
- `shared/src/`: LG application and core sources.
- `shared/test/`: LG tests.
- `shared/native/`: Dune configuration and native bridges.
- `tests/e2e/`: Maestro flows and fixtures.
- `scripts/`: build and validation commands, run from the repository root.
- `docs/`: design and development documentation.
- `duniverse/`: fetched OCaml dependencies; ignored by Git.

## iOS

Open `apple/Project.xcworkspace` and run the `LogseqChat App` scheme in Xcode.

The Apple backend comes from the `LUIAppleBackendStatic` product of the LUI
Swift package, pinned by Git revision in `apple/Package.swift` and `apple/Package.resolved`.
Use Swift 6.2 or later. Backend changes belong in the LUI repository.

The first iOS build creates a deployment-targeted OCaml 5.5 toolchain under
`_build/apple-toolchains`. Native dependencies and core objects are keyed by
compiler, target, and source fingerprints, so later builds reuse them. Set
`LOGSEQ_CHAT_APPLE_TOOLCHAIN_ROOT` to share the toolchain cache, or provide
`LOGSEQ_CHAT_IOS_TOOLCHAIN_PREFIX` to use an existing compatible compiler
directly.

## Android

Android is built exclusively from the Flutter project:

```sh
cd flutter
flutter pub get
flutter run
```

Build a debug APK or Play Store app bundle with:

```sh
cd flutter
flutter build apk --debug
flutter build appbundle --release
```

The Flutter Android host includes Capture and Journal app shortcuts, Capture
and Today’s Journal home-screen widgets, inbound sharing, deep links, native
authentication, media services, and the OCaml core JNI library.

## iPhone shortcuts and widgets

Long-press the app icon for Voice and Quick Add.
The Shortcuts app exposes Quick Add, Record Audio, Today's Journal, and Capture
to Journal (text input). The Quick Capture home-screen widget includes recording
and capture buttons; Today's Journal opens the journal. On iOS 18 and later,
Quick Add and Record Audio are also available in Control Center and on the Lock
Screen. These entry points open the existing composer and recorder, including
when the app needs to launch first.

Both iOS build scripts include App Intents metadata and the widget extension.
Device builds select a compatible development profile for `com.logseq.chat.widgets`;
set `LOGSEQ_CHAT_IOS_WIDGET_PROFILE` in `.logseq-chat-ios-device.env` to specify one.
The extension and app must be signed by the same team, and their profiles must
include the target device.

## Testing

Do not run `swift test` in this repository because the XCTest bridge hangs in
the current environment. Use the supported gates instead:

```sh
swift build --package-path apple --disable-sandbox --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
(cd flutter && flutter analyze && flutter test)
opam exec --switch=5.5.0 -- dune build @shared/test/runtest
opam exec --switch=5.5.0 -- dune build @shared/native/runtest
./scripts/test-android-e2e-runner.sh
```

Authentication uses Cognito Hosted UI authorization-code flow with PKCE. Apple
uses `ASWebAuthenticationSession`; Android uses Custom Tabs. Tokens are stored
in the platform secure store, so neither client depends on Amplify or the AWS
SDK.
