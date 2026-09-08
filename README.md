# Logseq Chat

Logseq Chat is a native SwiftUI app for Apple platforms and a Flutter Material
app for Android. Both clients use the same LG application model and OCaml
DataScript core.

## Apple platforms

Open `Project.xcworkspace` and run the `LogseqChat App` scheme in Xcode.
The Swift package can be compile-checked without launching XCTest:

```sh
swift build --disable-sandbox
```

Build the native macOS Release app, including the OCaml 5.5 DataScript core:

```sh
./scripts/build-macos-app.sh
open .build/macos/LogseqChat.app
```

The first Apple build creates a deployment-targeted OCaml 5.5 toolchain under
`_build/apple-toolchains`. Native dependencies and core objects are keyed by
compiler, target, and source fingerprints, so later builds reuse them. Set
`LOGSEQ_CHAT_APPLE_TOOLCHAIN_ROOT` to share the toolchain cache, or provide
`LOGSEQ_CHAT_IOS_TOOLCHAIN_PREFIX`/`LOGSEQ_CHAT_MACOS_TOOLCHAIN_PREFIX` to use
an existing compatible compiler directly.

## Android

Android is built exclusively from the Flutter project:

```sh
cd Flutter
flutter pub get
flutter run
```

Build a debug APK or Play Store app bundle with:

```sh
cd Flutter
flutter build apk --debug
flutter build appbundle --release
```

The Flutter Android host includes Capture and Journal app shortcuts, Capture
and Today’s Journal home-screen widgets, inbound sharing, deep links, native
authentication, media services, and the OCaml core JNI library.

## Testing

Do not run `swift test` in this repository because the XCTest bridge hangs in
the current environment. Use the supported gates instead:

```sh
swift build --disable-sandbox
cd Flutter && flutter analyze && flutter test
opam exec --switch=5.5.0 -- dune build @lg-test/runtest
opam exec --switch=5.5.0 -- dune build @core/runtest
./scripts/test-android-e2e-runner.sh
```

Authentication uses Cognito Hosted UI authorization-code flow with PKCE. Apple
uses `ASWebAuthenticationSession`; Android uses Custom Tabs. Tokens are stored
in the platform secure store, so neither client depends on Amplify or the AWS
SDK.
