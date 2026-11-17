# Agentic workspace — design (validated 2026-11-17)

## Goal

Run 5–6 concurrent AI coding work streams across projects without heavy
per-project editor windows, interleaved transcripts, or agents starving the
machine — from **hazel** anywhere (home, office, café), with heavy work on
whichever **compute target** fits the situation, configured declaratively.

## Roles

**Client — hazel** (the only device carried and looked at): browser (T3 Code
inbox), Zed for occasional reading/editing (ACP), terminal with
`herdr --remote <target>`, review tools (lazygit + difftastic, hunk).
Module: `agent-client`.

> Update (2026-11-17): hazel also runs its own T3 Code server, so it is a full
> T3 environment (its own projects and threads when alone); butternut and fern
> take specific threads via the desktop app's host picker or server links
> (`t3-link`). See `2026-11-17-t3code-integration.md` §9.

**Compute targets** — all import the same `agent-host` profile:

| Target | When |
|---|---|
| peacelily | at home, once on the LAN (GPU, llama-swap) |
| butternut | at home, or carried to the office/café as "portable compute" |
| maple | at home, LAN helper |
| AWS VM | away from home, on demand, budget-guarded |

`agent-host` provides: T3 Code server (HM `programs.t3code.server`, bound to the
Tailscale address), herdr server, Claude Code + OpenCode (from llm-agents.nix /
unstable for freshness), project checkouts + per-project devShells, and
`agents.slice` resource caps.

**Resolver** — `target <need>` returns the first reachable machine for a need;
`run-on <target> <cmd>` for one-off heavy commands. Cloud is chosen only with
explicit confirmation or within budget.

## Configuration split

Global, in nixconf:
- `programs.claude-code` (settings, hooks, agents, commands, skills pinned as
  flake inputs: anthropics/skills, superpowers)
- `programs.opencode` (Anthropic + llama-swap provider when reachable)
- `programs.mcp` (mcp-nixos, git, playwright) consumed via `enableMcpIntegration`
- `programs.t3code` (`userSettings`, `keybindings`, `providerInstances`;
  `mutable* = false`)
- `programs.herdr.settings` (palette theme, keybinds)
- `preferences.agents.needs = { heavy = [ "peacelily" "butternut" "cloud" ]; android = [ "butternut" ]; gpu = [ "peacelily" "butternut" ]; }`
- `preferences.agents.cloud = { budgetEUR = …; requireConfirm = true; idleStopMinutes = …; }`

Per project (committed in the project repo — names **needs**, never machines):
- `AGENTS.md` (+ `CLAUDE.md` symlink)
- `flake.nix` devShell with pinned tools (Android SDK, Blender, …), via direnv
- `.agents/targets.toml`, e.g. `default = "heavy"`, `android-emulator = "android"`
- `t3.json` worktree setup script (`direnv allow`, deps)
- optional `.mcp.json`

## Runtime

1. `target heavy` → machine (Tailscale reachability; cloud gated).
2. T3 Code opens the project on that host; each thread = worktree; setup runs;
   Claude Code / OpenCode works.
3. `herdr --remote <target>` to watch raw agents (working/blocked/done sidebar);
   orchestrator agents spawn/poll workers via herdr's API instead of nesting
   subagents in one transcript.

Work-stream state lives on the target; git is the source of truth. Switching
targets mid-stream = push branch, continue elsewhere. Agents are instructed to
commit often.

## Resources & notifications

- `agents.slice` on every target: MemoryHigh ≈ 60 %, MemoryMax ≈ 75 % of RAM,
  low CPUWeight/IOWeight; T3 Code server, herdr server and `run-on` jobs run
  inside it. earlyoom/systemd-oomd as backstop. Verify Claude doesn't escape
  the slice (check `/proc/<pid>/cgroup`).
- Claude Code hooks (`Notification`, `Stop`) → ntfy (ntfy.sh first, self-hosted
  on peacelily later) → hazel desktop (swaync) + phone.

## Failure modes

- Target disappears (power cut, asleep): resolver falls through; resume from
  pushed branch.
- Cloud runaway: budget + provider cap + idle auto-stop.
- Drift between targets: all deployed from the same flake (`deploy <host>`).

## butternut dual-mode boot

- **Unattended unlock:** LUKS keyfile on a USB flash drive (enrolled as an extra
  slot; initrd looks for the stick by UUID; password slot stays as fallback).
  Keep the stick on the keyring, not in the bag. Upgrade path: FIDO2 key
  (`systemd-cryptenroll --fido2-device=auto`).
- **Display detection:** a unit before the greeter reads
  `/sys/class/drm/*/status`, ignoring the dead internal eDP panel. External
  display → greetd (desktop). None → `headless.target` (network, Tailscale, SSH,
  agent-host services). udev rule starts greetd on display hotplug.
- **Networks:** office Wi-Fi + phone hotspot as system NetworkManager profiles
  (PSKs from sops) so they connect before login; Tailscale at boot.

## AWS target

- Same `agent-host` profile; image built from the flake.
- Region chosen after measuring latency from Egypt: me-central-1 (UAE),
  me-south-1 (Bahrain), eu-central-1 (Frankfurt).
- Persistent volume for checkouts/agent state; `cloud up` / `cloud down` from
  hazel; idle auto-stop; Tailscale via sops auth key; substitutes from the
  private R2 cache.

## Rollout

1. Switch butternut to the current build; verify.
2. Repo groundwork: eval gate + justfile, CLAUDE.md/AGENTS.md, maple headless.
3. `agent-host` on butternut + `agent-client` on hazel (declarative agents,
   MCP, skills, `agents.slice`, ntfy, T3 Code server, herdr).
4. Resolver + per-project `.agents/targets.toml`; trial on one project (e.g.
   Android app, emulator pinned to butternut).
5. butternut dual-mode boot (USB keyfile, display detection, Wi-Fi profiles).
6. Private cache (nixbuild.net → R2).
7. AWS target (latency test, image, `cloud up/down`, budget, auto-stop).
8. peacelily joins (LTS kernel, CUDA cache pin, llama-swap for OpenCode).

## Open / to verify

- T3 Code per-project options beyond `t3.json`; HM `programs.t3code.server`
  exists on HM master only (write our own user unit on 26.05).
- herdr worktree support: core vs plugin; behaviour under Sway.
- Claude Code slice-escape report.
- Paseo as an alternative to T3 Code (evaluate only if T3 Code disappoints).
