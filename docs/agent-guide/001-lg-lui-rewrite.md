# LG/LUI Rewrite

## Status

In progress on `codex/lg-lui-rewrite`.

The interaction baseline starts at `main` commit `2bd514d` and must be
refreshed against the then-current `main` before the final cutover. The rewrite
is complete only when it preserves every user-observable interaction from that
baseline on iOS and Android.

## Architecture decision

- Keep the existing OCaml core and its storage, synchronization, E2EE, search,
  FSRS, markup, and outliner behavior.
- Move application state, reducers, effects, projections, and ordinary UI into
  LG and LUI.
- Evolve the LUI SwiftUI renderer into a Skip package. Apple runs native
  SwiftUI; Android runs the SkipUI translation on Jetpack Compose.
- Keep operating-system services in the existing Swift and Kotlin adapters.
- Implement Logseq-specific editor, rich content, math, code, video, WebView,
  and media behavior as validated LUI extensions rather than standard LUI
  elements.
- Do not introduce Flutter or Dart into Logseq Chat.

## Non-negotiable interaction parity

The rewrite must preserve behavior, not merely expose similarly named
features. The following are authoritative evidence:

1. Every existing `.maestro/*.yaml` flow runs unchanged against the rewritten
   application on its declared platform.
2. Existing unit and policy tests remain green or are replaced by equivalent
   LG tests that exercise the same public behavior. Removing a test requires a
   written mapping to stronger coverage.
3. Existing accessibility identifiers remain available with the same meaning.
   Dynamic identifiers retain their current stable UUID/index composition.
4. Navigation depth, back behavior, editor cancellation, focus restoration,
   keyboard dismissal, scroll anchoring, and modal presentation match `main`.
5. Chinese and English IME behavior, UTF-16 caret positions, rapid
   Return/Backspace, editor handoff, autocomplete, drag/drop, long-press
   selection, and haptics match `main`.
6. Offline launch, optimistic edits, pending state, reconnection, SSE updates,
   encrypted graphs, assets, capture, sharing, audio, and background refresh
   preserve the current state transitions and feedback.
7. iOS-specific native presentation and Android-specific Compose behavior keep
   the platform differences deliberately encoded by the current `#if SKIP`
   branches.

## Interaction inventory

| Surface | Baseline evidence | Rewrite gate |
| --- | --- | --- |
| Authentication and graph lifecycle | `ios-graphs*.yaml`, `ios-staging-connect.yaml`, `android-staging-connect.yaml` | Same sign-in, graph selection/create/delete, unlock, and offline-open behavior |
| Journal chat and composer | `ios-chat-send-regression.yaml`, `ios-cold-start-composer.yaml`, `ios-capture-responsive.yaml` | Same draft, expand/dismiss, send, attachment, task, and scroll behavior |
| Search and node navigation | `ios-search-*.yaml`, `android-capture-search.yaml`, node/tag/sidebar navigation flows | Same full-screen search, result navigation stack, back, close, query, and status behavior |
| Outliner presentation | `ios-outliner-mode.yaml`, layout, hierarchy, anchor, and page flows | Same ordering, nesting, pagination, collapse, zoom, linked references, and anchor retention |
| Outliner editing | edit baseline, inline editor, continuous editing, rapid-enter, caret, toolbar, autocomplete flows | Same UTF-16/IME, focus, split/merge, pair deletion, toolbar, and handoff behavior |
| Outliner structure | drag, interactions, selection toolbar, empty block deletion flows | Same move, indent/outdent, selection, confirmation, delete, and haptic behavior |
| Rich content and media | `ios-rich-block-rendering.yaml`, YouTube, asset, and audio flows | Same markup actions, code/math/media rendering, playback, and asset presentation |
| Flashcards | `ios-flashcards-regression.yaml` | Same reveal and rating progression |
| Settings and diagnostics | settings tabs/theme/log flows | Same tabs, theme, language, runtime log filtering/copy, and connection settings |
| Sharing and deep links | share image/web/capture/result and shortcut flows | Same extension handoff, staging, result feedback, and destinations |
| Sync and resilience | local realtime, offline, reconnect, restart, snapshot/order regression flows | Same visible state, durability, cursor, and error behavior |

## Delivery gates

1. LG/LUI native runtime shell and reducer tests.
2. Shared LUI Swift/Skip renderer with component parity tests.
3. Virtualized keyed list, viewport events, anchor preservation, and imperative
   scroll tests on both hosts.
4. Native outliner editor extension and IME/caret stress tests.
5. Rich-content and platform-service extension boundaries.
6. Screen-by-screen migration while preserving the interaction inventory.
7. Full iOS and Android build, unit, integration, and unchanged Maestro suites.
8. Final diff against current `main`, with no unmapped interaction or test.

## Current implementation

The first LG/LUI runtime slice owns selected-graph, sync-status, and search
presentation/query state. Its retained-backend tests prove initial empty state,
in-place status patches, visible sync failures, search input ownership, query
reset, and search-subtree disposal.
