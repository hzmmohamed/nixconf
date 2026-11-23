# Photos: Immich design

Status: design, approved 2026-11-22 (B2 backup deferred to phase 2). Research: `2026-11-22-photos-immich-research.md`.

## Intent

All photos in one place, with a Google-Photos-grade UI on the Android phone and on the
desktops, on hardware at home. Sources today: the phone and some old drives, under 1 TB in
total. The phone is the main camera, so phone photos must reach the server on their own and
be safe off-site before they're ever removed from the phone. Recent photos (on the phone)
must stay viewable with no server reachable.

## Goals

1. Immich 3.x as a NixOS feature, host-agnostic, the same module on butternut and peacelily.
2. **Pilot on butternut now, phone photos only** (butternut has ~130–330 GB free, not
   enough for the old drives).
3. **Final home: peacelily** (powerful NVIDIA GPU, at home) once it's plugged in. GPU ML
   there.
4. Reachable from the phone and the laptops over Tailscale only, HTTPS.
5. **Off-site backup to Backblaze B2** with restic, daily, checked, the B2 side as
   OpenTofu (`infra/b2`). **Deferred to phase 2** (user, 2026-11-22): designed here, built
   after the pilot is running.
6. A written migration runbook butternut → peacelily, then the old-drive import on
   peacelily.

## Phases

1. **Pilot:** `immich` feature on butternut, phone backup. Until phase 2 lands, the phone
   keeps every original (no "Free up space"), so there are two copies: phone + butternut.
2. **Off-site backup:** `infra/b2` (OpenTofu) + `immich-backup` feature on butternut.
3. **Move to peacelily** (runbook), CUDA ML, the **Tailscale Service `svc:photos`**
   (`https://photos.tail1a9f7c.ts.net`, permanent name), then the old-drive import.

## Non-goals (v1)

- Family accounts, shared albums, public share links (immich-public-proxy). Later.
- A second local copy (3-2-1 copy 2: USB disk or another host). Later; v1 has the library
  and B2, and the phone holds recent originals.
- Offline browsing of remote-only photos (Immich doesn't do it on Android; see research §4).
- TV slideshow (immichframe/immich-kiosk), desktop app window, Workflows, LLM tagging.
- GPU video transcoding (NVENC). CPU transcoding is fine at this size.

## Anti-goals (a failure even if it "works")

- **Lock-in:** originals must stay plain files in a readable folder tree, usable without
  Immich or its database.
- **Losing phone photos:** never "Free up space" on the phone before the B2 backup of those
  photos is confirmed.
- **Public exposure:** no Funnel, no open firewall port, no public DNS.
- **Big builds on hazel:** the CUDA ML build happens on peacelily/butternut only.
- **Silent backup failure:** a failing backup must be visible, not just in the journal.

## Constraints

- nixos-26.05 ships immich **2.7.5**; nixpkgs-unstable has **3.4.2**. The phone app
  auto-updates to 3.x (a v3 app talks to v2 servers, not the reverse). Start the library on
  3.x to avoid a v2→v3 migration on real data.
- Immich has no S3 storage backend: media lives on a local filesystem.
- Tailnet policy (`docs/tailscale-policy.hujson`): phone (user-owned) → butternut
  (user-owned) is `autogroup:self`, all ports; phone → peacelily (`tag:server`) allows
  `tcp:443`. Butternut's 443 is T3 Code, 8443 is OpenCode. So: **butternut serves Immich on
  HTTPS 8444, peacelily on 443. No policy change.**
- Secrets: `secrets/<hostname>/<service>.yaml`, sops, user creates them.
- Agents never deploy, never run sops, never `tofu apply`.

## Approaches

Picked in the conversation (research doc §2–§5):

| | Choice | Rejected, and why |
|---|---|---|
| Host | butternut pilot (phone only) → peacelily | wait for peacelily (phone unprotected meanwhile); maple (no GPU, disk unknown); cloud/EC2 (≈ $40–90/month, fern is on-demand) |
| Serverless | — | impossible: Postgres + Redis + long-running workers + ML |
| Phone → server | Immich app backup | Syncthing → external library: no backup-state UI, no safe "Free up space", duplicates if mixed |
| Off-site | restic → B2 | S3 Deep Archive: cheaper (≈ $1 vs ≈ $6/TB-month) but restic works badly on cold storage, 180-day minimum, slow paid restores |
| Version | 3.x from nixpkgs-unstable (module + package) | stay on 2.7.5 until 26.11 (forces a v2→v3 migration later); unstable package with the 26.05 module (module may lag 3.x changes) |
| Alternative app | Immich | Ente (E2E + S3-native, only worth it for cloud hosting); PhotoPrism (no real phone app) |

## Design

### Modules

**`modules/nixos/features/immich.nix`** → `flake.nixosModules.immich`. Owns its
infrastructure (service, Tailscale serve unit, ML acceleration). Options under
`preferences.immich`:

| Option | Default | Notes |
|---|---|---|
| `mediaLocation` | `/var/lib/immich` | Same path on every host, so migration is a plain restore |
| `tailscaleServePort` | `443` | butternut sets `8444` |
| `cuda` | `false` | peacelily sets `true`: CUDA onnxruntime for ML + GPU devices |

- **3.x:** a new flake input `nixpkgs-unstable` (`github:nixos/nixpkgs/nixos-unstable`). The
  feature does `disabledModules = ["services/web-apps/immich.nix"]`, imports unstable's
  module file, and sets `services.immich.package` to unstable's `immich` (and the ML
  package wherever the module takes it from). Postgres, VectorChord and Redis stay on
  26.05's packages, as the module wires them. The builder verifies VectorChord's version is
  one Immich 3.4 accepts. Drop the override when 26.11 ships ≥ 3.x.
- **Service:** `services.immich.enable`, `host = "127.0.0.1"`, port 2283, local Postgres +
  Redis from the module, `machine-learning.enable = true`, `openFirewall = false`.
- **Settings: declarative** (`services.immich.settings`, so the web settings page is
  read-only). This is my call: it fits the repo and means migration carries no settings
  drift. Set at least:
  - `storageTemplate.enabled = true`, template `{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}`.
    This is the lock-in guard: `library/<user>/2026/2026-11-22/IMG_….jpg`.
  - `backup.database`: enabled, daily at 02:00, keep 14 (Immich's default, made explicit).
  - `newVersionCheck.enabled = false` (Nix pins the version).
  - `server.externalDomain` = the tailnet URL of the host
    (`https://${hostName}.${tailnet.domain}[:port]`).
  - ML URL `http://127.0.0.1:3003` (module default), and any timeout for a cold GPU.
  The builder starts from Immich's config-file defaults and changes only these.
- **Tailscale serve:** a root oneshot unit, copied from `agent-opencode.nix`
  (`opencode-tailscale-serve`): `tailscale serve --bg --https=<port>
  http://127.0.0.1:2283`, with the retry loop. Websockets and large uploads (videos of
  several GB) must work through it; the builder checks there's no body-size cap.
- **CUDA (`cuda = true`):** `immich-machine-learning` with `onnxruntime` overridden to
  `cudaSupport = true` (the `ai-server.nix` llama-cpp pattern, cache.nixos-cuda.org already
  a substituter), plus `services.immich.accelerationDevices` covering `/dev/nvidia*` (or
  `null`) so the ML unit sees the GPU. CPU on butternut.

**`modules/nixos/features/immich-backup.nix`** → `flake.nixosModules.immich-backup`.
Separate from the service so the module can be enabled on its own.

- `services.restic.backups.immich`:
  - repository `s3:https://s3.<region>.backblazeb2.com/<bucket>/immich` (from an option,
    `preferences.immich.backup.repository`, set per host; the same repo for both hosts
    over time).
  - `environmentFile` from a sops template: `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` =
    a B2 application key restricted to the bucket. `passwordFile` from sops. File:
    `secrets/${hostName}/immich-backup.yaml`, keys `b2-key-id`, `b2-key`,
    `restic-password`.
  - paths: `<mediaLocation>/{library,upload,profile,backups}`; excludes `thumbs`,
    `encoded-video` (they regenerate).
  - timer: daily 03:30 (after the 02:00 DB dump), `Persistent = true`, randomized delay.
  - `pruneOpts`: `--keep-daily 7 --keep-weekly 5 --keep-monthly 12`.
  - `initialize = true` (creates the repo on first run).
  - weekly check: `restic check --read-data-subset=5%` (`checkOpts`, or a separate
    timer).
- **Failure visibility:** `OnFailure=` on the backup and check units → a small unit that
  pushes to **ntfy** using the topic file the repo already has
  (`preferences.agents.ntfy.topicFile`, sops; same pattern as `headless-boot.nix`'s
  notify, read as root). That reaches the phone from headless peacelily too. If no topic
  file is set on the host, emit a `warnings` entry (don't fail eval). Also push one ntfy message
  on the **first successful** backup, so the user knows when "Free up space" is safe. My
  call: phone push over desktop notifications, because peacelily has no desktop.

### Hosts

- `hosts/butternut/configuration.nix`: import `immich` (phase 1) and `immich-backup`
  (phase 2); `preferences.immich.tailscaleServePort = 8444`.
- `hosts/peacelily`: nothing in v1. The migration phase adds the imports, `cuda = true`,
  port 443. Peacelily's disk needs ≥ ~1.5 TB (check when plugged in).
- Hazel, maple, fern: nothing.

### Photos launcher (desktops; added 2026-11-23)

Immich has no desktop app. `features/photos-client.nix` (`flake.nixosModules.photos-client`,
hazel + butternut) adds a vicinae entry **Photos** → `photos-open`: Chromium `--app` on
`<externalDomain>/photos` (default browser if Chromium isn't enabled). The URL is read from the
server's own `services.immich.settings.server.externalDomain` on the registry host with role
`photos` (butternut now), so the launcher follows the library. Window app_id
`chrome-<host>__photos-Default` (verified: Chromium drops the port, keeps the path) → sway
workspace **2**; the T3/OpenCode rule on 5 narrowed to root-URL app windows (`__-`). Icon:
Immich's logo, vendored (`photos-client/immich.svg`, CC-BY-4.0).

### Stable name: Tailscale Service `svc:photos` (phase 3; decided 2026-11-23)

`.local` (mDNS: LAN only, no trusted TLS) and invented names like `immich.garden` (`.garden` is
a real public TLD) are out; a bought domain + ACME is more machinery than one app needs.
Tailscale Services (GA 2026-02) give `https://photos.tail1a9f7c.ts.net`: MagicDNS + automatic
cert, and **the name survives moving hosts**. A Service host must be **tagged**: peacelily is
(`tag:server`); butternut is deliberately user-owned (tagging it would cut the phone's
`autogroup:self` access to T3 etc.), so the pilot keeps `butternut…:8444` and the phone switches
once, at the migration, to the permanent name. Phase 3 work:
- `docs/tailscale-policy.hujson`: `autoApprovers.services."svc:photos" = ["tag:server"]` and a
  grant `autogroup:member` (+ `tag:phone`, `tag:client`) → `svc:photos` `tcp:443`; applied with
  `infra/tailscale` (user runs plan/apply). The service definition itself via the provider if it
  has a resource for it, else the admin console (user step).
- `features/immich.nix`: an option (e.g. `preferences.immich.tailscaleService = "photos"`, null
  on butternut) switching the serve unit to `tailscale serve --service=svc:photos --https=443 …`
  and `externalDomain` to `https://photos.${tailnet.domain}`.
- Registry: move the `photos` role from butternut to peacelily (the launcher follows).

### Phone (user steps, written as a checklist in the plan)

1. Install Immich (Play Store or F-Droid). Server URL `https://butternut.tail1a9f7c.ts.net:8444`.
2. Create the admin account in the web UI first (first-run screen), then log in on the app.
3. Backup: Camera + chosen device albums (Screenshots, WhatsApp, …). Background backup on.
4. HyperOS: battery "No restrictions", autostart allowed for Immich.
5. Keep "Prefer remote images" off.
6. **"Free up space": only after the first B2 snapshot is verified to contain those
   photos**, and with a cut-off of ~12 months, so recent photos stay on the phone.

### Migration butternut → peacelily (runbook in the plan, user executes)

Peacelily deployed and on the tailnet → stop `immich-*` on butternut → run a final DB dump
and restic backup → copy `mediaLocation` to peacelily (rsync over the tailnet, or restic
restore as a restore test) → restore the DB dump with Immich's restore procedure → enable
the feature on peacelily (`cuda = true`, port 443, `immich-backup` with peacelily's sops
file, same repo) → change the phone's server URL → disable both features on butternut and
remove its data only after peacelily's first backup succeeds.

### Old drives (after migration, on peacelily)

Copy in with `immich-go` (nixpkgs) folder upload: dedups by checksum, keeps EXIF dates. Run
it on peacelily or from butternut with the drive attached. Drives that should stay
browsable in place can instead be an external library (read-only, not backed up by
`immich-backup`, since they're their own copy).

### B2 as code (phase 2): `infra/b2/`

A third OpenTofu stack next to `infra/aws` and `infra/tailscale`, same conventions
(`versions.tf`, `variables.tf`, `outputs.tf`, `backend.hcl.example`; state in the same
backend style as the other stacks). Provider `Backblaze/b2`.

- `b2_bucket`: private, name from a variable, lifecycle rule "keep only the last version"
  (`days_from_hiding_to_deleting = 1`; restic prunes, so old versions would only cost
  money), default server-side encryption on (restic encrypts anyway).
- `b2_application_key`: capabilities limited to that bucket (list/read/write/delete files,
  list buckets), name prefix `immich-backup`.
- Outputs (sensitive): key id + key. A script, like `scripts/tailscale/store-admin.sh`,
  writes them into `secrets/<host>/immich-backup.yaml` with sops; the restic password is
  generated there once (and goes into the KeePassXC vault by hand).
- Provider auth: a B2 **master** (or bucket-creating) key in the user's environment only
  (secretspec / env vars), never in git or sops-for-hosts.
- A `just` recipe pair (plan/apply) like the existing tofu ones. **The user runs init/apply**
  (agents never `tofu apply`).

## User steps outside the repo

Phase 1:
1. Free space on butternut (user-actions §6, Docker cache).
2. Deploy butternut, create the admin account in the web UI, do the phone checklist
   (no "Free up space" yet).

Phase 2:
3. B2 account + a master key in the environment; `tofu init/apply` in `infra/b2`.
4. Run the store script (sops), keep the restic password in KeePassXC (without it the B2
   copy is unreadable).
5. Deploy butternut, wait for the "first backup OK" push, only then "Free up space".

## Left to the builder

- Exact way to take unstable's module + package (input wiring, `disabledModules` path,
  how the module gets the ML package), and the VectorChord compatibility check.
- Exact settings JSON keys (from Immich 3.4's config-file docs).
- The CUDA override shape and device list.
- Verification: `just check`; eval butternut; build the butternut closure (on butternut);
  ideally run unstable's `nixosTests.immich` or a small VM test of the feature (service up,
  serve unit present, restic unit rendered). No deploys.
