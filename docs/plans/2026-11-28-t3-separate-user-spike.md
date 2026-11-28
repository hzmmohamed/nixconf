# T3 Code as its own user, agents as per-project users: spike (2026-11-28)

Research spike for the agent-isolation layer 3 (`2026-11-28-agent-isolation-research.md` §3.3).
Question: can T3 Code run as a `t3` Unix user while each agent run executes as a sandboxed
per-project user, packaged as a reusable NixOS module `services.t3code`? Design only; no NixOS
changes in this branch.

Sources: T3 Code at `t3code@9762a3c` (v0.1.13, 2026-11-28; the installed `t3` is v0.1.9, so a
few line numbers will have moved by the time this is implemented), read from the sparse clone in
`/tmp/agent-isolation-research/t3code`; `packages/shared` and `apps/server/src/sourceControl`
were not on disk, so `agentScopeCommand`, `resolveCommandPath` and the `gh` spawn code are
described from their call sites only. Citation form: `path:lines`, relative to the T3 repo unless
prefixed with `nixconf:`. "[verify]" marks a claim I could not check from the source.

---

## 0. Answer in one page

**Stage 1 (T3 whole as one `agent` user) is what the code supports today.** Every file T3 touches
and every process it spawns assumes one UID, and T3 says so: "An environment is a T3 server running
as an OS user. It is not a sandbox" (`SECURITY.md:16-20`); "`terminal:operate` and
`orchestration:operate` already grant OS-user execution" (`docs/internals/04_environment-auth.md:17-20`).
Running the existing `t3code.service` under another user changes nothing in the UI or the network
auth (sessions are bearer tokens over HTTP, no loopback or UID trust,
`apps/server/src/auth/EnvironmentAuthPolicy.ts:22-40`). What moves is the whole `~/.t3` and every
provider login, and **every `t3` CLI command must run as that user**, because the CLI signs itself in
by opening the server's SQLite database and HMAC key files directly (`apps/server/src/cli/runningServer.ts:43-61`,
`apps/server/src/auth/EnvironmentAuth.ts:1871-1877`), inside a state directory T3 re-chmods to 0700
on every start (`apps/server/src/config.ts:208-216`).

**Stage 2 (per-project agent users under a `t3` orchestrator) is feasible for Claude Code, through
the sketched wrapper → root broker → transient system unit, with five concrete adaptations and
three accepted degradations.** The reasons, from the source:

- T3 spawns Claude per turn as `/bin/sh -c <watch script> … <binaryPath> …` with five pipes and
  `detached: true` (`apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts:420-460`), and talks
  to it only over stdin/stdout (SDK stream-JSON) plus loopback HTTP for the `t3-code` MCP server
  (bearer token sent over the SDK control channel, `ClaudeAdapterV2.ts:1897-1931`,
  `apps/server/src/mcp/McpSessionRegistry.ts:113-160`). Nothing in that channel depends on the UID:
  `systemd-run --pipe` hands the same three fds to a unit under another user.
- `binaryPath` is a free setting pinned by our managed policy (`nixconf:modules/nixos/features/agent-t3code.nix:128-138`
  already points it at `claude-devshell`), so the wrapper is a one-line change on the nixconf side.
- What breaks, and how it is handled: **kill** (T3 kills by pid and process group, EPERM across
  UIDs: the broker stops the unit when the wrapper's connection dies); **cgroup caps** (T3's
  `app-t3code-agents` slice no longer contains the agent: the broker puts it in a Nix-defined
  `agents-<project>.slice`); **Claude's config dir** (T3 reads `settings.json`, `tasks/`, `projects/*.jsonl`
  and forks sessions in `homePath` as the server UID, `ClaudeAdapterV2.ts:4035-4036, 6154-6170, 8662-8685, 2305-2323`:
  one T3 provider instance per project, `homePath` on a group-shared directory); **attachments** (the
  path T3 hands the agent lies under the 0700 state dir: a per-unit `TemporaryFileSystem=` +
  `BindReadOnlyPaths=` makes just that subtree visible); **worktrees and git** (T3 creates, watches,
  commits in and removes worktrees as `t3`, never sets `safe.directory`: setgid project groups,
  default ACLs, `UMask=0002`, `core.sharedRepository=group`, and `safe.directory` in the agent
  user's gitconfig).
- Accepted degradations: preview port attribution (reads `/proc/<pid>/environ`,
  `apps/server/src/preview/PortScanner.ts:380`), Claude background-task output tail
  (`/tmp/claude-<server uid>`, `ClaudeTaskOutputTail.ts:23-34`), device tools (launchers and
  tokens under the 0700 state dir, `apps/server/src/device/AgentDeviceShim.ts:8-9, 31-39`).
- **Codex and OpenCode are one long-lived process per provider instance serving every thread**
  (`CodexAdapterV2.ts:1848`; `packages/provider-opencode/src/server/OpenCodeRuntime.ts:592-660`),
  so "per project" for them means one T3 instance per project: OpenCode as a Nix system service
  `opencode@<project>` with `User=agent-<project>` and T3's `serverUrl` pointing at it
  (`server/v2/OpenCode2Server.ts:122-185`); Codex through the same wrapper, if ever enabled.

One real escalation path stays open in stage 2 and needs a policy decision (§4.4): `t3.json`
layout commands, setup scripts and T3 terminals run as the server's user, i.e. as `t3`, after a
UI approval (`docs/internals/04_environment-auth.md:62-64`; `apps/server/src/project/ProjectSetupScriptRunner.ts:523-562`;
`apps/server/src/terminal/NodePtyAdapter.ts:256-271`). An agent that edits a worktree's `t3.json`
is one approval click away from running as `t3`. Terminals have a clean fix (`T3CODE_TERMINAL_SHELL`
to a broker-backed shell); `t3.json` commands need a policy lock or a documented rule.

Recommendation: build stage 1 now as `services.t3code` (user, home, unit, pairing helpers, root
Tailscale Serve, nixosTest), with the project registry and group layout already shaped for stage 2.
Build stage 2 for Claude first; keep OpenCode on stage 1 until a per-project instance is needed.

---

## 1. Findings from the source

### 1.1 How T3 spawns providers

| Provider | Mechanism | Binary | stdio / IPC | cwd |
|---|---|---|---|---|
| Claude Code | Claude Agent SDK `query()` in the server process (`ClaudeAdapterV2.ts:1883-1891`) with T3's own `spawnClaudeCodeProcess` (`:1832-1881`) → `NodeChildProcess.spawn("/bin/sh", ["-c", WATCH_SCRIPT, "t3-claude", cwd, command, ...args], {env, stdio: 5×pipe, detached: true})` (`:443-460`) | the `binaryPath` setting, default `"claude"` (`packages/contracts/src/settings.ts:639-649, 813-819`), `~` expanded, then PATH lookup inside `agentScope.wrap` (`apps/server/src/process/agentScope.ts:110-115, 437`) | SDK stream-JSON on stdin/stdout; fd 3 = death watcher, fd 4 = start gate (`:420-427`); MCP over `http://127.0.0.1:<port>/mcp` + bearer (`:2904-2940`) | the shell does `cd -P -- "$1"` itself (`:425`); `thread.worktreePath ?? workspaceRoot` (`orchestration-v2/RuntimePolicy.ts:155-165`) |
| Codex | one `codex app-server` per instance, JSON-RPC over stdio (`CodexAdapterV2.ts:1999-2049, 1804-1832`) | `settings.binaryPath || "codex"` (`:2004`) | stdio; MCP config per thread with `http_headers` (`:1731-1772`) | inherits the server's cwd; the thread cwd travels in the protocol (`:1741`) |
| OpenCode | one `opencode serve --hostname=127.0.0.1 --port=N` per instance (`OpenCodeRuntime.ts:592-660`); v2 can attach to a configured `serverUrl` (`v2/OpenCode2Server.ts:122-185`) | `"opencode"` on PATH (`packages/provider-opencode/src/settings.ts:19-24`) | HTTP + `Authorization: Basic opencode:<password>` (`OpenCodeRuntime.ts:578-588`) | per request (`:578-581`) |

No node-pty for providers. Every spawn is wrapped by `AgentScope.wrap`, which only adds
`systemd-run --user --scope --slice=app-t3code-agents(-<hash>).slice` when `XDG_RUNTIME_DIR` is set
and a probe succeeds (`agentScope.ts:164-187`); force-stop writes `cgroup.kill` or runs
`systemctl --user kill` (`:396-424`). There is no `sudo`, `setpriv`, `runuser` or uid switch anywhere.

**Environment:** the server's `process.env` is inherited wholesale, then edited
(`packages/provider-core/src/server/instanceEnvironment.ts:8-35`). Claude gets
`CLAUDE_CODE_ENTRYPOINT=t3-code`, the parent-session variables removed, `CLAUDE_CONFIG_DIR` set from
the instance `homePath` when non-empty, and **HOME untouched** ("Changing HOME hides macOS Keychain
credentials", `apps/server/src/provider/Drivers/ClaudeHome.ts:33-46, 51-95`), plus
`T3CODE_THREAD_ID` per query (`ClaudeAdapterV2.ts:1784-1797`). Per-instance env entries, including
resolved settings secrets, are merged in (`apps/server/src/provider/ProviderInstanceRegistry.ts:161-195`).
So whatever the server has (`SSH_AUTH_SOCK`, `GH_TOKEN`, …) reaches the child unless something
between them scrubs it.

**Same-UID reads/writes in the provider's home (the part that matters for stage 2):**

- `~/.claude` (or `homePath`): `settings.json`, `remote-settings.json` (`ClaudeAdapterV2.ts:4035-4036, 6297-6333`),
  `tasks/<listId>/*.json` (`:6154-6170`), `projects/*/<session>/subagents/*.jsonl` (`:8662-8685`),
  transcript usage (`provider/Drivers/claudeUsage.ts:139-147`), history import
  (`project/AgentSessionScanner.ts:1570-1600`), `getSessionMessages` on resume (`:1763-1774`) and
  `forkSession`, which **writes** a new session file (`:2305-2323`). Background-task output is read
  from `$CLAUDE_CODE_TMPDIR | $TMPDIR | /tmp/claude-<server uid>` (`ClaudeTaskOutputTail.ts:17-35`).
- `~/.codex`: shadow-home materialisation writes dirs and symlinks (`CodexHomeLayout.ts:366-461`),
  `auth.json` dir watched (`CodexDriver.ts:419-430`), `sessions/` and `state_5.sqlite` read.
- OpenCode: `auth.json`, `opencode.db` read-only (`server/usageLimits.ts:58, 99-125`).

**Kill model:** `process.kill(-pid, sig)` (`packages/provider-core/src/server/processGroup.ts:2-9`),
SIGKILL to the group on exit (`ClaudeAdapterV2.ts:464-468`), the shell watcher's `kill -TERM 0`
(`:422`), `ps`-based descendant reaping without a scope (`:1708-1742`), and a startup reaper that
matches pid + start time from `/proc` (`process/providerProcesses.ts:94-123`). `register` throws
unless the recorded pid's parent is the server or its launcher helper (`:129-137`). Every kill call
swallows errors, so a cross-UID EPERM is silent.

### 1.2 Git and worktrees

All git runs in the server process as its UID: plain `git` via `ChildProcess.make(executable,
args, {cwd, env})` on the full host env (`apps/server/src/vcs/GitVcsDriverCore.ts:1415-1449`), with
`GIT_CONFIG_*` injecting only `safe.bareRepository=explicit`, `maintenance.auto=false`, `gc.auto=0`
(`apps/server/src/vcs/VcsProcess.ts:113-157`). **`safe.directory`, `user.name`, `GIT_SSH_COMMAND`
and credential helpers are never set** (zero hits in `apps/server/src`), so identity and credentials
are the server user's. Hooks run by default (`RepositoryHooks` policy `all`, `GitVcsDriver.ts:400-402`).

Worktree layout: `<baseDir>/worktrees/<basename(project)>/<branch-slug>-<16 hex>`
(`GitVcsDriverCore.ts:6605-6643`; root at `config.ts:166`, one server-wide `worktreesDirectory`
setting, `packages/contracts/src/settings.ts:1421`). Creation: `git branch` + `git worktree add
[--lock --reason t3-create-…]`, optional sparse checkout and `submodule update`
(`:6648-6750, 6822-6895`). The server also: watches `.git/worktrees/<name>/{HEAD,index}` with
`fs.watch` (`vcs/VcsStatusBroadcaster.ts:1157-1175`); runs `git status --porcelain=2` on each event
(`:3473-3480`); rewrites the index via copy + `link` + `rename` (`:6540-6557`); background-fetches
into `<common>/objects/tmp_objdir-t3code-*` (`:1896-1945`); writes `refs/t3code/pre-refresh` and
checkpoint refs under `refs/t3/…` with private objdirs and hard-linked objects
(`vcs/GitVcsDriver.ts:1310-1340, 2020-2105`; publish copies the fanout-dir mode "Git has already
applied core.sharedRepository", `:2031-2035`); restores with `git restore … && git clean -fd`
(`:2327, 2415`); removes worktrees with Node `fs.remove` then `git worktree remove`
(`vcs/worktreeRemoval.ts:233-265`); and commits/pushes/creates PRs itself
(`GitVcsDriverCore.ts:4282-4309, 4487-4619`; `git/GitManager.ts:3209-3222`). The index watcher
(`@ff-labs/fff-node`) needs `r-x` on every directory (`workspace/WorkspaceSearchIndex.ts:1107-1129`).
`sharedCheckoutGuard.ts` is a logical busy check on thread state, not an ownership check
(`git/sharedCheckoutGuard.ts:17-100`).

**Consequence:** if a worktree were *owned* by another user, every one of these fails with
"dubious ownership" (git ≥ 2.35.2 compares the top-level and, for linked worktrees, the gitdir
owner with the euid; `safe.directory` is honoured only in system/global/command scope, `man
git-config`). The viable shape is the reverse: `t3` owns the clone and the worktrees, the project
user gets **group** write through setgid directories + default ACLs + `umask 002`, and the agent
user carries `safe.directory` for the clone and the worktrees root in its own gitconfig (git 2.54
here; the `/*` suffix form needs ≥ 2.46). `core.sharedRepository=group` in the clone makes git's
own objects/refs/index group-writable; working-tree files follow umask and the default ACL.

### 1.3 Terminals, previews, file viewer, attachments

| Feature | Runs as | Touches | Breaks under a different agent UID? |
|---|---|---|---|
| Terminals: node-pty `spawn(shell, args, {cwd, env})`, no uid option (`terminal/NodePtyAdapter.ts:256-271`); shell = configured → requested → `$SHELL` → zsh/bash/sh (`terminal/Manager.ts:703-739`); override `T3CODE_TERMINAL_SHELL`, "an executable path, not a command line" (`:709, 3025-3029`); env = `process.env` minus a blocklist + instance env (`:134-145, 1840-1860`) | server | worktree, server dotfiles | Terminal is a **`t3` shell** in the agent's worktree. Fix: `T3CODE_TERMINAL_SHELL` → broker-backed shell (`systemd-run --pty --uid=agent-<p>`) |
| Previews: pinned `chrome-headless-shell` under `~/.t3/tools` (`preview/PreviewBrowser.ts:173-186`), Playwright profiles under `userdata/server-browser` (`ServerBrowser.ts:739`); `html_render` reads the agent's `.html` and image paths as the server (`htmlRender/HtmlRender.ts:496-541, 325-410`), writes the result into `attachments/` (`:565-583`); screenshots to `userdata/browser-artifacts`, recordings to `attachments/`, paths returned to the agent (`mcp/McpHttpServer.ts:776-804`; `mcp/toolkits/preview/handlers.ts:142-188`); port→thread attribution via `/proc/<pid>/environ` (`preview/PortScanner.ts:380, 609-619`) | server | agent-written files (must be readable by `t3`), paths under 0700 `userdata/` | Partly: returned paths need the bind trick (§3.3); `/proc/<pid>/environ` of another UID is unreadable → auto-attribution off; agent files in a private `/tmp` invisible |
| File viewer / editor: `WorkspaceFileSystem.readFile` (O_NOFOLLOW), `writeFile` inside a workspace root (`workspace/WorkspaceFileSystem.ts:386-440, 596-651`); `TaskFolders` mkdir/symlink/`rm -rf` (`workspace/TaskFolders.ts:738-805, 1015-1026`) | server | the whole worktree | Works with group rw + default ACL; files `t3` creates are group-writable by the agent |
| Attachments: `attachmentsDir = <stateDir>/attachments` (`config.ts:155`), not separately configurable; uploads land as umask-mode files (`assets/AttachmentUpload.ts:150-218`); the agent gets the **absolute path** in its prompt (`packages/provider-core/src/server/attachmentPrompt.ts:160-182`) and, for Claude, `additionalDirectories = [cwd, extraRoots, attachmentsDir, …]` (`ClaudeAdapterV2.ts:2787-2795`) | server | `~/.t3/userdata/attachments/*` read by the agent | Yes: `userdata` is 0700 (`config.ts:208-216`), so no traversal for another UID. Fix in §3.3 |
| MCP (`t3-code` tools) | server | nothing on disk; loopback HTTP + bearer | No |
| Secrets: `userdata/secrets/<name>.bin` 0600 in a 0700 dir (`auth/ServerSecretStore.ts:174-189, 232-235`), injected as env (`ProviderInstanceRegistry.ts:161-195`); agent-requested files under `secrets/files/` (`secrets/SecretRequests.ts:319-334`) | server | env only | No, if the broker forwards the allowlisted variables; `secrets/files/` paths break |
| Device tools: launchers `userdata/device/bin/agent-device` (0755) with `--bearer-token` args, endpoint JSON 0600, emulator token in the server's `/run/user/<uid>` (`device/AgentDeviceShim.ts:8-9, 31-39, 236-283`; `device/LocalDeviceHost.ts:232-243`) | server | agent executes the launcher | Yes; stays a stage-1 feature (butternut Android) |
| Codex managed-token broker: unix socket in `$TMPDIR/t3-token-*/s`, dir must be own uid + 0700 (`provider/CodexManagedTokenBroker.ts:45-88`) | server | Codex child | Yes (Codex only) |

### 1.4 The existing nixconf unit and the CLI's state

`nixconf:modules/nixos/features/agent-t3code.nix:584-639` runs `t3 serve --mode web --no-browser
--host 127.0.0.1 --port N [--tailscale-serve --tailscale-serve-port 443] --base-dir %h/.t3 %h` as
a **systemd user service** of the owner, with `PATH` from the owner's per-user profile and
`claudeAgent.binaryPath = /etc/profiles/per-user/<user>/bin/claude-devshell` pinned in the managed
policy (`:128-138`). Settings (`programs.t3code.userSettings.providerInstances`, `:536-562`) write
the Claude instances' `homePath` to `${home}/.claude-work` etc.

Can it run as another user? Yes, mechanically: `t3 serve` reads nothing from the invoking user
beyond `HOME` (base dir `~/.t3`, `apps/server/src/os-jank.ts:276-282`) and `XDG_RUNTIME_DIR`
(scopes). What moves and what changes:

| State | Where | Moves with the user? | Note |
|---|---|---|---|
| sessions, pairing links, projects, threads | `userdata/statev2.sqlite` (+WAL) (`config.ts:154`; `persistence/AuthSessions.ts:232`) | yes | re-pair every device once |
| session signing key, MCP OAuth key, settings secrets | `userdata/secrets/*.bin` (`ServerSecretStore.ts:185-189`) | yes | plaintext, 0600 |
| discovery file | `userdata/server-runtime.json` (`serverRuntimeState.ts:12-35`), no token | yes | pid liveness treats EPERM as alive (`:132-140`), so cross-user `kill -0` is fine |
| single-instance lock | `userdata/server-owner.sqlite` (`serverOwnership.ts:172-208`) | yes | `isServerOwnershipHeld` returns `false` on EACCES (`:220-221`): an owner-UID `t3` would wrongly think no server runs |
| worktrees, caches, tools (chrome), runtime | `<base>/{worktrees,caches,tools,runtime}` (`config.ts:150-180`) | yes | `browserLink` in nixconf (`agent-t3code.nix:261-272`) must run as the new user |
| compile cache | `~/.cache/t3code/compile-cache` (`cliCompileCache.ts:12-16`) | yes | |
| provider logins | `~/.claude*`, `~/.codex`, `$XDG_DATA_HOME/opencode` | **re-login as the new user** | the research doc's credential table applies |
| Tailscale Serve | `tailscale serve` run **by the server process** (`server.ts:1050-1191`); failure only logs (`:1095-1103`) | needs operator | `tailscale set --operator` takes one user; use a root oneshot like `agent-opencode.nix:392-412` and drop `--tailscale-serve` |
| `t3 pair`, `t3 auth`, `t3 thread`, `t3 project`, `t3 environment link` | open the DB and keys in-process (`cli/pair.ts:481-503`; `cli/auth.ts:34-55`; `cli/thread.ts:261-298`; `cli/environment.ts:40-75`) | **must run as the server user** | `t3-pair`, `t3-link`, `registerProjects` in nixconf become `doas -u t3 …`; `t3-link` over SSH must log in as `t3@host` |
| desktop app | remote environment by URL/pairing | unchanged | its own local backend must stay off (already: `agent-t3code.nix:670`) |
| "Open in editor", startup browser | `process/externalLauncher.ts:817-826`; `serverRuntimeStartup.ts:368-383` | no session → fail | already `--no-browser`; "Open in" was never useful on a headless server |

There is no `--token` flag on `t3 serve` and no loopback trust; the only fixed credential is
`T3CODE_DEV_AUTH_TOKEN` for dev web servers (`cli/config.ts:180-198, 330-331`).

---

## 2. Stage 1: T3 Code as one dedicated user

This is §3.3 of the research doc made concrete against the findings above. Module: `services.t3code`
(flake.nixosModules.t3code), host-agnostic, consumed by `agent-t3code` for the nixconf-specific
policy, projects and desktop bits.

### 2.1 Shape

```nix
services.t3code = {
  enable = true;
  user = "t3";                    # created: fixed uid, group "t3", no wheel, no doas, linger
  home = "/var/lib/t3code";       # HOME of the unit; ~/.t3 lives here (0711 home, T3 keeps userdata 0700)
  package = llm.t3code;
  port = 3773;
  tailscaleServe.enable = true;   # root oneshot `tailscale serve --bg --https=443 http://127.0.0.1:<port>`
  policy = { … };                 # /etc/t3code/policy.json, `t3 policy check` at build time (as today)
  settings.providerInstances = …; # written into <home>/.t3/userdata/settings.json by a oneshot as `t3`
  environment = { PATH = …; DIRENV_CONFIG = …; LD_LIBRARY_PATH = …; };
  projects = { <name> = { path = "/var/lib/t3code/projects/<name>"; remote = "…"; }; };  # registry, see 3.1
  operators = [ "hfahmi" ];       # doas rule `permit persist <op> as t3`; `t3-pair`/`t3-link`/`t3ctl` wrappers
};
```

The unit: a **system service** (`systemd.services.t3code`, `User=t3`, `WorkingDirectory=<home>`,
`UMask=0002`), not a user service. Reasons: one unit to start at boot without `loginctl
enable-linger` juggling; hazel can gate it on the owner's session with a plain `polkit` rule for
`systemctl start/stop t3code.service` (research doc §7 Q7); the `KillMode=mixed`, `OOMPolicy`,
`Restart`, `MemoryLow` settings from `agent-t3code.nix:623-631` carry over unchanged. T3's own
agent scopes need a user manager (`XDG_RUNTIME_DIR` set, `systemd-run --user`, `agentScope.ts:164-168`):
keep them by making the unit `PAMName=login` + `users.users.t3.linger = true`, so `user@<uid>.service`
exists and `XDG_RUNTIME_DIR=/run/user/<uid>` is set [verify that T3's probe passes under `PAMName`;
if not, scopes are off and T3 falls back to `ps` reaping, `ClaudeAdapterV2.ts:1708-1742`, which still
works within one UID].

`t3 pair`, `t3 auth`, `t3 thread`, `t3 project add` run as `t3` (§1.4): the module ships
`t3ctl <subcommand…>` = `doas -u t3 env HOME=<home> t3 --base-dir <home>/.t3 "$@"`, and the
nixconf `t3-pair`, `t3-link`, `registerProjects` call it. `t3-link <host>` must `ssh t3@<host> t3
pair …`, so `users.users.t3.openssh.authorizedKeys.keys = self.sshKeys.<owner>` on every T3 host
and `t3`'s login shell stays `nologin` except via that key [decide: nologin + `ForceCommand`, or a
real shell for `ssh t3@localhost` editor access as in research §3.3].

Provider logins: `doas -u t3 -s` once per account dir (`claude` → `/login` with
`CLAUDE_CONFIG_DIR`), `opencode auth login`. `programs.t3code` (home-manager) is not available for a
system user without an HM user; the module writes `settings.json` keys itself (a oneshot `jq`
merge as `t3`, same as `desktopSettingsMerge` does today, `agent-t3code.nix:338-362`).

Projects: `t3`'s own clones under `<home>/projects/<name>` (research doc §3.3 "the shared surface is
git"); `workspace-bootstrap.nix` clones them as `t3`. The owner's checkouts stay agent-free.

### 2.2 Failure modes

| Failure | Cause | Mitigation |
|---|---|---|
| server starts, UI works, but every `t3` CLI call by the owner says "no running server" or EACCES | CLI opens `<home>/.t3/userdata` as the caller (`runningServer.ts:43-61`; `config.ts:208-216` chmod 0700) | `t3ctl` wrapper; nothing else may call `t3` directly (deny `t3` in the owner's PATH on T3 hosts) |
| Tailscale Serve silently absent | not the operator; T3 only logs (`server.ts:1095-1103`) | root oneshot; keep `--tailscale-serve` off; nixosTest asserts the oneshot is wanted |
| Claude "not logged in" in every thread | credentials live in the owner's `~/.claude` | login as `t3`; `claude auth status` check in `t3ctl doctor` |
| threads start outside the dev shell | `claude-devshell` resolves direnv allow per user (`agent_devshell.py`) | pre-create `~t3/.local/share/direnv/allow/<hash>` declaratively (research §3.3) |
| chrome-headless-shell "cannot run" | `browserLink` ran as the owner (`agent-t3code.nix:257-272`) | `ExecStartPre` runs as `t3` already (same unit) |
| hazel: T3 runs on battery from boot | system unit + linger | `ConditionACPower` or the polkit start/stop rule; owner's choice (research §7 Q7) |
| desktop app opens its own local backend and fights the service | `~hfahmi/.t3` vs `~t3/.t3` are different homes now, so no lock conflict (`serverOwnership.ts:172`), but the app would spawn a second, owner-UID server | keep `localEnvironmentEnabled = false` (`agent-t3code.nix:336`) |
| a thread's `git push` or `gh pr create` fails | `t3` has no credentials | per-user fine-grained PAT via `gh auth login --with-token` as `t3`; `/etc/gitconfig` credential helper (`github.nix:126-128`) already applies to every user |
| `/dev/kvm`, Vulkan | groups were granted to the owner (`agent-t3code.nix:702-703`) | `users.users.t3.extraGroups = ["kvm" "render"]` on hosts that need them |

### 2.3 nixosTest (`checks.t3code-user`)

`pkgs.testers.runNixOSTest` (pattern: `nixconf:modules/checks/immich-vm.nix`), one node importing
`services.t3code` with `tailscaleServe.enable = false`, `browser.enable = false`, policy with
updates off, a throwaway project cloned from a bare repo created in the test, and an `operator`
user. Assertions:

1. `systemctl show -p User t3code.service` is `t3`; `wait_for_open_port(3773)`; `ss -ltn` shows
   only `127.0.0.1:3773`.
2. `stat -c %a:%U /var/lib/t3code/.t3/userdata` is `700:t3`; as the operator, `cat …/statev2.sqlite`
   fails, `t3 --base-dir /var/lib/t3code/.t3 auth session list` fails.
3. `t3ctl auth session issue --scope orchestration:read --ttl 1m` succeeds as the operator and the
   token authenticates against `/api/...` [pick an endpoint from `EnvironmentHttpApi`]; the same
   token over `curl` works from the operator's shell (network auth is UID-agnostic).
4. `doas -u t3 …` from the operator works with persist; `doas -u root` from `t3` fails.
5. Process tree: the unit's cgroup contains no process with uid ≠ `t3`; `t3`'s `~/.ssh` does not
   exist; the operator's `~/.ssh/test-key` is unreadable from `doas -u t3 cat`.
6. A fake provider binary (`binaryPath` pinned by policy to a script that writes `id -u`, `$HOME`,
   `$CLAUDE_CONFIG_DIR`, `$PWD`, `env | sort` to a file and exits) run through a thread started via
   `t3ctl thread launch` [verify the CLI can start a thread without a real model]; assert uid `t3`,
   cwd under `/var/lib/t3code/.t3/worktrees/<project>/`, and `SSH_AUTH_SOCK` absent.

If 6 is not drivable headlessly, replace it with running the pinned script through `systemd-run
--user --scope` as `t3` and keep the assertions.

---

## 3. Stage 2: per-project users through a broker

### 3.1 Registry (Nix → one JSON file, consumed by the broker and the tests)

```nix
services.t3code.projects.nixconf = {
  path = "/var/lib/t3code/projects/nixconf";   # t3's clone, owner t3:proj-nixconf, setgid, default ACL g:proj-nixconf:rwX
  user = "agent-nixconf";                      # created; home /var/lib/agents/nixconf (0750 agent:proj)
  claude.configDir = "/var/lib/agents/nixconf/claude";   # T3 instance "claude-nixconf": homePath = this
  claude.account = "personal";                 # documentation only: which login to do there
  network = { allowProxy = true; extraAllow = []; };     # IPAddressAllow beyond loopback
  limits = { MemoryMax = "40%"; CPUWeight = 50; TasksMax = 2048; };
  extraBinds = [];                             # e.g. an AVD dir
};
```

Derived by Nix: group `proj-<name>` with members `t3` and `agent-<name>`; `systemd.slices."agents-<name>"`;
`systemd.tmpfiles` rules creating `<path>`'s parent, `/var/lib/t3code/.t3/worktrees/<basename path>`
(pre-created so T3's `mkdir -p` inherits setgid + default ACL; **assertion: basenames unique across
projects**, since T3 keys worktree dirs by `basename(cwd)`, `GitVcsDriverCore.ts:6605-6643`),
`<claude.configDir>` (owner `agent-<name>:proj-<name>`, 2770, default ACL `g:proj-<name>:rwX` so T3's
reads and `forkSession` writes work and the agent can append afterwards), and `/var/lib/agents/<name>/tmp`
(for `CLAUDE_CODE_TMPDIR`, see 3.5); `/etc/agent-broker/projects.json` listing per project: uid, gid,
roots (`path`, worktrees dir), config dir, allowed argv[0] set (the Nix store paths of `claude`,
`codex`, and the shell for terminals), env allowlist, unit properties.

The clone itself: `git config core.sharedRepository group` and `safe.directory` entries
(`<path>`, `<worktrees dir>/*`) in `/var/lib/agents/<name>/.gitconfig` (written by tmpfiles from
Nix), plus `user.name/email` and the project's credential helper. `t3`'s gitconfig needs no
`safe.directory`: it owns everything.

### 3.2 Wrapper, broker, unit

**Wrapper** (`claude-brokered`, replaces `claude-devshell` in the pinned `binaryPath`): a Python
stdlib program. It connects to `/run/agent-broker/sock`, sends one JSON line `{argv, cwd, env:
{allowlisted vars}}` and its fds 0, 1, 2 with `socket.send_fds`, then waits for the exit status line.
On `SIGTERM`/`SIGINT`/`SIGHUP` or stdin EOF it closes the connection and exits 143. It is what T3
sees as "the provider process": its pid is what `/bin/sh` exec's into, its parent is the server or
the launcher helper, so `providerProcesses.register` (`providerProcesses.ts:129-137`) stays happy,
and T3's `kill -TERM 0` / `cgroup.kill` / `process.kill(-pid)` all hit the wrapper, which is
exactly what we want them to hit.

The dev-shell logic of `agent_devshell.py` moves **inside** the unit (the broker prepends
`agent-devshell <binary>` to argv; the direnv allow/cache belongs to the agent user, not `t3`).

**Broker** (`agent-broker.socket` + `agent-broker@.service`, `Accept=yes`, `SocketMode=0660`,
`SocketGroup=t3`, so only `t3` can connect; root, Python stdlib, ~200 lines): per connection it
receives the request and the three fds; resolves the project **from `cwd`** (must be under a
registered `path` or worktrees dir, after `realpath`; the client's claim is never trusted); checks
`argv[0]` against the project's allowed set and `env.CLAUDE_CONFIG_DIR == claude.configDir` when
present; then runs

```
systemd-run --pipe --wait --collect --quiet \
  --unit=agent-<proj>-<8 hex> --slice=agents-<proj>.slice \
  --uid=agent-<proj> --gid=proj-<proj> --working-directory=<cwd> \
  --setenv=HOME=/var/lib/agents/<proj> --setenv=PATH=<nix profile of the agent user> \
  --setenv=CLAUDE_CONFIG_DIR=… --setenv=T3CODE_THREAD_ID=… --setenv=CLAUDE_CODE_TMPDIR=/var/lib/agents/<proj>/tmp \
  --setenv=<each allowlisted var: CLAUDE_CODE_*, ANTHROPIC_*, DIRENV_CONFIG, TERM, LANG, NIX_*> \
  -p UMask=0002 -p NoNewPrivileges=yes -p RestrictSUIDSGID=yes -p CapabilityBoundingSet= \
  -p ProtectSystem=strict -p ProtectHome=tmpfs -p PrivateTmp=yes -p ProtectKernelTunables=yes \
  -p ProtectControlGroups=yes -p RestrictNamespaces=yes -p LockPersonality=yes \
  -p BindPaths=<path>:<path> -p BindPaths=<worktrees dir>/<basename>:<same> \
  -p BindPaths=/var/lib/agents/<proj>:/var/lib/agents/<proj> \
  -p TemporaryFileSystem=/var/lib/t3code/.t3/userdata:ro \
  -p BindReadOnlyPaths=/var/lib/t3code/.t3/userdata/attachments \
  -p BindReadOnlyPaths=/var/lib/t3code/.t3/userdata/browser-artifacts \
  -p ReadWritePaths=/nix/var/nix/daemon-socket \
  -p IPAddressDeny=any -p IPAddressAllow=127.0.0.0/8 -p IPAddressAllow=::1 [-p IPAddressAllow=<proxy>] \
  -p MemoryMax=… -p TasksMax=… -p RuntimeMaxSec=12h -p TimeoutStopSec=15 -p KillMode=control-group \
  -- agent-devshell <argv…>
```

with its stdin/stdout/stderr set to the received fds (`--pipe` passes them to the unit as-is,
`man systemd-run`; the fd-reopen caveat there does not apply: the SDK child never reopens
`/proc/self/fd/*`). The broker waits for `systemd-run` **and** for EOF on the control connection;
whichever comes first, it `systemctl stop`s the unit (so a wrapper killed by T3 cannot leave an
orphan agent, which is the failure T3's own kill path would otherwise have), then writes the exit
status back. `RuntimeMaxSec` is the backstop if the broker itself dies.

Why a broker and not polkit on `org.freedesktop.systemd1.manage-units` for `t3`: that action lets
the caller start *any* transient unit with *any* `User=`, including root. `run0` has the same
granularity. A setuid helper (agent-as-unix-user's `su_as_agent`, `agent-as-unix-user@README.md:95-140`)
is the other precedent; a socket-activated root service is easier to audit, has no setuid binary on
agent-reachable paths, and logs every request to the journal.

**Terminals:** `T3CODE_TERMINAL_SHELL=/run/current-system/sw/bin/t3-terminal-shell` in the unit's
`Environment` (`Manager.ts:3025-3029` reads it from the server env); the script sends the same
request with `--pty` semantics (the broker uses `systemd-run --pty` when fd 0 is a TTY) and
`argv = [bash]`. The owner's T3 terminal in a thread is then a shell *as that project's user*, in
the same sandbox; a `t3` shell stays reachable via `doas -u t3 -s`.

**OpenCode:** one T3 instance per project (`opencode-<name>`, `serverUrl = http://127.0.0.1:<port>`)
backed by `systemd.services."opencode@<name>"` (`User=agent-<name>`, same sandbox properties as a
static unit, `opencode serve --hostname 127.0.0.1 --port <port>`; T3 v2 attaches to a configured
`serverUrl`, `v2/OpenCode2Server.ts:122-185`) [verify how the Basic-auth password is configured for
an external server: `OPENCODE_SERVER_PASSWORD` on the service side and the instance setting on T3's].
Until then OpenCode threads run as `t3` (stage 1).

### 3.3 The five adaptations, with the source line that forces each

1. **Kill → connection lifetime.** `process.kill(-pid)` and `kill 0` cannot cross UIDs
   (`processGroup.ts:2-9`; `ClaudeAdapterV2.ts:422, 464-468`); the broker's EOF-stop replaces them.
   `providerProcesses` matches pid + start time (`:94-123`): it sees the wrapper, fine.
2. **Caps → `agents-<proj>.slice`.** T3's `systemctl --user set-property` on `app-t3code-agents`
   (`agentScope.ts:188-236`) no longer contains the agent; the Nix slice does. T3's `agentScope.kill`
   via `cgroup.kill` (`:407-417`) kills the wrapper, which stops the unit (1).
3. **Attachments → `TemporaryFileSystem=` + `BindReadOnlyPaths=`.** `userdata` is 0700
   (`config.ts:208-216`) and `attachmentsDir` is not relocatable (`config.ts:155`). Inside the unit,
   `/var/lib/t3code/.t3/userdata` is an empty root-owned tmpfs with only `attachments/` and
   `browser-artifacts/` bound in; `/var/lib/t3code` and `.t3` carry mode 0711 so the path resolves.
   Attachment files are umask-mode (`AttachmentUpload.ts:150-218`), i.e. 0664 under `UMask=0002`,
   readable. The `[Attached … saved at: <path>]` prompt text (`attachmentPrompt.ts:160-182`) and
   Claude's `additionalDirectories` (`ClaudeAdapterV2.ts:2787-2795`) keep working unchanged.
4. **Claude home → per-project instance on a group-shared dir.** T3 reads and writes `homePath`
   as the server (`§1.1`), and `homePath` is per *instance*, not per project. So: instance
   `claude-<proj>` with `homePath = claude.configDir`; the broker enforces the match. The owner picks
   the project's instance in the model picker (default per project is not a T3 setting
   [verify: `defaultModelSelection` is global, `agent-t3code.nix:87-92`]; a wrong pick is refused by
   the broker with a clear error on stderr, which T3 surfaces as a provider failure). Account ↔
   project is natural here: nixconf = personal login, routelab and d_abm = work login.
5. **Worktrees and the clone → group layout.** `t3` creates and owns them; agent needs rw: setgid
   + default ACL on `<path>` and `<worktrees>/<basename>` (pre-created, 3.1), `UMask=0002` on both
   `t3code.service` and the agent unit, `core.sharedRepository=group`, agent-side `safe.directory`.
   T3-side writes (`restore`, editor saves, index refresh, `fs.remove`) all work because `t3` owns
   or group-writes everything; agent-created directories inherit the group and the setgid bit, and
   the default ACL gives `t3` `rwx` on them, so `worktreeRemoval.ts:233-251` succeeds.

### 3.4 Failure modes

| Failure | Cause | Mitigation |
|---|---|---|
| orphan agent after T3 restart / force stop | T3's kills hit the wrapper only | broker EOF-stop; `RuntimeMaxSec`; nixosTest 6 |
| "Cannot identify spawned provider" | a hop that forks before exec | the wrapper execs nothing; it *is* the recorded pid |
| resume fails: "session not found" | T3 looked in a different `homePath` than the agent used | broker refuses mismatched `CLAUDE_CONFIG_DIR`; instance per project |
| `forkSession` file unwritable by the agent | written by `t3` | default ACL `g:proj:rwX` on the config dir; `t3` runs with `UMask=0002` |
| agent cannot read an attachment | 0700 `userdata` | adaptation 3; test asserts `cat <attachment>` inside the unit |
| agent `git commit` fails: dubious ownership / EACCES on `index.lock` | worktree owned by `t3`; `.git/worktrees/<n>` owned by `t3` | agent `safe.directory` for `<path>` and `<worktrees>/*`; `core.sharedRepository=group`; group-writable index via setgid + ACL |
| T3 `git status` fails on agent-created files | files 0644 owned by agent, dirs 0755 | `UMask=0002` in the unit plus default ACL (ACL default overrides umask for group bits) |
| preview does not attach to the agent's dev server | `/proc/<pid>/environ` unreadable across UIDs (`PortScanner.ts:380`) | accepted; the agent passes the URL to `preview_open` explicitly; document in guidelines |
| `html_preview` of a `/tmp` path fails | `PrivateTmp=yes` | `CLAUDE_CODE_TMPDIR=/var/lib/agents/<proj>/tmp` (group-shared, bound) [verify Claude's scratchpad honours it]; guidelines: artifacts under the worktree |
| background task output not shown in T3 | `/tmp/claude-<t3 uid>` (`ClaudeTaskOutputTail.ts:23-34`) | accepted degradation, or set the same `CLAUDE_CODE_TMPDIR` in `t3code.service` for one project only (not per project; T3 reads one path) |
| device tools (`agent-device`) fail inside the unit | launchers and tokens under 0700 `userdata/device`, emulator token in `t3`'s `/run/user` | butternut keeps Android threads on a stage-1 instance (`claude-devshell` as `t3`), or bind `userdata/device` too and grant `kvm` to the agent user: later |
| agent breaks out via `t3.json` / setup script / terminal | those run as `t3` after approval (`04_environment-auth.md:62-64`; `ProjectSetupScriptRunner.ts:523-562`) | terminals: `T3CODE_TERMINAL_SHELL` broker shell; `t3.json` commands: policy lock if one exists [verify in `packages/contracts/src/settings.ts`], else a `pre-commit`-style check that `t3.json` is unchanged from `main` before T3 reads it is impossible to enforce from outside; **open question 2** |
| `nix develop` in the unit cannot substitute | `IPAddressDeny=any` | `IPAddressAllow=<egress proxy>` (layer 4) and the daemon does the fetching anyway; the daemon socket is bound rw |
| `systemd-run` as root needs the agent user's `XDG_RUNTIME_DIR` for direnv's `systemd-run --user` warm-up | `agent_devshell.py` spawns a user-manager unit on unmetered links | disable the warm-up in the unit (`AGENT_DEVSHELL_NO_WARMUP`), or `PAMName=login` on the agent unit so `user@<uid>` exists; prefer disable |
| memory pressure kills `t3` instead of agents | the agent is no longer in T3's slice; `ManagedOOMPreference=avoid` on `t3code.service` already (`agent-t3code.nix:631`) | `ManagedOOMMemoryPressure=kill` on `agents-<proj>.slice` |

### 3.5 nixosTest (`checks.t3code-broker`)

Same VM as stage 1 plus two projects `alpha` and `beta`, each with a bare origin, a `t3`-owned
clone, one worktree created by `git worktree add` **as `t3`** (standing in for T3), and a fake
provider pinned as `argv[0]` for the test: a script that echoes `id -u`, `$HOME`, `$PWD`,
`$CLAUDE_CONFIG_DIR`, `env`, then copies stdin to stdout, then runs a list of probes and reports
each result on stdout. Driving it through the real wrapper as `t3` with `systemd-run --user --scope`
(what T3 does). Assertions:

1. **Identity**: uid is `agent-alpha`, `HOME=/var/lib/agents/alpha`, `PWD` is the worktree.
2. **Pipe**: `echo ping | wrapper … | grep ping` round-trips (stdio passthrough across UIDs).
3. **Env**: `SSH_AUTH_SOCK`, `GH_TOKEN`, `AWS_*`, `LD_PRELOAD` set in the caller's env are absent
   inside; `CLAUDE_CONFIG_DIR` and `T3CODE_THREAD_ID` are present.
4. **Filesystem**: `ls /var/lib/t3code/projects/beta` → EACCES (group) *and* ENOENT (not bound);
   `ls /home`, `/var/lib/t3code/.t3/userdata/statev2.sqlite` → ENOENT; `cat
   /var/lib/t3code/.t3/userdata/attachments/x.txt` → ok; `touch /var/lib/t3code/.t3/userdata/attachments/y`
   → EROFS; `touch /etc/x`, `/nix/store/x` → EROFS; `touch <worktree>/new && stat -c %G <worktree>/new`
   → `proj-alpha` and group-writable.
5. **Git both ways**: inside the unit `git -C <worktree> commit --allow-empty -m x` succeeds; then
   as `t3`, `git -C <worktree> status --porcelain=2` and `git worktree remove` succeed; a second
   worktree created by `t3` after the agent's commit is readable by the agent.
6. **Lifetime**: start a sleeping provider, `kill -KILL` the wrapper's process group as `t3`;
   within 20 s `systemctl list-units 'agent-alpha-*'` is empty and the sleep's pid is gone.
7. **Caps**: `cat /sys/fs/cgroup/agents-alpha.slice/memory.max` equals the configured value; the
   unit's cgroup is under it; `TasksMax` enforced (fork bomb returns EAGAIN).
8. **Network**: `curl --max-time 3 http://127.0.0.1:<t3 port>/` connects (any response);
   `curl 10.0.2.2` (QEMU host) fails with network unreachable/denied.
9. **Broker policy**: a request with `cwd=/tmp` → refused; `cwd=<alpha worktree>` with
   `CLAUDE_CONFIG_DIR=/var/lib/agents/beta/claude` → refused; `argv[0]=/bin/sh` → refused; a
   connection from a non-`t3` user → `connect` EACCES (socket mode).
10. **Terminal**: `t3-terminal-shell -c 'id -u'` under `script -q` (a PTY) → `agent-alpha`.

Only the assertions above involving T3 behaviour (worktree naming, attachments path, `kill 0`) are
stand-ins; a second, opt-in test runs the real `t3 serve` with the fake provider pinned by policy
if `t3ctl thread launch` turns out to work headlessly (stage-1 test 6).

---

## 4. Open questions for the owner

1. **`services.t3code` vs the repo's `preferences.*` convention.** You asked for `services.t3code`;
   the repo's features declare `preferences.<feature>`. I propose `services.t3code` for the
   reusable module (it looks like a NixOS service to a stranger) and keep `preferences.agents.t3code`
   as the nixconf-specific layer that sets policy, projects and desktop bits on top. Confirm.
2. **`t3.json` layout commands and setup scripts run as `t3`.** In stage 2 that is the one path from
   an agent user to the orchestrator user, gated by a UI approval. Options: (a) accept, with the
   rule "never approve a `t3.json` command you did not write"; (b) lock it off in policy if a key
   exists; (c) treat `t3` itself as the thing layer 4 fences (it already has no root, no owner
   secrets; its exposure is the other projects' clones and its own PAT/logins). My recommendation
   is (c) plus (a): the boundary that matters is owner ↔ agents, and stage 1 already gives it.
3. **Who pushes.** T3 can commit, push and open PRs server-side as `t3` (`GitManager.ts:3209-3222`),
   or agents push as `agent-<proj>` with `agent-push`. One set of write credentials per project
   user (research §3.3 table) and read-only tokens for `t3`'s background fetches is the clean split,
   but it disables T3's own push and PR buttons. Decide per project or globally.
4. **Per-project instances in the model picker.** Stage 2 means choosing `claude-nixconf` for a
   nixconf thread; the broker refuses the wrong one. Acceptable, or should the broker instead
   *override* `CLAUDE_CONFIG_DIR` from the cwd and we accept that T3's resume/history views read a
   different directory than the agent wrote (they would mostly degrade, not break: the CLI reads its
   own transcripts for `--resume`) [verify what `getSessionMessages` on resume is used for,
   `ClaudeAdapterV2.ts:1763-1774`]?
5. **Stage 1 user name and home.** Research §3.3 says `agent`, `/home/agent`; this doc says `t3`,
   `/var/lib/t3code`, since in stage 2 the agents are not that user. `/var/lib` fits a system
   service; `/home` fits `ssh t3@localhost` editor access. Pick one before the sops/age and
   `workspace-bootstrap` work lands on it.
6. **hazel.** Same as research §7 Q7: system unit from boot with `ConditionACPower`, or a polkit
   rule letting the owner start/stop `t3code.service` from the launcher. I lean to the polkit rule.
7. **Where the broker lives.** Part of `services.t3code` (simplest) or its own `services.agent-broker`
   so OpenCode's and herdr's per-project units can use it too. I lean to its own module with
   `services.t3code.broker.enable` wiring it.

---

## 5. What was not checked

- `packages/shared` (`agentScopeCommand`, `resolveCommandPath`, `HostProcess`) and
  `apps/server/src/sourceControl` were not in the sparse clone; behaviour described from call sites.
- Whether `systemd-run --user` probes pass inside a `PAMName=login` system unit (stage 1 scopes).
- Whether `t3ctl thread launch` can start a thread against a fake provider without a model call
  (decides whether the nixosTests drive real T3 or stand-ins).
- Whether Claude Code honours `CLAUDE_CODE_TMPDIR` for its scratchpad as well as task output.
- OpenCode v2 external-server auth settings; Codex is not installed here and was read only.
- Line numbers are against v0.1.13 source; the deployed `t3` is v0.1.9.
