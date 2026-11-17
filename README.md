# nixconf

My NixOS fleet as one flake: two laptops, two headless boxes and an
on-demand cloud agent host, all on **nixos-26.05**, built with
[flake-parts](https://github.com/hercules-ci/flake-parts) and
[import-tree](https://github.com/vic/import-tree) (the "dendritic" pattern).

[![NixOS 26.05](https://img.shields.io/badge/NixOS-26.05-5277C3?logo=nixos&logoColor=white)](https://nixos.org)
[![Built with flake-parts](https://img.shields.io/badge/built%20with-flake--parts-7EBAE4)](https://flake.parts)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

> [!WARNING]
> This is a personal config. It is public so other people can read it, but it
> is not a distro. It will not build on your machine as it is: it expects my
> hardware, my sops/age keys, my tailnet and my username. Take ideas and copy
> modules, but don't run `nixos-rebuild` against it. To start from it, at a
> minimum replace `modules/user.nix`, `modules/ssh-keys.nix`,
> `modules/hosts-registry.nix`, every `hardware-configuration.nix` / `disko.nix`,
> and `.sops.yaml` and `secrets/`.

## Hosts

| Host | Machine | Role | Notable |
|------|---------|------|---------|
| **hazel** | ThinkPad E14 Gen 2, i5-1135G7, 256 GB | Primary, carried | Sway, greetd, battery-aware. Edits the repo and deploys every host. Never builds big things: its nix daemon sends builds to butternut |
| **butternut** | ASUS TUF, Alder Lake + RTX 3050 | Desk build server, agent host, cache | A laptop with a broken panel, used as a desktop on an external monitor and on AC. Remote builder for hazel, harmonia cache, NVIDIA PRIME with the dGPU kept awake for CUDA, LTS kernel |
| **maple** | Intel laptop, dead screen | Headless, always on | SSH and Tailscale, syncthing, nix-serve, docker and k8s CLI. Lid and suspend ignored |
| **peacelily** | Intel + NVIDIA | Headless GPU AI server | llama-swap, Wyoming STT/TTS, Qdrant, LibreChat. *Not yet redeployed with the current config* |
| **fern** | EC2, eu-central-1 | On-demand cloud agent host | Started with `cloud-box up/down`, stops itself when idle. IaC in [`infra/aws/`](infra/aws). *Not created yet* |

Test VMs: `desktop-vm` (Sway) and `niri-desktop-vm` (Niri, currently broken).

Hosts, addresses, SSH keys, Syncthing IDs, Tailscale tags and builder roles all
come from one registry, [`modules/hosts-registry.nix`](modules/hosts-registry.nix).
`/etc/hosts`, SSH `known_hosts`, the Syncthing mesh and the remote builders are
all generated from it.

## Highlights

- **Dendritic layout.** Every `.nix` file under `modules/` is a flake-parts
  module, and `flake.nix` is a single line. There are no `imports = [ ./… ]`
  path lists: features export `flake.nixosModules.<name>`, and hosts pick from
  them by name.
- **One registry for the fleet.** Hosts, addresses, keys and roles are
  declared once and every network-facing module reads them from there (see
  [Hosts](#hosts)).
- **Secrets with sops-nix and age.** Each host has its own files
  (`secrets/<host>/<service>.yaml`), and paths are built from the hostname, so
  features don't hardcode hosts ([`secrets/README.md`](secrets/README.md)).
- **Wrapped programs.** fish, kitty, git, neovim, jj and others are built as
  standalone packages with their config baked in
  ([`modules/wrappedPrograms/`](modules/wrappedPrograms)), so they also run
  outside NixOS:
  `nix run github:hzmmohamed/nixconf#neovim`.

## Interesting modules

These go beyond setting a few options and are the parts most worth borrowing.
Each one has a header comment explaining how it works.

### Voice

- **Push-to-talk [dictation](modules/nixos/features/dictation.nix) into any
  window.** Hold `Mod4+d` to record and release to stop, or tap to latch.
  Silero VAD cuts the recording at natural pauses, and each segment is
  transcribed while you keep talking. `stream` mode types each segment at its
  pause. `batch` mode, the default, types everything once you stop. A journal
  makes drafts crash-safe, a picker lets you reopen earlier drafts, and a live
  overlay shows progress.
- **[GPU dictation server](modules/nixos/features/dictation-server.nix).**
  This is whisper.cpp with Whisper large-v3-turbo on butternut's RTX 3050,
  using Vulkan, so no CUDA toolkit is needed. It is socket-activated: the
  model loads while you start speaking, and the server stops after a period
  of idleness to give the ~1.2 GB of VRAM back to CUDA work. Clients use the
  first server they can reach, and otherwise fall back to Parakeet on the
  local CPU.

### Desktop and theming

- **[Wallpaper subsystem](modules/nixos/features/wallpaper/wallpaper.nix).**
  One command, `set-wallpaper`, runs `awww`, swaps to a paired light/dark
  default when darkman flips the mode, and keeps the license attribution of
  every image in a JSON file next to it. The defaults are an openly licensed
  light/dark pair from Wikimedia Commons, fetched at build time.
- **[Palette from the wallpaper](modules/nixos/extra/theme-palette.py).**
  matugen extracts the palette and a contrast contract then enforces it:
  every text and UI role is stepped in OKLCH lightness until it meets its
  WCAG 2.2 ratio against its surface. The static palettes face the same rule
  in a flake check (`design-contrast`). The palette files are re-rendered and
  `theme-mode light|dark` reloads every app, with no rebuild
  ([`extra/theme.nix`](modules/nixos/extra/theme.nix),
  [design system](docs/plans/2026-11-17-design-system.md)).
- **[Wallpaper search in the launcher](modules/nixos/features/vicinae-wallpapers.nix).**
  A [vicinae](modules/nixos/features/vicinae.nix) extension, written here,
  that searches Openverse, the Wikimedia picture of the day and NASA APOD.
  It previews, applies and favourites wallpapers and keeps their
  attribution.
- **Small desktop tools.**
  [`window-switch`](modules/packages/window-switch.nix) lists every Sway
  window, heaviest first by the summed RSS of its process tree, and can focus
  or kill it.
  [`audio-sink-menu`](modules/packages/audio-sink-menu.nix) picks an output
  and moves every playing stream onto it.
  [`desktop-status`](modules/packages/desktop-status.nix) provides bar widgets
  (unread mail, Syncthing, agent sessions, nix builds, free disk, camera in use) that stay hidden while
  there is nothing to show. They work in both waybar and Noctalia.
- **[Removable media](modules/nixos/features/removable-media.nix).** udiskie
  is the only automounter. A bar icon appears only while a device is mounted,
  and LUKS sticks open a themed passphrase dialog.
- **[Headset-aware audio](modules/nixos/hosts/butternut/audio.nix).** A
  WirePlumber policy makes a newly connected headset the default device and
  switches back to the previous choice when it disconnects. DeepFilter
  denoises the built-in mic only.

### Networking

- **[Café-safe firewall](modules/nixos/features/trusted-networks.nix).**
  Features open their LAN ports (KDE Connect, Syncthing, mDNS, spotifyd, …)
  only on trusted networks: the tailnet, the direct cable, and named
  NetworkManager profiles. The wired LAN counts as trusted only while its
  gateway's MAC address is the home router's. On any other Wi-Fi those ports
  stay closed.
- **[Cable link](modules/nixos/features/cable-link.nix).** Plug in an
  ethernet cable and NetworkManager picks the right profile by itself: DHCP
  when the other end is the router, a static point-to-point link when it is
  the other laptop. Manual profiles let either laptop share its internet
  with the other. [mDNS](modules/nixos/features/lan-discovery.nix) means the
  hosts still find each other as `<host>.local` without DNS or Tailscale.
- **Tailnet as code.** The ACL policy and the OAuth clients for tagged logins
  live in OpenTofu under [`infra/tailscale/`](infra/tailscale).

### Fleet and deploys

- **[`deploy`](modules/packages/deploy.nix).** It works out where each host
  should be built. Hosts marked `buildOnTarget` build on the target. Other
  hosts build on the deploying machine's remote builder and then substitute
  from butternut's harmonia cache. Activation runs as a transient systemd
  unit, so a dropped SSH connection doesn't leave a host half-switched.
  `--plan` prints the plan and runs nothing.
- **[Remote builder](modules/nixos/features/nix-builder.nix).** hazel's
  256 GB disk never builds anything big: its daemon offloads to butternut
  over `ssh-ng` with a forced `nix-daemon --stdio`, and falls back to local
  builds when butternut is unreachable.
- **[`nixconf-sync`](modules/packages/nixconf-sync.sh).** It keeps this repo
  in step between machines over SSH, without GitHub. It fast-forwards when
  one side is behind and refuses when the two have diverged. It pushes only
  to a side ref, so the peer's working tree, where agents may be busy, is
  never touched.
- **[Dual-mode headless boot](modules/nixos/features/headless-boot.nix).**
  This is for a laptop that also has to work without a screen. The LUKS key
  can come from a USB stick, with the password prompt kept as a fallback.
  Initrd SSH lets you unlock over the cable. greetd starts only when an
  external display is connected, and the machine sends an "I'm up" ntfy
  push.

### Agents

- **[Agent tooling](modules/nixos/features/agent-common.nix).** Claude Code
  comes with shared MCP servers and pinned skills. Managed keys (permission
  denies, notification and status hooks) are merged into
  `~/.claude/settings.json` without replacing the file. Two accounts are
  supported, personal and work.
  [`agent-host`](modules/nixos/features/agent-host.nix) and
  [`agent-client`](modules/nixos/features/agent-client.nix) set up the
  compute and client roles, and T3 Code and OpenCode come pinned from flakes
  ([design](docs/plans/2026-11-17-agentic-workspace-design.md)).
- **On-demand cloud box.** [`cloud-box up/down`](modules/packages/cloud-box.nix)
  starts and stops fern. [`cloud-idle-stop`](modules/nixos/features/cloud-idle-stop.nix)
  powers fern off once there are no signs of work: no agent session working,
  no CPU load, no recent terminal input, no T3 tab open.
  [`workspace-bootstrap`](modules/nixos/features/workspace-bootstrap.nix)
  clones the projects onto the empty box, using repo URLs kept in sops so
  they stay out of this public repo.

### Secrets and the vault

- **[Local-first vault](modules/nixos/features/vault.nix).** KeePassXC in a
  Syncthing folder shared between the hosts and the Android phone.
- **[secretspec](modules/nixos/features/secretspec.nix).** Projects commit
  only the names of their secrets. This module writes each machine's
  provider config: the keyring on desktops, sops-backed files on headless
  hosts.

### Gaming

- **[Declarative non-Steam games](modules/nixos/features/gaming.nix).** Games
  are declared in `preferences.gaming.games` and run with umu + GE-Proton on
  the dGPU with gamemode, plus a declarative PCSX2 setup
  ([butternut's list](modules/nixos/hosts/butternut/games.nix)). A gamescope
  Big Picture session is in
  [`gaming-console`](modules/nixos/features/gaming-console.nix).

## Layout

```text
flake.nix                 inputs + `mkFlake (import-tree ./modules)`, nothing else
modules/
├── user.nix              the username; every module reads it from here
├── theme.nix             palettes and fonts
├── hosts-registry.nix    the fleet: addresses, keys, roles, builders
├── devshell.nix          devenv shell, treefmt (alejandra), git hooks
├── checks.nix            one eval-only check per host
├── nixos/
│   ├── base/             option declarations: preferences.*, persistance.*
│   ├── features/         one flake.nixosModules.<name> per file
│   ├── extra/            integration layers: home-manager bridge, theme, impermanence
│   └── hosts/<host>/     configuration.nix, hardware, disko, plus split files (gpu, power, …)
├── wrappedPrograms/      perSystem packages with config baked in
├── packages/             deploy, cloud-box, nixconf-sync, small tools
└── vms/                  purpose-built test VMs
infra/                    OpenTofu: aws/ (fern), tailscale/ (tailnet policy)
secrets/                  sops-encrypted, one directory per host plus shared/
scripts/                  install-host.sh (nixos-anywhere), runbook helpers
docs/plans/               designs, backlog, user action list
```

[`ARCHITECTURE.md`](ARCHITECTURE.md) goes through the modules one by one.

### Conventions

- **The directory tree is just organisation.** import-tree loads every file,
  so you can move or rename a file freely. Only the exported attribute names
  matter.
- **Flakes only see tracked files.** A new module stays invisible until you
  run `git add` on it (`git add -N` is enough).
- **Features are independent and own their infrastructure.** A feature does
  not import other features. It declares its own sops secrets, Syncthing
  folders and firewall ports. The exceptions are the `desktop` and `general`
  aggregates. Hosts do the composing.
- **No hardcoded identities.** Read the username from
  `config.preferences.user.name` (or `self.user`), the hostname from
  `config.networking.hostName`, and colours from
  `config.preferences.theme.palette.{light,dark}`. Never write hex values.

A host is a list of features:

```nix
flake.nixosModules.hostMaple = {...}: {
  imports = [
    self.nixosModules.base
    self.nixosModules.general

    self.nixosModules.sops
    self.nixosModules.openssh
    self.nixosModules.tailscale
    self.nixosModules.syncthing
    self.nixosModules.nix-serve
    # …
  ];
};
```

## Key inputs

| Input | Purpose |
|-------|---------|
| `nixpkgs` (nixos-26.05), `home-manager` (release-26.05) | Base system and user config |
| `flake-parts`, `import-tree` | Module system and automatic imports |
| `disko`, `impermanence`, `persist-retro` | Declarative disks, opt-in ephemeral root |
| `sops-nix` | Secrets |
| `wrappers`, `wrapper-modules` | Programs with baked-in config |
| `catppuccin` | Theming for apps that ship catppuccin modules |
| `noctalia` | Desktop shell (Sway hosts, `preferences.desktopShell`) |
| `claude-code`, `llm-agents`, `anthropic-skills`, `superpowers` | Agent CLIs and pinned skills |
| `nix-gaming`, `firefox-addons`, `nix-index-database`, `reticulum-flake` | Assorted features |
| `devenv`, `treefmt-nix` | Dev shell, formatting |

## Usage

The dev shell (`nix develop --impure`, or direnv) provides `just`:

```bash
just fmt                       # format (alejandra via treefmt)
just lint                      # deadnix (fatal) + statix (advisory)
just eval <host>               # evaluate one host, no build (~10 s)
just check                     # fmt-check + lint + eval every host (run before committing)

just deploy-plan <host>        # where would it build? prints, runs nothing
just deploy <host> [switch|boot|test] [--dry-run]
just deploy-all
just sync                      # sync the repo between hazel and butternut, no GitHub needed
```

Each recipe in the [`justfile`](justfile) has the raw `nix` command next to it.

<details>
<summary><b>Installing a new machine</b></summary>

1. Add the host to [`modules/hosts-registry.nix`](modules/hosts-registry.nix)
   (addresses, roles, builder relations).
2. Create `modules/nixos/hosts/<host>/configuration.nix` exporting
   `flake.nixosConfigurations.<host>` and `flake.nixosModules.host<Name>`. Add a
   `disko.nix` too, and `git add -N` both files.
3. Generate the host's secrets under `secrets/<host>/` and add its age key to
   `.sops.yaml` (see [`secrets/README.md`](secrets/README.md)).
4. Check it: `just eval <host>`.
5. Boot the target into a NixOS installer with SSH, then:
   `scripts/install-host.sh <host> <ip>` (nixos-anywhere + disko; copies the
   age key; `--cache` uses the local nix-serve).
6. Fill in the real `hostKey` and `syncthingId` in the registry, then
   `just deploy <host>`.

</details>

<details>
<summary><b>Adding a feature</b></summary>

1. Create `modules/nixos/features/<name>.nix` exporting
   `flake.nixosModules.<name>`. Declare its options under
   `preferences.<name>.*`.
2. Keep everything the feature needs (secrets, Syncthing folders, firewall
   ports, persistence paths) in that file.
   [`shared-zotero.nix`](modules/nixos/features/shared-zotero.nix) is the
   reference example.
3. `git add -N` the file, import it from the hosts that need it, and run
   `just check`.

</details>

## Working with agents

Most changes here are made with coding agents (Claude Code, OpenCode, T3
Code), and I review them. [`CLAUDE.md`](CLAUDE.md), which `AGENTS.md` links to,
is the agent briefing: golden commands, invariants, hazards, and what an agent
must never run. Deploys, `sops` and `nixos-rebuild` stay with me, and
`.claude/settings.json` blocks them. Plans and the backlog are in
[`docs/plans/`](docs/plans).

## Status

- Known broken: `niri-desktop-vm` and `packages.desktop` (niri wrapper vs niri
  26.04), and `packages.meshchatx` (insecure pnpm). `just eval-all` skips them.
  The niri and hyprland stack is slated for removal.
- Next up:
  [`docs/plans/2026-11-17-backlog.md`](docs/plans/2026-11-17-backlog.md).

## Credits

The repo started as a fork of
**[vimjoyer/nixconf](https://github.com/vimjoyer/nixconf)**, and the git
history and the MIT [LICENSE](LICENSE) come from there. Since then it has
absorbed my older Snowfall Lib config.

Ideas borrowed from other configs, and the README layout too:

- [mightyiam/infra](https://github.com/mightyiam/infra): the dendritic pattern
- [stoating/nixos](https://github.com/stoating/nixos): a flake-parts +
  import-tree setup close to this one
- [Misterio77/nix-config](https://github.com/Misterio77/nix-config)
- [ryan4yin/nix-config](https://github.com/ryan4yin/nix-config)
- [fufexan/dotfiles](https://github.com/fufexan/dotfiles) (and nix-gaming)
- [iynaix/dotfiles](https://github.com/iynaix/dotfiles)
- [dbeley/nixos-config](https://github.com/dbeley/nixos-config)
- [tetra-fox/nix-config](https://github.com/tetra-fox/nix-config)
- [repinek/nixos-dotfiles](https://github.com/repinek/nixos-dotfiles)
- [ladas552/flake-ocean](https://tangled.org/ladas552.me/flake-ocean)
- [MostlyKIGuess/nix-flake-public](https://github.com/MostlyKIGuess/nix-flake-public)
- [noctalia](https://github.com/noctalia-dev/noctalia-shell) and
  [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell): desktop shells
