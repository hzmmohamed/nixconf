# Work projects review: Nix pinning and worktree/agent readiness (2026-11-17)

Read-only review of two work repos against the agentic-workspace design
(`2026-11-17-agentic-workspace-design.md`): one git worktree per stream, agents in
`agents.slice`, compute picked per need, slow uplink, Nix purist. Nothing in either
repo was changed. Citations are `file:line` relative to each repo root.

Host facts that matter for both (hazel/butternut today):

- `nix config show`: `flake-registry = https://channels.nixos.org/flake-registry.json`,
  `use-registries = true`, `nix-path = nixpkgs=flake:nixpkgs …/channels`,
  `accept-flake-config = false` (good, keep it). User registry has `unstable`,
  `nixos`; system registry pins `nixpkgs` to a store path.
- direnv loads system nix-direnv 3.1.2 (`/etc/direnv/direnvrc`).
- `aws`, `docker`, `node`, `pnpm`, `kubectl`, `kind` come from
  `/run/current-system/sw/bin`, **not** from either project's shell. `gh`, `jq`,
  `ctlptl`, `tilt` (outside routelab's shell) are missing on the host.
- nixconf pins `nixos-26.05` at `b349185b` (2026-11-15).

---

## 1. routelab-monorepo

### Current state

| Item | Finding |
|---|---|
| HEAD | `154a2eebc` on `feat/observability-phase-1` (2026-11-16), 50 dirty/untracked paths |
| Flake | flake-parts + `devenv.flakeModule` (`flake.nix:20-21`); shells `default` (web) and `mobile` (Android), plus `packages.mobile-ci-image` |
| Inputs | `nixpkgs` = `github:nixos/nixpkgs?rev=331800de…` (`flake.nix:10`, locked 2026-05-31); `devenv` = `github:cachix/devenv` (unpinned branch, `:11`, locked `3f0b902b` 2026-03-02); `flake-parts` (`:9`, 2026-03-01); `devenv-root` = `file+file:///dev/null` (`:5-8`) |
| Lock | 15 nodes, all `github:` types, no indirect/registry refs. `flake.lock` **is tracked** although `.gitignore:59` ignores it (force-added; a fresh clone is fine, but `git add -A` style tooling won't pick up a regenerated lock without `-f`) |
| `.envrc` | tracked (also ignored at `.gitignore:58`); `nix_direnv_version 3.0.6` guard with hashed `source_url` fallback; writes `$PWD` to a `mktemp` file and does `use flake . --override-input devenv-root file+file://…` |
| `nixConfig` | none |
| systems | `x86_64-linux i686-linux x86_64-darwin aarch64-linux aarch64-darwin` (`flake.nix:22-28`) |
| Android | Nix-provided: devenv `android` module (`flake.nix:554-590`) = `androidenv` (platforms 32–36, NDK 27.x, emulator 35.2.5, x86_64 google_apis_playstore images). CI image uses `androidenv.composeAndroidPackages` directly (`:235-245`). Good. |
| JDK | `jdk17` (`flake.nix:317-319`, `:253`) |
| AGENTS.md / CLAUDE.md | both present (31 KB / 32 KB, near-identical copies, not a symlink) |
| `.mcp.json` | one server: `npx -y effect-mcp@latest` |
| `.claude/` | only `projects/…/memory/*.md` (two files are **tracked**) and an empty `worktrees/`; no `settings.json` |
| `t3.json`, `.agents/` | absent |
| Sizes | `.git` 1.1 G (pack 237 MiB); tracked files ~240 MB; working tree 35 G. Big untracked: `apps/` 15 G (`apps/observer` 11 G: `node_modules` 4.1 G, `android/app/build` 2.3 G, `android/.gradle` 462 M), `.android` 7.0 G (AVDs), `.repos` 4.6 G (26 submodules), `infra` 3.4 G (mostly node_modules), `packages` 2.1 G, `.turbo` 1.3 G, `.local` 1.2 G, `.devenv` 528 M, root `node_modules` 357 M |
| Shared caches (home) | `~/.local/share/pnpm` 20 G, `~/.cache/pnpm` 3.4 G, `~/.gradle` 8.1 G (wrapper dists 6.7.1, 8.14.3, 9.0.0) |

### Problems, ranked

1. **Committed production credential.** `Tiltfile:301` contains a full Postgres
   connection string with an embedded password for an `*.elb.eu-central-1.amazonaws.com`
   host (legacy observer DB). Every worktree and every agent transcript sees it.
   Rotate it, move it to sops/`.env`, and purge from history if the repo is ever shared.
   (Value deliberately not reproduced here.) Related, not committed but agent-readable:
   `~/.gradle/gradle.properties` holds the observer upload-keystore passwords;
   `apps/dashboard/.env`, `apps/observer/.env` exist (git-ignored).
2. **Devshell ships stale agent CLIs that shadow the global ones.** `claude-code`
   and `opencode` are in both shells (`flake.nix:130-131`, `:327-328`) from the
   2026-05-31 nixpkgs: claude-code **2.1.158** (`.devenv/profile/bin/claude`) vs
   the host's 2.1.282. Any agent/T3 Code process that runs inside the direnv env
   gets the old binary first on `PATH`. Remove them; agents come from nixconf
   (`programs.claude-code`, llm-agents.nix).
3. **`$PWD`-dependent state makes every worktree a different, heavier env.**
   - `devenv.root` is injected from `$PWD` (`.envrc` + `flake.nix:39-46`); it is
     part of the derivation, so each worktree evaluates a distinct shell env
     (store paths of the SDK are shared, but the env and `rl-dev-mobile` GC root
     are per checkout).
   - devenv's android module exports `ANDROID_USER_HOME=$(pwd)/.android` and
     `ANDROID_AVD_HOME=$(pwd)/.android/avd` (seen in
     `/nix/store/…-routelab-mobile-env`): each worktree would get its own 7 G
     `.android` and must re-run `create-avd`; entering from a subdirectory puts
     AVDs in the wrong place.
   - `.devenv/` (528 M profile, `tasks.db`, process-compose state) is per checkout.
   - `.envrc` leaks one `mktemp` file per reload.
4. **Git hooks break in worktrees.** `core.hooksPath = .git/hooks` (relative). In a
   linked worktree `.git` is a file, so `<worktree>/.git/hooks` doesn't exist → hooks
   silently don't run. The installed `pre-commit` hook also hard-codes a store bash
   (`/nix/store/51sszqz1…-bash-5.2-p15`) that GC can remove. `.husky/` exists too
   (`pnpm exec lint-staged`), so two hook systems compete.
5. **Inputs not fully pinned / hygiene.**
   - `devenv` follows a branch (`flake.nix:11`) and drags its own nixpkgs
     (`cachix/devenv-nixpkgs/rolling`, 2025-10-24), `nix` (devenv-2.32), `nixd`,
     `cachix`, `git-hooks`, `flake-compat`, two `flake-parts`, `nixpkgs-lib` — no
     `follows`. That's a second full nixpkgs tree (only devenv's own tooling uses
     it, but it must be fetched on every new target, over a slow link).
   - `nixpkgs` is pinned with `?rev=` in the URL (`:10`), so `nix flake update`
     can't move it; bumps need hand edits and the lock and URL can drift.
   - `nixpkgs` is 5.5 months old.
6. **Impure runtime fetches.** `.mcp.json` runs `npx -y effect-mcp@latest`
   (unpinned, network on every session); `rl-dev-build-sqlite` runs
   `npx --yes node-gyp` (`flake.nix:195`, `:350`); Gradle wrapper downloads
   distributions from services.gradle.org (`apps/observer/android/gradle/wrapper/gradle-wrapper.properties`);
   `Tiltfile:173` uses `nix shell --inputs-from . nixpkgs#emscripten …` (pinned via
   the flake's nixpkgs — acceptable, but it's a build at Tilt time, not in the shell).
   `.envrc` falls back to fetching nix-direnv from GitHub when the host lacks it
   (hashed, so pinned, but network).
7. **Agent essentials missing from the shell.** No `git` (only referenced by store
   path in scripts), `gh`, `jq`, `ripgrep`, `fd`, `docker`/`docker-compose`,
   `kubectl`, `ctlptl`, `kind`, `awscli2`, `postgresql` client (`psql` only via store
   path in `rl-dev-db-clean`), `typescript-language-server`/`vtsls`, `adb` (mobile
   shell only). Today these leak in from the host system profile.
8. **Concurrency collisions between worktrees.** Fixed ports in Tilt/compose (5432,
   5005, 3040, 3000/3002, 4000-4002, 3100, 4566, 9187) and the default compose
   project name = directory name → a second worktree either fails to bind or starts
   a fresh empty Postgres volume. `ctlptl-config.yaml` registry port 5005 also
   collides with gql-api's 5005 (looks vestigial — Tiltfile uses `docker_compose`,
   no k8s resources).
9. **Repo hygiene that confuses agents.** Stray files from mis-quoted commands in the
   root: `--desired-status`, `--query`, `--record-type`, `:5432`, `.grafana.net`,
   `infra/stack/--record-data`, `infra/stack/--record-ttl`; large binaries at root
   (`MBTA_GTFS.zip` 22 MB, HTML decks). `AGENTS.md` and `CLAUDE.md` are two diverging
   copies.
10. **Minor.** `systems` lists `i686-linux`/darwin (`flake.nix:22-28`) — never built,
    widens `nix flake check`; `allowUnfreePredicate = pkg: true` (`:103`) is broad;
    `rl-dev-db-clean`/`rl-dev-build-sqlite` are duplicated across both shells;
    `QT_QPA_PLATFORM=xcb` (`:593`) forces XWayland for the emulator.

### Proposed patch plan

**P1 — secrets (do first).** Replace `Tiltfile:301` value with
`os.getenv("LEGACY_DB_URL")` read from a git-ignored `.env.tilt` (or sops-decrypted
at shell entry). Rotate the password.

**P2 — pin everything, drop the impure root.**

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";          # branch in URL, rev in lock
  flake-parts.url = "github:hercules-ci/flake-parts";
  flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  devenv.url = "github:cachix/devenv/v1.x.y";                 # a release tag, not main
  devenv.inputs.nixpkgs.follows = "nixpkgs";                  # one nixpkgs tree
  # devenv-root removed (see below)
};
nixConfig = { };  # deliberately empty: never rely on accept-flake-config
systems = [ "x86_64-linux" "aarch64-linux" ];
```

Option A (minimal): keep devenv, keep `devenv-root`, but derive the root from
`git rev-parse --show-toplevel` in `.envrc` instead of `$PWD`, and set
`env.ANDROID_USER_HOME`/`ANDROID_AVD_HOME` explicitly (below) so devenv's
`$(pwd)` default is overridden.

Option B (recommended for "no ambiguity"): replace devenv with a plain
`pkgs.mkShell` per shell. Nothing devenv-specific is used except `scripts`,
`android`, `languages.*` and `info` — all trivially expressible as
`writeShellApplication`s + `androidenv.composeAndroidPackages` (already written for
the CI image at `flake.nix:235-245`). This removes `--impure`/`devenv-root`, the
second nixpkgs, `.devenv/` state, and makes the shell identical across worktrees
and targets. Share one `android` composition between `mobile` shell and
`mobile-ci-image` (add `includeEmulator`/`includeSystemImages` only for the shell).

**P3 — devShell contents** (both shells, via a shared `commonPackages` list):

```nix
commonPackages = with pkgs; [
  git gh jq ripgrep fd just
  nodejs_24 pnpm typescript-language-server vtsls
  postgresql_17 docker-client docker-compose tilt
  awscli2 kubectl kind ctlptl            # only if k8s is still used; else drop + delete ctlptl-config.yaml
  python314 gnumake stdenv.cc node-gyp   # replaces `npx --yes node-gyp`
];
# mobile adds: jdk17, android sdk, maestro, sqlitebrowser, scrcpy
# REMOVE: claude-code, opencode (come from nixconf)
```

Env for the mobile shell (shared, per-machine, not per-worktree):

```nix
ANDROID_USER_HOME = "$HOME/.local/share/routelab/android";   # set in shellHook so $HOME expands
ANDROID_AVD_HOME  = "$HOME/.local/share/routelab/android/avd";
GRADLE_USER_HOME  = "$HOME/.gradle";                          # explicit; shared, has its own locking
```

Move the existing `.android/avd` there once (7 G), then fix the absolute `path=` in
`*.ini`.

**P4 — `.envrc`** (identical in every worktree, no temp files):

```bash
# nix-direnv is provided by the host; fail loudly instead of curling it
nix_direnv_manual_reload   # optional: avoid surprise rebuilds while agents edit flake.nix
watch_file flake.nix flake.lock nix/*.nix
use flake ".#${ROUTELAB_SHELL:-default}"
dotenv_if_exists .env.local
```

T3 setup for mobile streams sets `ROUTELAB_SHELL=mobile` (or a second
`.envrc.mobile` sourced via `source_env_if_exists`).

**P5 — hooks.** Pick one system. Either set `core.hooksPath` to an absolute,
worktree-independent path (e.g. `git config core.hooksPath .husky/_` — relative to
the worktree root, which exists in every worktree because it's tracked) or let
git-hooks.nix generate them with `pkgs` store paths and re-install in the T3 setup
script. Don't leave `.git/hooks` as a relative hooksPath.

**P6 — MCP.** Pin `effect-mcp` to an exact version, or better package it with
`buildNpmPackage` in the flake (`packages.effect-mcp`) and point `.mcp.json` at
`nix run .#effect-mcp` — or move it into nixconf `programs.mcp` per-project.

**P7 — concurrency.** Make ports overridable by an offset: `RL_PORT_BASE` read in
`Tiltfile`/compose (`${RL_PG_PORT:-5432}`), and set
`COMPOSE_PROJECT_NAME=routelab` explicitly so all worktrees share **one** DB stack
by default (agents talk to the shared DB; only streams that change schema get their
own stack with an offset). Document this in AGENTS.md.

**P8 — hygiene.** Delete the stray `--*`/`:5432` files; make `CLAUDE.md` a symlink
to `AGENTS.md`; un-track `.claude/projects/**/memory` (it's personal agent memory);
add an "Agent rules" section to AGENTS.md: shell commands must quote args, never
start the emulator per worktree, use `adb -s emulator-5554`.

### Worktree sharing scheme

| Thing | Size | Per-worktree or shared | How |
|---|---|---|---|
| tracked source | ~240 MB | per worktree | `git worktree add` |
| `.repos/*` submodules | 4.6 G | shared, read-only | **don't** `submodule update` in worktrees; symlink `.repos` → main checkout's `.repos` (they're reference code for agents) |
| pnpm store | 20 G | shared | already global (`~/.local/share/pnpm`); `pnpm install --frozen-lockfile --prefer-offline` hard-links, so a worktree's `node_modules` costs little on the same filesystem |
| `node_modules` (all) | ~7 G | per worktree (hard links) | setup script |
| `.turbo` | 1.3 G | shared | `TURBO_CACHE_DIR=$HOME/.cache/routelab/turbo` |
| Gradle | 8.1 G + 2.7 G | `~/.gradle` shared; `android/.gradle` + `app/build` per worktree | only on streams that build the APK |
| AVDs / emulator | 7 G | shared, **one emulator per machine** | `ANDROID_AVD_HOME` as above; streams attach via `adb` |
| `.devenv` | 528 M | per worktree (gone with option B) | — |
| `.env` files | tiny | shared | setup symlinks `apps/*/.env` from main checkout |
| `.local`, `.tiles`, `.open-tiles`, `.objects`, `.ticker-import` | 1.2 G | shared | symlink from main checkout |
| Postgres/compose volumes | — | shared stack by default | `COMPOSE_PROJECT_NAME=routelab` |

### `t3.json` sketch (verify schema against T3 Code docs)

```json
{
  "worktree": {
    "setup": [
      "ln -sfn \"$T3_MAIN_CHECKOUT/.repos\" .repos",
      "for f in apps/dashboard/.env apps/observer/.env; do [ -e \"$T3_MAIN_CHECKOUT/$f\" ] && ln -sfn \"$T3_MAIN_CHECKOUT/$f\" \"$f\"; done",
      "for d in .local .tiles .open-tiles .objects; do ln -sfn \"$T3_MAIN_CHECKOUT/$d\" \"$d\"; done",
      "direnv allow .",
      "direnv exec . pnpm install --frozen-lockfile --prefer-offline"
    ],
    "teardown": ["rm -rf node_modules apps/*/node_modules packages/*/node_modules"]
  }
}
```

`.agents/targets.toml`: `default = "heavy"`, `android-emulator = "android"` (→ butternut,
needs `/dev/kvm` + GPU; `start-emulator` already warns on missing KVM,
`flake.nix:489-492`).

### Risks

- Dropping devenv changes the env shape (scripts move from devenv `scripts` to
  packages); CI's `mobile-ci-image` is unaffected but the CI cache key
  (hash of flake.nix/lock) changes once.
- Bumping nixpkgs from 2026-05 to 26.05-latest may change androidenv attribute names
  / emulator version — rebuild of unfree SDK pieces is local (not on cache.nixos.org);
  do it on butternut, keep the GC root (`rl-dev-mobile`'s `--profile` idea) or push to
  the planned private cache.
- One shared Postgres for many agents: a stream running `rl-dev-db-clean` wipes
  everyone's data. Gate destructive scripts behind `RL_ALLOW_DESTRUCTIVE=1`.
- Symlinked `.repos` means an agent editing a reference repo edits it for all
  streams — make them read-only (`chmod -R a-w` or a read-only bind mount).

---

## 2. d_abm

### Current state

| Item | Finding |
|---|---|
| HEAD | `039b423` on `feat/sampling-sweep` (2026-11-16); uncommitted `flake.nix` change (adds `cartopy`, `pkgs.sumo`) |
| Flake | hand-rolled `forEachSupportedSystem`; one `devShells.default` (`flake.nix:281-345`), one `checks.pre-commit-check` |
| Inputs | `nixpkgs` and `nixpkgs-unstable` both `b40629ef` (2026-03-18) (`flake.nix:8-9`); `nixpkgs-unstable-25` `aefcb0d5` (2025-07-24) (`:7`); `nixpkgsMaven` `4d887ae7` (2023-06-18) (`:10`); `pre-commit-hooks` unpinned branch (`:5`) locked 2023-10-01 with its own `nixpkgs_2` (2023-07-13) and `nixpkgs-stable` (nixos-23.05) |
| Lock | 11 nodes, all `github:`, no registry refs; **5 distinct nixpkgs revisions** |
| `.envrc` | `use flake .` — **not tracked** (`.gitignore:6`), so a new worktree has no `.envrc` |
| `nixConfig` | none |
| systems | `x86_64-linux aarch64-linux x86_64-darwin aarch64-darwin` (`flake.nix:20`) |
| Python | Nix-provided `python313.withPackages` (`:289-325`) with 9 PyPI packages built in-flake (`:95-279`). `pyproject.toml` still has a stale `[tool.poetry]` (pandas 1.5, polars 0.19, `packages = [{include = "d_abm"}]` which doesn't exist); `poetry.lock` from 2025-04; `pkgs.poetry` in shell (`:330`). A Poetry venv `~/.cache/pypoetry/virtualenvs/eg-abm-CQeEGoQl-py3.13` exists (unused leftover) |
| JDK / Maven | `jdk25` from the main pkgs (`:340`), `maven` from the 2025-07 tree (`:343`); `java_binary: java` (`conf/base/parameters.yml:32`) → whatever is on `PATH` |
| MATSim jars | `tools/matsim-2026.0/matsim-2026.0.jar`, `tools/pt2matsim-26.4-shaded.jar` (`conf/base/parameters.yml:41-42`) — `tools/` is git-ignored (`.gitignore:210`) except force-added osmosis; paratransit jar from sibling repo `../matsim-paratransit/target/…-shaded.jar` (`conf/base/parameters_paratransit.yml:25`, `parameters_sim_stage.yml:16`) |
| Agent files | no AGENTS.md, no CLAUDE.md, no `.mcp.json`, no `t3.json`; `.claude/` has only `projects/…` memory |
| Sizes | `.git` 466 M (pack 424 MiB); tracked ~25 MB; working tree 69 G: `output/` 60 G (`v0.4/subregion_cut` 23 G, `v0.4/aws_runs` 17 G, `sampling_sweep` 5.2 G, …, two `_backup_2026-11-16*` 1.4 G), `.synpp_cache` 4.7 G, `interactive/` 1.6 G (node_modules 977 M), `data/` 1.5 G, `infra/aws` 462 M (node_modules 412 M), `.repos` 442 M (3 submodules), `tools/` 377 M |

### Problems, ranked

1. **Cloud-run tooling is not in the shell.** The Fargate path needs node 24 + pnpm
   (Alchemy), AWS CLI v2, Docker (`infra/aws/README.md:79-80`); none are in
   `flake.nix`. They come from the host system profile — invisible dependency,
   breaks on any target that doesn't happen to have them (AWS VM image, peacelily).
   `interactive/` (Vite/Playwright app) also needs node/pnpm. The `Dockerfile`
   runs `npm install -g pnpm` inside the dev shell — there is no `npm` in that shell,
   so the image build as written likely fails (not verified by building).
2. **Credentials: static long-lived keys, agent-readable.** `infra/aws/.env` sets
   `AWS_PROFILE`; that profile exists only in `~/.aws/credentials` as **static keys**
   (no `aws_session_token`; `~/.aws/config` has only `[default] region`). The README
   assumes SSO (`infra/aws/README.md:70-77`). Any agent in any worktree can submit
   16 vCPU/64 GB Fargate tasks with those keys; the only guard is the USD 150 budget
   alarm (`src/Budget.ts`), which alerts, it doesn't stop.
3. **Worktree-hostile paths.**
   - `.envrc` untracked → new worktree has no dev env.
   - `../matsim-paratransit/…` is relative to the checkout; from a worktree under
     e.g. `~/work/worktrees/d_abm/<stream>/` it resolves to nothing.
   - `tools/` jars are untracked manual downloads → missing in worktrees.
   - `output_root: output/v0.4` (`conf/base/globals.yml`) and `data/` are relative:
     a worktree starts with empty `data/` and `output/`, so any pipeline that needs
     upstream outputs (population, subregion_cut, …) must either re-run for hours or
     find a shared copy.
   - `.synpp_cache` (4.7 G) relative to cwd.
4. **Too many nixpkgs, some ancient.** 5 revisions in the lock (2023-06, 2023-07,
   23.05, 2025-07, 2026-03). `nixpkgsMaven` is imported (`flake.nix:64`) and passed
   (`:91`) but never used. The `pkgs-23-05` binding is actually the 2026-03 tree
   (`:60-63`) — misleading names. `pre-commit-hooks` from 2023 pulls a 2023 nixpkgs
   just for `black`/`nixfmt` hooks. Each extra tree is a large download on a fresh
   target over a slow link.
5. **Memory guard is not cgroup-aware.** The MATSim watchdog reads
   `/proc/meminfo` `MemAvailable` (`src/eg_abm/pipelines/subregion_cut/nodes.py:1271-1282`)
   and kills the JVM below `min_available_gb`. Inside `agents.slice` with
   `MemoryMax`, `/proc/meminfo` still reports host memory, so the kernel's cgroup OOM
   killer fires first (on the JVM or, worse, on the agent). Local runs use explicit
   `-Xmx` (`java_memory` 7–8 G in `parameters_full_region.yml:104-120`, 16 G in
   `parameters_paratransit.yml:42`, 8 G in `parameters_layer3_estimation.yml:23`);
   two concurrent 16 G runs exceed any sensible slice on butternut.
6. **Duplicate/stale Python dependency story.** Nix is the real source of truth;
   `pyproject.toml` `[tool.poetry]` + `poetry.lock` + `pkgs.poetry` contradict it.
   An agent following conventions will run `poetry install` and fetch an incompatible
   2023-era environment from PyPI.
7. **Telemetry / network at runtime.** `kedro-telemetry` is installed
   (`flake.nix:127-144`, `:322`) and `pyproject.toml` has `[tool.kedro_telemetry] project_id`;
   with consent stored in `~/.config/kedro/telemetry.toml` it phones home on runs
   unless disabled per env. Set `KEDRO_DISABLE_TELEMETRY=true` / `DO_NOT_TRACK=1` in
   the shell. `bin/sim` uses `python3` for JSON (`infra/aws/bin/sim:84-85`) — fine,
   it is in the shell.
8. **Agent essentials missing.** No `git`, `gh`, `jq` (runner tests need it:
   `infra/aws/README.md:50`), `ripgrep`, `fd`, `pyright`/`basedpyright` or
   `python-lsp-server`, `jdt-language-server`, `zstd` (used for routed plans),
   `awscli2`, `docker-client`, `nodejs_24`, `pnpm`. `pytest` is present.
9. **Minor.** `shellHook` comment about Python 3.14 while using 3.13
   (`flake.nix:284-285`); pre-commit uses `nixfmt` while the flake is
   alejandra-formatted; darwin systems listed; `.ipynb_checkpoints`, a 5 MB paper
   PDF and `pipeline_flow.*` at root.

### How runs work today (local vs cloud)

- **Local loop:** Kedro pipelines in the dev shell, `run_scenarios.sh`
  (`kedro run --pipeline=… --env=…`, `run_scenarios.sh:32-55`); Java is spawned as a
  subprocess with `-Xmx{java_memory}` and the MemAvailable watchdog; outputs under
  `output/v0.4/…`.
- **Cloud loop** (`infra/aws/README.md:118-142`): `bin/sim stage <scenario> <rate>`
  (Kedro `sim_stage` → `output/v0.4/aws_runs/<run-id>/{run/,manifest.json}`, run ids
  are immutable and content-hashed) → `bin/sim submit <id>` (content-addressed blob
  upload to `s3://tfc-cairo-sim-<stage>/inputs/blobs/<sha256>`, jar to
  `jars/<sha256>.jar`, `aws ecs run-task`; refuses dirty manifests) →
  `wait|status|progress|logs -f|list|cancel` → `fetch [--summary|--for-bundle]` →
  `bundle [--cloud]`. Runner heartbeats `status.json` every 60 s and uploads
  `result.json` on every exit; exit codes are MATSim's (124 timeout, 143 SIGTERM).
- **Agent suitability:** already excellent for non-interactive use: every step is a
  CLI with exit codes, `--dry-run`, `--json` (progress), immutable ids, idempotent
  uploads. Missing pieces: (a) credentials that don't require a human and are scoped,
  (b) a `bin/sim submit --no-wait` + `bin/sim wait --timeout` contract documented for
  agents, (c) a notification hook (ntfy) on completion instead of an agent polling
  for hours inside the slice, (d) a hard cost cap per stream.
- **Old path:** `ci/run-pipeline.sh` (static `AWS_ACCESS_KEY_ID` + `S3_BUCKET`,
  `tfc-abm-artifacts`) and the `Dockerfile` predate `infra/aws`; treat as legacy.

### Proposed patch plan

**P1 — one nixpkgs, everything pinned.**

```nix
{
  description = "Egypt Transportation Agent-based Model";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";   # or keep b40629ef until the bump is tested
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    # only if a package really needs an older tree, and name it for what it is:
    # nixpkgs-maven-2025.url = "github:NixOS/nixpkgs/aefcb0d5…";
  };
  nixConfig = { };   # deliberately empty
  outputs = { self, nixpkgs, git-hooks, ... }: let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    …
```

Drop `nixpkgs-unstable` (duplicate), `nixpkgsMaven` (unused), the `pkgs-23-05`
misnomer; take `maven`, `gdal`, `osmium-tool`, `yamlfmt` from the one tree. Expected
lock: ~3 nodes instead of 11.

**P2 — pin the Java side in Nix.**

```nix
matsimJar = pkgs.fetchurl {        # MATSim 2026.0 release zip; hash from tools/matsim-2026.0-release.zip
  url = "https://…/matsim-2026.0-release.zip"; hash = "sha256-…";
};
pt2matsimJar = pkgs.fetchurl { url = "…/pt2matsim-26.4-shaded.jar"; hash = "sha256-…"; };
```

Export `D_ABM_MATSIM_JAR`, `D_ABM_PT2MATSIM_JAR` from the shell and change
`conf/base/parameters.yml:41-42` to `${oc.env:D_ABM_MATSIM_JAR}` (OmegaConf resolver).
For matsim-paratransit: add it as a flake input
(`inputs.matsim-paratransit.url = "git+ssh://…/matsim-paratransit"`, `flake = true`;
it already has a `flake.nix`) and build the shaded jar with `maven.buildMavenPackage`
— or, short-term, export `D_ABM_PARATRANSIT_JAR=$HOME/work/tfc/repos/matsim-paratransit/target/…`
from a machine-local `.envrc.local` so the path doesn't depend on the worktree's
location. Set `JAVA_HOME = pkgs.jdk25` explicitly and `java_binary` to
`${oc.env:JAVA_HOME}/bin/java`.

**P3 — devShell additions.**

```nix
packages = [ python sumo graphviz typst gdal osmium-tool yamlfmt ruff black ]
  ++ (with pkgs; [
    jdk25 maven jdt-language-server
    git gh jq ripgrep fd zstd just
    basedpyright                  # or pyright
    awscli2 docker-client         # bin/sim, image-push
    nodejs_24 pnpm                # infra/aws (alchemy), interactive/
  ]);
env = {
  KEDRO_DISABLE_TELEMETRY = "true";
  DO_NOT_TRACK = "1";
  JAVA_HOME = "${pkgs.jdk25.home}";
};
# REMOVE pkgs.poetry; delete [tool.poetry] from pyproject.toml and poetry.lock
```

Optionally a `devShells.cloud` (aws, docker, node, pnpm, jq only) for a lightweight
AWS-VM target that only dispatches and monitors runs.

**P4 — `.envrc`, tracked** (remove `.envrc` from `.gitignore:6`):

```bash
watch_file flake.nix flake.lock
use flake .
# machine-local paths (data root, paratransit jar, AWS profile): never committed
source_env_if_exists .envrc.local
```

`.envrc.local` (git-ignored) per machine:
`export D_ABM_DATA_ROOT=$HOME/data/d_abm` etc.

**P5 — memory model for agents.**
- Make the watchdog read the cgroup: `min(MemAvailable, memory.max - memory.current)`
  from `/sys/fs/cgroup/$(cut -d: -f3 /proc/self/cgroup)/memory.{max,current}`.
- Derive the default `-Xmx` from the cgroup limit (e.g. 70 % of `memory.max` when
  it isn't `max`), matching how the runner uses 80 % on Fargate
  (`infra/aws/README.md:128`), and refuse to start a local run larger than the slice.
- Use a machine-wide `flock ~/.cache/d_abm/matsim.lock` so two streams don't start
  two 16 G JVMs on butternut; heavy runs go to peacelily or Fargate via `target heavy`.

**P6 — credentials.**
- Replace the static keys with IAM Identity Center (SSO) profiles as the README
  intends: an **operator** profile (only the `cairo-sim-<stage>-operator` policy —
  RunTask/StopTask/Describe on that cluster, the run bucket, logs, ECR push, SSM read)
  for agents, and a separate admin profile only humans use for `alchemy deploy`.
  SSO sessions expire (8–12 h), which is a feature for agents; refresh from hazel.
- For unattended AWS-VM targets use an instance role with the operator policy, not
  keys. Keep keys out of worktrees: `AWS_PROFILE` in `.envrc.local`, not
  `infra/aws/.env` copied around.
- Add a hard per-run cap in `bin/sim submit` (`CAIRO_SIM_MAX_USD_PER_RUN`, refuse when
  `--cpu × --memory × MAX_RUNTIME` exceeds it) — the budget only alerts.

**P7 — AGENTS.md for d_abm** (new; `CLAUDE.md` → symlink). Outline:

```markdown
# AGENTS.md — d_abm (Egypt transport ABM: Kedro + MATSim)
## Environment
- Enter with direnv (`use flake`). Never `pip install`/`poetry install`; Python deps live in flake.nix.
- Java: jdk25 from the shell. Jars: $D_ABM_MATSIM_JAR, $D_ABM_PT2MATSIM_JAR, $D_ABM_PARATRANSIT_JAR.
## Data
- data/ and output/ are symlinks to the machine's shared data root; treat output/v0.4/** produced by
  others as read-only. Write new outputs only under output/v0.4/<your-stream>/ or via a new --env.
## Running
- Tests: `pytest tests/`; infra: `cd infra/aws && pnpm test` (fake aws, offline).
- Local MATSim only for smoke runs (lastIteration 0–2, java_memory ≤ 8G). Anything larger: AWS.
- AWS: `infra/aws/bin/sim stage …` → `submit <id> --label <stream>` → `status`/`progress`;
  don't `wait` in the foreground for hours — submit, record the run id in the PR/plan, end the turn.
  Never pass `--force`, `--allow-dirty` or `--spot` without being asked. Never `alchemy deploy`.
- Paper: `./run_scenarios.sh paper`.
## Conventions
- Kedro pipelines under src/eg_abm/pipelines/<name>/, params in conf/base/parameters_<name>.yml.
- Commit often; plans in docs/plans/YYYY-MM-DD-*.md.
```

**P8 — hygiene.** Remove the stale `Dockerfile`/`ci/run-pipeline.sh` or mark them
legacy; move `1-s2.0-…pdf`, `pipeline_flow.*`, `.ipynb_checkpoints` out of the root;
delete `output/v0.4/_backup_2026-11-16*` once confirmed.

### Worktree sharing scheme

| Thing | Size | Per-worktree or shared | How |
|---|---|---|---|
| tracked source | ~25 MB | per worktree | `git worktree add` |
| `data/` | 1.5 G | shared, read-only | symlink `data` → `$D_ABM_DATA_ROOT/data` |
| `output/` | 60 G | shared | symlink `output` → `$D_ABM_DATA_ROOT/output`; streams write to their own sub-env (`conf/<stream>/globals.yml` with `output_root: output/v0.4-<stream>` when they change upstream nodes) |
| `output/v0.4/aws_runs` | 17 G | shared | content-addressed run ids already make concurrent use safe |
| `.synpp_cache` | 4.7 G | shared | symlink, or set synpp working dir via env |
| `tools/` jars | 377 M | Nix store | P2 |
| `interactive/node_modules`, `infra/aws/node_modules` | 1.4 G | per worktree (pnpm hard links) | only when the stream touches them |
| `.repos` submodules | 442 M | shared, read-only | symlink |
| `infra/aws/.env` | tiny | shared | symlink from main checkout (or replace with `.envrc.local`) |

Remote targets (peacelily, AWS VM) don't get `data/`/`output/` over the Egyptian
uplink: they fetch inputs from S3 (`bin/sim` already content-addresses inputs;
extend the same idea with a `bin/data pull <dataset>` from the run bucket) and only
stage/submit there.

### `t3.json` sketch (verify schema against T3 Code docs)

```json
{
  "worktree": {
    "setup": [
      "for d in data output .synpp_cache .repos; do ln -sfn \"$T3_MAIN_CHECKOUT/$d\" \"$d\"; done",
      "[ -e \"$T3_MAIN_CHECKOUT/.envrc.local\" ] && ln -sfn \"$T3_MAIN_CHECKOUT/.envrc.local\" .envrc.local",
      "[ -e \"$T3_MAIN_CHECKOUT/infra/aws/.env\" ] && ln -sfn \"$T3_MAIN_CHECKOUT/infra/aws/.env\" infra/aws/.env",
      "direnv allow .",
      "direnv exec . pytest -q tests --co >/dev/null"
    ]
  }
}
```

`.agents/targets.toml`: `default = "heavy"`, `matsim-local = "heavy"` (peacelily
first), `matsim-full = "cloud"`.

### Risks

- Collapsing to one nixpkgs changes Python package versions (geopandas, polars,
  jax/pymc for biogeme — the flake already disables several test suites to make them
  build, `flake.nix:223-232`). Bump on a branch, run `pytest` and one smoke MATSim run.
- `fetchurl` for MATSim jars needs stable URLs (MATSim releases on GitHub/Maven are
  fine; pt2matsim shaded jar may need to be built with `buildMavenPackage`).
- Shared `output/` means one agent's bad run can overwrite another's inputs: enforce
  per-stream `output_root` in AGENTS.md and keep `output/v0.4` read-only for agents
  (bind mount or permissions).
- SSO migration may break existing CI that uses static keys (`ci/run-pipeline.sh`).

---

## 3. Cross-cutting recommendations

1. **No host leakage.** Every tool an agent needs is in the project shell; the host
   provides only nix, direnv/nix-direnv, git-credential plumbing and the agent CLIs.
   Consider dropping `aws`, `node`, `pnpm`, `docker` CLI, `kubectl`, `kind` from the
   global system profile on agent hosts once both shells carry them — then any
   missing dependency fails loudly instead of silently using a host version.
2. **Agent CLIs never in project shells.** They come from nixconf
   (llm-agents.nix / unstable) so they update without touching project locks.
3. **Registries can't leak into these flakes** (no indirect inputs in either lock),
   but `nix shell nixpkgs#…`/`nix run nixpkgs#…` typed by agents **does** use the
   host registry. Pin the registry on agent hosts to the system nixpkgs
   (`nix.registry.nixpkgs.flake = inputs.nixpkgs`, `nix.channel.enable = false`,
   `nix.settings.flake-registry = ""`) and add to both AGENTS.md: "use
   `nix shell --inputs-from . nixpkgs#…`, never bare `nixpkgs#…` or `<nixpkgs>`".
4. **Keep `accept-flake-config = false`.** Neither project has `nixConfig`; if one is
   added later (e.g. devenv's cachix), add the substituter to nixconf
   `nix.settings.trusted-substituters` instead — `accept-flake-config = true` lets
   any flake in a worktree an agent checks out add substituters/keys.
5. **Share the nixpkgs revision with nixconf** where practical (`nixos-26.05`): most
   of the closure is then already on every target, which matters more than freshness
   over a slow link.
6. **GC roots for heavy shells.** nix-direnv roots each worktree's shell under
   `.direnv/`; many worktrees = many roots of the same env (cheap). Removing a worktree
   must remove its `.direnv` too, or `nix-collect-garbage` keeps stale envs forever.
7. **Registration per tool.** Both repos need: `AGENTS.md` (+ `CLAUDE.md` symlink),
   tracked `.envrc`, `t3.json`, `.agents/targets.toml`, optional `.mcp.json` (pinned),
   and a `.claude/settings.json` with project permissions (allow `pnpm test`,
   `pytest`, `bin/sim status|progress|list`, deny `bin/sim submit --force`,
   `alchemy deploy`, `rl-dev-db-clean`). OpenCode reads `AGENTS.md` natively.
