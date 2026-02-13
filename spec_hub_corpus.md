# Hub Corpus (Distributed Corpus Sync) Specification

This document specifies the "hub-corpus" feature: **distributed corpus synchronization** between multiple Echidna instances via a central WebSocket hub process (`echidna-corpus-hub`).

It is written to match the behavior implemented in:
- Client (Echidna): `echidna/lib/Echidna/CorpusSync.hs`
- Campaign + entry hashing: `echidna/lib/Echidna/CorpusSync/Hash.hs`
- Protocol encoding/decoding: `echidna/lib/Echidna/CorpusSync/Protocol.hs`
- Hub server: `echidna/src/hub/Main.hs`
- Benchmark target used in this spec: `echidna/benchmark/contracts/bench/CorpusMaze.sol`

The second half of this document defines a **benchmark/testing procedure** that demonstrates how hub-corpus improves:
- time-to-bug discovery
- time-to-deep-coverage
using `CorpusMaze.sol` as a concrete target.

## 0. Feynman-Style Introduction (For Anyone)

### 0.1 The Problem, In One Sentence

When you run multiple Echidna fuzzers separately, they often waste time re-discovering the same "good starting points" instead of building on each other's progress.

### 0.2 What Is A "Corpus" (No Jargon)

Think of fuzzing like exploring a huge maze of program behaviors.

- A **transaction sequence** is one attempt at walking the maze (a list of calls with inputs).
- Coverage-guided fuzzing tries many random attempts, but it also keeps the attempts that went somewhere new.
- The set of those "useful attempts" is the **corpus**.

In Echidna terms: the corpus is a collection of call sequences that are good seeds for future mutations.

Why keep them?
- If one sequence reached a new branch/state, mutating that sequence is much more likely to reach a nearby new branch/state than starting from scratch.

### 0.3 Why Sharing A Corpus Helps (The Key Intuition)

Imagine 4 people trying to solve a combination lock.

- If they never talk, each person will try many combinations the others already tried.
- If they write down every partial success (for example "first digit is 7") and share it, everyone starts from the best-known partial progress.

Hub-corpus is that "shared notebook" for fuzzing:
- if any node finds a sequence that unlocks a new branch/state, other nodes can reuse it as a starting point
- this makes the whole fleet converge on deep behaviors faster

### 0.4 What The Hub Actually Does (Simple Story)

The hub (`echidna-corpus-hub`) is a WebSocket server. It does not run the EVM and it does not fuzz.

It does three jobs:
1. **Receive** new corpus entries from nodes.
2. **Deduplicate + store** them (so the same entry is not saved 100 times).
3. **Announce** that "a new interesting entry exists" to all connected nodes.

Nodes can then ask the hub for the full content (the transaction sequence) if they want it.

This "announce first, fetch later" design matters:
- Announcements are small (metadata only).
- Payloads are only transferred to nodes that decide to ingest them.

### 0.5 What Each Node Does

Each Echidna node runs its normal fuzzing loop, plus a small sync client:
- When it discovers new coverage, it publishes the triggering transaction sequence as a **coverage entry**.
- When it finds a failing property, it publishes a **failure event** (`failure_publish`), and the hub may broadcast `fleet_stop` (optional).
- When it hears about a new entry via `corpus_announce`, it decides whether to ingest it.
- Ingest rule (reproducers): reproducers (if published as corpus entries) are always ingested.
- Ingest rule (coverage): coverage entries are rate-limited and can be sampled, to avoid flooding.
- If it ingests, it requests the payload (`corpus_get`) and inserts the sequence into its local corpus, so it can mutate it.

### 0.6 How Nodes Avoid Mixing "Incompatible" Corpuses (Campaign Fingerprint)

Sharing is only useful if the sequences make sense in the recipient's world.

Example of "does not make sense":
- A sequence calls address `0xABC...`, but your node never deployed a contract at `0xABC...`.

To prevent this, every message is scoped to a **campaign fingerprint**:
- each node computes a hash that summarizes the "important parts" of what it is fuzzing (contracts and their runtime codehashes, deployment config, fork settings, etc.)
- nodes only share entries when they compute the same fingerprint (unless you override it)

So, from a user's perspective:
- same target + same deployment + same fork configuration -> share corpus
- different build or different target -> automatically isolated

### 0.7 A Concrete Example: Why `CorpusMaze` Benefits

`CorpusMaze` is deliberately built so that you only advance state if the low nibble matches exactly:
- to go from state 0 to 1, you need `x & 0xF == 0`
- to go from 1 to 2, you need `x & 0xF == 1`
- ...
- reaching state 16 falsifies `echidna_maze_unsolved()`

So the hard part is not "one magic input", it is building a long prefix of correct steps.

With hub-corpus:
- if node A reaches state 8, it publishes the sequence
- node B can start mutating around a state-8-reaching sequence instead of spending time rediscovering states 0..7
- the fleet effectively explores deeper levels in parallel

### 0.8 What "Faster" Means In Practice (What To Measure)

There are two separate "wins":
- **Bug discovery win**: time until any node finds a falsification (time-to-first-failure).
- **Coverage win**: how quickly the fleet reaches deeper program states/branches (for `CorpusMaze`, the deepest `state == k` branch reached).

The benchmark section later in this doc is designed to measure both with repeatable runs.

### 0.9 Why This Beats The Standard Approach

The "standard" multi-process approach is: start multiple Echidna instances, each with its own local corpus, and hope that running more CPU in parallel finds bugs faster.

That helps, but it leaves a lot of performance on the table for deep/stateful targets:
- Each node spends significant time rediscovering the same shallow prefixes (duplicated work).
- A "breakthrough" input sequence found by one node does not help others until the run ends (or you manually copy corpuses around).
- If you split one machine into many processes, you also lose some of the benefit of a single shared in-memory corpus, because corpuses are now isolated.

Hub-corpus improves on this by sharing the *useful intermediate progress* continuously:
- When any node finds a sequence that reaches new coverage/state, that sequence becomes a seed for all other nodes (subject to ingest rate limits/sampling).
- Nodes stop doing the same early exploration repeatedly and can spend more time pushing the frontier outward.
- The total effective work of the fleet becomes closer to "N people exploring together" instead of "N people exploring the same first few rooms".

On `CorpusMaze` specifically, the standard approach wastes time because many nodes will keep re-finding "state 0 -> 1" and "1 -> 2" sequences.
With hub-corpus, once any node reaches (say) state 8, other nodes can immediately start mutating around a state-8-reaching sequence, which makes reaching 9..16 much more likely within the same time budget.

Operationally, hub-corpus also gives you:
- A single place to persist campaign entries and resume after restarts.
- Optional fleet coordination: the hub can broadcast `fleet_stop` when a failure is reported (useful for time-to-failure benchmarks).

### 0.10 When Hub-Corpus Helps (And When It Doesn't)

Hub-corpus is not only for `CorpusMaze`. `CorpusMaze` is just a benchmark where the benefit is easy to see.

Hub-corpus tends to help most when:
- The target is deep and stateful (state machines, multi-step setup, invariants that only fail after many calls).
- Interesting behavior requires rare preconditions (specific bit patterns, role/permission sequences, time/epoch transitions, multi-contract orchestration).
- You are running a fleet (multiple processes or machines) and want nodes to share intermediate breakthroughs continuously.

Hub-corpus tends to help least (or can even slow things down) when:
- The target is shallow/stateless and coverage saturates quickly.
- Bugs are typically found very quickly, so sync overhead dominates.
- You are already running one Echidna process with many workers on one machine (those workers already share a single in-memory corpus).
- Nodes are not actually compatible (different builds/deployments/fork state). The campaign fingerprint prevents mixing by default; forcing `campaignOverride` can cause nodes to ingest many unusable sequences.

## 1. Background and Motivation

Echidna is coverage-guided: as it discovers new coverage, it keeps "interesting" call sequences in a **corpus** and mutates them to explore new behaviors.

In a single Echidna process, multiple workers already share a corpus in-memory. However, in a multi-machine or multi-process fuzzing fleet, each Echidna instance traditionally learns in isolation and duplicates work.

The hub-corpus approach provides:
- **cross-instance learning**: coverage-improving sequences discovered by any node become seeds for all nodes
- **failure coordination**: once any node finds a failure, it publishes a `failure_publish` event; the hub can optionally broadcast `fleet_stop` to stop peers quickly
- **optional coordinated stopping**: stop the entire fleet once one node finds a failure (useful for time-to-failure benchmarks)
- **persistence**: the hub stores entries on disk and supports reconnect + resume

This feature is specifically designed to help targets where reaching deep state requires a sequence of partial advances, e.g. `CorpusMaze`.

## 2. Non-Goals

This v1 implementation does not try to be:
- a secure multi-tenant service on an untrusted network (it has basic bearer auth, but not hardened beyond size limits and rate limits)
- a general-purpose artifact store (it stores only corpus entries for fuzzing, in a fixed JSON encoding)
- a fully validating execution-based "proof" that ingested entries are semantically valid for a recipient (see `validate` modes below)
- a bandwidth-optimized binary protocol (messages are JSON; compression is not implemented in v1)

## 3. Terminology

- **Node / client**: an Echidna instance running a fuzzing campaign.
- **Hub**: the centralized WebSocket server (`echidna-corpus-hub`) that deduplicates, persists, and broadcasts corpus metadata.
- **Campaign**: a fuzzing "universe" identified by a fingerprint hash; prevents corpus mixing across incompatible builds/configs.
- **Entry**: a single corpus element consisting of a transaction sequence (`txs`) plus metadata (`EntryMeta`).
- **Entry ID**: content-addressed identifier of an entry: `sha256(encode(txs))`.
- **Seq**: monotonically increasing sequence number assigned by the hub to accepted entries (per campaign); used for resume/paging.
- **Coverage entry**: an entry published when a node finds new coverage.
- **Reproducer entry**: an entry published when a node finds a failure (a failing call sequence).
- **Announce**: hub broadcast containing only entry metadata; peers fetch the payload via `corpus_get` if they decide to ingest.

## 4. High-Level Architecture

### 4.1 Components

1. Hub process: `echidna-corpus-hub`
   - Listens on a TCP host/port
   - Accepts WebSocket connections
   - One logical state machine per campaign (campaign is identified by hash string)
   - Persists entries to disk and reloads them on restart

2. Client in each Echidna node: "CorpusSync"
   - Runs in-process alongside fuzzing workers
   - Publishes new-coverage entries and failure events (including reproducer payload) to hub (configurable)
   - Subscribes to hub announcements and ingests selected remote entries into local corpus
   - Persists ingested entries to local corpus dir (if `corpusDir` configured)

### 4.2 Data Flow

At a high level:

```text
          (corpus_publish / failure_publish)
Node A --------------------------------------+
                                             |
                                             v
                                         +-------+
                                         |  Hub  |
                                         +-------+
                                             |
                                             v
          (corpus_announce / fleet_stop)  (broadcast)
Node B <--------------------------------------+
  |                                           |
  +--- corpus_get(entry_id) ------------------+
  <--- corpus_entry(entry + txs) -------------+
```

Key property: nodes do not push full payloads to every peer. They push once to hub, then peers pull on demand.

## 5. Campaign Fingerprint (Isolation)

All messages are scoped to a **campaign fingerprint** (a `Text` hash) carried in the envelope field `campaign`.

### 5.1 Default fingerprint computation

Unless overridden, the client computes a fingerprint via `computeCampaignFingerprint` in `echidna/lib/Echidna/CorpusSync/Hash.hs`:
- `echidna_version` (the compiled Echidna version)
- `selected_contract` (if the user chose `--contract`, included; otherwise `null`)
- `contracts`: list of all compiled contracts, keyed by `contractName` and including their `runtimeCodehash`
- deployment-relevant Solidity config (`SolConf`):
  - `contractAddr`, `deployer`, `solcLibs`
  - `deployContracts`, `deployBytecodes`
  - `allContracts`
- fork settings (`rpcUrl`, `rpcBlock`)
- `chainId`

The descriptor is encoded as JSON, then hashed with SHA-256 to produce the campaign fingerprint.

Practical implication: two nodes will only share corpus if they are actually fuzzing a compatible build + deployment configuration.

### 5.2 Override

You can override the campaign identifier with:
- config: `corpusSync.campaignOverride`

This is useful if you intentionally want to force multiple nodes to share a corpus even if some descriptor fields differ. It is also dangerous: it can cause nodes to ingest invalid sequences (reverts, missing addresses, etc).

## 6. Entry Model

### 6.1 Payload (txs)

An entry payload is:
- `txs`: `[Tx]` as Echidna uses internally (`Echidna.Types.Tx`)
- encoding: `"json"` (v1)
- compression: `"none"` (v1)

The hub persists these JSON payloads as `.txt` files containing JSON.

### 6.2 Content addressing: `entry_id`

Both publisher and hub compute:

```text
entry_id = sha256(encode(txs))
```

Publishing rules:
- The client populates `EntryMeta.entryId` with this value.
- The hub recomputes `entry_id` and rejects entries where it does not match (`id_mismatch`).

Ingestion rules:
- Recipients recompute and drop entries whose payload hash does not match the announced `entry_id`.

This provides:
- strong deduplication
- idempotent GETs and replays
- cheap integrity checking of payloads

### 6.3 EntryMeta fields

`EntryMeta` fields as used by the implementation:
- `entry_id`: `Text` (sha256 hex)
- `entry_type`: `"coverage"` or `"reproducer"`
- `encoding`: `"json"`
- `compressed`: `"none"`
- `tx_count`: length of `txs`
- `bytes`: size of encoded payload in bytes
- `origin`:
  - `instance_id`: opaque random ID assigned by client per run
  - `worker_id`: optional worker ID (coverage entries have this)
  - `worker_type`: optional `"fuzz"`/`"symbolic"` (coverage entries use this)
- `hints`: optional JSON object (used for informational/diagnostic metadata)

Client-side hint population:
- Coverage entries:
  - `coverage_points_total`: total coverage points known by the origin node at the time of publishing
  - `num_codehashes`: number of codehashes tracked in coverage
  - `corpus_size`: size of the origin node's local corpus
- Reproducer entries:
  - `test_name`: name of the falsified property/assertion

## 7. Transport and Protocol

### 7.1 Transport

- WebSockets:
  - `ws://host:port/path` (plaintext)
  - `wss://host:port/path` (TLS)
- The client supports both; it chooses based on URL scheme.
- Default path used by configs is `/ws`.

Note: `CorpusSyncTLSConf` exists in config (`insecureSkipVerify`, `caFile`) but is not wired into the v1 client transport yet.

### 7.2 Envelope

All messages are JSON in an envelope:

```json
{
  "v": 1,
  "type": "corpus_publish",
  "msg_id": "0123abcd...",
  "ts": "2026-02-12T12:34:56Z",
  "campaign": "<campaign_fingerprint>",
  "payload": { ... }
}
```

Fields:
- `v`: protocol version (currently `1`)
- `type`: message type string
- `msg_id`: request/response correlation ID (may be `null`)
  - direct responses typically mirror the request's `msg_id`
  - broadcast messages typically set `"msg_id": null`
- `ts`: timestamp (UTC) set by sender
- `campaign`: campaign fingerprint string
- `payload`: message-specific JSON object

### 7.3 Client -> Hub messages

#### 7.3.1 `hello` (required first message)

The hub requires that the very first message on a connection is `hello`. If not, the hub closes the connection.

Payload (client):

```json
{
  "instance_id": "<random hex>",
  "client": { "name": "echidna", "version": "<string>" },
  "capabilities": {
    "max_msg_bytes": 1048576,
    "supports_binary": false,
    "supports_zstd": false,
    "supports_resume": true
  },
  "resume": { "since_seq": 123 },
  "auth": { "type": "bearer", "token": "<token>" }
}
```

Notes:
- `resume.since_seq` may be `null` (if resume disabled).
- `auth` may be `null` if no token configured.

Hub-side auth behavior:
- `--no-auth` accepts all clients.
- otherwise, hub expects `auth.type == "bearer"` and `auth.token` in allowed token list.

#### 7.3.2 `corpus_publish`

Publish one entry (coverage or reproducer, but in practice client publishes:
- coverage entries due to coverage improvements
- reproducer entries via `failure_publish` message type instead)

Payload:

```json
{ "entry": { ...EntryMeta... }, "txs": [ ... ] }
```

#### 7.3.3 `corpus_publish_batch`

Publish multiple entries in one message.

This is treated as an extension (not a different envelope version). Hub advertises support in `welcome.features.supports_batch`.

Payload:

```json
{
  "items": [
    { "entry": { ...EntryMeta... }, "txs": [ ... ] },
    { "entry": { ...EntryMeta... }, "txs": [ ... ] }
  ]
}
```

#### 7.3.4 `corpus_get`

Request payload for a known entry ID.

Payload:

```json
{ "entry_id": "<sha256>" }
```

#### 7.3.5 `corpus_since_request`

Request a page of metadata newer than a given hub seq number.

Payload:

```json
{ "since_seq": 123, "limit": 1000 }
```

`since_seq` is exclusive: entries with `seq <= since_seq` are omitted.

#### 7.3.6 `failure_publish`

Publish a failure event (plus a reproducer payload).

The client generates:
- `entry_id` for the reproducer as `sha256(encode(txs))`
- `failure_id` as `sha256(encode(test_name <> ":" <> entry_id))`

Payload:

```json
{
  "failure": { "failure_id": "<sha256>", "test_name": "<name>" },
  "reproducer": {
    "entry_id": "<entry_id>",
    "encoding": "json",
    "compressed": "none",
    "txs": [ ... ],
    "origin": { "instance_id": "<origin_instance_id>" }
  }
}
```

The hub uses `failure_id` primarily for deduplicating fleet-stop broadcasts.

Note (v1): the hub currently does **not** persist or announce the reproducer payload from `failure_publish`.
It acks/logs the failure and may broadcast `fleet_stop`, but peers cannot fetch that reproducer via `corpus_get`.

### 7.4 Hub -> Client messages

#### 7.4.1 `welcome`

Sent once after a successful hello/auth.

Payload:

```json
{
  "session_id": "hub",
  "hub": { "name": "echidna-corpus-hub", "version": "0.2.0" },
  "features": {
    "supports_get": true,
    "supports_batch": true,
    "supports_since_request": true,
    "supports_stop_broadcast": true
  },
  "state": { "latest_seq": 456, "corpus_entries": 120 }
}
```

Clients use `features.supports_batch` for publish batching decisions.

#### 7.4.2 `ack`

Direct response to publish (or other accepted requests).

Examples:

```json
{ "ok": true, "status": "accepted" }
```

or

```json
{ "ok": true, "status": "deduped" }
```

For batch publish:

```json
{ "ok": true, "status": "batch", "accepted": 10, "deduped": 3, "rejected": 2 }
```

#### 7.4.3 `error`

Direct error response.

Payload:

```json
{ "code": "bad_request", "message": "<details>" }
```

Known codes used by the hub:
- `bad_request`
- `rate_limited`
- `too_large`
- `id_mismatch`
- `not_found`

#### 7.4.4 `corpus_announce` (broadcast)

Notifies peers that a new entry has been accepted for the campaign.

Payload:

```json
{ "seq": 457, "entry": { ...EntryMeta... } }
```

Peers treat this as an *opportunity* to ingest: they may ignore it due to sampling, rate limits, or pending limits.

#### 7.4.5 `corpus_since` (direct)

Response to `corpus_since_request`.

Payload:

```json
{
  "from_seq": 123,
  "to_seq": 200,
  "entries": [
    { "seq": 124, "entry": { ...EntryMeta... } },
    { "seq": 125, "entry": { ...EntryMeta... } }
  ],
  "truncated": true
}
```

Rules:
- `limit` is clamped by hub to `1..5000`.
- If `truncated=true`, client should request again with `since_seq=to_seq`.

#### 7.4.6 `corpus_entry` (direct)

Response to `corpus_get`.

Payload:

```json
{ "entry": { ...EntryMeta... }, "txs": [ ... ] }
```

#### 7.4.7 `fleet_stop` (broadcast; optional)

If the hub is started with `--broadcast-fleet-stop`, the first time it sees a new `failure_id` it broadcasts:

```json
{
  "reason": "failure",
  "failure_id": "<failure_id>",
  "test_name": "<test_name>"
}
```

Clients with `corpusSync.behavior.stopOnFleetStop=true` will stop their local workers.

## 8. Hub Server Semantics

### 8.1 Campaign state

The hub maintains per-campaign state:
- `entries`: map `entry_id -> EntryMeta` (dedup)
- `index`: append-only list `[(seq, EntryMeta)]` used for resume paging
- `nextSeq`: last used seq (starts at `0`; first accepted entry uses `seq=1`)
- `coverageCount`: number of accepted coverage entries
- `failuresSeen`: set of `failure_id` values seen since hub start (not persisted)
- `conns`: active connections in this campaign

### 8.2 Acceptance / dedup rules

On publish:
1. Hub enforces:
   - max message size (`--max-msg-bytes`)
   - max entry size (`--max-entry-bytes`)
   - optional per-connection publish rate limit (`--max-publishes-per-minute`)
2. Hub recomputes `entry_id = sha256(encode(txs))` and compares to `EntryMeta.entryId`.
3. Dedup:
   - if `entry_id` already exists in campaign, hub acks with `deduped` and does not re-persist/broadcast.
4. Optional cap:
   - if entry is coverage type and `--max-coverage-entries > 0`, hub rejects once cap is hit.
   - reproducers are always accepted (not subject to `maxCoverageEntries`).
     This refers to entries of type `reproducer` published via `corpus_publish` / `corpus_publish_batch`.
     `failure_publish` does not currently insert a corpus entry in v1.

### 8.3 Persistence format

For each campaign `C` in `--data-dir`:

```text
<data-dir>/<campaign>/
  corpus/
    <entry_id>.txt          (JSON array of Tx)
  index.jsonl               (append-only JSONL, one line per accepted entry)
```

The index lines have the form:

```json
{ "seq": 457, "ts": "<hub timestamp>", "entry": { ...EntryMeta... } }
```

Persistence is best-effort:
- payload write is skipped if the file already exists
- index append failure is logged but does not crash the hub

### 8.4 Reload on restart

On startup, hub scans `--data-dir` and loads campaigns with an `index.jsonl`:
- parses JSONL lines
- reconstructs `entries` and `index` in-memory
- sets `nextSeq` to `max(seq)` in that index file
- recomputes `coverageCount` as number of entries whose `entry_type` is `coverage`

### 8.5 Broadcast and backpressure

The hub uses per-connection bounded queues:
- direct queue (not intended to drop)
- broadcast queue (droppable; on overflow, increments `droppedBroadcast` counter)
- get queue for `corpus_get` requests

Priority:
- writer loop uses `orElse` to prefer direct messages over broadcast messages.

Backpressure knobs:
- `--max-inflight-gets` controls get queue capacity and also influences other queue capacities.

### 8.6 GET serving and payload cache

`corpus_get` requests are served asynchronously:
- hub verifies the entry exists in `entries`
- reads `corpus/<entry_id>.txt` and decodes it as JSON
- optional LRU cache by bytes (`--payload-cache-mb`)

### 8.7 Failure publish and fleet-stop broadcast

On `failure_publish`:
- hub acks immediately
- logs the failure
- if `--broadcast-fleet-stop` is enabled and `failure_id` was not already seen since hub start:
  - hub broadcasts `fleet_stop`

Note: `failuresSeen` is not persisted; a hub restart resets the "first time seen" memory.

## 9. Client (Echidna) Semantics

### 9.1 Lifecycle

When `corpusSync.enabled=true`, Echidna starts:
- a campaign event listener that turns local achievements into outbound sync messages
- a connection manager that maintains a WebSocket session and ingests inbound messages

The client allocates:
- a bounded outbound TBQueue (to ensure the campaign cannot stall due to sync)
- several dedup/inflight sets:
  - `publishedIds` to avoid publishing the same entry twice
  - `knownIds` to avoid ingesting the same entry twice
  - `pendingGets` to track in-flight `corpus_get` requests
- `lastSeq` (int) updated from hub announcements and since replies

### 9.2 Publishing behavior

Triggers:
- coverage: on `NewCoverage{transactions}` events (if `publish.coverage=true`)
- failures: on `TestFalsified` events (if `publish.failures=true`)

Publishing constraints:
- entries with empty `txs` are not published
- entries larger than `publish.maxEntryBytes` are not published

Coverage publish rate limiting:
- coverage publishes are limited by a token bucket:
  - `publish.maxPerSecond` and `publish.burst`
- failure publishes are not rate-limited by this client-side mechanism

Batching:
- if hub `welcome.features.supports_batch=true` and `publish.batchSize > 1`,
  client batches multiple coverage publishes into `corpus_publish_batch`.

### 9.3 Ingestion behavior

On `corpus_announce` and `corpus_since` entries, the client evaluates whether to ingest:
- requires `ingest.enabled=true`
- requires `meta.bytes <= publish.maxEntryBytes` (same bound used for local publish)

Entry-type policy:
- `reproducer` entries are always eligible for ingestion (and are fetched with high priority)
- `coverage` entries are subject to:
  - a per-minute token bucket (`ingest.maxPerMinute`)
  - deterministic sampling (`ingest.sampleRate`)
  - inflight cap (`ingest.maxPending`)

Deterministic sampling:
- for coverage entries only
- computes `sha256(encode(instance_id <> ":" <> entry_id))` and maps it to a unit interval
- ingests if `< sampleRate`

This has the effect that, for `sampleRate < 1`, different nodes probabilistically ingest different subsets of coverage entries (reducing redundant bandwidth while still ensuring some fleet-wide propagation).

### 9.4 Payload verification and validation

After `corpus_entry` is received:
1. Verify `entry_id` matches payload: `sha256(encode(txs))`.
2. Enforce size bound.
3. Apply `validate` mode:
   - `none`: accept without checks.
   - `replay` (v1): checks that any relevant `Tx.dst` address is present in the VM's `deployed` contracts set.
   - `execute`: currently same behavior as `replay` (reserved for future stronger validation).

Important: v1 does **not** re-execute the full tx sequence for validation.

### 9.5 Admission to local corpus

If validation passes, the entry is:
- inserted into the in-memory corpus (`env.corpusRef`) with a weight.
- optionally persisted to disk under `corpusDir` if configured.

Weight policy:
- `ingest.weightPolicy` exists, but v1 admission uses `constantWeight` in all cases.

On-disk persistence (current v1 behavior):

```text
<corpusDir>/coverage/<entry_id>.txt
```

### 9.6 Fleet stop behavior

If a client receives `fleet_stop` and `behavior.stopOnFleetStop=true`:
- non-origin nodes stop their workers immediately.
- the origin node (the one that published the failure) delays stopping until shrink is complete.

This prevents losing the final shrunk reproducer due to an eager stop.

## 10. Configuration Surface

### 10.1 Client config keys (YAML)

In Echidna YAML, the relevant subtree is `corpusSync`.

Important keys (see `echidna/lib/Echidna/Types/Config.hs`):
- `enabled: bool`
- `url: ws://... or wss://...`
- `token: string|null`
- `campaignOverride: string|null`
- `publish`:
  - `coverage: bool`
  - `failures: bool`
  - `maxPerSecond: int`
  - `burst: int`
  - `maxEntryBytes: int`
  - `batchSize: int`
- `ingest`:
  - `enabled: bool`
  - `validate: none|replay|execute`
  - `maxPending: int`
  - `maxPerMinute: int`
  - `sampleRate: float (0.0-1.0)`
  - `weightPolicy: constant|local_ncallseqs|hub_score` (v1 admits with constant weight)
  - `constantWeight: int`
- `behavior`:
  - `stopOnFleetStop: bool`
  - `resume: bool`
  - `reconnectBackoffMs: [int]` (optional; defaults exist)

### 10.2 Hub flags

Relevant flags (see `echidna/src/hub/Main.hs`):
- `--host HOST`
- `--port PORT`
- `--data-dir PATH`
- `--token TOKEN` (repeatable)
- `--no-auth`
- `--max-msg-bytes N`
- `--max-entry-bytes N`
- `--broadcast-fleet-stop`
- `--stats-interval-ms N`
- `--stats-file PATH`
- `--payload-cache-mb N`
- `--max-inflight-gets N`
- `--max-publishes-per-minute N`
- `--max-coverage-entries N`

## 11. Testing and Benchmarking Procedure (CorpusMaze)

This section provides a concrete procedure to show that hub-corpus improves:
- bug discovery (time-to-falsification)
- deep coverage convergence

### 11.1 Why CorpusMaze is a good target

`echidna/benchmark/contracts/bench/CorpusMaze.sol` defines:
- a state variable `state` starting at `0`
- a transition function `step(uint256 x)` where advancing from `k` to `k+1` requires `(x & 0xF) == k`
- an invariant `echidna_maze_unsolved()` which returns `state != FINAL_STATE`

The invariant is falsified once the sequence reaches `FINAL_STATE = 16`.

Why this fits hub-corpus:
- reaching deeper states requires accumulating a prefix of "good" calls
- once one node finds a sequence reaching state `k`, that sequence is a valuable seed for mutations that reach `k+1`
- hub-corpus turns every node's partial progress into shared starting points

### 11.2 Baselines to compare (recommended 3-way)

To attribute improvements correctly, compare these modes:

1. **Single-process baseline**
   - 1 Echidna process
   - `TOTAL_WORKERS` workers in the same process
   - no hub
   - represents the best-case "shared memory corpus" setup on one machine

2. **Fleet without sync**
   - `NODES` processes
   - `WORKERS_PER_NODE = floor(TOTAL_WORKERS / NODES)` workers each (min 1)
   - no hub process and no hub connection
   - each node has an isolated corpus (no cross-node sharing of coverage-improving sequences)
   - this isolates the effect of splitting into multiple processes without any cross-learning
   - if you want to measure *time-to-first-failure*, you need external coordination to stop the other nodes when one fails
     (otherwise your "fleet duration" may mostly measure how long the slowest node runs)

3. **Fleet with hub-corpus**
   - same fleet shape as (2)
   - hub process running (`echidna-corpus-hub`)
   - nodes connect over WebSockets and continuously share progress:
     publish new-coverage entries, dedup at hub, announce to peers, peers `corpus_get` and ingest into their local corpus
   - optional failure coordination: hub can broadcast `fleet_stop` on first failure event (useful for time-to-failure benchmarks)
   - hub persists accepted entries and supports client resume after reconnect/restart

Key difference between (2) and (3): both use the same *amount of fuzzing work* (same number of nodes/workers), but
only (3) turns discoveries on one node into immediately usable seeds on other nodes.

To keep (2) vs (3) a fair comparison, hold everything constant except corpus sharing:
- same target (`TARGET_FILE`, `TARGET_CONTRACT`)
- same fuzz settings (`seqLen`, `testLimit`, `timeout`, `testMode`, etc.)
- same total workers and same workers-per-node split
- same seed policy (or at least the same seed distribution scheme)

In practice, the runtime difference should be basically:
- Fleet without sync: do not run the hub; run each node without `--corpus-sync true` (and if your YAML enables corpus sync, force-disable via `--corpus-sync false`).
- Fleet with hub-corpus: run the hub; run each node with `--corpus-sync true --corpus-sync-url ws://.../ws` (and optionally run the hub with `--broadcast-fleet-stop` for time-to-failure benchmarking).

The most informative claim to validate is typically:

```text
fleet_with_hub is faster than fleet_without_sync
```

and ideally approaches:

```text
fleet_with_hub ~= single_process_baseline
```

### 11.3 Functional correctness checks (pre-benchmark)

These scripts already exist and should be run first:
- `echidna/benchmark/scripts/test_corpus_sync_ingest.sh`
  - proves: publisher -> hub -> listener ingestion -> listener persists entries
- `echidna/benchmark/scripts/test_corpus_sync_hub_reload.sh`
  - proves: hub persists `index.jsonl` + payloads and can reload them after restart
- `echidna/benchmark/scripts/test_corpus_sync_stop_on_fleet_stop.sh`
  - proves: failure_publish triggers hub `fleet_stop` broadcast and non-origin nodes stop cleanly

### 11.4 Benchmark A: Time-to-Bug (Time-to-Failure)

Goal:
- Measure how quickly the fleet finds the falsification (maze solved).

#### 11.4.1 Use the existing benchmark runner

There is an existing benchmark script under `echidna/benchmark/scripts`:
- `bench_corpus_3v1.sh`: runs repeated "baseline vs fleet+hub" comparisons and writes a summary JSON.

Example:

```bash
cd echidna/benchmark
REPEATS=10 NODES=3 TOTAL_WORKERS=3 HUB_PORT=9020 BROADCAST_FLEET_STOP=1 ./scripts/bench_corpus_3v1.sh
```

What it measures:
- baseline duration: time for a single process with `TOTAL_WORKERS` to fail
- fleet duration: time for the fleet to fail, with the hub broadcasting `fleet_stop` so other nodes stop quickly

Outputs:
- `out/bench_corpus_3v1_<timestamp>/results.jsonl`
- `out/bench_corpus_3v1_<timestamp>/summary.json`
- per-run logs and per-node `coverage/` and `corpus/` dirs

Interpretation:
- compare `summary.json` median/min values
- for meaningful comparisons, increase `REPEATS` and ensure machine load is stable

#### 11.4.2 Add "fleet without sync" (manual, recommended)

To isolate the hub-corpus effect, replicate the same fleet shape but disable sync:

1. Run `NODES` independent Echidna processes with the same `WORKERS_PER_NODE`.
2. Start a wall-clock timer when all nodes start.
3. Detect the first node to exit with failure (Echidna exit code `1`).
4. Record `t_first_failure`.
5. Terminate the remaining nodes.

This gives a robust estimate of "time to first bug in a fleet that does not share corpus".

### 11.5 Benchmark B: Faster Deep-Coverage Convergence

Goal:
- Show that hub-corpus reaches deeper states (and thus covers deeper branches) faster.

You can measure deep coverage on `CorpusMaze` in two complementary ways:
- **coverage percentage** (from `.lcov`)
- **maze depth reached** (from coverage text output, by checking which state-branches were executed)

#### 11.5.1 Make the target "non-trivial" for coverage benchmarking

If the default benchmark config solves the maze too quickly, reduce slack so differences are measurable:
- lower `seqLen` (fewer total attempts per sequence)
- lower `workers`
- run with a fixed `--timeout` instead of stopping on failure, and set `stopOnFail: false`

The key is to pick parameters such that:
- not all runs reach final state quickly
- coverage increases gradually over time

#### 11.5.2 Recommended run shape (coverage over time)

Run each mode for a fixed timeout `T` seconds, and request periodic coverage snapshots:
- use `--timeout T` (seconds)
- use `--save-every M` (minutes) to write periodic coverage outputs during the run

Example (5 minutes total with 1-minute snapshots):

```bash
cd echidna/benchmark

# Baseline (single process):
mkdir -p out/cov_baseline
../result/bin/echidna contracts/bench/CorpusMaze.sol \
  --contract CorpusMaze \
  --config echidna/bench.single.yaml \
  --workers 4 \
  --timeout 300 \
  --save-every 1 \
  --test-mode exploration \
  --corpus-dir out/cov_baseline/corpus \
  --coverage-dir out/cov_baseline/coverage

# Fleet with hub-corpus (manual so we can also use exploration + snapshots):
mkdir -p out/cov_fleet_hub
../result/bin/echidna-corpus-hub --host 127.0.0.1 --port 9030 --data-dir out/cov_fleet_hub/hub_data --no-auth --stats-interval-ms 2000 --stats-file out/cov_fleet_hub/hub_stats.json &
HUB_PID="$!"
sleep 0.5

PIDS=()
for i in $(seq 1 4); do
  mkdir -p out/cov_fleet_hub/node_${i}
  ../result/bin/echidna contracts/bench/CorpusMaze.sol \
    --contract CorpusMaze \
    --config echidna/bench.fleet.yaml \
    --workers 1 \
    --timeout 300 \
    --save-every 1 \
    --test-mode exploration \
    --corpus-dir out/cov_fleet_hub/node_${i}/corpus \
    --coverage-dir out/cov_fleet_hub/node_${i}/coverage \
    --corpus-sync true \
    --corpus-sync-url "ws://127.0.0.1:9030/ws" \
    >out/cov_fleet_hub/node_${i}/out.log 2>out/cov_fleet_hub/node_${i}/err.log &
  PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do
  wait "${pid}"
done
kill "${HUB_PID}" >/dev/null 2>&1 || true
```

Notes:
- `run_fleet_local.sh` is a convenience runner for a hub + local fleet; it uses `bench.fleet.yaml` which enables corpus sync.
- For the "fleet without sync" mode, run multiple processes like `run_fleet_local.sh` but omit the `--corpus-sync` flags and use a config without `corpusSync` enabled.

#### 11.5.3 Extract metric 1: coverage percent from LCOV

Each node writes coverage snapshots as:

```text
<coverageDir>/covered.<timestamp>.lcov
```

Compute per-snapshot line coverage for `CorpusMaze.sol` by parsing `DA:<line>,<hits>` entries in LCOV.

Suggested reporting:
- for baseline: one time series
- for fleet modes: take the max/median across nodes at each snapshot timestamp (or normalize by nearest snapshot time)

#### 11.5.4 Extract metric 2: "maze depth" from coverage text output

Coverage text snapshots have the form:

```text
<coverageDir>/covered.<timestamp>.txt
```

These show each source line with a marker (e.g., `*`) indicating covered lines.

For `CorpusMaze`, deep state corresponds to covering the `else if (state == k)` ladder.

Define:
- `depth = max k such that the branch for state k was executed at least once`

This can be extracted by scanning for lines that match:

```text
else if (state == <k>)
```

and checking whether that line is marked covered.

This "depth" is a very direct proxy for deep coverage convergence on this benchmark.

#### 11.5.5 Expected outcome

Typical expectation on this benchmark:
- `fleet_without_sync` has slower depth growth and high run-to-run variance (each node re-discovers the same shallow prefixes).
- `fleet_with_hub` accumulates deep prefixes faster because discoveries are shared, so depth increases more steadily and earlier.
- `single_process_baseline` is usually strong, but `fleet_with_hub` should approach it even when distributed across processes/machines.

### 11.6 What to log / archive for analysis

For each run (per mode), archive:
- command line and config used
- Echidna exit code
- wall-clock duration (time-to-failure or full timeout)
- output directories:
  - `corpus/` contents and size
  - `coverage/covered.*.lcov` and `.txt`
- for hub runs:
  - hub `--stats-file` snapshots (JSON)
  - hub logs (`hub.log`)
  - hub persisted data (`hub_data/<campaign>/...`)

For hub runs, the hub `index.jsonl` is also useful as a record of:
- accepted entries over time (with seq numbers)
- origin metadata and hints (`coverage_points_total`, etc.)
