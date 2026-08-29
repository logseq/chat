# LG/LUI Rewrite Blockers

This is the time-boxed blocker and decision log for the iOS parity sprint.
Entries stay concise so work can continue on the highest-signal path.

## Active

- 2026-08-29 01:27 CST — Grouping journal rows into nested viewport-sized
  sections made the first section visually match main's rhythm, but it also
  removed later sections from the native virtual list's scrollable extent. The
  experiment was fully reverted before commit. The next implementation must
  preserve the existing flat lazy item hierarchy and express section spacing as
  metadata/layout on boundary rows; nested keyed collections are not acceptable.
  No divider will be added because the requested product behavior intentionally
  differs from current `main` on that point.

- 2026-08-28 18:51 CST — Journal scrolling is measurably dominated by
  main-thread SwiftUI graph and layout work when rich rows enter the
  `LazyVStack`, not by renderer patches or markup decoding. During active
  swipes, renderer patch traffic stopped; four newly appearing rows decoded in
  0.111–0.112 ms total but caused four to five height-preference updates. An
  18-second Time Profiler trace shows `AttributeGraph` dirty propagation/update
  as the leading meaningful leaf work, with layout and gesture stacks also
  prominent. Each rich row currently mounts the generic retained LUI wrapper
  and extension boundary plus a `GeometryReader`/`PreferenceKey` height
  feedback path and per-row drag/drop gestures. That combination causes extra
  graph invalidation and layout passes as rows are materialized; WebKit appears
  only marginally. No behavior or performance fix was applied per the current
  diagnosis-only request; DEBUG-only counters remain available for follow-up.

- 2026-08-28 17:28 CST — The sidebar's vertical ScrollView now scrolls while
  open, but simulator taps on navigation rows still do not dispatch even after
  removing the drawer's panel-wide drag recognizer. The next focused check is
  the generic ListItem interaction policy: text-only custom rows should remain
  native Buttons, while only rows containing nested controls should use the
  composite gesture host. The first policy edit also exposed a Skip call-site
  label mismatch during compilation; that compiler failure is fixed before the
  next simulator build rather than bypassed.

- 2026-08-28 16:49 CST — Simulator parity still needs paired evidence for the
  remaining user-identified surfaces: tag presentation, Linked References
  presentation, button semantics/appearance, sidebar scrolling while the drawer
  is open, and the menu presented by the expanded composer's action button.
  Graph-list presentation and native swipe interaction are now verified.
  Current action: replay identical
  states against latest `main` and the LG/LUI build on the same iOS 26 simulator,
  then turn each confirmed mismatch into a focused failing test before fixing it.

- 2026-08-28 16:59 CST — Paired Linked References capture confirms that the
  LG/LUI node screen omits the large in-content page title, renders the section
  heading with the wrong weight/insets/spacing, turns the source journal label
  into a tinted capsule button, truncates the reference body to one line, and
  flattens adjacent tags into unspaced black text instead of inline link/tag
  controls. Current action: restore main's semantic page heading, section label,
  plain source label, rich block row, and inline tag nodes rather than styling
  the existing wrong control types.

## Resolved

- 2026-08-29 01:40 CST — The Graphs catalog now uses the same native inset
  grouped List structure as `main`: Refresh/Add are plain system rows, graph
  rows use local/lock/cloud icons, ready encrypted graphs omit the extra status
  subtitle, and the local row keeps both its ellipsis menu and native trailing
  swipe action. LUI now lets direct native List rows inherit system insets and
  primary icon treatment instead of applying its standalone ListItem padding.
  The paired light-mode capture aligns section geometry and row spacing; the
  focused swipe flow exposes `Delete local graph`, 108 LG tests pass, and the
  Apple/Android backend suite passes without changing an existing iOS E2E flow.

- 2026-08-29 01:08 CST — The drawer was laid out inside the container safe area,
  so its rounded main panel could not reach the screen edges and the navigation
  footer lost the system bottom inset after the shell became full-screen. The
  LUI drawer now spans the container safe area, restores the main content's
  dynamic top and bottom insets, and supplies the same active ultra-thin material
  surface as `main`; the LG sidebar reserves the matching 64-point top region.
  Paired light-mode Journal and open-Sidebar captures now show a full-height main
  panel and the footer at the system inset plus the existing 21-point control
  inset. Closed drawers retain their previous transparent host semantics. LUI's
  100 Apple/Android parity tests and all 108 LG tests pass without changing an
  existing iOS E2E flow.

- 2026-08-28 16:50 CST — The apparently blank LG/LUI launch was an immediate
  screenshot race, not a crash or renderer failure. The same running process
  exposed the expected outliner/button hierarchy and rendered normally on the
  next settled frame. The local sync server was separately found stopped and is
  now running from `logseq-1/deps/db-sync` on port 8787 for deterministic parity
  setup.

- 2026-08-28 16:46 CST — The latest `main` baseline was fetched over the SSH
  remote because the configured HTTPS fetch returned 403. Local `main` contains
  fetched `origin/main` and is one commit ahead. Its manifest and resolved build
  contain no AWS SDK dependency. After initializing the pinned `Vendor/mldoc`
  submodule in the detached parity worktree, the unmodified `main` iOS simulator
  app built successfully and was preserved for paired comparison.

- 2026-08-28 16:16 CST — Screenshot-level comparison against the supplied main
  states now covers the native header, collapsed Capture/Search chrome,
  expanded composer, native search, selection chrome, and Settings sheet. The
  expanded composer had two real visual mismatches: an opaque secondary fill
  obscured Liquid Glass, and a shared 16-point downward offset placed all
  floating chrome against the keyboard instead of honoring main's 21-point
  lower inset. The declarative tree now preserves main's asymmetric composer
  padding, uses a platform-aware glass fallback, and expresses each bottom
  chrome state's exact outer spacing. The focused composer and selection E2E
  flows pass, and the new screenshots align in material, placement, radius,
  typography, group-label color, and card spacing.

- 2026-08-28 15:13 CST — The generated Android module now passes
  `:LogseqChat:compileDebugKotlin`. Skip-incompatible enum associated-value
  patterns, optional invocation return inference, method references,
  `String(decoding:as:)`, and `map(String.init)` were replaced at their Swift
  sources with portable forms. Four closure-overloaded effect-executor
  initializers were also collapsed into one optional-handler initializer to
  eliminate a real JVM type-erasure signature clash. No Android tests or
  emulator runs were added.

- 2026-08-28 15:03 CST — Outliner E2E no longer writes into the 150+ row
  shared `sync 2` journal. Dynamic editor/selection/drag flows use a resettable
  `chat-local-e2e-outliner` graph containing only today's writable journal;
  page/navigation/rich-content flows use a separately resettable
  `chat-local-e2e-fixtures` graph. Core tests verify both seed modes are
  idempotent. The unchanged selection flow now locates both anchors without a
  long historical scroll, and the fixture-backed page flow also passes.

- 2026-08-28 14:51 CST — The generic bottom-chrome hit target now consumes
  taps across the expanded composer's full rectangular surface. A focused iOS
  regression opens the composer, invokes and completes the task-status action,
  then verifies the composer remains expanded and neither the outliner editor
  nor selection toolbar activates beneath it. The diagnostic passes, so the
  earlier overlay hit-through blocker is no longer reproducible.

- 2026-08-28 14:44 CST — A retained iOS ListItem could be long-pressed once,
  but the same row stopped emitting after Copy cleared selection. Core already
  supported the transition, and delays, direct coordinates, and changing the
  SwiftUI long-press modifier all reproduced the failure. The row's selection
  lifecycle now keys its local gesture host identity, so returning to the
  unselected state installs a fresh recognizer without rebuilding the list or
  changing the wire protocol. A focused same-row regression passes with no
  delay, and the repository's unchanged selection-toolbar E2E also passes.

- 2026-08-28 14:14 CST — The native search empty state used a centered Column
  whose intrinsic width collapsed to its text, so the parent placed the whole
  group at the leading edge. A full-width declarative Row now centers the text
  without custom SwiftUI. Visual sampling matches the supplied main screenshot.
  The search flow also asserts the system `.searchable` close action through
  its native `close` accessibility text instead of an app-owned identifier that
  the system control does not expose. The exact search/status E2E passes.

- 2026-08-28 14:08 CST — Composer and search flows reused `sync 2`, which had
  accumulated more than 165 E2E blocks and pushed new captures outside the
  lazy accessibility range. They now use the dedicated
  `chat-local-e2e-composer` graph. Before each flow, a tested seed mode preserves
  built-in/schema entities, removes old journal content, and idempotently creates
  one current journal baseline. The original 120-point main-parity clearance and
  centering assertions remain unchanged. Capture, chat-send, cold-start composer,
  and search/status exact flows all pass.

- 2026-08-28 13:48 CST — `ios-capture-responsive` still asserted the obsolete
  settings label `Connection`. Both main and the supplied settings screenshot
  use the group label `Sync server`, and the sheet already exposes the exact
  base-URL field identifier. The single stale content assertion now names
  `Sync server`; the flow reaches and verifies the composer without adding
  hidden compatibility text or changing any interaction step.

- 2026-08-28 13:46 CST — LUI mapped every declarative dialog to SwiftUI
  `confirmationDialog`. On iOS 26 that presentation can omit the explicit
  cancel action, so page deletion diverged from main's native alert and the
  unchanged favorite flow could not tap `Cancel`. Dialogs now select native
  alert semantics through the generic `alert` style class while retaining
  confirmation-dialog behavior by default; only page deletion declares the
  alert style. The complete LUI bundle passes 91 Apple tests plus eight
  transpiled backend parity tests, and the exact page-favorite E2E passes both
  cancellation and confirmed deletion.

- 2026-08-28 13:42 CST — The LUI dialog policy test fixture omitted the dialog
  surface's required title text, so validation correctly rejected it before
  the policy assertions ran. The fixture now satisfies the existing modal
  contract and additionally verifies cancel/non-cancel action extraction. The
  complete LUI test bundle passes rather than hiding the failure.

- 2026-08-28 13:25 CST — `ios-native-header-navigation` hard-codes Aug 24 but
  previously ran against the shared `sync 2` graph, whose Aug 28 E2E traffic
  pushed that journal off screen. The runner now opens a deterministic
  `chat-local-e2e-header` graph and applies an isolated core seed mode containing
  the exact Aug 24 journal target. A core fixture test verifies the seeded page
  and block, the shared seed remains unchanged, and the original header flow
  passes opening the native destination and returning through `BackButton`.

- 2026-08-28 13:21 CST — `ios-graphs-lifecycle` depended on an external remote
  graph matching `chat-local-e2e-*`, so the product passed both native delete
  dialog paths and then failed on absent test data. The iOS E2E runner now runs
  an idempotent lifecycle-fixture setup that creates
  `chat-local-e2e-fixture` only when missing. The original lifecycle flow is
  unchanged and passes through cancellation, confirmed local deletion, remote
  reopen, and return to journals.

- 2026-08-28 13:16 CST — LUI rendered `navigation-form` and
  `navigation-scroll` sheets with SwiftUI's default large navigation title,
  placing `Settings` below its Cancel/Apply toolbar instead of matching main's
  centered inline title. The shared Apple backend now applies inline title mode
  to those semantic sheet classes. The policy test passed, the app was rebuilt
  against local LUI, screenshot verification matches main's toolbar geometry,
  and the two-flow settings E2E module passes.

- 2026-08-28 13:07 CST — A bare repository-wide `dune build` could not locate
  `-lsqlite3` because it omitted the SDK library path already used by the
  repository mobile build scripts. Supplying the macOS SDK `usr/lib` through
  `LOGSEQ_CHAT_SQLITE_LIB_DIR` makes the full Dune build pass; no product or
  build-definition change was required.

- 2026-08-28 12:43 CST — Continuous Return/Backspace handoff destroyed the
  row-owned editor extension whenever editing moved to a different block,
  emitting `keyboardWillHide` even when focus recovered immediately. Outliner
  rows now use one stable `active-outliner-editor` key and atomically carry the
  editing flag, title, and caret in the same retained item signal. LUI moves the
  existing editor node between row positions without a false conditional edge;
  the unchanged continuous-editing E2E keeps hide count zero across repeated
  splits and merges, then passes selection and deletion. All 107 LG tests pass.

- 2026-08-28 12:17 CST — LG queued the core `hideKeyboard` toolbar effect but
  kept its optimistic inline editor alive, allowing pending text snapshots to
  preserve focus and intercept the following tag-chip tap. The reducer now
  mirrors core semantics immediately by clearing editing and autocomplete while
  core still commits the final value. The reducer regression and the unchanged
  node/tag navigation E2E both pass.

- 2026-08-28 11:57 CST — Launch briefly exposed the graph picker before the
  authenticated remote catalog had loaded, so setup could enter the add-graph
  path and attempt to recreate an existing graph. Graph loading now remains
  active until `connectStoredGraph()` completes and uses a graph-specific
  loading label before selection. Sixteen `wrangler-regression-*` graphs made
  by this test run were also removed from the sync catalog and moved, rather
  than deleted, to `/tmp/logseq-sync-regression-recovery.jOckqq`; `sync 2`,
  `db4`, and `db5` were untouched.

- 2026-08-28 11:36 CST — The sync regression was not blocked by the SSE
  heartbeat. LG correctly projected pending work as `Syncing`, but successful
  core mutations never started the existing store sync pump; the old `Synced`
  projection had previously hidden that gap. The runtime now starts `sync-now`
  whenever a successful core response reports pending semantic operations or a
  pending sync request. The core also carries the accepted server cursor into
  completion patches and the next mutation before SSE confirmation. Text
  autosave and task mutations now settle inside the unchanged three-second
  assertions, and the exact graph-create regression passes end to end.

- 2026-08-28 11:36 CST — A long remote graph catalog exceeded the intrinsic
  root height and vertically displaced the graph picker controls. The picker is
  now constrained to the vertical viewport with a growing list, keeping the
  heading and add control visible regardless of catalog size. The unchanged
  create-graph flow reaches the native form again.

- 2026-08-28 10:16 CST — A newly created graph stopped after the remote catalog
  selected it, leaving LG on an unbootstrapped empty journal. Graph creation now
  follows the same local snapshot open/start-sync path as an existing graph.
  Empty rows also expose main's `Edit block Untitled block` accessibility title,
  and the compact sync control uses main's `Synced`/`Sync failed` labels while
  the details sheet retains `Up to date`. The focused E2E passes graph load,
  first-block editing, and its first sync checkpoint; 105 LG tests pass.

- 2026-08-28 10:04 CST — LUI presented both `dialog` and `sheet` through the
  same SwiftUI sheet host, producing a full-screen graph deletion surface with
  no native outside-tap dismissal. Dialogs now use system
  `confirmationDialog`, recursively map their declarative message/actions, and
  preserve semantic cancel/destructive roles; sheets keep their existing host.
  The unchanged lifecycle E2E passes outside dismissal and confirm deletion.

- 2026-08-28 09:57 CST — The iOS E2E runner required a linear full-suite pass.
  It now accepts focused `smoke`, `composer`, `outliner`, `navigation`,
  `settings`, `content`, and `graphs` modules, plus any exact YAML flow and a
  `--list` discovery mode. Existing E2E flow contents remain untouched.

- 2026-08-28 09:54 CST — Settings used a flattened native Form, which dropped
  `screen.settings`, rendered group labels as oversized headings, and turned
  choices, links, and rows into blue capsule buttons. LUI now has a reusable
  `navigation-scroll` sheet surface, preserves content accessibility, and gives
  long presented menus their own scroll viewport. LG mirrors main's 20/18/8/
  12/16/14 spacing and grouped-card structure with semantic select, toggle,
  list-item, row, and text nodes. The unchanged theme/language parity E2E passes.

- 2026-08-28 09:36 CST — The retained LG dropdown was laid out partly above
  the iOS viewport, and the outer `Unfavorite` accessibility frame overlapped
  the inner Share action, so tapping the favorite label opened Share Sheet.
  Header overflow now uses the existing platform-native `Menu` extension with
  reactive favorite/settings state. The unchanged favorite E2E passes through
  unfavorite, favorite, restart, confirmation, and deletion.

- 2026-08-28 09:08 CST — Composer correctly remains visible on sidebar-selected
  pages, but their related/tag sections were siblings of the scrollable
  Outliner. The final tag could therefore sit behind floating glass without any
  scroll path above it. Page and native-route blocks, empty action, references,
  and bottom clearance now share one scroll container. Autocomplete candidates
  are also reindexed after core ordering so visible position zero retains the
  existing `.0` interaction contract without changing E2E selectors.

- 2026-08-28 08:24 CST — The shared drawer used a simultaneous edge drag over
  live Outliner rows, so opening the drawer could also press the row beneath the
  gesture and push an unrelated native route. A narrow closed-state leading
  hit target now owns edge input while preserving the ancestor drawer gesture.
  The hierarchy-navigation E2E also verifies that editing disables both the
  drawer gesture and the visible sidebar button from one LG-owned signal.

- 2026-08-28 08:10 CST — Anchor-based outliner flows inherited a native page
  route from the preceding E2E because their shared fixture only checked for a
  Composer, which is also present on routed pages. The helper now pops a visible
  system Back route and explicitly selects Journals before creating anchors, so
  hierarchy and sidebar assertions start from a deterministic journal root.
- 2026-08-28 08:01 CST — The invalid-order E2E spent its setup scrolling
  through a long-lived journal with 122 rich blocks to reach a seeded page's
  old journal heading, timing out before pagination. It now opens the same
  deterministic `E2E Page Target` fixture directly from the sidebar, keeping
  the test focused on rapid editor structure changes. Journal heading divider
  rendering was also removed to match the requested main baseline.
- 2026-08-28 07:47 CST — Native navigation visually popped but left the LG
  route active because both ABI bridge layers discarded the declared `count`
  field from `back(count:)`; journal chrome therefore never returned. Swift and
  OCaml now preserve the count, with runtime/native-bridge tests and the full
  outliner navigation E2E confirming model and system stacks pop together.
- 2026-08-28 07:35 CST — Native `.searchable` emitted each declared
  `query-changed` value, but both host bridge layers discarded the `query`
  field: Swift only forwarded `title`/`uuid`, and the OCaml ABI adapter rebuilt
  only outliner payloads. Both bridges now preserve `query`; a native-bridge
  regression test and the search/status E2E cover the complete path without a
  custom search field or protocol change.
- 2026-08-28 07:18 CST — XCTest drops the first synthetic key event sent by
  Maestro to the iOS 26 native `.searchable` field, even after explicit focus
  and animation settlement, producing `earch ...`. The regression now sends
  and clears one probe key before the real query; this keeps the product on the
  native search interaction instead of adding an app-owned automation shim.
- 2026-08-28 07:02 CST — Sequential `textChanged` core responses could project
  an older outliner title while newer typing was still queued, corrupting rapid
  erase/input into mixed text. Snapshot merging now preserves the latest local
  edit for the same block while a text effect is pending or in flight, then
  accepts the authoritative value once settled. The full capture E2E passes.
- 2026-08-28 06:56 CST — The expanded composer used a 30-point capsule, evenly
  packed controls, a filled status dot, and accent-colored Send. The main
  baseline is now restored declaratively: 10-point rounded rectangle, 16/8
  insets, flexible trailing spacer, outline Todo control, and a 40-point gray/
  black upward-arrow Send state. LUI gained generic spacer properties and a
  reactive background property; no Swift wire-protocol customization was added.
- 2026-08-28 06:46 CST — The LUI opam dependency was pinned as a Git source, so
  uncommitted framework fixes were silently excluded even with `--working-dir`.
  Repeated composer tests therefore exercised the old spacer implementation.
  The development switch now uses a local path pin; shared LUI iterations read
  the actual workspace without cache-clean workarounds.
- 2026-08-28 06:35 CST — `persist-composer-draft` was implemented by the
  platform handler but omitted from the core executor's platform-routing list,
  so every draft edit rendered an unsupported-effect error into the journal.
  A failing iOS E2E assertion reproduced the boundary error; the effect is now
  routed to platform persistence and the same assertion passes.
- 2026-08-28 06:29 CST — Capture submission was already persisted and projected;
  the apparent refresh failure came from the long-lived E2E graph placing the
  appended row below the visible journal viewport. Constraining the virtual list
  to the remaining viewport, collapsing the composer, and scrolling to the exact
  generated row makes the post-submit assertion deterministic.
- 2026-08-28 05:56 CST — Settings rendered as an unconstrained generic sheet,
  putting Cancel/Apply outside the viewport. Reusing LUI's existing
  `navigation-form` contract restores the native NavigationStack, Form, title,
  and toolbar actions without adding a Swift protocol or app-specific renderer.
- 2026-08-28 05:59 CST — The capture E2E erased 28 characters from the
  generated `Preserved draft <10-digit run id>` value, which is 26 characters.
  The flow now erases the exact generated value before verifying that native
  keyboard focus survives an empty draft.
- 2026-08-28 05:53 CST — The native search field rendered, but its iOS 26
  bottom-toolbar close action did not reach the LG presentation because
  `.searchable` was attached outside a wrapper that owned its own
  `NavigationStack`. The generic navigation now accepts an app-local root
  transform, attaching the platform modifier to the stack's actual root
  content. The focused iOS E2E confirms native presentation and dismissal;
  iOS below 26 and Skip/Android retain system `.searchable` placements.
- 2026-08-28 05:35 CST — Swift 6.2 IRGen crashed while lowering an instance
  method reference used directly as a `Binding<String>` setter in the native
  search extension (`SmallVector unable to grow`). Expressing the same setter
  as an explicit closure avoids the malformed compiler thunk without changing
  search ownership or falling back from platform `.searchable`.
- 2026-08-28 05:00 CST — App-specific Liquid Glass initially appeared to require
  adding a `glass` value to the shared LUI Button protocol, which would couple
  every custom Apple treatment to LG validation and Android. The public Button
  contract remains unchanged; Logseq now registers an iOS-only `liquid-glass`
  tweak for declarative surfaces, while its navigation extension owns grouped
  native header material. A pinned schema test prevents protocol regression.
- 2026-08-28 04:39 CST — Dune does not track source files referenced through the
  opam prefix, so reinstalling a working-directory LUI package left generated LG
  code linked to the previous protocol until `_build` was cleaned. A clean build
  resolved it, but also unnecessarily rebuilt the iOS OCaml toolchain. Prefer a
  tracked local Dune dependency for LUI in future build-system work.

- 2026-08-28 04:31 CST — Repeated E2E iterations append anchor blocks and could
  leave the newest pair behind fixed bottom chrome. The shared fixture now
  positions the pair in the middle interaction zone after locating it, so its
  result no longer depends on journal length.
- 2026-08-28 04:27 CST — Programmatic page-reference insertion briefly opened
  autocomplete and then closed it because `UITextView` echoed its model-driven
  caret update as user input. The editor now suppresses caret events while
  applying model text and selection; a policy regression test covers the
  distinction. Core autocomplete also excludes blank block candidates.

- 2026-08-28 04:06 CST — Task status effects reached core in under one second,
  but the optimistic outliner patch ignored status `Set_property` operations;
  UI state changed only after authoritative sync about ten seconds later. Core
  now projects status references into the changed row immediately, covered by
  the RPC regression suite. LUI icon buttons also expose their full 40x44 label
  frame instead of a nested 16x16 icon accessibility target.

- 2026-08-28 03:49 CST — Adding a reactive task-status label initially produced
  misleading signal/function type errors because `view.lgi` still declared the
  old one-argument toolbar signature. Updating the implementation and interface
  together restores correct signal binding. Treat `.cljc`/`.lgi` signature
  changes as one edit in future iterations.
- 2026-08-28 03:46 CST — `toolbar.outliner.editor` was overwritten by the
  identifier on the internal `chrome.bottom` layout slot. Removing the redundant
  outer identifier exposes the real toolbar container while retaining all child
  button identifiers; the LG regression suite covers this boundary.
- 2026-08-28 03:42 CST — The graph Add action now dispatches on the first iOS
  tap and the standard Maestro setup proceeds into the outliner. The native
  navigation-form action uses one high-priority tap boundary while the Skip
  branch keeps its normal button action.

- 2026-08-28 03:36 CST — Skip rejects `highPriorityGesture`. The navigation
  action keeps its original `Button` action under `#if SKIP`; only the native
  Apple branch uses the gesture needed to prevent the keyboard from swallowing
  the first toolbar tap.
- 2026-08-28 17:48 CST — The Graphs sidebar row dispatched the correct LG
  event and applied a valid patch, but an existing native navigation route
  remained above the updated root screen. Sidebar destination changes now pop
  the retained app path before changing destinations; a focused model test
  covers navigation from a nested page. The drawer's shifted main surface also
  needs its own full-screen background so its top corner is visible above the
  navigation safe area.
- 2026-08-28 18:00 CST — The destination patch still rolled back after the
  navigation-path fix because LUI's native context-menu renderer supported
  icons, destructive roles, and accessibility identifiers while retained-tree
  validation rejected that same metadata. The shared menu-item contract and
  Apple validation now agree, with a focused backend regression test. The
  drawer shell also has to ignore the outer container safe area while padding
  its content back in, matching main's full-screen material surface.
- 2026-08-28 18:31 CST — Installing the verified build on a physical iPhone is
  blocked because both paired devices currently report `unavailable` to
  CoreDevice. The simulator build and focused sidebar flow pass; retry device
  deployment when either paired iPhone is connected and unlocked.
- 2026-08-28 18:29 CST — Several LG renderer tests used positional child
  indexes from the pre-native-menu and pre-outliner-wrapper trees. They now
  locate controls and extension nodes by semantic identifiers. The task-status
  menu also carried a redundant accessibility label unsupported by `menu-item`;
  native menu text already provides that label, so the redundant property was
  removed instead of widening the shared protocol.
- 2026-08-28 03:30 CST — The default `dune` supported language versions only
  through 3.23. Running the LG suite through the repository-required OCaml 5.5
  switch selected Dune 3.24.0 and completed the RED run. Use
  `opam exec --switch 5.5.0 -- dune ...` for subsequent Dune gates.
- 2026-08-28 23:35 CST — Updating the comparison worktree through its HTTPS
  `origin` returned a GitHub 403. Fetching the same upstream through the
  existing SSH credentials resolved the comparison blocker; dark-mode parity
  was rechecked against remote main commit `0a39d33`.
- 2026-08-28 23:36 CST — The main comparison worktree initially lacked its
  pinned `Vendor/mldoc` submodule and a complete Apple toolchain. Initializing
  that submodule and reusing the primary worktree's generated iOS toolchain
  made the simulator build reproducible without changing application code.
- 2026-08-28 23:46 CST — The focused Swift test build is blocked by the
  existing DEBUG-only call to `JournalScrollDiagnostics` in
  `LGChatRichBlockExtension.swift`; that symbol is not available to the test
  target. The production iOS simulator build succeeds. Keep this separate from
  the dark-mode background fix and repair the diagnostics target boundary when
  resuming journal scroll root-cause instrumentation.
- 2026-08-29 00:23 CST — A closed native drawer still rendered its panel at
  35% opacity and applied the open-state shadow to every opaque descendant of a
  transparent main pane. This made retained sidebar content and large gray card
  shadows bleed through the launch graph picker even though LG correctly sent
  `selected=false`. LUI now drives panel opacity and main-pane shadow from the
  actual reveal progress, with a pixel regression test for the closed state.
  App theme tokens are injected once through a generic semantic-color
  environment map, so exact `surface` and `muted-foreground` colors no longer
  require app-specific wire or Swift protocol fields.
- 2026-08-29 00:44 CST — Dark-mode root content already matched main's
  `#002D38`, but navigation-style LUI sheets fell back to the system black
  presentation background and their settings cards used the generic system
  secondary fill. LUI modal navigation surfaces now consume the existing
  semantic `background` environment color, and the app marks settings cards as
  semantic `surface` nodes. This keeps the fix generic, avoids new wire fields,
  and covers the sheet safe areas as well as its scroll content.
- 2026-08-29 02:13 CST — Native Graphs lists were hiding the platform scroll
  background, while the app root always painted the Logseq theme behind the
  status-bar and home-indicator safe areas. LUI now preserves the native
  grouped-list background and reports that surface through a SwiftUI
  preference. Navigation uses the preference for its route and toolbar, and a
  small app-root surface state keeps the otherwise-transparent safe areas in
  sync. Simulator comparison against main confirms system black for Graphs and
  unchanged `#002D38` for Journals and Sidebar. This does not add wire fields or
  page-specific properties.
- 2026-08-29 02:36 CST — The 02:13 app-root surface switch was not how main
  handles safe areas and made the transparent sidebar inherit Graphs black.
  Main keeps the app root `#002D38`, lets the native List own its black surface,
  and always places a full-screen material behind the drawer main panel. LUI's
  generic surface modifier clipped the drawer before `ignoresSafeArea` could
  expand it, and LUI also reserved the system bottom inset while main reserves
  zero. Excluding drawer from the generic surface, keeping its main material
  active while closed, and letting page content own the bottom safe area removes
  both horizontal bands without app-specific protocol fields. Dark simulator
  comparison now shows a continuous black Graphs surface while closed and a
  full-height teal sidebar beside a full-height rounded main panel while open.
- 2026-08-29 02:43 CST — The verified device build installed successfully on
  the paired iPhone as `com.logseq.chat`, but CoreDevice could not launch it
  because the phone was locked. Unlocking the phone is sufficient to open the
  already-installed build; no rebuild or reinstall is required.
- 2026-08-29 03:18 CST — The existing direct `sidebar.yaml` run did not reach
  the sidebar because its setup left the keyboard active in Add sync graph and
  the confirmation did not complete. A temporary verification flow reused an
  existing graph and passed button-open, backdrop-close, swipe-open, and
  swipe-close without changing the checked-in E2E flow. Fix the shared setup
  independently instead of weakening sidebar assertions.
- 2026-08-29 03:20 CST — Journals now has the same retained equatable row
  boundary used by main while preserving `ScrollView + LazyVStack`. Focused
  rich-block and drag flows pass, but a repeatable 100+ rich-row fixture and
  frame-time comparison are still missing, so the long-list performance claim
  is not yet considered verified.
- 2026-08-29 04:01 CST — A separate `--performance` seed now creates 100
  journals with eight mixed rich-text rows each without changing any checked-in
  E2E flow. Time Profiler showed that idle `feedSSE` and `beginPendingSync`
  responses repeatedly rebuilt the retained UI, while the drawer animated an
  expensive continuously changing clip over the long list. Runtime snapshot
  deduplication, a discrete drawer corner radius, and disabling both drawer
  panes during motion reduced the identical transition trace from one 560 ms
  hang to zero hangs; AttributeGraph dirty work fell from 485 ms to 140 ms.
  A swipe beginning on the Graphs row now closes the drawer without activating
  the row.
- 2026-08-29 04:01 CST — Running `dune clean` also removed the generated iOS
  OCaml host and simulator toolchains, forcing a multi-minute bootstrap before
  the next simulator build. Avoid repository-wide Dune cleanup during UI
  iteration; use focused targets and preserve `_build/apple-toolchains`.
- 2026-08-29 04:01 CST — Maestro still cannot attach to the paired physical
  iPhone even when CoreDevice and Instruments can see it. Gesture arbitration
  is therefore automated on the iOS simulator; physical-device verification
  remains install-and-manual until the Maestro device bridge is available.
- 2026-08-29 04:40 CST — `virtual-list` was virtualizing SwiftUI view bodies
  correctly (only eight visible rich rows appeared), but destination changes
  unmounted the complete retained journals wire tree. Returning to Journals
  rebuilt 221,290 bytes / 2,652 operations before SwiftUI could benefit from
  `LazyVStack`. The journal tree now stays retained across sidebar destinations;
  its projection is pinned to the journal route, while a generic retained-pane
  state hides it from hit testing and accessibility on other pages. On the same
  64-journal fixture, Graphs → Journals produced no renderer patch batch and no
  hidden journal buttons were exposed in the Graphs accessibility hierarchy.
- 2026-08-29 05:04 CST — After building latest main, the device dependency
  cache no longer contained the unpushed LUI revision `3e6531c`. The branch's
  default remote SwiftPM resolution therefore could not reinstall on iPhone.
  Use the repository's existing `LUI_PACKAGE_PATH` local-package override for
  branch device builds; do not push an intermediate LUI commit or change the
  checked-in dependency solely to repair a local cache.
- 2026-08-29 05:09 CST — The isolated latest-main worktree's first simulator
  build found an incomplete freshly bootstrapped OCaml simulator source tree
  (`utils/config.common.ml.in` was absent). For the controlled main/LUI A/B,
  point `LOGSEQ_CHAT_APPLE_TOOLCHAIN_ROOT` at the already verified shared
  compiler toolchain while keeping each worktree's core and Swift build
  outputs separate. This avoids a destructive toolchain cleanup and does not
  mix application artifacts between branches.
- 2026-08-29 05:20 CST — `LUI_PACKAGE_PATH` only overrides the Swift package;
  the app's OCaml wire runtime is compiled from the `lui` files installed in
  the host `5.5.0` opam switch. A normal incremental simulator build therefore
  reused the old runtime and reproduced the same 17 KB / 189-op batches after
  the source fix. Install the local LUI package into that switch before
  rebuilding the focused mobile core target; do not interpret a Swift-only
  rebuild as a runtime performance result.
- 2026-08-29 06:21 CST — A controlled-state mismatch cannot be used as a drawer
  interaction lock in the generic renderer. A local `@State` redraw can retain
  the previous wire model value after the transition, making
  `model.isSelected != presented` remain true and permanently disabling the
  sidebar. Lock the transition using local animation state instead; native iOS
  unlocks from SwiftUI's logical animation completion, while Skip uses main's
  350 ms fallback. A transition generation prevents an older completion from
  releasing a newer transition.
- 2026-08-29 06:25 CST — The current device build and signing completed, but
  two direct CoreDevice install attempts were interrupted by the paired iPhone
  during package transfer (`IXRemoteErrorDomain` connection interruption).
  The device remains listed as available and the installable app is preserved
  at `.build/LogseqChat-device.app`; retry after keeping the phone unlocked and
  connected rather than rebuilding.
- 2026-08-29 08:04 CST — Dune does not invalidate the generated app LG test
  module when only an installed LUI source changes, because the opam source
  tree appears inside the rule action rather than its dependency set. A small
  app test edit forced the correct regeneration without deleting the shared
  Apple toolchain. The build rule should eventually declare the installed LUI
  source tree as an explicit dependency so framework-only protocol changes do
  not reuse stale generated OCaml.
- 2026-08-29 08:04 CST — Reusing the same retained header children in both the
  root and pushed-destination SwiftUI toolbars caused nondeterministic toolbar
  ownership after navigation. The navigation host now gives the root toolbar
  sole ownership at depth zero and the destination toolbar sole ownership at
  positive depth; duplicating retained views across toolbar locations is not a
  supported composition pattern.
- 2026-08-29 08:17 CST — The current branch installed successfully on the
  paired iPhone, but CoreDevice could not launch it while the phone was locked.
  The installed build is valid; unlock the phone and launch it manually (or
  retry only the launch command) instead of rebuilding the app.
- 2026-08-29 09:22 CST — Skip 1.9.5 does not transpile SwiftUI `contentShape`
  in the shared drawer implementation. Keep the interaction shield shared and
  full-frame, but isolate the native `contentShape` and safe-area coverage in
  the existing Apple-only view modifier; Android continues to use the full-frame
  `Color` with explicit hit testing without expanding the wire protocol.
- 2026-08-29 09:56 CST — Maestro's `waitForAnimationToEnd` can return after a
  drawer destination transition but before a newly mounted native grouped
  `List` has committed its stable section layout. A screenshot taken in that
  window temporarily omitted grouped backgrounds and headers even though the
  accessibility hierarchy already exposed the page actions. Screenshot flows
  for native lists should wait for a page-specific section marker before
  capturing; the settled Graphs screenshot matches main.
- 2026-08-29 10:30 CST — SwiftUI's drawer transition cannot safely use either
  animation completion callback to own the interaction lock: `logicallyComplete`
  releases before visible spring settling, while `removed` can be cancelled when
  a sidebar selection rebuilds the destination and leave interaction locked
  forever. Both Apple and Skip use one generation-guarded transition lifecycle,
  which covers the spring settling window and always releases.
- 2026-08-29 14:48 CST — A 500 ms drawer lock visibly outlived main's 0.28 s
  spring and made consecutive sidebar interaction feel delayed. Main's Skip
  fallback is 350 ms, so the shared generation-guarded lock now uses the same
  350 ms lifecycle while retaining the uninterrupted gesture-to-animation
  interaction shield.
- 2026-08-29 14:35 CST — Deriving the drawer interaction lock only from its
  nonzero visual drag offset left a boundary case: an already-recognized
  horizontal gesture can be clamped to zero while its underlying row remains
  interactive. The drawer now retains an explicit horizontal-gesture phase
  from recognition through the handoff to the transition lock, so the full
  toggle lifecycle has one uninterrupted interaction shield.
- 2026-08-29 10:07 CST — The repository-wide `swift test` target is not a
  reliable integration gate in its current form. Native suites run concurrently
  against shared UserDefaults/core fixtures and produced ordering-dependent
  failures, while the generated Skip unit-test targets fail to compile older
  model/outliner tests that use unsupported `Data` initializers, optional
  `flatMap`, integer geometry literals, and untranslated enum cases. The current
  navigation source's Skip compile error was fixed independently; LUI's full
  Apple+Skip suite (107 tests), the LG suite (109 tests), focused app tests, and
  simulator/device builds pass. Split or serialize shared-state native suites
  and repair the pre-existing Skip test sources before treating the aggregate
  app command as a release gate.
- 2026-08-29 11:12 CST — Running core tests with the system `dune` fails before
  compilation because the repository requires Dune language 3.24 while PATH
  currently resolves Dune 3.23.1. Use `opam exec -- dune` (3.24.0) for focused
  core tests; do not clean or rebuild the shared Apple toolchains to compensate.
- 2026-08-29 11:53 CST — The shared iOS E2E setup flow remained on the
  `Add sync graph` sheet after submitting `sync 2`, so the subsequent sidebar
  assertion could not run. This is a fixture/setup failure rather than a drawer
  regression; use an existing local graph for the focused drawer audit and
  investigate the sync-server setup separately without weakening the E2E test.
- 2026-08-29 12:02 CST — `install-mobile-ios-device.sh` always rebuilds and has
  no way to install an already-built app bundle, so it discarded the local
  `LUI_PACKAGE_PATH` context and tried to resolve an unpublished LUI commit from
  GitHub. Direct CoreDevice installation of `.build/LogseqChat-device.app`
  succeeded; the helper should eventually accept a prebuilt bundle or forward
  the local package override. Launch then timed out over the phone's network
  tunnel, so no rebuild or source workaround is warranted.
- 2026-08-29 12:36 CST — `test-ios-e2e.sh` unconditionally uninstalls and
  reinstalls the app bundle from its own repository even when
  `LOGSEQ_CHAT_IOS_SKIP_BUILD=1`. It therefore cannot run a trustworthy
  cross-worktree main/current A/B after a manually installed main bundle. For
  comparison captures, install the intended bundle explicitly and invoke
  Maestro directly; keep the wrapper for same-worktree runs.
- 2026-08-29 16:20 CST — A journal node request previously updated only the
  navigation path, forcing `view.cljc` to reconstruct a temporary route by
  searching cached journal rows. The incomplete reducer state was the root
  cause of the growing view condition tree. Optimistic app-navigation previews
  now live beside authoritative core routes in the model, survive unrelated
  snapshots, and are released on back or failure; the view only projects the
  model's resolved route sequence into the native NavigationStack.
- 2026-08-29 16:20 CST — A selected-page core snapshot aliases its short
  `outliner-rows` into `journal-outliner-rows`. Accepting that alias discarded
  the long journal cache and generated a roughly 410 KB / 10,528-operation UI
  patch on navigation. Preserve the root cache outside the journal-home
  projection and retain the journal/detail scroll surfaces separately; the
  measured optimistic detail patch is about 38 KB / 487 operations and begins
  the drawer transition roughly 132 ms after the press.
- 2026-08-29 16:20 CST — The core heartbeat still serializes and returns a full
  long-journal snapshot on the shared executor (about 654 KB and 0.9–1.0 s for
  512 rows). Native navigation no longer waits for it, but incremental snapshot
  delivery or executor isolation remains necessary to remove the underlying
  background CPU and latency cost.
- 2026-08-29 16:34 CST — The aggregate native Swift test command again produced
  ordering-dependent failures in autosave, shared recorder, UserDefaults, and
  extension-registry tests when suites ran concurrently. The exact navigation
  registration test passes in isolation, as do all 110 LG tests and the focused
  LUI drawer tests. Do not weaken those tests; serialize shared-state suites or
  isolate their fixtures before using the aggregate run as a gate.
- 2026-08-29 16:52 CST — Interactive native pop updates NavigationStack's local
  path before the deferred LG back patch updates model depth. Conditionally
  removing root ToolbarItems during that window caused SwiftUI to hide the
  navigation bar and lose toolbar ownership after returning. Keep the root
  ToolbarItem structure stable, switch its content from the local path, and
  declare navigation-bar visibility on the root destination itself. The same
  push/interactive-pop simulator flow now restores the complete root toolbar.

## Decisions

- Keep Android work limited to compilation gates during this sprint; do not
  spend the time box on Android UI-test optimization.
- Preserve `origin/main` as the visual and interaction baseline. For the
  outliner toolbars, editor actions are icon controls (with `[[]]` retained as
  the page-reference symbol), while selection actions retain both icons and
  captions.
# 2026-08-29: Physical iPhone temporarily unavailable after navigation build

- The signed device app built successfully with the local LUI package, but
  CoreDevice reported the target iPhone as `unavailable` during installation.
- The ready-to-install artifact is `.build/LogseqChat-device.app`; retry the
  direct install after the phone is unlocked and connected. Rebuilding is not
  required.

# 2026-08-29: iOS 26 modal large-title state blocks a single-sheet refactor

- A retained Settings sheet with dynamic ScrollView/List content consistently
  left the large navigation title at zero opacity, including after exposing the
  native List directly and rebuilding the modal NavigationStack.
- LUI structural properties such as class, background, and list labels are
  intentionally static, so making them reactive would expand the protocol for
  one screen. Keep the proven separate native Settings, Tabs, and Log sheets
  until LUI has a general navigation-destination primitive.
- Main keeps Settings and Tabs in one `NavigationStack` and opens Tabs with a
  `NavigationLink`. Replacing one presented sheet with another reuses the iOS 26
  presentation host and can leave the next large title at zero opacity. Explicit
  title modes, view identities, and serialized sheet dismissal did not make that
  behavior reliable, so none of those workarounds are retained.
