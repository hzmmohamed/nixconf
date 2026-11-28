# attn integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** attn's daemon, sensor and awatcher replace ActivityWatch on hazel and butternut.

**Architecture:** A new `attn` input (attn's own package, no `follows`) and one feature,
`features/attn.nix`, that imports `inputs.attn.nixosModules.device` and owns all wiring
(swayidle, fish, awatcher, agent-net). Hosts import it and set `deviceId`. An eval-only
flake check pins the wiring on both hosts.

**Tech Stack:** NixOS 26.05 flake-parts modules, home-manager, attn `nixosModules.device`.

**Spec:** `docs/superpowers/specs/2026-11-28-attn-integration-design.md`

## Global Constraints

- Input: `attn.url = "git+ssh://git@github.com/hzmmohamed/attn";` — no `inputs.nixpkgs.follows`.
- Only the `attn` lock entry is added; never `nix flake update` other inputs.
- `sink = "dir:///var/lib/attn/sink"`; `recipients = ["<owner's vault age1… public key>"]` (owner supplies; never invent one).
- swayidle timeout `180` s → `idleCommands.idle`, resume → `idleCommands.active`.
- Usernames via `config.preferences.user.name`; no hardcoded hostnames.
- Never read `/var/lib/attn`, the sink, or any tracker output. No `ptrace_scope` (isolation Phase 0 owns it).
- Metered link: the first `attn` fetch also pulls attn's nixpkgs (~40 MB); say so before running it.
- Done = `just check` (or its raw commands) passes; `nix build --no-link .#checks.x86_64-linux.attn-wiring` passes.

## Review Focus

- Port 5600 has one listener: no `activitywatch*` user unit left on either host (pinned in Task 1's check).
- Agent shells post nothing: the fish hook keeps attn's `AGENT_DEVSHELL`/`CLAUDECODE`/`OPENCODE` guard (attn's own check covers it; Task 1 asserts the hook is present).
- Metered policy works: the daemon unit's PATH holds `agent-net` and grants `AF_NETLINK` (Task 1).
- Existing swayidle timeouts (lock, screen-off) survive the extra entry (Task 1 asserts 3 timeouts).
- `agent-env` still ships the same `agent-net` to the user and to nx/agent-devshell after the move (Task 2: `just check` + agent-env tests).

---

### Task 1: Failing wiring check

**Files:**
- Modify: `modules/checks.nix` (add `attn-wiring` to the `checks` attrset)

**Interfaces:**
- Produces: `checks.x86_64-linux.attn-wiring`, a `runCommand` guarded by `assert lib.assertMsg …` over `self.nixosConfigurations.{hazel,butternut}.config`.

- [ ] **Step 1: Write the check.** For each `h` in `["hazel" "butternut"]`, with `c = self.nixosConfigurations.${h}.config` and `hm = c.home-manager.users.${c.preferences.user.name}`, assert:
  - `c.services.attn.device.enable && c.services.attn.sensor.enable`
  - `c.services.attn.device.sink == "dir:///var/lib/attn/sink"`
  - `c.services.attn.device.recipients != []`
  - `lib.any (p: (p.pname or p.name) == "agent-net") c.systemd.services.attn-daemon.path`
  - `lib.hasInfix "AF_NETLINK" c.systemd.units."attn-daemon.service".text`
  - `builtins.length hm.services.swayidle.timeouts == 3` and one entry has `timeout == 180`, `command == c.services.attn.sensor.idleCommands.idle`, `resumeCommand == c.services.attn.sensor.idleCommands.active`
  - `hm.systemd.user.services ? awatcher`
  - `!(lib.any (lib.hasPrefix "activitywatch") (lib.attrNames hm.systemd.user.services))` and `!(hm.services ? activitywatch && hm.services.activitywatch.enable)`
  - `!(lib.any (e: e.id == "pmjeegjhjdlccodhacdgbgfagbpmccpe") hm.programs.chromium.extensions)` (Clockify gone)
  - `lib.elem "SWAYSOCK" hm.wayland.windowManager.sway.systemd.variables && hm.wayland.windowManager.sway.systemd.enable`
  - `lib.hasInfix "attn-sensor.sock" c.programs.fish.interactiveShellInit`
  - and across hosts: hazel's `deviceId != butternut's deviceId`.
  Use `builtins.unsafeDiscardStringContext` before `hasInfix` on strings with store paths (as attn's `nix/checks.nix` does).
- [ ] **Step 2: Run it, expect failure.** `nix build --no-link .#checks.x86_64-linux.attn-wiring` → eval error (`services.attn` does not exist).
- [ ] **Step 3: Commit** `checks: attn-wiring (failing until the attn feature lands)`. (`git add` the file; it is tracked already.)

### Task 2: `agent-net` as a flake package

**Files:**
- Create: `modules/packages/agent-net.nix` (`perSystem.packages.agent-net`)
- Modify: `modules/nixos/features/agent-env.nix:30` (`agentNet = self.packages.${pkgs.stdenv.hostPlatform.system}.agent-net;`; header `{self, ...}:`)

**Interfaces:**
- Produces: `self.packages.x86_64-linux.agent-net` (`meta.mainProgram = "agent-net"`), same script (`../nixos/features/agent-env/agent_net.py`) and deps (`networkmanager`, `iproute2`), same `makeWrapper … --suffix PATH` shape as `mkTool`.

- [ ] **Step 1:** Move the definition; keep `mkTool` in agent-env for the other tools.
- [ ] **Step 2: Verify unchanged behaviour.** `python3 -m unittest discover -s modules/nixos/features/agent-env/tests` passes; `nix eval --raw .#packages.x86_64-linux.agent-net.drvPath` succeeds; `just eval hazel` OK.
- [ ] **Step 3: Commit** `agent-net: a flake package (attn's networkStatusPackage needs it)`.

### Task 3: attn input, feature, hosts; ActivityWatch out

**Files:**
- Modify: `flake.nix` (input), `flake.lock` (`nix flake lock` adds only `attn` and its transitive inputs)
- Create: `modules/nixos/features/attn.nix` (`flake.nixosModules.attn`; `git add -N`)
- Delete: `modules/nixos/features/activitywatch.nix`
- Modify: `modules/nixos/hosts/hazel/configuration.nix:46`, `modules/nixos/hosts/butternut/configuration.nix:73` (replace `activitywatch` import with `attn`; set `services.attn.device.deviceId`)
- Modify: `modules/nixos/features/chromium.nix` (drop the Clockify line)

**Interfaces:**
- Consumes: `self.packages.<system>.agent-net` (Task 2); attn options `services.attn.{device,sensor}.*`, read-only `services.attn.sensor.idleCommands.{idle,active}`.

- [ ] **Step 1: Input.** Add the input after `treefmt-nix` with a comment (private repo; owner's SSH key; attn's own nixpkgs on purpose so store paths match attn CI). Run `nix flake lock` (metered: announce). `git diff flake.lock` shows only new nodes.
- [ ] **Step 2: Feature** `features/attn.nix`, header `{inputs, self, ...}:`, module `{config, lib, pkgs, ...}:`, with `imports = [inputs.attn.nixosModules.device];` and:
  - `services.attn.device = { enable = true; sink = "dir:///var/lib/attn/sink"; recipients = [ <vault key> ]; networkStatusPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.agent-net; };` — recipients with a comment: the offline vault key; the brain's (peacelily host key via ssh-to-age) joins when peacelily is up.
  - `services.attn.sensor = { enable = true; gitRoots = lib.mkDefault ["${home}/work" "${home}/nixconf"]; };` with `home = config.users.users.${user}.home`.
  - `home-manager.users.${user}.services.swayidle.timeouts = [{ timeout = 180; command = idle; resumeCommand = active; }];`
  - `home-manager.users.${user}.systemd.user.services.awatcher`: `Unit = { Description = "awatcher (window and idle watcher, posts to attn)"; After = ["sway-session.target" "attn-sensor.service"]; PartOf = ["sway-session.target"]; }; Service = { ExecStart = lib.getExe pkgs.awatcher; Restart = "on-failure"; RestartSec = 5; }; Install.WantedBy = ["sway-session.target"];` (the `sway-session.target` binding mirrors the removed afk watcher's comment; copy that rationale).
  - A header comment: what runs where (daemon system unit, sensor + awatcher user units), what's deferred (S3, token, sops, ptrace_scope).
- [ ] **Step 3: Hosts.** Generate two UUIDs (`uuidgen` ×2 or `python3 -c 'import uuid;print(uuid.uuid4())'`); set one per host next to the import, with a comment "attn device id (identifier, not a secret)".
- [ ] **Step 4: Remove** `activitywatch.nix` (`git rm`), and Clockify from `chromium.nix`. `rg -n activitywatch modules` → only the chromium/vscode extension comments remain.
- [ ] **Step 5: Verify.** `nix build --no-link .#checks.x86_64-linux.attn-wiring` passes; `just eval hazel`, `just eval butternut` OK.
- [ ] **Step 6: Commit** `attn: daemon, sensor and awatcher on hazel and butternut; ActivityWatch out`.

### Task 4: Docs, full check, PR

**Files:**
- Modify: `ARCHITECTURE.md` (an `attn` feature entry; drop `activitywatch`), `docs/plans/2026-11-17-user-actions.md` (first-deploy checks below)

- [ ] **Step 1: Docs.** User actions: deploy hazel, butternut; then `systemctl status attn-daemon`, `systemctl --user status attn-sensor awatcher` (sensor's `PrivateTmp` may fail in a user manager — report back), `curl -s http://127.0.0.1:5600/api/0/info`.
- [ ] **Step 2:** `just check` (or raw: `nix fmt -- --ci`/treefmt check, deadnix, `nix run .#fleet -- …` per justfile) → all OK; agent-env unit tests pass.
- [ ] **Step 3: Commit** docs; `nix run .#fleet -- affects` → copy the `Affects:` line.
- [ ] **Step 4:** `agent-push`; `gh pr create --title "attn: replace ActivityWatch on hazel and butternut (attn plan 5)" --body …` (summary, deferred items, owner's first-deploy checks, `Affects:` line, attribution); link the PR.
