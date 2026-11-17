# OpenCode integration — specification (2026-11-17)

Companion to `2026-11-17-agentic-workspace-design.md` and the T3 Code spec
(`2026-11-17-t3code-integration.md`, written in parallel). Goal: configure
OpenCode as declaratively as possible, integrated with the Nix store and the
agent-host / agent-client split, so that the T3 Code vs OpenCode comparison is
fair: both get the same care.

**How claims are marked**
- **[src]**: checked in the OpenCode source, `anomalyco/opencode` @ `a0777f3`
  (branch `dev`, 2026-11-17, just after v2.3.0). Paths are relative to the repo root.
- **[docs]**: the v2 docs, which live in the repo under
  `services/site/src/docs/content/<page>.mdx` (published at
  `https://opencode.ai/v2/docs/<page>`). Cited as `docs:<page>`.
- **[hm]**: Home Manager `modules/programs/opencode.nix`, release-26.05 vs master
  (master @ `9d7ba6b`, 2026-11-16).
- **[verify]**: inferred and not tested. Listed again in §9.

Current repo state (read only, not edited here): `features/agent-common.nix`
enables `programs.opencode` with **OpenCode 1.x** (`llm.opencode` = 1.19.5), the
V1 config shape (`autoupdate`, `provider.llama-swap.npm`, a placeholder model) and
`enableMcpIntegration`. `features/agent-t3code.nix` points T3 Code's `opencode`
provider at `/etc/profiles/per-user/hfahmi/bin/opencode`. This spec recommends
moving to **2.x**. Reasons are in §1.4 and §7.1.

---

## 1. What OpenCode is now (2.x)

### 1.1 Release line

- **V2 is the current line.** The repo CHANGELOG starts at v2.0.26 (2026-10-08) and is
  at **v2.3.0 (2026-11-13)**: 19 releases in five weeks, often several a week.
  [src: `CHANGELOG.md`]
- V1 and V2 both install the `opencode` binary and no longer coexist by default
  [docs:migrate-v1]. Builds you can use:
  - nixpkgs **26.05**: `opencode` **1.15.10** (V1).
  - nixpkgs **unstable**: `opencode` **2.2.6** (V2). Built from source, ships
    `passthru.jsonschema.{cli,config,theme}`, and its wrapper sets
    `OPENCODE_DISABLE_AUTOUPDATE=true`.
  - **llm-agents.nix** (pinned in our flake.lock): `opencode` **1.19.5** (V1) and
    `opencode2` **2.3.0** (V2). `opencode2` is the npm Bun binary, renamed to
    `opencode2`, with no jsonschema passthru and no autoupdate guard.
    [src: `packages/opencode2/package.nix`, `hashes.json` in the llm-agents store path]
  - The upstream flake (`nix/opencode.nix`) builds with `OPENCODE_CHANNEL=prod`.
    That channel uses a different service port and file name (see §4.1), so don't use it.
- **Three intentional V1 to V2 breaks** [docs:migrate-v1]:
  1. New plugin API. V1 plugins don't run.
  2. New server API and clients (`@opencode/client`). `attach` is replaced by `--server <url>`.
  3. Terminal client config moved from layered `tui.json` files to **one global
     `~/.config/opencode/cli.json`**. It is auto-migrated once, only if `cli.json` doesn't exist yet.

  V1 server config (`opencode.json`) is still read and normalized in memory. The
  native V2 shape is optional but clearer (§2).

### 1.2 Architecture [docs:cli/index, docs:troubleshooting, src: `packages/cli/src/server-process.ts`, `packages/client/src/effect/service.ts`]

```
                 ┌──────────── one background server per user ("service") ─────────────┐
 opencode (TUI) ─┤  owns sessions, config, providers, MCP, permissions, tool execution,   │
 opencode mini  ─┤  snapshots, worktrees, PTYs; HTTP API + embedded web UI; Basic auth    │
 web UI / PWA   ─┤  (user "opencode", password); SQLite ~/.local/share/opencode/opencode.db│
 desktop app    ─┤  registration: ~/.local/state/opencode/service.json (url,pid,version,pw)│
 T3 Code (v2)   ─┤  private cfg:  ~/.config/opencode/service.json (host,port,pw,env,cors)  │
 opencode run   ─┘                                                                         │
                 └──────────────────────────────────────────────────────────────────────────┘
 opencode acp  → always a private standalone server (stdio ACP), not the shared service
```

- **Shared background service.** Each client discovers the server through the
  registration file. If none is found, it spawns one with `opencode serve --service`,
  detached via `child_process.spawn(..., {detached:true})`. A client of a
  **different version** stops the running service (SIGTERM, then SIGKILL) and starts
  its own. [src: `packages/client/src/effect/service.ts` `ensure()` →
  `decide()` → `"replace"`; `service-contender.ts`]
- **Default address:** `127.0.0.1:49374` (0xC0DE) for the `latest` channel. Other
  channels get a hash-derived port and `service-<channel>.json`.
  [src: `packages/cli/src/services/service-config.ts` `defaultPort`, `filename`]
- **Service mode** (`serve --service`):
  - Reads hostname, port, password, CORS and env from `~/.config/opencode/service.json`.
    CLI flags `--hostname`, `--port` and `--cors` override them.
  - The password comes **only** from that file. If the file has none, the server
    generates a random one and writes it back.
  - The env map is merged into `process.env`.
  - If a compatible service already answers at the target URL, the new process exits 0.

  [src: `server-process.ts` `processEffect`]
- **Foreground mode** (`opencode serve`): uses `OPENCODE_PASSWORD` (or the legacy
  `OPENCODE_SERVER_PASSWORD`), or prints a random password. It does **not** register
  as the shared service. `--standalone` on any client runs a private server. All modes
  share the same SQLite DB. [src: `server-process.ts`, `packages/cli/src/env.ts`]
- **Clients:**
  - full-screen TUI: `opencode [dir]`
  - `opencode mini`: minimal TUI with scrollback replay
  - `opencode run`: scripting and CI. Options: `--format json`, `--auto` (approve
    anything not denied), `--archived`, `-w/--worktree[=name]`, `--session`, `--continue`
  - embedded **web UI** on the same port. It has an inbox, projects, worktree
    picker, mobile composer dock and PWA assets (`sw.js`).
  - the **desktop app** (Electron). Not packaged for NixOS here, and not needed.
  - **SDK**: `@opencode/client` (V2 HTTP API, OpenAPI at `/openapi.json`) and
    `opencode api <operationId|METHOD path>`.
  - **ACP**: `opencode acp`, for Zed. Always starts a *private* local server.
    [src: `packages/cli/src/commands/handlers/acp.ts` → `Standalone.start()`]

  [docs:cli/commands, docs:cli/web]
- **Pairing:**
  - `opencode pair` prints one-time links (5 min) and a QR code. They set a 30-day
    cookie in a browser or in the app.
  - `opencode pair --remote` exposes the server **to the internet** through
    OpenTunnel. **Don't use it here. We have Tailscale.** [docs:cli/web]
- **Gone in V2:** session sharing (the `/share` backend was retired in 2.0.30, but
  the `share` key is still in the schema), LSP execution (`lsp` config is accepted but
  **no language servers, LSP tools or diagnostics run**), and the `CLAUDE.md`
  fallback. [CHANGELOG 2.0.30; docs:migrate-v1 "Supported fields without direct
  native equivalents"; docs:instructions]

### 1.3 State locations: declarative vs mutable

| Path | Owner | Contents | Nix stance |
|---|---|---|---|
| `~/.config/opencode/opencode.json` | **HM** | server config (global layer) | read-only store symlink. OpenCode hot-reloads it [docs:commands "Loading"] |
| `~/.config/opencode/opencode.jsonc` | app (if created) | wins over `.json` | must not exist. First-run check |
| `~/.config/opencode/{agents,commands,skills,themes,plugins}/` | **HM** | file-based definitions | store symlinks |
| `~/.config/opencode/AGENTS.md` | **HM** | global instructions | store symlink |
| `~/.config/opencode/cli.json` | app | TUI settings. The TUI rewrites it from its settings dialog | **don't manage it.** Use `OPENCODE_CLI_CONFIG_CONTENT` instead (merged over `cli.json`, authoritative while set) [docs:cli/config "Inline config"] |
| `~/.config/opencode/service.json` | app (0600) | service host, port, **password**, CORS, env | activation **merge** of managed keys, like `claude-settings-merge` (§7.5) |
| `~/.local/state/opencode/service.json` | server | registration (url, pid, version, password) | never touch |
| `~/.local/share/opencode/opencode.db` | server | sessions, **credentials** (API keys, OAuth), projects (incl. **worktree startup command**), **saved "allow always" approvals**, plugin storage | mutable. Back it up. `OPENCODE_DB` overrides the path [docs:cli/providers "Storage", docs:troubleshooting] |
| `~/.local/share/opencode/snapshot…` | server | internal git object DB for undo | can grow on big repos (§5.4) |
| `~/.local/share/opencode/worktree/<proj6>/` | server | default worktree parent | or set `worktree.directory` |
| `~/.local/share/opencode/repos/` | server | clones for `references` | |
| `~/.local/share/opencode/log/opencode.log` | server | logs (`role=server`, `run=`) | |
| `/etc/opencode/opencode.json` + `agents/ commands/ skills/ plugins/` | **NixOS** (`environment.etc`) | *system* layer: **highest precedence**, policies outrank everything | option for hard guards (§2.9) |

`opencode debug paths [db|data|config|state|log|repos|…]` prints each one
[docs:cli/index "Paths"].

### 1.4 Why 2.x and not the current 1.x baseline

- T3 Code 0.1.9 has a dedicated **OpenCode 2 driver**. It can connect to an existing
  V2 server (`serverUrl` + `serverPassword`) or manage the shared V2 service
  (`serve --service`). [src t3code: `packages/provider-opencode/src/server/v2/*`,
  `versionProbe.ts` classifies by major version]
- Only V2 has:
  - background subagents. Each child gets **its own session and transcript**, which
    addresses the "interleaved subagent transcript" pain point.
  - worktree tools and per-project startup commands
  - the inbox, mobile web UI and multi-server desktop app
  - the `claude-agent` provider (Claude subscription through the official Claude Code
    binary, §3.1)
  - `herdr`-aware tabs (`tabs.mode: "auto"` hides tabs inside Herdr
    [docs:cli/config "Tabs"])
- V1 is in maintenance. A fair comparison should test the product people actually use in Nov 2026.

---

## 2. Settings reference (relevant subset)

Full schema: `packages/schema/src/config.ts` (`Config.Info`) [src]. Keys below are
**native V2**. HM writes them verbatim into `opencode.json`.

### 2.1 Top level (`opencode.json`)

| Key | Set to | Why | Ref |
|---|---|---|---|
| `$schema` | auto-added by HM | editor validation | [hm] |
| `update` | `"disable"` | Nix owns updates. Global only; the project value is ignored. Also set the `OPENCODE_DISABLE_AUTOUPDATE=1` env guard (§7.1) | docs:config "Updates"; src `packages/cli/src/services/updater.ts:608` |
| `share` | `"disabled"` | sharing backend is gone. Harmless explicit off | src `config.ts` |
| `model` | `"claude-agent/opus"` | default for new sessions (§3). The root model **drops `#variant`** | docs:models "Defaults" |
| `default_agent` | `"build"` | explicit | docs:agents |
| `snapshots` | `true` (global). `false` in projects with huge untracked trees if size bites | undo/redo | docs:snapshots |
| `permissions` | ordered array (§2.3) | last match wins | docs:permissions |
| `policies` | hard denies (§2.3) | cannot be overridden by a project or by "allow always" | docs:policies, docs:permissions "Policies" |
| `agents` | overrides + custom (§2.4) | model routing | docs:agents |
| `commands` | prefer files (§2.5) | | docs:commands |
| `instructions` | `[]` globally | AGENTS.md is loaded anyway | docs:instructions |
| `skills` | extra dirs, e.g. superpowers (§7.4) | | docs:skills |
| `mcp` | `{ timeout, servers }` (§2.6) | V2 shape: `mcp.servers.<name>` | docs:mcp-servers |
| `formatter` | unset globally. Per project with `direnv exec` (§2.7) | the server PATH lacks devShell tools | docs:formatters |
| `watcher.ignore` | per project (§6) | huge trees | docs:config "Watcher" |
| `worktree.directory` | default, or per project (§5) | | docs:config "Worktrees" |
| `compaction` | `{ auto = true; keep.tokens = 20000; buffer = "15%"; }` | long agent runs | docs:compaction |
| `tool_output` | default (2000 lines / 50 KB) | | docs:config "Output" |
| `websearch.provider` | unset (asks once), or `"tavily"` etc. with a sops key | | docs:websearch |
| `warming` | **off** (default) | it would spend subscription or API budget keeping caches warm | docs:warming |
| `plugins` | absolute **Nix store directories** only (§7.6). No npm names | npm plugins are installed at runtime (impure) | docs:plugins; src `packages/core/src/plugin/module.ts` |
| `references` | per project (§6) | named external context | docs:references |
| `providers` | `peacelily` (+ optional `anthropic`, `claude-agent` tweaks) (§3) | | docs:providers |
| `experimental` | `{ subagent_depth = 2; }` if orchestrators nest. Consider `todo = true` | | docs:config "Experimental"; src `packages/schema/src/config/experimental.ts` |
| `lsp` | **don't set** | V2 ignores it | docs:migrate-v1 |
| `username`, `timezone`, `enterprise` | not needed | | src |

**Variables:** `{env:NAME}` and `{file:path}` work inside any string. A missing
value becomes an empty string. [docs:config "Variables"]

### 2.2 Environment variables (server process) [src: grep `OPENCODE_*` across `packages/`]

| Var | Use here |
|---|---|
| `OPENCODE_DISABLE_AUTOUPDATE=1` | belt and braces with `update:"disable"` (nixpkgs-unstable sets it, llm-agents does not) |
| `OPENCODE_DISABLE_FREE_MODELS=1` | hides "free" OpenCode Zen models, so code is never sent to them by accident [docs:models "Free models"] |
| `OPENCODE_CLI_CONFIG_CONTENT='{…}'` | declarative TUI settings (§2.8) |
| `OPENCODE_CLAUDE_PATH` | absolute path of the `claude` binary for `claude-agent` (§3.1) |
| `OPENCODE_PASSWORD` | used by `opencode --server …` clients and foreground `serve`. **Ignored in `--service` mode** [src] |
| `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG_CONTENT` | extra config layers. Not needed |
| `OPENCODE_DISABLE_PROJECT_CONFIG=1` | skip project config and AGENTS.md. Not wanted |
| `OPENCODE_DISABLE_CLAUDE_CODE(_SKILLS)=1` | stop reading `~/.claude/skills` and `.claude/skills`. **Keep reading them** (§7.4) |
| `OPENCODE_DB`, `OPENCODE_LOG_LEVEL`, `OPENCODE_DISABLE_FILEWATCHER`, `OPENCODE_MODELS_URL`/`_PATH`, `OPENCODE_DISABLE_MODELS_FETCH` | diagnostics or offline only |
| `HTTP(S)_PROXY`, `NO_PROXY` (must include loopback), `NODE_EXTRA_CA_CERTS` | not needed [docs:network] |

### 2.3 Permissions and policies [docs:permissions, docs:policies]

- **Rule shape:** `{action, resource, effect}`. Rules come from lower-precedence
  config first, then global, then the agent's own. **The last match wins.** With no
  match the effect is `ask`.
- **Default base policy:** allow everything, except `*.env` / `*.env.*` reads, which ask.
- **`external_directory` is *allowed* by default in V2.** V1 asked. Add an `ask`
  rule to restore the V1 behaviour.
- **Actions:**
  - built-ins: `read edit glob grep shell subagent skill question webfetch websearch external_directory execute`
  - MCP tools: `<server>_<tool>` (normalized name)
  - `bash` → `shell` and `task` → `subagent` (renamed from V1)
- **"Allow always"** saves *project-scoped* allow rules in the DB. They never
  override a configured `deny`.
- **Policies** run after the rules and the saved approvals. They can only turn an
  effect into `deny`. Global and system policies outrank project ones. This is the
  equivalent of Claude Code's `permissions.deny`.

Recommended global rules, mirroring `managedClaudeSettings` in `agent-common.nix`:

```jsonc
"permissions": [
  { "action": "external_directory", "resource": "*",            "effect": "ask"   },
  { "action": "external_directory", "resource": "~/work/*",     "effect": "allow" },
  { "action": "external_directory", "resource": "/nix/store/*", "effect": "allow" },
  { "action": "edit",  "resource": "/nix/store/*", "effect": "deny" },
  { "action": "shell", "resource": "git push *",   "effect": "ask"  }
],
"policies": [
  { "action": "tool.use", "resource": "shell:sudo *",     "effect": "deny" },
  { "action": "tool.use", "resource": "shell:doas *",     "effect": "deny" },
  { "action": "tool.use", "resource": "shell:rm -rf *",   "effect": "deny" },
  { "action": "tool.use", "resource": "shell:rm -r *",    "effect": "deny" },
  { "action": "tool.use", "resource": "shell:nix copy *", "effect": "deny" },
  { "action": "tool.use", "resource": "shell:git push --force*", "effect": "deny" },
  { "action": "tool.use", "resource": "shell:git push -f *",     "effect": "deny" }
]
```

The shell scanner splits compound commands, and rules apply to every subcommand and
every `cd` target [docs:permissions "Scanner"]. Unattended runs (`opencode run
--auto`) still honour `deny` and policies.

### 2.4 Agents [docs:agents; src `packages/schema/src/config/agent.ts`]

- **Built-ins:** `build` (primary, default), `plan` (primary; edits denied except
  `~/.opencode/plan`), `general` (subagent; cannot spawn), `explore` (read-only
  subagent). The hidden `title`, `summary` and `compaction` agents can be overridden
  by ID (`agents.title.model` replaces V1 `small_model`).
- **Fields:** `description`, `mode` (`primary|subagent|all`), `model`
  (`provider/model#variant`), `system` (or the Markdown body), `permissions`,
  `steps`, `hidden`, `color`, `disabled`. The `request` header/body overlay is stored
  but **not sent** yet.
- **Subagents** always run in the background, in child sessions. The parent gets
  reports when a child goes idle (2.3.0). Depth is set by `experimental.subagent_depth`
  (default 1).
- **File agents:** `~/.config/opencode/agents/<id>.md` and `.opencode/agents/<id>.md`.
  A nested path becomes a namespaced ID (`team/reviewer`). Use **V2 frontmatter
  only**: a file that mixes V1 and V2 fields is read as V2, and its V1 fields are
  ignored.

### 2.5 Commands [docs:commands]

- **Locations:** `~/.config/opencode/commands/*.md` and `.opencode/commands/*.md`.
  Nested paths become `/a/b`.
- **Frontmatter:** `description`, `agent`, `model`, `subagent` (`true` runs it as a
  background child).
- **Placeholders:**
  - `$ARGUMENTS` for the whole argument string; `$1..$n` for positional arguments,
    where the last one swallows the rest.
  - ``!`cmd` `` inlines shell output **outside the permission system**. Trusted text
    only.
- MCP prompts appear as `/<server>:<prompt>`.

### 2.6 MCP [docs:mcp-servers]

- **Server definition:** `mcp.servers.<name>`.
  - local: `{type:"local", command:[…], cwd, environment, disabled, codemode, timeout, protocol, pool}`
  - remote: `{type:"remote", url, headers, oauth|false, …}`
- **Defaults:**
  - Code Mode is on by default: tools are grouped behind `execute`, which keeps context small.
  - `mcp.timeout.{startup,catalog,execution}` default to 30 s / 30 s / 12 h.
  - Set `pool: true` (2026-07-28 protocol only) to share one connection across projects.
- **Behaviour in a project:**
  - A project server with the same name **replaces** the whole global object.
  - Local servers run with the server's PATH. Wrap devShell-dependent servers in
    `direnv exec <dir>` (§6).

### 2.7 Formatters [docs:formatters]

- **Off unless `formatter` is set.** `true` enables the built-ins, which run only if
  their executable is on the **server's** PATH. That includes `nixfmt` (we use
  alejandra), `prettier` (needs a `prettier` dep in package.json), `ruff`, `ktlint`
  and others.
- **Custom entries:** `{command:[…,"$FILE"], extensions:[…], environment, disabled}`.
  Commands run from the project directory.
- **Recommendation:**
  - Don't enable formatters globally. The repos have pre-commit or treefmt.
  - Per project, use `direnv exec` so the devShell's formatter is found (§6).

### 2.8 TUI / CLI settings (`cli.json` content) [docs:cli/config; schema `https://opencode.ai/v2/cli.json`]

Passed through `OPENCODE_CLI_CONFIG_CONTENT`. Nested objects merge over the app's
`cli.json`; scalars and arrays replace.

```json
{
  "theme": { "name": "catppuccin", "mode": "system" },
  "animations": false,
  "mouse": true,
  "session": { "thinking": "hide", "permissions": "prompt", "new_location": "launch", "tps": false },
  "tabs": { "mode": "auto", "scope": "cwd", "layout": "vertical", "indicators": "status" },
  "diffs": { "source": "branch", "view": "auto", "tree": true },
  "attention": { "notifications": true, "sound": false },
  "terminal": { "title": true, "copy": "select" },
  "highlights": false,
  "keybinds": { "leader": "ctrl+x" }
}
```

- **Theme:** `catppuccin`, `catppuccin-frappe` and `catppuccin-macchiato` are built
  in [src: `packages/tui/src/theme/v1.ts`]. `mode: "system"` follows the terminal's
  light/dark (darkman switches foot).
- **Layout:** vertical tabs match the "vertical bar on the right" taste.
  `tabs.mode:"auto"` hides tabs inside Herdr.
- **Notifications:** `attention.notifications` gives native desktop notifications
  from the *local* TUI while the terminal is unfocused, even when connected to a
  remote server.

### 2.9 System layer (optional)

`/etc/opencode/opencode.json` has the **highest precedence**, and its `policies`
outrank everything [docs:config "Locations", docs:policies "Precedence"]. Putting
the deny policies there (`environment.etc."opencode/opencode.json"`) makes them
impossible to override from any project. Recommended on agent hosts: it is cheap
and declarative.

---

## 3. Providers and models

### 3.1 Claude subscription: the `claude-agent` provider [docs:claude-agent (noindex page); spec `specs/v2/claude-agent-provider.md`; CHANGELOG 2.2.3, 2.2.5]

**How it works**
- OpenCode runs the **user's installed `claude` binary** through Anthropic's
  **Claude Agent SDK**. It never reads Claude Code's saved login and never proxies its
  traffic. Log in with `claude auth login` on each host, then run
  `opencode auth login claude-agent` (or `/connect`, then **Claude Agent**).
- Requires Claude Code **≥ 2.1.248**. llm-agents `claude-code` is 2.1.326. Check the
  `claude-code` flake input too.
- **Models** come from Claude Code: `claude-agent/opus`, `claude-agent/sonnet`,
  `claude-agent/haiku` (plus `default`). Effort is selected with a variant:
  `claude-agent/opus#high`. The list is probed once and cached in the DB.
  [src: `packages/core/src/plugin/provider/claude-agent/{provider.ts,claude/probe.ts}`] [verify exact IDs with `opencode models claude-agent`]
- **What Claude gets:** Claude Code's system prompt plus the OpenCode agent prompt,
  AGENTS.md, skills and MCP instructions, and **OpenCode's tools and permissions**.

**What is turned off inside the `claude` process**
- Claude Code's built-in tools
- `~/.claude` settings, CLAUDE.md files, hooks, MCP servers, plugins and skills
- auto-memory, auto-compaction and the advisor tool
- Tool calls run **one at a time** (no parallel tool calls).

**Billing**
- Usage draws on the subscription. Anthropic paused the planned separate "Agent SDK
  credit" on 2026-06-15. Its support site says *"Claude Agent SDK, claude -p, and
  third-party app usage still draw from your subscription's usage limits"*
  ([letsdatascience](https://letsdatascience.com/news/anthropic-pauses-claude-agent-sdk-billing-overhaul-1cff2071)).

**ToS caveat (be honest about it)**
- Anthropic blocked subscription OAuth outside its own apps on 2026-01-09, and sent
  OpenCode legal requests in March 2026 (Anthropic OAuth removed).
- The Claude Agent route avoids those mechanisms (official binary, public SDK). It
  shipped on 2026-10-30, but there is **no explicit Anthropic endorsement**.
  ([falcao.org](https://falcao.org/posts/anthropic-claude-access-crackdown-ecosystem-fallout/),
  [bito.ai](https://bito.ai/ai-tools/opencode-vs-claude-code-a-2026-comparison-after-the-oauth-split/))
- T3 Code's Claude driver also runs the official Claude Code. The policy risk is
  similar for both. What differs is the harness:
  - T3 Code runs *real Claude Code*: its tools, CLAUDE.md, plugins and hooks.
  - OpenCode runs a *Claude model inside OpenCode's harness*.
- Keep that in mind when judging output quality in the trial.

**Nix specifics**
- Set `OPENCODE_CLAUDE_PATH` to the **unwrapped** binary (`${claudePkg}/bin/claude`),
  not the HM `--plugin-dir` wrapper. The SDK passes its own flags and settings.
  [verify that the wrapper also works]
- One `claude` child process per active Claude session. Budget roughly 300–500 MB
  each inside `agents.slice`. [verify]
- `claude-agent` is **not available in remote workspaces**. It must run on the same
  machine as the OpenCode server, so log Claude in on every agent host.

### 3.2 Anthropic API key (fallback / burst) [docs:providers, docs:cli/providers "Environment"]

- The built-in `anthropic` provider reads `ANTHROPIC_API_KEY` from the **server
  process env**.
- Put it in sops (`secrets/shared/agents.yaml` key `anthropic-api-key`). Render an
  env file and pass it as `EnvironmentFile=` to the user unit (§7.5). It is **not**
  stored in the DB.
- Don't use `opencode auth login anthropic --method key` for this: that writes the
  key into SQLite.
- Model IDs: `anthropic/claude-opus-5-5`, `anthropic/claude-sonnet-5-5`,
  `anthropic/claude-haiku-5-5`.
- Optional `providers.anthropic.settings.cache.ttl = "1h"` for long sessions. Writes
  cost 2× instead of 1.25× [docs:models "Cache lifetime"].

### 3.3 Local models: llama-swap on peacelily [docs:models "Compatible", "Reasoning"; docs:providers "Custom", "Timeouts"]

There is no auto-discovery for generic OpenAI-compatible servers (only Ollama, LM
Studio and vLLM have it). List the models explicitly:

```jsonc
"providers": {
  "peacelily": {
    "name": "peacelily (llama-swap)",
    "package": "@opencode/ai/providers/openai-compatible",
    "settings": {
      "baseURL": "http://peacelily:9292/v1",
      "headerTimeout": 600000          // llama-swap cold start: healthCheckTimeout = 600 s
    },
    "compatibility": { "reasoningField": "reasoning_content" },
    "models": {
      "qwen-coder": {
        "modelID": "qwen3.5:9b-coding", "name": "Qwen3.5 9B coding (128k)",
        "capabilities": { "tools": true, "input": ["text"], "output": ["text"] },
        "limit": { "context": 131072, "output": 16384 },
        "cost": { "input": 0, "output": 0 }
      },
      "qwen-moe": {
        "modelID": "qwen3.5:35b-a3b", "name": "Qwen3.5 35B-A3B",
        "capabilities": { "tools": true, "input": ["text"], "output": ["text"] },
        "limit": { "context": 16384, "output": 4096 },   // raise after peacelily change below
        "cost": { "input": 0, "output": 0 }
      },
      "qwen-small": {
        "modelID": "qwen3.5:4b", "name": "Qwen3.5 4B (titles, summaries)",
        "capabilities": { "tools": false, "input": ["text"], "output": ["text"] },
        "limit": { "context": 16384, "output": 1024 },
        "cost": { "input": 0, "output": 0 }
      }
    }
  }
}
```

**Caveats**
- **Context size.**
  - OpenCode's system prompt, tool schemas and AGENTS.md (routelab's is 31 KB, about
    8k tokens) need **≥ 32k**. 64k+ is better.
  - The 16k entries are only fit for titles and summaries.
  - `compaction.buffer` is a percentage of the model's window, so small windows
    compact constantly.
- **Bugs in `features/ai-server.nix`, to fix on peacelily (not done here):**
  - `"--no-mmproj" + "--ctx-size 131072 "` is missing a space. It produces
    `--no-mmproj--ctx-size`, so the 128k context is probably **not** applied.
  - The `9b-coding` entry omits `--jinja`. Tool calling needs the Jinja chat
    template. Newer llama.cpp enables it by default [verify on the pinned llama.cpp].
  - Raise `qwen3.5:35b-a3b` to `--ctx-size 65536` if VRAM allows.
- **Reasoning field.** llama-server streams reasoning as `reasoning_content` (the
  default `--reasoning-format`). `compatibility.reasoningField` makes OpenCode read it
  and send it back.
- **Offline behaviour.** If peacelily is down, the static models are still listed,
  and requests fail with a transport error after retries (3× retry). Nothing
  auto-hides them. That is acceptable: pick another model.
- **Tool-call quality** of 4–9B models on OpenCode's tool set is weak. Use local
  models for read-only exploring, titles, commit messages and docs, not for
  multi-file edits.

### 3.4 Per-agent model routing (recommendation)

| Agent | Model | Rationale |
|---|---|---|
| root `model` / `build` | `claude-agent/opus` | main engine, subscription |
| `plan` | `claude-agent/opus#high` | design work |
| `explore` (built-in subagent) | `claude-agent/haiku` | cheap, parallel search. Swap to `peacelily/qwen-coder` when at home |
| `title`, `summary` (hidden) | `claude-agent/haiku` | always reachable. `peacelily/qwen-small` is the at-home option, but titles fail when away (no fallback chain) |
| custom `local` (primary) | `peacelily/qwen-coder` | free, offline from the cloud, no subscription. For mechanical tasks |
| custom `reviewer` (subagent) | `claude-agent/sonnet` | second opinion, edits denied |
| `compaction` | inherits the session model | quality matters |

A command's `model` overrides the agent's model, and the agent's model overrides
the session's [docs:commands "Execution"].

---

## 4. Remote and multi-machine

### 4.1 Topology

```
 hazel (client)                                      butternut / peacelily / maple / AWS (agent-host)
 ─────────────                                       ───────────────────────────────────────────────
 browser / phone ─https─► tailscale serve :8443 ──► 127.0.0.1:49374  opencode serve --service
 opencode --server https://<host>.<tailnet>.ts.net:8443 ───────┘       (systemd user unit, agents.slice)
 herdr --remote <host> ── ssh ─► herdr server ─► local `opencode` TUIs (discover the same service)
 T3 Code UI ──────────────────► t3 serve ──── serverUrl=http://127.0.0.1:49374 ──┘ (same sessions)
```

**Bind loopback, front it with `tailscale serve`.** This differs from the T3 module,
which binds the tailnet IP. Reasons:
1. The **service mode** reads `hostname` from `service.json`. Any client-spawned
   fallback service then uses the same address as the systemd unit. With per-unit
   flags, a TUI-spawned service would bind `127.0.0.1:49374` *next to* the unit's
   `100.x:49374`, and the registration file would flip between them. [src]
2. HTTPS through MagicDNS certs gives the web UI a **secure context** on the phone
   (PWA, service worker, clipboard). Plain `http://100.x` does not. [verify the PWA
   install on iOS Safari]
3. Nothing listens on a non-loopback interface, so café Wi-Fi is never a concern
   even if the firewall changes.

Alternatively, bind the Tailscale IPv4 like T3 Code. In that case also write
`hostname` into `service.json` (§7.5). Don't use both.

**Port** is 49374 for `latest`-channel builds (llm-agents `opencode2` is the npm
build; nixpkgs-unstable sets `OPENCODE_CHANNEL=latest`). The upstream flake
(`prod`) gets a hash-derived port. **First-run check:** `opencode service status`.

### 4.2 Auth

- Basic auth: user is always `opencode`; the password lives in `service.json`.
  Web sessions use a 30-day cookie, obtained via `opencode pair --url
  https://<host>.<tailnet>.ts.net:8443` (one-time link and QR) or by entering the
  server address and password in the app. [docs:cli/web]
- One shared sops secret `opencode-password` (in `secrets/shared/agents.yaml`) is
  used on all hosts:
  - agent hosts merge it into `service.json`
  - hazel exports it as `OPENCODE_PASSWORD` for `opencode --server` (§7.5)
- Changing the password signs every web session out.
- CORS is only needed for a web client served from *another* origin. The embedded UI
  is same-origin even behind `tailscale serve`. [verify; if the UI rejects the
  proxied origin, set `cors` in `service.json`]

### 4.3 Attaching from hazel

- **Command:** `opencode --server https://butternut.<tailnet>.ts.net:8443
  ~/work/tfc/repos/d_abm`
  - The directory is a **server-side** path. Checkouts live at identical paths on
    every host.
  - Tools run on the server; hazel only renders. [src: `packages/cli/src/session-target.ts`]
- **Wrapper:** an `oc` script, `oc [target] [dir]`, resolves the target with
  `target <need>` and sets `OPENCODE_PASSWORD` from the sops file (§7.5).
- **Herdr route:** `herdr --remote <host>` runs a plain `opencode` on the host. It
  discovers the service locally, with no password needed, and inherits herdr's
  attention signals.
- **Phone:** open `https://<host>.<tailnet>.ts.net:8443`, which shows the inbox.
  Pair once.
- **Zed (ACP)** on hazel runs OpenCode **locally on hazel**: `opencode acp` always
  uses a private standalone server. Use it for small local edits only. For remote
  work, use the TUI, web UI or T3 Code. [src]

### 4.4 Bandwidth (Egypt)

- **Model traffic** goes target → provider. Hazel's uplink is not involved.
- **TUI ↔ server** is a JSON API plus an event stream: text deltas only.
- **Web UI assets:** first load is a few MB (brotli). After that they are served
  with `immutable` cache headers. [src: `packages/cli/src/services/web-ui.ts`]
- **Datasets** stay on the target, as the design doc says.

---

## 5. Parallel work streams

### 5.1 How OpenCode handles many streams [docs:agents, docs:cli/tui, CHANGELOG 2.2.x–2.3.0]

- **One server, many projects ("locations").** Each directory gets its own services.
  A location is unloaded after `experimental.location_idle_timeout` (default
  60 min). Running sessions keep it loaded.
- **Sessions are independent.** Many can run at once, across projects.
- **Where you see them:**
  - TUI tabs (`Ctrl+Tab`, scoped per cwd or globally), `Ctrl+O` for recent
    sessions and projects
  - the web **inbox** (Working / unread shelves; mark read/unread; failed-run
    indicators)
  - **steering** (Enter while running) and **queueing** (`Ctrl+X Enter`)
- **Subagents** are background child sessions with their own transcripts. The
  parent stays usable while several children run. This is a direct fix for "all
  subagent steps interleave in one chat".
- **Background shell** (`shell` tool with `background: true`) suits dev servers and
  emulators. Output is kept in a managed file.
- **Scripted streams:** `opencode run -w=<name> --archived --auto "…"` starts a
  session in a **new worktree**, kept out of the inbox. `--format json` gives NDJSON
  for orchestrators. `opencode api session.list` and `session.wait` let you poll.
- `opencode stats --project . --cost` gives per-project usage.

### 5.2 Worktrees [docs:config "Worktrees"; docs:build/plugins/server "Worktrees"; src `packages/core/src/worktree.ts`]

- **Built-in Git strategy.**
  - The new-session dialog lets you choose a project and a worktree (`Ctrl+Alt+O`,
    base branch `Ctrl+Alt+B`).
  - Code Mode tools `worktree_create`, `worktree_list` and `worktree_remove`;
    removal needs edit approval.
  - `opencode run -w`.
- **Location:** `worktree.directory` (relative to the canonical checkout), else
  `~/.local/share/opencode/worktree/<first 6 chars of project ID>/<name>`.
- **Startup command:** each project has a **startup script** in the DB
  (`Project.commands.start`).
  - Runs once per new worktree via `bash -lc`.
  - Env: `OPENCODE_WORKTREE_BASE` (source checkout) and `OPENCODE_WORKTREE_PATH`.
  - Set it in the web UI (Project settings, then Worktree) or with `opencode api
    project.update`.
  - This is the counterpart of T3 Code's `t3.json` setup script. It is **not in a
    file**, so seed it declaratively (§6.3).
- **Plugins** can replace the strategy (for example jj or copy-on-write). Not needed.

### 5.3 Compaction [docs:compaction]

- Automatic near the limit. Keeps about 15k tokens of recent context; we set 20k.
- Manual: `opencode api post /api/session/<id>/compact`.
- Native provider compaction is opt-in per provider/model
  (`settings.compaction.type: "native"`). Not needed for claude-agent: OpenCode
  disables Claude Code's own auto-compaction and does it itself.

### 5.4 Undo / snapshots [docs:snapshots]

- **`/undo` and `/redo`** (`<leader>u` / `<leader>r`) roll back the conversation *and*
  the attributed file changes. Select a message, then **Revert**, to go further back.
- **Snapshots cover** the session's active directory in a git worktree: tracked files
  plus non-ignored untracked files up to 2 MiB each. Ignored files are not captured,
  and neither are shell side effects.
- **Storage:** a separate git object DB under the data dir.
  - For routelab (1.1 GB `.git`, 6.4k tracked files) and d_abm (987 tracked files,
    `data/` and `output/` ignored) this should stay small.
  - Watch `du -sh ~/.local/share/opencode/snapshot*`.
- Snapshots are **not** a backup. Agents commit often, as the design doc says.

### 5.5 Honest comparison with T3 Code's worktree-per-thread model

| Aspect | OpenCode 2.3 | T3 Code 0.1.9 (per its spec / to verify there) |
|---|---|---|
| Default isolation | session in the project checkout; worktree is opt-in per session/run | worktree per thread is the core model |
| Setup hook | project `commands.start` (DB, UI or API) | `t3.json` setup script (committed file) |
| Subagent visibility | separate child sessions, background | depends on the engine (Claude Code subagents interleave) |
| Many projects in one UI | yes (web inbox, TUI tabs, desktop) | yes (inbox) |
| Engines | its own harness with any provider (claude-agent, API, local) | drives Claude Code / OpenCode / Codex as providers |
| Undo | per-message snapshot rollback | git-based (worktree per thread) |

OpenCode treats worktrees as a tool you reach for. T3 Code makes them the unit of
work. With OpenCode, the worktree-per-stream discipline comes from habit: always
start streams with `run -w` or the worktree picker, plus the seeded startup command.
In T3 Code it comes from structure.

---

## 6. Projects

### 6.1 Per-project files (committed in each repo; they name *needs*, never machines)

- `AGENTS.md` is loaded from the workspace up to the project root. Nested
  `AGENTS.md` files load lazily when the agent reads that area. **No CLAUDE.md
  fallback** [docs:instructions].
- `.opencode/opencode.jsonc` holds project config. **Pick one form**: `.opencode/`
  files override every direct `opencode.json` in the tree [docs:config "Locations"].
- `.opencode/{agents,commands,skills,plugins,themes}/`.
- `.claude/skills/` and `.agents/skills/` are read too (compatibility).
- `.mcp.json` (Claude format) is **not** read. Translate it into `mcp.servers`.

### 6.2 routelab-monorepo

**Facts:** flake + devenv, prettier ^3.8.1, a 31 KB AGENTS.md **and** a separate
32 KB CLAUDE.md (they have drifted), `.mcp.json` with `effect-docs` via `npx`,
Android app (emulator → butternut), k8s via ctlptl, docker-compose.

**Actions:**
- **Make `CLAUDE.md` a symlink to `AGENTS.md`**, as the design doc says. Otherwise
  OpenCode and Claude Code read different guidance, which skews the comparison. Don't
  add `CLAUDE.md` to `instructions`: that would double the context.
- Add `.opencode/opencode.jsonc`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "watcher": { "ignore": [".devenv/**", ".direnv/**", "node_modules/**", "**/node_modules/**",
                          ".android/**", ".ci-cache/**", ".ci-out/**", ".objects/**",
                          ".open-tiles/**", ".alchemy/**", "generated/**", "*.log"] },
  "formatter": {
    "prettier": { "disabled": true },
    "repo-prettier": { "command": ["direnv", "exec", ".", "pnpm", "exec", "prettier", "--write", "$FILE"],
                       "extensions": [".ts", ".tsx", ".js", ".json", ".md", ".yaml", ".yml"] }
  },
  "mcp": { "servers": {
    "effect-docs": { "type": "local", "command": ["direnv", "exec", ".", "npx", "-y", "effect-mcp@latest"] }
  } },
  "permissions": [
    { "action": "shell", "resource": "kubectl delete *", "effect": "ask" },
    { "action": "shell", "resource": "ctlptl delete *",  "effect": "ask" },
    { "action": "shell", "resource": "pnpm alchemy deploy *", "effect": "ask" }
  ]
}
```

- `.opencode/commands/`:
  - `android-run.md`: frontmatter `description: Build, install and smoke-test the
    Android app on the emulator`, `agent: build`. Body: "Run `target android` …; on
    the target start the emulator in the background shell …; `direnv exec .
    ./gradlew installDebug`; capture `adb logcat` for $ARGUMENTS."
  - `web-dev.md`: start the web dev server as a background shell, then verify with
    the Playwright MCP if it is enabled.
  - `k8s-up.md`: `ctlptl apply -f ctlptl-config.yaml`, then status. `subagent: true`.
- `.opencode/agents/android-tester.md` (subagent, `claude-agent/sonnet`). Only
  `shell` allowed for `adb *`, `./gradlew *` and `direnv exec *`; edits denied.
- `effect-docs` via `npx -y …@latest` is impure (npm at runtime). Accept it for now,
  or pin a version.

### 6.3 d_abm (MATSim on AWS Fargate)

**Facts:** Kedro / Poetry / Java, `data/ output/ tools/ simulation_output` ignored,
`infra/aws/bin/sim` is the per-run CLI (`stage → submit → wait|logs|status → fetch →
bundle`), a USD 150 budget, task defaults of 16 vCPU / 64 GB / 12 h, and **no
AGENTS.md**.

**Actions:**
- **Create `AGENTS.md`.** Cover: pipeline map from the README; "never run full MATSim
  locally; use `bin/sim` or `agent-run` with `-Xmx` caps"; S3 run layout; "`bin/sim
  submit` costs money: ask first"; how to read `status.json` and convergence series.
- `.opencode/opencode.jsonc`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "watcher": { "ignore": ["data/**", "output/**", "simulation_output/**", "tools/**", "reports/**",
                          ".synpp_cache/**", ".viz/**", "build/**", "infra/aws/node_modules/**", ".repos/**"] },
  "formatter": { "ruff-repo": { "command": ["direnv", "exec", ".", "ruff", "format", "$FILE"],
                                "extensions": [".py", ".pyi"] } },
  "references": { "routelab-infra": { "path": "../routelab-monorepo/infra/stack",
                                       "description": "Alchemy stack whose versions infra/aws mirrors" } },
  "permissions": [
    { "action": "shell", "resource": "infra/aws/bin/sim submit *", "effect": "ask" },
    { "action": "shell", "resource": "infra/aws/bin/sim bundle * --cloud", "effect": "ask" },
    { "action": "shell", "resource": "aws ecs run-task *", "effect": "deny" },
    { "action": "shell", "resource": "pnpm exec alchemy deploy *", "effect": "deny" },
    { "action": "shell", "resource": "kedro run --pipeline=matsim*", "effect": "ask" },
    { "action": "shell", "resource": "java *", "effect": "ask" }
  ]
}
```

- `.opencode/commands/`:
  - `sim-stage.md`: `infra/aws/bin/sim stage $1 $2`, e.g. `/sim-stage central 0.1`.
  - `sim-submit.md`: `agent: sim-operator`. Body requires a cost estimate before
    `bin/sim submit $1`.
  - `sim-watch.md`: `subagent: true`. Polls `bin/sim status $1` and `progress`, then
    reports. Use `bin/sim wait` with a background shell, not a busy loop. The
    experimental `automations` flag can run a timer prompt instead
    [src `packages/schema/src/config/flag.ts`].
  - `sim-fetch.md`: `bin/sim fetch $1 && bin/sim bundle $1`, then summarise the
    diagnostics.
- `.opencode/agents/sim-operator.md` (subagent, `claude-agent/sonnet`, `steps: 30`):
  - shell allowed only for `infra/aws/bin/sim *`, `aws s3 ls *` and `jq *`
  - edits denied
  - `bin/sim submit` stays `ask` (inherited)
- **Memory:** OpenCode itself is light. Local Kedro or MATSim runs started by the
  agent run inside the service's cgroup, which is `agents.slice` (§7.5). Tell the
  agent to use `agent-run` (a transient scope in the slice) for long jobs.

### 6.4 Registering and seeding projects declaratively

- Projects become known when a location is first opened. Their **worktree startup
  command** lives in the DB.
- A oneshot user unit `opencode-seed-projects` runs after `opencode.service`. For each
  entry in a Nix attrset `preferences.agents.opencode.projects`, it is idempotent:

```bash
# for each { dir, start }:
opencode api GET "/api/location?location%5Bdirectory%5D=$dir" >/dev/null   # registers project
id=$(opencode api project.list | jq -r --arg d "$dir" '.[] | select(.canonical==$d) | .id')
opencode api project.update --param projectID="$id" \
  --data "$(jq -n --arg s "$start" '{commands:{start:$s}}')"
```
  [src: `packages/protocol/src/groups/{location,project}.ts`; `packages/cli/src/commands/handlers/api.ts` param interpolation] [verify the query encoding]

- Startup commands:
  - **routelab:**
    `ln -s "$OPENCODE_WORKTREE_BASE/node_modules" . 2>/dev/null; ln -s "$OPENCODE_WORKTREE_BASE/.android" .; direnv allow .`
  - **d_abm:**
    `for d in data output tools simulation_output .synpp_cache; do ln -s "$OPENCODE_WORKTREE_BASE/$d" .; done; direnv allow .`
  - Share untracked data via symlinks and never copy it, as the memory note requires.
- Checkouts themselves stay out of scope: git clone per host, as in the design doc.

---

## 7. Nix integration

### 7.1 Package choice

**Recommended:** llm-agents `opencode2` (2.3.0), re-exposed as `opencode`.
- Already in our flake, deliberately *not* following nixpkgs, and served from
  cache.numtide.com.
- Fresh (V2 ships several releases a week).
- The npm Bun binary has `channel=latest`, so port 49374.
- T3 Code and the HM 26.05 `extraPackages` wrapper both expect `bin/opencode`. The
  26.05 wrapper hard-codes `$out/bin/opencode`.

**Trade-offs:**
- No `passthru.jsonschema`, so HM master's `validateFiles` can't be used.
  Mitigation: a flake check that validates the generated `opencode.json` against a
  pinned copy of `https://opencode.ai/config.json` (optional).
- No built-in autoupdate guard. We add it in the wrapper.

**Alternative:** nixpkgs-unstable `opencode` 2.2.6.
- Source-built, ships schemas, sets the autoupdate guard.
- Lags roughly a week, and would add a `nixpkgs-unstable` input. Pick it only if
  schema validation matters more than freshness.

**Not:** llm-agents `opencode` 1.19.5 (the current baseline: V1, and V1 config), or
nixpkgs 26.05's 1.15.10.

**Version lockstep matters.** A client of a different version replaces the running
service (§1.2). Every host and T3 Code must use **the same store path**, which one
flake.lock guarantees. The systemd unit's `ExecStart` path changes on update, so
sd-switch restarts it on activation.

### 7.2 HM module choice

- **HM release-26.05** `programs.opencode` options: `enable package extraPackages
  enableMcpIntegration settings tui web.{enable,extraArgs,environmentFile} context
  commands agents skills themes tools`.
  - It has **no `cli`, `mutableSettings` or `validateFiles`**.
  - `web` runs `opencode serve <extraArgs>` with `Restart=always`. That is the
    foreground mode: it does not register as the shared service, and its restart
    policy would loop if an incumbent exists.
  - The MCP integration emits the **V1** MCP shape (`mcp.<name>` with `enabled`).
- **HM master** adds:
  - `cli` (writes `cli.json`, or `OPENCODE_CLI_CONFIG_CONTENT` when `mutableSettings`)
  - `mutableSettings` (moves our layer to `home-manager.json` via `OPENCODE_CONFIG`)
  - `validateFiles.{config,cli,tui}`
  - `isOpenCode2` detection
  - DAG-ordered JSON
- **Plan:** stay on 26.05. Use `settings`, `context`, `commands`, `agents`, `skills`
  and `themes` (all fine with V2). Do **not** use:
  - `web`: write our own unit
  - `tui`: V2 ignores it
  - `tools`: V1 `tool()` files; V2 custom tools are plugins [docs:build/plugins/migrate-v1 "Migrate custom tools"]
  - `enableMcpIntegration`: we emit the V2 shape ourselves

  `mutableSettings = false` is the implicit 26.05 behaviour: HM owns `opencode.json`.
  Switch to HM master's `cli` / `validateFiles` when we move to HM 26.11.

### 7.3 Proposed module `features/agent-opencode.nix`

It replaces the `programs.opencode` block in `agent-common.nix`. It is
self-contained like `agent-t3code.nix` and follows `preferences.agents.role`.

```nix
# OpenCode 2 (design: docs/plans/2026-11-17-opencode-integration.md).
#   host:   shared background service (`opencode serve --service`) as a user unit in
#           agents.slice, on 127.0.0.1:49374, exposed to the tailnet via `tailscale serve`.
#   client: `oc` wrapper that attaches to preferences.agents.target.
{inputs, ...}: {
  flake.nixosModules.agent-opencode = {config, lib, pkgs, ...}: let
    agents = config.preferences.agents;
    cfg = agents.opencode;
    user = config.preferences.user.name;
    system = pkgs.stdenv.hostPlatform.system;
    llm = inputs.llm-agents.packages.${system};
    claudePkg = inputs.claude-code.packages.${system}.claude-code;
    userBin = "/etc/profiles/per-user/${user}/bin";

    cliSettings = { /* §2.8 JSON as Nix */
      theme = { name = "catppuccin"; mode = "system"; };
      animations = false;
      session = { thinking = "hide"; permissions = "prompt"; tps = false; };
      tabs = { mode = "auto"; scope = "cwd"; layout = "vertical"; indicators = "status"; };
      diffs = { source = "branch"; view = "auto"; tree = true; };
      attention = { notifications = true; sound = false; };
      terminal = { title = true; copy = "select"; };
      highlights = false;
    };

    # `opencode` with Nix-friendly defaults baked in (applies to TUI, service, T3, herdr).
    opencode = pkgs.symlinkJoin {
      name = "opencode-${llm.opencode2.version}";
      paths = [llm.opencode2];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        makeWrapper ${lib.getExe llm.opencode2} $out/bin/opencode \
          --set OPENCODE_DISABLE_AUTOUPDATE 1 \
          --set OPENCODE_DISABLE_FREE_MODELS 1 \
          --set OPENCODE_CLAUDE_PATH ${claudePkg}/bin/claude \
          --set OPENCODE_CLI_CONFIG_CONTENT ${lib.escapeShellArg (builtins.toJSON cliSettings)} \
          --prefix PATH : ${lib.makeBinPath [pkgs.git pkgs.direnv pkgs.jq pkgs.fd]}
      '';
      meta.mainProgram = "opencode";
    };

    # V2-shaped MCP servers from programs.mcp (HM 26.05 would emit the V1 shape).
    hmCfg = config.home-manager.users.${user};
    mcpServers = lib.mapAttrs (_: s:
      if s ? url && s.url != null
      then {type = "remote"; inherit (s) url;} // lib.optionalAttrs (s ? headers) {inherit (s) headers;}
      else {type = "local"; command = [s.command] ++ (s.args or []);}
        // lib.optionalAttrs ((s.env or {}) != {}) {environment = s.env;})
      hmCfg.programs.mcp.servers;

    plugins = import ./opencode-plugins.nix {inherit pkgs lib;}; # §7.6 (notify, direnv)
  in {
    options.preferences.agents.opencode = {
      projects = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {options = {
          dir = lib.mkOption {type = lib.types.str;};
          start = lib.mkOption {type = lib.types.lines; default = "";};
        };});
        default = {};
        description = "Projects registered with the OpenCode service and their worktree startup command.";
      };
      tailscaleServePort = lib.mkOption {type = lib.types.port; default = 8443;};
    };

    config = lib.mkMerge [
      {
        sops.secrets."agents-opencode-password" = {
          sopsFile = ../../.. + "/secrets/shared/agents.yaml";
          key = "opencode-password";
          owner = user;
        };

        home-manager.users.${user} = {
          programs.opencode = {
            enable = true;
            package = opencode;
            context = ./opencode/AGENTS.md;          # global rules (Nix purist, agent-run, commit often)
            agents = ./opencode/agents;              # reviewer.md, local.md (V2 frontmatter)
            commands = ./opencode/commands;          # global /review, /commit, /handoff
            settings = {
              update = "disable";
              share = "disabled";
              model = "claude-agent/opus";
              default_agent = "build";
              permissions = [ /* §2.3 */ ];
              policies = [ /* §2.3 */ ];
              compaction = { auto = true; keep.tokens = 20000; buffer = "15%"; };
              experimental.subagent_depth = 2;
              skills = ["${inputs.superpowers}/skills"];      # §7.4
              plugins = [ "${plugins.notify}" "${plugins.direnv}" ];
              mcp.servers = mcpServers;
              agents = {
                plan.model = "claude-agent/opus#high";
                explore.model = "claude-agent/haiku";
                title.model = "claude-agent/haiku";
                summary.model = "claude-agent/haiku";
              };
              providers.peacelily = { /* §3.3, baseURL = agents.llamaSwapUrl */ };
            };
          };
        };
      }

      (lib.mkIf (agents.role == "host") { /* §7.5 */ })
      (lib.mkIf (agents.role == "client") { /* §7.5 `oc` */ })
    ];
  };
}
```

Notes:
- `programs.mcp.servers` already contains `nixos` (mcp-nixos) and `git`
  (mcp-server-git) from agent-common, so OpenCode and Claude Code share them.
  Playwright MCP is a candidate for routelab, as the design doc says.
- HM 26.05 writes `settings` with `pkgs.formats.json`. Lists keep their order, so
  the ordered `permissions` and `policies` arrays are safe without HM master's DAG
  ordering.
- T3 Code's `providerInstances.opencode.config.binaryPath =
  "${userBin}/opencode"` keeps working with this wrapper. Add `serverUrl =
  "http://127.0.0.1:49374"` and the password so T3 Code **shares the service** instead
  of spawning its own `serve` (coordinate with the T3 spec).

### 7.4 Skills: shared with Claude Code

- Same format (`SKILL.md` + frontmatter `name`, `description`). OpenCode also honours
  `disable-model-invocation` and `metadata.opencode/autoinvoke`.
- V2 **reads `~/.claude/skills` and `.claude/skills` automatically**, at lower
  precedence than `~/.config/opencode/skills`. The anthropic-skills that HM
  `programs.claude-code.skills` installs therefore appear in OpenCode with no extra
  config. [docs:skills "Discovery", "Precedence"]
- Claude Code **plugins** (superpowers via `--plugin-dir`) are not seen. Add
  `"${inputs.superpowers}/skills"` to `settings.skills`.
- Some superpowers skills refer to Claude-Code-only tools (TodoWrite, Task). V2 has
  `subagent`, and `todowrite` only with `experimental.todo = true`. Expect partial fit.

### 7.5 Host: service unit, secrets, tailscale serve; client: `oc`

```nix
# role == "host"
{
  home-manager.users.${user} = {
    systemd.user.services.opencode = {
      Unit = {
        Description = "OpenCode 2 background service (TUI, web, T3 Code)";
        After = ["network-online.target"];
      };
      Service = {
        ExecStartPre = "-${lib.getExe opencode} service stop";   # evict a client-spawned stray (outside the slice)
        ExecStart = "${lib.getExe opencode} serve --service";
        Restart = "on-failure";          # NOT always: an incumbent makes us exit 0
        RestartSec = 5;
        Slice = "agents.slice";
        Environment = ["PATH=${userBin}:/run/current-system/sw/bin:/run/wrappers/bin"];
        EnvironmentFile = "-${config.sops.templates."opencode-env".path}";  # ANTHROPIC_API_KEY=… (optional)
      };
      Install.WantedBy = ["default.target"];
    };

    # Merge managed keys into the app-owned service.json (same pattern as claude-settings-merge).
    home.activation.opencodeServiceConfig = {
      after = ["writeBoundary"]; before = [];
      data = ''
        run ${pkgs.writeShellScript "opencode-service-merge" ''
          f="$HOME/.config/opencode/service.json"; mkdir -p "$(dirname "$f")"
          cur=$(${pkgs.jq}/bin/jq -e . "$f" 2>/dev/null || echo '{}')
          pw=$(tr -d '\n' < ${config.sops.secrets."agents-opencode-password".path})
          new=$(${pkgs.jq}/bin/jq --arg pw "$pw" '.password=$pw | .hostname="127.0.0.1" | .port=49374 | del(.remote)' <<<"$cur")
          [ "$new" = "$cur" ] && exit 0
          umask 077; printf '%s\n' "$new" > "$f.tmp" && mv -f "$f.tmp" "$f"
        ''}
      '';
    };
  };

  sops.templates."opencode-env" = {
    owner = user;
    content = ''ANTHROPIC_API_KEY=${config.sops.placeholder."agents-anthropic-api-key"}'';
  };

  # Expose loopback service to the tailnet over HTTPS (MagicDNS cert).
  systemd.services.opencode-tailscale-serve = {
    after = ["tailscaled.service"]; wants = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = "${lib.getExe config.services.tailscale.package} serve --bg --https=${toString cfg.tailscaleServePort} http://127.0.0.1:49374";
  };
}
```

```nix
# role == "client": oc [dir]  → attach to preferences.agents.target
home.packages = [(pkgs.writeShellScriptBin "oc" ''
  target=''${OC_TARGET:-${agents.target}}
  export OPENCODE_PASSWORD=$(cat ${config.sops.secrets."agents-opencode-password".path})
  exec ${lib.getExe opencode} --server "https://$target.<tailnet>.ts.net:${toString cfg.tailscaleServePort}" "''${@:-$PWD}"
'')];
```

Also on the host: the `opencode-seed-projects` oneshot (§6.4), with `After=` and
`Requires=opencode.service`.

**Why these choices**
- **The systemd unit is the service.** TUIs, herdr panes and T3 Code reuse it
  through the registration file because the version matches. A client-spawned service
  would be **detached into the client's cgroup** (the terminal's scope, outside
  `agents.slice`). `ExecStartPre=service stop` reclaims ownership when the unit
  starts. [src: `service-contender.ts` `detached:true`] [verify that `service stop`
  is harmless when nothing runs]
- **Tool shells are children of the server**, so every agent command started by
  OpenCode is accounted to `agents.slice`. Check with `grep agents.slice
  /proc/<pid>/cgroup`, as `agent-host.nix` describes.
- **Restarting the unit kills persistent PTYs.** `opencode service restart` hands
  them off; systemd does not. Accept this on rebuilds.
- **Secrets:**
  - password: sops, merged into a 0600 app file
  - API key: sops template passed as an env file; never in the store or the DB
  - Credentials from `opencode auth login` (OAuth, MCP OAuth) still land in SQLite.
    That is mutable state to back up, not something to declare.
- **Autoupdate** is disabled three ways: `update = "disable"`, the
  `OPENCODE_DISABLE_AUTOUPDATE` wrapper env, and a read-only store binary.

### 7.6 Plugins as Nix store directories (pure)

- Local plugin directories need no npm install: the host provides `@opencode/plugin`
  and `effect` at runtime. [src: `packages/plugin/src/runtime-modules.ts`
  (`runtimePackages`), `source.bun.ts` (`provides`)]
- Configured local entries must be **directories** containing `index.ts`. Use
  `pkgs.writeTextDir "index.ts" …` and reference its store path in `plugins`.
  [docs:plugins]
- **`notify`** (ntfy and desktop, reusing `agent-notify` from agent-common):
  - Subscribe with `ctx.event.subscribe({types: ["permission.asked", "form.created",
    "session.execution.succeeded", "session.execution.failed"]})`.
  - Event envelope: `{type, location?: {directory}, data: {sessionID, …}}`
    [src: `packages/schema/src/event.ts`, `permission.ts`, `session-event.ts`].
  - **Drop events whose `location.directory` ≠ `ctx.location.directory`.** Plugin
    instances are per location, and each one sees the whole stream, so without this
    filter every loaded project sends a duplicate notification.
  - Skip child sessions: `(await ctx.session.get({sessionID})).parentID`.
  - Notify with `spawn("agent-notify", [title, body])`.
  - The local TUI's `attention.notifications` already covers desktop
    notifications. The plugin adds phone (ntfy) coverage for sessions nobody is
    watching.
- **`direnv`:** `ctx.shell.hook("create.before", e => Object.assign(e.env, <cached
  "direnv export json" for e.cwd>))`.
  - The agent's shell then gets the project devShell (Android SDK, Java, Poetry, pnpm)
    with no `direnv exec` prefixes. nix-direnv makes repeat calls cheap.
  - OpenCode has **no** native direnv support (no `direnv` in the source).
    [docs:build/plugins/server "Shell"]
  - Until this plugin exists, AGENTS.md must tell agents to prefix devShell
    commands with `direnv exec .`.
- Both plugins are untested sketches (about 40 lines each). Build them during rollout.

### 7.7 What stays mutable (by design)

- the DB (sessions, credentials, saved approvals, project startup commands; the last
  is seeded but editable)
- `cli.json` (app-owned; our env var overrides it)
- `service.json` (merged)
- the snapshot and worktree dirs

Back up `~/.local/share/opencode/opencode.db` with the other agent state.

---

## 8. Daily workflows, comparison, trial

### 8.1 Daily flows (OpenCode variant)

1. **Morning on hazel:**
   - `target heavy` picks butternut.
   - Open `https://butternut.<tailnet>.ts.net:8443`. The inbox shows yesterday's
     streams, with unread markers.
   - Or `oc` in workspace-5 foot for the TUI. Vertical tabs, one per stream.
2. **New stream:**
   - Web UI: New session, choose the project, choose **new worktree**. The startup
     command symlinks the data and runs `direnv allow`.
   - Scripted: `oc` → `!opencode run -w=<name> --auto "…"`, or over ssh on the target.
3. **Orchestration:**
   - The parent session (`claude-agent/opus`) spawns `general` and `reviewer` background
     subagents. Each has its own transcript, and the parent keeps steering.
   - herdr shows raw panes when needed: `herdr --remote butternut`, where a plain
     `opencode` finds the local service.
4. **Android:** `/android-run login-flow` in a routelab session on butternut. Emulator
   in a background shell; the subagent reads logcat.
5. **Simulation:** `/sim-stage central 0.1`, then `/sim-submit <run>` (asks first),
   then `/sim-watch <run>` (background child; notifies via ntfy when done), then
   `/sim-fetch <run>`.
6. **Away from home:** the phone shows the same inbox. Answer permission prompts and
   questions from the mobile composer.
7. **Cheap tasks:** switch agent with `Shift+Tab` to `local` (peacelily). For example
   "write the changelog entry", "rename these tests".

### 8.2 T3 Code vs OpenCode (fair matrix)

T3 Code cells are based on the T3 module in this repo and its provider source. Where
they disagree, the T3 spec takes precedence.

| Criterion | OpenCode 2.3 | T3 Code 0.1.9 |
|---|---|---|
| UX model | TUI (tabs, mini), web inbox, desktop app. Sessions first; worktrees optional | web inbox. Threads first; worktree per thread |
| Claude subscription | via `claude-agent` (official binary, OpenCode's tools and prompt additions; Claude Code settings, hooks, plugins and CLAUDE.md **off**) | drives **real Claude Code** (its tools, CLAUDE.md, plugins, hooks) |
| Other engines | any provider: API keys, local llama-swap, Copilot, etc. | Claude Code, OpenCode (v1/v2), Codex as providers |
| Parallelism | many sessions per server; background subagents in separate transcripts; `run -w` | many threads; each thread is a worktree plus an engine process |
| Remote | one service per host; `--server` TUI from hazel; web UI; Basic auth with cookie pairing | `t3 serve` web on the tailnet |
| Phone | mobile composer dock, inbox, PWA (needs HTTPS → `tailscale serve`) | web UI (check the mobile UX in the T3 spec) |
| Notifications | native TUI attention; plugin events for ntfy | engine hooks (Claude Code hooks → agent-notify) |
| Nix fit | 2.x binary from llm-agents; config fully declarative except DB state (credentials, approvals, project startup cmd) and `service.json` merge; HM 26.05 lacks `cli` | HM `programs.t3code` (26.05 settings; server unit hand-written); `t3.json` is a committed file |
| Local models | first-class (custom OpenAI-compatible provider, per-agent routing) | only through an engine that supports them (OpenCode) |
| LSP / diagnostics | **none in V2** | whatever the engine does (Claude Code: no LSP by default) |
| Maturity / churn | very fast (19 releases in 5 weeks); V2 new since Oct 2026; big community | younger (0.1.x) |
| Cost | Claude via subscription (gray area), API keys pay-as-you-go, local free | same subscription via Claude Code |
| Lock-in | own DB and session format; export with `session export` | thread state plus engine sessions |
| Combination | **T3 Code can use the OpenCode service as an engine**, so the two are not exclusive | |

### 8.3 Trial plan (two weeks, same projects, same model)

**Setup (both arms)**
- Same host (butternut), same `agents.slice`, same Claude subscription, same AGENTS.md.
  Make CLAUDE.md a symlink first.
- Arm A, week 1: OpenCode (web inbox + `oc` TUI, `claude-agent/opus`).
- Arm B, week 2: T3 Code (Claude Code driver).
- Optional arm C (days 6–7 of each week): T3 Code UI with the OpenCode engine pointed
  at the shared service.

**Tasks per arm (comparable, different features)**
1. routelab: a feature touching web and Android, verified on the emulator.
2. routelab: a refactor with 3+ parallel streams (worktrees) merged at the end.
3. d_abm: stage, submit, watch and fetch a Fargate run, then write the analysis summary.
4. d_abm: a Kedro pipeline change with tests, plus a review subagent.
5. One "away" day driven from phone and hazel only.

**Record daily** (a small table in this repo)
- time to first useful diff
- interventions (permission or question prompts; wrong-path corrections)
- transcript clarity with subagents (1–5)
- streams kept alive at once
- `systemctl --user show agents.slice -p MemoryPeak`
- OOMs
- reconnect behaviour after a network drop
- phone usability (1–5)
- subscription usage (% of weekly limit)
- Nix friction: rebuilds needed, mutable state touched by hand

**Decision rule**
- Keep the arm with fewer interventions per merged change and better parallel
  visibility. Treat equal results as a tie broken by phone and remote UX.
- If OpenCode wins on harness but loses on the Claude-in-OpenCode quality question,
  try arm C as the steady state.

---

## 9. Gaps, risks, first-run checks

### 9.1 Risks

1. **Claude subscription route.** `claude-agent` lacks Anthropic endorsement and
   follows January's block and March's legal requests. It could break or become
   disallowed. Fallback: Anthropic API key (cost) or `local`.
2. **Version-replacement behaviour.** Any `opencode` of a different version (an
   un-rebuilt host, or another channel) **kills and replaces** the service. Keep all
   hosts and T3 Code on one flake.lock. Avoid `nix run`ning other versions on agent
   hosts.
3. **Detached fallback services** escape `agents.slice`. The unit is mitigated by
   `ExecStartPre`. Check `/proc/<pid>/cgroup`.
4. **No LSP** in V2, and **no CLAUDE.md** fallback.
5. **Fast churn.** Pin with flake.lock. Read CHANGELOG before bumping. Experimental
   keys can vanish [docs:config "Experimental"].
6. **HM 26.05 gaps.** No `cli`; `web` uses foreground serve with `Restart=always`;
   the MCP shape is V1; `extraPackages` hard-codes `bin/opencode`. Our module works
   around all of them.
7. **Mutable DB state**: credentials, approvals, project startup commands. Seeding
   covers the last; back up the DB.
8. **devShell PATH.** The server runs with the profile PATH. Until the direnv plugin
   exists, rely on AGENTS.md telling agents to use `direnv exec .`.
9. **Local models.** Context too small on most llama-swap entries; the
   `--no-mmproj--ctx-size` bug; tool-call quality.
10. **Snapshot or watcher load** on 35/69 GB trees. Mitigated by `watcher.ignore`;
    measure snapshot size.
11. **npm plugins / `npx` MCP** are impure. Use store directories and pinned versions.
12. **Pairing `--remote`** (OpenTunnel) would expose the server to the internet.
    Never use it. Consider a `policies`/wrapper guard [verify that a config-level
    switch exists].

### 9.2 First-run checks (per agent host)

```bash
opencode --version                       # 2.3.x, same on all hosts and in T3 Code
systemctl --user status opencode         # active, Slice=agents.slice
opencode service status                  # http://127.0.0.1:49374 (port = latest channel)
opencode api get /api/info               # {version, pid} → pid in agents.slice:
grep agents.slice /proc/$(opencode api get /api/info | jq .pid)/cgroup
opencode debug config                    # sources: ~/.config/opencode/opencode.json (+ project), no opencode.jsonc
test ! -e ~/.config/opencode/opencode.jsonc
opencode debug paths                     # db/data/state locations
claude auth status && opencode auth login claude-agent && opencode models claude-agent   # opus/sonnet/haiku ids
opencode models peacelily                # qwen-coder/qwen-moe/qwen-small listed
opencode run --standalone -m peacelily/qwen-coder "list files with the glob tool"       # tool call works
opencode mcp list                        # nixos, git connected
opencode debug agents                    # build/plan/explore/general + reviewer/local; title/summary models
tailscale serve status                   # https :8443 → 127.0.0.1:49374
# from hazel:
oc ~/work/tfc/repos/d_abm                # attaches; tools run on the target
opencode pair --url https://$(hostname).<tailnet>.ts.net:8443   # phone: open link, inbox loads
# behaviour:
#  - plan agent cannot edit; policies block `sudo ls`; `git push` asks
#  - /undo restores files; check du -sh ~/.local/share/opencode/snapshot*
#  - create a worktree session in routelab → startup command ran (symlinks exist)
#  - start a TUI of a *different* version? (don't) → confirm the unit is not replaced in normal use
```

### 9.3 Open items to verify (collected)

- exact `claude-agent` model IDs
- whether the HM-wrapped `claude` works as `OPENCODE_CLAUDE_PATH`
- process memory per Claude session
- `tailscale serve` with a custom HTTPS port, and web UI behaviour behind the proxy
  (CORS, cookies, PTY websockets)
- PWA on the phone
- `opencode api` query encoding for `location[directory]`
- whether `ExecStartPre=service stop` is harmless
- llama.cpp `--jinja` default on the pinned version
- the TUI's behaviour with its env-provided CLI config when the settings dialog
  writes `cli.json`
- the event envelope `location` field for plugin filtering
- whether a config switch exists to forbid `pair --remote`
