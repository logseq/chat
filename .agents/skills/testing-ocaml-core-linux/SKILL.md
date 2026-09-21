---
name: testing-ocaml-core-linux
description: Build and run the OCaml core test gate on Linux (opam deps, duniverse restore, lg prefix cache + dune shared cache, parallel test-chunk layout in shared/test/dune).
---

# Logseq Chat OCaml core testing on Linux

The only Linux-runnable surface is the OCaml core in `shared/`. The gate is:

```sh
eval $(opam env)          # 'default' switch here; README documents 5.5.0
dune build @shared/native/runtest
```

Never `swift test` — it hangs on Linux.

## Cold-build performance knobs

Two layered caches make `rm -rf _build` rebuilds fast; keep both warm:

- `chat/.lg-cache/` — lg's content-addressed compile cache, outside `_build`,
  survives clean builds. Prefix keys are recorded in each `*.state` artifact
  (provenance key, lg >= the cache-fix revision pinned in `logseq_chat.opam`);
  do not digest state bytes.
- Dune shared cache — off by default. Enable per machine in
  `~/.config/dune/config`:

  ```
  (lang dune 3.0)
  (cache enabled)
  ```

  Restores all builtin-rule artifacts (vendored deps, generated-module cmx)
  on a cold `_build`. The `@runtest` action itself replays from cache when
  inputs are unchanged.

Expected on an 8-core box: ~40s cold without dune cache, ~13s with it
(11.6s is the test run — a user rule, only skipped when fully replayed).
A cold build where `.lg-cache` is ALSO empty recompiles every cljc (~4min).

## Test target layout (shared/test/dune)

- `lg-native-cmi-deps` alias (also in `shared/native/dune`) forces vendored
  duniverse cmis to exist before lg runs; without it lg falls back to
  same-named opam cmis and fails with "inconsistent assumptions".
- `logseq_chat_lui_test_base` — chunk compiled off
  `../native/logseq_chat_lg_core_native.state` (emitted by the core rule's
  `--emit-state`), emits `include Logseq_chat_lg_core_native` + literal/lui/
  app/lg-test framework.
- `logseq_chat_lui_test_p1..p8` — 41 test namespaces as independent chunks
  off `logseq_chat_lui_test_base.state` (`--compile-files-chunk-from` +
  `--prefix-interface` pointing at the base cmi). Add new test files to a
  chunk (or a new chunk) — they compile in parallel.
- Generated chunk modules must be listed on a LIBRARY (`logseq_chat_lui_test_parts`,
  `wrapped false`): dune does not emit compile rules for generated modules on
  an executable. The runner exe needs `(link_flags -linkall)` — test
  registration is initializer side-effects that dead-stripping drops.
- `logseq_chat_lui_test_z` is the last module alphabetically: it carries
  `run.cljc`, which must run after all chunk registrations.

## Environment restore (if duniverse/ is missing)

`duniverse/` is gitignored. Restore per `logseq_chat.opam.locked`: clone the
opam source trees for each vendored package at the locked commit (private
repos lg/lui/signal-lg need `LOGSEQ_GITHUB_PAT`). `duniverse/lg` must match the
lg pin in `logseq_chat.opam` — `%{bin:lg}` resolves to the vendored copy.
