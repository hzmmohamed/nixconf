# Secrets across machines and projects: design (rev. 2, 2026-11-17)

Status: **phase 1 implemented** (KeePassXC + `vault` Syncthing folder, `modules/nixos/features/vault.nix`).
Later phases are proposals. No secret values appear in this document. Names and paths only.

Revision 2 replaces the Bitwarden-centred draft (Bitwarden Secrets Manager + rbw) after the
user's decision on 2026-11-17: the source of truth for passwords and secrets is **local-first,
distributed and serverless**: **KeePassXC + Syncthing**. No Vaultwarden/Bitwarden server, no
SaaS secret store. The AWS part (IAM Identity Center, separate agent identity), per-host sops keys,
the plaintext-token inventory and the migration/rotation steps carry over from revision 1.

## TL;DR

| Layer | Holds | Delivered by | Who sees it |
|---|---|---|---|
| **Personal vault**: `~/Vault/personal.kdbx` (KeePassXC / KeePassDX) | human credentials, TOTP, recovery codes, break-glass copies (admin age key, AWS root MFA recovery), human-only project secrets (Android release keystore) | **Syncthing** folder `vault` between phone, butternut, hazel, maple (+ optional encrypted cloud peer) | the human, after unlocking with password + key file (biometric on the phone). Never unlocked on headless or agent-only hosts |
| **Dev-secrets vault** (phase 2): `~/VaultDev/dev.kdbx` | project dev secrets agents may use (dev API tokens, dev DB URLs) | Syncthing folder `vault-dev`: **send-receive on hazel only, receive-only on agent hosts**; unlocked by a key file from sops | agents on agent hosts, via `secretspec` (`kdbx://` provider) |
| **sops-nix** (this repo) | machine/system secrets and bootstrap material (Tailscale, Wi-Fi, Syncthing keys, nix-serve, ntfy topic, the dev-vault key file, the cloud-peer encryption password) | `nixos-rebuild`, decrypted with **per-host** age keys (from SSH host keys) | root / the owning service / the user if `owner = user` |
| **AWS IAM Identity Center** (+ instance role / Roles Anywhere) | cloud credentials, short-lived | `aws sso login` (device code) / instance metadata | permission set: **Admin** (human) vs **Operator** (separate agents identity) |

**secretspec 0.21** is the per-project *declaration + injection* layer: each repo commits a
`secretspec.toml` with **names** and one alias (`team`); each machine's Nix-generated user config
says what `team` means there (`kdbx://` dev vault on agent hosts, `keyring://` → KeePassXC on
desktops once KeePassXC serves the Secret Service, `file://` from sops where there's no vault).

Unchanged prerequisites (they matter more than the tooling):
1. **Stop copying the single master age key to every host** (`scripts/install-host.sh` puts it in
   `~/.config/sops/age/keys.txt`, user-readable, so agent-readable, and it decrypts every host's
   secrets). Move to per-host keys derived from SSH host keys.
2. **Passwordless `doas` on agent hosts gives agents root.** Require a password (or `persist`) where
   agents run, or move agents to their own Unix user. See "Agent exposure model".

## Decision: why KeePassXC + Syncthing

- **Available offline and through outages.** Every peer has a full copy: café, ADSL down, phone in
  airplane mode. Bitwarden/Vaultwarden needs a reachable server (a VPS costs money; home hosting
  dies with home power/ADSL).
- **One encrypted file, many replicas.** KDBX 4 (Argon2id + ChaCha20/AES) is the security
  boundary. Syncthing is only transport (TLS between known device IDs). An off-site copy can live
  on an **untrusted** Syncthing peer that only stores ciphertext.
- **Mature clients**: KeePassXC 2.8.0 (nixos-26.05) on Linux, KeePassDX on Android (biometric
  unlock, autofill), and secretspec reads KDBX natively (`kdbx://`, KDBX 3/4 read, KDBX 4 write).
- **Cost:** conflicts are possible (two devices edit while apart). KeePassXC can merge two
  versions of a database, and Syncthing keeps the losing copy as a conflict file, so nothing is
  lost. Handling is described below.

## Vault design (phase 1, implemented)

### Files and folders

```
~/Vault/                        Syncthing folder id "vault" (0700), synced
  personal.kdbx                 the personal vault
  *.sync-conflict-*.kdbx        only after a conflict; merge, then delete
~/.local/share/keepassxc/
  personal.keyx                 key file: NOT synced, NOT in git, 0600
```

- **Composite key = master password + key file.** The key file never lives in the synced folder
  (it would travel with the database and add nothing). Anyone who gets `personal.kdbx` alone
  (stray backup, wrong Syncthing share, stolen cloud disk) also needs the key file, and still the
  password.
- Key file created by KeePassXC (Database → New → "Add additional protection" → Key File →
  Generate, `.keyx` v2 format). Copied **once** to each peer by hand (see user steps). Not via sops
  while the single master age key is on every host: that would hand it to every agent anyway.
- **Backups of the key file:** without it the vault is lost. Keep an offline copy (USB stick in a
  drawer) and a paper copy (the `.keyx` v2 file is a short XML with a 64-hex-digit key, printable).
  maple's Syncthing versioning protects the *database*, not the key file.
- **YubiKey/FIDO2 later (optional):** KeePassXC and KeePassDX both support HMAC-SHA1
  challenge-response (slot 2) as an extra key component; KeePassDX talks to it over NFC/USB via the
  "Key Driver" app. Program **two** YubiKeys with the same secret (one is the backup). Add it with
  Database → Database Security → Add YubiKey; every peer then needs a key present. FIDO2/passkeys
  are for *websites* (KeePassXC 2.8 stores passkeys); they can't unlock the database.

### Syncthing topology (as implemented)

Folder `vault` → `~/Vault`, declared by `features/vault.nix` (features own their infra):

| Peer | Role | Notes |
|---|---|---|
| butternut | send-receive, KeePassXC GUI | desktop + agent host: short auto-lock recommended (`preferences.vault.autoLockSeconds = 300`) |
| hazel | send-receive, KeePassXC GUI | **device ID missing from the registry** in `features/syncthing.nix` (eval warns). Until added, hazel gets no vault (nor Zotero) |
| maple | send-receive, **folder only** (headless, `preferences.desktop.enable = false`) | `preferences.vault.keepVersions = true`: staggered versioning, 1 year. The always-on copy and history |
| phone | send-receive (Syncthing-Fork) | `preferences.vault.extraDevices.phone.id`, a TODO in `vault.nix` |
| cloud (optional) | **untrusted, receive-encrypted** | `extraDevices.cloud = { id; untrusted = true; }`; encryption password from sops `secrets/shared/vault.yaml` key `vault.encryption-password` (declared only when an untrusted peer exists) |

Settings: `fsWatcherDelayS = 1` (default 10) so a save reaches the other peers within seconds,
which keeps the window for conflicting edits small. `ignorePerms = false`. Folder path is created
`0700` by tmpfiles before Syncthing first touches it, and listed in `persistance.data.directories`.

Peers not in the registry are skipped with an eval warning instead of failing.

### Conflict handling

- KeePassXC config (managed): `AutoSaveAfterEveryChange` (no long-lived unsaved edits),
  `AutoReloadOnChange` (when Syncthing replaces the file, KeePassXC reloads; with unsaved edits it
  offers to **merge**), `UseAtomicSaves` (write temp + rename, so Syncthing never ships a half-written
  file), `BackupBeforeSave = false` (a `.old.kdbx` in `~/Vault` would sync too; history is maple's
  versioning).
- If two peers edited while apart, Syncthing keeps the newer file and renames the other to
  `personal.sync-conflict-<date>-<time>-<device>.kdbx`. Resolve on a desktop: open
  `personal.kdbx` → **Database → Merge From Database…** → pick the conflict file (same key) → save →
  delete the conflict file. KeePassXC merges per entry using modification times and keeps entry
  history, so both sides' changes survive.
- Phone habit: lock KeePassDX after use and let Syncthing-Fork finish before editing elsewhere.
  KeePassDX notices a changed file when it reopens the database.
- Phase 2 nicety: a systemd user `.path` unit on `~/Vault` that sends a notification when a
  `*.sync-conflict-*` file appears.
- Restore an older version: maple `~/Vault/.stversions/` (staggered: hourly for a day, daily for a
  month, weekly for a year).

### KeePassXC on desktops (implemented)

home-manager `programs.keepassxc` (HM 26.05) with `settings` → `~/.config/keepassxc/keepassxc.ini`:

| Group | Keys | Why |
|---|---|---|
| General | SingleInstance, RememberLastDatabases/KeyFiles, OpenPreviousDatabasesOnStartup, AutoSaveAfterEveryChange, AutoReloadOnChange, UseAtomicSaves, BackupBeforeSave=false | sync-friendly, see above |
| GUI | ApplicationTheme=auto, MinimizeToTray/OnClose/OnStartup, ShowTrayIcon, CompactMode, CheckForUpdates=false | tray app, updates come from the flake |
| Security | LockDatabaseIdle (900 s, `preferences.vault.autoLockSeconds`), LockDatabaseScreenLock, ClearClipboard (30 s), IconDownloadFallback=false | auto-lock, no clipboard leftovers, no favicon lookups via DuckDuckGo |
| Browser | Enabled, UpdateBinaryPath=false | KeePassXC-Browser extension; HM installs the native-messaging manifest for Chromium/Firefox |
| SSHAgent | Enabled = `preferences.vault.sshAgent` (default false) | can add vault-stored SSH keys to gpg-agent while unlocked |
| FdoSecrets | **Enabled=false** | no Secret Service yet; gnome-keyring unchanged |

Also: autostart minimized via `preferences.autostart` (sway `startup`), the KeePassXC-Browser
extension added to Chromium next to Bitwarden, **Super+p** → `vault-open` (focus the KeePassXC window,
or bring it back from the tray; then Ctrl+F search, Ctrl+B copy user, Ctrl+C copy password).

Known quirk: the config is a read-only store link, so changing a setting in the GUI shows a save
error. Change settings in `vault.nix`. Window state, recent databases and key-file paths live in
`~/.cache/keepassxc/` and stay writable.

Screen lock: KeePassXC locks on logind `Lock`/`PrepareForSleep`. swayidle's idle timeout runs
swaylock directly (no logind `Lock` signal), so for idle the KeePassXC timer is what locks.
Phase 2: make swayidle call `loginctl lock-session` so both lock together.

Clipboard history: vicinae's clipboard provider has `ignorePasswords = true`, and KeePassXC marks
copies with `x-kde-passwordManagerHint: secret`, so copied passwords don't land in history.

### Keyboard picker (`vault-pick`): investigated, not implemented

- `keepassxc-cli` (2.8.0) has **no unlock cache or agent**: every `ls`/`show`/`clip` re-opens the
  database and re-derives the key (password on stdin, or `--no-password -k keyfile`). `open` is an
  interactive REPL, not a daemon. A picker would either prompt for the master password every time
  (Argon2, about 1 s each) or keep the password in a long-lived process or file. Neither is sane.
- The GUI's D-Bus API (`org.keepassxc.KeePassXC.MainWindow`) only has open/lock/close/exit, no search.
- **Auto-type on Wayland:** KeePassXC 2.8 has a Wayland backend via xdg-desktop-portal
  **RemoteDesktop** + **GlobalShortcuts**. sway's portal (`xdg-desktop-portal-wlr`) implements
  neither, so global auto-type and the global hotkey don't work on sway. Per-entry auto-type from
  the main window is also portal-based.
- What was implemented instead: Super+p focus/raise (above).
- **Phase 2 picker (clean path):** once KeePassXC serves the Secret Service, `vault-pick` lists items
  of the exposed group over D-Bus (`secret-tool search --all` or python `secretstorage`), shows titles
  in `vicinae dmenu`, then copies with `wl-copy --sensitive` and clears after 30 s (or types with
  `wtype`). KeePassXC asks for confirmation per client (`FdoSecrets/ConfirmAccessItem`) and unlocks
  on demand. The browser protocol (`keepassxc-proxy`, used by `git-credential-keepassxc`) is
  URL-matched, not a list, so it's no good for a picker.

## Phase 2: KeePassXC as Secret Service (`org.freedesktop.secrets`)?

### Who uses the Secret Service today (gnome-keyring, PAM-unlocked at greetd login, butternut + hazel via `features/email.nix`)

| Consumer | Item (attributes, no values) | Behaviour needed |
|---|---|---|
| `email-oauth2` (aerc `passwordCommand`, `imapnotify-{personal,work}`, `mail-unread-refresh` timer) | `service=email-oauth2 account={personal,work}` (OAuth **refresh tokens**) | read **unattended, all session long**, from systemd user services, every few minutes |
| Chromium (`--password-store=gnome-libsecret`, `features/chromium.nix`) | "Chromium Safe Storage" (`application=chromium`) | read at browser start. The key encrypts cookies and saved logins; **lose it = logged out everywhere** |
| VSCodium (`password-store = gnome-libsecret`) | extension tokens (GitLab, Claude Code, …) | read at start/use |
| `gh`, others | none yet on desktops | — |

### What changes with KeePassXC

- Only one process can own `org.freedesktop.secrets`. KeePassXC's FdoSecrets fails to start while
  gnome-keyring's `secrets` component owns the name, so you must turn off
  `services.gnome.gnome-keyring` (and the PAM hooks) on that host.
- KeePassXC must be **running and unlocked**. There's no PAM unlock: the user unlocks it at
  session start (password + key file; later YubiKey). Requests while locked bring up the unlock
  dialog (`FdoSecrets/UnlockBeforeSearch`). From a systemd user service that pops up a window or
  fails.
- **Auto-lock breaks unattended consumers.** With a 5–15 min idle lock, `imapnotify`/`mail-unread-refresh`
  fail to refresh tokens until the next unlock, so notifications and unread counts stop. Chromium
  started while locked can't decrypt cookies.

### Recommendation: hybrid first, full switch optional

- **Default (recommended): keep gnome-keyring for machine-local app secrets** (OAuth refresh tokens,
  Chromium Safe Storage, VSCodium). They're per-machine, re-creatable, PAM-unlocked with the login,
  and not worth syncing. **KeePassXC holds human credentials** (browser extension, phone, SSH keys).
  This keeps email/Chromium unchanged. It loses only the "one store" aesthetic.
- **Full switch (if wanted later), per host:**
  1. In KeePassXC: Settings → Secret Service Integration (`FdoSecrets.Enabled = true` in `vault.nix`);
     Database Settings → Secret Service → expose a dedicated group (`Secret Service/<host>`, so
     machine-local items don't mix with personal entries). `ConfirmAccessItem = true`.
  2. Unlock ordering: a user service watches the exposed collection's `Locked` property on D-Bus and
     starts `vault-unlocked.target`. `imapnotify-*`, `mail-unread-refresh.timer` get
     `Requisite/After = vault-unlocked.target` (replacing `sway-session.target`) and
     `Restart=on-failure, RestartSec=60`.
  3. Auto-lock policy: lock on screen lock and sleep only, not on a short idle timer (otherwise mail
     breaks), or accept that mail pauses while locked. butternut (agent host) should *not* do the
     full switch while agents share the user (see below).
  4. Migrate items: in a session where gnome-keyring still runs, list what exists (Seahorse, labels
     and attributes only). Then: `email-oauth2 setup personal` / `work` again after the switch (two
     browser consents, simplest). Chromium: either accept re-logins, or copy the single "Chromium
     Safe Storage" value by hand (lookup with gnome-keyring running, store with KeePassXC running,
     same attributes; do it in one terminal, no files). VSCodium: sign in to extensions again.
  5. Disable `services.gnome.gnome-keyring` and the `enableGnomeKeyring` PAM lines on that host
     (move them from `email.nix` into a `keyring` choice: `preferences.secretService = "gnome-keyring" | "keepassxc"`).
- **Headless hosts and agent services never use a Secret Service:** maple, peacelily, the AWS VM,
  lingering user services, `agent-run` jobs. No D-Bus session or unlocked GUI there. Use sops files
  (`/run/secrets/*`, `owner = user` only where needed), `systemd` credentials
  (`LoadCredentialEncrypted=` for system services), or the secretspec `file://`/`kdbx://` providers.

## secretspec (project secrets)

### Version

nixos-26.05 ships **0.10.1. Too old** (no `kdbx`/`file`/`sops`/`age` providers, no provider
credentials, no `[defaults]` chain, no scopes, no external providers). The nixpkgs locked by
**`llm-agents`** builds **0.21.1** (verified: `inputs.llm-agents.inputs.nixpkgs.legacyPackages.${system}.secretspec`),
with no new flake input. Pin through that, and run `secretspec check` in CI. If llm-agents drops
the package, use a `secretspec` overlay from the `cachix/secretspec` flake as an input.

### Providers that fit

| Machine | `team` alias → | Why |
|---|---|---|
| agent hosts (butternut agents, maple, peacelily) | `kdbx://<home>/VaultDev/dev.kdbx?keyfile=/run/secrets/vault-dev-keyfile` | dev vault, key-file-only, file synced **receive-only**; no network needed |
| hazel (human) | same `kdbx://` for dev secrets (send-receive, KeePassXC edits it) + `human` alias = `keyring://` (KeePassXC Secret Service, only if the full switch was done) or `kdbx://…/personal.kdbx` with the password from `SECRETSPEC_KDBX_PASSWORD` typed per shell | human-only profiles (`android-release`, `ops`, `lago`) |
| AWS VM / CI-like boxes without Syncthing | `file:///run/secrets/secretspec` (sops-rendered) or `systemd-credential://` | no vault replica |

- The `kdbx` provider addresses entries as `secretspec/{project}/{profile}/{KEY}` (group path +
  title, `Password` field; `prefix=` and `field` change that). The password comes from a provider
  credential or `SECRETSPEC_KDBX_PASSWORD`, the key file from `?keyfile=`. A key-file-only dev vault
  needs neither prompt nor env.
- `keyring://` on desktops works with either provider (gnome-keyring or KeePassXC), but needs an
  unlocked session collection. Never use it for anything agents or headless hosts need.
- **External providers** (0.21+, `secretspec-provider-<scheme>` executables, "Secret Provider
  Protocol v1"): a `keepassxc-cli`-based provider is possible, but `kdbx://` is native and makes it
  unnecessary. Keep the option for a KeePassXC-GUI bridge (FdoSecrets) if `keyring://`'s item layout
  turns out awkward.
- Agent sessions: `require_reason = "agents"` (the default) puts every agent read in
  `secretspec audit`. That's an audit trail, not a boundary. The boundary is **what's in dev.kdbx**.
- Why a separate dev vault and not `personal.kdbx`: agents on agent hosts need unattended reads.
  Any unattended unlock material (key file, password) on an agent host is readable by agents, so the
  database it opens must contain **only** what agents may have.
- Writes: only from hazel in KeePassXC (or `secretspec set` there). The `vault-dev` folder is
  `receiveonly` on agent hosts, so an agent's local `secretspec set` never propagates (Syncthing flags
  it "locally changed", and you revert it from the GUI).

Machine config (generated by Nix into `~/.config/secretspec/config.toml`, phase 2 `features/secretspec.nix`):

```toml
[defaults.providers]
team = { uri = "kdbx:///home/<user>/VaultDev/dev.kdbx?keyfile=/run/secrets/vault-dev-keyfile" }
# hazel only:
human = { uri = "keyring://" }
```

### Per-project `secretspec.toml` drafts (names only)

Common header. The project names only aliases; machines define them:

```toml
#:schema https://secretspec.dev/schema/secretspec.schema.json
[project]
name = "routelab"
revision = "1.0"
require_reason = "agents"
[defaults]
providers = ["team"]
```

**routelab-monorepo**

```toml
[profiles.default]            # local dev (compose Postgres, alchemy dev); agents may read
BETTER_AUTH_SECRET        = { description = "better-auth signing secret (dev)", generate = true }
DATABASE_URL              = { description = "dashboard dev DB URL", default = "postgres://…localhost…" }
VITE_MAPBOX_ACCESS_TOKEN  = { description = "Mapbox public token (dashboard)" }
MAPBOX_ACCESS_TOKEN       = { description = "Mapbox token (map-matching-worker)", required = false }
PLUNK_TOKEN               = { description = "Plunk email API (dev)", required = false }
TILES_SIGNING_KEY         = { description = "tiles CloudFront signing key (dev)", required = false }
VITE_TILE_SERVER_CREDENTIALS = { description = "tile server basic auth", required = false }
LEGACY_DB_URL             = { description = "legacy observer DB (Tiltfile); rotated", required = false }
SDI_DB_PASSWORD           = { description = "legacy import tool DB", required = false }
FLEXPRICE_API_KEY         = { description = "billing (Tilt/dev)", required = false }
ORIGIN_SECRET_HEADER      = { description = "ticker origin secret (dev)", required = false }
OTEL_EXPORTER_OTLP_HEADERS = { description = "OTLP auth header (Grafana Cloud)", required = false }

[profiles.ops]                # human-only (Grafana push, alerts)
defaults = { providers = ["human"] }
GRAFANA_TOKEN     = { description = "infra/grafana/cloud/push.mjs" }
TEAMS_WEBHOOK_URL = { description = "alert webhook" }

[profiles.lago]               # human-only, deployment/deploy-lago
defaults = { providers = ["human"] }
LAGO_RSA_PRIVATE_KEY = {}  LAGO_ENCRYPTION_PRIMARY_KEY = {}  LAGO_ENCRYPTION_DETERMINISTIC_KEY = {}
LAGO_ENCRYPTION_KEY_DERIVATION_SALT = {}  SECRET_KEY_BASE = {}  POSTGRES_PASSWORD = {}
REDIS_PASSWORD = {}  LAGO_REDIS_CACHE_PASSWORD = {}  LAGO_SMTP_PASSWORD = {}  LAGO_ORG_USER_PASSWORD = {}
LAGO_ORG_API_KEY = {}  LAGO_AWS_S3_ACCESS_KEY_ID = {}  LAGO_AWS_S3_SECRET_ACCESS_KEY = {}
GOOGLE_AUTH_CLIENT_ID = {}  GOOGLE_AUTH_CLIENT_SECRET = {}  PORTAINER_PASSWORD = {}

[profiles.android-release]    # human-only; never in dev.kdbx
defaults = { providers = ["human"] }
OBSERVER_UPLOAD_STORE_PASSWORD = { description = "upload keystore password" }
OBSERVER_UPLOAD_KEY_PASSWORD   = { description = "upload key password" }
OBSERVER_UPLOAD_KEY_ALIAS      = { description = "upload key alias", required = false }
OBSERVER_UPLOAD_STORE_FILE     = { description = "keystore (binary)", as_path = true }

[scopes.web]
secrets = ["BETTER_AUTH_SECRET","DATABASE_URL","VITE_MAPBOX_ACCESS_TOKEN","PLUNK_TOKEN","VITE_TILE_SERVER_CREDENTIALS"]
[scopes.tilt]
secrets = ["LEGACY_DB_URL","FLEXPRICE_API_KEY","SDI_DB_PASSWORD"]
```

(The `lago` line packing is shorthand here. Write one key per line with descriptions in the real file.)
Not secrets, so keep them in a committed `.env.defaults`/devenv `env`: `ROUTELAB_PROFILE`,
`ROUTELAB_ALARM_EMAIL`, `ROUTELAB_OTLP_BASE_URL`, `ROUTELAB_PRODUCTION_HOSTS`, `VITE_*_URL`,
`AWS_REGION`. AWS creds come from `AWS_PROFILE` (SSO), never from secretspec. Prod runtime secrets
stay in AWS Secrets Manager (Alchemy `Secrets.ts`). **Verify** the per-profile `defaults.providers`
syntax against 0.21's schema before committing.

**d_abm**: no secrets, only AWS identity plus config.

```toml
[project]
name = "d_abm"
revision = "1.0"
[defaults]
providers = ["team"]
[profiles.default]
CAIRO_SIM_ALERT_EMAIL = { description = "budget alert address", required = false }
```

Config (`CAIRO_SIM_STAGE`, `_AWS_REGION`, `_AWS_ACCOUNT_ID`, `_VPC_ID`, `_SUBNET_IDS`, `_BUDGET_USD`,
`_*_IMAGE`) moves from untracked `infra/aws/.env` to a committed `infra/aws/.env.defaults`. Retire the
legacy `ci/run-pipeline.sh` (`AWS_ACCESS_KEY_ID`, `S3_BUCKET`).

**nixconf** (dev shell / agents)

```toml
[project]
name = "nixconf"
revision = "1.0"
[defaults]
providers = ["team"]
[profiles.default]
CACHIX_AUTH_TOKEN    = { required = false }
R2_ACCESS_KEY_ID     = { required = false }   # R2 binary cache (S3 API), not AWS_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY = { required = false }
NIXBUILD_NET_TOKEN   = { required = false }
GITHUB_TOKEN         = { required = false, description = "fine-grained, read-only; nix access-tokens / gh for agents" }
```

The ntfy topic stays in sops (`secrets/shared/agents.yaml`, already wired to `agent-notify`).

### direnv vs wrappers

`.envrc` after `use flake` can do `eval "$(secretspec export --reason 'direnv shell')"`, but that
puts values into every shell and agent process in the repo (and into transcripts via `env`/error
dumps). Recommendation: **wrap commands** (`secretspec run --scope web -- pnpm dev`, Tilt, Lago
scripts; `run` also masks values in output) for routelab; **no secrets in env** for d_abm
(`AWS_PROFILE` only). Don't use devenv's `secretspec:` integration: it pulls values into Nix eval
(risk of the world-readable store).

## Android (primary mobile peer)

1. Install **Syncthing-Fork** (Catfriend1; F-Droid or Play) and **KeePassDX** (F-Droid or Play).
2. Syncthing-Fork: ⋮ → *Show device ID*, then put it in `vault.nix` (`extraDevices.phone.id`) and
   rebuild butternut/hazel/maple. On the phone, add butternut and maple as devices (scan the QR from
   each host's Syncthing GUI: Actions → Show ID). Accept the `vault` share and set the folder to
   `/storage/emulated/0/Vault` (shared storage so KeePassDX can open it). Folder type send-receive.
   Watch for changes: on.
3. **Battery:** Android Settings → Apps → Syncthing-Fork → Battery → *Unrestricted*. In
   Syncthing-Fork's run conditions allow mobile data (the vault is tiny) and don't require charging,
   or changes made on the phone wait until it's charging on Wi-Fi.
4. **Key file:** from a desktop, `adb push ~/.local/share/keepassxc/personal.keyx /sdcard/Download/`
   (the `adb` feature is on butternut/hazel), or send it with KDE Connect. In KeePassDX, select it as
   the key file when opening `Vault/personal.kdbx`. Then move it out of `Download` into a
   non-synced folder (e.g. `Documents/keys/`), re-select it once, and delete the copy from `Download`.
   **Never put it under `Vault/`.**
5. KeePassDX: Settings → *Advanced unlock* → biometric unlock (the composite key is wrapped by the
   Android Keystore; the master password is still needed after reboot/timeout). Settings → Form
   filling → *set KeePassDX as autofill service* (Android Settings → Passwords & autofill). Optional:
   the KeePassDX keyboard ("Magikeyboard") for apps without autofill support. Set the app lock timeout
   (e.g. 5 min) and "lock on screen off".
6. Test: edit an entry on the phone, then within seconds KeePassXC on butternut reloads it (with
   `AutoReloadOnChange`).

## Optional off-site encrypted peer

An untrusted Syncthing device stores only encrypted file names and blocks. It can't read the
vault, even with root (the KDBX is encrypted a second time anyway). It only needs to talk to maple
(always on). The NixOS peers share with it using the same folder password from sops.

| Option | Cost | Notes |
|---|---|---|
| Oracle Cloud Always Free (Ampere A1 or E2.1.Micro) | free | idle instances can be reclaimed, and sign-up needs a card. Install with nixos-anywhere |
| Hetzner Cloud CAX11 (ARM) | about €4/month | simplest, EU, reliable. nixos-anywhere works |
| AWS t4g.nano | about $3–4/month incl. EBS | use a **personal** account, not the TfC work account |

Sketch (new host, e.g. `modules/nixos/hosts/rowan/`):

```nix
flake.nixosModules.hostRowan = {...}: {
  imports = [self.nixosModules.base self.nixosModules.general self.nixosModules.sops
             self.nixosModules.openssh self.nixosModules.tailscale self.nixosModules.syncthing];
  # Not vault.nix: this node never holds the plaintext folder.
  services.syncthing.settings = {
    devices.phone.id = "…";                 # trusted peers are in features/syncthing.nix
    folders.vault = {
      type = "receiveencrypted";            # stores ciphertext only; no password here
      path = "/srv/syncthing/vault-encrypted";
      devices = ["maple" "butternut"];      # hazel/phone optional
    };
  };
  # GUI stays on 127.0.0.1; reach it with `ssh -L 8384:localhost:8384`.
};
```

Trusted side (already supported by `vault.nix`): `preferences.vault.extraDevices.cloud = { id = "…"; untrusted = true; };`
plus `vault.encryption-password` in `secrets/shared/vault.yaml` (sops). The module then shares the
folder with that device with `encryptionPasswordFile` and marks the device `untrusted`. Restore:
`FOLDER_PASSWORD=… syncthing decrypt --to /tmp/vault-restore /srv/syncthing/vault-encrypted` (password via env, not argv).
(The phone, if it also shares with the cloud node, needs the same password typed in Syncthing-Fork.)

## Migration from Bitwarden

1. Create the vault on hazel or butternut (user steps below). Settings: KDBX 4, Argon2id, about 1 s
   decryption time (KeePassDX on the phone must open it in reasonable time, so test).
2. Bitwarden web vault → Tools → Export → **`.json` (unencrypted)** to `$XDG_RUNTIME_DIR` (tmpfs,
   not `~/Downloads`). KeePassXC → Database → Import → **Bitwarden** (KeePassXC 2.7+ imports Bitwarden
   JSON incl. folders, TOTP, custom fields, attachments not included). Then `shred -u` the export.
3. Verify: entry count per folder, a few TOTPs against the phone authenticator, passkeys (Bitwarden
   passkeys don't export: re-register them in KeePassXC/KeePassDX), attachments (download them
   separately).
4. Keep Bitwarden **read-only for about a month** (don't add new items there). Keep the Bitwarden
   extension next to KeePassXC-Browser for that time; `rbw` stays installed (`features/rbw.nix`).
5. Then: remove the Bitwarden extension from `chromium.nix`, drop `features/rbw.nix` from hosts,
   delete `~/.config/rbw/` and `~/.config/Bitwarden CLI/` state, and finally delete or close the
   Bitwarden account (or keep a free account dormant with a strong unique password, as you like).

## Agent exposure model

Agents run as the same Unix user in `agents.slice` on butternut/peacelily/maple/the AWS VM.
**Anything the user can read, agents can read.** Claude Code deny rules are speed bumps.

| Secret | Today | Target |
|---|---|---|
| master age key | on every host, user-readable | **hazel only** (+ paper/vault copy). Hosts use SSH-host-derived age keys (root-only) |
| `/run/secrets/*` | root/owner, but doas is passwordless | doas password on agent hosts. User-owned secrets limited to what agents may have (dev-vault key file, ntfy topic) |
| personal vault | Bitwarden via rbw (unlocked up to 1 h) | `personal.kdbx` present on butternut (encrypted), **unlocked only in the human desktop session**, auto-lock 300 s there. **Never unlocked, no key file, no GUI on maple/peacelily/AWS VM** (maple only has the ciphertext replica) |
| project dev secrets | `.env` files, `gradle.properties` | `dev.kdbx` (agent-safe contents only) via secretspec `kdbx://`, receive-only replica |
| human-only secrets (release keystore, Lago, ops tokens) | agent-readable files | `personal.kdbx`/`human` alias on hazel only |
| AWS | static admin-ish keys everywhere | agents: **Operator** permission set via a *separate* Identity Center user. Humans: Admin, on hazel only |

While KeePassXC is unlocked in the butternut desktop session, same-user processes can still try to:
- use **browser integration**: needs an association key stored in the database, and a new
  association brings up a GUI approval dialog. Don't approve unexpected requests.
- use **Secret Service** (phase 2): only the exposed group, and with `ConfirmAccessItem` every new
  client needs GUI approval. Another reason to keep the full switch off butternut.
- **ptrace/read KeePassXC memory**: set `kernel.yama.ptrace_scope = 2` (admin-only attach) on agent
  hosts (phase 2, check no debugger workflow depends on it).
- **read the clipboard** (`wl-paste` with the desktop's `WAYLAND_DISPLAY`): 30 s clear. Agents
  started from T3 Code/herdr services don't need `WAYLAND_DISPLAY`, so strip it from their environment.
- **read `personal.keyx`**: the key file alone does not open the database; the master password
  is never stored on disk, and Wayland clients cannot keylog each other.

**Long-term (real boundary):** run `agent-host` services as a dedicated `agent` Unix user with its
own `~/.aws`, secretspec config and dev-vault key file; the human session (KeePassXC, personal
vault, SSO admin) stays out of reach. Track it in the agentic-workspace design.

**Why a separate Identity Center user for agents:** an SSO access token in `~/.aws/sso/cache` can be
exchanged for *any* permission set of that user. With a dedicated agents user that only has
Operator, logging in on an agent host is safe by construction.

## Current state (inventory: names and paths only)

| Where | What | Problem |
|---|---|---|
| `~/.aws/credentials` | one `[default]` profile, **static access keys** | long-lived; every agent can launch 16 vCPU/64 GB Fargate tasks; only a budget *alert* |
| `~/.aws/config` | `[default] region` only | no SSO profiles; d_abm README already assumes SSO |
| `~/.alchemy/profiles/default/aws.json` | `method: "stored"`, **second copy of static keys** | migrate to `sso`, rotate |
| `~/.config/doctl/config.yaml` | single `access-token` | plaintext; no repo references DigitalOcean any more |
| `~/.config/rbw/config.json` | `lock_timeout 3600` | while unlocked, any user process can `rbw get` any item; retire with Bitwarden |
| `~/.config/Bitwarden CLI/data.json` | official `bw` CLI state | delete after migration |
| `~/.docker/config.json` | `auths` for the ECR registry | 12 h ECR token in plaintext → ECR credential helper |
| `~/.npmrc` | npm auth token | plaintext, long-lived |
| `~/.config/gh/hosts.yml` | `oauth_token` | plaintext |
| `~/.kube/config` | EKS contexts | exec plugin inherits the active AWS profile |
| `~/.gradle/gradle.properties` | `OBSERVER_UPLOAD_*` | release keystore passwords, agent-readable |
| routelab `apps/dashboard/.env`, `apps/observer/.env` | `BETTER_AUTH_SECRET DATABASE_URL …` | git-ignored, missing in worktrees |
| routelab `Tiltfile:301` | committed legacy DB URL with password | rotate; read `LEGACY_DB_URL` from env |
| d_abm `infra/aws/.env` | config | untracked, missing in worktrees |
| nixconf `secrets/` | one age recipient (`&primary`) | master key on every host |
| gnome-keyring (butternut, hazel) | email OAuth refresh tokens, Chromium Safe Storage, VSCodium tokens | fine as machine-local store (see phase 2 discussion) |

Good already: routelab CI deploys via **GitLab OIDC → `CI_DEPLOY_ROLE_ARN`**; prod runtime secrets
live in **AWS Secrets Manager** (Alchemy). d_abm defines a least-privilege
**`cairo-sim-<stage>-operator`** policy (`infra/aws/src/Operator.ts`), currently attached to nothing.

## AWS plan (unchanged from rev. 1)

1. Identity Center path:
   - **A (preferred):** AWS Organizations + Identity Center (organization instance, eu-central-1;
     an *account instance* can't grant account access). Users: `hfahmi` (human), `hfahmi-agents`.
     Permission sets: `AdministratorAccess` (or narrower `Deployer`) → human only; `CairoSimOperator`
     (customer-managed policy `cairo-sim-<stage>-operator`) → both; later `RoutelabReadOnly` → agents.
     Portal session 12 h, permission set 1–4 h.
   - **B (no Organizations):** IAM user + `SignInLocalDevelopmentAccess` + `aws login` (CLI ≥ 2.32;
     26.05 has 2.34.24); an `agents` IAM user assuming `cairo-sim-operator`. Verify `source_profile`
     with `login_session`.
2. AWS agent VM: instance profile = operator policy (+ SSM).
3. Alchemy profile → method `sso`, `ssoProfile = tfc-admin`; delete stored keys.
4. CI unchanged (GitLab OIDC). Add a hard per-run cap in `bin/sim` (`CAIRO_SIM_MAX_USD_PER_RUN`).
5. Headless hosts: `ssh <host> aws sso login --sso-session tfc-agents --use-device-code` from hazel,
   open the URL on hazel/phone (`just aws-login <host>` later). Phase 3: IAM Roles Anywhere.

`features/aws.nix` (phase 2): `sops.templates."aws-config"` renders `~/.aws/config` (start URL and
account IDs kept out of the public repo) with `[sso-session tfc]`, `[profile tfc-admin]`,
`[profile tfc-operator]`, `[sso-session tfc-agents]`, `[profile tfc-agent]`, `[profile tfc-vm]`;
`preferences.aws.defaultProfile` (`tfc-admin` on hazel, `tfc-agent` on agent hosts) → `AWS_PROFILE`;
`amazon-ecr-credential-helper` as Docker `credHelpers`; drop the unused `aws-vault`.

## Phases

| Phase | Content | State |
|---|---|---|
| **1** | `features/vault.nix`: Syncthing folder `vault` (butternut, hazel, maple + phone/cloud TODOs, maple versioning), KeePassXC + managed config on desktops (FdoSecrets off), Browser extension, autostart, Super+p raise. rbw kept | **done** |
| 2a | Bitwarden → KeePassXC migration (user), phone setup, hazel device ID, conflict notifier | user + small module |
| 2b | **sops per-host keys** (`sops.age.sshKeyPaths`, `.sops.yaml` per-host recipients, `install-host.sh` ships host keys, not the master key), rotate the master key; doas password on agent hosts | proposal |
| 2c | `vault-dev` folder + `dev.kdbx` + `features/secretspec.nix` (0.21.1 from llm-agents nixpkgs, generated user config, sops key file) and `secretspec.toml` in routelab/d_abm/nixconf | proposal |
| 2d | AWS Identity Center + `features/aws.nix` rewrite; rotate static keys | proposal |
| 2e | Secret Service decision (hybrid by default; optional full switch per host), `vault-pick`, swayidle → `loginctl lock-session`, `ptrace_scope` | proposal |
| 3 | `agent` Unix user, Roles Anywhere, YubiKey | later |

## Migration and rotation steps (after phase 2b–2d)

1. **Inventory into vaults:** dev secrets → `dev.kdbx` (`secretspec import dotenv://apps/dashboard/.env`
   on hazel with the `team` alias, or by hand in KeePassXC). Release keystore values and Lago/ops →
   `personal.kdbx` under `secretspec/routelab/<profile>/`.
2. **secretspec in repos:** commit `secretspec.toml` + script wrappers. Delete git-ignored `.env`
   files once `secretspec check` passes on two machines.
3. **AWS:** Identity Center, verify `aws sts get-caller-identity --profile tfc-operator`, run one
   `bin/sim` as `tfc-agent`, switch Alchemy to `sso`. **Deactivate, then delete** the static keys
   (check "last used"), remove `~/.aws/credentials` and the Alchemy stored profile.
4. **sops:** per-host keys, `sops updatekeys secrets/**/*.yaml`, remove `~/.config/sops/age/keys.txt`
   from all hosts but hazel, **rotate** the master key and the secrets it protected that matter
   (Tailscale auth key, nix-serve signing key, Wi-Fi PSK if worried).
5. **Others:** rotate the routelab legacy DB password; revoke/replace the npm token; re-issue the gh
   token as fine-grained; revoke the DO token if unused; ECR helper instead of Docker `auths`.
6. **Harden agent hosts:** doas password, deny-list additions (`Read(~/.aws/sso/**)`,
   `Read(~/.local/share/keepassxc/**)`, `Read(~/Vault/**)`: speed bumps), `ptrace_scope`, later the
   `agent` user.

## Risks and open questions

- **Same-user agents remain the root problem.** Everything here reduces blast radius. Only a
  separate Unix user (or VM) is a boundary.
- **Key-file loss = vault loss.** Keep the offline and paper copies. Check them yearly.
- **Conflicts** need a human merge. Rare with `fsWatcherDelayS = 1` and auto-save, but expect the
  occasional `sync-conflict` file after the phone was offline.
- **Syncthing untrusted devices**: historically labelled beta; the vault is KDBX-encrypted anyway,
  so the risk is mainly availability of the off-site copy. Test a `syncthing decrypt` restore once.
- **hazel's Syncthing device ID** is missing from `features/syncthing.nix`, so hazel currently syncs
  nothing (Zotero included).
- **secretspec moves fast** (0.10 → 0.21 in about 5 months). Pin it and run `secretspec check` in CI.
  Verify before 2c: `kdbx://` with a key-file-only database and sops-nix symlinked paths;
  per-profile `defaults.providers`; `keyring://` item layout under KeePassXC FdoSecrets.
- **Public repo:** keep start URL and account IDs out of nixconf (sops templates). Syncthing device
  IDs are not secret (they're already in `features/syncthing.nix`).

## Sources

- KeePassXC 2.8.0 (nixos-26.05): `keepassxc --help`, `keepassxc-cli --help`/`show --help`, config keys
  and D-Bus interfaces read from the binary; https://github.com/keepassxreboot/keepassxc/blob/develop/src/core/Config.cpp ;
  https://keepassxc.org/docs/KeePassXC_UserGuide (Secret Service, Browser, Auto-Type, Merge).
- home-manager 26.05 `modules/programs/keepassxc.nix` (settings → ini, autostart, native messaging hosts).
- nixpkgs 26.05 `nixos/modules/services/networking/syncthing.nix` (folder `devices` with
  `encryptionPasswordFile`, `versioning`, `fsWatcherDelayS`); Syncthing 2.1.7 CLI (`device-id`, `decrypt`).
- Syncthing docs: untrusted devices https://docs.syncthing.net/users/untrusted.html ; versioning
  https://docs.syncthing.net/users/versioning.html ; conflicts https://docs.syncthing.net/users/syncing.html#conflicting-changes
- KeePassDX https://github.com/Kunzisoft/KeePassDX/wiki ; Syncthing-Fork https://github.com/Catfriend1/syncthing-android
- secretspec 0.21.1 source (`src/provider/{kdbx,keyring,external,file,systemd_credential}.rs`), https://github.com/cachix/secretspec
- AWS: Identity Center account instances https://docs.aws.amazon.com/singlesignon/latest/userguide/account-instances-identity-center.html ;
  session duration https://docs.aws.amazon.com/singlesignon/latest/userguide/user-session-duration-prereqs-considerations.html ;
  `aws login` https://aws.amazon.com/blogs/security/simplified-developer-access-to-aws-with-aws-login
- Local: `modules/nixos/features/{vault,syncthing,sops,rbw,email,chromium,vscode,vicinae,swayidle,agent-common}.nix`,
  `scripts/{install-host,gen-syncthing-secrets}.sh`; routelab/d_abm files as in rev. 1.
