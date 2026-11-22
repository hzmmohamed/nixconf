# GitHub auth via `gh` login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `gh` installed and wired into git on hazel, butternut and fern, with a login prompt exactly when a host is not logged in.

**Architecture:** One feature module `flake.nixosModules.github`. Package + `gh` config through home-manager `programs.gh`; the git credential helper through `/etc/gitconfig` (the wrapped git reads it); prompts: a fish `gh` function (interactive auto-login), a desktop user oneshot (notification), a headless shell reminder. "Logged in" is tested offline with `gh auth token --hostname github.com` (reads keyring/hosts.yml, no network).

**Tech Stack:** NixOS 26.05 module, home-manager, fish, systemd user units, libnotify.

**Spec:** `docs/plans/2026-11-22-github-auth-design.md`

## Global Constraints

- No token in the repo or sops; no PAT creation step.
- Login command, verbatim: `gh auth login --web --git-protocol ssh --hostname github.com`.
- Logged-in test, verbatim: `gh auth token --hostname github.com` (exit 0 = logged in). Never `gh auth status` (network).
- Non-interactive callers (T3 service, agents, pipes) never get a prompt.
- Repo rules (CLAUDE.md): username via `config.preferences.user.name`; desktop-only bits gated on `config.preferences.desktop.enable`; `git add -N` new files; **no commits** unless the user asks; `nix fmt` + deadnix clean; `just check` (raw: see `justfile`) before handing back.

## Review Focus

1. T3 / an agent runs `gh pr list` on an unauthenticated host → plain `gh` error, no blocking prompt (fish function only acts when stdin and stdout are TTYs; T3 execs the binary, not fish). Test: Task 2 step 1 case "piped".
2. The user aborts or fails the login (Ctrl-C, denies in browser) → the original command is not run; the function returns the login's exit status. Test: Task 2 case "login fails".
3. `gh auth …` itself on an unauthenticated host → passthrough, no auto-login loop. Test: Task 2 case "auth subcommand".
4. Existing hand-written `~/.config/gh/config.yml` (`git_protocol: https`) gets replaced by the HM store link → HM moves it to `config.yml.backup` (`backupFileExtension = "backup"`); activation fails if that backup already exists. Record in user actions: `mv ~/.config/gh/config.yml{,.old}` before switching if a `.backup` exists. `hosts.yml` must stay writable (HM must not manage it: leave `programs.gh.hosts` unset). Test: Task 1 eval asserts `gh/hosts.yml` not in `xdg.configFile`.
5. Hosts without the feature (maple, peacelily) → no `/etc/gitconfig`, git unchanged. Test: Task 1 eval on maple.

---

### Task 1: `github` feature: package, gh config, git credential helper, host imports

**Files:**
- Create: `modules/nixos/features/github.nix`
- Modify: `modules/nixos/hosts/hazel/agents.nix`, `modules/nixos/hosts/butternut/agents.nix`, `modules/nixos/hosts/fern/configuration.nix` (add `self.nixosModules.github` next to `agent-t3code`)

**Interfaces:**
- Produces: `flake.nixosModules.github`; let-bindings `gh = lib.getExe pkgs.gh` and `user` reused by Task 2 in the same file.

- [ ] **Step 1: Write the failing eval checks** (scratch script `$SCRATCH/test-github-eval.sh`, bash):

```bash
set -euo pipefail
ev() { nix eval --raw ".#nixosConfigurations.$1.config.$2"; }
evj() { nix eval --json ".#nixosConfigurations.$1.config.$2"; }
for h in hazel butternut fern; do
  ev $h environment.etc.gitconfig.text | grep -q 'helper = !/nix/store/.*/bin/gh auth git-credential'
  ev $h environment.etc.gitconfig.text | grep -q '\[credential "https://gist.github.com"\]'
  evj $h home-manager.users.hfahmi.programs.gh.enable | grep -qx true
  evj $h home-manager.users.hfahmi.programs.gh.gitCredentialHelper.enable | grep -qx false
  evj $h home-manager.users.hfahmi.programs.gh.settings.git_protocol | grep -qx '"ssh"'
  evj $h home-manager.users.hfahmi.xdg.configFile --apply 'builtins.hasAttr "gh/hosts.yml"' | grep -qx false
done
evj maple environment.etc --apply 'builtins.hasAttr "gitconfig"' | grep -qx false
echo PASS
```

- [ ] **Step 2: Run it, expect FAIL** (`bash $SCRATCH/test-github-eval.sh` → error: attribute `gitconfig` missing / `programs.gh.enable` false).

- [ ] **Step 3: Implement `modules/nixos/features/github.nix`** in the house style (header comment explaining intent and the design-doc pointer, `{...}: { flake.nixosModules.github = {config, lib, pkgs, ...}: …}`):
  - `home-manager.users.${user}.programs.gh = { enable = true; settings.git_protocol = "ssh"; gitCredentialHelper.enable = false; }` (HM's helper only writes HM `programs.git`, which this repo doesn't use).
  - `environment.etc.gitconfig.text`: `[credential "https://github.com"]` and `[credential "https://gist.github.com"]`, each `helper = !${gh} auth git-credential` (absolute path, so it works where `gh` isn't on PATH).
  - Add the imports to the three hosts; `git add -N modules/nixos/features/github.nix`.

- [ ] **Step 4: Run the check, expect PASS**, then `nix fmt` and `just eval hazel` (raw: `nix eval --raw .#nixosConfigurations.hazel.config.system.build.toplevel.drvPath`).

### Task 2: login prompts + docs

**Files:**
- Modify: `modules/nixos/features/github.nix`
- Modify: `ARCHITECTURE.md` (feature table row near `secretspec`/`vault`), `docs/plans/2026-11-17-user-actions.md` (new section)

**Interfaces:**
- Consumes: `gh`, `user` from Task 1.
- Produces: HM `programs.fish.functions.gh` (all hosts); HM `systemd.user.services.github-auth-check` (desktop only); a headless reminder in HM `programs.fish.interactiveShellInit` (non-desktop only).

- [ ] **Step 1: Write the failing tests** (`$SCRATCH/test-github-prompt.sh`, bash). Build a stub `gh` in a temp dir that appends `"$*"` to `$LOG`, exits 0 for `auth token` iff `STUB_LOGGED_IN=1`, exits `$STUB_LOGIN_RC` (default 0) for `auth login`, else 0. Extract the function body with `nix eval --raw .#nixosConfigurations.hazel.config.home-manager.users.hfahmi.programs.fish.functions.gh.body`, wrap it in `function gh … end`, and run it with the stub first on PATH. TTY cases run under `script -qec "fish -c '…'" /dev/null`; the piped case runs `echo | fish -c '…' | cat`. Assertions on `$LOG`:
  - "not logged in, tty": `gh pr list` → log lines exactly `auth token --hostname github.com`, `auth login --web --git-protocol ssh --hostname github.com`, `pr list`.
  - "logged in, tty": → `auth token --hostname github.com`, `pr list`.
  - "piped, not logged in": → only `pr list`.
  - "auth subcommand": `gh auth status` (not logged in, tty) → only `auth status`.
  - "login fails": `STUB_LOGIN_RC=1` → no `pr list` line; function exit status 1.
  - Eval: hazel and butternut have `systemd.user.services.github-auth-check` with `Install.WantedBy = ["graphical-session.target"]`; fern does not; fern's `programs.fish.interactiveShellInit` contains `gh auth login`, hazel's does not.

- [ ] **Step 2: Run, expect FAIL** (`functions.gh` missing).

- [ ] **Step 3: Implement in `github.nix`:**
  - `programs.fish.functions.gh = { wraps = "gh"; description = …; body = …; }`: if `$argv[1]` ≠ `auth`, `isatty stdin`, `isatty stdout`, and `command gh auth token --hostname github.com` fails (output to /dev/null), print one line ("GitHub: not logged in, starting login…") and run the login command; on failure `return $status`. Then `command gh $argv`.
  - Desktop (`lib.mkIf config.preferences.desktop.enable`): `systemd.user.services.github-auth-check`, `Type = oneshot`, `After`/`PartOf`/`WantedBy` `graphical-session.target` (pattern: `features/battery-notify.nix`), a `writeShellApplication` running `${gh} auth token --hostname github.com >/dev/null 2>&1 || notify-send -a GitHub -i dialog-password "GitHub: not logged in" "Run: gh auth login"` (`runtimeInputs = [pkgs.libnotify]`).
  - Headless (`lib.mkIf (!config.preferences.desktop.enable)`): append to `programs.fish.interactiveShellInit` (order vs fish.nix's `exec zellij` doesn't matter: zellij panes skip the exec and print the line, an acceptable nag until login): if `isatty stdout` and `command gh auth token --hostname github.com` fails, `echo "GitHub: not logged in on $hostname: run gh auth login"`.
  - Docs: ARCHITECTURE row `github` — "gh (HM programs.gh, git_protocol ssh) + /etc/gitconfig credential helper; login prompts: fish auto-login, desktop notification, headless reminder; per-host device-flow login, no tokens in sops". User actions section: after deploying each of hazel, butternut, fern run `gh auth login` once (device code at github.com/login/device, password from KeePassXC); if `~/.config/gh/config.yml.backup` exists, move it aside before switching; verify with `gh auth status` and the T3 PR panel.

- [ ] **Step 4: Run both test scripts, expect PASS.**

- [ ] **Step 5: Full check:** `just check` (raw: `nix build --no-link .#checks.x86_64-linux.treefmt`, `nix develop --impure -c deadnix --fail modules`, the per-host evals). Expected: fmt clean, deadnix clean, every host OK except the known SKIP. Leave changes uncommitted; report the diff summary.
