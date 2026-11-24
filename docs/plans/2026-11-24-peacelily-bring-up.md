# peacelily bring-up (2026-11-24)

peacelily is the headless GPU AI server (Core Ultra 5 245K, RTX 5060 Ti 16 GB,
one NVMe). It was last on the tailnet around **2026-04-29** (network review:
"offline 202 days" on 2026-11-17), running a config from about commit `20b91eb`
(2026-04-22). Branch `peacelily-prep` brings the config up to date. This doc
covers what changed, what was fixed, what needs a decision, and a runbook.

Eval: `nix eval --raw .#nixosConfigurations.peacelily.config.system.build.toplevel.drvPath`
passes. The closure was **not built**: NVIDIA/CUDA builds are long.

## 1. What the new config changes on peacelily

Compared with the April system:

| Area | April system | New config |
|---|---|---|
| Kernel / driver | `linuxPackages_latest`, NVIDIA open (April) | **6.18.63 LTS** (`nvidia.nix` default), NVIDIA **595.71.05** open (supports Blackwell sm_120) |
| Remote access | **No sshd**. Only Tailscale SSH (`--ssh`), global TCP 22 open | sshd on **7654** (`openssh`, butternut + hazel keys, password auth still on), Tailscale SSH kept, no global 22 |
| Tailscale | shared auth key, user-owned | OAuth client login with tags `tag:server tag:gpu` (registry), `--operator`, tailscale0 trusted |
| Networking | NetworkManager | + resolved (`dns`), `/etc/hosts` + ssh config + known_hosts from the registry, trusted networks (`everywhere = true`), system Wi-Fi profiles (`wifi-home`) |
| Nix | | daily GC (14 d), weekly optimise, min-free 10 GiB, `nix-builder` client (no builder assigned) |
| Power | `powersave` (power-profiles-daemon, powertop auto-tune, **AMD LACT**) + plymouth | removed. No sleep targets, nvidia-persistenced, journald capped at 1 GB / 1 month, `Africa/Cairo` |
| AI services | `${PORT}` llama-swap, 16k contexts, broken `--no-mmproj--ctx-size`, services on 0.0.0.0 with ports open globally, LibreChat registration **open** | fixed flags/contexts (2026-11-17), every port admitted on **tailscale0 only**, LibreChat registration off, optional Qdrant API key; today: fixed llama ports + `--metrics`, CPU fallback for STT/TTS, LibreChat STT/search fixes |
| Monitoring | none | **new** `monitoring` feature: Prometheus (127.0.0.1:9090) + Grafana (:3000, tailnet) |
| Secrets | `secrets/shared/librechat.yaml` | `secrets/peacelily/librechat.yaml` (moved with `git mv`; same recipients, content unchanged) |

Secrets the new config decrypts, all present and all encrypted for the
**primary** age key: `shared/tailscale.yaml`, `shared/tailscale-oauth.yaml`,
`shared/wifi.yaml`, `peacelily/librechat.yaml`. The April install put the
primary key at `~/.config/sops/age/keys.txt` on peacelily (install-host.sh), so
a redeploy needs no sops work.

## 2. Fixed on this branch

Commits on `peacelily-prep`:

1. **ai-server** (`a08d174`)
   - **Whisper would crash-loop.** It asked for `device = "cuda"`, but nixpkgs is
     not built with `cudaSupport`: CTranslate2 links only OpenBLAS, onnxruntime
     (Piper) and torch (Kokoro) are CPU builds. faster-whisper exits at startup
     when asked for CUDA. Whisper and Piper now use the GPU only when the package
     set has CUDA, and the eval prints a warning until it does. Decision in §3.1.
   - **llama-server on fixed ports 8010-8015** (llama-swap `proxy`) with
     `--metrics`. Prometheus scrapes loaded models directly, and a scrape never
     triggers a model load.
   - **LibreChat STT removed.** It pointed at `localhost:10300/v1/audio/transcriptions`,
     but 10300 speaks the Wyoming protocol, not HTTP. LibreChat now uses the
     browser's speech recognition, as the April features guide recommends.
     Kokoro TTS (HTTP, 127.0.0.1:8880) stays.
   - **LibreChat `SEARCH` off.** It needs Meilisearch, which isn't configured. The
     dead `SEARXNG_URL` (searx is commented out) is gone too.
   - LibreChat secrets moved to `secrets/peacelily/` (per-host convention).
2. **Host** (`4a3ef0c`): dropped `powersave` and plymouth. Added server basics
   (as on maple) and nvidia-persistenced. Marked `hardware-configuration.nix` as
   a placeholder: it was never generated on the machine.
3. **Monitoring** (`d894835`): ported from `feature/monitoring-stack` (below).

### `feature/monitoring-stack`: what was ported

| Branch content | Here |
|---|---|
| `monitoring.nix` (Prometheus, Grafana, node/nvidia-gpu/systemd exporters) | `features/monitoring.nix`, reworked. Exporters bind 127.0.0.1 (the branch used 0.0.0.0). GPU exporter only on NVIDIA hosts. Grafana is tailnet-only through the firewall. The admin password is generated on first start (the branch kept `admin/admin`). llama targets are read from llama-swap's config instead of a hard-coded list |
| `ai-server.nix`: fixed ports + `--metrics` | re-done on today's model set (`mkModel`) |
| `llama-cpp-overview.json`, `nvidia-gpu-metrics.json` | `features/monitoring/dashboards/`, as fixed on the branch |
| `node-exporter-full.json` (680 KB) | not committed. Fetched from grafana.com (dashboard 1860, rev 46, hash-pinned) |
| `docs/plans/2026-04-01-monitoring-stack.md` | not ported (implementation plan, now done) |
| `zellij` on peacelily | not ported (comes with the agent-host role, §3.6) |
| `flake.lock`, `.claude` settings commits | skipped, as asked |

**The branch can be deleted** once `peacelily-prep` is merged:
`git branch -D feature/monitoring-stack`. Claude did not delete it.

## 3. Decisions for you

### 3.1 CUDA package set (backlog: `nixpkgs-cuda` pin)

On the current nixpkgs rev (`b349185`), **cache.nixos-cuda.org already has the
`cudaSupport = true` builds** of everything ai-server needs. Checked 2026-11-24
(narinfo 200): torch 2.11.0, ctranslate2 4.7.2, onnxruntime 1.24.4,
wyoming-faster-whisper, wyoming-piper, python3.13-kokoro, llama-cpp 9190.
Without CUDA, Whisper large-v3 on the CPU takes seconds per utterance.

| Option | What | Cost |
|---|---|---|
| **A (recommended now)** | A second instance of the **existing** `nixpkgs` input with `config.cudaSupport = true`, used only for the AI service packages | No lock change. The rest of the system is unchanged. One more nixpkgs eval (~seconds). Substitutes only while cuda hydra has built our rev, so check before each `nix flake update` |
| B (backlog item) | Separate `nixpkgs-cuda` input pinned to `hydra.nixos-cuda.org/job/nixos-cuda/channel-26.05/_tested/latest` | Cache hits guaranteed across bumps. Costs a second input to bump by hand, and the AI packages can lag the system |
| C | Global `nixpkgs.config.cudaSupport = true` on peacelily | Rebuilds anything with a CUDA flag in the closure. Likely long uncached builds. Not recommended |

Sketch for A (in `ai-server.nix`; `inputs` from the flake-parts module args):

```nix
pkgsCuda = import inputs.nixpkgs {
  inherit (pkgs.stdenv.hostPlatform) system;
  config = { allowUnfree = true; cudaSupport = true; };
};
# services.wyoming.faster-whisper.package = pkgsCuda.wyoming-faster-whisper;
# services.wyoming.piper.package = pkgsCuda.wyoming-piper;
# kokoroPython = pkgsCuda.python313.withPackages (...);
# llama-cpp-cuda = pkgsCuda.llama-cpp;   # same store path as today's override
# cudaPkgs = true;
```

**VRAM:** Whisper large-v3 on CUDA keeps about 3-4 GB resident, Kokoro about 1 GB.
That does not fit next to `qwen3.5:9b-coding` with its 64k context in 16 GB.
Pick one:
- `large-v3-turbo` with `int8_float16`, about 1.5 GB;
- STT on the CPU and TTS on the GPU;
- the existing `dictation-server` (whisper.cpp on Vulkan, cache.nixos.org,
  socket-activated with idle unload). This is the better fit for the
  `dictate` clients/phone anyway.

Recommendation: A, with Whisper `large-v3-turbo`. Say the word and Claude
implements it.

### 3.2 Per-host age key (security audit)

Today every host holds the **primary** age key, which decrypts every secret in
the repo, admin credentials included. peacelily runs several network services.
Recommendation: switch peacelily to its SSH host key, as fern does:

1. Merge this branch and redeploy (sshd then generates `/etc/ssh/ssh_host_ed25519_key`).
2. On hazel/butternut: `ssh -p 7654 peacelily cat /etc/ssh/ssh_host_ed25519_key.pub | nix run nixpkgs#ssh-to-age`.
3. Claude adds `&peacelily` to `.sops.yaml` with rules for `secrets/peacelily/` and
   the shared files peacelily reads (`tailscale`, `tailscale-oauth`, `wifi`), and
   sets `sops.age.keyFile = lib.mkForce null; sops.age.sshKeyPaths = [...]` on peacelily.
4. You run `sops updatekeys -y` on those four files, redeploy, then
   `ssh -p 7654 peacelily rm ~/.config/sops/age/keys.txt`.

Also fill in the registry `hostKey` for peacelily with the host key from step 2
(`modules/hosts-registry.nix`, TODO there).

### 3.3 LUKS (security audit)

The current disk is plain ext4. Adding LUKS means a **reinstall**: disko
reformats the disk, which wipes the model cache, the LibreChat DB and Qdrant.
peacelily is a headless desktop, so the unlock options are:
- **TPM2 + PIN fallback** (`systemd-cryptenroll --tpm2-device=auto`, systemd
  initrd): unattended reboots. Recommended if it is encrypted at all.
- initrd SSH (`headless-boot.initrdSsh`): it only binds a static cable address
  today, so it would need generalising to the LAN.
- USB key stick (`headless-boot.usbKeyfile`).

Recommendation: **redeploy now without LUKS**. Do LUKS + TPM2 only if you
reinstall anyway (path B), and say so first so Claude can write the disko change.

### 3.4 Kernel (backlog "LTS kernel on NVIDIA hosts")

Already done: `nvidia.nix` defaults to `pkgs.linuxPackages` (6.18.63 LTS) since
2026-11-17. peacelily inherits it. Nothing to decide unless the Arrow Lake CPU
needs a newer kernel. The 6.18 LTS supports it.

### 3.5 Other options (not done)

- **LAN remote builder** (backlog): butternut is the builder. Making peacelily one
  (`builderFor`, harmonia on the LAN) is worth it only after it runs stably.
  It needs a DHCP reservation first (`lan = null` in the registry; the network
  review suggested 192.168.100.11).
- **Qdrant API key**: `preferences.ai-server.qdrantApiKey.enable = true` once
  `secrets/peacelily/qdrant.yaml` exists (key `qdrant_api_key`, `openssl rand -hex 32`).
- **LibreChat search**: `services.librechat.meilisearch.enable` + a master key
  in sops. **Web search**: re-enable SearXNG (needs `searx_secret_key`).
- **`tailscale serve`** for LibreChat/Grafana/Qdrant (HTTPS on the tailnet name,
  services on loopback), as the network review sketches. The current pattern
  (0.0.0.0 + tailscale0-only firewall) is consistent with the rest of the fleet.
- **Disk**: one NVMe, single ext4. Models alone are about 35 GB
  (`/var/cache/llama.cpp`). Check `df -h /` before Immich moves here.

### 3.6 Later items: what peacelily needs for them

- **Immich move** (2026-11-22 design): import `immich` with `cuda = true`. Needs
  disk space for the library (a second disk?), the B2 backup secrets, and
  option A above for CUDA onnxruntime.
- **Mail triage**: nothing yet. It will be a small service calling llama-swap.
- **Agent host** (registry role `agent-host`): `agent-host` + `zellij` +
  linger. Not imported yet. The agentic design has peacelily joining in step 8.

## 4. Runbook

Run from **butternut**: it builds the CUDA closure itself, and hazel's 256 GB
disk must not receive it. Commands are fish-compatible.

### 4.0 Merge and sync

```fish
cd ~/nixconf
git merge --ff-only peacelily-prep    # or however you merge
just sync
```

### 4.1 Reach the machine

The April system has **no sshd**. Its Tailscale node key has probably expired
(offline for more than 180 days), and the shared auth key in sops is likely
expired too. So the first contact is the **physical console**: plug in a
monitor and keyboard, log in as `hfahmi` (old password).

```sh
tailscale status                # "Logged out" / "expired"?
doas tailscale up --ssh         # prints a login URL: open it on the phone
nixos-version
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINTS
df -h /
nvidia-smi -L
ls -l ~/.config/sops/age/keys.txt
```

Expect partitions labelled `disk-main-ESP` and `disk-main-root` on
`nvme0n1` (the layout from `disko.nix`). If you see that and the age key is
there, **redeploy** (4.2). If only the age key is missing, push it after
`tailscale up` (from butternut; Tailscale SSH on port 22):

```fish
ssh -p 22 hfahmi@peacelily 'mkdir -p ~/.config/sops/age && umask 077 && cat > ~/.config/sops/age/keys.txt' < ~/.config/sops/age/keys.txt
```

If the layout differs, or the disk is to be wiped or encrypted, **reinstall** (4.3).

### 4.2 Redeploy (keeps data)

1. Hardware config. From butternut, approve the Tailscale SSH check once
   (it opens a browser link), then fetch the generated config:

   ```fish
   ssh -p 22 hfahmi@peacelily true
   ssh -p 22 hfahmi@peacelily nixos-generate-config --show-hardware-config --no-filesystems > /tmp/peacelily-hw.nix
   ```

   Give `/tmp/peacelily-hw.nix` to Claude. Claude merges it into
   `modules/nixos/hosts/peacelily/hardware-configuration.nix` (flake-parts
   wrapper) and commits. Then `just sync`.

2. Dry run, then install as the boot entry. Port 22 = Tailscale SSH, because
   sshd doesn't exist yet. Use `boot`, not `switch`: the kernel changes, and
   the Tailscale/firewall switch could drop the session.

   ```fish
   just deploy-plan peacelily
   DEPLOY_SSH_PORT=22 just deploy peacelily --dry-run
   DEPLOY_SSH_PORT=22 just deploy peacelily boot
   ssh -p 22 hfahmi@peacelily doas reboot
   ```

   If deploy stops with "runs commit … this checkout does not have", the April
   system was deployed from a checkout that isn't here. Check it, then add `--force`.

3. After the reboot, sshd runs on 7654: `ssh -p 7654 peacelily` (or plain
   `ssh peacelily`: the registry ssh config sets the port). From now on it's
   just `just deploy peacelily`.

### 4.3 Reinstall (wipes the disk)

Boot the NixOS minimal ISO on peacelily. Set a root password (`sudo passwd root`)
and note its LAN IP (`ip -br addr`). Then from butternut:

```fish
ssh root@<ip> nixos-generate-config --show-hardware-config --no-filesystems > /tmp/peacelily-hw.nix
# → Claude updates hardware-configuration.nix (+ disko for LUKS if chosen), commit, just sync
./scripts/install-host.sh peacelily <ip>
```

install-host.sh builds locally (so on butternut), copies the primary age key,
and partitions `/dev/nvme0n1` with disko. After the first boot, Tailscale logs
in through the OAuth client with the registry tags.

### 4.4 Tailscale tags and registry

- Tags: a node re-authenticated by hand (4.1) is user-owned. Apply the registry
  tags and disable key expiry with the tailnet-as-code apply
  (`scripts/tailscale/apply.sh`, docs/plans/2026-11-17-tailnet-as-code.md).
  Or `doas tailscale logout` on peacelily and let `tailscaled-autoconnect` log
  in again with the OAuth client.
- Check the tailnet IP still matches the registry (`ts4 = "100.127.239.128"`).
  If not, give Claude the new one. Pin it in the admin console.
- Give Claude the host key for `hostKey`:
  `ssh -p 7654 peacelily cat /etc/ssh/ssh_host_ed25519_key.pub`.

### 4.5 Verify

On peacelily (`ssh peacelily`):

```sh
nixos-version --configuration-revision
uname -r                                   # 6.18.63
nvidia-smi                                 # 595.71.05, RTX 5060 Ti
systemctl --failed
systemctl status llama-swap wyoming-faster-whisper-english wyoming-piper-english \
  wyoming-openwakeword kokoro-tts qdrant librechat mongodb prometheus grafana --no-pager | grep -E '●|Active'
tailscale status --self
doas cat /var/lib/grafana/admin_password   # Grafana login: admin / this
```

From hazel or butternut (tailnet):

```sh
curl -s http://peacelily:9292/v1/models | jq -r '.data[].id'
curl -s http://peacelily:9292/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5:4b","messages":[{"role":"user","content":"Say hi"}],"max_tokens":20}' | jq -r '.choices[0].message.content'
curl -s http://peacelily:6333/collections | jq .status
curl -sI http://peacelily:3080 | head -1       # LibreChat
curl -sI http://peacelily:3000/login | head -1 # Grafana
# The model loaded above should be "up" in Prometheus:
ssh peacelily curl -s 'http://127.0.0.1:9090/api/v1/query?query=up' | jq -r '.data.result[] | "\(.metric.job) \(.metric.instance) \(.value[1])"'
# Not reachable from the LAN (only tailscale0), from another LAN machine:
#   curl -m 3 http://<peacelily LAN IP>:9292/v1/models   → timeout
```

LibreChat accounts: registration was open in April, so a redeploy keeps the
existing account(s). After a reinstall (fresh DB) registration is closed: set
`ALLOW_REGISTRATION = true` in `ai-server.nix`, deploy, register, set it back,
and deploy again.

Expected warning on every eval/deploy until §3.1 is decided:
`ai-server: nixpkgs is not built with cudaSupport …`.
