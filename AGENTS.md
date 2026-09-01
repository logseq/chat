# Logseq Chat

Logseq Chat uses native SwiftUI on Apple platforms and Flutter Material on Android, backed by an OCaml DataScript core. Canonical setup is in `README.md`.

## Testing

- Do NOT run `swift test` (xctest). It hangs indefinitely in this
  environment (an async Swift Testing case blocks on an XCTWaiter that never
  finishes), wasting many minutes per run. Do not run it.
- Validate OCaml core changes with `dune build @core/runtest`.
- If a Swift compile check is needed, use `swift build` (build only, no test
  run) with sandbox disabled; SwiftPM's own sandbox conflicts with the agent
  sandbox.

## Build system

- `dune build` of the whole workspace fails on `logseq_chat_mobile_entry`
  because `logseq_chat_platform_crypto` is only compiled by the platform
  build scripts; this is expected. Use the `@core/runtest` target instead.
- The platform build scripts (`scripts/build-mobile-ios-*.sh`,
  `scripts/build-android-native.sh`, `scripts/build-macos-app.sh`) hardcode
  the OCaml module list. Adding a new module under `core/` requires updating
  `core/dune` and every one of those scripts (compile and link sections).

## Cursor Cloud specific instructions

Cloud Agent VMs are Linux. They cannot run Xcode, the iOS simulator, the macOS `.app`, or `swift test`. Do not try to start those from this environment.

The Linux-runnable surface is the OCaml core in `core/` (inbox capture, DataScript model, RPC, SQLite persistence). There is no in-repo HTTP server; the app’s default API (`http://127.0.0.1:8787`) lives in a separate Logseq product.

### OCaml core

Use the `5.5.0` opam switch (create it if needed with `opam switch create 5.5.0`):

```sh
eval $(opam env --switch=5.5.0)
dune runtest
```

`dune runtest` is the lint/test/build gate here. `dune build` of `logseq_chat_mobile_entry` looks for SQLite via a Homebrew path in `core/dune`; on Linux, either skip that executable or set `LIBRARY_PATH` to your system SQLite lib dir (e.g. `/usr/lib/x86_64-linux-gnu` on Debian/Ubuntu) first.

`opam install . --deps-only` does not apply nested pins from `datascript-ocaml-native`. Pin these first (idempotent):

```sh
opam pin add -n -y melange-edn-core git+https://github.com/RCmerci/melange-edn.git#main
opam pin add -n -y melange-edn-native git+https://github.com/RCmerci/melange-edn.git#main
opam pin add -n -y melange-transit-core git+https://github.com/RCmerci/melange-transit.git#main
opam pin add -n -y melange-transit-native git+https://github.com/RCmerci/melange-transit.git#main
opam install . --deps-only --yes --with-test
```

`opam init` on this VM must use `--disable-sandboxing`. New shells need `eval $(opam env --switch=5.5.0)` unless `.bashrc` already loads it.

A representative core action is the Swift FFI RPC `dispatch` / `send`, which optimistic-captures a journal block (see `core/logseq_chat_rpc_test.ml` and `dune runtest`).

### iOS / Android / macOS

On a Mac, follow `README.md`: open `Project.xcworkspace`, run the `LogseqChat App` scheme. Native core builds (`scripts/build-mobile-ios-*.sh`, `scripts/build-macos-app.sh`, `scripts/build-android-native.sh`) expect an `ocaml-demo` checkout via `LOGSEQ_CHAT_OCAML_DEMO_ROOT` (defaults to a machine-local path). Do not start Android emulators or Maestro from Cloud Agent unless that stack is explicitly in scope.
