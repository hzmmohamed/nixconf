# Photos: Immich, self-hosted, phone-first

Status: research, 2026-11-22. Nothing implemented. Input for a design/plan.
Backlog item: "Immich pilot locally on butternut (GPU for ML), then backup/host on
peacelily or cloud" (`2026-11-17-backlog.md`, Media & self-hosting).

**Legend.** ✅ checked in this session (command run, output seen) · 📄 upstream docs, release
notes or source · 🗣 community reports (may be stale) · ❓ my inference, not checked.

---

## What the user wants (restated)

1. One place for all photos (phone + scattered older ones), with a Google-Photos-grade UI on
   the phone and on the desktops.
2. Server at home on our own hardware; no cloud needed.
3. Phone works when the home server is unreachable, at least for **recent** photos.
4. Phone photos get to the server automatically (Immich's own backup, or Syncthing).
5. Open question: could a cloud/"serverless" deployment be cheaper or better?

## Verdict

**Immich, on peacelily once it's plugged in (butternut as an optional interim; see Answers),
from nixpkgs' NixOS module, upgraded to Immich 3.x. Reach it over
Tailscale. Back phone photos up with the Immich app, not Syncthing. Back up the library
off-site to cold object storage. Skip any cloud or serverless deployment.**

Two blockers before the pilot:

- **Disk.** ✅ butternut's only disk is a 2 TB NVMe at **93 % used (131 GB free)**. "Lots of
  storage" is not true today. Either reclaim the ~200 GB Docker cache (user-actions §6) or
  add a disk. Library size is the open question from user-actions §8.
- **Version.** ✅ The pinned nixos-26.05 nixpkgs ships **immich 2.7.5**. nixpkgs-unstable has
  **3.4.2**, and upstream released 3.4.1 on 2026-11-11. Start the library on 3.x (details
  below).

---

## 1. Immich today (Nov 2026)

- 📄 Releases: v3.0.0 (2026-07-01) → 3.3.x (Oct) → **3.4.1 (2026-11-11)**. v3.0 added
  mobile non-destructive editing, mobile slideshows, OCR, **Immich as the Android
  gallery/viewer app**, much more reliable Android background backup (periodic task
  scheduling), direct upload into albums, Workflows (preview automation: trigger → filter →
  action), an integrity checker (untracked/missing files, checksum mismatches), and smoother
  timelines on big libraries.
- 📄 v3 breaking changes: pgvecto.rs dropped (VectorChord only), API changes.
- 📄 **App/server compatibility:** a v3 app talks to v2 and v3 servers; a v2 app only talks to
  v2. The Play Store app auto-updates to 3.x, so a 2.7.5 server keeps working with it, but
  the server should not lag far behind the app.
- 📄 A native iOS app (SwiftUI on a shared Rust core) was announced 2026-11-20 as a proof of
  concept, "will ship with offline mode". **Android stays on the Flutter app**, with no
  date. This phone is Android, so this doesn't help yet.

### Not Immich?

| | Immich | Ente (self-hosted) | PhotoPrism |
|---|---|---|---|
| Phone app + auto backup | ✅ best in class | ✅ good | ❌ none official (web/PWA) |
| Faces, CLIP search, map, memories, sharing | ✅ | partial (on-device ML) | partial |
| Storage backend | local filesystem only | **S3 only** | local filesystem |
| End-to-end encryption | ❌ | ✅ | ❌ |
| Self-host weight | Postgres + Redis + ML, ~4–8 GB RAM | Go server + Postgres + S3 | light |

📄🗣 Immich is still the right call for "seamless, intuitive, everything". Ente only wins if
you want the server or cloud to never see plaintext, which doesn't apply on your own box.

## 2. Where it runs

| Host | Pros | Cons |
|---|---|---|
| **butternut** ✅ recommended | always on, AC, RTX 3050 (4 GB) for ML, 2 TB NVMe, already the tailnet's service hub (`tailscale serve` for T3) | disk 93 % full; also the build box, so ML jobs compete with builds (only during the initial import) |
| maple | always on, headless, idle | ❓ disk size unknown (offline during this session); no GPU; laptop SATA disk |
| peacelily | GPU AI server | not redeployed; heavier blast radius |
| fern / any EC2 | — | see §5 |

Split option, later and only if needed: run the Immich server and storage on maple, and ML on
butternut through Immich's **multiple ML URLs with fallback** 📄 (tries the URLs in order;
keep the local one last). This isn't needed for the pilot.

### GPU ML on NixOS

- ✅ nixpkgs has `services.immich.machine-learning.enable` and `accelerationDevices` (default
  `[]` = `PrivateDevices`), which runs `immich-machine-learning` as a native systemd
  service.
- 🗣 CUDA for the ML service needs `onnxruntime` built with CUDA, i.e. an override
  (`cudaSupport`) on `immich-machine-learning`. That's a long build, but it's on butternut,
  so it's fine. The fallback is CPU ML: the i7/Ryzen does a one-off index of ~50k photos
  overnight, and after that the load is trivial.
- ❓ 4 GB of VRAM fits the default CLIP and face models. Bigger multilingual CLIP models may
  not fit.

### Getting 3.x

The 26.05 module already handles VectorChord ✅ (`ps.vectorchord`, auto
`ALTER EXTENSION … UPDATE`). Options:

1. **Add a `nixpkgs-unstable` flake input**, use `services.immich.package =
   unstable.immich` (+ ML package). Risk: the 26.05 module may lag 3.x's env/config changes.
2. Same, but also swap the module: `disabledModules =
   ["services/web-apps/immich.nix"]` + import unstable's. This is the most correct, and
   it's the usual NixOS pattern.
3. Stay on 2.7.5 until 26.11 (≈ Dec 2026), then migrate 2→3. This means a v2→v3 migration
   on a real library, which is what we want to avoid.

→ **Option 2.** A fresh library starts on 3.x, and 26.11 later just drops the override.

## 3. Phone → server (backup)

**Use the Immich app's backup, not Syncthing.** Reasons:

- 📄 The app uploads into Immich-owned storage, dedups by checksum, and lets you pick which
  device albums (Camera, Screenshots, WhatsApp, …) to back up. It shows per-asset backup
  state in the timeline (cloud badge), and has **"Free up space"** with a date cut-off that
  only removes local copies the server already has.
- 📄 With Syncthing → external library, Immich only **indexes** the folder (read-only, picked
  up on rescan). You lose the backup-state UI and the safe "free up space", and running both
  gives **duplicates**.
- 📄 v3 fixed the main Android complaint (background backup that only ran when the app was
  opened). 🗣 What's left is the usual Android battery-optimisation killing. On HyperOS: set
  Immich to "No restrictions" for battery + autostart allowed.
- Syncthing keeps doing what it's good at (vault, Zotero, files). One phone-side sync agent
  for photos is enough.

Where Syncthing still fits: a **one-way "Phone backup" folder for non-gallery files**, or as
a belt-and-braces raw copy of `DCIM/Camera` to a plain folder on butternut that Immich
**doesn't** index. That's optional, and it's a backup, not a library.

## 4. Server → phone (access, offline)

**Online (home or away):** the phone already runs Tailscale. Publish Immich with `tailscale
serve` on a separate HTTPS port of `butternut.tail1a9f7c.ts.net` (same pattern as
`agent-opencode`). The app has **automatic URL switching** 📄: LAN URL on home Wi-Fi, tailnet
URL elsewhere. No public exposure. For sharing links with family later: `services.immich-public-proxy`
✅ exists in nixpkgs (exposes only shared links, not the app).

**Offline (server unreachable):** this is the weak spot.

- 📄 Photos **still on the phone** always show (the app merges local and remote in one
  timeline). Recent photos are on the phone anyway, so **"recent photos offline" is mostly
  free**, as long as "Free up space" uses a cut-off like "older than 6–12 months".
- 🗣 Remote-only photos: thumbnails are cached **lazily**, only ones you have scrolled past.
  Everything else shows blurry ThumbHash placeholders. The cache can also get evicted when
  you view full-size images. Keep "Prefer remote images" **off** (Settings → Advanced).
- 📄🗣 Full-library thumbnail prefetch is **not in Immich**. A PR (#31834: prefetch + a
  persistent cache, ~320 MB per 32k assets) was **closed unmerged**, and the feature request
  (#32763, Oct 2026) was closed as a duplicate. The native iOS app promises offline mode;
  Android has no date.
- Workarounds for "these specific albums offline": download an album's originals to the
  phone from the app (they become local assets), or keep a Syncthing folder of selected
  albums (Immich's storage template can lay out `library/` by album; ❓ check it isn't
  confusing with dedup).

→ Recommendation: **phone keeps the last ~12 months locally, and everything older lives on
the server.** That covers "recent offline" with no extra moving parts. Revisit when Android
offline mode lands.

## 5. Cloud / serverless?

- **Serverless Immich: not possible.** ❓📄 It's a stateful stack: Postgres with VectorChord,
  Redis/Valkey, a long-running job worker (thumbnails, video transcode, ML), and a
  websocket API. There is no serverless mode, and nothing in the roadmap points to one.
- 📄 No native S3 storage (planned, PoC only). Cloud Immich means a VM + block storage, or
  FUSE-mounted S3 (slow, fragile). An always-on EC2 + EBS for ~0.5–1 TB is roughly
  $40–90/month ❓ (from memory, not priced). fern is designed as on-demand with idle
  auto-stop, the opposite of a photo server.
- The cloud's only real job here is **off-site backup**, and cold object storage is cheap:
  S3 Glacier Deep Archive ≈ $1/TB-month, Backblaze B2 ≈ $6/TB-month ❓ (from memory; verify
  before choosing). Restore speed: hours for Deep Archive, instant for B2.
- If you ever want a cloud-hosted library: **Ente** is the one that fits (S3-native,
  E2E-encrypted, so a cheap VPS + B2 is safe). That would replace Immich, not complement
  it. Not recommended now.

## 6. Backups (3-2-1)

📄 Immich dumps its DB daily at 02:00 to `<mediaLocation>/backups` (keeps 14). Back up
`upload/`, `library/`, `profile/`, `backups/`; skip `thumbs/` and `encoded-video/` (they
regenerate). DB first, then files.

Proposal ❓:
1. **Copy 1**: butternut's library.
2. **Copy 2, other machine**: restic (or Syncthing receive-only + versioning) to maple, or a
   USB disk on butternut.
3. **Copy 3, off-site**: restic → S3 Deep Archive or B2, nightly, from butternut. This fits
   the existing AWS/OpenTofu setup in `infra/aws/` (user applies).

## 7. Importing the scattered photos

- ✅ `immich-go` is in nixpkgs: bulk uploader that understands **Google Photos Takeout**
  (merges the JSON sidecars: dates, GPS, albums), plain folders, and other Immich servers.
- `immich-cli` ✅ for plain folders.
- Or mount old folders read-only as **external libraries** (indexed in place, not copied).
  Good for archives you want to browse but keep where they are.
- ❓ Where do they live today? Google Photos? Old drives? Old laptops? This decides the
  import plan.

## 8. Nice extras, later

- **TV**: `services.immichframe` / `services.immich-kiosk` ✅ in nixpkgs. A slideshow on the
  Samsung TV next to maple, which ties into the Jellyfin/living-room backlog item.
- **Desktop**: the web UI as a Chromium app window (like T3), on workspace 2 or 4.
- **Workflows** (v3 preview): auto-album rules (e.g. screenshots → archive).
- **Local LLM tagging** (backlog "photo organisation with local LLMs"): Immich's CLIP search
  covers most of it. Anything extra can hit the API from peacelily later.

---

## Proposed shape in nixconf (❓ for the design step)

- `modules/nixos/features/immich.nix` → `flake.nixosModules.immich`, owning its
  infrastructure: `services.immich` (3.x via unstable module + package), media dir, the
  `tailscale serve` unit, firewall (none; tailnet only), optional CUDA ML override behind
  `preferences.immich.cuda`, persistence entries.
- `secrets/butternut/immich.yaml` only if needed (the DB is local over a unix socket, so
  likely none).
- Backup: a separate `features/immich-backup.nix` (restic) so the pilot doesn't wait on it.
- Host: `hosts/butternut/configuration.nix` imports it. Hazel gets nothing (client is the
  browser + phone app).

## Answers (user, 2026-11-22)

- **Sources:** old drives + the phone. No Google Takeout, so `immich-go`'s Takeout mode
  isn't needed. Old drives: copy in with `immich-go`/`immich-cli` folder upload (dedup by
  checksum), or index in place as an external library if a drive stays attached.
- **Host:** **peacelily is the target** (powerful NVIDIA GPU, lives at home), but it isn't
  plugged in yet and hasn't been redeployed with the current config (it already imports
  `nvidia` + `ai-server`). Photos sit on butternut until then. Disk size on peacelily: ❓
  (one NVMe in `disko.nix`; capacity not recorded).
  Consequences:
  - The feature stays host-agnostic (`mediaLocation` etc. as options), so the same module
    goes on either host.
  - On peacelily the ML service shares the GPU with llama-swap (LLMs). ML jobs are bursty
    (heavy only during imports), and Immich unloads idle models (`MACHINE_LEARNING_MODEL_TTL`),
    so co-existing is fine ❓; worst case, cap llama-swap or run imports at night.
  - Two ways to start: (a) wait for peacelily and import straight there; (b) pilot on
    butternut now, then move by DB dump + rsync of the media dir (same `mediaLocation` path
    on both hosts makes it a plain restore 📄). (a) avoids a migration; (b) gets the phone
    backing up sooner.
- **Off-site backup:** required, part of v1 (not deferred).
- **Family access / sharing:** later. No immich-public-proxy in v1.

- **Size:** under 1 TB (no finer estimate). Budget ~1.2 TB on the host: originals +
  thumbnails/previews + transcoded videos ❓ (derivatives are typically a 10–20 % overhead,
  more with lots of video). Off-site at that size: B2 < ~$6/month, Deep Archive < ~$1/month.
  Butternut's 131 GB free (≈ 330 GB after the Docker cleanup) is too small for the full
  import, so the butternut interim (option b) would be phone-only; old drives go straight
  to peacelily. Peacelily needs ≥ ~1.5 TB for headroom (check its NVMe, or add a disk).

## Still open

1. Peacelily's disk capacity (check when it's plugged in).
2. Off-site target: S3 Deep Archive (≈ $1/TB-month, restores take hours) or B2
   (≈ $6/TB-month, instant). Prices from memory, verify before choosing.

## Sources

- Immich releases & v3.0.0 notes: https://github.com/immich-app/immich/discussions/29439 ·
  3.4.1: https://freedom.tech/posts/2026-11-11-immich-3-4-1/ · https://immich.app/blog
- App/server compatibility: https://forum.yunohost.org/t/info-immich-check-mobile-app-version-before-upgrading-the-server-from-2-7-5-3-0-2/42569 ·
  https://docs.pr-30460.preview.immich.app/concepts/versioning
- Native iOS app / offline mode: https://github.com/immich-app/immich/discussions/33515
- Offline thumbnails: https://github.com/immich-app/immich/pull/31834 ·
  https://github.com/immich-app/immich/discussions/32763 ·
  https://github.com/immich-app/immich/discussions/9706 ·
  https://github.com/immich-app/immich/discussions/7627
- Mobile backup: https://docs.immich.app/features/mobile-backup/ ·
  https://docs.immich.app/features/mobile-app
- External library vs app backup: https://lumadock.com/tutorials/immich-external-library ·
  https://github.com/immich-app/immich/discussions/19853
- S3: https://github.com/immich-app/immich/discussions/23745 ·
  https://github.com/immich-app/immich/discussions/24608
- Backup & restore: https://docs.immich.app/administration/backup-and-restore
- Remote ML: https://docs.immich.app/guides/remote-machine-learning
- CUDA on NixOS: https://discourse.nixos.org/t/immich-and-cuda-accelerated-machine-learning/58330 ·
  https://wiki.nixos.org/wiki/CUDA
- Alternatives: https://contabo.com/blog/immich-vs-photoprism-vs-ente/ ·
  https://www.macrostack.net/compare/ente-photos-vs-immich
- Syncthing-Fork on Android: https://knightli.com/en/2026/05/31/syncthing-android-fork-setup-guide/
