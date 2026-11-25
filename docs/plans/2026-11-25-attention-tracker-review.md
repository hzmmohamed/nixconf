# Review: attention tracker design (2026-11-25)

Reviewed: `docs/plans/2026-11-25-attention-tracker-design.md` (authoritative) and
`docs/plans/2026-11-25-attention-tracker-research.md`. Context read: `CLAUDE.md`,
`modules/nixos/features/{ai-server,activitywatch,agent-t3code,agent-common,agent-opencode,chromium,sops}.nix`,
`.sops.yaml`, `modules/hosts-registry.nix`, `modules/nixos/hosts/{peacelily,hazel,butternut}/disko.nix`,
`docs/plans/2026-11-24-peacelily-bring-up.md`, `apps/phone/` (DraftStore, WavWriter, Recorder),
Effect 4.1.1 sources (`ai/McpServer.ts`, `ai/LanguageModel.ts`, `ai/Model.ts`, `crypto/`, `sql/`,
`http-api/`, `eventlog/`), routelab `infra/stack` (Alchemy 2.0.0-beta.85, effect 4.1.1 pinned exactly).
Web: age spec (c2sp.org/age), typage README, DuckDB 1.4 encryption post, `@duckdb/node-api` /
`duckdb-bun`, bun2nix docs, `@effect/platform-bun` v4 API docs, LibreChat MCP + data-retention docs,
OwnTracks HTTP booklet, age-kmp / kage / age-kotlin, Android Keystore. Verified on butternut:
`kernel.yama.ptrace_scope = 1`.

## Verdict

The product shape is right and the storage decision (sealed, append-only, age-encrypted batches in S3,
one brain that pulls) is the correct one for the four non-negotiables. The design does **not yet
achieve** constraint 2 (no plaintext at rest) and constraint 4 (capture independent of the brain) in
three places, and it has one key-management hole that defeats the whole encryption story on the
current fleet: the sops primary key sits in the owner's home on hazel and butternut, where
commercial-model agents run as the same user, and `.sops.yaml` encrypts every `secrets/**` file to it;
if the brain's age identity and S3 read credentials go into sops as written, any agent on hazel can
decrypt the entire archive. A second structural hole is that Tailscale identity is the only auth for
the PWA and API, and every agent on hazel or butternut *is* that identity. Third, the local queue as
specified (one open age stream, last heartbeat only in memory) is not crash-safe: the age STREAM
format rejects a stream without its final chunk, so a daemon crash does not lose "the in-memory tail",
it loses the whole open segment plus the open span. All three are fixable without changing the
architecture; the fixes are specified below. The Effect/Bun/Kotlin stack is viable with two
substitutions (`duckdb-bun` over libduckdb from nixpkgs instead of Node-API; the PWA's own Ask page
instead of LibreChat for M1). Recommendation: approve the architecture, require the blocker fixes to be
written into the design before M0 starts, and fold the bring-up's per-host sops key work (§3.2 there)
into M0's prerequisites.

## Findings

### Blockers

**B1. The sops primary key on agent hosts breaks the archive's confidentiality.**
Problem: `modules/nixos/features/sops.nix:17` sets `sops.age.keyFile = ${home}/.config/sops/age/keys.txt`
on every host; `.sops.yaml`'s catch-all rule encrypts `secrets/.*\.yaml` to `&primary` only; the
bring-up plan (§3.2) confirms every host holds the primary key today. Design §5.5 puts peacelily's age
identity and (implicitly) its S3 read credentials in sops. Any Claude Code / T3 / OpenCode process on
hazel or butternut runs as the owner's user, can read `keys.txt`, decrypt `secrets/peacelily/*.yaml`
from the working tree, obtain the brain identity plus S3 reader credentials, and read and decrypt
`raw/`. That is a commercial-model agent with the full plaintext archive one `sops -d` away.
Why it matters: it voids constraint 1 and 2 at once, silently, and the design's threat model (§6)
does not list it.
Fix: (1) the brain's age identity is **never in the repo**: derive it from peacelily's SSH host key
(`ssh-to-age`, exactly as fern does: `modules/nixos/hosts/fern/configuration.nix:79`
`sops.age.sshKeyPaths`), or generate it on peacelily and back up the private half only in the
KeePassXC vault; devices receive the *public* recipient. (2) The brain's S3 reader credentials live in
`secrets/peacelily/attn.yaml` encrypted to peacelily's host key **and an offline admin key only**,
never to the primary key that is deployed on agent hosts. (3) Do bring-up §3.2 (per-host keys) before
the brain exists, and plan the move of the primary key off hazel/butternut (a second non-agent Unix
user for secret editing, or a hardware-backed age plugin). Add this chain to §6.

**B2. Tailscale identity is not a second factor; agents on hazel/butternut hold it.**
Problem: §6 "Tailscale identity is the auth for the PWA" and R §4.7 (`Tailscale-User-Login` header).
There is one tailnet user. Every process on hazel and butternut, including commercial-model agents,
presents that identity to `tailscale serve`. The brain's HTTP API would therefore hand rollups,
timelines, check-in transcripts and locations to any agent that issues an HTTP request to
`https://peacelily.<tailnet>.ts.net/api/...`. The MCP token is protected (§5.7); the plain API is not.
Fix: the PWA and API authenticate a *browser/session*, not a host: a WebAuthn passkey registered
once per browser (phone, hazel Chromium), or a long-lived session token minted by `attn session issue`
on peacelily and pasted into the PWA once. Tailscale ACLs remain the network gate. The OwnTracks
endpoint gets its own basic-auth secret. T3's agent browser (`browserCookieImport = false`,
`agent-t3code.nix:64`) does not share the owner's Chromium profile, which is why cookie-based
sessions work here. Write the rule: "no endpoint of the brain answers on Tailscale identity alone".

**B3. The queue is not crash-safe as specified.**
Problem: §5.3 "Events are appended to an open age stream segment on disk; only ... the last event per
bucket ... is in memory ... a crash loses at most the in-memory tail." Two errors. (a) The age payload
is a STREAM of 64 KiB chunks with a final-chunk flag; the spec says "Streaming decryption MUST signal an
error if the end of file is reached without successfully decrypting a final chunk" (c2sp.org/age).
`age-encryption` follows it. A segment whose writer died is therefore undecryptable in full, and the
daemon cannot repair it (it has no private key). (b) With aw-server's heartbeat merge, the "last event
per bucket" is the whole open span: if the owner sits in one window for three hours, that is three
hours in memory. Both losses happen on every crash, OOM kill, or hard power-off.
Fix: see (d). In short: a **frame log** (each flush is an independently decryptable age file with a
length prefix; a truncated trailing frame is dropped), plus **progress checkpoints** (the open span is
re-emitted every N seconds with the same ULID and a growing duration; the brain keeps the last record
per id). Bounded loss = N seconds, no unreadable segments.

### Major

**M1. Batches are confidential but not authentic.**
Age to public recipients does not authenticate the writer, and the recipients are public by
construction. Per-device IAM keys sit in the user's home on agent hosts (same user as the agents) and
on a phone. Anyone with them can PUT forged batches into `raw/<device_id>/` (the brain would ingest
them as truth) or fill the prefix. Separately, the owner's AWS SSO cache (`~/.aws/sso/cache`, feature
`aws.nix`) is readable by agents, and the admin role can `DeleteObject` on the archive.
Fix: per-device **signing key** (ECDSA P-256: hardware-backed in Android Keystore, WebCrypto-native on
Bun, `effect/crypto/Signature.ts`), signature over the ciphertext's SHA-256 stored as a plaintext
sidecar object or trailer; the brain verifies against an enrolled-devices list **before** decrypting
and quarantines failures. Enable **versioning + Object Lock** (governance mode, long retention) on the
raw bucket, or put it in an account/role the day-to-day SSO permission set cannot delete from. Device
credentials and signing keys are owned by the daemon's system user (M2), not the owner's home.

**M2. The daemon on hazel/butternut shares a Unix user with commercial-model agents.**
See (a) for the full exposure list and mitigation set. Headline: split the daemon into a *system*
service (`User=attn`, queue, keys, upload; no access for the owner's user) and a small *session*
sensor (D-Bus/MPRIS/PipeWire/sway IPC; holds only the current state); make the AW API ingest-only
(no `/export`, no event GETs); rely on `kernel.yama.ptrace_scope = 1` (already the case on butternut)
for the session sensor's memory. The design currently says "a user service ... the daemon holds only
the recipients' public keys", which protects the queue but not credentials, the signing key (M1), or
the in-memory state, and leaves `/export` as a free read of everything not yet sealed.

**M3. Location capture depends on the brain (constraint 4).**
§5.4: OwnTracks in HTTP mode posts to the brain's `/owntracks`. OwnTracks queues offline (the booklet
confirms it) but its outgoing queue is bounded (default length 100 in the app's logs; location
messages retried up to 10,000 times) and its queue is plaintext in app storage. A week of peacelily
being off (the §11 scenario) loses or stalls location, which §2 lists as an anti-goal.
Fix: location is collected by **Pollen** (fused location provider, batched like `android.app`) into
the same signed, encrypted queue; OwnTracks-to-brain is acceptable only as an M3 stopgap and the
design must say that it violates constraint 4 while it lasts. If OwnTracks is wanted for its battery
tuning, the receiver can be a tiny Alchemy-managed Lambda (Bun custom runtime) that age-encrypts to the
recipients and PUTs into `raw/owntracks/`: AWS up ≠ brain up, and plaintext exists only in Lambda
memory. Prefer Pollen.

**M4. LibreChat cannot satisfy constraint 2 as deployed; the Nix assertion is the wrong guard.**
LibreChat stores conversations, messages and shared links in MongoDB as plain documents
(librechat.ai data-retention docs; `CREDS_KEY`/`CREDS_IV` encrypt only stored credentials). peacelily is
plain ext4 (`hosts/peacelily/disko.nix`; bring-up §3.3 recommends no LUKS), so every chat about the
data is plaintext at rest. Meilisearch (if ever enabled) and the uploads directory would add two more
plaintext copies. Also, peacelily is slated to become an `agent-host` (registry roles
`["server" "agent-host" "gpu"]`, bring-up §3.6), so (c) applies to the brain host too. The proposed
assertion only sees Nix config: LibreChat also enables built-in endpoints from env keys and lets users
paste their own keys (`user_provided`), neither visible to an assertion on `settings.endpoints`.
Fix: see (h). M1 ships **Ask in the PWA** (Effect `Chat` + `Toolkit` over llama-swap, history in the
encrypted DuckDB). LibreChat is optional and only with: MongoDB `dbPath` on an encrypted volume
(LUKS loop file or `systemd-cryptsetup` keyed from sops), `temporaryChatRetention` at a few hours,
search off, uploads off, and the LibreChat unit sandboxed with `IPAddressDeny=any` +
`IPAddressAllow=127.0.0.0/8 100.64.0.0/10`. The network sandbox, not the assertion, is the guard; keep
the assertion as a tripwire.

**M5. The phone's audio path contradicts both the encryption rule and Pollen's existing code.**
§5.4 "check-in audio streamed into an age file while recording". Pollen's `WavWriter` uses
`RandomAccessFile` and patches the RIFF sizes at close (`audio/WavWriter.kt:60`), which needs seeking;
an age stream cannot be patched, and (B3) a recording interrupted by Xiaomi killing the app is
undecryptable. `DraftStore` keeps `audio.wav` plaintext in `filesDir` (`drafts/DraftStore.kt`).
Fix: record **raw PCM s16le 16 kHz frames** into the same frame log as everything else (each frame an
age file; no container; `checkin.audio.data` carries `sample_rate`, `channels`, `format`,
`frame_count`); the live preview reads from the in-memory ring buffer; check-ins never go through
`DraftStore`. Whether Android FBE already satisfies "not plaintext at rest" is an owner question (Q1).

**M6. The at-rest inventory on peacelily is incomplete.**
Beyond DuckDB: (1) **core dumps**: `systemd-coredump` writes process memory (plaintext data, keys) to
`/var/lib/systemd/coredump` on crash: set `systemd.coredump.enable = false` or `LimitCORE=0` on the
daemon and brain units, and `ProtectProc`/`PrivateTmp`. (2) **journald**: the brain and LibreChat must
not log request paths with titles/URLs; use Effect's logger with `Redacted` and a tracking-data-free
log policy; test it. (3) **STT temp files**: whisper.cpp's HTTP server and Wyoming implementations may
write the uploaded audio to a temp file; give the STT unit `PrivateTmp=true` on tmpfs
(`boot.tmp.useTmpfs` is false on this fleet) or feed audio over stdin. (4) **DuckDB**: 1.4+ encrypts
the main file, WAL and temp files for an encrypted database (duckdb.org 2025-11-19 post), but the
default in-memory database spills unencrypted: never use `:memory:` for real data, set
`temp_directory` on tmpfs anyway, and pass the key via a prepared `ATTACH` with statement logging off.
(5) **Parquet snapshots** of L4 (R §3.4 "to S3 derived/") are plaintext rollups: drop them or use
Parquet modular encryption. (6) **Swap**: hazel/butternut use zram (RAM-backed; confirm no writeback
device); peacelily has none. (7) **PWA offline cache**: the service worker caches derived JSON in the
browser's storage (plaintext on the phone, OS-encrypted). Decide whether that passes (Q1).

**M7. Corrections target derived ids.**
§5.2 `correction {target_event_id ...}` where the target is an L2 span (R §2.2 "tap a segment").
L2 spans are rebuilt from raw and their ids are not stable across rebuilds or decoder changes.
Fix: corrections address **(device_id, time range)** plus the op (`relabel`, `split at t`, `break`,
`tombstone`), and optionally the raw event ULIDs as hints. Replay is then well-defined.

**M8. Model binding choice.**
§5.5 prefers `@duckdb/node-api` under Bun's Node-API with `duckdb-bun` as fallback. Flip it:
`duckdb-bun` dlopens `libduckdb` via `bun:ffi`, so the library can come from nixpkgs `duckdb` 1.5.2
(same major as the Node-API package), no Node-API surface, no prebuilt bindings to patchelf, one
fewer bun2nix special case. Keep `@duckdb/node-api` as the fallback. There is no `@effect/sql-duckdb`;
write a thin `DuckDb` service (see g).

### Minor

- **m1.** §5.5 "rules and taxonomy are data, not config ... never in nixconf" vs §5.9 "private rules
  ... live in nixconf". Pick the first; nixconf holds only the bootstrap list if anything.
- **m2.** S3 key names leak metadata to AWS: device id, bucket id (`aw-watcher-web_hazel`), seal
  cadence. Acceptable, but say so; or use an HMAC of the bucket id in the key.
- **m3.** `If-None-Match: *` on PutObject exists since 2024; Bun's built-in S3 client may not expose
  the header. Builder note: use `@distilled.cloud/aws` or raw SigV4 if not.
- **m4.** The frame/batch `date` in the key must be defined (UTC seal date) to make the brain's
  cursor deterministic.
- **m5.** `t3.meta` snapshots thread titles; fine (encrypted), but the brain must not echo them into
  rollup names that reach the shadow or logs.
- **m6.** The `media.consumed` seam exports to the inbox project: state that the model boundary
  travels with the data.
- **m7.** The `shell.cwd` hook's "skip agent shells by env markers" is advisory (agents can unset
  env); harmless, since pollution is the only risk, but say so.
- **m8.** Android Keystore Ed25519 is recent; use P-256 for the phone's signing key (and everywhere,
  for one code path).
- **m9.** §5.7 "MCP token exists only in LibreChat's config": LibreChat's `librechat.yaml` is built by
  Nix into the store (`services.librechat.settings`), world-readable. Pass the token through
  `${ENV_VAR}` from a sops env file instead.
- **m10.** R §4.6's "refuse clientInfo.name matching claude*" tripwire is fine as logging, not as a
  control; do not describe it as one.

## Answers to the open points

### a. Daemon next to commercial-model agents on hazel/butternut

What remains exposed with the design as written (user service, public keys only):

| Exposure | Agent can... | Severity |
|---|---|---|
| `GET /api/0/buckets/<id>/events`, `/export` on 127.0.0.1:5600 | read everything not yet sealed, plus whatever the daemon caches for the API | high |
| In-memory state (last event per bucket, upload buffers) via `/proc/<pid>/mem`, ptrace | blocked by `ptrace_scope=1` for non-descendants (verified on butternut) unless CAP_SYS_PTRACE; agents are denied `sudo`/`doas` only by a Claude settings deny list | medium |
| Per-device IAM key + signing key in the user's home | forge or flood batches (M1) | high |
| sops primary key in the user's home | B1 | critical |
| `systemctl --user` on the daemon unit; unit files, env files | stop, replace, or wrap the daemon (pollution/DoS, and a MITM of watchers) | medium |
| Watcher traffic (loopback HTTP, plaintext) | sniff with `tcpdump` needs CAP_NET_RAW (no); otherwise only by MITM above | low |
| Fish cwd hook | only in interactive shells; posts cwd; nothing to steal | low |
| T3 agent browser / any process can POST to :5600 | pollute buckets | low |

Mitigation set (recommend all):

1. **Two processes.** `attn-daemon` as a **system** service (`User=attn`, `StateDirectory=attn`,
   `ProtectHome=yes`, `PrivateTmp`, `NoNewPrivileges`, `LimitCORE=0`), owning the queue, the IAM
   credentials (`sops.secrets.*.owner = "attn"`), the signing key and the uploader. `attn-sensor` as
   the user's session service (needs the session bus for MPRIS, PipeWire, sway IPC, swaylock, T3
   store), stateless, posting to the daemon like any watcher. The sensor's memory is protected by
   `ptrace_scope=1`; set it explicitly in nixconf (`boot.kernel.sysctl."kernel.yama.ptrace_scope" = 1`)
   so it survives a kernel config change.
2. **Ingest-only API.** Keep `GET /api/0/info`, `GET/POST /buckets/<id>` (metadata), `POST events`,
   `POST heartbeat`. Drop `/export` and `GET events` entirely. Watchers never read events; awatcher,
   aw-watcher-web and aw-watcher-vscode only create buckets and post. This removes the biggest leak
   and matches "write but never read back" that §5.3 already claims for the queue.
3. **Listener.** Loopback TCP :5600 must stay for aw-watcher-web (a Chromium extension cannot use
   Unix sockets or inject auth headers) and awatcher. Bind it as the system service; check the
   `Origin` header for the pinned extension id (`chromium.nix`: `nglaklhklhcoonedhgnpgddginnjdadi`)
   and a per-host **watcher token** for everything that can send one (sensor, fish hook, vscode via
   its settings). This is pollution control, not confidentiality; say so.
4. **Rate and sanity limits** on ingest (events/min per bucket, bucket count), so a hostile local
   process cannot flood the archive.
5. **Agent deny rules** in `agent-common.nix`: deny `Bash(curl*5600*)`, `Bash(systemctl --user *attn*)`
   and reading `/var/lib/attn`. These are courtesy fences (Claude settings only, not OpenCode/T3), not
   controls; the system user is the control.
6. **Keys out of `$HOME`** (B1, M1): the agent-reachable home holds nothing that decrypts or signs.

### b. The "change" axis: outcome evidence

Yes, collect it, locally, without any API credential:

- A `git.activity` watcher inside the **daemon** (not the fish hook): for every repo the `shell.cwd`
  and editor watchers have seen, every 10 minutes run `git log --since=<cursor> --author=<owner
  emails> --format=%H%x00%ct%x00%P%x00%s --numstat` and `git for-each-ref --merged <default>` after
  the user's own fetches (never fetch from the daemon). Events: `{repo, sha, parents, branch,
  subject, files, insertions, deletions, merged_into_default: bool, co_authors}`. Co-authored
  (agent) commits count as the owner's; record the trailer so the review can say "12 commits, 9 with
  an agent".
- "Merged PRs" are inferred from the local default branch (`--merged` after the owner's next pull),
  not from GitHub. No token leaves the device, no network dependency. If the owner wants PR titles,
  add an *optional* device-side `gh pr list --author @me --state merged --json` run with the
  existing `gh` auth on the host, output encrypted like any bucket; the brain never holds a GitHub
  token.
- T3 outcomes: `t3.meta` already snapshots runs; add thread `status`/`completed_at` so "ship X"
  intentions can cite finished threads.
- Boundary: this is all inside the device queue and the archive; it crosses nothing. Commit subjects
  from work repos are sensitive (owner question Q4).

### c. Brain on butternut while peacelily is delayed

Acceptable only as a **pull + DuckDB + PWA** brain, and only under the (a) conditions plus:
`attn-brain` as its own system user with the DuckDB key and S3 reader credentials readable by it
alone (sops `owner`), the age identity derived from butternut's host key and not shared with
peacelily later (two recipients from day one: butternut-brain, vault; peacelily added when it arrives,
with a one-time re-encrypt of the archive or simply accepting that pre-peacelily batches are
readable only via the vault key), API auth per B2, `ptrace_scope=1` (already), coredumps off, zram
without writeback, logs clean. butternut's RTX 3050 Laptop is a 4 GB-class part: Whisper turbo
already lives there for dictation; a 9B review model does not fit, a 4B labeller barely. So the
temporary brain cannot run the Thursday review, which is the point of M0. Recommendation: do not.
peacelily's bring-up is M0's first task either way; spend the delay on the daemon, the spec vectors
and the Alchemy stack, which need no brain. And note that peacelily will itself become an agent host
(bring-up §3.6), so the (a) measures are the brain host's measures too.

### d. Heartbeat merge vs encrypted append-only queue

"Only the last event per bucket in memory, flushed on change" is wrong twice (B3). Structure that is
correct and crash-safe:

- **Frame log.** A segment file is a sequence of frames: `[u32 len][age file]`. Each frame is a
  complete age encryption (header + payload) of a zstd-compressed NDJSON chunk (or a PCM chunk for
  audio). Frames are independently decryptable, so a truncated trailing frame is dropped and
  everything before it is intact. Per-frame overhead with two X25519 recipients is about 300 bytes;
  at one frame per minute per device that is nothing. `age-encryption` (typage) encrypts a
  `Uint8Array` or a `ReadableStream`; frames are small, use the array form. The batch uploaded to
  S3 is the segment file itself plus a plaintext trailer/sidecar with the manifest fields that are
  bookkeeping (device id, seq, frame count, sha256, signature). `events.ndjson`/`manifest.json`
  inside a tar is then unnecessary; drop tar.
- **Progress checkpoints.** The heartbeat merge keeps one open event per bucket in memory. Every N
  seconds (N = 60, configurable) write a *checkpoint* record for each open event: same ULID, current
  duration, `open: true`. When the event closes (data changes or pulsetime lapses), write the final
  record `open: false`. The brain keeps the last record per `(device, bucket, id)` by `(seq, frame,
  line)`. Loss on crash is bounded by N, and the log is idempotent.
- **fsync policy.** `fdatasync` on every frame; a frame is the unit of durability and of loss.
- **Seal.** Close the segment at 15 min / 1 MB / shutdown / `SIGTERM`; rename to `<seq>.sealed`; the
  uploader only touches sealed files; delete after a verified PUT (the brain's cursor is not needed
  for deletion since `If-None-Match` makes re-PUTs harmless).
- **Bookkeeping** (`seq`, upload state, cursors) in a tiny plaintext SQLite or JSON in
  `/var/lib/attn`: no tracking data, as the design already allows.

This is a simpler structure than the design's (no tar, no open stream, no "flush on change"
special case) and it is the same structure for desktop, phone and audio.

### e. Key management

- **Recipients**: brain identity (host-key-derived, never in git) + vault key (KeePassXC, offline).
  Two from day one; the phone and daemons carry both public keys.
- **Rotation**: age has no rekeying. Adding a recipient is forward-only. Compromise of the brain
  identity means `attn rekey`: download all, decrypt with the vault key on an offline machine,
  re-encrypt to the new recipient set, upload under a new generation prefix (`raw-g2/`), keep the old
  prefix under Object Lock until the retention passes. Document this runbook now; it is the only
  way to answer "what if peacelily's key leaks".
- **Enrolment**: `attn device enrol <name>` on peacelily (the brain is the registrar): creates the IAM
  user/key with the prefix-scoped policy via Alchemy, records `{device_id, signing_pubkey, iam_user,
  enrolled_at}` as a `device` event in the brain's own bucket, prints a one-time bundle (recipients,
  device id, IAM key) delivered over SSH/Tailscale, never pasted into a chat. The signing key is
  generated **on the device** (Keystore on Android, file owned by `attn` on desktops); only the public
  half travels.
- **Revocation**: `attn device revoke`: deactivate the IAM key (Alchemy or `aws iam
  update-access-key`), write `revoked_at`; the brain rejects batches signed after that time and
  quarantines (not deletes) anything already uploaded for review.
- **Stolen device**: queue unreadable (no private key on devices), LUKS on both laptops (both
  `disko.nix` files use LUKS), FBE on the phone; the thief holds a PUT-only key and a signing key
  until revoked. Signing + Object Lock bound the damage to junk you can filter by time.
- **S3 credential scoping**: `s3:PutObject` on `arn:…/raw/<device_id>/*` only; no `ListBucket`,
  no `GetObject`; deny `s3:PutObject` without `If-None-Match` via an `s3:if-none-match` condition
  if available in the region, else rely on Object Lock. The brain's reader: `ListBucket` +
  `GetObject` on `raw/*`, `PutObject` on its own prefixes (`location`, `rule`, `taxonomy`, `device`,
  `review`). Nobody has `DeleteObject`; versioning on; Object Lock governance.
- **DuckDB key**: 32-byte random, generated on peacelily, stored in sops encrypted to peacelily's
  host key + vault (B1), delivered to `/run/secrets` owned by `attn-brain`, read once, `ATTACH ...
  (ENCRYPTION_KEY ?)` with statement logging off, zeroised after use. Rotation: `COPY FROM DATABASE`
  into a new encrypted file under a new key; or simply drop derived layers and rebuild from raw
  (they are rebuildable by design, which makes key rotation trivial).
- **Recovery if peacelily dies**: new host, new host-key identity added as recipient, vault key
  decrypts history during `attn rekey` or the brain is given the vault key once, offline, to rebuild.
  The derived DB is not backed up; raw is the backup.

### f. Data structures

- **Batch format**: replace tar+zstd+age with the frame log (d). Keep NDJSON, ULIDs, per
  (device, bucket) `seq`, `If-None-Match: *`. Add the signature and a plaintext sidecar manifest with
  bookkeeping fields only. Add `format_version` per frame header, not only per batch.
- **ULIDs at ingest** are right, but with checkpoints the id must be minted when the span *opens* and
  reused by its checkpoints.
- **Derived layers L0..L5**: right. L4 Parquet snapshots to S3: drop (M6) or encrypt.
- **Corrections**: time-range addressed (M7). Add `applies_from_rebuild_version` so an old correction
  that no longer matches after a decoder change is reported, not silently dropped.
- **Rules/taxonomy as events**: right. Add an explicit `rule.order` and record `rule_id@version` in
  every L3 label so a label is reproducible.
- **Schema evolution**: AW's `type` string versioning plus per-frame `format_version` is enough.
  Keep every decoder forever (raw is forever).
- **Cross-device overlap**: primary/secondary per minute is fine. Define the tie-break by
  `attention` state first, then input activity; write it in `spec/`.
- **Over-built**: tar in the batch; the `/export` endpoint; the `shadow` profile's Parquet path at this
  stage. **Under-built**: authenticity, enrolment, the audio frame format, the correction address.

### g. Effect v4 architecture

Services (ports) as `Context.Service` classes, one `Layer` per implementation, production wiring in
`main.ts` only:

Daemon: `Clock`, `Journal` (frame log: `append(frame)`, `seal()`, `sealed(): Stream`), `Sealer`
(`age` recipients, zstd; `Redacted` keys), `Signer` (`crypto/Signature`), `Sink` (`put(key, body,
{ifNoneMatch})`; `S3Sink`, `DirSink`, `MemorySink`), `NetworkPolicy` (`agent-net` signal),
`Ingest` (heartbeat merge + checkpoints, `Ref` of open events), `AwApi` (`HttpApi` group:
info/buckets/events/heartbeat), `Sensors` (each a `Stream<Event>` scoped layer: MPRIS, PipeWire, T3,
cwd). Brain: `BatchSource` (`list(cursor)`, `get(key)`; S3 and memory), `Verifier` (signatures,
device registry), `Decrypter` (age identity, `Redacted`), `DuckDb` (a thin service over `duckdb-bun`:
`query`, `exec`, `transaction`, `withAppender`; `Scope`-managed connection; there is no
`@effect/sql-duckdb`, and `effect/sql` is unstable anyway), `Refinery` (rules → embeddings → LLM,
each a service), `ModelGateway` (the **typed boundary**: a `LanguageModel` layer built only from
`OpenAiClient.layer({ apiUrl })` where `apiUrl: AllowlistedUrl` is a branded `Schema` that only
parses loopback/tailnet hosts; `Model.ProviderName` fixed to `"llama-swap"`; a unit test that the
production layer graph contains no other `LanguageModel` provider), `Stt`, `Jobs` (`Cron` +
`Schedule`), `Api` (`HttpApi` + `HttpApiBuilder`, auth middleware per B2), `Mcp`
(`McpServer.toolkit` + `McpServer.middleware` bearer check, `layerHttp`), `Notifier` (ntfy).

Testing: `TestClock` for seal/checkpoint timing; `MemorySink`/`MemoryBatchSource` round-trips;
golden vectors in `spec/` consumed by a conformance test in Bun and Kotlin (the frames are tiny, so
vectors can include a truncated-frame case and a bad-signature case); DuckDB in a temp encrypted file
per test; `McpTest` for tool contracts; `LanguageModel` faked with a scripted layer for the review
job. Resource safety: every file, connection and HTTP server in a `Scope`; `Effect.acquireRelease` for
the DuckDB connection and the open segment; interruption-safe seal on `SIGTERM` via
`BunRuntime.runMain`. Unstable-module risk: `ai/*`, `http-api/*`, `sql/*`, `eventlog/*` are all
`@stability unstable` (checked in 4.1.1 headers); pin `effect`, `@effect/platform-bun`,
`@effect/ai-openai` exactly (routelab pins `effect@4.1.1`), keep the adapter surface to
`LanguageModel.generateText`/`streamText`, `Toolkit`, `McpServer.toolkit`/`middleware`/`layerHttp`,
and put those imports in one module per side so a bump touches one file.

### h. LibreChat

Can it satisfy constraint 2? Not as deployed (M4): plaintext conversations in MongoDB on plain ext4,
plus Meilisearch and uploads if enabled. It supports MCP (`mcpServers` in `librechat.yaml`,
`streamable-http` with headers and `${ENV_VAR}` substitution), so the integration works, but every
answer the model gives about the data is written to MongoDB. The Nix assertion is a tripwire, not a
guard: it cannot see `user_provided` keys typed in the UI or env-enabled built-in endpoints.
Options, in order:

1. **PWA Ask page** (recommended for M1): Effect `Chat` over `ModelGateway` with the same `Toolkit`
   the MCP server exposes; history stored in the encrypted DuckDB; tool calls shown per answer
   (R §2.2 already sketches it). Phone and desktop, one surface, no MongoDB, no second auth.
2. LibreChat with: MongoDB `dbPath` on an encrypted volume (LUKS loop file keyed from sops, or a
   LUKS data partition on a second disk), `temporaryChatRetention` 24 h and temporary-chat default,
   `SEARCH=false`, uploads disabled, MCP token via env from sops (m9), unit sandboxed to loopback +
   tailnet egress. Keep the assertion too. This costs a disk change on a host that is not yet
   redeployed.
3. OpenCode `attention` agent on the desktop pinned to `providers.peacelily` (R §4.6): OpenCode's
   session store is plaintext on an agent host; same problem, worse host. No.

### i. Other

- **Model boundary in the inbox seam** (m6) and in the "managed open-weight hosting" open question:
  write the rule as "open weights, run by the owner" vs "open weights, run by anyone"; it changes
  M4 and the publishability profiles.
- **GPU contention**: the design says "tracker and coding do not compete for the GPU" (§10) but both
  use peacelily's llama-swap; llama-swap groups/`ttl` resolve it, say which wins.
- **Coverage honesty**: add the daemon's own heartbeat bucket (`attn.health`) so "device on,
  nothing captured" is distinguishable from "device off".
- **Simpler**: once the frame log exists, "batch" and "segment" are the same thing; the spec shrinks
  to frames + sidecar + bucket types.

## Concrete edits to the design doc

1. §3: add "Key custody: no secret that decrypts or signs tracking data is ever readable by the
   owner's Unix user on an agent host; the sops primary key is not such a secret's recipient."
2. §5.2: replace tar+zstd+age with the frame log; add signature + plaintext sidecar; add checkpoint
   records; make corrections time-range addressed; add `format_version` per frame.
3. §5.3: split into `attn-daemon` (system user) and `attn-sensor` (session); ingest-only AW API (no
   `/export`, no event GETs); watcher token + Origin check; rate limits; `ptrace_scope=1` in nixconf;
   coredumps off; keys in `/var/lib/attn`.
4. §5.4: PCM frames for audio, no WAV, not via `DraftStore`; signing key in Keystore; location via
   Pollen, OwnTracks-to-brain marked as a constraint-4 exception if kept.
5. §5.5: brain as its own system user; identity from host key; DuckDB key via sops to host key +
   vault only; `duckdb-bun` first; at-rest inventory from M6; journald/coredump policy; drop Parquet
   to S3.
6. §5.7: M1 chat = PWA Ask; LibreChat optional with the M4 conditions; assertion demoted to tripwire;
   network sandbox is the guard; MCP token via env.
7. §6: rewrite with the chain in B1, the identity problem in B2, forged batches (M1), the agent-host
   future of peacelily, Object Lock/versioning, the `attn rekey` runbook, enrolment/revocation.
8. §7 M0: prerequisites = bring-up §3.2 (per-host sops keys), raw bucket with versioning + Object
   Lock, device enrolment.
9. §8: remove "which S3 client" from the builder list and add the `If-None-Match` requirement as a
   must; add "API session auth mechanism" with the two options from B2.
10. §9 risks: add "primary key on agent hosts" (until moved) and "Tailscale identity is one user".
11. Fix m1 (rules location) and m10 (tripwire wording).

## Questions only the owner can answer

- **Q1.** Does OS-level encryption at rest (LUKS on the laptops, FBE on the phone, the PWA's browser
  cache) count as "not plaintext", or must the application encrypt regardless? It decides whether the
  phone's queue and the PWA offline cache need application-level encryption and how strict M6's list
  is.
- **Q2.** Are you willing to move the sops primary key off hazel/butternut (edit secrets from a second
  non-agent user, a dedicated machine, or an age hardware plugin)? Without that, B1 is only partially
  fixed (brain secrets excluded from the primary key) and every other secret stays agent-readable.
- **Q3.** API auth: passkey per browser, or a pasted long-lived session token? (Both work; passkeys
  need WebAuthn in the PWA in M0.)
- **Q4.** May commit subjects and PR titles from work repositories (routelab, d_abm) enter the
  archive, or only repo/sha/branch/line counts?
- **Q5.** Location: Pollen-native collection in M3, or OwnTracks-to-brain now with the constraint-4
  exception written down?
- **Q6.** Chat in M1: PWA Ask page (recommended) or LibreChat with an encrypted MongoDB volume (a
  disk change on peacelily before its redeploy)?
- **Q7.** Raw bucket: Object Lock (governance mode, years) and a separate account or role your daily
  SSO permission set cannot delete from? That makes a mistaken upload permanent too.
- **Q8.** "Open weights" means run by you only, or also open-weight models on a managed host
  (Bedrock et al.)? It decides M4 and the published profiles.
- **Q9.** butternut's RTX 3050: the 4 GB or the 6 GB variant? Only matters if you still want a
  temporary brain there (c).
