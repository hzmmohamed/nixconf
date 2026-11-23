# Phone as a fallback workstation: T3 + coding agents on Android, from nixconf

Status: research, 2026-11-22. Nothing implemented. Input for a design/plan.
Phone: Xiaomi 11T Pro (vili), Snapdragon 888, 8 GB, aarch64, tailnet node `21081111rg`
(registry `phone`).

**Legend.** ✅ checked in this session (command run, output seen) · 📄 upstream docs or
source say so · 🗣 community or anecdotal reports (one or two sources, may be stale) · ❓ my
inference, not checked.

---

## Verdict

**Feasible, probably. The base should be Nix-on-Droid.** It is the only option that is both
glibc (so the store builds of T3, Claude Code and OpenCode run unmodified) and declarative
from this flake. Everything heavy is already in binary caches for aarch64-linux, so the phone
never builds anything big:

- ✅ `cache.numtide.com` serves aarch64-linux builds of `t3code` 0.1.9, `claude-code`
  2.1.326 and `opencode` 1.19.5 at the repo's pinned `llm-agents` rev.
- ✅ `cache.nixos.org` covers nixos-26.05 aarch64 for git, node, fish, neovim and the rest.
- ✅ A Nix-on-Droid config built on nixos-26.05 + home-manager release-26.05 + those
  packages evaluates on butternut today.

**Biggest risk: does Claude Code's native binary run under proot?** Every glibc route on
this phone is proot (Nix-on-Droid, proot-distro). An Anthropic issue reports an infinite
self-relaunch loop under proot (#86798, v2.1.232, closed "not planned"). Another community
project says the latest binary works fine in proot-distro Ubuntu. The spike below settles
this in about 20 minutes. If it fails, the idea is roughly dead: the fallbacks are an older
JS build of Claude Code, or OpenCode only.

Android's Linux Terminal (AVF) is out. The phone's last OS is Android 14 (HyperOS 1), and the
Terminal needs Android 15+ plus non-protected-VM support, which Snapdragon chips mostly lack.

---

## Recommended architecture

```
Android 14 / HyperOS 1
├─ Tailscale app (VPN; node 21081111rg)         ← unchanged
├─ T3 Code mobile app ──► http://127.0.0.1:3773  (phone's own T3; loopback)
│                    └──► https://butternut.<tailnet>.ts.net (as today)
└─ Nix-on-Droid app (com.termux.nix; proot; glibc userland from /nix/store)
   ├─ tmux
   │  ├─ t3 serve --host 127.0.0.1 --port 3773   (llm-agents t3code.unwrapped, aarch64)
   │  └─ shells: fish/git/neovim from the repo's wrapped programs (aarch64)
   ├─ claude (llm-agents claude-code, aarch64)  [+ opencode, optional]
   ├─ ~/src/<small project> with its aarch64 dev shell, realised in advance
   └─ sshd :8022 (optional; lets hazel/butternut push generations)

nixconf
└─ modules/droid/phone.nix → flake.nixOnDroidConfigurations.phone
   built on butternut (binfmt aarch64 for the trivial local derivations)
   → harmonia → phone substitutes on home Wi-Fi; heavy paths come from numtide/nixos caches
```

**Operating rule.** The phone gets updates only on Wi-Fi at home: switch, prefetch project
shells, clone repos. In fallback mode the phone uses only its local store plus the Anthropic
API over mobile data. "Fallback" means no home machines, not no internet: agents need the API.

---

## 1. Base layer choice

| | Nix-on-Droid | Termux + repo bootstrap script | Termux + proot-distro (Ubuntu) | Android Linux Terminal (AVF) |
|---|---|---|---|---|
| libc | glibc (nixpkgs aarch64) | bionic | glibc | glibc (real VM) |
| Store builds of t3/claude/opencode | ✅ run as-is (glibc) | ❌ glibc + /nix/store paths | ❌ not Nix; npm/curl installers | n/a |
| Claude Code | native linux-arm64 binary under proot; loop risk (🗣 #86798) | 📄 ≥2.1.113 needs glibc; community `glibc-runner` patching, or pin 2.1.112 (🗣) | 🗣 works with latest (claude-code-android Path B); loop risk the same | 🗣 SIGILL regression reported on AVF (#55519) |
| T3 server (node-pty, ffi-rs, koffi, fff, keyring natives) | prebuilt linux-arm64 glibc natives in the store build | rebuild every native against bionic; `fff-bin` has no android target ❓ | npm install, glibc prebuilds | n/a |
| Overhead | proot (ptrace on every syscall) | none | proot | VM, near-native |
| Declarative from this flake | ✅ `nixOnDroidConfigurations` + home-manager | partial (dotfiles + pkg list) | no | no |
| Termux:API / Widget / Boot | ❌ different sharedUserId (`com.termux.nix`); `android-integration.*` gives `termux-wake-lock`, `termux-open-url`, `xdg-open`, `am`, `termux-setup-storage` 📄 | ✅ | ✅ | n/a |
| Health | "prototype"; last code change 2026-07; app based on Termux 0.118.0, targetSdk 28 ✅ | Termux: active | active | ❌ not on this phone |

**Why Nix-on-Droid:**

- It is the only option where "the repo's packages run on the phone" holds without
  repackaging anything. The aarch64 store builds already contain linux-arm64 prebuilds for
  every native module T3 ships ✅ (the package maps `aarch64-linux → linux-arm64` in
  `llm-agents/packages/t3code/unwrapped.nix`).
- The proot overhead is the same price proot-distro pays.
- Losing Termux:API/Widget/Boot costs little. Wake lock and URL opening come built in via
  `android-integration`. Boot autostart isn't needed for a fallback you start by hand.

**Compatibility check** (✅, run in this session): Nix-on-Droid master `3264519` with this
repo's nixpkgs (26.05.20261115) + home-manager release-26.05 evaluates
`environment.path` and the home-manager generation with `git`, `claude-code` and
`t3code.override {providerPackages = [];}`, with no warnings. Two caveats:

- Its modules still call `lib.mdDoc`, which nixpkgs 26.05 removed. That's harmless while
  only option descriptions use it, but building its manual would fail ❓.
- `activationPackage` hard-codes an aarch64 `proot-termux-static` store path (2026-02-20)
  and needs `--impure`. That path is on `nix-on-droid.cachix.org` ✅ but not on
  cache.nixos.org, so an x86 eval can't produce `activationPackage` without fetching it.

## 2. T3 server on aarch64 Android

What T3 0.1.9's server needs at runtime ✅ (from the installed store path):

- Node `^22.16 || >=24.10`; the wrapper pins nodejs 24.21.
- SQLite is Node's built-in `node:sqlite`, not a native module.
- Native `.node` modules: `node-pty` (terminals), `@napi-rs/keyring`, `ffi-rs`, `koffi`,
  `bufferutil`/`utf-8-validate`, the `@cursor/sdk` tree-sitter bindings, and
  `@ff-labs/fff-bin` (file finder).
- `transcribe-cpp` (server-side dictation; the x86 build ships `linux-x64-cpu-vulkan`).
  Optional: the mobile app dictates on-device 📄.
- `playwright-core` (needs a browser; skip on the phone).
- Plus a git binary and the provider CLIs on PATH.
- Closure: 729 MiB unpacked, ~180 MiB download for aarch64 ✅.
- RSS on butternut: ~450 MiB for the server, ~290–340 MiB per Claude session ✅.

**Under Nix-on-Droid** it should run as a plain Linux process ❓. `process.platform` is
`linux`, because the glibc node doesn't know it's on Android. Unknowns for the spike:

- node-pty under proot (forkpty/`/dev/ptmx`): 🗣 shells and tmux work in proot.
- Keyring with no D-Bus/secret service: ❓ expect a fallback or a warning.
- `os.networkInterfaces()`: proot apps hit netlink restrictions only with targetSdk ≥ 30,
  and the app targets 28 ✅.

**Keeping it running.** No service manager exists: start `t3 serve` in tmux. No
`--tailscale-serve` either: the Android Tailscale app exposes no CLI or local API inside
proot.

**Phone client → phone server.** Pair the mobile app with `http://127.0.0.1:3773`. Two
things suggest this works:

- 📄 "A loopback address such as 127.0.0.1 reaches only the device opening the link".
- 📄 On mobile, an address without a scheme uses HTTP, so the app allows cleartext.

Loopback also counts as a secure context for MCP sign-in 📄.

**Pairing with the other environments:**

- *Phone app → butternut etc.*: unchanged (HTTPS via Tailscale Serve).
- *Hazel → phone T3* (hazel on the phone's hotspot): `t3 serve --lan`, then pair from the
  desktop app over HTTP 📄. Plain HTTP, but the hotspot is a private link.
- *Linked environments / `t3-link`* (server to server, `delegate_task`): **HTTPS required,
  HTTP refused** (#26840, see `2026-11-17-t3code-integration.md` §3.4). To get HTTPS on the
  phone, run a second, userspace tailnet node inside Nix-on-Droid:
  `tailscaled --tun=userspace-networking --state=… --socket=…` as e.g. `phone-t3`, then
  `tailscale --socket=… serve` (📄 the mode exists; 🗣 it runs in Termux/proot). Leave this
  for phase 2: the fallback scenario has nothing to link to.

## 3. Claude Code and OpenCode on the phone

- 📄 Official: Linux arm64 with glibc or musl. Android/bionic isn't supported. Since 2.1.113
  the npm package is a stub that pulls a native glibc binary, so plain Termux broke.
  linux-arm64-android builds are a feature request with no answer (🗣 #72620, #50270).
- **Termux (bionic)** 🗣: either pin 2.1.112 (the last JS build; needs Node ≥25 because 24
  hangs), or run the linux-arm64 binary through `glibc-runner` with patching
  (ferrumclaudepilgrim/claude-code-android "Path A"). Known gotchas there:
  - Bun's c-ares reads `/etc/resolv.conf`, which Termux lacks.
  - The vendored ripgrep has no android build.
  - `/tmp` isn't writable.
  - Shebang scripts break.
- **glibc under proot** 🗣: the same project's "Path B" (proot-distro Ubuntu) reports the
  latest version working. Against that, #86798 (2026-08, v2.1.232–233) reports
  `proot-distro login ubuntu -- claude.exe` re-execing its whole host command chain forever,
  probably from `/proc/self/exe` resolution. It was auto-closed, with no workaround. **Most
  important unknown; the spike tests it first.**
- Nix-on-Droid already avoids several of the Termux gotchas:
  - ✅ It writes `/etc/resolv.conf` (1.1.1.1, 8.8.8.8).
  - ✅ The Nix `claude-code` is the official linux-arm64 binary, wrapped with
    `DISABLE_AUTOUPDATER=1` and with `bubblewrap`/`socat` on PATH.
  - 🗣 The linux-arm64 binary bundles its own ripgrep.

  The sandbox (`bubblewrap`) can't work under proot ❓. Leave it off; the user approves
  commands in T3 anyway.
- **OpenCode**: a Bun-compiled binary, aarch64 in numtide's cache ✅ (~92 MiB closure
  download). 🗣 Unreliable in plain Termux, fine in proot.
- **Auth.** Run `claude setup-token` on butternut (a long-lived subscription OAuth token),
  store it in the KeePassXC vault (already synced to the phone), and on the phone export
  `CLAUDE_CODE_OAUTH_TOKEN` for `t3 serve`. This beats a browser OAuth dance on the phone,
  and beats copying `~/.claude/.credentials.json`, where refresh-token rotation fights the
  other machine ❓. The browser flow should also work through
  `android-integration.xdg-open` / `termux-open-url` 📄, with paste-code as the fallback.

## 4. aarch64 closures without building on the phone or on mobile data

| Source | Covers | Status |
|---|---|---|
| cache.nixos.org | nixpkgs 26.05 aarch64-linux (git, node, fish, neovim, tmux, python) | ✅ |
| cache.numtide.com | llm-agents aarch64 (t3code, claude-code, opencode) at the pinned rev | ✅ |
| nix-on-droid.cachix.org | proot-static, bootstrap bits | ✅ (proot path) |
| *nothing* | the repo's own derivations: wrapped-program wrappers, Nix-on-Droid activation scripts, `t3code.override {providerPackages=[];}` wrapper | trivial `runCommand`s that must run on aarch64 |

The tiny local derivations can be built two ways:

- **(a) On the phone** during `nix-on-droid switch`: seconds of CPU, no big downloads. Fine
  for the bootstrap.
- **(b) On butternut**, with `boot.binfmt.emulatedSystems = ["aarch64-linux"]` (qemu-user;
  NixOS adds `extra-platforms` itself 📄). Butternut builds
  `nixOnDroidConfigurations.phone`, harmonia serves the result (harmonia doesn't care about
  architecture ❓), and the phone substitutes with butternut's key in `nix.substituters`.
  Nix-on-Droid's Nix is single-user, so the phone honours its own substituter list.
  Recommended for the steady state; it also allows a `deploy`-style push over ssh (sshd in
  Nix-on-Droid).

Don't add `aarch64-linux` back to `systems`. That would make `nix flake check`/`show`
evaluate every perSystem package for aarch64 (niri, quickshell, meshchatx…) and the devenv
shell. Instead, call the wrapped-program definitions with an aarch64 `pkgs` from the droid
module. ✅ This works today: calling `modules/wrappedPrograms/{git,fish}.nix`'s `perSystem`
with aarch64 pkgs evaluates. The plan should still factor the reuse into a cleaner
`self.lib`/`wrapperModules` entry point.

Skip cross-compilation: everything is already native aarch64 in the caches.

**Data budget** (✅, summed from narinfo FileSize / compressed NAR sizes):

| Item | Download | Unpacked |
|---|---|---|
| t3code server closure | ~180 MiB | 729 MiB |
| claude-code closure | ~180 MiB | 432 MiB |
| opencode closure | ~92 MiB | 284 MiB |
| git / node 24 / python3 / fish / neovim | 128 / 66 / 77 / 103 / 67 MiB (overlapping) | — |
| **All of the above + rg + tmux, deduplicated** | **~640 MiB** | **~2.1 GiB** |

Add the Nix-on-Droid base and its bootstrap, and each project's dev shell. Every
llm-agents bump re-downloads ~120 MiB (t3) + ~160 MiB (claude) of NARs: home Wi-Fi only.
llm-agents doesn't follow our nixpkgs, so its closures bring their own glibc and node.
Keep it that way: cache hits matter more than the duplication.

## 5. Android constraints

- **Phantom process killer** (Android 12+) 📄. It kills an app's child processes when the
  whole system has more than 32, or when they use a lot of CPU. An agent running tests
  passes 32 easily. Disable it:
  - Android 14 has **Developer options → "Disable child process restrictions"**. ❓ whether
    HyperOS shows it.
  - Or over adb:
    `settings put global settings_enable_monitor_phantom_procs false` (12L+), or
    `device_config put activity_manager max_phantom_processes 2147483647`.
  - Either survives reboots? 🗣 the settings flag does; the device_config value can be reset
    by config syncs.
- **HyperOS** 🗣: set Nix-on-Droid to battery "No restrictions", enable Autostart, and lock
  it in Recents. Hold the app's wakelock (notification button, or `termux-wake-lock` via
  `android-integration`). Keep the session in the foreground notification. The
  low-memory killer still wins under memory pressure.
- **Thermals** 🗣: the Snapdragon 888 is known for heavy throttling under sustained load.
  Expect builds and tests to slow after minutes. Charging plus a fan-less case helps.
- **RAM.** Of 8 GB, plan on ~3–4 GB for Nix-on-Droid before the low-memory killer gets
  aggressive ❓. Budget: T3 0.45 + one Claude 0.35 + proot ≈ 1 GB, leaving ~2–2.5 GB for the
  project (one dev server *or* one test runner, tsc included). One agent at a time; two if
  the project is tiny.
- **Storage.** ~2–4 GiB for the store, plus repos and node_modules, in app-private storage
  (`/data/data/com.termux.nix`). Uninstalling the app wipes it. `termux-setup-storage`
  exposes shared storage, including the Syncthing vault folder.
- **proot cost** 🗣: CPU-bound work runs at native speed. Syscall-heavy work (npm install,
  git on big trees, many small processes) is several times slower. Small repos only.

## 6. Flake wiring sketch

**Inputs to add** (named here, not added):

```nix
nix-on-droid = {
  url = "github:nix-community/nix-on-droid";   # master tracks unstable; release-24.05 is the last release branch
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.home-manager.follows = "home-manager";
};
```

`llm-agents` and `home-manager` already exist.

**Files:**

- `modules/flake-parts.nix`: add `nixOnDroidConfigurations` as a mergeable flake option,
  like `diskoConfigurations`.
- `modules/droid/` (import-tree picks it up):
  - `phone.nix`: `flake.nixOnDroidConfigurations.phone`.
  - `base.nix`: `flake.droidModules.base` (nix settings, caches, android-integration, hosts).
  - Later, `t3.nix` / `agents.nix`.
- `modules/checks.nix`: `checks.x86_64-linux.phone-eval`, evaluating
  `config.environment.path.drvPath` and the home-manager generation. Not `activationPackage`:
  that needs the aarch64 proot path in the eval store.

```nix
# modules/droid/phone.nix (sketch)
{inputs, self, ...}: let
  system = "aarch64-linux";
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays = [inputs.nix-on-droid.overlays.default];
  };
  llm = inputs.llm-agents.packages.${system};
in {
  flake.nixOnDroidConfigurations.phone = inputs.nix-on-droid.lib.nixOnDroidConfiguration {
    inherit pkgs;
    home-manager-path = inputs.home-manager.outPath;
    extraSpecialArgs = {inherit inputs self;};
    modules = [
      self.droidModules.base
      ({...}: {
        system.stateVersion = "24.05";
        user.userName = self.user.name; # ❓ check Nix-on-Droid's user module semantics (uid/gid are Android's)
        environment.packages = [
          llm.claude-code
          (llm.t3code.override {providerPackages = [];})
          pkgs.tmux pkgs.openssh
          # self.lib.wrapped pkgs .git/.fish/.neovim  (refactor of modules/wrappedPrograms)
        ];
        android-integration = {termux-wake-lock.enable = true; termux-wake-unlock.enable = true;
                               xdg-open.enable = true; termux-setup-storage.enable = true;};
        nix.extraOptions = "experimental-features = nix-command flakes";
        nix.substituters = ["https://cache.numtide.com" /* + butternut harmonia via ts4 */];
        nix.trustedPublicKeys = [/* numtide, self.nixServeKeys.butternut */];
        networking.hosts = /* from modules/hosts-registry.nix ts4 → names: resolv.conf is
                              1.1.1.1/8.8.8.8, so MagicDNS names don't resolve */ {};
        home-manager.config = {...}: {home.stateVersion = "24.05"; /* fish, git identity */};
      })
    ];
  };
}
```

**Reuse:**

- `self.user` (name; the home dir is Android's).
- `self.sshKeys`: authorized keys for sshd :8022. Add a `phone` key slot plus a registry
  `userKey`/`sshPort = 8022`.
- Wrapped programs, via aarch64 pkgs.
- `hosts-registry` (ts4 → `/etc/hosts`, which also follows the "don't rely on Tailscale
  DNS" rule).
- Theme: only the Nix-on-Droid `terminal.colors` (light *or* dark; no `theme-mode` there).
- Skip: base/features NixOS modules (they're not NixOS modules here).

**Secrets.** No sops-nix for Nix-on-Droid, and the age key stays off the phone. Instead:

- The Claude OAuth token, a GitHub fine-grained PAT or deploy key, and anything else live
  in the KeePassXC vault (Syncthing → phone). Read them with `keepassxc-cli` from shared
  storage ❓, or paste them once into `~/.config/…` files the config only references.
- Generate a phone SSH key on the phone.

**One-command bootstrap**, on a fresh Nix-on-Droid, Wi-Fi:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hzmmohamed/nixconf/main/scripts/droid-bootstrap.sh)
```

The script:

1. Writes `~/.config/nix/nix.conf` (flakes, numtide + nix-on-droid caches and keys, plus
   butternut's harmonia when reachable).
2. Runs `nix-on-droid switch --flake github:hzmmohamed/nixconf#phone`. Eval happens on the
   phone, once: minutes, plus a fetch of the inputs' tarballs.

Steady state: `deploy phone` from hazel/butternut builds on butternut, pushes over ssh to
:8022, and runs `<generation>/activate`. ❓ Check that running a generation's activate
script by hand is what `nix-on-droid switch` does.

## 7. Which projects fit

Rule of thumb for 8 GB under proot: **one agent, one small repo, one process at a time.**
Practical limits: ≲300 MB node_modules, a dev server *or* a test runner, no containers, no
GPU, no emulator.

- **Fits:** small TS/JS apps (landing page, one package, vitest/jest), Python packages with
  aarch64 manylinux wheels (glibc, so wheels work), small Go/Rust CLIs (slow first build),
  docs and scripts, reviewing and landing small PRs.
- **Doesn't fit:**
  - routelab-monorepo (Gradle/Android, >8 GB) and d_abm (69 GB data).
  - Anything needing Docker/k8s, CUDA or Chromium/Playwright.
  - Nix evaluation of this repo (each host eval ≈ 1–2 GB and minutes; deploys are
    impossible from the phone anyway).
  - Big git trees (proot makes git slow).
- **How a project declares it:** it exposes `devShells.aarch64-linux.phone` (or `default`),
  lean and fully cached. The droid config lists phone projects (`phone.projects = [{ url;
  dir; }]`), and an at-home `phone-prefetch` clones them and realises their shells. If a
  shell fails to evaluate or realise for aarch64, the project isn't phone-capable. ❓
  Optionally a `phone: true` hint in the project's AGENTS.md, so agents keep it light.

---

## Risks

1. **Claude Code under proot** (#86798 loop; the reports disagree). It kills the idea, or
   forces a pinned old JS build, which may not suit T3 0.1.9's agent SDK (0.3.321).
2. **Nix-on-Droid health.** It's a prototype with ~138 open issues. The bootstrap is pinned
   to 24.05, and modules still use the removed `lib.mdDoc` (lazy for now). An eventual
   nixpkgs change can break eval with no upstream fix; plan to carry a patched input.
3. **Android kills processes** (phantom killer, low-memory killer, HyperOS battery policy):
   sessions die mid-task. Mitigation: settings above, tmux, T3's persisted threads.
4. **Version skew.** The phone's T3 server must match the mobile app's protocol. numtide
   bumps arrive only when the phone switches on Wi-Fi, while the Play Store app may update
   itself first.
5. **Performance and thermals.** proot syscall overhead plus a throttling Snapdragon 888
   make "small project" mean genuinely small.
6. **Security.** A lost phone means an exposed Claude token, GitHub credential and T3
   pairing sessions. Mitigation: phone-scoped tokens, a written revoke procedure,
   Android's own encryption and lock.
7. **Storage.** Uninstalling or clearing the Nix-on-Droid app deletes the store and
   repos. Keep work pushed.

## Open questions only you can answer

1. Exact HyperOS/Android build? Do Developer options show **"Disable child process
   restrictions"**? (Settings → About phone.)
2. Is Nix-on-Droid already bootstrapped, and which app version? Where is Termux from: F-Droid,
   GitHub or Play? (The Play build is a different fork.)
3. Free internal storage? (≥6 GB recommended.)
4. OK with a long-lived Claude subscription token (`claude setup-token`) living on the phone?
   And a GitHub credential there, push-capable or read-only?
5. Should the phone's T3 be reachable from other machines (needs the userspace
   `phone-t3` tailnet node for HTTPS), or local-only?
6. Which concrete small projects? The landing page repo name, and which package.
7. OK to enable `boot.binfmt.emulatedSystems = ["aarch64-linux"]` on butternut (qemu-user,
   small), and an sshd on the phone (port 8022, key-only, tailnet only)?
8. Is OpenCode wanted on the phone (+~90 MiB), or Claude Code only?

---

## Spike plan (throwaway; nothing in the repo)

Goal: in about an hour, on **home Wi-Fi**, prove or kill the idea by answering four things:

1. Does `claude` run under Nix-on-Droid's proot?
2. Does `t3 serve` start?
3. Does the T3 mobile app pair with it over 127.0.0.1?
4. Can one agent run a tiny project's tests without getting killed?

It needs no flake eval on the phone: it realises the exact aarch64 store paths found above
(about 450 MiB download).

**0. Android prep** (by hand):

- Settings → About phone → tap *OS version* 7×.
- Developer options → **Disable child process restrictions** on, if present.
- Apps → Nix-on-Droid → Battery saver → *No restrictions*; Autostart on.
- Open Nix-on-Droid and pick *Acquire wakelock* from its notification.

**1. Bootstrap check** (in Nix-on-Droid; bash). If the app was never set up, let its first
run finish (it asks for a channel/flake: accept the defaults).

```bash
uname -m; nix --version; df -h ~ | tail -1; free -m 2>/dev/null || cat /proc/meminfo | head -3
mkdir -p ~/.config/nix
cat >> ~/.config/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
substituters = https://cache.nixos.org https://cache.numtide.com https://nix-on-droid.cachix.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g= nix-on-droid.cachix.org-1:56snoMJTXmDRC1Ei24CmKoUqvHJ9XCp+nidK7qkMQrU=
EOF
```

**2. Fetch the exact aarch64 paths** (llm-agents `47a7bbf`, nixpkgs 26.05.20261115):

```bash
CLAUDE=/nix/store/fc8j2dzzmnj0f4zh9l1kzam5imyz0pzy-claude-code-2.1.326
T3=/nix/store/am47qga7b0f8a6jp0948xkl9rsxdw59p-t3code-0.1.9
GIT=/nix/store/lpmhqhwfgfp5hg6hcnfgsz3hzx357q4l-git-2.54.0
NODE=/nix/store/96pgw1l4za19h8h1gyv2b94rmhd35mca-nodejs-24.22.3
TMUX=/nix/store/g1vgk897zrxkxwjawg5p8181wal9ygf5-tmux-3.7b
time nix-store --realise $CLAUDE $T3 $GIT $NODE $TMUX
export PATH=$CLAUDE/bin:$T3/bin:$GIT/bin:$NODE/bin:$TMUX/bin:$PATH
cat > ~/spike-env.sh <<EOF
export PATH=$CLAUDE/bin:$T3/bin:$GIT/bin:$NODE/bin:$TMUX/bin:\$PATH
EOF
```

**3. Kill test #1: Claude Code under proot.** If this hangs, or `ps` shows many `claude`
processes multiplying, it's the #86798 loop. Stop and report.

```bash
timeout 60 claude --version; echo "exit=$?"
ps -ef | grep -c '[c]laude'
# auth: on butternut run `claude setup-token`, copy the token via KeePassDX, then:
read -rsp 'CLAUDE_CODE_OAUTH_TOKEN: ' CLAUDE_CODE_OAUTH_TOKEN; export CLAUDE_CODE_OAUTH_TOKEN; echo
echo "export CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" >> ~/spike-env.sh; chmod 600 ~/spike-env.sh
timeout 120 claude -p 'Reply with the single word: pong'; echo "exit=$?"
```

**4. Kill test #2: T3 server plus the mobile app over loopback.**

```bash
tmux new -d -s t3 'source ~/spike-env.sh; T3CODE_TELEMETRY_ENABLED=false t3 serve --host 127.0.0.1 --port 3773 --no-browser 2>&1 | tee ~/t3.log'
sleep 20; tail -n 30 ~/t3.log
curl -sI http://127.0.0.1:3773/ | head -1
source ~/spike-env.sh; t3 pair --label phone-local --ttl 10m
```

In the T3 mobile app: Settings → Environments → Add environment → paste the pairing URL
(`http://127.0.0.1:3773/…`). If the Claude provider shows as missing, set its binary path
to `$CLAUDE/bin/claude` in the provider settings.

**5. Kill test #3: one agent on a tiny project.**

```bash
source ~/spike-env.sh
mkdir -p ~/src/spike && cd ~/src/spike && git init -q && npm init -y >/dev/null
time npm i -D vitest            # ~20–30 MB from npm (Wi-Fi)
git add -A && git commit -qm init
```

In the app: add project `~/src/spike` on the phone environment and start a thread:
*"Write `src/slug.ts` (slugify) with 10 vitest cases and run them."* While it runs, in a
second tmux window:

```bash
watch -n5 'grep -E "MemAvailable|SwapFree" /proc/meminfo; ps -eo rss,comm --sort=-rss | head -6'
```

**6. Optional: phantom-killer check.** If the Nix-on-Droid session dies within ~10 min, the
killer is still active: use the adb route.

```bash
for i in $(seq 40); do sleep 900 & done; echo started; sleep 600; jobs | wc -l
```

The adb route, from hazel with wireless debugging paired:

```bash
adb shell settings put global settings_enable_monitor_phantom_procs false
adb shell /system/bin/device_config put activity_manager max_phantom_processes 2147483647
```

**Report back** (paste):

- Output of steps 1, 3 and 4.
- Whether pairing worked.
- Test time and the lowest MemAvailable from step 5.
- Whether anything got killed.

**Pass** = all four of the goal questions answered yes. **Kill** = step 3 loops/hangs (then
try `nix-store --realise /nix/store/y89mrnddbd3x9v3g3gqw00nwkncmq030-opencode-1.19.5` as the
agent before giving up), or step 5 keeps getting killed with the settings applied.

**Cleanup:** `tmux kill-server; rm -rf ~/src/spike ~/spike-env.sh ~/t3.log; nix-collect-garbage`,
then revoke the token (`claude` account settings) and the T3 session
(`t3 auth session list` / `revoke`).

---

## Sources

- Nix-on-Droid: https://github.com/nix-community/nix-on-droid (README, `modules/environment/{android-integration,login,networking,nix}.nix`, `templates/advanced/flake.nix`, CHANGELOG); app: https://github.com/nix-community/nix-on-droid-app (`gradle.properties` targetSdk 28, `app/build.gradle` `applicationIdSuffix ".nix"`)
- Termux plugin signing / sharedUserId: https://github.com/termux/termux-app (README)
- Claude Code on Android (Paths A/B/C, glibc-runner, DNS, ripgrep, TMPDIR, phantom killer): https://github.com/ferrumclaudepilgrim/claude-code-android ([install](https://cdn.jsdelivr.net/gh/ferrumclaudepilgrim/claude-code-android@main/docs/install.md), [troubleshooting](https://cdn.jsdelivr.net/gh/ferrumclaudepilgrim/claude-code-android@main/docs/troubleshooting.md), [changelog](https://cdn.jsdelivr.net/gh/ferrumclaudepilgrim/claude-code-android@main/CHANGELOG.md))
- Claude Code proot self-relaunch loop: https://github.com/anthropics/claude-code/issues/86798
- Claude Code ≥2.1.113 on Termux (glibc), android binary request: https://claudeissues.com/issue/50270-v2-1-113-broken-on-termux-android-native-binary-requires-glibc-no-js-fallback, https://claudeissues.com/issue/72620-feature-publish-linux-arm64-android-native-binary-for-termux; AVF SIGILL: https://claudeissues.com/issue/55519-bug-sigill-on-arm64-avf-android-virtualization-framework-vm-regression-introduce
- OpenCode on Android: https://cosyra.com/guides/opencode-on-android.html
- T3 docs: https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md (loopback pairing, HTTP on mobile, Android CA), `docs/user/install.md`, `docs/user/faq.md`; local: `docs/plans/2026-11-17-t3code-integration.md` §2.2, §3
- Linux Terminal / AVF on Snapdragon: https://www.androidauthority.com/snapdragon-chips-android-linux-terminal-3608648, https://9to5google.com/2026/11/04/the-first-snapdragon-phone-with-android-linux-terminal-support-is-here/
- 11T Pro final OS (HyperOS 1, Android 14): https://www.androidupdatetracker.com/p/xiaomi-11t-pro, https://ximitime.com/hyperos/vili/stable/global/
- Phantom process killer: https://github.com/agnostic-apollo/Android-Docs/blob/master/en/docs/apps/processes/phantom-cached-and-empty-processes.md, https://raw.githubusercontent.com/AidanPark/openclaw-android/main/docs/disable-phantom-process-killer.md
- Tailscale userspace networking: https://tailscale.com/docs/concepts/userspace-networking.md
- Checked locally (✅): T3 store path `/nix/store/vhr3…-t3code-0.1.9` (package.json, `.node` files, `node:sqlite`); `llm-agents` `47a7bbf` `packages/{t3code,claude-code}`; aarch64 out paths and narinfos on cache.numtide.com / cache.nixos.org; Nix-on-Droid `3264519` + nixpkgs 26.05 + HM 26.05 eval; wrapped git/fish eval with aarch64 pkgs; RSS of T3/Claude on butternut.
