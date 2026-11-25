# attn core (format, desktop daemon, archive) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new private repo `attn` holding the frame-log format (`spec/` + golden vectors), the shared Effect schemas, the desktop `attn-daemon` (ingest-only ActivityWatch API → heartbeat merge with checkpoints → signed, age-encrypted frame log → append-only upload), the Alchemy stack for the raw bucket, and the Nix package + NixOS module for the daemon. Everything is tested against synthetic data; no brain, no real data.

**Architecture:** Bun workspace with Effect v4 services and layers (`Journal`, `Sealer`, `Signer`, `Sink`, `Ingest`, `AwApi`, `Uploader`), wired only in `packages/daemon/src/main.ts`. The format is defined once in `packages/model` and pinned by golden vectors in `spec/vectors/`, which the Kotlin writer (a later plan) must also pass. The Alchemy stack lives in `packages/infra`, laid out like routelab's `infra/stack`.

**Tech Stack:** Bun 1.3.x (nixpkgs), `effect` 4.1.5 + `@effect/platform-bun` 4.1.5 (exact pins), `age-encryption` 0.3.1, `ulid` 3.0.2, `alchemy` + `@alchemy.run/aws` 2.0.0-beta.87, `@distilled.cloud/aws` 1.0.0-rc.20, bun2nix, flake-parts.

**Spec:** `docs/plans/2026-11-25-attention-tracker-design.md` in nixconf (with the review `2026-11-25-attention-tracker-review.md` §d, §e, §g). Copy both into the new repo's `docs/` in Task 1.

**Scope.** This is plan 1 of the split. Later plans: (2) nixconf P0 security prerequisites (move the sops primary key off agent hosts, `ptrace_scope`, agent deny rules); (3) `attn-sensor` (media-aware idle, T3, git, cwd); (4) the brain + PWA M0 (pull, verify, encrypted DuckDB, rules, rollups, passkeys, review); (5) nixconf integration (awatcher, aw-watcher-web policy, device enrolment, deploy); (6) Pollen tracker module (M1). The peacelily bring-up has its own plan.

## Global Constraints

- Repo at `~/work/personal/attn`, **private**; no real tracking data, keys, hostnames or personal rules in any commit. Tests and vectors use synthetic data and test-only keys.
- No plaintext tracking data at rest: the daemon writes only age ciphertext to disk; it holds **public** recipients only and never decrypts.
- Recipients are X25519 age recipients (`age1…`, generated with `generateX25519Identity`), not hybrid, so the Kotlin writer can match.
- Signatures: ECDSA P-256 / SHA-256 (`effect/crypto/Signature` `ecdsaP256`).
- Every Effect package pinned exactly: `effect@4.1.5`, `@effect/platform-bun@4.1.5`. Imports of unstable modules (`effect/http-api`, `effect/http`, `effect/crypto`) live in as few files as possible.
- Runtime is Bun only; tests run with `bun test`.
- AW API on `127.0.0.1:5600`, ingest-only: no `/export`, no event `GET`s, no `/query`.
- Uploads always send `If-None-Match: *`; a 412 means "already there" and counts as success.
- Seal a segment at **15 min**, **1 MiB**, on shutdown or SIGTERM. Flush a frame every **5 s** when records are pending. Checkpoint open events every **60 s**.
- Object key: `raw/<device_id>/<YYYY-MM-DD UTC seal date>/<bucket_id>/<seq>.attn`, sidecar at the same key + `.sig.json`.
- Agents never run `alchemy deploy`; the owner deploys. `alchemy plan` is allowed only with the owner's credentials in their own shell.

## Review Focus

1. **A watcher sends events out of order or with a timestamp in the future** (awatcher after suspend, clock jumps): the merge must not produce negative durations or extend a closed span backwards; an out-of-order event opens a new span. → test in Task 6.
2. **The process is killed mid-frame** (OOM, power loss): on restart the partial trailing frame is cut off, earlier frames survive, the segment still seals and uploads. → test in Task 5.
3. **The upload fails halfway** (network drops after the segment PUT, before the sidecar PUT): the retry must re-send both, and a 412 on the segment must not stop the sidecar from going up. → test in Task 8.
4. **A hostile or buggy local process floods the API** (thousands of buckets or events per second): limits answer 429 and the queue stays bounded. → test in Task 7.
5. **The device is offline for days**: sealed segments accumulate, `seq` keeps increasing across restarts, nothing is deleted before a confirmed upload. → test in Task 9.

---

### Task 1: Repository, flake and workspace

**Files:**
- Create: `~/work/personal/attn/{flake.nix,package.json,bunfig.toml,tsconfig.base.json,.gitignore,README.md,LICENSE}`
- Create: `packages/model/{package.json,tsconfig.json,src/index.ts}`, `packages/model/test/smoke.test.ts`
- Create: `docs/design.md`, `docs/review.md` (copies of the nixconf design and review)

**Interfaces:**
- Produces: workspace `@attn/model`; `nix develop` shell with `bun`, `age`, `awscli2`, `jq`; `nix flake check` runs `bun test` and `tsc --noEmit`.

- [ ] **Step 1:** `git init` at `~/work/personal/attn`; LICENSE Apache-2.0 (unpublished until M5); `.gitignore` covers `node_modules`, `.alchemy/`, `state/`, `*.attn` outside `spec/vectors/`.
- [ ] **Step 2:** `flake.nix` with flake-parts (systems `x86_64-linux`), `devShells.default` (bun, age, awscli2, jq, typescript), `formatter` alejandra; nixpkgs input pinned to the same branch as nixconf (`nixos-26.05`).
- [ ] **Step 3:** root `package.json` with `"workspaces": ["packages/*"]`, scripts `test` (`bun test`), `typecheck` (`tsc -b`); `tsconfig.base.json` strict, `"module": "preserve"`, `"moduleResolution": "bundler"`, `"types": ["bun-types"]`, `"exactOptionalPropertyTypes": true`.
- [ ] **Step 4:** smoke test `packages/model/test/smoke.test.ts`: `expect(Effect.runSync(Effect.succeed(1))).toBe(1)`.
- [ ] **Step 5:** run `nix develop -c bun install && nix develop -c bun test` → 1 pass; `nix develop -c bun run typecheck` → no errors.
- [ ] **Step 6:** commit `chore: scaffold attn workspace`.

### Task 2: Model schemas

**Files:**
- Create: `packages/model/src/{AwEvent.ts,Bucket.ts,Record.ts,Sidecar.ts,Ids.ts,index.ts}`
- Test: `packages/model/test/schemas.test.ts`

**Interfaces:**
- Produces:
  - `AwEvent = Schema.Struct({ timestamp: Schema.String /* ISO 8601 UTC */, duration: Schema.Number /* ≥ 0 */, data: Schema.Record(Schema.String, Schema.Unknown) })`
  - `Bucket = Schema.Struct({ id, type, client, hostname, created })` (all strings)
  - `AttnRecord = Schema.Struct({ id: Ulid, bucket_id: Schema.String, timestamp, duration, data, open: Schema.Boolean })` — one NDJSON line
  - `Sidecar = Schema.Struct({ format_version: Schema.Literal(1), device_id: DeviceId, bucket_id, seq: Schema.Int /* ≥ 0 */, frame_count: Schema.Int, sha256: Schema.String /* hex */, alg: Schema.Literal("ES256"), sig: Schema.String /* base64 */, tz: Schema.String /* IANA */, sealed_at: Schema.String })`
  - `Ulid`, `DeviceId` (UUID v4) as branded strings; `newUlid(): Effect<Ulid>` using `ulid`'s `monotonicFactory` seeded from `Clock.currentTimeMillis`.

- [ ] **Step 1: failing tests** — `AwEvent` decodes `{timestamp:"2026-11-25T10:00:00Z",duration:0,data:{app:"x"}}`; rejects `duration:-1`; `AttnRecord` round-trips through `Schema.encode`/`decode`; `Sidecar` rejects `alg:"ES384"`; `newUlid` under `TestClock` at t=1000 returns ids that sort increasingly across 3 calls.
- [ ] **Step 2:** run `bun test packages/model` → fails (modules missing).
- [ ] **Step 3:** implement the schemas above.
- [ ] **Step 4:** run → pass.
- [ ] **Step 5:** commit `feat(model): AW event, record and sidecar schemas`.

### Task 3: Frame codec

**Files:**
- Create: `packages/model/src/Frame.ts`
- Test: `packages/model/test/frame.test.ts`

**Interfaces:**
- Consumes: `AttnRecord` (Task 2).
- Produces:
  - `encodeFrame(records: ReadonlyArray<AttnRecord>, recipients: ReadonlyArray<string>): Effect<Uint8Array, FrameError>` — plaintext = zstd(`{"format_version":1,"kind":"ndjson"}\n` + one JSON line per record); age-encrypt to all recipients; output `[u32 big-endian length][age bytes]`.
  - `encodePcmFrame(pcm: Uint8Array, meta, recipients)` — same envelope, header `{"format_version":1,"kind":"pcm_s16le","sample_rate":16000,"channels":1}`; declared now so the Kotlin writer and the brain share one header vocabulary.
  - `splitSegment(bytes: Uint8Array): { frames: ReadonlyArray<Uint8Array>; truncatedTail: boolean }` — length framing only, no decryption (the daemon uses this for recovery).
  - `decodeFrame(frame: Uint8Array, identities: ReadonlyArray<string>): Effect<{ header; records: ReadonlyArray<AttnRecord> }, FrameError>` (used by tests now, the brain later).
  - `FrameError` tagged error with `reason: "Truncated" | "Decrypt" | "Header" | "Decode"`.

- [ ] **Step 1: failing tests** — round trip 3 records through `encodeFrame`/`splitSegment`/`decodeFrame` with a test identity; two frames concatenated split into 2; a segment with the last frame cut by 10 bytes gives `frames.length === 1, truncatedTail: true`; decoding with a wrong identity fails with `reason: "Decrypt"`; ciphertext contains no plaintext substring of a record's `data.title`.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** implement with `age-encryption` (`Encrypter.addRecipient`, `encrypt(Uint8Array)`), `Bun.zstdCompressSync`/`zstdDecompressSync`.
- [ ] **Step 4:** run → pass.
- [ ] **Step 5:** commit `feat(model): age frame codec`.

### Task 4: Signing, sidecar and golden vectors

**Files:**
- Create: `packages/model/src/Seal.ts`, `spec/FORMAT.md`, `spec/vectors/` (generated), `scripts/gen-vectors.ts`
- Test: `packages/model/test/seal.test.ts`, `packages/model/test/conformance.test.ts`

**Interfaces:**
- Consumes: `Sidecar`, frame codec.
- Produces:
  - `signSegment(segment: Uint8Array, key: Signature.PrivateKey, meta: Omit<Sidecar,"sha256"|"sig"|"alg"|"format_version"|"frame_count">): Effect<Sidecar>` — sha256 over the whole segment, ES256 signature over the 32-byte digest, `frame_count` from `splitSegment`.
  - `verifySegment(segment: Uint8Array, sidecar: Sidecar, key: Signature.PublicKey): Effect<void, SealError>` with `reason: "Hash" | "Signature" | "FrameCount"`.
  - `objectKey(sidecar: Sidecar): string` → `raw/<device_id>/<sealed_at UTC date>/<bucket_id>/<seq>.attn`.
  - `spec/vectors/`: `identity.txt` (test-only age identity), `signing.pub` (SEC1 hex), `ok.attn` + `ok.sig.json` (2 frames), `truncated.attn`, `badsig.sig.json`, `expected.ndjson` (decoded records).

- [ ] **Step 1: failing tests** — sign/verify round trip; flipping one byte gives `reason: "Hash"`; a sidecar signed by another key gives `"Signature"`; `objectKey` for `sealed_at:"2026-11-25T23:59:59Z"` is dated `2026-11-25`. Conformance: `ok.attn` verifies with `signing.pub`, decodes with `identity.txt` to exactly `expected.ndjson`; `truncated.attn` yields 1 frame and `truncatedTail`; `badsig.sig.json` fails with `"Signature"`.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** implement `Seal.ts`; write `scripts/gen-vectors.ts` (`bun run scripts/gen-vectors.ts` writes `spec/vectors/`, deterministic records, fresh test keys); write `spec/FORMAT.md` describing frame layout, headers, sidecar fields, key layout, checkpoint semantics (last record per `(device, bucket, id)` by `(seq, frame, line)` wins), the primary-device tie-break (attention state, then input activity).
- [ ] **Step 4:** generate vectors once, commit them; run tests → pass.
- [ ] **Step 5:** commit `feat(model): signed sidecar, FORMAT.md and golden vectors`.

### Task 5: Journal (encrypted frame log on disk)

**Files:**
- Create: `packages/daemon/{package.json,tsconfig.json}`, `packages/daemon/src/Journal.ts`, `packages/daemon/src/Bookkeeping.ts`
- Test: `packages/daemon/test/journal.test.ts`

**Interfaces:**
- Consumes: `encodeFrame`, `splitSegment`, `signSegment`.
- Produces: `class Journal extends Context.Service<Journal, { append(bucketId: string, records: ReadonlyArray<AttnRecord>): Effect<void, JournalError>; sealDue(now: Date): Effect<ReadonlyArray<SealedSegment>>; sealAll: Effect<ReadonlyArray<SealedSegment>>; sealed: Effect<ReadonlyArray<SealedSegment>>; remove(s: SealedSegment): Effect<void> }>`, `SealedSegment = { path: string; sidecar: Sidecar }`, `Journal.layer(config: { stateDir: string; deviceId: DeviceId; recipients: ReadonlyArray<string>; signingKey: Signature.PrivateKey; tz: string })`.
- On disk (`stateDir`): `open/<bucket_id>.seg` (one open segment per bucket), `sealed/<bucket_id>/<seq>.attn` + `.sig.json`, `bookkeeping.json` `{ nextSeq: Record<bucketId, number> }` written atomically (tmp + rename). Every append `fdatasync`s.

- [ ] **Step 1: failing tests** (temp dir per test) — append 2 frames then `sealAll` gives one sealed segment that verifies and decodes to the 2 frames' records; `sealDue` seals a segment opened 15 min ago (via `TestClock`) and not one opened 14 min ago; a segment over 1 MiB seals on the next append; **crash recovery**: write a segment, append 7 garbage bytes to it, reopen the layer → the open segment is truncated to its last whole frame, seals, and verifies; `seq` survives a layer restart (seal, restart, seal → seq 0 then 1); no file under `stateDir` contains a record's plaintext `title`.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** implement; on layer start, for each `open/*.seg`, `splitSegment` and truncate to the last whole frame.
- [ ] **Step 4:** run → pass.
- [ ] **Step 5:** commit `feat(daemon): encrypted journal with crash recovery`.

### Task 6: Ingest (heartbeat merge and checkpoints)

**Files:**
- Create: `packages/daemon/src/Ingest.ts`
- Test: `packages/daemon/test/ingest.test.ts`

**Interfaces:**
- Consumes: `Journal.append`, `newUlid`.
- Produces: `class Ingest extends Context.Service<Ingest, { heartbeat(bucketId: string, ev: AwEvent, pulsetime: number): Effect<void>; insert(bucketId: string, evs: ReadonlyArray<AwEvent>): Effect<void>; flush: Effect<void>; checkpoint: Effect<void>; closeAll: Effect<void> }>`; `Ingest.layer` with a background fiber that runs `flush` every 5 s and `checkpoint` every 60 s (`Schedule.spaced`).
- Merge rule (aw-server's): with an open event `last` for the bucket, if `deepEqual(ev.data, last.data)` and `last.start ≤ ev.start ≤ last.end + pulsetime`, set `last.end = max(last.end, ev.start + ev.duration)`; otherwise close `last` (emit `open:false`) and open `ev` with a new ULID. An event with `ev.start < last.start` closes `last` and opens a new span (no backwards extension). Durations are never negative.
- Records go to an in-memory pending list per bucket; `flush` writes one frame per bucket via `Journal.append`. `checkpoint` adds the open event of each bucket to pending with `open:true` and its current duration.

- [ ] **Step 1: failing tests** (`TestClock`, a `MemoryJournal` test layer that captures appended records) — 3 heartbeats with the same data 10 s apart, `pulsetime 15` → one span, duration 20 s, still open; a heartbeat with different data closes the first (`open:false`) and opens a second with a new id; a gap larger than `pulsetime` opens a new span; **out-of-order**: a heartbeat timestamped before the open span's start opens a new span and leaves the first's duration unchanged; after 60 s a checkpoint record with the same id, `open:true`, and current duration is appended; `insert` writes closed records as-is; `closeAll` closes every open span.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run → pass.
- [ ] **Step 5:** commit `feat(daemon): heartbeat merge with checkpoints`.

### Task 7: Ingest-only AW API

**Files:**
- Create: `packages/daemon/src/AwApi.ts`, `packages/daemon/src/Limits.ts`
- Test: `packages/daemon/test/awapi.test.ts`

**Interfaces:**
- Consumes: `Ingest`.
- Produces: an `HttpApi` (`effect/http-api`) group `aw` and its handlers layer `AwApiLive`, served by `BunHttpServer` on `127.0.0.1:5600` in Task 9:
  - `GET /api/0/info` → `{ hostname, version: "attn-<version>", testing: false, device_id }`
  - `GET /api/0/buckets/` → `Record<id, Bucket>` (metadata only); `GET /api/0/buckets/:id` → `Bucket` or 404
  - `POST /api/0/buckets/:id` (body `Bucket` fields) → 200; existing id → 304, like aw-server
  - `POST /api/0/buckets/:id/events` (body `AwEvent | AwEvent[]`) → 200
  - `POST /api/0/buckets/:id/heartbeat?pulsetime=<s>` (body `AwEvent`) → 200
  - Everything else, including `GET …/events` and `/api/0/export`, → 404.
- Bucket metadata is not tracking data: kept in `stateDir/buckets.json`.
- `Limits`: per-bucket 600 requests/min, max 64 buckets; over → 429. Origin: requests with an `Origin` header are accepted only from `chrome-extension://<allowedExtensionIds>` (config; default `["nglaklhklhcoonedhgnpgddginnjdadi"]`); requests without `Origin` need `Authorization: Bearer <watcherToken>` **unless** `allowUnauthenticatedLocal` is set (default `true` in M0 so awatcher works; the token mechanism per watcher is the builder's call within this rule, recorded in `docs/`).

- [ ] **Step 1: failing tests** (in-process server via `HttpApiTest`/`HttpApiBuilder` test helpers with a capturing `Ingest` layer) — create bucket → 200, again → 304; heartbeat reaches `Ingest.heartbeat` with `pulsetime`; `GET /api/0/buckets/x/events` → 404; `GET /api/0/export` → 404; `Origin: https://evil.example` → 403; 601st heartbeat in a minute → 429; creating a 65th bucket → 429.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run → pass.
- [ ] **Step 5:** commit `feat(daemon): ingest-only ActivityWatch API`.

### Task 8: Sink and uploader

**Files:**
- Create: `packages/daemon/src/Sink.ts`, `packages/daemon/src/Uploader.ts`, `packages/daemon/src/NetworkPolicy.ts`
- Test: `packages/daemon/test/uploader.test.ts`

**Interfaces:**
- Consumes: `Journal.sealed`, `Journal.remove`, `objectKey`.
- Produces:
  - `class Sink extends Context.Service<Sink, { put(key: string, body: Uint8Array, contentType: string): Effect<"created" | "exists", SinkError> }>`; layers `Sink.memory` (test; exposes `objects`), `Sink.dir(root)` (`fs.open(…, "wx")`), `Sink.s3({ bucket, region, credentials })` via `@distilled.cloud/aws` `PutObject` with `IfNoneMatch: "*"` (412 → `"exists"`).
  - `class NetworkPolicy extends Context.Service<NetworkPolicy, { metered: Effect<boolean> }>`; `NetworkPolicy.agentNet` runs `agent-net --json` if present (fallback `false`), `NetworkPolicy.fixed(b)` for tests.
  - `Uploader.run: Effect<void, never, Journal | Sink | NetworkPolicy>` — for each sealed segment, oldest first: skip if metered and size > 64 KiB; put segment, then sidecar (`key + ".sig.json"`); `remove` only after both are `created|exists`; retry with `Schedule.exponential("2 seconds")` capped at 5 min.

- [ ] **Step 1: failing tests** — two sealed segments upload in order to `Sink.memory` and are removed locally; a sink that fails the sidecar PUT once: segment stays local, the retry gets `"exists"` for the segment and `"created"` for the sidecar, then removes; metered policy holds a 100 KiB segment and sends a 10 KiB one; `Sink.dir` returns `"exists"` on a second put of the same key.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run → pass.
- [ ] **Step 5:** commit `feat(daemon): append-only uploader`.

### Task 9: Daemon main, config and `attn status`

**Files:**
- Create: `packages/daemon/src/{Config.ts,main.ts,status.ts}`, `packages/daemon/bin/attn.ts`
- Test: `packages/daemon/test/e2e.test.ts`

**Interfaces:**
- Consumes: all daemon services.
- Produces:
  - `DaemonConfig` read with `effect/Config` from env: `ATTN_STATE_DIR`, `ATTN_DEVICE_ID`, `ATTN_RECIPIENTS` (comma-separated `age1…`), `ATTN_SIGNING_KEY_FILE` (PKCS#8 DER), `ATTN_SINK` (`s3://bucket` | `dir:///path`), `ATTN_AWS_REGION` (default `eu-central-1`), `ATTN_LISTEN` (default `127.0.0.1:5600`), `ATTN_TZ` (default `Africa/Cairo`), secrets as `Redacted`.
  - `bin/attn.ts` commands: `attn daemon` (runs `main` with `BunRuntime.runMain`; on SIGTERM: `Ingest.closeAll` → flush → `Journal.sealAll` → one upload pass), `attn status` (queue depth, oldest sealed segment age, last upload time from `bookkeeping.json`; no tracking data), `attn keygen` (writes a P-256 PKCS#8 key with mode 0600 and prints the public SEC1 hex).

- [ ] **Step 1: failing e2e test** — start the daemon layer graph with `Sink.dir(tmp)`, `TestClock`, test recipients and signing key; POST a bucket and 5 heartbeats over HTTP; advance 15 min; the dir contains one `.attn` and its `.sig.json` at the expected key; it verifies with the public key and decodes (test identity) to one record of the merged span (the last checkpoint or closed record wins); **offline**: with a sink that always fails, three seals over 45 min leave three local segments with seq 0, 1, 2, and a restart keeps them and continues at seq 3; `attn status` output contains no record field values.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run → pass.
- [ ] **Step 5:** commit `feat(daemon): main, config and status CLI`.

### Task 10: Alchemy stack for the archive

**Files:**
- Create: `packages/infra/{package.json,alchemy.run.ts,src/policies.ts,src/devices.ts,README.md}`
- Test: `packages/infra/test/policies.test.ts`

**Interfaces:**
- Produces:
  - `rawBucketPolicy(bucketArn: string, ownerRoleArns: ReadonlyArray<string>): PolicyStatement[]` — deny `s3:DeleteObject`, `s3:DeleteObjectVersion`, `s3:PutBucketVersioning`, `s3:PutObjectRetention` for everyone; deny any `s3:PutObject` without TLS.
  - `devicePolicy(bucketArn: string, deviceId: DeviceId): PolicyDocument` — allow only `s3:PutObject` on `${bucketArn}/raw/${deviceId}/*`.
  - `brainPolicy(bucketArn: string): PolicyDocument` — `s3:ListBucket` on the bucket, `s3:GetObject` on `raw/*`, `s3:PutObject` on `raw/brain/*`.
  - `alchemy.run.ts`: `AWS.S3.Bucket("Raw", { objectLockEnabled: true, versioning: "Enabled", objectLockConfiguration: { mode: "GOVERNANCE", years: 10 }, publicAccessBlock all true, policy: rawBucketPolicy(...) })`; one `AWS.IAM.User` + inline policy + `AWS.IAM.AccessKey` per entry of `devices.ts` (a list of `{ name, deviceId }`, empty in git; real ids come from an env file the owner keeps outside the repo); a `brain` user with `brainPolicy`. State `AWS.state()` as routelab does; stage `prod`; region `eu-central-1`.
- [ ] **Step 1: failing tests** — `devicePolicy` resource is exactly `arn:aws:s3:::b/raw/<id>/*` and has no `GetObject`/`ListBucket`; `rawBucketPolicy` denies `DeleteObject` with `Principal: "*"`; `brainPolicy` cannot `DeleteObject`.
- [ ] **Step 2:** run → fail.
- [ ] **Step 3:** implement; README gives the owner's commands (`alchemy plan --stage prod`, `alchemy deploy --stage prod`) and the rekey runbook outline from the design §6.
- [ ] **Step 4:** run tests → pass; `bun run typecheck` → clean. (No plan/deploy by agents.)
- [ ] **Step 5:** commit `feat(infra): raw archive bucket and scoped IAM`.

### Task 11: Nix package and NixOS module

**Files:**
- Create: `nix/package.nix`, `nix/modules/device.nix`, `bun.nix` (generated by bun2nix), `nix/checks.nix`
- Modify: `flake.nix`

**Interfaces:**
- Produces: `packages.x86_64-linux.attn` (the `attn` CLI via bun2nix `writeBunApplication` or `mkBunDerivation`); `nixosModules.device` with options `services.attn.device = { enable; deviceId; recipients; sink; signingKeyFile; awsCredentialsFile; listen ? "127.0.0.1:5600"; tz ? "Africa/Cairo"; }`; `checks.x86_64-linux.{tests,typecheck,module-eval}`.
- The module creates system user/group `attn`, `systemd.services.attn-daemon` (`User=attn`, `StateDirectory=attn`, `ProtectHome=yes`, `PrivateTmp=yes`, `NoNewPrivileges=yes`, `LimitCORE=0`, `ProtectSystem=strict`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `EnvironmentFile=` the credentials file), `ExecStartPre` runs `attn keygen` once if the key file is missing.

- [ ] **Step 1:** add bun2nix input; generate `bun.nix`; write `nix/package.nix`.
- [ ] **Step 2:** `checks.module-eval`: evaluate a minimal `nixosSystem` importing `nixosModules.device` with test values and assert `config.systemd.services.attn-daemon.serviceConfig.User == "attn"` and `ProtectHome == true`.
- [ ] **Step 3:** `checks.tests` runs `bun test` in the sandbox against the bun2nix deps; `checks.typecheck` runs `tsc -b`.
- [ ] **Step 4:** run `nix flake check` → all pass; `nix build .#attn && ./result/bin/attn --help` lists `daemon`, `status`, `keygen`.
- [ ] **Step 5:** commit `feat(nix): attn package and device module`.

---

## Self-review notes

- Spec coverage for this plan's scope: frame log (T3–T5), checkpoints and merge (T6), ingest-only API with Origin/token/limits (T7), If-None-Match uploads and metered policy (T8), signing and enrolment-ready keys (T4, T9 `keygen`), Object Lock + no-delete + scoped IAM (T10), system-user daemon (T11). Sensor, brain, PWA, Pollen, nixconf P0 and integration are later plans (listed in Scope).
- Not here on purpose: enrolment CLI (`attn device enrol`) belongs with the brain (it is the registrar); the rekey tool belongs with the brain plan; both are outlined in the infra README.
