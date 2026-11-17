# Repo size audit and parallel-work strategy (2026-11-17)

Read-only audit of `routelab-monorepo` (~35 GB) and `d_abm` (~69 GB) on butternut
(ext4 `/`, 1.8 TB, 85 % used, 268 GB free). Nothing was modified. Measured with `du`,
`git count-objects`, `git rev-list --disk-usage`, `git ls-tree -l`, `find -links`,
`b2sum` (only to find duplicates) and `docker system df -v`.

Related: `2026-11-17-t3code-integration.md` (§5 worktrees, `t3.json`),
`2026-11-17-work-projects-review.md` (worktree sharing scheme).

**Main finding:** git is small in both repos. The disk goes to build output,
emulator images, logs and simulation output. A new worktree costs very little for
d_abm. For routelab it costs about 1 GB if it shares state with the main checkout,
and much more if it doesn't. At least 25–30 GB can be freed without losing any
data.

---

## 1. routelab-monorepo

### 1.1 Breakdown (35 GB)

| Path | Size | What it is |
|---|---|---|
| `apps/observer` | **11 G** | `node_modules` 4.1 G, `android/` 3.0 G (`app/build` 2.3 G, `.gradle` 462 M, `app/.cxx` 267 M), **`.android/avd` 2.5 G (a duplicate AVD)**, `builds/` 973 M (6 APKs) |
| `.android/avd` | **7.0 G** | `routelab-e2e.avd` 4.4 G (a 4.3 G qcow2 overlay), `routelab-app-emulator.avd` 2.6 G (April) |
| `.repos` (submodules) | **4.5 G** | `jazz` 2.94 G (**`node_modules` 1.9 G + Rust `target/` 0.93 G**), `hive-gateway` 0.63 G (**untracked clone, not a submodule**), `react-native-navigation` 0.27 G, `constructive` 0.28 G, others small |
| `infra` | 3.3 G | `stack/.alchemy/log` **2.1 G**, `analytics/.alchemy/log` **0.46 G**, two `node_modules` 0.46 G each, `.alchemy/bundles` + `dev` 0.27 G, `state/` 320 K (**keep**) |
| `apps/dashboard` | 2.0 G | `node_modules` 1.6 G, `.output` + `dist` + `dist-open` + `.tanstack` 0.32 G |
| `.turbo/cache` | 1.3 G | 5,126 entries, 0.51 G older than 30 days |
| `.local` | 1.2 G | `osrm/tunisia-261031` 904 M, `schematic-eval` 154 M, `prod-data` 102 M |
| `.git` | 1.1 G | `objects` 242 M (4 packs, 237 MiB), `modules` 873 M (21 submodule gitdirs) |
| `packages` | 908 M | mostly `node_modules` |
| other apps | ~1.9 G | gql-api 529 M, landing-page 425 M, guide 359 M (`.dashboard-build` 117 M), … |
| `.devenv/state` | 528 M | `prek` (pre-commit hook environments) |
| `node_modules` (root) | 205 M | |
| loose root files | ~24 M | `MBTA_GTFS.zip` 22 M, two Mishwar HTML files 1.7 M, `claude-sessions.log` 180 K, `browser.log`, `claude.log`, `events_2026-1{0,1}-*.log` (~14 K) |

**Tracked tree:** 6,451 files, **236 MB** at HEAD. The onboarding worktree
`.agentic-onboarding/routelab-monorepo` measures 243 MB. The largest tracked blobs are
test `.gpkg` files (43 + 15 + 13 MB) and deck PDFs (13.5 + 5.6 MB).

**node_modules in total:** 78 directories, 9.2 G counted once each. Only **3.66 G** of
that has link count 1, so it belongs to the repo alone. The other ~5.5 G is hard links
into the pnpm store (`~/.local/share/pnpm/store`, 20 G), so deleting `node_modules`
frees only ~3.7 G. Of the repo-only part, **3.17 G is in `apps/observer`**: Gradle
`android/build` (2.26 G) and `.cxx` (1.02 G) intermediates that React Native native
libraries write *inside* `node_modules/.pnpm/*`. The real repo-exclusive footprint is
therefore ~29.5 G, not 35 G.

**Likely accidental files at the root.** All are zero bytes and untracked, probably
redirections from mistyped commands (for example `> :5432` from a `psql`/`pg_isready`
line, or flags that the shell took for file names):
`:5432` (Nov 16), `--desired-status` (Nov 12), `--query` (Nov 12), `--record-type`
(Nov 11), `.grafana.net` (Nov 11), and the empty `observer-validate.log` (Oct 16).
Agent transcripts in `~/.claude/projects/-home-hfahmi-work-tfc-repos-routelab-monorepo/`
mention `--desired-status`/`--record-type`, so agent shell commands probably created
them. Add a line to AGENTS.md: "quote URLs and flags, never redirect to an argument".

### 1.2 Submodules (`.repos/`)

`.gitmodules` lists 26 gitlinks. On disk there are 27 directories, because
`hive-gateway` is an untracked plain clone (`?? .repos/hive-gateway/` in `git status`).
`.git/config` still has entries for 7 removed submodules (`effect-v3`,
`eslint-plugin-boundaries`, `penpot-mcp`, `react-native-coachmark`, `.agents/effect-atom`,
`.agents/effect-machine`, `repos/tfc-plugins`). They take no disk space, but they are
config clutter. Three gitlinks are not initialised in `.git/config` (`-` in
`git submodule status`), but their directories exist with their **own embedded
`.git`**: `custom-expo-updates-server`, `serverless-expo-ota-server`, `tfc_qgis_plugins`.
`frond` and `react-native-navigation` also have embedded `.git` directories instead of
`.git/modules`.

| Submodule | Checkout | Gitdir | Commits | Shallow | Note |
|---|---:|---:|---:|---|---|
| jazz | **2940 M** | 101 M | 4783 | no | 2.85 G of the checkout is build output (`node_modules`, `target/`) |
| hive-gateway | 340 M | 285 M | 1 | yes | **untracked**, not registered |
| react-native-navigation | 51 M | **215 M** | 5745 | no | embedded `.git` |
| effect-v4 | 59 M | **159 M** | 587 | yes, but fetched deeper | |
| constructive | 145 M | **137 M** | 7817 | no | |
| alchemy | 182 M | 48 M | 1 | yes | |
| loom | 70 M | 76 M | 966 | no | |
| crystal | 72 M | 11 M | 1 | yes | |
| pg_trickle | 36 M | 59 M | 1171 | no | |
| a5geo | 54 M | 36 M | 1 | yes | |
| omt-router | 7 M | 44 M | 69 | no | |
| tfc_qgis_plugins | 36 M | 12 M | 1 | yes | not initialised in config |
| xlsform-editor | 13 M | 26 M | 142 | no | |
| custom-expo-updates-server | 5 M | 13 M | 73 | no | embedded `.git`, not initialised |
| hypercore | 3 M | 9 M | 2041 | no | |
| yielded-auth | 9 M | 7 M | 174 | no | |
| effect-qb | 11 M | 5 M | 1175 | no | |
| bye | 14 M | 5 M | 21 | no | |
| apollo-client, urql, typed, effect-form, effect-graphql, code-mix-graph, frond, protomux, serverless-expo-ota-server | ≤21 M each | ≤4 M each | 1–374 | mixed | |

Shallow: 11 of 27. **Full-history gitdirs total ~0.7 G.** At depth 1 they would be
~0.25 G, which saves **~0.45 G**. Taking `effect-v4` back to depth 1 saves another ~0.1 G.
The large item in `.repos` is not history: it is **jazz's build output (2.85 G)**, plus
the unregistered `hive-gateway` (0.63 G).

### 1.3 Git object store

237 MiB packed. Reachable objects are 194 MiB, or 216 MiB with reflogs. There are 30
stashes and 151 refs. `git gc` / `git maintenance run --task=gc` would save
**~20–40 MB**, which isn't worth worrying about. `--aggressive` gains little on a repo
this size.

### 1.4 Docker (from read-only `docker system df -v`)

Docker as a whole: images 33.4 GB (25.9 GB reclaimable), volumes 24.8 GB (21.8 GB
reclaimable), build cache 5.8 GB. Routelab's share:
- **Images:** 29 images named routelab, ~2.7 GB of unique layers. Several are 11–20
  months old: the `routelab-*-graphql` set, `routelab-monorepo-{legacy-db,reporting,operational}-graphql`,
  `observer-write-api` 1.56 GB, eight `projectors-drain` tags.
- **Volumes:** `routelab-monorepo_postgres-volume-data-auth` 2.5 GB (in use, **keep**).
  `kurrentdb-volume-{data,logs}` 1.1 GB (unused). `postgres-volume-data-projections`
  150 MB. `floci-data` 366 MB (in use). Six `floci-code-*` volumes 285 MB. Old `routelab_*`
  volumes from before the project was renamed are 0 B.
- **168 unused anonymous volumes, 19.9 GB.** Some belong to other projects, but the
  541.5 MB repeats look like Postgres init volumes from repeated `compose up`.

### 1.5 User-level caches shared by both repos

| Cache | Size | Cleanup |
|---|---:|---|
| pnpm store `~/.local/share/pnpm/store` | 20 G | `pnpm store prune` (removes unreferenced packages) |
| `~/.gradle` | 8.1 G | delete `~/.gradle/caches/<old-version>` and `~/.gradle/wrapper/dists/<old>` |
| `~/.npm` | 7.4 G | `npm cache clean --force` (pnpm doesn't use it) |
| `~/.cache/pnpm` | 3.7 G | metadata cache, safe to delete |
| `~/.m2` | 985 M | MATSim/Maven, keep |

---

## 2. d_abm

### 2.1 Breakdown (69 GB)

| Path | Size | What it is |
|---|---|---|
| `output/v0.4` | **58 G** | see 2.2 |
| `output/scenarios` | 1.5 G | `matsim_remediated` |
| `.synpp_cache` | **4.7 G** | 143 entries, **all from 2025-08/09**. The synpp stages were ported to Kedro (`src/eg_abm/pipelines/matsim/nodes.py`: "Ported from synpp stages"). `synpp` is still a Poetry dependency, but nothing reads this cache directory |
| `interactive` | 1.5 G | `node_modules` 977 M, `public` 310 M, `test-results` 173 M, `dist` 118 M |
| `data` | 1.5 G | lfs 408 M, tawwaly 320 M, capmas 277 M, osm 155 M, counts 153 M, … (input data, **keep**) |
| `.git` | 467 M | **427 MB cruft pack of unreachable objects** (has `.mtimes`). Reachable objects are only **19 MiB** |
| `infra/aws` | 462 M | `node_modules` 460 M |
| `.repos` | 442 M | `scrape-cedej` 407 M, mostly *untracked/ignored* content (`firefoxvm-default.qcow2` 223 M, ignored `src/` 184 M); `effect-smol` 32 M checkout + 34 M gitdir (full, 2107 commits); `kedro-mlflow` 2.4 M |
| `tools` | 377 M | `matsim-2026.0/` 125 M **and** `matsim-2026.0-release.zip` 108 M, `osmosis-0.49.2/` and its `.zip` (14 M, tracked), `osmosis-0.48.3.zip`, `pt2matsim-26.4-shaded.jar` 85 M |

Tracked tree: **984 files, 23.5 MB** (largest: `tools/osmosis-0.49.2.zip` 14 MB). The
onboarding worktree measures 26 MB. Python comes from the flake (`use flake .`). The
Poetry venv is 6.7 M.

### 2.2 `output/v0.4` (58 G, 43 entries)

| Dir | Size | Age | Note |
|---|---:|---|---|
| `subregion_cut/central` | 23 G | Nov 12–16 | `r010/{stuck_exp,injection_exp}`: many experiment variants, each with `ITERS/` |
| `aws_runs` | 17 G | Nov 12–16 | 30 runs plus `_jars/_routed/_staged/_staging`. **Also stored in S3** (`bin/sim fetch`). Same config hash rerun 2–4× (e.g. `…-49af15f0`, `…-9625e873`, `…-9e93bbc3`) |
| `sampling_sweep` | 5.2 G | **Jul 13** | 141 runs of ~121 M each, plus `ref` |
| `matsim_runs` | 2.9 G | **May 25** | 2 hashed runs |
| `run_bundle` | 2.5 G | Nov 15–16 | includes `_staging` 634 M and `_work` 483 M |
| `sumo`, `matsim` | 1.4 G each | | |
| `paratransit_corridor_runs` | 1.1 G | | |
| `_backup_2026-11-16`, `_backup_2026-11-16b` | 0.9 + 0.5 G | Nov 16 | |
| `pt_sweep`, `layer3_supply_check_runs`, `full_region`, … | ~3 G | | |

By type, files over 100 MB: `.zst` 30 GB, `.parquet` 2.7 GB, `.gz` 1.5 GB, uncompressed
`.xml` 1.4 GB (one file). MATSim `ITERS/**/events*` = 11.9 GB in 46 files.
`output_events*` = 18.2 GB in 54 files.

**Byte-identical duplicates (confirmed with b2sum over all files > 20 MB in `output`,
`.synpp_cache` and `data`): 13.1 GB in 75 groups.** Mostly MATSim writing the last
iteration's `ITERS/it.N/N.events.xml.zst` *and* `output_events.xml.zst`, plus
`stuck_exp/*/ITERS/it.0/0.plans.xml.zst`, which is identical in 9 variants
(0.73 GB × 8 extra copies). Only 1.0 GB in `output` is hard-linked today.

---

## 3. Waste candidates, ranked

Risk levels: **[safe]** = regenerable or exact duplicate, no data loss. **[low]** = costs
a rebuild or re-download. **[med]** = loses results that are hard to regenerate unless
archived first. **[high]** = don't do without thinking. Every command below is for
*you* to run. Run any dry-run form first.

### routelab

| # | GB | Item | Risk | Command |
|---|---:|---|---|---|
| R1 | **2.85** | jazz reference clone build output | safe | `git -C .repos/jazz clean -ndX` (dry run), then `git -C .repos/jazz clean -fdX` |
| R2 | **2.6** | Alchemy logs | safe | `rm -rf infra/stack/.alchemy/log infra/analytics/.alchemy/log` (**never** `.alchemy/state`) |
| R3 | **2.5** | duplicate AVD `apps/observer/.android` (created when the devenv shell was entered from `apps/observer`; Aug 31) | low | check `emulator -list-avds` from the root shell, then `rm -rf apps/observer/.android` |
| R4 | **~6.3** | Android build intermediates: `apps/observer/android/app/build` 2.3, `.cxx` 0.27, `android/.gradle` 0.46, `node_modules/.pnpm/*/android/{build,.cxx}` 3.3 | low (next APK build is a full rebuild) | `rm -rf apps/observer/android/app/build apps/observer/android/app/.cxx apps/observer/android/.gradle`; `find apps/observer/node_modules/.pnpm -path '*/android/build' -prune -o -path '*/android/.cxx' -prune -type d -print` (to review), then delete the same paths with `-exec rm -rf {} +` |
| R5 | 4.3 | `routelab-e2e` AVD userdata overlay (qcow2 snapshot state) | low (e2e AVD state is wiped) | `emulator -avd routelab-e2e -wipe-data` once, or delete and recreate with the repo's `create-avd` |
| R6 | 0.63 | `hive-gateway` untracked clone | low | register it shallow (`git submodule add --depth 1 …`) or move it to the shared reference directory (§3.1) |
| R7 | ~0.55 | old APKs (keep `latest` per channel) | low | in `apps/observer/builds/serverless`, delete the 3 APKs that aren't `latest.apk` (0.55 G) |
| R8 | 0.5–1.3 | turbo cache | safe | `find .turbo/cache -mtime +14 -delete`, or move to `TURBO_CACHE_DIR=$HOME/.cache/routelab/turbo` (shared by all worktrees) |
| R9 | 0.53 | `.devenv/state/prek` | safe | `rm -rf .devenv/state/prek` (rebuilt on the next hook run) |
| R10 | ~0.55 | submodule full history (constructive, jazz, loom, pg_trickle, omt-router, rnn, xlsform, effect-v4 deepened, …) | low (needs network) | per submodule: `git submodule deinit -f .repos/X && rm -rf .git/modules/.repos/X && git submodule update --init --depth 1 .repos/X`; set `git config -f .gitmodules submodule..repos/X.shallow true` so it stays shallow. Embedded-`.git` ones (rnn, custom-expo, serverless, frond): `git submodule absorbgitdirs` first. Clean up stale `.git/config` sections with `git config --remove-section submodule.<old>` |
| R11 | 0.3 | dashboard/guide build output (`.output`, `dist*`, `.dashboard-build`, `.tanstack`) | safe | `pnpm -r exec rm -rf dist .output` or `git clean -ndX apps/dashboard apps/guide` and review |
| R12 | 0.03 | git gc | safe | `git maintenance run --task=gc` |
| R13 | 0 | junk root files | safe | `rm -- ':5432' --desired-status --query --record-type .grafana.net observer-validate.log` (note the `--`) |
| D1 | ~2.7 + 1.1 | old routelab images; unused kurrentdb volumes | low | `docker image ls | grep routelab`, then `docker rmi <id>…` for tags you don't need; `docker volume rm routelab-monorepo_kurrentdb-volume-{data,logs}` |
| D2 | up to 19.9 | 168 dangling anonymous volumes (all projects) | med (check that none hold data you want) | `docker volume ls -qf dangling=true` to review, then `docker volume prune` (anonymous volumes only) |
| D3 | up to 25.9 | unused images, all projects | low | `docker image prune -a --filter until=720h` |
| U1 | 7.4 + 3.7 | `~/.npm`, `~/.cache/pnpm` | safe | `npm cache clean --force; rm -rf ~/.cache/pnpm` |
| U2 | ? (several) | pnpm store | safe (re-downloads on demand) | `pnpm store prune` |
| U3 | ? | old Gradle distributions/caches | low | `ls ~/.gradle/caches ~/.gradle/wrapper/dists` and delete old versions |

**routelab total without touching data: ~20 GB in-repo** (R1–R11) **+ ~4 GB Docker
(D1) + ~11 GB user caches (U1)**.

### d_abm

| # | GB | Item | Risk | Command |
|---|---:|---|---|---|
| A1 | **13.1** | byte-identical duplicates in `output/` | safe (hard links, same bytes) | `nix shell nixpkgs#rdfind -c rdfind -dryrun true -makehardlinks true -minsize 20000000 output` and then without `-dryrun`. Alternative: `nix shell nixpkgs#jdupes -c jdupes -r -L output`. Caveat: a tool that edits a file *in place* would change every copy. MATSim/Kedro write new files, so this is fine |
| A2 | **4.7** | `.synpp_cache` (14 months old, pipeline now Kedro) | med (recomputing synpp stages takes hours; archive first) | `tar -I 'zstd -19 -T0' -cf ~/archive/d_abm-synpp_cache-2025.tar.zst .synpp_cache && aws s3 cp …`, then `rm -rf .synpp_cache` |
| A3 | up to **17** | `aws_runs` (in S3) | med (re-download over Egyptian bandwidth) | keep the runs you are comparing against; `rm -rf` superseded reruns of the same config hash and the `_staged`/`_staging` scratch; `bin/sim fetch <run>` when needed |
| A4 | 5.2 + 2.9 | `sampling_sweep` (Jul), `matsim_runs` (May) | med | archive to S3 (`aws s3 sync output/v0.4/sampling_sweep s3://…/archive/…`), then delete locally |
| A5 | 1.4 | `_backup_2026-11-16{,b}` | med | delete once the Nov 16 migration they protect has been checked |
| A6 | 1.1 | `run_bundle/_staging` + `_work` | low | scratch areas, delete when no run is active |
| A7 | **0.41** | git cruft pack (unreachable objects) | safe | `git gc --prune=now` (the next ordinary gc after `gc.pruneExpire` does the same thing) |
| A8 | 0.29 | `interactive/test-results`, `interactive/dist` | safe | `rm -rf interactive/test-results interactive/dist` |
| A9 | 0.23 | `tools/*.zip` next to their extracted directories (untracked ones) | safe | `rm tools/matsim-2026.0-release.zip tools/osmosis-0.48.3.zip` |
| A10 | 0.22 | `scrape-cedej/firefoxvm-default.qcow2` | low | delete if that VM isn't needed |

**d_abm total: ~13.5 GB with zero risk (A1, A7, A8, A9)**, plus **10–30 GB** after
archiving (A2–A6).

### 3.1 Reference repos: shallow submodules vs a shared reference directory

| | (i) keep submodules, make them shallow | (ii) drop submodules, use a shared reference directory |
|---|---|---|
| Disk | ~3.4 G checkouts + ~0.25 G gitdirs, **per checkout that initialises them** | one copy per host for all repos and worktrees (e.g. `~/.local/share/reference-repos/<name>`). Some can be shared across projects: d_abm's `effect-smol` was the Effect v4 development repo, routelab has `effect-v4`; check whether one would do |
| Pinning | SHA recorded in routelab history (reproducible) | manifest file (`.agents/reference-repos.txt`: `name url ref`) and a small sync script (`git clone --depth 1 --filter=blob:none`, `git fetch --depth 1 origin <ref> && git checkout FETCH_HEAD`) |
| Noise | every bump is a commit; `git status`/`submodule status` show `+`/`-` drift; T3 `worktreeSubmodules` must be `none`; ripgrep/IDE indexing walks 4.5 G unless excluded | `.repos` becomes a gitignored **symlink** → the shared directory. Agents read `.repos/<name>` exactly as now. Worktrees get the same symlink from the setup script (already planned) |
| Mistakes to avoid | someone running `pnpm install` / `cargo build` inside a reference repo (as happened in jazz, 2.85 G) | same risk. Make the shared directory read-only (`chmod -R a-w`) after the sync script runs |
| Cost to move | R10 commands | `git rm --cached .repos/*` + remove `.gitmodules` entries, one commit; move directories (`mv` on the same filesystem, so instant); add the symlink and gitignore it |

**Recommendation:** (ii). The repos are documentation for agents, not dependencies.
A symlinked shared directory removes the per-worktree question entirely, keeps
`git status` quiet, and works for d_abm's 3 submodules in the same way. Keep (i) only
if teammates who clone routelab also need the reference code, because the manifest
plus script still gives them that.

---

## 4. Cost of one new worktree

Git objects are shared through the main `.git`, so the costs below are working-tree
and install costs only.

### routelab

| Part | Light (TS/web stream) | Android stream | Unmanaged worst case |
|---|---:|---:|---:|
| tracked files | 0.24 G | 0.24 G | 0.24 G |
| submodules | 0 (`worktreeSubmodules: none` + `.repos` symlink) | 0 | **~1.6 G** with `recursive` (submodule gitdirs are cloned again under `.git/worktrees/<wt>/modules` **over the network**, plus ~0.75 G of clean checkouts); ~1.0 G at depth 1 |
| `node_modules` (pnpm hard links from the store) | **~0.7–1.0 G** for a full install (≈163 k directories × 4 KiB, plus per-project caches); ~0.1–0.3 G with `pnpm install --filter <app>...` | ~1 G + **3.3 G** native builds inside `node_modules` | same |
| `.devenv` | 0.53 G (prek) unless the prek cache is pointed at a shared directory | 0.53 G | 0.53 G |
| `.direnv` / nix shell | ~0 (store paths shared, a GC root per worktree) | ~0 | ~0 |
| turbo | 0 with a shared `TURBO_CACHE_DIR` | 0 | up to 1.3 G |
| Gradle project + `app/build` | 0 | **~3 G** (`~/.gradle` 8.1 G is shared) | 3 G |
| AVD | 0 | 0 if `ANDROID_AVD_HOME` points to a shared path | **2.5–7 G** (devenv sets `ANDROID_AVD_HOME=$PWD/.android/avd`) |
| `.local` / `.tiles` / … | 0 (symlinked) | 0 | 1.2 G |
| **Total** | **≈1.0–1.8 G** | **≈8 G** | **≈15+ G** |

With 4–5 concurrent light worktrees that is ~5–8 GB. That's affordable once R1–R4 free
~14 GB. A routelab worktree is expensive only when it builds Android or when the
sharing in the setup script is missing. Creation time is set by `pnpm install --offline`
(hard-linking ~1.2 M files) plus nix-direnv evaluation (`devenv-root` from `$PWD` makes
each worktree a distinct derivation; see the work-projects review, P4).

### d_abm

| Part | Size |
|---|---:|
| tracked files | **0.026 G** |
| submodules (`recursive`) | ~0.08 G + network; 0 with `none` |
| `interactive` / `infra/aws` `node_modules` (only if that stream needs them) | ~0.1–0.2 G each (hard links) |
| Python / Java env | ~0 (flake, shared store; `~/.m2` shared) |
| `data`, `output`, `.synpp_cache`, `tools` jars | **0 only if symlinked.** Copying them would cost 66 G and is not acceptable |
| per-worktree outputs | whatever the stream produces under `output/worktrees/<wt>/`. Seed with `cp -al` (hard links) |
| **Total** | **≈30–300 MB** plus the run outputs the stream creates |

A d_abm worktree is nearly free. The danger is **writes**: through the `output`
symlink a worktree can overwrite `output/v0.4`. The `conf/local/globals.yml`
`output_root` override in the setup script addresses that (T3 integration spec §5.4).
The other limit is RAM rather than disk: MATSim runs from two streams at the same time
can OOM the machine whatever the checkout layout is.

---

## 5. Parallel-work strategies (for brainstorming, not a decision)

T3 facts (from the integration spec): every thread runs either **local** (main
checkout) or in its own **worktree**. The project default comes from
`defaultThreadEnvMode`, resolved as project override → environment setting → `t3.json`
→ built-in `local`. You choose per thread in the composer's workspace picker
(`mod+shift+x`). `mod+shift+l` reuses the previous worktree, so several threads can
share one worktree. Worktrees live in `worktreesDirectory` (`~/.t3/worktrees/...`), keep
their directory name when the branch is renamed, and appear grouped under the project.
The onboarding branches' `t3.json` currently sets `"defaultThreadEnvMode": "worktree"`.
Changing it to `"local"` makes worktree an explicit per-thread choice. [Verify the
picker label in the running T3 version.]

| Option | Disk per stream | Setup friction | Tool visibility | Conflict risk | Cleanup |
|---|---|---|---|---|---|
| **(a) One shared checkout plus guard rails** (current) | 0 | none | perfect: one path, one devShell, one VSCodium window, one dev server | **high** for overlapping files, lockfiles, `pnpm install`, Gradle builds, formatters touching everything, `git add -A`/commit races, branch switches that pull the rug from under everyone | none |
| **(b) Local by default, worktree for long, risky or conflicting streams** (T3 per thread) | 0 or ~1–2 G (routelab light) / ~0.1 G (d_abm) | the setup script (already written on the onboarding branches) | T3 shows worktree threads under the project with their branch. VSCodium needs a second window, or "open folder" on the worktree | low for isolated streams; still high among the local threads | T3 `worktreeCleanup` (on merge, settled-after-days). Test the symlink-safety check first (spec §5.2) |
| **(c) Lean worktrees**: `git worktree add --no-checkout` + `git sparse-checkout set --cone apps/dashboard packages/ui …` + no submodules + filtered `pnpm install --filter` + shared turbo/prek caches | routelab **~0.2–0.5 G** | higher: the stream's package set has to be known up front; T3 doesn't create sparse worktrees itself (the setup script would have to run `sparse-checkout` after creation, which only removes files afterwards) | the agent sees only its packages. That's good for focus, bad for cross-package refactors and repo-wide typecheck | low | same as (b) |
| **(d) jj workspaces** (`jj workspace add`, jj 0.41 installed) | ≈ tracked size (0.24 G / 0.03 G) + installs; submodules are never checked out | requires `jj git init --colocate`; the team stays on git | **poor**: extra workspaces are not git worktrees, so T3, husky/prek hooks, VSCodium SCM and agents running `git` don't recognise them [verify for jj ≥ 0.41] | low; jj's auto-snapshotting and first-class conflicts are good for agents | `jj workspace forget` + `rm` |
| **(e) Separate clones with `git clone --reference <main>`** (alternates) | tracked size + a few MB (~0.25 G) + installs; `--dissociate` adds ~0.24 G of pack | moderate: separate remotes/branches, hooks, `direnv allow` | appears to T3 as **another project** (or the same repository from another host), not a worktree of the main one | lowest: fully independent `.git`, index and config | `rm -rf`. Without `--dissociate`, the clone breaks if the main repo prunes objects it borrowed |

Guard rails that help in every option (all go in AGENTS.md):
- one stream per package/directory; declare "I own `apps/dashboard`" in the thread's first message
- never `git add -A`, stage paths explicitly; commit early and often on your own branch (in a shared checkout: commit, then rebase rather than switching branches)
- only one stream at a time may run `pnpm install`, a lockfile change, a Gradle build or `devenv up`. Use `flock ~/.cache/routelab/install.lock`
- one shared service stack (`COMPOSE_PROJECT_NAME=routelab`) and one emulator per machine; dev servers pick a free port
- d_abm: one MATSim run per host at a time (lock plus memory cap); outputs go to a private `output_root`
- quote all arguments (prevents the `:5432`/`--query` junk files)

### Suggested defaults

- **routelab:** `defaultThreadEnvMode: "local"`. Small, single-package edits (docs,
  one component, a fix) run in the shared checkout under the guard rails. Use a
  **worktree** for multi-hour features, anything that relocks dependencies, schema or
  codegen changes, refactors that touch many packages, and Android work. First do R1–R4
  (~14 GB), move `.repos` to the shared reference directory, share turbo/prek/AVD
  paths, and keep `worktreeSubmodules: "none"`. Look at (c) only if more than ~5
  concurrent worktrees becomes normal.
- **d_abm:** **local** for code, docs and analysis notebooks (the tree is 26 MB, so
  conflicts are the real issue, not disk). Use a **worktree** for any stream that
  *runs the pipeline or simulations*, so its `output_root` is private. **Never copy
  data/output**: always symlink, and seed with `cp -al`. Do A1 + A7 now (13.5 GB, no
  risk), and archive A2–A4 to S3 when convenient.
- Keep (d) jj and (e) `--reference` clones in mind as alternatives. Neither fits T3 and
  the existing hooks as well as (b).

---

## Implemented (2026-11-17)

Option (b) plus §3.1 (ii), on both `agentic/onboarding` branches: `t3.json` and the nixconf
T3 policy default to `local`; reference repos are listed in `.agents/reference-repos.txt` and
synced by `.agents/reference-repos.sh` into `~/.local/share/reference-repos/` (populated on
butternut from the old checkouts), linked as git-ignored `.repos/<name>`. routelab keeps
`.repos/loom` as a submodule because CI builds it. Shared-checkout rules are in each AGENTS.md;
d_abm worktrees also get private `bin/sim` run/bundle directories. Migration steps:
`2026-11-17-user-actions.md`, "Work repos: parallel setup".
