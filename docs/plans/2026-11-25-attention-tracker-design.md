# Attention tracker: design (2026-11-25)

Status: **approved by the owner 2026-11-25**; next step is the implementation plan.
Working name **attn** (the owner names it later).

Companion documents (where they disagree with this one, this one wins):
- Research record: [`2026-11-25-attention-tracker-research.md`](2026-11-25-attention-tracker-research.md) (*R §n*)
- Expert review of the first draft: [`2026-11-25-attention-tracker-review.md`](2026-11-25-attention-tracker-review.md) (*V §n*); all its edits and the owner's answers are folded in below.

## 1. Intent

A personal attention tracker that answers *what do I actually mostly do, against what I really
want to do*. It is not a timesheet: nothing is exported to an employer (Clockify is gone).
ActivityWatch collected well but never produced insight or a readable report. This one is
built around a weekly loop, and the time data is evidence for that loop, not the product.

**The weekly loop** (Egyptian work week, Sunday to Thursday; Friday off; the review and
lookahead days are settings, because the week sometimes shifts):

1. **Saturday: lookahead.** Set the week's intentions per area/project (and the kind of week:
   more reading, fewer late nights), seeded from the last review's projection.
2. **Sunday to Thursday: the streams.**
   - *Tracked*: time by business area, project, repository, project aspect (routelab:
     mobile app / dashboard / devops-servers-deploys), device and activity; non-work too
     (YouTube by channel, articles by domain, Reddit by subreddit, phone apps), and time in
     T3/IDE apps themselves.
   - *Lived*: an evening voice check-in: how the day felt, where he worked (home, office,
     café), what he saw, who he met, energising or draining, early or late.
   - *Where*: location history.
   - *Done*: outcome evidence: commits he authored (with agents or not), merged branches,
     finished T3 threads.
3. **Thursday end of day: review.** An agent drafts a review that correlates the intentions
   and how they turned out with **all** the data of the week, on two axes: *time* (did the
   hours go where intended) and *change* (did the intended things actually change). It ends
   with a projection: a proposed intention list for next week.
4. The Saturday lookahead starts from that projection.

Well-being is the point: a good week is one where he did what he set out to do in a way that
felt good.

## 2. Goals, non-goals, anti-goals

**Goals**
- Live one full weekly loop as early as possible (M0), then grow without rework.
- Know what he is doing in each application, using whatever it exposes (T3's store, browser
  URLs, editor files, shell cwd, git).
- Smart idle: a video playing, or an agent working while he watches, is not "away".
- Chat with the data and read reports **from the phone**.
- Agentic: an MCP server and an HTTP API over the data.
- Cheap to run, nothing to babysit.
- Publishable as an open-source project; ActivityWatch-compatible.

**Non-goals**
- Employer timesheets, billing, Clockify/Kimai export.
- iOS, macOS, Windows. Android and NixOS Linux only.
- The second brain / media inbox: a separate project; this one exposes a seam (§5.10).
- Screenshots, screen recording, keystroke logging.
- Following ActivityWatch's development: we speak its format and ingest API; we do not run
  its server or depend on its releases.

**Anti-goals** (failure even if it works)
- Any commercial model touching the data (§3).
- Plaintext tracking data on any disk (§3).
- Reviews built on silent collection gaps.
- A tool that needs attention to keep running.
- Data loss when a device is offline or the brain is down.

## 3. Constraints (non-negotiable)

1. **Model boundary.** No commercial model (Anthropic, OpenAI, Google, ...) ever processes the
   data: raw events, check-ins, location, outcomes, summaries, reviews, chat. Open-weight
   models only, run on hardware the owner controls. Consequences: no chat through Claude
   Code, T3 or OpenCode; agent sessions that *build* attn never read real data; the boundary
   travels with the data into any future project (the inbox seam included).
2. **No plaintext at rest, anywhere.** Plaintext tracking data exists only in process memory.
   **The application encrypts regardless of disk encryption** (LUKS on the laptops and
   Android's file-based encryption do not count). Covers device queues, the phone, S3, the
   brain's database, audio, caches, the PWA's offline cache, chat history, logs, core dumps,
   temp files and swap.
3. **Key custody.** No secret that decrypts or signs tracking data is ever readable by the
   owner's Unix user on a host where agents run, and the sops primary key is never such a
   secret's recipient (V B1).
4. **Capture never depends on the network or the brain.** Every collector queues locally,
   encrypted, for as long as needed.
5. **Stack**: Effect v4 on **Bun** for all TypeScript, pinned exactly (with
   `@effect/platform-bun` and `@effect/ai-openai`); Alchemy v2 for AWS, laid out like routelab's
   `infra/stack`; Kotlin on Android. No Rust, no Node.
6. **Personal AWS account**, eu-central-1, via the owner's AWS SSO setup
   (`2026-11-17-aws-sso-runbook.md`).
7. **Raw is kept forever**, immutable: versioning + Object Lock, and the owner's everyday role
   cannot delete it.
8. **Hosts**: hazel (laptop, 256 GB, no big builds), butternut (desk, always on, agent host),
   peacelily (headless RTX 5060 Ti 16 GB, *not yet redeployed*, slated to become an agent host
   too), phone (Xiaomi, Android). Nix builds everything except the Android app (Gradle).
9. The repo is private until M5; nothing personal (rules, keys, hostnames, real data) is ever
   committed to it or to nixconf.

## 4. Approaches

Storage and sync (decided 2026-11-24):

| | Approach | Trade-off | Verdict |
|---|---|---|---|
| A | ActivityWatch collects, we build the brain on top | fastest start; inherits AW's cadence and weak sync | rejected: owner won't follow AW's development |
| B | **Signed, encrypted, append-only frame logs in S3**; devices queue locally; one brain pulls | no server; any language writes it; merge = listing; minutes of lag | **chosen** |
| C | Effect `eventlog` + encrypted sync server on Cloudflare | live sync; unstable, replicates everywhere, Kotlin would reimplement it | rejected (R §4.2) |
| D | Self-hosted bucket at home | no cloud; unreachable off-tailnet, peacelily not up | rejected for now; the sink is a port |

Languages: Rust device core (rejected: Android-only, no cross-platform need), Node (rejected:
Bun). **Chosen: Bun + Effect v4 on desktops and the brain; Kotlin on the phone.**

Inference: commercial cloud models (excluded), managed open-weight hosting such as Bedrock
(open, §11), **peacelily with llama-swap (chosen)**. A temporary brain on butternut was
considered and rejected: its 4 GB GPU cannot run the review, and it is an agent host (V §c).

Chat: Claude in T3 via MCP (excluded), OpenCode (a coding harness; plaintext session store on
an agent host), LibreChat (stores chats in plaintext MongoDB; V M4), **an Ask page in the PWA
(chosen)**. LibreChat stays possible later under the conditions in V §h.

Location: OwnTracks posting to the brain (breaks constraint 4; plaintext app queue),
**Pollen-native collection (chosen)**.

## 5. Design

### 5.1 Overview

```
 hazel / butternut                               phone (Pollen)
 ┌──────────────────────────────────────┐        ┌───────────────────────────────┐
 │ awatcher · aw-watcher-web · -vscode  │        │ usage · location · check-in   │
 │ attn-sensor (session: MPRIS, PipeWire│        │ frame log (age, signed, P-256 │
 │   sway IPC, T3 store, git, cwd hook) │        │   Keystore)  → upload queue   │
 │          │ POST (ingest-only API)    │        └───────────────┬───────────────┘
 │ attn-daemon (system user `attn`)     │                        │
 │   merge + checkpoints → frame log    │                        │
 │   (age to public keys, signed) → S3  │                        │
 └──────────────────┬───────────────────┘                        │
                    ▼                                            ▼
     S3 eu-central-1: raw/<device>/<utc-date>/<bucket>/<seq>.attn   (+ .sig sidecar)
     versioned · Object Lock · PUT-only per device · nobody deletes
                    │ pull every 5 min (verify signature → decrypt)
                    ▼
 peacelily: attn-brain (system user `attn-brain`)
   encrypted DuckDB: L0 raw → L1 spans → L2 timeline → L3 labels → L4 rollups → L5 reviews
   ModelGateway → llama-swap (open models only) · Stt → multilingual Whisper (local)
   HttpApi + PWA (passkey sessions) · Ask (Chat + Toolkit) · MCP (token) · Jobs
                    ▲
   phone / desktop browsers over Tailscale, each with its own passkey
```

### 5.2 Data model

**Standard: ActivityWatch's model, verbatim** (R §3.1): bucket {id, type, client, hostname,
created}; event {timestamp (UTC), duration (s), data}. Ingested unchanged: `currentwindow`,
`afkstatus`, `web.tab.current`, `app.editor.activity`. OwnTracks' `location` message shape is
reused for location.

**Our bucket types** (AW-shaped): `attention`, `t3.focus`, `t3.meta`, `shell.cwd`,
`git.activity`, `android.app`, `location`, `checkin.audio`, `checkin.transcript`,
`checkin.tags`, `intention`, `review`, `projection`, `correction`, `rule`, `taxonomy`,
`device`, `attn.health`, `media.consumed`. Shapes: R §3.2, plus:
- `git.activity`: `{repo, sha, parents, branch, subject, files, insertions, deletions,
  merged_into_default, co_authors}`; commit subjects from work repos are allowed (owner).
- `checkin.audio`: raw PCM s16le 16 kHz frames, `{sample_rate, channels, format, frame_count}`.
- `attn.health`: the daemon's own heartbeat, so "device on, nothing captured" differs from
  "device off".
- `rule` / `taxonomy`: the labelling rules and the area → project → aspect tree, as events
  (§5.6), with `rule.order` and versions.

**Intentions are structured** (R §2.1):
`{id, week, kind: hours-in | hours-not-after | sessions | ship | mood, target, direction, note}`.

**Frame log: the on-disk, in-flight and archive format** (V §d; one format for desktop, phone
and audio):
- A **segment** is a sequence of frames `[u32 length][age file]`. Each frame is a complete age
  encryption, to the recipients (§6), of a zstd-compressed NDJSON chunk (or a PCM chunk) with
  a `format_version` header. Frames decrypt independently; a truncated trailing frame is
  dropped and everything before it survives. `fdatasync` per frame.
- Each NDJSON line is an AW event plus a ULID `id`, minted when a span **opens**.
- **Checkpoints**: an open (heartbeat-merged) event is re-emitted every 60 s with the same id,
  its current duration and `open: true`; the closing record has `open: false`. The brain keeps
  the last record per `(device, bucket, id)`. Crash loss ≤ 60 s.
- A segment seals at 15 min, 1 MB, shutdown or SIGTERM; the sealed segment **is** the batch
  uploaded to `raw/<device_id>/<UTC seal date>/<bucket_id>/<seq>.attn` with
  `If-None-Match: *`, plus a plaintext sidecar (`device_id`, `seq`, `frame_count`, `sha256`,
  P-256 signature over the hash). Sidecars hold bookkeeping only. Key names reveal device,
  bucket and cadence to AWS; accepted.
- `spec/` holds golden segments, including a truncated-frame and a bad-signature case; the Bun
  and Kotlin writers both pass them in CI.

**IDs and time**: ULIDs; a stable random device UUID plus hostname for humans; UTC events, the
IANA zone per segment; "not after 22:00" evaluated in local wall time per day.

**Derived layers** (rebuildable; raw is the only truth; R §3.4): L0 raw tables → L1 spans per
device → L2 one attention timeline per device (focused app wins: browser → URL, editor →
file, T3 → thread; attention state applied) → L3 labels (area, project, aspect, activity;
`source`, `confidence`, `rule_id@version`) → L4 rollups → L5 narratives. Cross-device overlap
is real: one primary device per minute for rollups (tie-break by attention state, then input
activity; written in `spec/`), the other as secondary time.

**Corrections are events addressed by `(device_id, time range)`** plus an op (relabel, split at
t, break, tombstone), with raw ULIDs as hints and `applies_from_rebuild_version`; a correction
that no longer matches after a decoder change is reported, not dropped (V M7).

### 5.3 Desktops: attn-daemon and attn-sensor (Bun + Effect)

Replaces ActivityWatch on hazel and butternut. Two processes (V M2, §a):

- **`attn-daemon`**, a **system** service (`User=attn`, `StateDirectory=attn`,
  `ProtectHome=yes`, `PrivateTmp`, `NoNewPrivileges`, `LimitCORE=0`). Owns the frame log, the
  heartbeat merge and checkpoints, the device's signing key and IAM credentials (sops secrets
  owned by `attn`, encrypted to the host key, never the primary key), and the uploader. Holds
  only the recipients' public keys: it can write the queue, never read it back.
- **Ingest-only AW API on 127.0.0.1:5600**: `GET /api/0/info`, bucket create/metadata, `POST`
  events, `POST` heartbeat (aw-server's merge rule). **No `/export`, no event reads, no
  `/query`.** Pollution controls, not confidentiality: an `Origin` check pinned to the
  aw-watcher-web extension id, a per-host watcher token for clients that can send one,
  rate and bucket-count limits.
- **`attn-sensor`**, the user's session service (needs the session bus): media-aware
  `attention` (§5.7), `t3.focus` and `t3.meta` (from the local T3 store on hosts running T3),
  `git.activity` (every 10 min, `git log --author` over repos seen by the cwd/editor watchers,
  never fetching; optional `gh pr list` on the device with its existing auth), and the
  `shell.cwd` endpoint for a fish hook (interactive shells; skipping agent shells is advisory).
  Stateless beyond current state; posts to the daemon like any watcher.
- **Uploader**: network-aware (holds bulk uploads on a metered link via the `agent-net` signal).
  S3 client must send `If-None-Match` (Bun's built-in client may not; use
  `@distilled.cloud/aws` or SigV4 directly).
- **`attn status`**: coverage, last upload, queue depth; `/health` for waybar later.
- nixconf sets `kernel.yama.ptrace_scope = 1` explicitly, and adds courtesy deny rules for
  agents (port 5600, `/var/lib/attn`, the attn units) in `agent-common.nix`. The system user is
  the control; the deny rules are fences.

Third-party watchers, unchanged: **awatcher** (nixpkgs; wlroots window + idle) replaces the
broken `aw-watcher-window`; **aw-watcher-web** via Chromium policy; **aw-watcher-vscode**
(already in `vscode.nix`). The Clockify extension leaves `chromium.nix`.

### 5.4 Phone: Pollen (Kotlin)

Pollen stays in nixconf and gains a tracker module that consumes `spec/` from the attn flake
input (as `phone-app.nix` already passes store paths to Gradle):

- **Frame log + uploader**: same format; age in Kotlin (`age-kmp` or `kage`); P-256 signing key
  generated in the **Android Keystore**; public keys only for encryption; S3 SigV4 PUT with
  `If-None-Match`; drains when online.
- **Usage**: `UsageStatsManager.queryEvents` in a periodic WorkManager job (the OS keeps the
  log, so Xiaomi killing the app loses nothing).
- **Location**: fused location provider, batched into the `location` bucket in the same frame
  log (no OwnTracks).
- **Check-in**: one screen, one record button, three spoken prompts and a few chips (place,
  energy −2..2, day shape). Audio is recorded as **PCM frames straight into the frame log**,
  never through `WavWriter`/`DraftStore`; a live preview may run from the in-memory buffer.
  The transcript of record is made by the brain.

### 5.5 Brain: attn-brain on peacelily (Bun + Effect)

A system service (`User=attn-brain`, sandboxed: egress only to loopback, the tailnet and S3;
`LimitCORE=0`, `PrivateTmp`), bound to 127.0.0.1, published with `tailscale serve`.

- **Pull**: lists `raw/` with a cursor per device and bucket every 5 min; **verifies the
  signature against the enrolled-device registry before decrypting**, quarantines failures;
  decrypts with the brain identity; loads into DuckDB.
- **Storage, encrypted at rest**: an encrypted DuckDB database (1.4+ encrypts the file, WAL and
  temp files) via **`duckdb-bun`** (bun:ffi over nixpkgs `libduckdb`; `@duckdb/node-api` as
  fallback), opened with a prepared `ATTACH ... ENCRYPTION_KEY`, statement logging off, never
  `:memory:` for real data, `temp_directory` on tmpfs. Kept audio stays in its frame logs. No
  Parquet snapshots. Logs carry no tracking data (`Redacted`, a tested log policy).
- **Enrich**: rules → embeddings (EmbeddingGemma on peacelily) → a small open model for the
  residue (§5.6). T3 context from `t3.meta`.
- **Transcribe**: a local **multilingual Whisper** (large-v3-turbo, auto language, code-switching
  tolerated; mostly English, Arabic where natural), fed over stdin or a sandboxed unit with
  `PrivateTmp`; audio kept, so transcripts can be regenerated with better open models.
- **Serve**: HttpApi + the PWA, Ask, the MCP server.
- **Jobs**: evening check-in nudge, daily digest, Thursday end-of-day review draft, Saturday
  lookahead seed. Notifications via ntfy or Pollen's push (builder's call).

### 5.6 Rules and taxonomy

Rules and the taxonomy are **data**: `rule` and `taxonomy` events, edited in the PWA, archived
like everything else, never in any repo. Rules apply in `rule.order`; every label records
`rule_id@version`. Bootstrap: the owner enters a starter list (routelab with its aspects,
d_abm, nixconf, reading, admin, ...); after a few days the brain proposes clusters of the
unlabelled residue for him to name.

### 5.7 Attention and coverage

- **Media-aware idle** (in `attn-sensor`): input-idle becomes `watching` when MPRIS reports
  playback, a PipeWire stream comes from the focused app, the tab is `audible`, or an idle
  inhibitor is held; `supervising` when a T3/agent run is active in the focused window;
  `away` only when none apply; `locked` from swaylock.
- **Coverage** = share of the waking day with a known state per device, plus "last frame seen"
  per device and watcher, using `attn.health`. Every screen and the review show it; the review
  opens with it.

### 5.8 Surfaces

**PWA** (served by the brain; installable): Home (week vs intentions, today's strip,
coverage), Day (attention strip per device, top projects and non-work, outcomes, the check-in;
relabel / split / mark as break), Week review (two axes, each claim with expandable evidence;
accept / edit / regenerate the projection), Intentions (Saturday editor), Places (location by
day), **Ask** (chat), Rules & taxonomy. Text sketches: R §2.2.

**Auth**: every browser registers a **passkey**; nothing on the brain answers on Tailscale
identity alone (V B2). The PWA's offline cache is encrypted with a key derived from the
passkey's PRF output; where PRF is unavailable, nothing tracking-related is cached offline.

**Ask**: Effect `Chat` + the same `Toolkit` the MCP server exposes (`time_by`, `timeline`,
`checkins`, `intentions`, `outcomes`, `coverage`, `places`, `search_titles`), read-only over
derived data, tool calls shown per answer, history stored in the encrypted DuckDB.

**MCP server** (Effect `ai/McpServer`, HTTP, bearer token): for open-model clients only. The
token is delivered through a sops env file to such a client's unit, never into the Nix store,
`programs.mcp`, `.mcp.json` or any Claude Code / T3 / OpenCode config. Client-name checks are
logging, not a control.

### 5.9 Agent layer and the typed model boundary

`ModelGateway` is the only `LanguageModel` in the brain: built solely from
`OpenAiClient.layer({ apiUrl })` where `apiUrl` is a branded `AllowlistedUrl` schema that only
parses loopback or tailnet hosts; provider fixed to `llama-swap`; a test asserts the
production layer graph contains no other provider. Backed by the unit's network sandbox and
the absence of any commercial key. Models (R §4.4, confirm on hardware): gpt-oss-20b for Ask
and tools, Qwen3.5-9B with thinking for the review, Qwen3.5-4B for labelling. The tracker
and coding share llama-swap; the owner does one at a time, so no priority scheme.

### 5.10 Seams for later projects

- **Inbox / second brain**: the brain exports `media.consumed` and attention-state changes;
  the model boundary applies to whatever consumes them.
- **Away from home**: §11.

### 5.11 Effect structure (V §g)

Ports as `Context.Service`, one `Layer` per implementation, wiring only in `main.ts`.
- Daemon: `Clock`, `Journal` (frame log), `Sealer` (age, zstd, `Redacted` keys), `Signer`,
  `Sink` (`S3Sink`, `DirSink`, `MemorySink`), `NetworkPolicy`, `Ingest` (merge + checkpoints),
  `AwApi` (HttpApi group). Sensor: one scoped `Stream<Event>` layer per source.
- Brain: `BatchSource`, `Verifier` (device registry), `Decrypter`, `DuckDb` (thin, scoped, over
  `duckdb-bun`; no `@effect/sql-duckdb` exists), `Refinery`, `ModelGateway`, `Stt`, `Jobs`,
  `Api` (passkey middleware), `Mcp`, `Notifier`.
- Tests: `TestClock` for seal/checkpoint timing; memory sink/source round trips; `spec/`
  conformance; a temp encrypted DuckDB per test; `McpTest`; a scripted `LanguageModel` for the
  review job. Every file, connection and server in a `Scope`; interruption-safe seal on
  SIGTERM via `BunRuntime.runMain`.
- Unstable modules (`ai`, `http-api`, `sql`): exact pins; their imports live in one module per
  side so a bump touches one file.

### 5.12 Repository, build, deployment

```
flake.nix            flake-parts, devenv shell (Bun, DuckDB CLI, age, awscli2), treefmt
spec/                frame-log format, bucket shapes, tie-breaks, golden vectors
packages/            Bun workspace, Effect pinned exactly
  model/             Schemas for all bucket types and the sidecar
  daemon/  sensor/   attn-daemon, attn-sensor
  brain/             attn-brain
  pwa/               Vite app
  infra/             Alchemy stack: bucket (versioning, Object Lock), per-device IAM,
                     brain reader role, the no-delete policy
android/tracker-lib/ Kotlin library Pollen consumes
nix/modules/         device.nix (daemon, sensor, awatcher, fish hook, sysctl),
                     brain.nix (service, STT endpoint, llama-swap entries, tailscale serve)
```

- **Nix**: Bun apps via **bun2nix**; `libduckdb` from nixpkgs for `duckdb-bun`; PWA as a static
  derivation; `nix flake check` runs typecheck, tests and `spec/` conformance.
- **nixconf** consumes the flake input: `nixosModules.device` on hazel and butternut,
  `nixosModules.brain` on peacelily, `tracker-lib` into Pollen. Secrets for attn live in
  nixconf's sops, encrypted to host keys plus the offline vault key only.
- **Alchemy** deploys from the dev shell (stage `prod`, state in S3 as routelab does); it owns
  infrastructure only.
- **CI**: GitHub Actions (`nix flake check`); Android tests on butternut via
  `nix run .#phone-app -- test`.

## 6. Keys, trust and threat model

- **Recipients**: the brain identity (derived from peacelily's SSH host key with `ssh-to-age`,
  as fern does; never in git) and the owner's **offline vault key** (KeePassXC). Devices carry
  both public keys. The archive survives losing peacelily.
- **Signing**: each device has a P-256 key generated on the device (Keystore on Android, a file
  owned by `attn` on desktops); the brain trusts only enrolled keys.
- **Enrolment** (`attn device enrol <name>`, on peacelily): creates the prefix-scoped IAM user
  through Alchemy, records a `device` event `{device_id, signing_pubkey, iam_user,
  enrolled_at}`, hands the device a bundle (recipients, device id, IAM key) over SSH/Tailscale.
- **Revocation** (`attn device revoke`): deactivate the IAM key, record `revoked_at`; later
  batches are rejected, earlier ones quarantined for review.
- **S3 policy**: devices `PutObject` on `raw/<device_id>/*` only (no list, no get); the brain
  lists and gets `raw/*` and puts its own buckets; nobody holds `DeleteObject`; versioning and
  Object Lock (governance, long retention); the owner's everyday SSO role cannot delete.
- **DuckDB key**: random, generated on peacelily, in sops encrypted to the host key + vault,
  `/run/secrets` owned by `attn-brain`; rotation = rebuild from raw under a new key.
- **Rekey runbook** (`attn rekey`): age cannot re-key in place; on brain-key compromise,
  decrypt with the vault key offline, re-encrypt to a new recipient set under `raw-g2/`, keep
  the old prefix under Object Lock. Documented in M0.
- **Stolen device**: queue unreadable; a PUT-only key and a signing key until revoked; Object
  Lock and signatures bound the damage to filterable junk.
- **Agents**: they run as the owner's user on hazel, butternut and (later) peacelily. They can
  pollute ingest (bounded by token/Origin/rate limits); they cannot read the queue, the keys,
  the brain's database or its API (passkeys). The remaining hole is the sops primary key on
  agent hosts, closed by P0.

## 7. Milestones

**P0, prerequisites** (mostly nixconf; the owner deploys):
- peacelily bring-up (`2026-11-24-peacelily-bring-up.md`), including per-host sops keys.
- **Move the sops primary key off hazel and butternut** (a separate non-agent Unix user for
  editing secrets, or a hardware-backed age plugin; §11) and re-encrypt attn's secrets to host
  keys + vault only.
- `kernel.yama.ptrace_scope = 1` and agent deny rules in nixconf.
- The Alchemy stack: raw bucket (versioning, Object Lock), device and brain roles, no-delete
  policy; the rekey runbook.

**M0, one honest week**: attn-daemon + attn-sensor (window, web, editor, idle, git) on hazel
and butternut; brain on peacelily (pull, verify, encrypted DuckDB, rules, rollups); PWA with
passkeys (Home, Day, Intentions, Week, Rules); Thursday review on Qwen3.5-9B. Until M1, the
check-in is typed into the PWA. While P0's peacelily part is pending, build and test the
daemon, `spec/` and the stack against synthetic data.

**M1, the lived stream**: Pollen frame log, check-in screen with PCM capture, location;
multilingual Whisper on peacelily; Ask page; Saturday lookahead; nudges.

**M2, honest attention**: media-aware idle, T3 focus and `supervising`, cwd → repo and aspect,
corrections UI, coverage and `attn.health` everywhere, MCP server.

**M3, phone usage**: Pollen usage collector; non-work breakdowns on the phone side.

**M4, away from home**: whatever §11 decides.

**M5, publishable**: `spec/` docs, single-box profile, bring-your-own open-model endpoint,
releases, the repo goes public after a clean-up pass.

## 8. Left to the builder

Rule syntax; DuckDB table layout; PWA framework details (routelab uses `@effect/atom-react`);
notification channel; seal thresholds within the stated bounds; the review prompt (expect a
month of iteration); llama-swap entry details; the watcher-token mechanism per watcher.

## 9. Risks

1. Collection gaps hollow out reviews → coverage everywhere, `attn.health`.
2. The human side lapses → 60-second check-in, nudges, a review that tolerates gaps.
3. Review quality on 9–20B open models → structured prompts; raw and audio kept for
   regeneration.
4. Effect v4 `ai`/`http-api`/`sql` unstable; Bun FFI for DuckDB → exact pins, thin adapters,
   a DuckDB spike first.
5. Two writers of the frame format drift → `spec/` vectors in both CI legs.
6. peacelily not up / primary key still on agent hosts → P0 before real data flows.
7. Passkey PRF support on the phone's browser → no offline cache if absent.

## 10. Decisions log

Owner (2026-11-24/25): week Sun–Thu, review Thursday end of day, lookahead Saturday (movable);
personal AWS; no Rust, Kotlin on Android; Bun for Effect; raw forever; check-ins mixed, mostly
English; location now; chat not through T3/OpenCode; tracker and coding don't compete for the
GPU; open models only; no plaintext on disk; accepted every review recommendation: app-level
encryption regardless of disk encryption, move the primary key off agent hosts, passkeys,
work-repo commit subjects allowed, Pollen-native location (in M1), Object Lock with a
no-delete everyday role, PWA Ask instead of LibreChat, no temporary brain on butternut.

My calls (correct me): eu-central-1; working name `attn`; repo private until M5,
Apache-2.0 when public; ntfy or Pollen push for nudges.

## 11. Open

- **Primary-key mechanism** for P0: a second non-agent Unix user on hazel for secret editing
  (no hardware needed) or an age hardware plugin (YubiKey). Recommendation: the second user
  now, hardware later if wanted.
- **When peacelily is off** (travel, outage): capture is unaffected; Ask and new reports pause.
  Options: managed open-weight hosting (does "run by someone else" count? owner to decide), an
  on-demand GPU box in AWS running the same brain, a read-only copy of reports. Its own
  product question, for M4.
- Project name.
