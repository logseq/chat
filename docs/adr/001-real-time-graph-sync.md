# ADR 001: Real-time Logseq graph sync

- Status: Accepted; implementation in progress
- Date: 2026-08-14
- Owners: Logseq Chat and db-sync teams

## Context

At the time of this decision, Logseq Chat read and wrote a small, chat-specific projection through the
Graph API and authenticates those requests with a personal access token (PAT). Its
local database also defines a reduced schema whose property types do not always
match the graph database on the server. Refreshing is periodic, so a change made by
another Logseq client is not visible immediately.

The current native persistence path is also not a db-sync graph store. It serializes
OCaml values with `Marshal` into a two-column `kvs(address, payload)` table. db-sync
snapshots contain ClojureScript Transit values in Logseq's
`kvs(addr, content, addresses)` layout. Those formats must not be treated as
interchangeable. The current platform-to-core call and HTTP adapter also buffer one
complete JSON response, so a long-lived SSE connection needs a new byte-stream
adapter rather than extending the blocking request call.

Logseq Chat needs a local, queryable copy of the selected graph and near-real-time
updates from db-sync. The design must work for both encrypted and unencrypted
graphs, preserve the server graph schema exactly, and add as little protocol and
server complexity as possible.

## Decision drivers

- Users sign in inside Logseq Chat with their Cognito credentials; they do not open
  an external login page or create or paste a PAT.
- An authorized user can open any graph available to that account.
- The local graph uses the server-provided schema. Attribute cardinality, uniqueness,
  value type, reference semantics, and values are not coerced for the chat app.
- The first use of a graph creates a complete local copy before incremental sync
  begins.
- Incremental messages describe the latest affected entities, not DataScript tx-data.
- Incremental delivery is resumable, idempotent, ordered, and small.
- The server never receives graph decryption keys or plaintext for protected values.
- Logseq Chat can create blocks and modify block properties, but cannot request an
  entity deletion.
- Authentication, networking, and operating-system integration are platform
  adapters; sync protocol, codecs, state transitions, encryption orchestration,
  persistence, and graph mutations are implemented in the OCaml core.

## Implementation state

This ADR defines the target architecture. The implementation is deliberately being
rolled out in stages, so target behavior must not be mistaken for current platform
support:

| Area | Current state |
| --- | --- |
| Apple authentication | Amplify UI Swift `Authenticator` with `AWSCognitoAuthPlugin`; access-token session refresh is owned by Amplify |
| Android authentication | Cognito SDK adapter exists, but the Amplify Authenticator UI and challenge parity are not complete |
| Graph discovery | Authenticated db-sync `GET /graphs`, including encrypted-graph metadata |
| Graph catalog and offline open | The complete discovered graph catalog is persisted in the app metadata store; the last selected graph and its local mirror open before authentication or network restore |
| Unencrypted Apple sync | Full snapshot import, SSE latest-entity changes, offline-first local writes, self-echo reconciliation, and durable cursor are implemented and device-verified |
| Snapshot baseline | `snapshot/download` returns the pre-stream server `t`, schema version, row count, stream URL, and content encoding in one metadata response; OCaml commits that `t` only after atomic import |
| Android sync transport | OCaml core and full-snapshot download/import are connected; native SSE transport is not connected yet |
| Encrypted graph sync | Graphs are discoverable but opening them is explicitly rejected until the E2EE milestone is implemented and verified |

## Decision

### 1. Authenticate inside the app with Amazon Cognito

Logseq Chat will use the native Amplify Authenticator component rather than
implementing username, password, challenge, and account-recovery screens itself.
On Apple platforms this is Amplify UI Swift's `Authenticator` with Amplify Swift
and `AWSCognitoAuthPlugin`. Android will use the corresponding native Amplify UI
Authenticator behind the same app-level auth interface. The app will not open
Cognito Managed Login, Hosted UI, an embedded web view, or the system browser.

Logseq Chat is a Skip application, so authentication is exposed to shared app code
through a small platform service: Amplify Swift on Apple and Amplify Android in the
generated Android application. Cognito SDK session objects and tokens do not cross
the OCaml graph boundary; the adapter supplies an access token only when the OCaml
core requests an authenticated transport operation.

The preferred password flow is SRP (`ALLOW_USER_SRP_AUTH`) so the password itself
is not sent to Cognito. The Cognito app client is a public native client with no
client secret and allows refresh-token authentication. Enabled sign-in challenges,
including new-password, SMS MFA, TOTP, account confirmation, and recovery, are
rendered and continued by Amplify Authenticator rather than duplicated in Chat UI.

Amplify Auth owns session persistence and refresh. Logseq Chat obtains the Cognito
User Pool access JWT from `fetchAuthSession` when it needs to call an API. Every
Graph API, db-sync, asset, and key-management request will use:

```http
Authorization: Bearer <cognito-access-token>
```

The db-sync HTTP layer validates the JWT issuer, signature, expiry,
`token_use=access`, and Cognito `client_id`, then apply the same graph membership and
permission checks used by existing sync clients. A token identifies a user, not a graph. Graph
selection therefore happens only after the app calls the authenticated db-sync
`GET /graphs` operation. Semantic reads and writes remain under `/api/v1/graphs/...`;
graph discovery does not use the semantic graph-list route.

PAT configuration and the PAT input screen will be removed after Cognito login is
available. PATs may remain supported by existing APIs during migration, but Logseq
Chat will not use or persist them. Federated social sign-in is outside this decision
because Cognito User Pool federation normally uses a browser redirect; it must not
be added by silently changing the built-in-login requirement.

### 2. Use one server schema and keep sync metadata outside the graph

The db-sync server and Logseq Chat local graph will use the exact schema encoded in
the snapshot root for the server-reported Logseq schema version. It must match the
corresponding `logseq.db.frontend.schema/schema` definition. Schema datoms and
property-definition entities already stored in the graph remain part of the
existing snapshot. Logseq Chat will not maintain a reduced or chat-specific copy of
graph attributes.

The existing snapshot and tx-log formats use Transit. The new entity-change payload
will do the same so keywords, UUIDs, instants, integers, sets, and references retain
their logical types. References are normalized to stable lookup refs using the same
normalization rules as the current tx log; they are not changed into untyped JSON
strings. Cardinality-many values retain set semantics. The client will reject a
snapshot or change set when a value does not conform to the shared schema instead
of coercing it.

The existing chat cache may be removed or retained as a rebuildable UI projection,
but it is not the graph mirror and is never a sync source of truth. Each selected
graph currently has `graph.sqlite` for the Logseq-layout KVS graph and an atomically
replaced Transit `sync.checkpoint` sidecar containing graph id, schema version, and
applied server `t`. The separate app metadata store persists the discovered graph
catalog, last selected graph, pending local requests, and UI state. Those records
are not graph attributes and are not a second graph cursor.

No local-only attributes such as sync status or cached JSON projections will be
added to the graph database. This prevents the chat app from changing the meaning
or type of any server property.

Schema changes are a synchronization boundary. An SSE `reset` event with reason
`schema-changed` makes the client download a new snapshot into a new local database
and atomically replace the old database after validation. The client must not try to
infer or migrate a newer server schema.

### 3. Implement the client sync engine in OCaml

All cross-platform sync behavior will be implemented once in the existing native
OCaml core. Swift and Kotlin must not contain independent implementations of the
snapshot importer, SSE parser, cursor state machine, entity merge rules, schema
validation, E2EE value transformation, optimistic reconciliation, or write
allowlist.

The OCaml core owns:

- the db-sync request and response types;
- Transit and EDN codecs;
- SSE framing, event validation, replay, and server `t` state;
- framed snapshot decoding, staging, schema-first import, and atomic activation;
- the exact Logseq graph schema and typed DataScript values;
- entity upsert and remote-deletion application;
- E2EE key-state and protected-value transformation, using platform crypto
  primitives where required;
- validation that outgoing mutations are block creation or block-property updates;
- local query projections consumed by the chat UI.

Platform code is limited to Cognito UI and SDK calls, HTTP/SSE byte transport,
secure key and token storage, file handles, OS cryptographic primitives, background
lifecycle, and presentation. These adapters pass opaque byte chunks and explicit
results to OCaml. They do not parse or rewrite graph values.

The SSE adapter opens and owns the platform network task, then feeds bounded byte
chunks and terminal results into short, serialized OCaml FFI calls. It must not hold
an OCaml runtime lock for the lifetime of a connection. Blocking native REST
transport releases the OCaml runtime while waiting, so an unreachable server cannot
serialize unrelated local graph operations behind its timeout. Snapshot downloads
likewise stream to a file or bounded OCaml decoder;
they are not materialized as one JSON RPC string.

The existing JSON RPC across the Swift/Kotlin-to-OCaml FFI remains a small control
and UI envelope. Graph snapshots, SSE entity values, and outgoing graph mutations
do not pass through `Yojson.Basic`; keeping them as typed OCaml values avoids the
property-type loss this ADR forbids.

Both codec projects are cross-target OCaml implementations supporting native OCaml,
js_of_ocaml, and Melange; they are not Melange-only libraries. Logseq Chat's mobile
core uses their native backends:

- `melange-transit-native` for the existing db-sync Transit JSON protocol, snapshot
  row contents, entity events, keywords, UUIDs, dates, maps, sets, and tagged values;
- `melange-edn-native` for schema or configuration artifacts that are represented as
  EDN and for typed EDN/Yojson conversion at explicit non-graph boundaries.

The shared core packages provide the common value models, and the native packages
provide native parsing and writing. The js_of_ocaml and Melange variants are not
runtime dependencies of the mobile app, but their cross-backend test suites are
useful compatibility evidence for payloads also produced by ClojureScript.

Transit remains the sync wire format. EDN is not an intermediate representation for
Transit payloads. The dependencies are pinned to exact Git revisions by the native
dependency build script so Apple and Android builds use the same codec version. Cross-codec
fixtures copied from `logseq-1` must prove byte-level decoding compatibility before
the old JSON projection path is removed.

`datascript-ocaml` already uses `melange-transit-native` in its native SQLite work
and contains `Logseq_sqlite_storage`, which recognizes Logseq's Transit root, tail,
and persistent-sorted-set nodes and has tests against generated and real Logseq
graphs. That implementation will be promoted from its example library into a
supported package and reused. The existing `datascript-ocaml-native.sqlite` adapter
and Logseq Chat's `Marshal` codec cannot open a db-sync snapshot directly and will
not be used to decode it.

### 4. Bootstrap with the existing db-sync snapshot download

When a user opens a graph that has no completed local copy for its graph id and
schema version, the client will follow the existing db-sync snapshot contract used
by Logseq Chat:

1. `GET /sync/:graph-id/snapshot/download` to obtain the existing snapshot stream
   URL together with the current server transaction number `t`, schema version,
   row count, and content encoding. That `t` is the pre-stream replay baseline.
2. Download the gzip-capable framed Transit stream of SQLite `kvs` rows
   `[addr, content, addresses]`.
3. Stage those rows unchanged in a temporary Logseq-layout SQLite database.
4. Use the promoted native `Logseq_sqlite_storage` Transit decoder to load the
   snapshot schema and datoms, then reconstruct the app's local DataScript graph in
   schema-first import order, as the current `frontend.worker.sync.download`
   implementation does.

The platform adapter may inspect the stream URL and content encoding to perform the
download, but passes the original metadata response to OCaml. The OCaml sync session
validates `t`, schema version, and row count and owns the import checkpoint.

No new snapshot envelope or parallel Graph API snapshot route will be introduced.
The existing snapshot preserves all `kvs` graph storage; both server and client open
it with the same version of `db-schema/schema`. Asset bytes remain in the existing
asset API; asset entities and metadata are in the graph snapshot.

The snapshot-download handler reads baseline `t` before the client consumes the
separate snapshot stream. After import, SSE starts from that `t`, so every
transaction concurrent with snapshot streaming is considered again.
Complete entity upserts are idempotent, making an entity already present in the
snapshot safe to replay. db-sync must not garbage-collect tx-log entries newer than
the baseline while the download is active; if it cannot serve the range, it sends a
reset and the client downloads again.

The client verifies the stream framing and imports into a new local database. It
records the baseline `t` only after import succeeds, then exposes the graph. An
interrupted or invalid import is discarded and restarted; a partial graph is never
opened.

### 5. Support encrypted and unencrypted graphs with the same sync protocol

The existing graph-list metadata identifies whether a graph is encrypted. For an
encrypted graph, Logseq Chat will use the existing Logseq E2EE key flow:

1. Fetch the user's encrypted private key with the Cognito access token.
2. Unlock it locally with the user's E2EE password.
3. Fetch the graph AES key encrypted for that user.
4. Decrypt protected attribute values and encrypted assets only on the device.

The server stores and transmits protected values as ciphertext and does not receive
the password, private key, or plaintext AES key. Unprotected schema and identity
fields remain available to db-sync so it can authorize access, identify affected
entities, and produce change sets.

The existing snapshot format and the new entity-change format each work for both
encrypted and unencrypted graphs. For encrypted graphs, protected values are
ciphertext on the wire and are decrypted by the existing
`frontend.worker.sync.crypt` rules before local transaction. The schema-aware
encryption codec must round-trip the original property type; encryption is not
allowed to permanently turn a keyword, number, UUID, instant, reference, or
collection into a string in the local graph. Existing Logseq encryption metadata
and algorithms will be reused rather than introducing a chat-specific format.

If the key is missing, access was revoked, or decryption fails, the app stops import
or event application and locks the graph. It does not store a partly decrypted graph
or fall back to treating ciphertext as user content.

### 6. Stream entity change sets over SSE

db-sync will expose one authorized SSE stream for a selected graph and schema
version:

```http
GET /sync/:graph-id/events?since=<t>
Accept: text/event-stream
Authorization: Bearer <cognito-access-token>
Last-Event-ID: 48192
```

The query `since` is used when the platform cannot set `Last-Event-ID`; if both are
present, `Last-Event-ID` wins. The server sends heartbeat comments and disables
intermediary buffering. On token expiry, the client refreshes the token and resumes
from its last committed cursor.

Normal events use the existing monotonically increasing, graph-branch-scoped server
transaction number as the cursor:

```text
id: 48193
event: graph-changes
data: {"format-version":1,"graph-id":"...","schema-version":"...","t-before":48192,"t":48193,"upserts":[...],"deleted":[...]}
```

The actual `data` payload is Transit-encoded even when shown as JSON above. It has
only these change collections:

- `upserts`: the complete latest server representation of each affected entity;
- `deleted`: stable remote entity identifiers for entities that no longer exist.

An entity identifier is a typed lookup identity, not a numeric DataScript entity
id. The initial protocol supports `[:block/uuid <uuid>]` and `:db/ident` identities,
which are exactly the identities retained by the current normalized tx log. An
upsert is encoded as that identity plus a complete attribute map. Every reference
value is encoded as a typed lookup identity as well; no server-local numeric entity
id crosses the wire.

The implementation reuses `storage/fetch-tx-since`, `storage/get-t`, and the current
DataScript connection in the per-graph Durable Object. For `t-before`, the handler
captures the current immutable database value and `t-now`, reads normalized tx-log
entries in `(t-before, t-now]`, and extracts stable entity identities from their
entity positions, `:block/uuid` additions, and `:db/retractEntity` lookup refs. It
deduplicates those identities and reads their current datoms from the captured
database, converting reference entity ids back to lookup identities according to
the exact schema.
Each surviving identity becomes one latest-state upsert; each affected identity
absent from that database becomes a deletion. The event advances directly to
`t-now` because the protocol promises the latest state, not every intermediate
transaction.

The current normalizer does not retain a stable identity for every possible
DataScript entity (for example, a file entity identified only by `:file/path`). The
server must not emit a partial entity or numeric id in that case. Before enabling
SSE for such entities, normalization is extended to retain every supported unique
identity and the server capability's minimum cursor is advanced. A replay that
encounters an older unidentifiable transaction returns `reset` and requires a fresh
snapshot. This keeps legacy tx-log limitations explicit instead of silently losing
changes.

For a live commit, the transaction listener can perform the same derivation from
the transaction report's tx-data and immutable `db-after`, paired with the existing
server transaction number. Capturing the database value and `t-now` under the
graph's serialized writer prevents a transaction from being present in one and
absent from the other.

Raw datoms and tx-data remain an internal change index and are never sent to Logseq
Chat. Multiple writes to an entity in the range produce one final upsert. If an
entity was changed and then deleted, only its id is included in `deleted`. No
unchanged entity is included. Transactions that affect no graph entity can advance
`t` with an empty change set so continuity is preserved.

An upsert is a complete entity, rather than a partial property patch. This is the
smallest idempotent unit that also communicates property retractions without
recreating tx-data semantics. Applying the same event more than once has no effect:
the client replaces the known attributes of every upserted entity, retracts local
attributes absent from that representation, and retracts every deleted entity.

The client applies one event and advances its local `t` in one durable operation.
It must reject an event when its graph id or schema version differs, or when
`t-before` does not equal the last committed `t`.

If the requested cursor has expired, the schema changed, an event is too large for
the stream, or the server cannot prove a contiguous range, the server sends:

```text
event: reset
data: {"reason":"cursor-expired","snapshot-required":true}
```

The client then closes the stream and repeats the full-snapshot process. SSE is
at-least-once delivery; the cursor and idempotent entity upserts make duplicates
safe.

### 7. Restrict client writes to block creation and property modification

Logseq Chat may submit only these mutations through authenticated server APIs:

- add a new block;
- modify properties of an existing block.

Writes use the existing semantic REST resources under `/api/v1/graphs/:graph-id`.
Block creation uses `capture` (and the corresponding task or asset operation), and
property changes use the block property update resource. Logseq Chat does not call
the db-sync tx-batch endpoint and does not submit raw DataScript transactions.

The client will not expose or call entity-delete, page-delete, block-delete,
retract-entity, arbitrary transaction, move, or asset-delete operations. The server
must enforce this allowlist; hiding controls in the UI is not sufficient. For an
encrypted graph, the client encrypts protected property values with the graph AES
key before upload, using the existing E2EE codec.

This restriction applies to mutations initiated by Logseq Chat. The local database
is still a mirror, so it must apply deletions received over SSE when another
authorized Logseq client or server process deletes an entity. A remote deletion is
never converted into or replayed as a client-originated delete request.

A successful create or property update is not considered synchronized merely
because its HTTP request succeeded. The originating client receives the same
authoritative entity upsert through SSE as other clients. Optimistic UI state may be
shown separately, but only the SSE event advances the graph cursor and replaces the
local graph value. Existing server conflict and permission rules remain
authoritative.

Every supported mutation is local-first. The OCaml core commits it to the app's
durable pending store before the UI publishes the result. A single serialized sync
pump sends queued operations when transport is available. An HTTP failure
leaves the operation retryable; it must not roll back the local edit, hide the graph,
or block subsequent create, edit, search, and navigation operations. A remote read
or refresh cannot overwrite an unsynchronized local value. On successful REST
submission the operation enters a submitted state and remains overlaid on the graph
mirror until the matching SSE upsert confirms the authoritative value.

## End-to-end flow

1. Log in inside the app through Amplify Auth and the Cognito User Pool.
2. List authorized graphs and select one.
3. Resolve the graph's schema version and encryption flag.
4. If encrypted, unlock the graph key locally.
5. If no valid local copy exists, call the existing `snapshot/download` API, retain
   its metadata `t` as the pre-stream baseline, and atomically import its framed
   `kvs` row stream.
6. Open SSE from the baseline server transaction number `t`.
7. Apply ordered entity upserts and deletions transactionally and persist each
   cursor.
8. On disconnect, refresh the Cognito session if necessary and resume from the
   committed cursor.
9. On `reset`, build a new local database from a fresh full snapshot.

## Required server changes

- Reuse the existing Cognito JWT verification and graph access checks, and add the
  Logseq Chat Cognito app client id to the allowed client ids.
- Expose graph encryption and schema-version metadata in the graph list.
- Keep `GET /sync/:graph-id/snapshot/download` and its framed Transit `kvs` stream as
  the only full-download path. Its metadata response includes the pre-stream `t`,
  schema version, row count, stream URL, and content encoding; bootstrap does not
  add a separate `/pull` request.
- Add `GET /sync/:graph-id/events?since=<t>` to the existing per-graph Durable
  Object, with replay, heartbeat, and explicit reset behavior.
- Use `storage/fetch-tx-since` and `storage/get-t` to find affected stable entity
  identities, then pull their latest values from the current DataScript connection;
  do not introduce a second change database, cursor, or an `as-of` query.
- Use the Cognito `client_id` claim to enforce that Logseq Chat may call only
  block-create and block-property-update mutations.
- Emit metrics for connected streams, replay lag, event size, reset reason,
  authorization failure, and snapshot duration.

## Required Logseq Chat changes

- Replace PAT configuration with built-in Cognito login and challenge screens backed
  by Amplify Auth session, refresh, logout, and secure storage behavior.
- Add pinned `melange-transit-native` and `melange-edn-native` dependencies to the
  OCaml build.
- Promote and reuse `datascript-ocaml`'s tested Logseq KVS Transit reader; do not
  feed server snapshot rows to the current `Marshal`-based SQLite adapter.
- Implement protocol codecs, snapshot import, SSE state, entity application, E2EE
  orchestration, and mutation validation as OCaml modules behind narrow signatures.
- Keep Swift and Kotlin adapters byte-oriented and free of graph-schema or sync-state
  logic.
- Add graph selection and encrypted-graph unlock states.
- Replace the reduced local schema with the exact `logseq-1` graph schema for the
  server-reported schema version and reuse the current snapshot row import design.
- Store the applied server `t` and snapshot import state outside the graph database.
- Persist the full graph discovery catalog and last selected graph in the app
  metadata store so an existing graph opens without authentication or network.
- Add an SSE client with reconnect, replay, atomic event application, and reset
  handling.
- Add byte-stream platform adapters and short serialized FFI entry points so the
  current blocking JSON RPC mutex is never held by a live stream.
- Query the local full graph for chat views and expose only add-block and
  modify-block-properties mutations.
- Persist every mutation before presentation, send queued writes only through the
  semantic REST API, and retain optimistic values until authoritative SSE echo.
- Reuse Logseq's E2EE key and value codecs and keep decrypted graph storage within
  the platform's protected application data.

## Consequences

### Positive

- The chat app sees changes shortly after they commit without periodic full refresh.
- Full local data enables offline and low-latency queries.
- Reusing db-sync snapshot download and the DataScript tx-data log avoids a second
  snapshot or change-history subsystem.
- One schema and typed transport prevent subtle cross-client property corruption.
- Entity snapshots are simpler and safer to apply than raw transaction history.
- SSE uses ordinary authenticated HTTP and is simpler than a bidirectional socket
  for a server-to-client feed.
- The same protocol supports encrypted graphs without weakening E2EE.
- One OCaml sync engine gives Apple and Android identical cursor, codec, schema,
  encryption, and mutation behavior.

### Negative

- A first open can be expensive for a large graph.
- Complete affected entities may repeat unchanged attributes, although only affected
  entities are sent.
- The server must retain enough cursor history for useful reconnects or force a new
  snapshot.
- Mobile lifecycle limits mean real-time delivery is guaranteed only while the app
  can maintain the stream; background refresh remains a best-effort fallback.
- E2EE password and key recovery add user-visible failure states.
- Built-in Cognito authentication requires native UI for all enabled challenge
  states on both Apple and Android platforms.
- The native OCaml build gains two codec dependencies and requires compatibility
  fixtures against the ClojureScript server formats.

## Rejected alternatives

### Continue polling the Graph API

Polling is simple but wastes requests, increases update latency, and cannot provide
a reliable contiguous cursor.

### Use Cognito Managed Login or Hosted UI

Browser-based login supports federation well, but it violates the requirement that
authentication be built into Logseq Chat. The app embeds Amplify's native
Authenticator component and uses Cognito SDK authentication instead.

### Add a new full-snapshot endpoint

db-sync already has `GET /sync/:graph-id/snapshot/download` and a streaming snapshot
of its DataScript SQLite `kvs` rows. Creating another endpoint or entity snapshot
format would duplicate its permission, snapshot, encryption, and import behavior.

### Send DataScript tx-data over SSE

Raw tx-data exposes storage internals, is difficult to version, can contain
intermediate values, and forces every client to reproduce server transaction
semantics. It also makes schema and encryption mistakes more likely.

### Send partial entity patches

Patches are smaller in some cases but require explicit attribute-retraction and
cardinality-many merge rules. Those rules become another form of tx-data. Complete
latest entities are idempotent and unambiguous.

### Maintain a chat-specific graph schema

A projection is attractive for UI code but changes types, drops data needed by
references, and creates a second schema that must migrate independently. UI models
may project from the local graph in memory, but the stored graph must use the server
schema.

### Implement sync separately in Swift and Kotlin

Separate platform implementations would duplicate the most correctness-sensitive
state machine and make schema, encryption, and replay behavior diverge. Platform
code provides capabilities to the OCaml core instead.

### Use WebSockets for the new downstream feed

The client only needs a resumable server-to-client stream. SSE supplies reconnect
and event ids over HTTP with less client and infrastructure complexity. Existing
WebSocket sync can continue serving existing clients during rollout.

## Rollout and verification

The snapshot and SSE payloads are versioned independently from the graph schema.
The new path will be enabled behind a server capability flag and rolled out first to
test graphs, then unencrypted graphs, then encrypted graphs.

The implementation is complete when automated integration tests demonstrate:

- built-in Cognito login, challenge handling, session refresh, logout, expired-token
  reconnect, and graph authorization;
- exact schema and value-type parity after a full snapshot import;
- native OCaml Transit fixtures decode snapshot rows and SSE entities produced by
  `logseq-1`, then encode values the server decodes without type changes;
- native OCaml EDN fixtures preserve every schema/configuration value used by the
  app, including UUID and instant tags;
- the same OCaml sync tests run for both Apple and Android core builds, with no sync
  decisions implemented in Swift or Kotlin;
- first-open behavior never exposes a partial graph;
- remote create, update, property retraction, reference change, move, and entity
  deletion produce minimal, latest-state events with no tx-data on the wire;
- the server derives those events solely from the existing DataScript tx-data log,
  existing server transaction numbers, and a captured current database value;
- Logseq Chat can add blocks and modify block properties, while all delete and
  arbitrary transaction requests are rejected by the server;
- duplicate and replayed events are idempotent and cursor gaps trigger reset;
- disconnect/reconnect does not lose committed changes;
- while the API is unreachable, repeated creates and property edits remain
  responsive, survive process termination, preserve their latest state, and synchronize after
  reconnect without duplicate server entities;
- schema changes force atomic re-bootstrap;
- encrypted and unencrypted snapshots converge to the same logical graph data;
- encrypted changes and assets are never plaintext in server logs or wire captures;
- revoked graph access terminates the stream and prevents reconnect.

## References

- `logseq-1/docs/agent-guide/db-sync/protocol.md`
- `logseq-1/deps/db-sync/src/logseq/db_sync/storage.cljs`
- `logseq-1/deps/db-sync/src/logseq/db_sync/worker/handler/sync.cljs`
- `logseq-1/src/main/frontend/worker/sync/download.cljs`
- `datascript-ocaml/examples/logseq_sqlite_storage.ml`
- `logseq-chat/core/logseq_chat_sqlite.ml`
- `logseq-chat/core/logseq_chat_core_ffi.c`
- [melange-transit: native OCaml, js_of_ocaml, and Melange Transit JSON](https://github.com/RCmerci/melange-transit)
- [melange-edn: native OCaml, js_of_ocaml, and Melange EDN](https://github.com/RCmerci/melange-edn)
- [Amplify Swift sign-in](https://docs.amplify.aws/swift/frontend/auth/sign-in/)
- [Amplify Swift session and Cognito token access](https://docs.amplify.aws/swift/frontend/auth/manage-user-sessions/)
- [Amazon Cognito User Pool authentication flows](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-authentication-flow-methods.html)
