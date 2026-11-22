# GitHub access via `gh` login, prompted when missing

**Status:** design, 2026-11-22. Small change.

## Intent

T3 Code's pull-request panel (and agents using `gh`) should work against
GitHub on every T3 host without dashboard-created tokens or sops ceremony.
Credentials are obtained by a CLI login flow and stored where the tool keeps
them; the user is prompted at the moment one is missing.

## Goals / non-goals

- Goals: `gh` installed and authenticated per machine (hazel, butternut,
  fern); git uses it for HTTPS to github.com; the user is told when a host
  is not logged in.
- Non-goals: sharing one token across machines (each host logs in once, by
  device flow: user agreed); a general credentials registry (later, once a
  second service needs it); changing SSH-based git push.
- Anti-goals: a token in the repo or in sops; a step that requires creating
  a PAT on github.com.

## Approaches

- **A. `github` feature, prompt-on-demand (picked).** Small, concrete,
  shaped so the check/login pair can later become a registry.
- B. Generic credentials registry (`creds status/login`, one notification
  listing everything missing). Deferred: shape would be guessed from one entry.
- Dropped: `GH_TOKEN` through secretspec. Still needs a hand-made PAT.

## Design

New `flake.nixosModules.github` (`modules/nixos/features/github.nix`),
imported by hazel, butternut, fern:

1. **Package**: `pkgs.gh` in `environment.systemPackages` (T3's service PATH
   already includes `/run/current-system/sw/bin`). `gh` config:
   `git_protocol: ssh`.
2. **Git credential helper**: `credential."https://github.com".helper =
   "!gh auth git-credential"` (and `gist.github.com`), system-wide, so HTTPS
   clones and private flake fetches work. Token storage stays `gh`'s:
   Secret Service (gnome-keyring) on desktops, `~/.config/gh/hosts.yml`
   (0600) on headless hosts.
3. **Prompt when missing**
   - Interactive: `gh` invoked from a terminal while unauthenticated runs
     `gh auth login --web --git-protocol ssh --hostname github.com` first,
     then the original command (device code shown; user approves at
     github.com/login/device, password from KeePassXC).
   - Desktop: a user oneshot after `graphical-session.target` runs
     `gh auth status`; if not logged in, `notify-send` "GitHub: not logged
     in. Run `gh auth login`."
   - Headless: fish `interactiveShellInit` (login shells over SSH) prints a
     one-line reminder when `gh auth status` fails.
   - Never prompt from non-interactive callers (T3 service, agents): they
     just fail as `gh` normally does.

## Left to the builder

- Whether the interactive auto-login is a `gh` wrapper package or a fish
  function (must not affect T3/agents, which call `gh` non-interactively).
- How to set the system git config given git is a wrapped package
  (`modules/wrappedPrograms/git.nix`, `-c` flags) without a second git on
  PATH; adding the helper there is acceptable if it degrades cleanly where
  `gh` is absent.
- Keep the status check cheap/offline-tolerant (no notification spam when
  the network is down: distinguish "not logged in" from "can't reach").
- User actions to record in `2026-11-17-user-actions.md`: deploy, then
  `gh auth login` once per host.
