# Agent guidelines

Shared by every coding agent on this machine (Claude Code, OpenCode). Yours
to read, not to edit — it comes from the NixOS config.

## Environment

Project work (build, test, lint, run the app, anything whose version
matters) runs in the project's dev shell, not a system tool that's "close
enough".

Check `$AGENT_DEVSHELL`:
- `loaded` — you're already in it; run project commands directly.
- `not-allowed` — tell the user; never run `direnv allow` yourself.
- `not-built` or `error` — mention it, and use `direnv exec . <cmd>` only
  when you actually need the shell now (it builds the shell in the
  foreground; on a metered link say so first).
- `none` — started through T3, but this project has no dev shell (no
  `.envrc`); use what's already on `PATH` plus `nx`.
- unset — not started through T3 at all; assume your shell as-is.

After editing `flake.nix`, `.envrc`, or devenv files this session, run
project commands as `direnv exec . <cmd>` to pick up the change.

Generic tools that don't depend on the project come from `nx`, below —
never guess a "close enough" version for project work.

## Tools (nx)

`nx` runs a tool from the Nix store on demand, without adding it to the
project. Examples:

    nx openssl version
    nx -p ffmpeg ffprobe in.mp4
    nx --py requests -- script.py

Exit code 3 means it refused to fetch the tool on a metered link — report
that to the user instead of forcing it (`NX_FORCE=1`), unless they've
already agreed to the pull.

## Network

The session context or `agent-net` says whether the link is metered,
unmetered, or offline. On metered, prefer work where the data already
lives (`kubectl ... -o jsonpath=...`, `aws ... --query`/`--max-items`,
`| head`, `wc -l` first) and avoid large pulls without a reason. On
unmetered, relax. This is guidance, not a hard rule — when the network
changed what you did, say so in one line, e.g. "skipped the 2.1 GB image
pull: on the hotspot".

## Git

The session context's `Git:` line (or `agent-git`) says where you are.
Workflow: one thread = one branch = one worktree; a thread is done when
its branch is merged. This overrides any default to "commit only when
asked".

- **Own worktree/branch**: commit as you go, with focused messages; never
  hand back with uncommitted work. To finish: run the repo's checks,
  rebase onto the default branch if behind, `agent-push`, then
  `gh pr create --fill` (or `--title/--body`) and link the PR. Don't merge
  unless the user says so. After rebasing a pushed branch:
  `agent-push --force-with-lease`.
- **Main checkout** (shared with other threads): its dirty files may not
  be yours, and another thread may have files staged. Commit by path
  (`git commit -- <paths>`), never a bare `git commit`; for non-trivial
  edits suggest a worktree thread.
- Never skip commit hooks (`--no-verify`, `PREK_ALLOW_NO_CONFIG=1`). A
  hook with no config in a new worktree means the dev shell was never
  entered there: run `nix develop -c true` in it once, then commit.
- A repo's own CLAUDE.md/AGENTS.md can override this (e.g. direct to
  main, or no PRs).

## Delegation (T3)

- Quick, blocking helper on your own model (lookup, search, one-off
  review): your native subagent (Claude `Agent` in the foreground,
  OpenCode `task`).
- Long or background work, another model/provider, its own checkout, or
  anything the user may want to message mid-way: T3 `delegate_task`
  (`isolation:"worktree"` for its own branch).
- New top-level threads only when the user asks.
- In between (long enough to steer, or editing code alongside others):
  ask the user. Otherwise pick, and say which in one line.
- A brief gives exact paths, verified facts and decisions already made;
  the child's last message is its report.

## Working with the user

- Steps only the user can run (privileges, logins, deploys): paste-ready
  CLI blocks; you make every file edit. Their shell is fish and root is
  `doas`, so give multi-line logic as a bash script.
- Personal activity data (tracker events, check-ins, location) never
  goes to a commercial model, you included: open-weight models only.

## Editing

For large or repetitive edits (many files, many similar changes, generated
tables), write and run a short Python (stdlib-only) script instead of many
individual edit-tool calls; show the script or summarise what it changed.
