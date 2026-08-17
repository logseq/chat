# ADR 002: Mobile outliner mode and safe block operations

- Status: Proposed
- Date: 2026-08-16
- Owners: Logseq Chat and db-sync teams
- Amends: ADR 001, section 3 (local pending persistence) and section 7 (client write restrictions)

## Context

Logseq Chat currently presents journal and page blocks as chat-oriented cards. Mobile users also need
an outliner view that follows the core interaction model of the Logseq mobile app: page or journal
headings, ordered nested blocks, bullets, task states, disclosure controls, and direct block editing.
The reference is the Logseq mobile journal layout supplied for this work on 2026-08-16.

The app already has the data needed to render a tree: each projected block has a stable UUID, page
UUID, optional parent UUID, and Logseq order key. It also already supports title and task-status
updates and root-level capture. It does not yet expose structural outliner mutations or client-originated
deletion. ADR 001 deliberately prohibited move and delete requests while the synchronization path was
being established.

A mobile outliner is not useful if it merely resembles an outline but cannot safely perform the small
set of structural operations users need while editing. At the same time, Logseq Chat should not port
the complete desktop editor, command system, plugin API, selection model, or undo engine. The design
must therefore define a minimal mobile operation set and one safe mutation path shared by Chat and
Outliner modes.

## Decision drivers

- Journals can switch between Chat and Outliner modes from an icon button in the header. Regular pages
  are Outliner-only and never show Chat mode or the Chat composer.
- Outliner ordering and nesting match the selected local Logseq graph rather than a second UI-owned
  copy of the tree.
- Chat and Outliner modes use the same mutation commands and safety checks.
- Ordinary block deletion is supported in both modes through Logseq's `delete-blocks` outliner
  operation. Recycle remains page-only and is not used for blocks.
- Structural edits remain local-first, durable, idempotent, and compatible with SSE reconciliation.
- The server remains authoritative for Logseq order generation and graph invariants.
- Encrypted and unencrypted graphs use the same semantic operation envelope.
- The implementation covers mobile editing needs only. Undo and redo are explicitly excluded.
- The OCaml core owns operation validation, optimistic projection, pending state, and reconciliation;
  Swift and Kotlin only express UI intent and platform presentation.

## Decision

### 0. Use a functional core with an Elm-style update loop

The reusable outliner is an OCaml feature module, not a SwiftUI feature model. Its boundary is:

```text
Context + State + Message -> State + Command list
Command list + injected time/UUID providers -> semantic operations + platform commands
```

`update` is pure and owns editing drafts, UTF-16 caret state, selection, autocomplete, collapse,
zoom, keyboard semantics, structural planning, cycle checks, and drag/drop placement. The command
interpreter is the only layer that creates operation IDs, reads time, allocates block UUIDs, or stages
pending graph operations. Those dependencies are injected so reducer and interpreter tests are fully
deterministic.

SwiftUI renders the returned snapshot, sends UI events, and executes only platform commands such as
haptic feedback, focus, clipboard access, file picking, and a destructive confirmation dialog. It
does not calculate fractional order keys, split strings, merge titles, derive autocomplete results,
validate moves, or keep a second editing/selection/tree state. Events are serialized through the core
executor so text and caret changes cannot overtake Return, Backspace, or toolbar actions. A future web
shell can use the same reducer, selectors, command interpreter, projection, and synchronization code.

### 1. Add a content mode, not a second navigation destination

Journals have one content surface with two presentation modes:

- `chat`: the existing chronological card presentation and composer;
- `outliner`: a Logseq-style hierarchical block presentation.

An icon-only button in the existing header toggles the mode. It uses a bundled vector-drawn icon,
has the accessibility identifier `button.content-mode`, and announces the destination mode, for
example, "Show outliner" or "Show chat". The selected mode is app-local presentation state. It is not
written into the graph or sent to the server.

The last selected journal mode is persisted locally. Chat remains the default for existing
installations until the user switches. Regular pages always render the Outliner and hide the mode
button and Chat composer. Search results and the graph picker do not expose a mode switch.

Switching mode does not change the selected graph, page, search query, block selection, sync cursor,
or graph data. It only changes how the current block projection is rendered.

### 2. Build the visible outline from existing graph fields in OCaml

For each journal section or selected page, the OCaml selector builds a forest from:

- `uuid` for stable identity;
- `pageId` for the owning page;
- `parentId` for nesting;
- `order`, with `createdAt` and UUID as deterministic fallbacks;
- title, task status, references, and sync state for row content.

The snapshot exposes core-owned outliner state and derived rows. Each row contains the block, depth,
whether it has children, and its collapsed state. A parent outside the current section is treated as
the page root.
Cycles and orphaned parent references must not hide data: traversal uses a visited UUID set and appends
unvisited blocks deterministically at root depth. The renderer never recursively traverses without a
cycle guard.

Collapse, expand, and zoom are reducer-owned presentation operations in this version. They do not
update `:block/collapsed?`, enqueue a graph
write, or affect another Logseq client. Persisted graph collapse state can be added later without
changing the tree model.

### 3. Match the essential Logseq mobile outline presentation

Outliner mode renders:

- a journal or page heading above its blocks;
- one row per visible block in Logseq order;
- indentation derived from tree depth;
- a tappable bullet at the leading edge that zooms into that block subtree;
- a disclosure affordance at the trailing edge only when the block has children;
- subtle ancestor guide lines for nested content;
- task completion and cancellation styling without changing the stored title;
- existing reference/link rendering where the shared renderer supports it;
- existing pending and failed-sync feedback without turning it into graph data.

The supplied screenshot is a visual direction, not a requirement to reproduce unrelated Logseq mobile
navigation, author metadata, bottom tabs, or menus. Logseq Chat must not fabricate author information
that is absent from its projection.

Tapping a title enters the inline Outliner editor; it never opens the Chat composer. Tapping a task
marker uses the shared task-status operation. Tapping a disclosure control changes only local
collapsed state. A long press enters block-selection mode, and subsequent taps extend or reduce a
multiple selection. Buttons, toolbar commands, zoom, collapse/expand, and selection activation emit
native iOS haptic feedback. Chat cards retain their existing composer editing and destructive delete
command.

### 4. Support only the mobile outliner operation set

The following operation set is the product contract. UI gestures and keyboard behavior may be
different representations of the same semantic operation; they must not create additional mutation
types.

| Operation | Mobile behavior | Graph mutation | Initial UI |
| --- | --- | --- | --- |
| `save-block-title` | Edit and save one block title | Update the existing block | Inline/shared editor |
| `set-task-status` | Set or cycle a task status | Update the status property | Task marker/status picker |
| `insert-block` | Insert an empty or titled sibling/child at a semantic position | Create one block | Return/new-block action and action menu |
| `split-block` | Split title at the caret and insert the suffix as the next block | Atomic title update plus insert | Return in the editor |
| `merge-backward` | Merge a block into its previous visible block at title start | Atomic title update, child move, and deletion of the emptied block | Backspace at title start |
| `move-block` | Move before, after, or inside another block | Update parent, page, and order atomically | Indent, outdent, move up/down, and drag/drop |
| `delete-block-subtree` | Delete a block and its descendants after confirmation | Logseq `delete-blocks` outliner operation | Chat card and Outliner action menu |
| `collapse-block` / `expand-block` | Hide or reveal descendants | None in this version | Disclosure control |

`indent`, `outdent`, `move-up`, and `move-down` are not separate graph mutations. The OCaml reducer
resolves selected roots and intended neighbors against the projected DB, while its command interpreter
allocates compatible fractional order keys and emits one atomic `move-blocks` intent. Similarly,
`split-block` and `merge-backward` are named atomic editor
intents because exposing their constituent writes separately could leave the graph in an intermediate
or destructive state.

The implementation supports long-press multiple selection for the safe batch commands in the
selection toolbar. Structural batch commands validate the top-level selected roots, preserve their
relative outline order, and reject cycles or ambiguous cross-page placements. Drag/drop uses the same
`move-block` semantic command as indent/outdent; it is not a UI-owned tree rewrite.

The implementation exposes `save-block-title`, `set-task-status`, `insert-block`, atomic
`split-block`, atomic `merge-backward`, `move-block`, `delete-block-subtree`, and presentation-only
collapse/expand. Undo and redo remain excluded. Split and merge must not be exposed until the server
accepts each intent atomically with an operation identity and authoritative cursor guard.

The operation algebra is a mobile allowlist over Logseq's existing semantic outliner ops, not a new
tree model:

| Mobile intent | Logseq semantic foundation | Mobile restriction |
| --- | --- | --- |
| `save-block-title` | `:save-block` | Stable UUID plus parsed title fields only |
| `set-task-status` | `:set-block-property` for `:logseq.property/status` | Existing status choice only; associated Task tag semantics are preserved |
| `insert-block` | `:insert-blocks` | One block, stable client UUID, same page |
| `move-block` | `:move-blocks` | One source and stable target UUID; only before/after/first-child/last-child placements |
| move up/down, indent/outdent gesture | Logseq `:move-blocks-up-down` or `:indent-outdent-blocks`, canonicalized to `:move-blocks` | Canonicalization uses the projected DB and stores stable UUID refs, never numeric entity IDs |
| `delete-block-subtree` | `:delete-blocks` | One ordinary root; page and built-in entities rejected |
| `split-block` | Atomic group of `:save-block` and `:insert-blocks` | Not exposed until the server accepts the group atomically |
| `merge-backward` | Atomic group of save, child move, and `:delete-blocks` | Not exposed until the server accepts the group atomically |
| collapse/expand | Logseq has `:collapse-expand-blocks`, but mobile v1 keeps it presentation-only | No graph op or pending row |

The closed payload schemas and canonical stable-reference rules follow
`logseq.outliner.op/op-schema` and `logseq.outliner.op.construct`; only the rows above are accepted.
Options outside the required subset are rejected. In particular, the mobile client does not expose
`:transact`, page lifecycle, templates, batch operations, restore, permanent recycle deletion, or
reactions. Undo-oriented inverse-op construction is not ported.

### 5. Reuse the existing semantic endpoints

Swift dispatches typed UI messages to the OCaml update loop. The reducer and command interpreter
validate block identity and operation-specific fields, then use the existing authenticated db-sync semantic route for block
updates. Existing insertion and move routes remain the intended transport for the later UI slice.
Delete minimally extends the existing block DELETE route with the guard described below; an
unguarded DELETE is not safe for this client. The core never accepts or forwards arbitrary DataScript
transactions, and the platforms never calculate raw Logseq order keys.

The existing serialized pending-sync pump remains the single transport path. The optimistic projection
is derived from pending intent plus the local graph mirror and does not advance `appliedServerT`.
Authoritative SSE changes reconcile the projection. This keeps the first implementation small: it does
not introduce a second server operation protocol where an existing semantic route already expresses
the required operation.

The local graph DataScript database is strictly the authoritative mirror at `appliedServerT`. Accepted
local intents are persisted in an app-owned SQLite operation log, never transacted into graph
DataScript. All user-facing reads use this pipeline:

```text
authoritative DataScript db value + ordered pending ops
  -> semantic op-to-tx compiler
  -> repeated DataScript d/with
  -> immutable projected DataScript db value
  -> every product read
```

The core keeps two distinct DataScript values. `authoritative-db` is restored from and persisted to the
Logseq `kvs` table and is changed only by snapshot/SSE. `projected-db` is an immutable in-memory result
of applying pending projection transactions with `d/with`; it is never installed as the authoritative
connection and is never persisted. Thus pending state is represented in one complete DataScript DB for
reads without becoming server-confirmed graph state.

There is no feature-specific merge layer. Page/journal reads, linked references, object lookup,
properties/classes, tasks, arbitrary supported Datalog queries, query blocks, and outliner traversal
all receive a `read-snapshot` containing the same `projected-db`. Code that reads the authoritative DB
must be limited to sync application, conflict guards, and projection construction. A new read feature
is pending-aware by default because the read API does not expose the authoritative connection.

Supported product queries read current graph state. Transaction-history queries and code that depends
on projected transaction IDs or the projected basis value are not product APIs because rebuilding via
`d/with` may allocate different local transaction/entity IDs. UUIDs and idents remain the only stable
identities exposed outside the read layer.

The semantic op-to-tx compiler is the only place that understands pending operation effects. It
compiles operations in SQLite `sequence` order against the DB value produced by the previous operation:

- create/insert adds the stable block UUID, page, parent, provisional order, title, and derived datoms;
- save-title uses the same title parser/semantic reducer as authoritative writes, including refs, tags,
  properties, and query definitions, rather than changing only `:block/title`;
- property/task changes update both the property value and any derived object relationships;
- move changes parent/page/provisional order and propagates page membership to the moved subtree;
- delete retracts the ordinary-block subtree only from `projected-db`;
- collapse/expand remains UI state and produces no graph transaction.

Implicit supporting entities created by Logseq title semantics, such as the target of a newly typed
page reference, are part of the save-title projection even though explicit page creation UI is out of
scope. Otherwise pending linked refs and Objects would disagree with the eventual server result.

For encrypted graphs, the compiler uses the existing local E2EE transformation before `d/with`.
Protected datoms in `projected-db` keep the same ciphertext representation as `authoritative-db`, while
refs and other derived structural datoms are computed locally from decrypted editor input. Protected
plaintext is not persisted in the graph KVS or operation payload.

This is required for transitive features. For example, a pending title containing `[[Project]]` must
immediately appear in Project's linked references; a pending tag/property must affect Objects; a
pending query edit must re-evaluate against the same projected DB; and a pending delete must disappear
from all of those results without each feature implementing deletion filtering.

### Render and navigate DB-graph nodes

DB graphs use one node-reference syntax: `[[target]]`. The target can resolve through `:block/refs`
to either a page or an ordinary block. The mobile implementation does not parse, emit, autocomplete,
copy, or preserve the removed `((uuid))` block-reference syntax. Persisted references use the canonical
`[[uuid]]` identity form; presentation resolves the target title from the same projected DataScript DB.
Tags use the corresponding DB-graph identity form `#[[uuid]]` and `:block/tags` semantics.

The OCaml core invokes mldoc's inline parser and publishes a small typed render tree. Swift renders
that tree and sends typed tap actions; it does not parse Markdown or infer reference targets. Editing
always shows the raw title so formatting cannot change the source text or caret. Non-editing blocks
render the mldoc tree, including supported emphasis, code, links, `[[...]]` node references, and tags.

Page, ordinary block, tag, property, and class entities all use the same native node route. Their
entity kind selects the node page sections; it does not select a different routing mechanism. A page
node shows its blocks as an outliner, an ordinary block node shows that block as the outliner root,
and a tag node shows Tagged nodes queried from `projected-db`. Each route owns an independent core
projection keyed by node UUID, so pushing or popping a node cannot mutate the projection rendered by
the route underneath it. Native back and interactive-pop exit editing and selection before the
destination changes. Swift owns only the NavigationStack path and native presentation.

### Bound journal projection

`LazyVStack` alone is insufficient because serializing every journal and block still makes startup
linear in the whole graph. The shared core therefore owns a bounded recent-journal window and queries
only those journal pages and their visible outliner rows from `projected-db`. Reaching the oldest
loaded section sends `load-older-journals`, which expands the window by a fixed page batch. Swift does
not cache a second journal tree. Window expansion preserves the current immutable read snapshot and
is covered for thousands of journals, pending operations, collapse state, and zoom destinations.

The minimum projection contract is defined by Logseq DB-graph attributes, not by the fields currently
rendered in Chat:

| Read behavior | Datoms that semantic projection must keep coherent |
| --- | --- |
| Page/journal and outliner tree | `:block/uuid`, `:block/page`, `:block/parent`, `:block/order`, `:block/title`, timestamps, `:block/journal-day` |
| Linked references | `:block/refs` plus referenced page/block identity (`:block/uuid`, `:block/name`, `:block/title`) |
| Tags, classes, and Objects | cardinality-many `:block/tags`, `:block/link`, class/tag `:db/ident`, and referenced entity identity |
| Properties and property queries | explicit built-in `:logseq.property/*` and dynamically discovered `:user.property/*` idents with their real scalar/ref cardinality |
| Aliases and navigation | cardinality-many `:block/alias`, `:block/name`, `:block/link`, and `:block/refs` |
| Query blocks and general current-state Datalog | the complete semantic delta produced by the operation, not a UI-specific subset |

Save-title projection retracts stale derived refs/tags/property datoms before adding the newly parsed
ones. It must not hardcode a list of user properties because DB graphs store them as dynamic
`:user.property/<name>` attributes and property values may be scalar, ref, or cardinality-many. Delete
projection uses Logseq's complete ordinary-block delete delta, including subtree and inbound/derived
reference cleanup; a bare `:db/retractEntity` of only the selected block is insufficient for linked
refs and arbitrary queries.

The projection makes pending creates, title/status/property edits, and moves immediately editable and
visible, and hides pending deletes. Search is evaluated against projected values: a pending new or
renamed block can match, and a block whose pending title no longer matches is removed from results.
If search uses an auxiliary text index, that index is an in-memory derivative keyed by the projection
revision, never an independent source of truth. Editing a pending block replaces or composes its
pending intent; it does not create an entity in `authoritative-db`.

`read-snapshot` carries `(appliedServerT, opsRevision, projected-db, op-statuses)`. The pair
`(appliedServerT, opsRevision)` is the cache identity; the projected DB's own basis value is never used
as a server cursor. The OCaml core serializes snapshot/SSE application and op-log mutation, then
publishes one new immutable read snapshot. Readers hold one snapshot for the duration of a request so
linked refs, query results, and outline rows cannot observe different overlay revisions.

On any authoritative SSE change, the core commits the new base, reconciles explicit operation IDs when
available and otherwise checks submitted semantic intents against the new authoritative value, then
discards the old `projected-db` and every previously compiled projection transaction. It
validates and recompiles the remaining semantic intents in sequence against the new
`authoritative-db`. Stored tx-data, parent/order datoms, or a prior `d/with` result are never replayed.

Each semantic intent stores its operation-specific read set, expected versions, write set, and user
placement rather than precomputed tx-data. Recompilation follows these rules:

| Server change since the intent's base | Projection result |
| --- | --- |
| Does not intersect the intent's read/write set | Recompile the intent against the new DB, except guarded delete whose whole-graph CAS intentionally conflicts |
| Is the authoritative echo carrying the same operation ID | Remove the confirmed op, then compile later dependent ops against the server result |
| Changes an attribute the local intent will overwrite | Mark conflict; never silently choose local or remote |
| Changes a structural neighbor used by insert/move | Re-resolve only if the semantic placement is still unambiguous and its explicit precondition permits it; otherwise conflict |
| Adds/removes/moves/edits anything covered by a delete guard | Conflict; never recompute a broader or different delete set |
| Removes the operation target | Treat delete as satisfied; conflict other operation kinds |

For example, move stores “place A after B” plus source/target-neighborhood preconditions; it does not
store the old `:block/order` transaction. A title edit may survive an unrelated status change, but a
remote title/refs change conflicts. If an op can no longer compile or its precondition fails, it becomes
`conflicted`, is excluded from `projected-db`, and all dependent ops are excluded. Retryable transport
failures remain projected and visibly failed; semantic conflicts restore authoritative data. Guarded
delete persists the stable operation ID as server sync metadata. Non-destructive semantic writes may
be reconciled by their exact intended authoritative value until their endpoints expose operation
identity. Operation IDs are sync metadata, not graph datoms.

#### DataScript history is optional conflict evidence, not the pending model

If the DataScript runtime provides persistent `history`, `as-of`, and `since`, the core can reconstruct
the authoritative DB at an operation's `base_server_t` and calculate the exact authoritative datom
delta before recompilation. That makes read/write-set conflict explanations and three-way comparison
more precise. It does not remove the need for semantic intents, dependencies, operation IDs, transport
state, delete guards, or recompilation on the latest base; DataScript history is not a semantic branch
merge engine.

Because server `t` and DataScript transaction IDs are different domains, each authoritative SSE apply
must record their mapping (or store server `t` as transaction metadata). History retention must cover
the oldest live operation's base. Snapshot replacement can truncate older authoritative history, so
operation-specific expected values and delete guards remain the durable fallback even with history.

The checked-in `datascript-ocaml` runtime cannot currently be relied upon for this: its compatibility
`history` returns current facts and `is_history` is false, as documented in
`datascript-ocaml/docs/upstream_differences.md`. Therefore the initial design stores operation-specific
expected identities/attributes and guards in `logseq_chat_pending_ops` and uses SSE change identities for conflict
detection. A future real history implementation may replace some duplicated version evidence, but it
must not change the projection or operation lifecycle contracts.

An HTTP 2xx response means only that the server accepted the request. The pending overlay remains and
DataScript is unchanged until the matching authoritative SSE event is applied. Reconciliation applies
the SSE change to DataScript and removes the matching pending intent as one published model update, so
the UI does not flicker between optimistic and authoritative values. Restart reconstructs the same
projection from the authoritative mirror plus the durable pending log.

#### Wire-level operation identity and confirmation

Every semantic mutation carries `operationId`. Guarded delete stores a compact idempotency record in
the selected graph's existing `sync_meta`: operation ID, target, expected cursor, and accepted cursor.
The same request returns the stored result; reuse with a different target or guard returns 409. This
deliberately avoids changing `tx_log`, event aggregation, or db-sync's general rebase path.

The OCaml change decoder accepts an optional future `operation-ids` field, but the initial delete
contract does not require db-sync to emit it:

```text
id: 48193
event: graph-changes
data: {"format-version":1,"t-before":48192,"t":48193,
       "operation-ids":["mobile-op-uuid"],"upserts":[...],"deleted":[...]}
```

Guarded delete responses return `operationId`, `acceptedT`, and whether the request changed the graph.
The delete remains projected until the local authoritative cursor reaches `acceptedT`. Submitted
title/property writes without an accepted cursor remain projected until an SSE rebase shows their
exact intended value. An HTTP response never directly mutates the authoritative local mirror.

The operation log is an app-owned table in the selected graph's `graph.sqlite`, next to but outside
Logseq's DataScript `kvs` table. “Do not write pending state into DataScript” means that pending ops
never become graph datoms or `kvs` values; it does not require a second SQLite file. Keeping the tables
in one file allows graph persistence, cursor update, and op reconciliation to share one SQLite
transaction:

```sql
CREATE TABLE logseq_chat_pending_ops (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  operation_id TEXT NOT NULL UNIQUE,
  graph_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  target_uuid TEXT NOT NULL,
  payload BLOB NOT NULL,
  base_server_t INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (
    state IN ('queued', 'submitted', 'accepted', 'retryable', 'conflicted')
  ),
  attempt_count INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_error TEXT
);

CREATE INDEX logseq_chat_pending_ops_graph_queue
  ON logseq_chat_pending_ops (graph_id, state, sequence);

CREATE TABLE logseq_chat_pending_op_dependencies (
  operation_id TEXT NOT NULL REFERENCES logseq_chat_pending_ops(operation_id) ON DELETE CASCADE,
  depends_on TEXT NOT NULL REFERENCES logseq_chat_pending_ops(operation_id) ON DELETE CASCADE,
  PRIMARY KEY (operation_id, depends_on)
);

CREATE TABLE logseq_chat_sync_state (
  graph_id TEXT PRIMARY KEY,
  schema_version INTEGER NOT NULL,
  applied_server_t INTEGER NOT NULL,
  ops_revision INTEGER NOT NULL DEFAULT 0
);
```

`payload` is a versioned Transit value for the closed operation type; it is not arbitrary tx-data.
`sequence` gives deterministic overlay and send order. `base_server_t` records the authoritative
baseline against which the intent was created and is the initial guarded-delete CAS value. `submitted` means
a request is in flight, and `accepted` means HTTP succeeded but SSE has not confirmed the graph state.
`retryable` remains part of the projection; `conflicted` does not. Explicit dependencies cover edits
to pending-created blocks and structural operations whose source or target is also pending. SQLite
foreign keys are enabled for every graph connection, and `ops_revision` increments in the transaction
that mutates operation rows.

Queued edits to the same still-local block may be coalesced in one SQLite transaction. Submitted or
accepted rows are immutable; a later edit becomes a new ordered row. Enqueue, coalescing/canceling
dependent unsent operations, and delete-overlay creation are transactional. SSE reconciliation first
commits authoritative KVS changes and `applied_server_t`, then removes or advances matching operation
rows before publishing one new projection. `retryable` and `conflicted` rows retain visible error
details; explicit discard removes only the op row and reveals the unchanged authoritative mirror.

The initial implementation preserves ADR 001's authoritative KVS/cursor transaction. The app-owned
tables live in the same SQLite file and are copied during snapshot activation, but do not change
db-sync's tx-log or general rebase transaction.

Full snapshot activation stages a fresh authoritative `kvs` mirror. Before atomically replacing the
active file, the importer copies all non-reconciled operation/dependency rows and app-owned sync state
from the active database into the staging database in one transaction. Snapshot replacement must never
silently discard or apply pending intent. DataScript restore ignores these app-owned tables.

For deletion, unsent pending creates inside the confirmed subtree can be canceled atomically with the
delete intent because they have never existed on the server. Any already submitted but unconfirmed
create/update/move in the subtree must settle first; otherwise the delete is not sent and the UI asks
the user to retry after synchronization. This prevents a late self-echo from resurrecting or changing
the subtree after its delete guard was captured.

Split and merge must be exposed only when the server can apply their constituent changes atomically.
Until that contract exists, the renderer, shared title/status editing, insert/move endpoints, collapse,
and delete are still a valid incremental implementation of this ADR.

### 6. Make ordinary block delete shared, explicit, and subtree-aware

Chat and Outliner modes call exactly the same `delete-block-subtree` command. There is no separate
chat delete implementation and no view-specific request shape.

Delete follows Logseq's ordinary block semantics, not its page Recycle semantics. The semantic route
calls Logseq outliner's `delete-blocks` operation. That operation filters the requested roots to
top-level roots, computes each complete subtree, validates protected built-in entities, and removes
the selected roots and descendants from the outline transaction. Page deletion is a different
operation and remains unsupported in Logseq Chat.

Before submission, both modes show a destructive confirmation. The message identifies the block and
the number of descendants that will be deleted. Empty unsynchronized draft blocks may be discarded
locally without a server delete only when they have never been durably created and have no descendants.

The initial guard is deliberately coarse and simple. Confirmation captures the current
`appliedServerT`; the request body contains the stable client operation ID and `expectedServerT`. Inside
the same serialized graph operation that performs `delete-blocks`, the server reads its current graph
`t` and requires exact equality. Any intervening server write, even to unrelated content, returns HTTP
409 and deletes nothing. The user first synchronizes the new authoritative state and then confirms
again. A prior GET followed by an unguarded DELETE is insufficient because it has a
time-of-check/time-of-use race.

This whole-graph compare-and-set is intentionally more conservative than a subtree fingerprint. It
automatically covers descendants added or removed, moves, content/property edits, inbound references,
and other delete side effects without duplicating Logseq's delete-impact algorithm in OCaml and
Clojure. db-sync already exposes the current graph `t` within its serialized semantic handler. A later
version may use real DataScript history or a server-generated delete-impact token to reduce unrelated
conflicts, but it must preserve the same fail-closed behavior.

The existing `DELETE /api/v1/graphs/:graph-id/blocks/:block-id` route is extended to accept this
guarded-delete body. Logseq Chat never invokes it without `expectedServerT`. Other callers may keep
the existing behavior until the server API version removes unguarded deletion.

```json
{
  "operationId": "stable-client-generated-uuid",
  "expectedServerT": 48192
}
```

The serialized handler evaluates requests in this order: authenticate and validate the idempotency
record; if the same operation already completed, return its stored result; compare current
`storage/get-t` with
`expectedServerT`; validate that the target is an ordinary deletable block; then perform one
`delete-blocks` transaction carrying the operation ID. Stale `t` returns 409 with `currentServerT` and
deletes nothing. The guarded response uses the common semantic result envelope rather than an empty
204 so the client receives `operationId`, `acceptedT`, and `changed`.

Conflict behavior is deliberately fail-closed:

| Concurrent or stale state | Result |
| --- | --- |
| Same operation ID was already applied | Return the stored success without applying again |
| Target was already deleted, directly or with an ancestor | A recorded retry succeeds; a new stale request conflicts or returns not found |
| Any server write advanced `t`, related or unrelated | 409; sync and require confirmation again |
| Target moved, subtree membership changed, or affected content/properties/refs changed | Covered by the same `t` mismatch; delete nothing |
| An unsent local-only create exists in the subtree | Cancel it atomically when the confirmed delete is enqueued |
| A submitted but unconfirmed create/update/move exists in the subtree | Do not send delete until it settles; then rebuild the guard and confirm again |
| The same local delete is tapped twice | Reuse the pending operation; never enqueue a second request |
| The same operation ID is retried after an ambiguous transport failure | Return the stored result or 404 success; never apply twice |
| Target is a page, built-in entity, property, class, or malformed cyclic tree | Reject; delete nothing |
| Validation or transaction fails while deleting | Roll back the whole transaction; no partial subtree deletion |

The unrelated-write false conflicts are intentional in a version without undo or block Recycle:
occasionally asking for confirmation again is safer and substantially simpler than an incomplete
client-authored impact fingerprint.

The server also rejects deletion when:

- the target is a page rather than an ordinary block;
- the target is a built-in entity, property definition, or class definition;
- authorization does not permit writes to the graph;
- the subtree cannot be resolved without a cycle or missing required identity.

The UI hides a pending subtree in both modes. Before transport, the core compares its current
`appliedServerT` with `base_server_t` and cancels an already-stale operation. The server CAS remains
mandatory because local preflight cannot close the race. A transport/server failure or 409 removes the
optimistic overlay, restores the authoritative subtree, and reports the conflict. HTTP 404 is treated
as idempotent success because the requested block is already absent. Remote deletes continue to arrive
through SSE and affect both modes.

This ADR does not add undo, redo, or restore. Because ordinary blocks do not go to Recycle, the
confirmation step must state that the block and its descendants will be deleted. This limitation is
intentional and must not be obscured in the UI.

### 7. Enforce structural invariants in the OCaml core and server

For every insert, move, split, merge, and delete, both the OCaml validator and authoritative server
must enforce:

- stable UUID identity and membership in the selected graph;
- exactly one owning page for every live block;
- a parent that is either the owning page or a live block on that page;
- no self-parenting or ancestor cycle;
- no move into the block's own subtree;
- deterministic sibling ordering with no client-authored raw order key;
- atomic page propagation to descendants when a move crosses page roots, if cross-page moves are
  enabled later;
- no partial application of split, merge, move, or delete;
- guarded delete comparison and subtree deletion occur in one serialized server operation;
- title and encrypted-value handling consistent with the graph's E2EE state.

The initial mobile UI only moves blocks within one page. Cross-page move is rejected even though the
envelope can be extended later. The client sends plaintext protected values only to its local OCaml
core; encrypted graphs use the existing client-side encryption path before transport. Structural UUID,
parent, page, and order identities follow the existing db-sync representation.

### 8. Amend ADR 001's write allowlist narrowly

ADR 001 allowed block creation and property modification but prohibited client-originated delete,
move, and arbitrary transactions. This ADR replaces only that restriction for the closed mobile
operation set above.

The server may accept the typed semantic `insert-block`, `split-block`, `merge-backward`, `move-block`,
and guarded `delete-block-subtree` requests. It must continue to reject raw tx-data, page deletion, arbitrary
property-schema mutation, and any operation kind not in
the versioned allowlist. Existing local-first durability and authoritative SSE confirmation rules from
ADR 001 remain unchanged.

## Explicitly out of scope

- undo and redo;
- multi-block selection and batch edits;
- arbitrary drag-and-drop payloads or cross-page moves;
- copy, cut, and paste of block trees;
- block zoom/focus navigation;
- templates and commands;
- page create, rename, delete, or restore;
- property schema creation or class-property editing;
- reactions and comments;
- Recycle browser, restore, garbage collection, or permanent delete;
- arbitrary DataScript transactions;
- desktop-only keyboard command parity;
- persisted or synchronized collapse state;
- rich-text editor parity beyond the existing shared title editor.

These exclusions do not weaken the required operations. In particular, delete is required in both
Chat and Outliner modes and cannot be deferred behind the absence of undo/redo.

## Rejected alternatives

### Make the first outliner read-only

A read-only tree would satisfy the visual part of the request but not the mobile outliner workflow.
It would also make Chat and Outliner behavior diverge immediately. The small typed operation set is
preferred.

### Port Logseq's complete outliner and editor namespaces

The Logseq outliner supports batch operations, templates, properties, page lifecycle, reactions,
page recycle administration, plugin transactions, and desktop editor commands. Porting all of it would add
substantial surface area unrelated to the mobile product. This ADR reuses its invariants and preserves
the page-only Recycle boundary while implementing only the required semantic intents in the existing
OCaml core.

### Let Swift and Kotlin calculate order keys and transactions

That would duplicate the most fragile tree rules and allow the platforms to diverge. Platform views
send semantic placement; shared core and server code own validation and order generation.

### Put ordinary blocks in Recycle

Logseq Recycle is a page lifecycle feature. Applying page recycle metadata to ordinary blocks would
invent semantics that Logseq's outliner does not implement. Ordinary blocks therefore use
`delete-blocks`, with subtree confirmation and shared failure handling.

### Optimistically mutate the local graph mirror

The mirror is the exact server state at `appliedServerT`. Writing optimistic structural changes into it
would blur the sync boundary and complicate replay. Pending overlays provide responsive UI without
changing the authoritative mirror.

## Consequences

### Positive

- Journal and page content gain a familiar mobile Logseq outline without a second graph model.
- Chat and Outliner cannot drift into different mutation or deletion semantics.
- A small operation algebra covers Return, Backspace, indent, outdent, reorder, task changes, and
  deletion without exposing raw transactions.
- Server-owned order generation preserves Logseq ordering behavior across Apple, Android, and other
  clients.
- Whole-graph server-`t` guards, shared confirmation, pending state, failure rollback, and idempotent absence
  handling make destructive actions conflict-safe and retry-safe.
- Excluding undo/redo and desktop-only commands keeps the first implementation bounded.

### Negative

- Guarded delete requires a backward-compatible extension to the authenticated block DELETE route and
  an atomic server-side `t` comparison.
- Split, merge, move, and delete need atomic conflict handling and broader integration tests than the
  current capture/property paths.
- A pending-operation overlay must derive a coherent tree without mutating the local graph mirror.
- Deleted ordinary blocks cannot be restored in Logseq Chat because undo/redo is out of scope and
  Recycle does not apply to them.
- Collapse state does not initially follow the user between devices or launches.

## Rollout and verification

Implementation proceeds in this order:

1. Add pure OCaml tree projection and operation validation tests, including cycles, orphan parents,
   ordering ties, collapsed ancestors, and cross-page rejection.
   Add golden fixtures that run the allowlisted Logseq CLJS outliner op and the OCaml projection
   compiler from equivalent DB states and compare canonical current datoms by UUID/ident.
2. Add server contract tests for each allowed operation and for rejection of every non-allowlisted
   operation.
3. Implement durable optimistic overlays and prove restart/retry behavior before exposing mutations in
   the UI.
4. Add Outliner rendering and the header mode button on Apple and Android.
5. Enable title/status/insert/split/merge/move operations.
6. Enable the shared Chat/Outliner delete command only after server-`t` CAS, every conflict case above,
   failure rollback, idempotent retry, and SSE-echo tests pass.

The ADR is complete when automated tests demonstrate:

- the mode button switches the same journal and regular page between Chat and Outliner without data
  loss or navigation changes;
- nested blocks render in deterministic Logseq order, and collapse hides exactly the descendants of
  the collapsed block;
- cycles and orphaned parents cannot hang traversal or make blocks disappear;
- one projected DataScript DB makes pending title/ref/tag/property/move/delete effects visible to page
  reads, linked refs, Objects, current-state Datalog queries, search, and Outliner without feature-level
  merge code;
- Apple builds render the mode icon and expose its accessibility label and identifier; Android
  verification is deferred for this implementation pass;
- every supported mobile operation produces the same logical graph on the OCaml client and server;
- golden parity excludes numeric entity/tx IDs but covers page/parent/order, refs/tags/properties,
  implicit supporting entities, subtree effects, and encrypted value representation;
- split and merge are atomic under failure and process termination;
- indent, outdent, move up/down, and insert cannot create cycles or cross-page corruption;
- Chat and Outliner invoke the same delete operation and confirmation policy;
- deleting a parent removes the expected ordinary-block subtree through Logseq `delete-blocks`;
- any intervening server `t`, duplicate-tap, pending-local-write, and transaction-failure case follows
  the fail-closed table above, including conservative conflicts caused by unrelated server writes;
- offline delete survives restart, remains hidden as pending in both modes, and is submitted once;
- retrying an operation ID is idempotent;
- changed, aggregated, replayed, and idempotent-no-op responses preserve operation identity;
- authoritative SSE confirmation clears the pending overlay and advances the cursor, while a no-op
  remains projected until the client reaches and verifies `acceptedT`;
- encrypted graph operations do not expose protected plaintext to the server;
- raw transactions, page deletion, page recycle administration, cross-page move, and every
  unrecognized operation are rejected;
- no undo or redo state, command, RPC action, or UI is introduced.

## References

- `docs/adr/001-real-time-graph-sync.md`
- `../logseq-1/deps/outliner/src/logseq/outliner/op.cljs`
- `../logseq-1/deps/outliner/src/logseq/outliner/op/construct.cljc`
- `../logseq-1/deps/outliner/src/logseq/outliner/core.cljs`
- `../logseq-1/deps/outliner/src/logseq/outliner/recycle.cljs`
- `../logseq-1/src/main/frontend/handler/editor.cljs`
- `../logseq-1/src/main/frontend/modules/outliner/op.cljs`
- `Sources/LogseqChatModel/Models.swift`
- `Sources/LogseqChatModel/ViewModel.swift`
- `Sources/LogseqChat/ContentView.swift`
