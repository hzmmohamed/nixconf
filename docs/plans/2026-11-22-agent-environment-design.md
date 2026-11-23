# Agent environment: network awareness, dev shells, store-first tools

Status: design, 2026-11-22. Scope: `agent-common` / `agent-t3code` /
`agent-opencode` (hazel, butternut, later fern).

## Why

On the go, T3 runs over the phone hotspot: hazel on the hotspot, or butternut
on it directly or through hazel. Mobile data in Egypt is metered and tight.
Home Wi-Fi is metered too, but roomy. Agents know nothing about this today.
They also run with an inconsistent environment:

- T3's server is a systemd user service with a fixed PATH
  (`agent-t3code.nix`, `Environment = PATH=…`), so agents in T3 never see the
  project's dev shell. In the old VSCodium + direnv setup they did.
- What they do have is whatever happens to be on PATH, plus a bare `python3`
  and `jq` that `agent-common` adds as a workaround. When a tool is missing,
  they give up or improvise, even though every machine runs NixOS and could
  supply any tool.
- No global agent instructions exist (`~/.claude/CLAUDE.md` is absent), so
  preferences such as "script big edits in Python" can't reach every project.

## Goals

1. **Network awareness, light steering.** Agents know whether the uplink is
   metered. When it is, they lean toward doing the work where the data lives:
   server-side filters and summaries (`kubectl … -o jsonpath`, `aws … --query`,
   `--max-items`, `| head`, `wc -l` first), no large pulls without reason. When
   it isn't, they relax. When the network changed a decision, they say so
   ("skipped the 2.1 GB image pull: on the hotspot").
2. **The project dev shell, automatically.** Inside a project with an allowed
   `.envrc`, an agent session in T3 runs inside that dev shell, as it did
   under VSCodium + direnv. Project work (build, test, lint, anything
   version-sensitive) uses the shell's tools and versions, never "close
   enough" ones.
3. **Store-first generic tools.** For tools that don't depend on the project
   (an edit script in Python, `openssl`, `rg`, `ffmpeg`, Python with a couple
   of libraries), agents get them through one command that prefers what's
   already in the local store, states what a download would cost, and holds
   back large downloads on metered links.
4. **One set of agent guidelines on every machine**, covering the three goals
   above plus "prefer scripted edits (a Python script) over many edit-tool
   calls for big or repetitive changes".

## Non-goals

- Hard enforcement. Nothing blocks network access. This is information plus
  guidance, and the agent decides.
- Measuring bandwidth or data used.
- Cleaning up existing project dev shells (e.g. ones that ship Python for no
  reason). That's per project, later.
- Phone-side work (the phone already reports metered via DHCP).

## Anti-goals (a failure even if it "works")

- An agent using a store-first or "nearest version" tool for project builds
  and tests instead of the dev shell.
- Auto-allowing `.envrc` files. Cloned repos are untrusted; `direnv allow`
  stays a deliberate act (by you, or by a project's own T3 worktree setup
  script).
- Nagging: repeated network banners every turn, or prompts asking permission
  for small downloads.
- Surprise downloads on metered links caused by the new tooling itself (for
  example, the wrapper running `nix develop` on a project whose shell isn't
  built yet).

## Constraints and facts found

- NetworkManager already reports `GENERAL.METERED: yes (guessed)` for the
  Android hotspot (`wildflower`), via the hotspot's DHCP vendor option.
  Home Wi-Fi shows `no (guessed)`.
- The `nixpkgs` flake registry entry is pinned to the system's own nixpkgs
  (`system flake:nixpkgs path:/nix/store/…-source`), so
  `nix shell nixpkgs#foo` resolves to the revision the machine was built
  from: maximal store hits.
- `direnv` + `nix-direnv` (cached shells), `nix-index` (prebuilt database)
  and `comma` are installed everywhere (`features/nix.nix`).
- The store holds many interpreters already (`python3-3.10` … `3.14`, several
  `-env`s). Globbing `/nix/store` (≈211 k entries) takes about 2 s.
- T3 pins each provider's `binaryPath` (and may pin `launchArgs` /
  `environment`) in its policy (`agent-t3code.nix`, `limits.providers`).
  Currently `${userBin}/claude` and `${userBin}/opencode`.
- `agent-common` already merges managed hooks into each Claude account's
  `settings.json` (`agent-notify`, `agent-status`, including a
  `UserPromptSubmit` hook), for every dir in `preferences.agents.claudeAccounts`.
- Butternut behind hazel's cable share (`<peer>-shares` in `cable-link.nix`)
  can't see that hazel's uplink is the hotspot; NM marks the shared link
  unmetered.

## Approaches considered

**Dev shell in T3 sessions**

- **A. Whole session inside the shell (picked).** T3's provider binary becomes
  a wrapper that does `direnv exec <project root> <real binary>`. Every
  command the agent runs sees the shell, like VSCodium + direnv did. The
  environment is fixed at session start, so an agent that edits `flake.nix` /
  `.envrc` uses per-command `direnv exec . …` from then on, or you start a
  new thread.
- B. Per command: agents prefix project commands with `direnv exec . …` from
  instructions alone. It always picks up shell edits, but relies on agents
  remembering, and they forget. Kept only as the fallback inside A.

You picked A, with B as the fallback after shell edits.

**Store-first tools** (my call; not discussed in detail)

- Instructions only ("use `,` / `nix shell nixpkgs#…`"). Zero code, but no
  size check, no metered gate, and no reuse of other versions already in the
  store.
- **A small wrapper, `nx` (picked).** A shell command, so it works the same in
  Claude, OpenCode, T3 and a plain terminal. Adds the size check, metered
  gate and store-wide reuse on top of comma's lookup.
- An MCP tool. Agent-specific plumbing for something a shell command does
  just as well, and a shell command is easier to test by hand.

**How agents learn the network state** (my call)

- Instructions telling agents to run `agent-net` themselves. Works
  everywhere, but they'd only check when they remember.
- **Hook injection plus instructions (picked).** For Claude (and T3's Claude
  provider), a `SessionStart` hook adds one line of state, and the existing
  `UserPromptSubmit` slot adds a line **only when the state changed** since
  the last turn of that session. OpenCode and anything else: instructions
  telling them to run `agent-net` before data-heavy work.
- An MCP resource. Same objection as above.

## Design

### 1. `agent-net`: the network state

A small script in `agent-common` (`writeShellApplication`; nmcli, jq).

- Finds the device carrying the default route; reads `GENERAL.METERED`
  (`yes`/`no`, with or without "guessed") and the connection name.
- Prints one line, e.g. `metered (wildflower, wlo1)`,
  `unmetered (home, wlo1)`, `offline`; `--json` for scripts:
  `{"state":"metered","connection":"wildflower","device":"wlo1"}`.
- **Override file** `~/.local/state/agent-net/override` (`metered`,
  `unmetered`, or absent), set with `agent-net set metered|unmetered|auto`.
  This covers the cases NM gets wrong (butternut behind hazel's share on the
  hotspot; a roomy office Wi-Fi that guesses wrong).
- Declarative help for the share case (my call): a per-host option in
  `cable-link`, `preferences.cable.peerSharesMetered` (default false),
  sets `connection.metered = "yes"` on the `<peer>-shares` profile.
  butternut sets it true: its `hazel-shares` profile takes internet from the
  carried laptop, which on the go is the hotspot. hazel leaves it false
  (`butternut-shares` is home Wi-Fi). Override with `agent-net set` when
  that's wrong.
- No NM on the host (fern on EC2) → `unmetered`.

### 2. Hooks (Claude accounts, merged like the existing ones)

- `SessionStart`: emit `additionalContext` of
  `Network: <agent-net line>. See "Network" in your global instructions.`
- `UserPromptSubmit`: compare `agent-net --json`'s `state` with the last value
  stored for that session (`$XDG_RUNTIME_DIR/agent-net/<session_id>`); emit
  one line only on change ("Network changed: now metered (wildflower)").
  This sits next to the existing `agent-status` hook in the same event, and
  must stay fast (<100 ms; one nmcli call) and never fail the prompt.

### 3. Global agent guidelines

One Markdown file generated in `agent-common`, installed at
`~/.config/agents/guidelines.md` (a home-manager file, read-only).

- Claude: every account dir's `CLAUDE.md` must contain the import line
  `@~/.config/agents/guidelines.md`. An activation step (like the
  settings.json merge) **appends that line if missing** and never rewrites
  the rest, so the file stays yours to edit.
- OpenCode: its global `AGENTS.md` (or `instructions` config pointing at the
  same file; builder picks whichever OpenCode 2.x supports cleanly).

Content, short and directive (about 40 lines):

- **Environment layers.** "Project work (build, test, lint, run the app,
  anything whose version matters) runs in the project's dev shell. In T3 your
  session already runs inside it when `$AGENT_DEVSHELL` is `loaded`. If you
  changed `flake.nix`/`.envrc`/devenv files this session, run project
  commands as `direnv exec . <cmd>`. If `$AGENT_DEVSHELL` is `not-allowed`,
  say so; don't `direnv allow` yourself. Generic tools that don't depend on
  the project come from `nx` (below), never from guessing versions for
  project work."
- **`nx` usage** (two or three examples).
- **Network.** The steering in goal 1, framed as defaults ("on metered,
  prefer…"), plus "when the network changed what you did, say so in one
  line".
- **Editing.** "For large or repetitive edits (many files, many similar
  changes, generated tables), write and run a short Python script instead of
  many edit-tool calls; show the script or a summary of what it changed."

### 4. Dev shell wrapper: `agent-devshell`

`agent-devshell <real binary> [args…]`, used as T3's `binaryPath` for both
providers through two tiny wrappers (`claude-devshell`, `opencode-devshell`)
on the user profile.

1. Root = nearest ancestor of `$PWD` with an `.envrc` (stop at `$HOME` / `/`).
2. No `.envrc` → `AGENT_DEVSHELL=none`, exec the binary directly.
3. `.envrc` not allowed (`direnv status --json` reports the found RC as not
   allowed) → `AGENT_DEVSHELL=not-allowed`, exec directly.
   **Worktree exception (my call):** if root is a git worktree whose main
   checkout's `.envrc` is allowed and byte-identical to this one, the wrapper
   runs `direnv allow <root>`. You already trusted that exact content; the
   allow is per path only because direnv keys on path. Anything else stays
   `not-allowed`.
4. Allowed: check that a **cached** shell exists for that root, meaning
   either this checkout's nix-direnv profile (`.direnv/flake-profile-*` or
   the devenv equivalent) is present and current, or (for a worktree) the
   main checkout's profile is, and the shell-defining files (`flake.nix`,
   `flake.lock`, `.envrc`, `devenv.*`) are identical between the two. In the
   second case, seed this checkout's `.direnv/` from the main checkout's
   (same store paths, so no build) before entering. Deciding "cached" must
   not evaluate the flake or touch the network.
   - Cached → `direnv exec <root> env AGENT_DEVSHELL=loaded <binary>`.
   - Not cached → never block the thread start, whatever the network (my
     call: T3 may time out a slow provider start, and a first build can take
     minutes). Set `AGENT_DEVSHELL=not-built` and exec directly. On an
     unmetered link, also start a detached background warm-up
     (`systemd-run --user … direnv exec <root> true`) so the next thread
     finds it cached; on metered, don't. The guidelines tell the agent to
     mention `not-built` and use `direnv exec . <cmd>` if it needs the shell
     now (which builds in the foreground, a visible, deliberate choice).
5. Never fails closed: any error in steps 1-4 → exec the binary directly with
   `AGENT_DEVSHELL=error`.

The dev shell's PATH goes first, then the existing T3 PATH stays reachable
(direnv prepends), so `claude`'s own helpers, `git`, `nx` and `agent-net`
still resolve.

### 5. `nx`: store-first runner

`nx [-p <attr>] <program> [args…]` and `nx --py <pkg>… -- <python args…>`.
Bash or Python (stdlib) script in `agent-common`.

Resolution for `nx [-p attr] prog`, stopping at the first hit:

1. `prog` on PATH (and no `-p`) → exec.
2. Find the attribute: `-p` if given, else `nix-locate --whole-name
   --at-root --top-level /bin/<prog>`, preferring the attribute whose name
   matches `prog`. Ambiguous → print the top few and exit 2.
3. **Pinned and present:** `nix eval --raw nixpkgs#<attr>.outPath`
   (resolves to the system revision); if that path exists → run from it.
4. **Any version present:** newest valid `/nix/store/*-<pname>-*/bin/<prog>`
   (skip `.drv`, check `nix-store --check-validity`) → run it, and print to
   stderr `nx: using <name> from the store (not the pinned version)`. Skipped
   with `--exact`.
5. **Download:** `nix build --dry-run nixpkgs#<attr>` → parse the
   "will be fetched (X MiB download)" line. Metered (per `agent-net`) and
   above `NX_METERED_LIMIT_MB` (default 50) → refuse with
   `nx: <attr> needs 312 MiB download; on a metered link (wildflower). Re-run
   with NX_FORCE=1 to fetch.` (exit 3). Otherwise print the size and run via
   `nix shell nixpkgs#<attr> -c <prog> args…`.
   **Builds count too (my call).** The dry run also lists derivations that
   "will be built". On hazel those go to butternut (`builderFor`), and the
   outputs come back over the same link. On metered, any pending build
   (other than trivial local env/symlink builds such as `python3-*-env`,
   which are `preferLocalBuild`) → refuse with the same exit 3, naming the
   derivations. Generic tools from the pinned nixpkgs are normally all
   substitutable, so this rarely fires.

`nx --py requests rich -- script.py`: builds
`python3.withPackages (p: [p.requests p.rich])` from the pinned nixpkgs
(`nix shell --impure --expr`), with the same dry-run size check and gate.
Already-present libraries are reused as-is; the env itself is a local
symlink build. Reuse across *other* revisions is out of scope (step 4 is for
single binaries only).

The bare `python3` and `jq` in `agent-common` **stay** (my call): edit
scripts are the most common generic need and shouldn't pay nx's lookup. In
a dev shell, a project Python may shadow them; that's fine for edit scripts
(stdlib only), and the guidelines say edit scripts use the stdlib.

All of nx's own messages go to stderr, one line each, so they show up in the
agent's tool output without polluting stdout pipelines.

## Rollout

All in `agent-common` / `agent-t3code` / `agent-opencode` (+ the `peerSharesMetered`
option in `cable-link`, set on butternut), so every agent machine gets it from the existing feature
imports. Fern gets it when it's created. Verify with `just check`; the user
deploys.

## Left to the builder

- Exact nmcli/jq invocations, script language per tool (bash vs Python
  stdlib), file names under `~/.local/state`.
- How to detect "nix-direnv has a cached profile" reliably (the
  `.direnv/` profile symlink vs. `direnv status`), as long as it never builds
  on metered.
- Whether T3's Claude provider honours `settings.json` hooks
  (`SessionStart` / `UserPromptSubmit`). Verify early; if it doesn't, pin
  `AGENT_NET` into the provider `environment` at start and rely on the
  guidelines.
- Whether T3 starts the provider with `cwd` = project/worktree root (the
  wrapper assumes so); if not, read whatever T3 passes instead.
- The exact guidelines wording, within the content listed above.
