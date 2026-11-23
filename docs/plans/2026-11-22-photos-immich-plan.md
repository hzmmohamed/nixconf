# Photos (Immich) Implementation Plan

> **For agentic workers:** execute task by task; steps use checkbox (`- [ ]`) syntax. Per
> the user's workflow this runs as **T3 threads** (one thread per task or per phase,
> sequential, coordinator-curated briefs), not Claude Code subagents.

**Goal:** Immich 3.x as a host-agnostic NixOS feature, piloted on butternut for phone
backup, reachable over Tailscale; then B2 off-site backup; then the move to peacelily.

**Architecture:** `flake.nixosModules.immich` swaps in nixpkgs-unstable's Immich module and
package (26.05 has 2.7.5), runs it on loopback with declarative settings, and publishes it
with `tailscale serve`. A NixOS VM test (`checks.x86_64-linux.immich-vm`) proves the 3.x
module/package combination works on 26.05's Postgres/VectorChord. Phases 2 and 3 are
outlined here and get their own detailed plan when started.

**Tech Stack:** NixOS 26.05 + flake-parts/import-tree, nixpkgs-unstable (Immich 3.4.x),
`pkgs.testers.runNixOSTest`, Tailscale serve; later OpenTofu (`Backblaze/b2`), restic, sops,
ntfy.

**Spec:** `docs/plans/2026-11-22-photos-immich-design.md` (research:
`docs/plans/2026-11-22-photos-immich-research.md`).

## Global Constraints

- Immich **3.x** (nixpkgs-unstable has 3.4.2); never ship 26.05's 2.7.5.
- Immich listens on `127.0.0.1:2283`; `openFirewall = false`; no Funnel, no public DNS.
- `preferences.immich.mediaLocation` default `/var/lib/immich` (same path on every host).
- `preferences.immich.tailscaleServePort` default `443`; butternut sets `8444` (443 = T3,
  8443 = OpenCode). Tailnet policy needs no change.
- Storage template `{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}`, enabled.
- DB dump: enabled, daily 02:00, keep 14. `newVersionCheck.enabled = false`.
- `server.externalDomain = "https://${config.networking.hostName}.${self.tailnet.domain}"`
  plus `:${port}` when the port isn't 443. Never hardcode the hostname or tailnet.
- Repo invariants (CLAUDE.md): alejandra, deadnix-clean, `{...}:` headers, features don't
  import features, `git add -N` new files, no `nixos-rebuild`/deploy/sops/`tofu apply`/
  `git push` from agents.
- Work in a git worktree on local branch `immich`; one commit per task on that branch
  (approved for chaining threads); never push.
- Eval/build on butternut only (it's the build server); never big builds on hazel.

## Review Focus

1. **Large video upload through `tailscale serve`** (multi-GB phone videos): must not hit a
   body-size limit. Not testable in the VM; Task 3 verifies by hand on the pilot and the
   user-actions checklist says how.
2. **Server restarts / reboots:** Immich and the serve unit come back without a manual
   step. Task 2's VM test restarts `immich-server` and re-checks the API; the serve unit
   is a `RemainAfterExit` oneshot that retries for 5 min (agent-opencode pattern).
3. **Postgres/VectorChord from 26.05 under Immich 3.x:** a mismatch would break DB
   migrations on first start. Task 1's VM test fails if the server doesn't come up.
4. **Settings file actually applied:** a typo'd key is silently ignored by Immich. Task 2's
   VM test reads the settings back over the API (`/api/system-config`), not just the file.
5. **Host without Tailscale** (the VM, a future host): the feature must still eval and run.
   Task 2 gates the serve unit on `config.services.tailscale.enable` and the VM test
   asserts the unit is absent.

---

## Phase 1: pilot on butternut

### Task 1: unstable input, `immich` feature with Immich 3.x, VM test

**Files:**
- Modify: `flake.nix` (inputs)
- Modify: `flake.lock` (only the new input: `nix flake lock`, never `update`)
- Create: `modules/nixos/features/immich.nix`
- Create: `modules/checks/immich-vm.nix` (a flake-parts module adding
  `perSystem.checks.immich-vm`; import-tree picks it up)

**Interfaces:**
- Produces: flake input `nixpkgs-unstable` (`github:nixos/nixpkgs/nixos-unstable`, no
  `follows`); `flake.nixosModules.immich`; option namespace `preferences.immich`;
  check `checks.x86_64-linux.immich-vm`.

Verified facts for this task (from nixos-unstable's
`nixos/modules/services/web-apps/immich.nix`, 2026-11-22): the ML unit runs
`lib.getExe cfg.package.machine-learning` (no separate ML package option); the unstable
module adds `database.package` and read-only `database.setupSQL`; it sets up
`pgvector` + `vectorchord`. 26.05's module path to disable is
`"services/web-apps/immich.nix"`.

- [ ] **Step 1: Write the failing VM test** `modules/checks/immich-vm.nix`: a
  `pkgs.testers.runNixOSTest` named `immich-vm`, one node importing
  `self.nixosModules.immich` with `services.immich.enable` coming from the feature
  (no Tailscale), `virtualisation.memorySize = 4096`, `diskSize = 8192`. Test script:

  ```python
  import json
  machine.wait_for_unit("immich-server.service")
  machine.wait_for_open_port(2283)
  v = json.loads(machine.succeed("curl -sf http://127.0.0.1:2283/api/server/version"))
  assert v["major"] == 3, v
  machine.succeed("curl -sf http://127.0.0.1:2283/api/server/ping | grep -q pong")
  machine.fail("ss -ltn | grep -q '0.0.0.0:2283'")   # loopback only
  ```

- [ ] **Step 2: Run it, expect failure**
  Run: `nix build --no-link -L .#checks.x86_64-linux.immich-vm`
  Expected: FAIL (eval error: `self.nixosModules.immich` does not exist).

- [ ] **Step 3: Add the input and the feature.**
  `flake.nix`: `nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";` then
  `nix flake lock` (adds only that node; check `git diff flake.lock` touches nothing else).
  `modules/nixos/features/immich.nix`: header `{inputs, self, ...}:`, module
  `{config, lib, pkgs, ...}:` with
  `unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}`;
  `disabledModules = ["services/web-apps/immich.nix"]`;
  `imports = ["${inputs.nixpkgs-unstable}/nixos/modules/services/web-apps/immich.nix"]`;
  options `preferences.immich.mediaLocation` (`types.path`, `/var/lib/immich`),
  `tailscaleServePort` (`types.port`, `443`), `cuda` (`mkEnableOption`, unused until
  phase 3, assert it's false for now with a message pointing at phase 3);
  config: `services.immich = { enable = true; package = unstable.immich; host =
  "127.0.0.1"; port = 2283; openFirewall = false; inherit (cfg) mediaLocation;
  machine-learning.enable = true; }`. A header comment in the repo's style: what it is,
  why unstable, when to drop the override (26.11 ≥ 3.x), link to the design doc.
  `git add -N` both new files.

- [ ] **Step 4: Run the VM test, expect pass**
  Run: `nix build --no-link -L .#checks.x86_64-linux.immich-vm`
  Expected: PASS. If the server fails on DB migrations, it's Review Focus #3: set
  `services.immich.database.package`/postgres to what unstable's module expects
  (prefer 26.05's postgres with unstable's `vectorchord` only if needed), and note the
  choice in the module comment.

- [ ] **Step 5: Format, lint, commit**
  Run: `nix fmt` then `nix develop --impure -c just lint` (or the raw commands in
  `justfile`). Expected: clean.
  `git commit -m "immich: feature on nixpkgs-unstable's Immich 3.x, VM test"`

### Task 2: declarative settings + Tailscale serve

**Files:**
- Modify: `modules/nixos/features/immich.nix`
- Modify: `modules/checks/immich-vm.nix`

**Interfaces:**
- Consumes: Task 1's options and module.
- Produces: unit `immich-tailscale-serve.service` (only when
  `config.services.tailscale.enable`); `services.immich.settings` as in Global
  Constraints.

- [ ] **Step 1: Extend the VM test (failing)** — after the Task 1 assertions:

  `/api/system-config` needs an admin token: sign up the first admin, log in, use the bearer.

  ```python
  api = "http://127.0.0.1:2283/api"
  creds = '{"email":"admin@test.local","password":"test-password","name":"Admin"}'
  machine.succeed(f"curl -sf -H 'Content-Type: application/json' -d '{creds}' {api}/auth/admin-sign-up")
  tok = json.loads(machine.succeed(
      f"curl -sf -H 'Content-Type: application/json' "
      f"-d '{{\"email\":\"admin@test.local\",\"password\":\"test-password\"}}' {api}/auth/login"
  ))["accessToken"]
  c = json.loads(machine.succeed(f"curl -sf -H 'Authorization: Bearer {tok}' {api}/system-config"))
  assert c["storageTemplate"]["enabled"] is True
  assert c["storageTemplate"]["template"] == "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}"
  assert c["backup"]["database"]["enabled"] is True
  assert c["backup"]["database"]["cronExpression"] == "0 02 * * *"
  assert c["backup"]["database"]["keepLastAmount"] == 14
  assert c["newVersionCheck"]["enabled"] is False
  machine.fail("systemctl cat immich-tailscale-serve.service")
  machine.succeed("systemctl restart immich-server.service")
  machine.wait_for_open_port(2283)
  machine.succeed("curl -sf http://127.0.0.1:2283/api/server/ping | grep -q pong")
  ```

- [ ] **Step 2: Run, expect failure** (settings assertions fail: settings are `null`).
  Run: `nix build --no-link -L .#checks.x86_64-linux.immich-vm`

- [ ] **Step 3: Implement.** `services.immich.settings` with exactly: `storageTemplate =
  {enabled = true; template = "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}";}`,
  `backup.database = {enabled = true; cronExpression = "0 02 * * *"; keepLastAmount =
  14;}`, `newVersionCheck.enabled = false`, `server.externalDomain` per Global
  Constraints, `machineLearning.urls = ["http://127.0.0.1:3003"]`. Confirm key names
  against Immich 3.4's config-file docs (https://docs.immich.app/install/config-file/);
  everything else stays default (partial config is fine).
  Serve unit: copy `opencode-tailscale-serve` from
  `modules/nixos/features/agent-opencode.nix:376-394` (root oneshot, `RemainAfterExit`,
  after `tailscaled*.service`, 60×5 s retry), command
  `tailscale serve --bg --https=${toString cfg.tailscaleServePort} http://127.0.0.1:2283`,
  wrapped in `lib.mkIf config.services.tailscale.enable`.

- [ ] **Step 4: Run, expect pass.** Same command. Expected: PASS.

- [ ] **Step 5: fmt, lint, commit.**
  `git commit -m "immich: declarative settings, tailscale serve"`

### Task 3: butternut pilot wiring + docs

**Files:**
- Modify: `modules/nixos/hosts/butternut/configuration.nix` (imports + preference)
- Modify: `modules/checks/immich-vm.nix` (add eval check `immich-butternut-config`)
- Modify: `ARCHITECTURE.md` (feature entry), `docs/plans/2026-11-17-backlog.md` (mark
  pilot in progress, link design), `docs/plans/2026-11-17-user-actions.md` (new section)

**Interfaces:**
- Consumes: `flake.nixosModules.immich`, `preferences.immich.tailscaleServePort`.

- [ ] **Step 1: Eval check (failing).** `checks.x86_64-linux.immich-butternut-config`, a
  `runCommand` that fails unless, for `self.nixosConfigurations.butternut.config`:
  `services.immich.enable == true`, `lib.versions.major services.immich.package.version
  == "3"`, `preferences.immich.tailscaleServePort == 8444`,
  `services.immich.settings.server.externalDomain ==
  "https://butternut.tail1a9f7c.ts.net:8444"` (computed in the check from
  `self.tailnet.domain`, not typed), and
  `systemd.services ? immich-tailscale-serve`. Use `lib.assertMsg` per condition so the
  failure names it.
  Run: `nix build --no-link .#checks.x86_64-linux.immich-butternut-config` → FAIL.

- [ ] **Step 2: Wire butternut.** Add `self.nixosModules.immich` to butternut's imports
  and `preferences.immich.tailscaleServePort = 8444;`. Re-run → PASS.

- [ ] **Step 3: Full repo check + closure build.**
  Run: `nix develop --impure -c just check` → every host OK (niri-desktop-vm SKIP).
  Run (on butternut): `nix build --no-link .#nixosConfigurations.butternut.config.system.build.toplevel`
  → builds.

- [ ] **Step 4: Docs.** `ARCHITECTURE.md`: one entry for `features/immich.nix` (what,
  options, unstable override, serve port) in the features section's style.
  `user-actions.md`: new section "Immich pilot (butternut)" as paste-ready steps:
  (1) free space (point at §6), (2) `just deploy butternut`, (3) open
  `https://butternut.tail1a9f7c.ts.net:8444`, create the admin account, (4) phone:
  install Immich (Play Store/F-Droid), log in with that URL, back up Camera + chosen
  albums, background backup on, HyperOS battery "No restrictions" + autostart, keep
  "Prefer remote images" off, (5) **don't use "Free up space" until phase 2's first B2
  backup push**, (6) test a large video (> 1 GB) uploads (Review Focus #1); if it fails,
  report the error. Backlog: mark the Immich item "pilot in progress", link the design.

- [ ] **Step 5: fmt, lint, commit.**
  `git commit -m "butternut: Immich pilot on :8444; docs"`

---

## Phase 2: off-site backup (follow-up; detailed plan when started)

- **Task 4: `infra/b2/`** OpenTofu stack per design §"B2 as code": `versions.tf`
  (`Backblaze/b2`), `variables.tf` (bucket name), bucket + lifecycle + scoped
  application key, sensitive outputs, `backend.hcl.example` matching `infra/aws`;
  `scripts/b2/store-key.sh` (sops write to `secrets/<host>/immich-backup.yaml`, generate
  `restic-password` once), `just` plan/apply recipes like the tofu ones. Verification:
  `tofu validate` + `tofu fmt -check` (no init against the real API, no apply).
- **Task 5: `features/immich-backup.nix`**: `services.restic.backups.immich` per design
  (paths, excludes, 03:30 timer, prune, weekly 5 % check, `initialize`), sops template
  for B2 env vars, ntfy `OnFailure` + first-success push via
  `preferences.agents.ntfy.topicFile`, `warnings` when no topic file. Test: extend
  `immich-vm` (or a new VM test) with a local restic repo (`/tmp/repo`, plain path) to
  prove paths/excludes and the OnFailure wiring; eval check on butternut.
- **Task 6:** butternut imports `immich-backup`; user-actions phase 2 steps.

## Phase 3: peacelily (follow-up; when peacelily is plugged in and redeployed)

- **Task 7:** `preferences.immich.cuda`: `services.immich.package` with
  `machine-learning` overridden to CUDA `onnxruntime` (ai-server.nix llama-cpp pattern;
  needs an unfree/CUDA-enabled unstable pkgs instance), `accelerationDevices` for
  `/dev/nvidia*`; peacelily imports `immich` + `immich-backup`, port 443 (default).
  Eval check for peacelily. Build on peacelily/butternut only.
- **Task 8:** migration runbook in user-actions (design §"Migration"), plus a restore
  test from B2. Then the old-drive import with `immich-go` (steps in user-actions).
