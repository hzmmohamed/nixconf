# attn integration (attn plan 5): design (2026-11-28)

Short design. Upstream: attn `docs/design.md` §5.3, §5.12, §6, §7.

## Intent

attn replaces ActivityWatch on hazel and butternut from day one: attn's system
daemon (ingest-only AW API on `127.0.0.1:5600`, age-encrypted frame log) plus its
session sensor, fed by the same third-party watchers (window/idle, web, editor).
S3 upload, enrolment and sops secrets come later (they wait on the Alchemy stack
and P0).

## Goals / non-goals / anti-goals

- Goals: daemon + sensor + awatcher on both hosts; swayidle and fish wired to the
  sensor; ActivityWatch gone; `agent-net` drives the metered upload policy.
- Non-goals (later): `s3://` sink and AWS credentials, the watcher token, sops
  secrets for attn, `ptrace_scope` and agent deny rules (owned by the isolation
  design's Phase 0), peacelily's brain recipient.
- Anti-goals: any secret or private key in git; any agent reading tracker output
  (`/var/lib/attn`, the sink); hardcoded usernames/hostnames.

## Approaches

- **A. One `attn` feature (picked).** `features/attn.nix` imports attn's device
  module and owns every piece; hosts import it and set `deviceId`. Matches
  "features own their infra"; a third device is one line.
- B. Per-host config: less indirection, but recipients, watchers and the AW
  removal written twice.

Cross-cutting, decided with the owner:
- **Package**: attn's own `packages.attn` (the module default), built against
  attn's locked nixpkgs, no `follows`, so the deployed store path equals what
  attn's CI builds and a CI-pushed cache can serve it (download-only deploys on a
  metered link). Cost: a second nixpkgs at eval and in the closure.
- **Fetch**: `git+ssh://git@github.com/hzmmohamed/attn` (repo is private; the
  owner's SSH key works on both hosts). Once agents move to their own Unix user
  without `~/.ssh`, they can evaluate only while the locked source is already in
  the store; revisit (gh token in `access-tokens`) then.

## Design

- `flake.nix`: input `attn` as above; `flake.lock` updated for that input only.
- `agent-net` becomes a flake package (`packages.agent-net`), still used by
  `agent-env`; attn's `networkStatusPackage` takes it.
- `features/attn.nix` (`flake.nixosModules.attn`):
  - imports `inputs.attn.nixosModules.device`;
  - `services.attn.device`: `enable`, `sink = "dir:///var/lib/attn/sink"`,
    `recipients` = the owner's offline vault age **public** key (owner supplies;
    the brain recipient joins once peacelily is up), `networkStatusPackage`;
    `deviceId` is left to the host;
  - `services.attn.sensor`: `enable`, `fishHook = true` (skips agent shells),
    `gitRoots` defaulting to the user's `~/work` and `~/nixconf` *(builder's
    call; hosts may override)*;
  - swayidle: one extra home-manager `services.swayidle.timeouts` entry,
    `timeout = 180` *(builder's call: aw-watcher-afk's default)*, `command =
    idleCommands.idle`, `resumeCommand = idleCommands.active`;
  - awatcher: a home-manager user service (`awatcher` from nixpkgs), bound to
    `sway-session.target` like the old afk watcher;
  - launcher entry `attn status` is not added (no UI yet).
- SWAYSOCK: already imported into the user manager by home-manager's sway
  systemd integration (`variables` default); verified in eval, nothing added.
- Removed: `features/activitywatch.nix` and its imports in both hosts; Clockify
  from `chromium.nix` (design §5.3). The ActivityWatch web and VS Code extensions
  stay; they now post to attn.
- Hosts: hazel and butternut import `attn` and set `deviceId` (a fresh UUID each,
  committed: an identifier, not a secret).

## Left to the builder

Exact gitRoots, awatcher unit details, how `agent-net` moves into a package
without changing `agent-env`'s behaviour.

## Watch on first deploy (owner)

`systemctl status attn-daemon`, `systemctl --user status attn-sensor` (its
`PrivateTmp` may fail in a user manager), `systemctl --user status awatcher`.
