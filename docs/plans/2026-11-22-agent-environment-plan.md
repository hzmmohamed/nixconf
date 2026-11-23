# Agent Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents know whether the link is metered, run inside the project's dev shell in T3, get generic tools store-first via `nx`, and share one set of global guidelines.

**Architecture:** Three stdlib-Python CLIs (`agent-net`, `nx`, `agent-devshell`) plus a guidelines Markdown file live in `modules/nixos/features/agent-env/`. A new flake-parts file `agent-env.nix` contributes them to the existing `flake.nixosModules.agent-common` (same multi-file pattern as `hosts/<h>/*.nix`), wires Claude hooks through a new `agent-common` option, and adds a `checks.agent-env` derivation that runs the unit tests. T3's provider `binaryPath`s point at dev-shell wrappers.

**Tech Stack:** Nix (flake-parts, home-manager), Python 3 stdlib (`unittest`, `subprocess`, `json`), NetworkManager `nmcli`, iproute2 `ip -j`, direnv 2.37 + nix-direnv, nix-index (`nix-locate`).

**Spec:** `docs/plans/2026-11-22-agent-environment-design.md`

## Global Constraints

- Repo rules (`CLAUDE.md`): don't commit unless the user asks. After creating any file run `git add -N <file>` (flakes only see tracked files). Never `git add -A`, `nixos-rebuild`, `deploy`, `sudo`/`doas`. Work in a git worktree: the main tree has other agents' uncommitted changes.
- Usernames via `config.preferences.user.name`; hostnames never hardcoded in features; alejandra + deadnix clean; `{...}:` headers.
- Python: stdlib only, `#!/usr/bin/env python3`, no third-party imports. Every script resolves external tools from `PATH` (tests put fakes first on `PATH`).
- Packaging: each CLI is `makeWrapper ${pkgs.python3}/bin/python3 $out/bin/<name> --add-flags <script> --suffix PATH : <deps>`. **Suffix, never prefix**, so nothing leaks ahead of the user's or the dev shell's PATH.
- Hooks and `agent-devshell` never fail closed: any internal error → exit 0 with no output (hooks) / exec the target binary anyway (devshell).
- `NX_METERED_LIMIT_MB` default **50**. Override file `${XDG_STATE_HOME:-~/.local/state}/agent-net/override`. Guidelines installed at `~/.config/agents/guidelines.md`; Claude import line exactly `@~/.config/agents/guidelines.md`.
- `AGENT_DEVSHELL` values exactly: `loaded`, `not-allowed`, `not-built`, `none`, `error`.
- Dev loop: `python3 -m unittest discover -s modules/nixos/features/agent-env/tests -v`. Gate: `nix build --no-link .#checks.x86_64-linux.agent-env` and `just check` (or the raw commands in `justfile`).

## Review Focus

1. A hook gets garbage or empty stdin, or `nmcli`/`ip` is missing or hangs → the prompt still goes through (exit 0, no stdout, finishes within 2 s). Test in Task 2.
2. The agent starts in a subdirectory of the project (T3 cwd = `repo/app/`) → `agent-devshell` still finds `repo/.envrc`. Test in Task 4.
3. T3 passes flags with spaces/quotes/`=` to the provider → `agent-devshell` forwards argv byte-identical in every branch. Test in Task 4.
4. `nix build --dry-run` prints nothing to fetch (all present), or sizes in KiB/GiB → `nx` treats as 0 / converts correctly. Test in Task 3.
5. `agent-net` missing or erroring when `nx`/`agent-devshell` ask for the network state → treated as unmetered, no crash. Tests in Tasks 3 and 4.

---

### Task 1: `agent-net` CLI and the test harness

**Files:**
- Create: `modules/nixos/features/agent-env/agent_net.py`
- Create: `modules/nixos/features/agent-env/tests/fakebin.py`
- Create: `modules/nixos/features/agent-env/tests/test_agent_net.py`
- Create: `modules/nixos/features/agent-env.nix`

**Interfaces:**
- Produces (CLI): `agent-net` → one stdout line; `agent-net --json` → `{"state": "metered"|"unmetered"|"offline", "connection": str|null, "device": str|null, "source": "nm"|"override"|"none"}`; `agent-net set metered|unmetered|auto` (auto deletes the override file).
- Produces (Python, importable by tests and Task 2): `status() -> dict` (the `--json` shape).
- Produces (test helper) `fakebin.FakeBin(tmpdir)`: `.add(name, stdout="", stderr="", exit=0)` writes an executable that prints the canned output and appends its argv (JSON list) to `<tmpdir>/calls/<name>.jsonl`; `.calls(name) -> list[list[str]]`; `.env(**extra) -> dict` = os.environ with `PATH=<tmpdir>/bin:<dir of python3>` plus extras; `.run(script, *args, stdin="", env=None) -> CompletedProcess` (text, 10 s timeout).
- Produces (Nix): `agent-env.nix` with `perSystem.checks.agent-env` (runCommand, `nativeBuildInputs = [python3 bash coreutils]`, runs `python3 -m unittest discover -s ${./agent-env/tests} -v`; tests locate scripts via `Path(__file__).parent.parent`) and `flake.nixosModules.agent-common` adding package `agent-net` to `home-manager.users.${user}.home.packages`. Deps suffix: `networkmanager iproute2`.

- [ ] **Step 1: Write the failing tests** (`test_agent_net.py`, one `FakeBin` per test)
  - `test_metered_hotspot`: `ip` prints `[{"dst":"default","dev":"wlo1","metric":600}]`; `nmcli` prints `yes (guessed)\nwildflower`. stdout == `metered (wildflower, wlo1)\n`; `--json` state `metered`, source `nm`.
  - `test_unmetered_guessed`: nmcli `no (guessed)\nhome` → `unmetered (home, wlo1)`.
  - `test_unknown_is_unmetered`: nmcli `unknown\nfoo` → state `unmetered`.
  - `test_lowest_metric_route_wins`: two defaults, `eno2` metric 100 and `wlo1` metric 600 → nmcli called with `eno2` (assert via `.calls("nmcli")`).
  - `test_offline`: `ip` prints `[]` → `offline`, connection null.
  - `test_no_nmcli`: no fake nmcli, ip has a route → state `unmetered`, source `none`.
  - `test_override`: `set metered` with `XDG_STATE_HOME=<tmp>`, nmcli says `no` → `--json` state `metered`, source `override`; `set auto` → back to `unmetered`, file gone.
  - `test_set_rejects_bad_value`: `set foo` → exit 2.
- [ ] **Step 2: Run** `python3 -m unittest discover -s modules/nixos/features/agent-env/tests -v`. Expected: FAIL (`agent_net.py` missing).
- [ ] **Step 3: Implement `agent_net.py`.** Route: `ip -j route show default`, pick min `metric` (missing = 0). Metered: `nmcli -t -g GENERAL.METERED,GENERAL.CONNECTION device show <dev>`, first line starts with `yes` → metered, else unmetered. Each subprocess gets `timeout=1.5`; timeout/OSError → treat as tool missing. Override wins over NM, and it still applies when there's no route (stays `offline`).
- [ ] **Step 4: Write `fakebin.py`, then `agent-env.nix`** (package + check as in Interfaces). `git add -N` all new files.
- [ ] **Step 5: Run the unit tests, then** `nix build --no-link .#checks.x86_64-linux.agent-env`. Expected: all PASS; check builds.
- [ ] **Step 6: Run** `just eval hazel` (raw: `nix eval --raw .#nixosConfigurations.hazel.config.system.build.toplevel.drvPath`). Expected: a drv path, no error.

### Task 2: Network hooks for Claude

**Files:**
- Modify: `modules/nixos/features/agent-common.nix` (options block near `projects`; `managedClaudeSettings.hooks`; the jq filter in `claudeSettingsMerge`)
- Modify: `modules/nixos/features/agent-env/agent_net.py`
- Modify: `modules/nixos/features/agent-env.nix`
- Test: `modules/nixos/features/agent-env/tests/test_agent_net_hooks.py`

**Interfaces:**
- Consumes: `status()` from Task 1.
- Produces (CLI): `agent-net hook session-start` and `agent-net hook prompt`. Both read Claude hook JSON on stdin (`session_id`) and print either nothing or `{"hookSpecificOutput": {"hookEventName": "SessionStart"|"UserPromptSubmit", "additionalContext": <text>}}`. Always exit 0.
  - session-start text: `Network: <agent-net line>. See "Network" in your global instructions.`
  - prompt text, only on change: `Network changed: now <agent-net line>.`
  - State per session in `${XDG_RUNTIME_DIR}/agent-net/<session_id>` (the `state` field only). Prompt with no stored state stores silently.
- Produces (Nix option): `preferences.agents.claudeHooks : attrsOf (listOf str)`, default `{}`, event name → extra hook commands appended after the built-in group for that event (new events allowed). `agent-env.nix` sets `SessionStart = ["<agent-net> hook session-start"]` and `UserPromptSubmit = ["<agent-net> hook prompt"]` with absolute store paths.
- The merge filter's `contains(...)` list also drops entries containing `agent-net`, so redeploys replace rather than duplicate.

- [ ] **Step 1: Write the failing tests**
  - `test_session_start_emits_context`: metered fakes, stdin `{"session_id":"s1"}` → JSON with eventName `SessionStart` and text `Network: metered (wildflower, wlo1). See "Network" in your global instructions.`
  - `test_prompt_silent_when_unchanged`: session-start then prompt, same fakes → prompt stdout empty.
  - `test_prompt_reports_change`: session-start metered; switch nmcli fake to `no\nhome`; prompt → text `Network changed: now unmetered (home, wlo1).`; a second prompt → empty.
  - `test_prompt_unknown_session_stores_silently`: prompt for `s9` with no prior state → empty stdout, state file written.
  - `test_hook_survives_garbage` (Review Focus 1): stdin `not json`, plus a case with an `nmcli` fake that sleeps 5 s → exit 0, empty stdout, wall time < 2 s.
- [ ] **Step 2: Run the unit tests.** Expected: the new tests FAIL.
- [ ] **Step 3: Implement the `hook` subcommand** in `agent_net.py`. Wrap the whole hook path in `try/except BaseException` → exit 0.
- [ ] **Step 4: Add the `claudeHooks` option** in `agent-common.nix`, fold it into `managedClaudeSettings.hooks` (`group (builtin ++ extra)` per event, plus events only in `claudeHooks`), extend the jq filter with `contains("agent-net")`, and set the option in `agent-env.nix`.
- [ ] **Step 5: Expose and verify the managed settings.** In `agent-common.nix`, also install the managed JSON as `xdg.configFile."agents/claude-managed.json".source` (handy for debugging later, too). Run `nix build --no-link --print-out-paths "$(nix eval --raw .#nixosConfigurations.hazel.config.home-manager.users.$(nix eval --raw .#nixosConfigurations.hazel.config.preferences.user.name).xdg.configFile.\"agents/claude-managed.json\".source)"` and `jq .hooks` the result. Expected: `SessionStart` = [agent-net hook session-start]; `UserPromptSubmit` = agent-status working, then agent-net hook prompt. Unit tests and `checks.agent-env` PASS.

### Task 3: `nx` store-first runner

**Files:**
- Create: `modules/nixos/features/agent-env/nx.py`
- Create: `modules/nixos/features/agent-env/tests/test_nx.py`
- Modify: `modules/nixos/features/agent-env.nix` (package `nx`; deps suffix `nix nix-index`, plus the `agent-net` package)

**Interfaces:**
- Consumes: `agent-net --json` (subprocess; missing, non-zero or bad JSON → unmetered, connection null).
- Produces (CLI): `nx [-p ATTR] [--exact] PROG [ARGS...]`, `nx --py PKG [PKG...] -- [PYTHON ARGS...]`. Exit codes: 2 = not found/ambiguous, 3 = refused on metered, otherwise the child's (via `os.execvp`). Env: `NX_FORCE=1`, `NX_METERED_LIMIT_MB` (default 50), `NX_STORE_DIR` (default `/nix/store`, for tests).
- Produces (Python, unit-testable): `parse_dry_run(stderr: str) -> tuple[float, list[str]]` (download MiB, names of derivations to build).
- Exact stderr lines (one each):
  - `nx: using <basename of store path> from the store (not the pinned version)`
  - `nx: fetching <attr> (<N> MiB download)` (N rounded to an int; omitted when 0)
  - `nx: <attr> needs <N> MiB download; on a metered link (<conn>). Re-run with NX_FORCE=1 to fetch.`
  - `nx: <attr> needs building <comma-separated drv names>; on a metered link (<conn>). Re-run with NX_FORCE=1 to build.`
  - ambiguous: `nx: <prog> is provided by several packages: <a>, <b>, <c>; pick one with -p` (top 5)

Resolution order (spec §5): PATH (skipped with `-p`) → `nix-locate --minimal --whole-name --at-root --top-level /bin/<prog>` (strip the `.out` suffix; prefer the attr equal to `prog`; one hit → use it; several and none equal → ambiguous) → `nix eval --raw nixpkgs#<attr>.outPath`, exists → exec `<path>/bin/<prog>` → (unless `--exact`) `nix eval --raw nixpkgs#<attr>.pname`, newest `NX_STORE_DIR/*-<pname>-<digit>*/bin/<prog>` (not `.drv`; version-sorted on the part after `<pname>-`; `nix-store --check-validity <path>` exits 0) → `nix build --dry-run nixpkgs#<attr>`, gate, `nix shell nixpkgs#<attr> -c <prog> ARGS`. `--py`: the same gate on the expression `(builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.python3.withPackages (p: with p; [PKGS])` via `--impure --expr`, then `nix shell --impure --expr … -c python3 ARGS`. Derivations whose name ends in `-env` don't count as builds for the gate.

- [ ] **Step 1: Write the failing tests** (fake `nix`, `nix-locate`, `nix-store`, `agent-net`; the fake `nix` dispatches on its argv via a small case statement the test writes)
  - `test_parse_dry_run_units` (Review Focus 4): `these 3 paths will be fetched (1.50 MiB download, 6 MiB unpacked):` → 1.5; `(512.0 KiB download` → 0.5; `(2.00 GiB download` → 2048; empty string → `(0.0, [])`; `these 2 derivations will be built:\n  /nix/store/abc-foo-1.0.drv\n  /nix/store/def-python3-3.13-env.drv` → names `["foo-1.0", "python3-3.13-env"]`.
  - `test_on_path_execs_directly`: `prog` is a fake on PATH → its output, no `nix` calls.
  - `test_pinned_present`: locate → `openssl.out`; eval outPath → a temp dir containing `bin/openssl` fake → runs it, no `nix build` call.
  - `test_other_version_from_store`: pinned outPath missing; `NX_STORE_DIR` has `aaa-python3-3.12.11/bin/python3` and `bbb-python3-3.13.18/bin/python3` → runs 3.13.18, stderr has the "not the pinned version" line with `bbb-python3-3.13.18`.
  - `test_exact_skips_store_scan`: same as above with `--exact` → goes to dry run.
  - `test_metered_refuses_large`: agent-net metered (`wildflower`), dry run 312 MiB → exit 3, exact refusal line, no `nix shell` call.
  - `test_metered_force`: same with `NX_FORCE=1` → `nix shell` called.
  - `test_metered_refuses_build_but_not_env`: dry run builds `foo-1.0.drv` → exit 3 with the build line; builds only `python3-3.13-env.drv` and fetches 1 MiB → proceeds.
  - `test_unmetered_large_proceeds`: 312 MiB, unmetered → stderr `nx: fetching openssl (312 MiB download)`, `nix shell` called.
  - `test_agent_net_missing` (Review Focus 5): no agent-net fake → behaves as unmetered.
  - `test_ambiguous`: locate returns `foo.out\nbar.out` for prog `baz` → exit 2, message lists both.
  - `test_py_builds_expression`: `--py requests rich -- -c 'print(1)'` → `nix shell` argv contains `--impure`, `--expr`, an expression with `[requests rich]`, then `-c python3 -c print(1)`.
- [ ] **Step 2: Run the unit tests.** Expected: the nx tests FAIL.
- [ ] **Step 3: Implement `nx.py`** per the resolution order and messages above.
- [ ] **Step 4: Run the unit tests and `checks.agent-env`.** Expected: PASS.
- [ ] **Step 5: Smoke on the real store** (read-only, no downloads): `nix run .#…` isn't exposed, so `python3 modules/nixos/features/agent-env/nx.py --exact -p hello hello` with `NX_METERED_LIMIT_MB=0` and `agent-net set metered` (or a fake), so it can only refuse or use the store. Expected: either `Hello, world!` (present) or the refusal line with a real size. Then `agent-net set auto`.

### Task 4: `agent-devshell` and T3 wiring

**Files:**
- Create: `modules/nixos/features/agent-env/agent_devshell.py`
- Create: `modules/nixos/features/agent-env/tests/test_agent_devshell.py`
- Modify: `modules/nixos/features/agent-env.nix` (package `agent-devshell`, deps suffix `direnv git systemd` plus `agent-net`; wrappers `claude-devshell` / `opencode-devshell` = `exec agent-devshell /etc/profiles/per-user/<user>/bin/<claude|opencode> "$@"`)
- Modify: `modules/nixos/features/agent-t3code.nix` (`limits.providers.instances.{claudeAgent,opencode}.binaryPath` → `${userBin}/claude-devshell` / `${userBin}/opencode-devshell`)

**Interfaces:**
- Consumes: `agent-net --json` (same fallback as nx).
- Produces (CLI): `agent-devshell BINARY [ARGS...]`, always ends in `os.execvpe`, with `AGENT_DEVSHELL` set:
  1. root = nearest dir with `.envrc`, from cwd upward, stopping **before** `$HOME` and `/`. None → `none`.
  2. `direnv status --json` (cwd = root): `.state.foundRC.allowed == 0` → allowed. Otherwise check the worktree exception: `git -C root rev-parse --show-toplevel --git-common-dir`; when the common dir is not `<toplevel>/.git`, main toplevel = parent of the common dir, main root = main toplevel / (root relative to toplevel); if `main_root/.envrc` is allowed (direnv status there) and byte-identical → `direnv allow <root>` and continue as allowed. Else `not-allowed`.
  3. cached ⇔ some `.direnv/flake-profile-*` symlink (no `.rc` suffix) resolves to an existing path **and** its `.rc` file is newer than every existing `flake.nix`, `flake.lock`, `.envrc`, `devenv.nix`, `devenv.yaml`, `devenv.lock` in root. For a worktree: also cached when the main root is cached and those files are byte-identical between the two (direnv then re-evaluates locally against store paths the main checkout already roots; no seeding needed, which is a simplification of the spec).
  4. cached → exec `direnv exec <root> env AGENT_DEVSHELL=loaded BINARY ARGS...`.
  5. not cached → `not-built`, exec BINARY; if unmetered, first fire `systemd-run --user --collect --quiet --unit agent-devshell-warm-<sha1(root)[:12]> -- direnv exec <root> true` (ignore its failure).
  6. any exception → `error`, exec BINARY.

- [ ] **Step 1: Write the failing tests.** Fake `direnv`, `git`, `systemd-run`, `agent-net`. The target BINARY is a fake that prints `AGENT_DEVSHELL` and its argv as JSON. The fake `direnv exec` execs its trailing args (`shift 2; exec "$@"`). Real temp dirs; `HOME` set to a temp parent.
  - `test_no_envrc_none`
  - `test_not_allowed`: status allowed=1 → `not-allowed`, no `direnv exec`.
  - `test_loaded_when_cached`: allowed, profile symlink → existing dir, `.rc` touched after `flake.nix` → `loaded`, `direnv exec <root>` called.
  - `test_stale_profile_not_built`: `flake.lock` newer than `.rc` → `not-built`.
  - `test_nested_cwd_finds_root` (Review Focus 2): cwd `root/app/src` → direnv called with `root`.
  - `test_envrc_in_home_ignored`: `.envrc` only in `$HOME` → `none`.
  - `test_argv_passthrough` (Review Focus 3): args `--flag="a b"`, `it's`, `x=y`, `""` arrive identical in the `loaded`, `not-built` and `none` branches.
  - `test_warmup_only_unmetered`: not cached + unmetered → one systemd-run call; metered → none.
  - `test_worktree_auto_allow`: git fake reports common dir `<main>/.git` for root `<wt>`; main status allowed, identical `.envrc` → `direnv allow <wt>` called; differing `.envrc` → no allow, `not-allowed`.
  - `test_worktree_cached_via_main`: main cached, shell files identical, worktree has no `.direnv` → `loaded`.
  - `test_error_still_execs`: `direnv` fake exits 1 with garbage → `error`, binary ran.
  - `test_agent_net_missing`: not cached, no agent-net → warm-up fired (treated as unmetered).
- [ ] **Step 2: Run the unit tests.** Expected: the devshell tests FAIL.
- [ ] **Step 3: Implement `agent_devshell.py`.**
- [ ] **Step 4: Package it, add the wrappers, repoint T3's `binaryPath`s.** The `claudeWork` instance follows the driver pin; `CLAUDE_CONFIG_DIR` from T3 passes through untouched.
- [ ] **Step 5: Run the unit tests, `checks.agent-env`, `just eval hazel` and `just eval butternut`.** Expected: PASS. Then the policy: `nix eval --json .#nixosConfigurations.hazel.config.home-manager.users.<user>.systemd.user.services.t3code.Unit.X-Restart-Triggers` gives the policy file path; `nix build --no-link` it and `grep -o '"binaryPath":"[^"]*"'`. Expected: paths ending in `claude-devshell` and `opencode-devshell`.
- [ ] **Step 6: Real direnv smoke** (no build): from this repo's main checkout, `python3 modules/nixos/features/agent-env/agent_devshell.py env | grep -E '^AGENT_DEVSHELL|^DEVENV_ROOT'`. Expected: `AGENT_DEVSHELL=loaded` and a `DEVENV_ROOT` line if the repo's shell is cached; `not-built` otherwise. Report which.

### Task 5: Global guidelines

**Files:**
- Create: `modules/nixos/features/agent-env/guidelines.md`
- Modify: `modules/nixos/features/agent-env.nix` (`xdg.configFile."agents/guidelines.md".source`; activation `agentGuidelinesImport` after `writeBoundary`; OpenCode wiring)
- Modify: `modules/nixos/features/agent-common.nix` only if `accountDirs` must be exposed (prefer recomputing it from `config.preferences.agents.claudeAccounts` in agent-env.nix)

**Interfaces:**
- Produces: `~/.config/agents/guidelines.md`. For every Claude account dir, `$HOME/<dir>/CLAUDE.md` contains the line `@~/.config/agents/guidelines.md` (create the file if missing; append with a separating blank line if non-empty; never rewrite other content; idempotent). OpenCode: the global `~/.config/opencode/AGENTS.md` gets the same content, if OpenCode 2.x reads it. Otherwise use opencode.json's `instructions` list pointing at the guidelines path. Check OpenCode 2.x docs/source in the `llm-agents` input to see which one it supports, and say which you used.

Guidelines content (about 40 lines, four `##` sections; the wording within them is the builder's, but these points are fixed by the spec):
- `## Environment`: project work (build, test, lint, run, anything version-sensitive) runs in the project's dev shell. Check `$AGENT_DEVSHELL`: `loaded` = you're in it; after editing `flake.nix`/`.envrc`/devenv files, run project commands as `direnv exec . <cmd>`; `not-allowed` = tell the user, never run `direnv allow` yourself; `not-built` = mention it, and use `direnv exec . <cmd>` only when you need the shell now (it builds; on a metered link say so first); unset = not started through T3, so assume your shell as-is. Generic tools that don't depend on the project come from `nx`; never pick "close enough" versions for project work.
- `## Tools (nx)`: what it does in one line; examples `nx openssl version`, `nx -p ffmpeg ffprobe in.mp4`, `nx --py requests -- script.py`; exit 3 means refused on a metered link, so report it rather than forcing it, unless the user agreed.
- `## Network`: the session context or `agent-net` says metered or unmetered. On metered, prefer work where the data lives (`kubectl … -o jsonpath`, `aws … --query/--max-items`, `| head`, `wc -l` first), avoid large pulls without reason. On unmetered, relax. When the network changed what you did, say so in one line ("skipped the 2.1 GB image pull: on the hotspot"). Guidance, not a hard rule.
- `## Editing`: for large or repetitive edits, write and run a short Python (stdlib) script instead of many edit-tool calls; show the script or summarise what it changed.

- [ ] **Step 1: Write a failing test** `tests/test_guidelines.py::test_sections_and_import_line`: `guidelines.md` has exactly the four headings above, mentions `AGENT_DEVSHELL`, `direnv exec .`, `nx`, `agent-net`, and is ≤ 60 lines. The activation snippet is a script `agent-env/guidelines-import.sh DIR...`, testable on its own: `test_import_idempotent` runs it twice on (a) a missing file, (b) a file with user text and no trailing newline, and expects the user text kept and the import line present exactly once.
- [ ] **Step 2: Run the unit tests.** Expected: FAIL.
- [ ] **Step 3: Write `guidelines.md` and `guidelines-import.sh`, then wire both, plus OpenCode, in `agent-env.nix`.**
- [ ] **Step 4: Run the unit tests, `checks.agent-env` and `just eval hazel`.** Expected: PASS.

### Task 6: Metered cable share on butternut

**Files:**
- Modify: `modules/nixos/features/cable-link.nix` (option next to `preferences.cable.peer`; the `${sharePeer}` profile)
- Modify: `modules/nixos/hosts/butternut/network.nix` (or `configuration.nix`, wherever `preferences.cable` is set for butternut)

**Interfaces:**
- Produces: `preferences.cable.peerSharesMetered : bool`, default `false`, description "Mark `<peer>-shares` as metered (the peer is a carried device that may be on a phone hotspot)." When true, `${sharePeer}` gets `connection.metered = 1` (NM keyfiles store the enum as an integer; `"yes"` is silently dropped). butternut sets `true`; hazel keeps the default.

- [ ] **Step 1: Add the option and the conditional** (`lib.optionalAttrs cfg.peerSharesMetered {connection.metered = 1;}` merged into the profile), and set it on butternut.
- [ ] **Step 2: Verify:** `nix eval .#nixosConfigurations.butternut.config.networking.networkmanager.ensureProfiles.profiles.hazel-shares.connection.metered` → `1`; the same path for hazel's `butternut-shares` has no `metered` attribute (`nix eval … --apply 'c: c ? metered'` → `false`).

### Task 7: Whole-repo check and hand-off notes

- [ ] **Step 1: Run** `just check` (raw: the `fmt-check`, `lint` and `eval-all` recipes in `justfile`). Expected: fmt clean, deadnix clean, every host OK except the known SKIP `niri-desktop-vm`.
- [ ] **Step 2: Append a section to `docs/plans/2026-11-17-user-actions.md`**: after deploying hazel/butternut, (1) open a new T3 thread in a direnv project and ask the agent for `echo $AGENT_DEVSHELL`; expect `loaded`. (2) Check whether the session context showed the `Network:` line. If not, the Agent SDK isn't loading user settings hooks (the spec's open question); report it so the follow-up can pin it via the provider `environment`. (3) Check that T3 started the provider in the worktree directory (`pwd` in the thread). Give these as paste-ready commands, per the user's preference.
- [ ] **Step 3: Report** which OpenCode instructions mechanism was used, the Task 4 Step 6 smoke result, and anything that deviated from the spec (the known one: no `.direnv` seeding for worktrees).
