# Attention tracker: product and architecture research report

> **Superseded in part by [`2026-11-25-attention-tracker-design.md`](2026-11-25-attention-tracker-design.md).**
> Kept as the research record. Where they differ, the design wins: no Rust (Bun/Effect on
> desktops, Kotlin on the phone), Bun instead of Node, chat through LibreChat (not OpenCode or
> T3), Sun–Thu week, location in scope now, raw kept forever.


Date: 2026-11-24. Author: research sub-agent. Status: recommendation for the owner's decision.

Evidence tags: **[local]** read in `/home/hfahmi/nixconf`, `/home/hfahmi/work/tfc/repos/routelab-monorepo`, the Effect 4.1.1 source under that repo's `node_modules`, or `~/.t3/userdata/statev2.sqlite` (schema only); **[web]** read online today; **[infer]** my inference, not verified end to end.

Hard constraint received mid-research, which overrides the original brief: **no commercial model (Anthropic, OpenAI, Google, ...) may ever touch this data: not raw events, not check-ins, not summaries. All inference uses open-weight models only.** The owner said every routing option (cloud brain, home brain, data read from the cloud or synced home) is acceptable as long as that model boundary holds. This report is written against that constraint; where the original brief's cloud-vs-home tension still matters, it is treated as secondary.

---

## 1. Executive recommendation

**Build it as planned, but put the brain on peacelily, not in the cloud, and make the cloud a dumb, cheap rendezvous.**

The shape:

1. **Devices** (hazel, butternut, later the phone and mac/win) run a small **Rust daemon** that speaks ActivityWatch's REST API on localhost, so the existing watchers (awatcher for Sway, aw-watcher-web, aw-watcher-vscode) work unchanged. The daemon buffers, seals events into immutable batches, encrypts them with age, and uploads them to S3 (eu-central-1). It also contributes the two watchers nobody else provides: media-aware idle and T3 thread focus.
2. **S3** holds append-only sealed batches (`raw/<device>/<date>/<seq>.ndjson.zst.age`). Merge is a listing. Nothing in the cloud can read them.
3. **peacelily** (RTX 5060 Ti 16 GB, always on, already planned as the llama-swap / Wyoming host [local]) runs the **brain**: one Effect v4 Node service that pulls and decrypts batches, loads them into DuckDB, enriches (project / aspect / activity / attention state), stores derived tables, serves the PWA and its API, serves an MCP server, runs the scheduled jobs (evening nudge, Sunday review draft, Monday intentions), and calls **only** llama-swap on localhost for inference and the local Whisper for speech. It is published on the tailnet with `tailscale serve`, the same way T3 is [local].
4. **Phone**: the **PWA** (installed to the home screen, reached over Tailscale) is the chat-and-reports surface. **Pollen** (the existing Kotlin companion app) becomes a sensor and a recorder: Android usage events, the evening voice check-in, uploads. No native chat UI in v1.
5. **Desktop chat**: the same PWA, plus OpenCode's TUI with an `attention` agent pinned to the llama-swap provider and the MCP server. **Claude Code and T3-with-Claude never see the MCP server**; the guard is structural (token issuance, config placement, egress firewall), described in §4.6.
6. **Cloud optional profiles** (later): a read-only "shadow" of derived reports on CloudFront for the hours peacelily is down, and an on-demand GPU EC2 profile (fern-style, Alchemy-managed, auto-stop) that runs the same brain with the same open models for travel weeks or for people who have no home GPU.

What changed versus the decisions in the brief, and why:

| Decision in brief | Recommendation | Why |
|---|---|---|
| Brain on butternut | **Brain on peacelily** | The model boundary makes GPU locality the deciding factor. peacelily already runs llama-swap with `--jinja` (tool calling), Whisper on CUDA, and is headless and always on [local: `modules/nixos/features/ai-server.nix`, `docs/plans/2026-11-24-peacelily-bring-up.md`]. butternut's RTX 3050 is a desktop that is sometimes carried. |
| "Everything after upload" in Lambda / Alchemy stack | **Brain is one long-running Node service at home; Alchemy declares only S3, CloudFront, Cognito and the optional GPU box** | A 20B-class model cannot run in Lambda, and a Lambda brain would have to call a GPU somewhere anyway. The serverless part collapses to storage. Effect v4 + Alchemy stay, just smaller. |
| Chat with the data through Claude in T3 via MCP | **Out.** Chat goes through the PWA (Effect `Chat` over llama-swap) and OpenCode with the local provider | The constraint. §4.6 designs the guard. |
| Rust core owns "fast native watchers (Sway focus)" | **Use awatcher (nixpkgs 0.3.1, Rust, wlr-foreign-toplevel + ext-idle-notify) for window and AFK; Rust core adds only what is missing** | Don't rewrite a maintained watcher; the AW ingest API is exactly what makes this free. [web: awatcher README; nixos MCP: `awatcher 0.3.1` in 26.05] |
| Phone collection through uniffi'd Rust core in Pollen | **Pollen writes batches natively in Kotlin first (age via `age-kmp`, S3 PUT with SigV4); uniffi later** | The batch format is tiny (AW event + manifest). A uniffi/cargo-ndk/crane toolchain is a milestone of its own; it should not gate the first weekly loop. |
| Client-side encryption vs. cloud brain tension | **Dissolved**: raw is age-encrypted to peacelily's and the owner's vault key; nothing readable in the cloud by default; the shadow profile is an explicit opt-in | The owner now cares about the model boundary, not where bytes rest. |
| Mobile product hosted serverless on AWS | **Mobile product is a PWA on the tailnet (v1), with an optional CloudFront shadow (v2)** | Chat needs the GPU; the GPU is at home. The shadow keeps reports readable when home is down. |

Everything else stands: ActivityWatch's event model and bucket conventions as the de facto standard; AW-compatible localhost ingest; sealed batches in object storage; Rust on devices, Effect v4 in the brain; a separate publishable repo that nixconf imports as a flake input.

---

## 2. Product: surfaces and flows

### 2.1 The weekly loop, made concrete

The loop has four moments. Each has one surface and one artefact.

| Moment | When | Surface | Artefact (a bucket, see §3) |
|---|---|---|---|
| Intentions | Monday morning (or Saturday evening; the owner picks the week boundary, open question) | PWA "This week" editor, seeded from last review's projection | `intentions` events, one per intention, `duration` = the week |
| Lived check-in | Evening, ~60 seconds | Pollen: one big record button, three spoken prompts, a few chips | `checkin.audio` (kept), `checkin.transcript`, `checkin.tags` |
| Tracked time | Continuous | Invisible: watchers + daemon | AW buckets + `attention` state |
| Review | Sunday evening, generated; owner reads and reacts Monday | PWA "Week" page; MCP `review_draft` for an OpenCode session | `review` event + `projection` (next week's seed) |

**Intentions are structured, not prose**, because the review must be able to check them. Each intention is:

```
{ id, week, kind: "hours-in" | "hours-not-after" | "sessions" | "ship" | "mood",
  target: { area?, project?, aspect?, activity?, hours?, after?: "22:00", count?, text? },
  direction: "more" | "less" | "about", note }
```

Examples: `hours-in routelab/dashboard about 12h`; `hours-not-after 22:00 less` ("fewer late nights"); `sessions reading more 4`; `ship "peacelily redeploy"`; `mood "more energising days"`. Free text is allowed on every intention; the review model quotes it.

**The review has two axes, as the owner asked.**
Axis 1, *time*: for every `hours-in` / `sessions` / `hours-not-after` intention, the achieved number from the rollups, with the delta and a one-line why (which days, which devices, what displaced it).
Axis 2, *change*: for `ship`, `mood` and `direction` intentions, evidence from events (did the repo get commits, did the aspect get hours) and from check-ins (what the owner said he felt, where he was, who he met) correlated with the day's time shape (late day, café day, agent-supervision day). This axis is narrative and must cite the check-in it draws on.

The review ends with a **projection**: a proposed intention list for next week, each tagged `carry`, `scale-down`, `scale-up`, `drop`, `new`, which becomes Monday's editor seed.

### 2.2 Screens (text sketches)

**PWA, Home** (phone first, 360 px):

```
┌ This week · Mon 24 → Sun 30 ─────── coverage 91% · refined 14 min ago ┐
│ routelab/dashboard   ████████░░  9.5 / 12 h                           │
│ late nights (>22:00) ██░░░░░░░░  2 of ≤1 evenings   ⚠                 │
│ reading sessions     ███░░░░░░░  1 / 4                                │
│ ship: peacelily redeploy                         not yet              │
├ Today ────────────────────────────────────────────────────────────────┤
│ 07:40 ▇▇▇▇ T3 · routelab/mobile   09:10 ▇▇ YouTube (lecture)          │
│ 10:00 ▇▇▇▇▇▇ VSCodium · d_abm     13:00 ▁▁ away   14:00 ▇▇ supervising│
│ [ Check in tonight ]   [ Ask ]                                        │
└───────────────────────────────────────────────────────────────────────┘
```

**PWA, Day**: a horizontal attention strip (active / watching / supervising / away / locked) per device, below it the top projects and the top non-work (YouTube channel, subreddit, article domain), and the check-in card if one exists. Tap a segment: the raw titles (home only, never in the shadow), with "relabel", "split", "this was a break" actions that become correction events (§3.6).

**PWA, Week review**: the generated review with the two axes, each claim followed by a small expandable "evidence" table (events or quotes). Buttons: "accept projection", "edit", "regenerate with notes".

**PWA, Intentions**: the editor, seeded; each row is one structured intention with a free-text note.

**PWA, Ask**: a chat with the data. Each answer shows which tools it called (`time_by`, `timeline`, `checkins`), so a wrong answer is debuggable. Model badge shows the llama-swap model name.

**Pollen, Check-in** (new screen next to the existing drafts list):

```
┌ Evening check-in · Mon 24 ──────────────┐
│  Where did you work?  [home] [office] [café] [other…]   │
│  Energy  draining ◯──◯──●──◯──◯ energising               │
│  Day shape   [early] [normal] [late]                     │
│        ( ●  )   tap to talk ~60 s                        │
│  "How did it feel, what did you see, who did you meet?"  │
│  transcribing on peacelily… / kept for later (offline)   │
└──────────────────────────────────────────┘
```

The audio is recorded with the existing `Recorder`/`WavWriter`, kept as a draft exactly like dictation drafts [local: `apps/phone/.../drafts/DraftStore.kt`], and uploaded as a batch. Transcription happens in the brain (§4.5), not on the phone; Pollen may show a live preview from the existing Whisper client when a server is reachable.

**Desktop**: the PWA in a browser or `t3-open`-style Chromium app window; OpenCode TUI with the `attention` agent for "analyst" conversations; a waybar glyph showing today's attention state and coverage (later).

### 2.3 Notifications and nudges

- 21:30 (configurable): "check in" push. v1: ntfy (already the planned path for agent hooks [local: `docs/plans/2026-11-17-agentic-workspace-design.md`]) to the phone; v2: Web Push from the PWA.
- Sunday 19:00: "your week is ready". Monday 08:30: "set this week" if intentions are empty.
- Coverage alerts: a device that uploaded nothing for 6 h while it was on (the daemon reports heartbeats) gets a nudge, because silent collection gaps are what made ActivityWatch reports hollow.

### 2.4 Idle-time suggestions seam (for the separate second-brain project)

Two interfaces, nothing more:

1. **Event stream**: the brain publishes `attention` transitions (`away → active`, `watching → active`, long `active` with no project) on an HTTP SSE endpoint and as an MCP resource subscription. The inbox project decides what to suggest.
2. **Consumption bucket**: `media.consumed` events (YouTube video id/channel, article URL/domain, duration watched, finished or not), derived from browser events. The inbox project reads it to mark lectures as watched. No suggestion logic lives in the tracker.

### 2.5 v1 versus later

**v1 (one honest week)**: awatcher + aw-watcher-web + aw-watcher-vscode on hazel and butternut; Rust daemon ingest/seal/upload; brain on peacelily with rules-based classification; intentions in the PWA; check-ins via Pollen recording + brain transcription; Sunday review generated by Qwen3.5-9B; PWA Home/Day/Week/Intentions/Ask.

**Later**: smart idle v2 (MPRIS/PipeWire/T3 run state), T3 thread focus, git-cwd aspects, corrections UI, Android usage stats in Pollen, cloud shadow, cloud GPU profile, uniffi core in Pollen, location (OwnTracks-shaped bucket), mac/win devices, publishing.

---

## 3. Data model

### 3.1 The standard: ActivityWatch events in buckets

Keep ActivityWatch's model verbatim [web: docs.activitywatch.net buckets-and-events]:

- **Bucket**: `id` (convention `<watcher>_<hostname>`), `type` (event schema name), `client`, `hostname`, `created`, `name`.
- **Event**: `timestamp` (ISO 8601, UTC), `duration` (seconds), `data` (JSON object whose schema is the bucket type).
- Known types we ingest unchanged: `currentwindow` {app, title}; `afkstatus` {status: afk | not-afk}; `web.tab.current` {url, title, audible, incognito, tabCount}; `app.editor.activity` {file, project, language}.
- **Heartbeats** with `pulsetime` merge adjacent identical events; the daemon implements `/api/0/buckets/<id>/heartbeat` exactly as aw-server does, because that is what every watcher calls [web: AW REST API].

Why keep it: three maintained watchers already emit it; `aw-server` import/export speaks it, so the owner (or anyone) can import our batches into a stock ActivityWatch for its UI; and it is the closest thing to an open standard for this data. Open mHealth / IEEE 1752.1 cover physical activity and sleep, not screen attention [web]; xAPI is learning-record shaped; OwnTracks JSON is the de facto location format and Dawarich imports it [web]. Nothing covers "what I paid attention to", so AW it is, and we publish our extensions as bucket types.

### 3.2 Our bucket types (extensions)

All AW-shaped, so they travel in the same batches and import into aw-server if ever needed.

| Bucket type | Producer | `data` |
|---|---|---|
| `attention` | daemon (media-aware idle, §6) | `{state: active \| watching \| supervising \| away \| locked, reason}` |
| `t3.focus` | daemon on T3 hosts and clients | `{environment, thread_id, project_id, run_active: bool}` |
| `shell.cwd` | shell hook → daemon | `{cwd, repo, branch}` |
| `android.app` | Pollen (UsageStatsManager `ACTIVITY_RESUMED/PAUSED`) | `{package, app, category}` (aw-android compatible where it makes sense) |
| `checkin.audio` | Pollen | `{draft_id, sha256, bytes, lang_hint}` + the audio as a side object in the same batch |
| `checkin.transcript` | brain | `{draft_id, text, model, lang}` |
| `checkin.tags` | Pollen | `{place, energy: -2..2, day_shape, people: [..]}` |
| `intention` | PWA | the structure in §2.1, `duration` = the week |
| `review` | brain | `{week, markdown, evidence_refs, model}` |
| `projection` | brain / PWA | `{week, intentions: [...]}` |
| `correction` | PWA / MCP | `{target_event_id, op: relabel \| split \| delete \| merge, payload}` |
| `location` | later: Pollen / OwnTracks | OwnTracks `location` shape `{lat, lon, tst, acc, batt, tid}` |
| `media.consumed` | brain (derived, also exported) | `{kind: youtube \| article \| reddit, id, channel \| domain \| subreddit, seconds, finished}` |

### 3.3 Envelope, batches, IDs

A batch is the unit of sync, not an event:

```
manifest.json      { format_version: 1, device_id, device_tz: "Africa/Cairo", bucket: {...AW bucket}, seq, from, to, count, sha256 }
events.ndjson      one AW event per line, plus "id": ULID (ours; AW's integer ids are server-local)
blobs/<sha256>     optional side objects (check-in audio)
```

Stored at `raw/<device_id>/<YYYY-MM-DD>/<bucket_id>/<seq>.tar.zst.age`. Sequence numbers are per device and bucket; a gap is detectable. Batches close every 15 min or 1 MB, and on shutdown. Uploads use `If-None-Match: *` so a key is never overwritten: append-only by construction.

IDs: ULIDs minted at ingest (time-ordered, sortable; Effect's `EventJournal.makeEntryIdUnsafe` has the same property [local]). Device IDs: stable random UUID per device, written once, plus the hostname for humans (hostnames can change; ActivityWatch's hostname-in-bucket-id is a known weakness [web: aw-sync README]).

Time zones: events are UTC; the manifest carries the device's IANA zone at seal time, and the brain renders in the owner's zone (`Africa/Cairo`, which has DST again since 2023, so "22:00" intentions must be evaluated in local wall time per day, not by a fixed offset).

### 3.4 Derived layers (rebuildable; raw is the only source of truth)

| Layer | Content | Store |
|---|---|---|
| L0 raw | the batches, decrypted into DuckDB tables per bucket type | DuckDB file on peacelily (`events_<type>`) |
| L1 spans | per device, non-overlapping intervals of (window app/title, web url, editor file, afk, attention state) | DuckDB |
| L2 attention spans | one timeline per device after precedence: web tab when a browser is focused, editor file when the editor is focused, T3 thread when T3 is focused; attention state applied (away time removed, watching kept with a flag) | DuckDB |
| L3 labels | each L2 span gets `area`, `project`, `aspect`, `activity` by rules first (§4.3), embeddings second, LLM third for the residue; the label records its `source` and `confidence` | DuckDB |
| L4 rollups | hourly and daily sums by (device, area, project, aspect, activity, attention state); the numbers the PWA and the review use | DuckDB + Parquet snapshot to S3 `derived/` (shadow profile only) |
| L5 narratives | daily digest (short), weekly review | DuckDB + the `review` bucket |

Corrections (§3.6) are applied at L2/L3; rollups are recomputed for the affected day.

### 3.5 Schema evolution

`format_version` on the manifest; each bucket type carries its version in the bucket `type` string when it changes incompatibly (`attention.v2`), the AW convention. The brain keeps decoders for every version it has ever seen; derived layers are dropped and rebuilt when a decoder changes. A `spec/` directory in the repo holds golden batches and a conformance test that the Rust, Kotlin and TypeScript implementations all run (three implementations of one format is the main drift risk, §8).

### 3.6 Dedup and corrections

- Ingest dedup: the daemon's heartbeat merge handles the watcher side; batches are idempotent by `(device_id, bucket_id, seq)`; the brain skips a batch it has already loaded (manifest sha256).
- Cross-device overlap is not deduplicated: two devices active at once is real (phone YouTube while the laptop builds). The L2 precedence picks *one* primary device per minute for the rollups (the one with input activity; ties → the one with a focused window), and keeps the other as `secondary` time.
- Corrections are **events, never edits**: `correction` events in their own bucket, uploaded like any other, replayed on rebuild. Delete is a tombstone. That keeps raw immutable and the audit trail honest.

---

## 4. Architecture

### 4.1 Device core (Rust)

One binary, `att-daemon`, per device, as a user service (`sway-session.target` on the laptops, following the fix in `activitywatch.nix` [local]):

- **AW-compatible server** on `127.0.0.1:5600`: `/api/0/info`, `/buckets`, `/buckets/<id>` (create/get), `/buckets/<id>/events` (POST), `/buckets/<id>/heartbeat?pulsetime=`, `/export`. Not `/query`: the AW web UI is not a goal; if the owner wants it, the daemon can *tee* events to a real `aw-server-rust` (nixpkgs 0.13.2) on another port.
- **Local journal**: SQLite (one file), WAL, retention 30 days or until sealed and acknowledged.
- **Sealer and uploader**: §3.3; age encryption with the `age` crate (`rage`, streaming API) [web] to the recipients in config (peacelily's key, the owner's vault identity); S3 PUT with SigV4 (the `aws-sdk-s3` crate, or a minimal signer to keep the binary small); retries with backoff; metered-link awareness (honour `agent-net`-style hints: hold uploads on hotspot, flush on home Wi-Fi) [infer].
- **Built-in watchers**: `attention` (media-aware idle, §6.2), `t3.focus` (§6.3), `shell.cwd` receiver (a one-line fish hook POSTs on `cd`), optional Sway IPC subscriber as a fallback when awatcher is not running.
- **Status**: `att status` prints coverage, last upload, queue size; a `/health` endpoint waybar can read.

Crates to reuse: `aw-models` on crates.io is stale (0.1.0, 2020 [web]); the model is three fields, so copy it. `age` 0.11/0.12 is maintained [web]. `rusqlite`, `axum`, `zstd`.

Memory target: under 30 MB resident. This is the reason for Rust on hazel (256 GB disk, battery).

### 4.2 Ingest and sync

S3 is the rendezvous because devices roam and peacelily may be off. Direct push to peacelily over the tailnet (lower latency at home) is a later optimisation; the daemon's uploader gets a second "sink" with the same append-only contract.

The brain's **puller** lists `raw/` with a per-device cursor, downloads new keys, decrypts with peacelily's age identity (from sops, like other peacelily secrets [local: `secrets/<hostname>/`]), verifies the manifest hash, loads into DuckDB, then moves the cursor. Listing is cheap (one `ListObjectsV2` per device per run, every 5 min).

Why not Effect `eventlog` for sync: it is `@stability unstable`; its encrypted replication holds every kept entry in memory during compaction and "a new device still replays the newest day or so of writes" [local: `effect/src/eventlog/EventLog.ts` doc comment]; it replicates everything everywhere, which we do not want; and Pollen would need the protocol in Kotlin. The ideas worth borrowing (owner-writes-own-files, ULID entry ids, encrypted batches with plaintext ids for dedup) are in our format already. Same verdict on aw-sync: it is the same "each device only writes files it owns" idea with SQLite files in a Syncthing folder, but its daemon mode cannot read the Android layout, deletions do not sync and duplicates accumulate [web: aw-sync README].

### 4.3 Enrichment (the "refinery" in the brain)

Classification runs in three tiers, cheapest first:

1. **Rules** (the owner's, private, not in the public repo; a YAML in nixconf secrets or a private overlay): regex on app/title/url/cwd → area/project/aspect/activity. The routelab aspect example from the real layout [local: `routelab-monorepo/apps`, `packages`]: `apps/observer` → mobile app; `apps/dashboard`, `packages/schematic-*` → dashboard; `infra/stack`, `deployment`, `ci` → devops/servers/deploys; T3 thread titles map through the thread's `project_id` → `workspace_root` [local: `projection_threads`, `projection_projects` columns].
2. **Embeddings**: EmbeddingGemma-300M is already resident on peacelily [local: `ai-server.nix` `embedding` group]; unlabeled titles/urls are matched to the nearest labelled example above a threshold.
3. **LLM**: the residue (new sites, odd titles) goes to Qwen3.5-4B with structured output (JSON schema → llama.cpp grammar) in batches of 50; labels carry `source: "llm"` and `confidence`, and the PWA shows them as suggestions until confirmed once.

### 4.4 The brain: placement and the open-model boundary

**Placement: peacelily**, as one systemd service (`att-brain`, Node 24, Effect 4.1.x), bound to `127.0.0.1`, published with `tailscale serve --https=443` under a path or a second hostname, like T3 [local: `agent-t3code.nix`]. The GPU budget today: Whisper turbo at `int8_float16` ≈ 1.5 GB resident, EmbeddingGemma ≈ 0.5 GB, one chat model swapped in by llama-swap [local: `ai-server.nix`].

**Inference boundary, enforced three ways:**

1. *Code*: the brain's `LanguageModel` layer is constructed from `OpenAiClient.layer({ apiUrl: <llama-swap /v1>, apiKey: none })` and nothing else; `Model.provider` is `"llama-swap"`. A unit test fails the build if any `apiUrl`, `baseURL` or `Model.provider` in the brain's configuration resolves to a non-allowlisted host (allowlist: `127.0.0.1`, `peacelily`, the GPU box's tailnet name).
2. *Network*: the service unit gets `IPAddressDeny=any` + `IPAddressAllow=127.0.0.0/8 100.64.0.0/10 <S3 endpoint ranges via a proxy>`; practically, egress to S3 goes through a local proxy or the unit allows only the S3 VPC endpoint / prefix list. The brain cannot reach `api.anthropic.com` or `api.openai.com` even by mistake [infer; standard systemd sandboxing].
3. *Config*: no Anthropic key is in the brain's environment, ever. (OpenCode's host service has one for other agents [local: `agent-opencode.nix`]; the brain is a different unit.)

**Effect 4.1.1 provider check** [local + web]:

- `effect/ai` ships `LanguageModel`, `Chat`, `Toolkit`/`Tool`, `McpServer`, `McpClient`, `OpenAiStructuredOutput` (schema rewriting for OpenAI-style strict JSON schema) and an `AnthropicStructuredOutput` we will not use. All `@stability unstable` or `experimental` [local: file headers].
- `@effect/ai-openai` 4.1.5 (npm, latest) exports `OpenAiClient` (options `apiKey`, `apiUrl`, `organizationId`, `projectId`, `transformClient`; `apiUrl` replaces `https://api.openai.com/v1`), `OpenAiLanguageModel` (implements `LanguageModel` over the **Responses API**), and an `OpenAiCompletions` module (Chat Completions) [web: npm registry, effect.website v4 API docs; the `OpenAiCompletions` docs page 404'd, so confirm its surface in `node_modules` after install].
- llama.cpp's `llama-server` serves `/v1/chat/completions` with OpenAI-style tool calls when started with `--jinja` (peacelily's `chatFlags` already do [local]), structured output via JSON-schema grammars, and since 2026 also `/v1/responses` (converted internally to chat completions; compliance work still open in PR #21174) [web]. **Use `OpenAiCompletions` against llama-swap in v1**; try `OpenAiLanguageModel` over `/v1/responses` as an experiment, since the Responses path is where Effect's provider puts reasoning metadata and tool-call state.
- Tool calling in Effect: `LanguageModel.generateText({ toolkit, toolChoice })` resolves tool calls in a loop; `Chat` keeps history in a `Ref` and can be persisted [local: `Chat.ts`, `LanguageModel.ts` docs]. This is enough for "Ask": a `Toolkit` of `time_by`, `timeline`, `checkins`, `intentions`, `coverage`, `search_titles` over DuckDB, and `Chat` per conversation.

**Models for peacelily (16 GB, with ~2 GB already resident)** [web, cross-checked with what `ai-server.nix` already pins]:

| Role | Model | Why | Fits? |
|---|---|---|---|
| Chat with data, MCP agent (tool calling) | **gpt-oss-20b** (Apache-2.0, native MXFP4 ≈ 12–13 GB) | the consensus "best all-rounder that fits 16 GB and handles tool calls well", two-turn agentic tool calling passes in 2026 tests | yes at 16k context; tight beside Whisper, so llama-swap must unload Whisper-adjacent models or use a smaller KV (`q8_0` is already set) |
| Weekly review (long context synthesis, batch) | **Qwen3.5-9B UD-Q4_K_XL, thinking on, 64k** (already configured as `qwen3.5:9b`) | long context, thinking helps correlation; a Sunday batch job can take minutes | yes |
| Weekly review, higher quality, slower | Qwen3.5-35B-A3B (already configured, CPU offload) or Gemma 4 26B-A4B QAT (~15 GB) | more capable; minutes per review is fine | 35B: with offload; Gemma 4 26B: only if Whisper is unloaded first |
| Labelling, titles, check-in cleanup | **Qwen3.5-4B Q8_0** (already `qwen3.5:4b`) with JSON-schema output | cheap, fast, structured | yes |
| Embeddings | EmbeddingGemma-300M (resident) | already there | yes |

Add to `ai-server.nix`: a `gpt-oss:20b` entry (`-hf ggml-org/gpt-oss-20b-GGUF`, `--jinja`, `--reasoning-format` as needed, `--ctx-size 16384`, `--parallel 1`). Keep one chat model loaded at a time (llama-swap default).

**Cloud option for the brain** (when peacelily is off, or for travel, or for strangers):

- *Self-run GPU EC2, fern-style*: g6.xlarge (L4 24 GB) ≈ $1.01/h on-demand, ≈ $0.36/h spot in eu-central-1; g5.xlarge (A10G 24 GB) ≈ $1.26/h; g6e.xlarge (L40S 48 GB) for 35B-class, roughly $2/h [web: doit.com price pages; g6e eu-central price not confirmed]. Same NixOS `ai-server` + `att-brain` modules, Alchemy-managed, idle auto-stop (the `cloud-idle-stop` feature already exists [local: `features/cloud-idle-stop.nix`]). A weekly review job is ~20 min → under $1/month on spot; interactive chat while travelling ≈ $0.4–1/h of use. Cold start 3–6 min (boot + model pull from S3-cached GGUF).
- *Managed open-weight hosting* (Bedrock now lists 18 fully managed open-weight models incl. gpt-oss-20b/120b, Qwen3-Next-80B-A3B, Mistral Large 3; AWS states prompts are not stored, logged, or used for training [web]; Together/Fireworks/DeepInfra are similar): **this is a question for the owner, not assumed acceptable**. It satisfies "open-weight model" but not "no third party processes the data". The design does not depend on it: it is one `apiUrl` away if the owner ever says yes.

### 4.5 Speech for the check-in (local and open)

Current state [local]: Pollen transcribes on the phone with Parakeet TDT 0.6B v2 int8 (English only) via sherpa-onnx, or remotely with butternut's `dictation-server` (whisper.cpp, large-v3-turbo q8_0, Vulkan, multilingual, vocabulary prompt). peacelily runs Wyoming faster-whisper `turbo` on CUDA with `language = "en"` hard-set.

Recommendation: **the brain transcribes, in batch, from the kept audio**, not the phone, so the phone's job is only to record reliably (which Pollen already does with drafts). The brain calls a local Whisper HTTP endpoint on peacelily: either add a `dictation-server`-style whisper.cpp instance to peacelily (multilingual, with the fleet vocabulary prompt) or a second Wyoming instance with `language = "auto"`/`ar` (the current `english` server is English-only). Audio is kept, so transcripts can be regenerated when better open models land: Qwen3-ASR 1.7B covers 52 languages including Arabic and has GGUFs for transcribe.cpp (pinned 2026-04) [web]; Egyptian-dialect Whisper fine-tunes exist on Hugging Face [web]; Voxtral (Apache-2.0) outperforms Whisper large-v3 on major languages but does not list Arabic [web]. For an English check-in Parakeet on the phone remains a fine live preview.

### 4.6 MCP: exposed safely under the model boundary

The MCP server cannot technically know which model its client is driving. So the guard is **where the server can be reached from and who can get a token**, with defense in depth:

1. **Transport**: Effect `McpServer.layerHttp` on the brain, HTTPS via Tailscale Serve, path `/mcp`. Bearer tokens required (`McpServer.middleware`); tokens are minted by `att token issue --client <name> --policy open-model-only` and carry the client name and policy; the server logs `clientInfo.name/version` from `initialize` [local: `McpServer.ts` records `clientInfo`] and refuses names matching `claude*`, `codex*`, `cursor*` as a soft tripwire.
2. **Where tokens live**: only in Nix-generated configs of open-model harnesses: OpenCode's `opencode.json` under an `attention` agent whose `model` is `peacelily/<model>` (the provider already exists: `providers.peacelily` with `@opencode/ai/providers/openai-compatible` and `baseURL = agents.llamaSwapUrl` [local: `agent-opencode.nix`]), and the brain's own `Chat` (which is in-process; no MCP needed). **Never** in `programs.mcp` (consumed by Claude Code via `enableMcpIntegration` [local: `agent-common.nix`]), never in a project `.mcp.json` (T3's Claude driver reads those [local: t3 integration doc §"Config inheritance"]).
3. **Agent-level pin**: OpenCode agents can carry MCP allow-lists per agent in 2.x config [infer from the `agents.*` + `mcp` sections in `agent-opencode.nix`]; the `attention` agent is the only one with the server, and its `model` is locked to the local provider. A T3 thread using the OpenCode driver with that agent gives the same guarantee, which is also the **phone path through T3's Android app** if the owner wants it (T3 server on peacelily is planned under the agent-host role [local: backlog]).
4. **Content minimisation**: MCP tools return rollups and labelled spans; raw titles/URLs only through an explicit `raw: true` flag that the token policy may deny.
5. **Plain statement for the owner**: with this constraint, "ask Claude about my week in T3" is gone. The replacements are the PWA's Ask page (Effect `Chat` + gpt-oss-20b, phone and desktop) and OpenCode's `attention` agent on the desktop.

### 4.7 Mobile and web app

**PWA** (Vite, TypeScript, Effect; `@effect/atom-react` is what routelab uses [local: `pnpm-workspace.yaml` overrides]), served by the brain on the tailnet. Installable; service worker caches the shell and the last derived JSON so Home works offline. DuckDB-Wasm with OPFS persistence is now stable (duckdb.org, 2026-09-18 [web]) and is the right tool **only for the shadow profile** (querying Parquet snapshots on CloudFront with range requests); at home the brain answers queries.

**Pollen** gains: `UsageStatsManager.queryEvents` (`ACTIVITY_RESUMED`/`PAUSED`, needs the `PACKAGE_USAGE_STATS` special permission, like aw-android 0.14.3 does [web]) → `android.app` bucket; the check-in screen; a batch writer (Kotlin, same manifest/NDJSON, `age-kmp`, which is UniFFI over the Rust reference implementation [web], or `kage` pure Kotlin alpha) and an S3 uploader (SigV4 with per-device IAM credentials from the profile server, scoped to `raw/<device_id>/*` PUT-only). Xiaomi's background killing is a known hazard: collection runs as a periodic WorkManager job that reads the OS's usage log (the OS keeps it; the app need not be alive), and uploads opportunistically. GrapheneOS later: usage stats and passkeys both work without Google services; `age-kmp` is pure JNI.

**Auth**: on the tailnet, Tailscale identity is the auth (the owner is the only tailnet user); the brain checks the `Tailscale-User-Login` header that `tailscale serve` injects. The **shadow profile** needs real auth because CloudFront is public: Cognito Essentials (passkeys, 10k MAU free [web]) + a Lambda presigner for `derived/` objects, or simpler, a single long-lived device token in the PWA. Decision deferred to the shadow milestone.

### 4.8 Encryption and keys

- Raw batches: age X25519 to two recipients: peacelily's identity (sops-managed, like other host secrets) and the owner's vault identity (KeePassXC, offline). Rotation = add a recipient; old batches stay readable by the vault key.
- Phone: encrypts with the same recipients; holds no decryption key.
- S3: bucket private, SSE-S3 on top (free), versioning off (append-only already), lifecycle: none (the owner wants history; ~50 MB/month, see §7).
- Derived snapshots in the shadow profile: SSE-KMS ($1/month per key [web]) and Cognito; they contain rollups and narratives, never raw titles.
- Secrets at home: sops (existing). In the cloud profile: SSM Parameter Store SecureString (free) rather than Secrets Manager.

---

## 5. Code organisation and build

### 5.1 Repository: one public repo, three toolchains

```
attention/                      (working name; the owner names it)
  flake.nix                     flake-parts; devenv shell like routelab; crane; treefmt
  spec/                         batch format spec + golden vectors (the contract between Rust, Kotlin, TS)
  crates/
    att-model/                  AW event/bucket types, manifest, ULID, age sealing (library)
    att-daemon/                 the device service (axum AW API, SQLite journal, sealer, uploader, watchers)
    att-ffi/                    uniffi bindings (later: Pollen, mac/win hosts)
  packages/                     pnpm workspace, Effect 4.1.x pinned exactly (routelab does the same for the same reason: unstable modules)
    model/                      Schema for every bucket type, manifest; shared by brain and PWA
    brain/                      Effect service: puller, refinery, DuckDB, HttpApi, McpServer, Chat, jobs
    pwa/                        Vite app
    infra/                      Alchemy stack: S3 bucket + IAM per device; optional: CloudFront shadow, Cognito, GPU box
  android/
    tracker-lib/                Gradle library module: batch writer, age-kmp, S3 uploader, usage collector, check-in UI pieces
  nix/
    modules/device.nix          NixOS module: att-daemon user service, awatcher, aw-watcher-web policy, fish cwd hook
    modules/brain.nix           NixOS module: att-brain service, llama-swap model entries it needs, Whisper endpoint, tailscale serve
    packages.nix                perSystem: att-daemon (crane), att-brain (pnpm → bundle), pwa (static)
```

**Pollen stays in nixconf** (its identity is "the fleet's companion app" [local: `2026-11-23-phone-pollen-identity.md`]). It consumes `android/tracker-lib` via Gradle `includeBuild` from the flake input's store path: `phone-app.nix` already passes store paths to Gradle (`-PsherpaAar`, `-PvadAssets`) [local], so one more `-PtrackerLib=${inputs.attention}/android/tracker-lib` fits the pattern.

### 5.2 Nix builds

- **Rust**: crane (`craneLib.buildPackage`, vendored deps, separate `cargoArtifacts` for caching). Checks: `cargo test`, clippy, the spec conformance test. Cross to Android later: `cargo-ndk` 4.1.2 is in nixpkgs 26.05, NDK via `androidenv.composeAndroidPackages { includeNDK = true; }`, target `aarch64-linux-android` through rust-overlay/fenix; crane's cross template exists [web: crane docs; nixos MCP]. This is a milestone, not a day.
- **TypeScript**: `fetchPnpmDeps` (fetcherVersion 3) + `pnpmConfigHook` + `pnpm_10` [web: nixpkgs], then `rolldown` to a single `dist/brain.mjs` + `node_modules` for native bits (`@duckdb/node-api` bindings are platform-specific and must come from the pnpm store, not be bundled). The NixOS brain module wraps `node dist/brain.mjs`.
- **DuckDB**: nixpkgs has `duckdb 1.5.2`; the Node binding pins its own DuckDB, which is fine on peacelily (no 250 MB Lambda limit any more). If the Lambda shadow ever needs DuckDB, tobilg's public layers (DuckDB 1.4.1, arm64, parquet/httpfs/json bundled) exist [web].
- **Android**: not hermetic, by design, same as Pollen today (Gradle fetches AGP/AndroidX) [local: `phone-app.nix` header]. Only butternut builds it (hazel's disk).
- **Alchemy**: runs in the dev shell from hazel or butternut (`alchemy deploy --stage prod`), state in DynamoDB like routelab (`AWS.state()` [local: `alchemy.run.ts`]). Alchemy does *not* build from Nix artefacts; its resources are infrastructure (bucket, IAM users/roles per device, optional CloudFront/Cognito/EC2). The CloudFront shadow's static files come from the Nix-built PWA directory, passed as a path, the same mechanism routelab uses for the dashboard build dir [local: `Web.ts`].
- **CI**: GitHub Actions on the public repo: `nix flake check` (Rust tests + clippy, TS typecheck + vitest, spec conformance, formatting), `alchemy plan` on the infra package with a read-only role. Android tests on butternut via `nix run .#phone-app -- test` stay in nixconf.
- **Dev shells**: devenv (owner's habit [local: routelab `flake.nix`]) with Rust, Node 24, pnpm, DuckDB CLI, `age`, `awscli2`; `direnv` so T3/OpenCode threads start inside it (per the agent guidelines).

### 5.3 How nixconf consumes it

```nix
inputs.attention.url = "github:<owner>/attention";
# hosts:
hazel, butternut: imports = [ inputs.attention.nixosModules.device ];  preferences.attention.device = { recipients = [...]; bucket = "..."; }
peacelily:        imports = [ inputs.attention.nixosModules.brain ];   preferences.attention.brain = { llamaSwapUrl = "http://127.0.0.1:9292/v1"; models = { chat = "gpt-oss:20b"; review = "qwen3.5:9b"; label = "qwen3.5:4b"; }; }
```

The brain module contributes its model entries to `services.llama-swap.settings.models` (so `ai-server.nix` and this module share one llama-swap), opens nothing on the firewall (tailscale serve), and reads its age identity and S3 credentials from sops. Private classification rules live in nixconf secrets, not in the public repo.

### 5.4 Consequences of the Rust + TS (+ Kotlin) split

- The batch format exists three times. Mitigation: `spec/` golden vectors and a conformance test in every CI leg; the format is tiny on purpose.
- Two language toolchains in one flake (crane + pnpm) and two dev-shell setups. Acceptable: routelab already has three (Node, Android, Python).
- Rust is the right tool on hazel (memory, battery, cross-platform later) but every watcher-side feature costs more time than it would in TS. Keep the daemon boring: the smartness lives in the brain.
- A TS-only alternative (a Node daemon on laptops) was rejected: 80–150 MB resident per device, no Android story.
- A Rust-only alternative (brain in Rust) was rejected: the Effect `ai` stack (`Chat`, `Toolkit`, `McpServer`, structured output rewriting) and the owner's fluency are worth more than one toolchain.

---

## 6. Collectors inventory

| Source | Yields | Mechanism | Feasibility | Priority |
|---|---|---|---|---|
| Sway focused window | app_id, title, per host | **awatcher** (wlr-foreign-toplevel; bundled aw-server not used; `aw-watcher-window_<host>` bucket) [web] | packaged, works today | v1 |
| AFK | not-afk / afk | **awatcher** via ext-idle-notify (idle timeout 180 s default, tunable) | packaged | v1 |
| Browser tabs (Firefox, Chromium incl. the T3 `--app` window) | url, title, audible, incognito | **aw-watcher-web** extension → localhost:5600 | packaged (HM `firefox-addons` input exists for Firefox; Chromium policy for the extension) | v1 |
| VSCodium | file, project, language | **aw-watcher-vscode** extension | exists | v1 |
| YouTube / Reddit / articles | video id + channel, subreddit, domain + title | brain derives from `web.tab.current` urls (regex), `media.consumed` from audible + duration | trivial | v1 |
| Terminal / git | cwd, repo, branch | fish hook on `PWD` change → `POST /att/cwd`; daemon reads `.git/HEAD` | trivial | v1.5 |
| T3 thread focus | environment, thread id, project, run active | daemon: focused window title matches T3 (desktop app `com.t3tools.T3Code`, or the Chromium app window with route `/threads/$environmentId/$threadId` [local: client bundle route strings]); thread → project via a read-only open of `statev2.sqlite` (`projection_threads.project_id`, `projection_projects.workspace_root`, `orchestration_v2_projection_runs.status` for "agent working") [local: schema] | medium: the desktop app's window title must be checked for thread name; SQLite is read with `immutable=1` on a copy to avoid WAL locks | v1.5 |
| Smart idle: media playing | MPRIS `PlaybackStatus=Playing` over D-Bus; PipeWire active output streams; browser `audible`; sway `inhibit_idle` on the focused node | daemon combines them into `attention=watching` (prior art: wayland-pipewire-idle-inhibit, sway-mpris-idle-inhibit [web]). Note `swayidle.nix` deliberately excludes audio from lock inhibition because music is a daemon [local]; here music-only does not count as watching, video does (window has `inhibit_idle` or a browser tab is audible *and* focused) | medium | v1.5 |
| Smart idle: agent working | T3 run `status` running / Claude process in the focused thread | `attention=supervising` while AFK and a run is active in the focused thread, capped (e.g. 45 min without input → away) | medium | v1.5 |
| Lock / lid / suspend | locked, suspended | logind `LockedHint`, `PrepareForSleep` | easy | v1.5 |
| Android app usage | package, app, category | Pollen: `UsageStatsManager.queryEvents` (needs `PACKAGE_USAGE_STATS` special-access permission) [web] | medium; Xiaomi background limits | v2 |
| Android browser URLs | url | aw-android does it with an accessibility service [web]; invasive, skip | low | later |
| Evening check-in | audio, transcript, tags | Pollen recorder + brain transcription (§4.5) | medium | v1 |
| Location | lat/lon/time | OwnTracks app → own MQTT/HTTP endpoint on the brain, or Pollen fused-location sampling; OwnTracks-shaped `location` bucket; Dawarich can import the same `.rec` [web] | medium; separate project seam | later |
| Calendar / meetings | events | not requested; the check-in covers "people encountered" | — | later |
| Keyboard/mouse intensity | counts | aw-watcher-input exists; marginal value | low | no |

---

## 7. Costs, privacy and threat model, publishability

### 7.1 Monthly cost at the owner's scale

Assumptions: 3 desktop-class devices + phone, ~10k merged events/device/day, batches every 15 min for ~4 buckets per device, one check-in audio (~1 MB) per day.

| Item | Estimate |
|---|---|
| S3 storage: ~1.5–2 MB/day compressed+encrypted total → ~60 MB/month, cumulative | < $0.02/month in year one; $0.25/month at 10 GB |
| S3 requests: ~1,200 PUT/day + listings (~300/day) → ~45k/month | ≈ $0.20 |
| Egress S3 → home (peacelily pulls everything once) | ~60 MB/month: $0.01 |
| KMS (only with the shadow profile) | $1 |
| CloudFront shadow (optional) | $0 on the Free flat-rate plan (1M requests, 100 GB) [web] |
| Cognito (optional) | $0 under 10k MAU [web] |
| Lambda presigner (optional) | $0 (free tier: 1M requests, 400k GB-s) [web] |
| **Inference** | **$0**: peacelily electricity (a 5060 Ti under sustained inference ≈ 150–180 W; a Sunday review of 10 min ≈ 0.03 kWh) |
| Cloud GPU profile when used | g6.xlarge spot ≈ $0.36/h, on-demand ≈ $1.01/h (eu-central-1) [web]; a weekly 20-min review on spot ≈ $0.50/month; a travel week with 2 h/day of chat on-demand ≈ $14 |
| Tailscale, domain | $0 (existing tailnet; no public domain needed in the home profile) |

Home profile total: **about $0.25/month**. Shadow profile: about $1.50/month. The original brief's serverless brain (Lambda + managed model) is gone; its biggest line (commercial model tokens, ~$10–15/month) is zero by constraint.

### 7.2 Threat model

Data classes: (A) raw titles/URLs/cwds (most sensitive: everything the owner reads), (B) check-in audio and transcripts (personal: feelings, people, places), (C) rollups and narratives (sensitive but aggregated), (D) intentions (personal).

| Adversary | Exposure | Mitigation |
|---|---|---|
| AWS account compromise | (A)(B) unreadable (age; keys never in AWS in the home profile); (C)(D) only if the shadow exists | per-device IAM credentials are PUT-only on their own prefix; shadow is opt-in; KMS + Cognito on it |
| Stolen laptop / phone | the local journal (A) for up to 30 days; phone drafts (B) | laptops are LUKS; Pollen stores in app-private storage; the phone uploads and prunes |
| Third-party model provider | none by constraint | enforced by code test + egress firewall + config placement (§4.4, §4.6) |
| Another tailnet device compromised | the brain's HTTPS surface | Tailscale ACL tags (planned [local: tailnet-as-code plan]) restrict who can reach `tag:gpu`; bearer tokens on MCP |
| The owner's own future self | the review nudging behaviour the owner did not want | reviews are drafts; corrections are events; nothing is deleted silently |
| Public repo leak | project names, rules, hostnames | rules and taxonomies live in nixconf secrets / a private overlay; the repo ships examples only; the existing public-repo hygiene rules apply |

### 7.3 Publishability

What a stranger needs: an OpenAI-compatible **open-model endpoint they are happy with** (llama-swap/Ollama on a 16 GB GPU or an Apple Silicon Mac, a GPU VPS, or a managed host if they accept it), a Whisper HTTP endpoint (or the brain's bundled whisper.cpp), a place for batches (S3 **or** a local directory **or** direct push to the brain over LAN/Tailscale: the uploader's sink is an interface), and ActivityWatch watchers for their desktop (the AW ecosystem does the collection work for every OS). Profiles, in the spirit of routelab's `tfc`/`selfhost` [local: `alchemy.run.ts`]: `home` (brain on a home box, batches in S3 or local), `cloud-gpu` (Alchemy-managed GPU box + S3), `single-box` (everything on one laptop, no sync). The published artefacts: the batch format spec, the Rust daemon binary (also a plain GitHub release, no Nix required), the brain as a container image and a NixOS module, the PWA.

---

## 8. Risks and consequences, ranked; rejected alternatives

1. **Collection gaps make reviews hollow** (the ActivityWatch experience). Wayland fragility, a browser extension that silently stops, T3 focus misattribution. Mitigation: a coverage number on every screen; the daemon reports its own heartbeat; the review states coverage first.
2. **The human side of the loop fails** (no check-ins, intentions left empty). Mitigation: 60-second voice check-in with three fixed prompts; nudges; the review tolerates missing days and says so.
3. **Open-model quality for the review** (correlating intentions, time and feelings across 7 days in 20–60k tokens). Qwen3.5-9B with thinking and a strongly structured prompt (tables in, checklist out) is the baseline; gpt-oss-20b or Qwen3.5-35B-A3B are the upgrade path; keeping audio and raw means every review can be regenerated with a better model later. Expect to iterate the prompt for a month.
4. **Effect v4 churn**: `ai`, `eventlog`, `McpServer`, `McpClient` are unstable/experimental [local]. Mitigation: exact pins (as routelab does), a small adapter layer around `LanguageModel`, no `eventlog`.
5. **Three implementations of the batch format** drift. Mitigation: `spec/` vectors in every CI leg; uniffi later collapses Kotlin into Rust.
6. **GPU contention on peacelily**: Whisper resident + chat model + OpenCode's coding model (`qwen3.5:9b-coding` with 64k context) compete for 16 GB. Mitigation: llama-swap groups, `ttl`, schedule the review at night, and accept that an OpenCode session may evict the chat model.
7. **peacelily off = no chat, stale reports**. Mitigation: devices keep uploading; the PWA shows the last snapshot; the shadow profile covers reports; the cloud-GPU profile covers travel. Honest limit: no model boundary-compliant chat without a GPU somewhere.
8. **Xiaomi background restrictions** on Pollen's collector and uploads. Mitigation: read the OS usage log in a periodic job; upload opportunistically; show "last upload" in the app.
9. **Privacy of derived data in the shadow**. Mitigation: no raw titles in `derived/`; KMS + Cognito; off by default.
10. **Scope creep** into the inbox and location projects. Mitigation: the two seams in §2.4; location is a bucket type and nothing else until its own design.

Rejected alternatives, briefly:

- *Effect `eventlog` as the sync*: unstable, replicate-everywhere, compaction in memory, Kotlin reimplementation (§4.2).
- *aw-sync / Syncthing folder*: no deletions, duplicates, Android layout gap (§4.2).
- *Remote ActivityWatch server*: unauthenticated, no HTTPS, explicitly discouraged by the project [web: AW remote-server docs].
- *Brain in Lambda with a commercial model*: excluded by constraint; and Lambda cannot host a 20B model.
- *Native Compose chat UI in Pollen for v1*: duplicates the PWA; Pollen stays a sensor and recorder.
- *Screenpipe-style continuous screen/audio capture*: far more invasive than needed; its MCP-as-sensor idea is borrowed in spirit [web].
- *Exist.io-style automatic correlations*: the owner wants a narrative against *intentions*, not a correlation matrix; Exist's "check two consecutive days" rule is worth copying for mood vs. late-night correlations [web].
- *Cloudflare (R2 + Workers) instead of AWS*: viable and cheaper for the shadow, but the owner's Alchemy/AWS muscle and the planned GPU box are on AWS; revisit only if the shadow becomes central.

---

## 9. Phased roadmap

Each milestone is independently useful.

**M0: one honest week (2–3 weeks of work).** awatcher + aw-watcher-web + aw-watcher-vscode on hazel and butternut, pointed at `att-daemon` (ingest, SQLite journal, sealer, age, S3 upload). Brain on peacelily: puller, DuckDB, rule-based labels, rollups, a minimal PWA (Home, Day, Intentions, Week) on the tailnet, Sunday review via Qwen3.5-9B. Check-ins recorded with Pollen's existing dictation keyboard into a note (no new screen yet), transcribed on butternut, pasted into the PWA. Output: the first review the owner reads on his phone. Infra: Alchemy stack with one bucket and two IAM users.

**M1: the check-in and the chat (2 weeks).** Pollen check-in screen + batch writer + uploader; brain transcription (multilingual Whisper on peacelily); `Ask` page with Effect `Chat` + Toolkit over DuckDB on gpt-oss-20b; MCP server with token policy; OpenCode `attention` agent in nixconf; nudges via ntfy.

**M2: attention that is honest (2 weeks).** Media-aware idle (MPRIS, PipeWire, audible, inhibit_idle), T3 focus and "supervising", shell cwd → repo/aspect, corrections UI, coverage metrics, the `media.consumed` export and the SSE seam.

**M3: phone usage and resilience (2 weeks).** Pollen usage-stats collector; shadow profile (CloudFront + Cognito + KMS, read-only reports); daily digest; waybar glyph.

**M4: away from home (1–2 weeks).** Cloud-GPU profile (fern-style box with `ai-server` + `att-brain`, auto-stop), measured latency from Egypt; direct-push sink for home LAN.

**M5: publishable (ongoing).** `spec/` and docs, `single-box` profile, Rust binary releases, container image, uniffi core into Pollen, mac/win daemon targets, location bucket.

---

## 10. Open questions only the owner can answer

1. **Week boundary and review time**: Monday→Sunday with a Sunday-evening review, or the Egyptian Sunday→Thursday work week with a Friday review?
2. **Check-in language**: English, Arabic, or mixed? It decides the Whisper configuration on peacelily (the current Wyoming server is English-only) and whether Parakeet's live preview is useful.
3. **Taxonomy v0**: the initial list of areas, projects and aspects (routelab: mobile / dashboard / devops; d_abm: ?; nixconf; reading; admin; TfC management?). Rules need it on day one.
4. **Managed open-weight hosting**: is a provider that runs open models (Bedrock's managed open-weight models, Together, Fireworks, etc.) acceptable as a fallback when peacelily is off, or is "self-run only" the rule? The design works either way; it changes M4.
5. **Shadow profile**: is a read-only copy of rollups and reviews (no raw titles) in AWS acceptable, for availability when home is down? If not, M3 drops it and "peacelily off" means "reports unavailable".
6. **Which AWS account** (personal vs. TfC) and region (eu-central-1 as stated, or me-central-1 for latency from Cairo, which the agentic-workspace design already planned to measure)?
7. **Raw data retention**: forever (the owner's wish for history) or a horizon? It affects nothing technical today, only the bucket lifecycle rule.
8. **Phone chat path**: PWA only, or also T3's Android app driving an OpenCode thread on peacelily with the local model? The latter needs the T3 server on peacelily (agent-host role) and is "free" once that exists.
9. **Pollen placement**: keep Pollen in nixconf and consume `android/tracker-lib` from the tracker repo (recommended), or move Pollen out?
10. **Name** of the project and repo, and the licence for publishing (AW is MPL-2.0; the model is copied, not linked, so any licence works; Apache-2.0 or MIT recommended for a community project).
11. **Location**: OwnTracks app now (independent of this project, writing to a bucket), or wait for the location project's own design?
12. **GPU sharing policy on peacelily**: may the tracker's chat model evict an OpenCode coding model mid-session, or does coding have priority (llama-swap groups)?

---

## Appendix A: sources

Local: `modules/nixos/features/{activitywatch,agent-t3code,agent-common,agent-opencode,ai-server,dictation,dictation-server,swayidle}.nix`; `modules/{hosts-registry,dictation-models}.nix`; `modules/packages/phone-app.nix`; `apps/phone/**`; `docs/plans/2026-11-17-{t3code-integration,agentic-workspace-design,backlog}.md`, `2026-11-22-phone-dictation-keyboard-design.md`, `2026-11-23-phone-pollen-identity.md`, `2026-03-28-peacelily-ai-server-design.md`, `2026-11-24-peacelily-bring-up.md`; `~/.t3/userdata/statev2.sqlite` schema; T3 0.1.9 client bundle route strings; routelab `infra/stack/{alchemy.run.ts,src/serverless/{index,Lambda,FrontDoor}.ts,src/Web.ts,package.json}`, `pnpm-workspace.yaml`, `packages/tiles/src/lambda.ts`, `docs/plans/2026-10-28-*.md`; Effect 4.1.1 `src/ai/{McpServer,McpClient,LanguageModel,Chat,Toolkit,Model,OpenAiStructuredOutput}.ts`, `src/eventlog/*`, `src/workflow/Workflow.ts`.

Web: ActivityWatch docs (buckets-and-events, REST API, remote-server), aw-server-rust and aw-sync README, awatcher README, aw-android (0.14.3, 2026-10), crates.io `aw-models`; nixpkgs 26.05 via the nixos MCP (`awatcher 0.3.1`, `aw-server-rust 0.13.2`, `duckdb 1.5.2`, `cargo-ndk 4.1.2`, HM `services.activitywatch.*`); npm registry (`@effect/ai-openai` 4.1.5, `@effect/ai-anthropic` 4.1.5, `@effect/sql-*` 4.1.5, no `@effect/sql-duckdb`); effect.website v4 API docs (`OpenAiClient`, `OpenAiLanguageModel`); llama.cpp server docs and PR #21174 (`/v1/responses`), function-calling docs (`--jinja`); DuckDB blog 2026-09-18 (Wasm + OPFS), tobilg duckdb-nodejs-layer; AWS pricing pages and CloudFront flat-rate plans (Nov 2025), KMS, Cognito Essentials passkeys, Bedrock managed open-weight models and data-protection statements; doit.com EC2 spot/on-demand pages for eu-central-1 g5/g6; local-LLM 16 GB guides (gpt-oss-20b, Gemma 4, Qwen3.5/3.6); Qwen3-ASR technical report and GGUFs, Voxtral announcement, Whisper Arabic fine-tunes; `age`/`rage`, `age-kmp`, `kage`; wayland-pipewire-idle-inhibit, sway-mpris-idle-inhibit; Screenpipe, Exist.io, Dawarich, OwnTracks; Open mHealth / IEEE 1752.1, LIFE format.
