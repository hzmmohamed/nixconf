# Agent isolation for one owner's NixOS fleet: research and design (2026-11-28)

Status: research report, design grade, no code. Written for the owner of hazel, butternut,
maple, peacelily and fern. Companion to `2026-11-17-agentic-workspace-design.md`,
`2026-11-17-secrets-design.md` ("Agent exposure model"), `2026-11-25-attention-tracker-design.md`
(§6, §7 P0, §11) and `2026-11-25-attention-tracker-review.md` (B1, B2, §a).

How claims are marked:

- **[repo]** read in this repository at the current `main` (file:line).
- **[src]** read in an upstream checkout, cited as `repo@sha:path` (shallow clones under
  `/tmp/agent-isolation-research/`, made 2026-11-28).
- **[doc]** vendor documentation or a published write-up, cited by URL.
- **[live]** observed on hazel today (`nix config show`, `/proc`, versions).
- **[verify]** inferred from the above but not exercised end to end. Each one is a first-run check.

No secret values, tokens or private addresses appear below. Hostnames are the fleet's own.

---

## 0. Recommendation in one page

**Make the Unix user the boundary, the kernel firewall the network boundary, and keep every
harness-level control (Claude deny rules, OpenCode policies, T3 modes) as ergonomics, not security.**

The fleet today runs every agent (Claude Code in VSCodium and the CLI, T3 Code threads, OpenCode)
as the owner's own account, and that account is root-equivalent three times over: passwordless
`doas` (`modules/nixos/features/doas.nix:11-12`), `trusted-users = ["root" "@wheel"]`
(`modules/nixos/features/nix.nix:27`; `nix config show` on hazel prints `trusted-users = root root
@wheel` [live]), and the sops primary age key in `~/.config/sops/age/keys.txt`
(`modules/nixos/features/sops.nix:17`), which decrypts every secret in the repository's history.
Nothing in a harness can repair that: Claude's own documentation says a Bash deny rule "isn't a
security boundary around the program" ([permissions doc](https://code.claude.com/docs/en/permissions)),
and its sandbox leaves Read, Edit, WebFetch, MCP servers and hooks outside the boundary
([sandboxing doc](https://code.claude.com/docs/en/sandboxing)).

Target architecture, in layers (details in §3, costs in §4, order in §5):

| Layer | What changes | Closes | Daily cost to the owner |
|---|---|---|---|
| **1. Root** | `doas` asks for a password (`persist`), `deploy` goes through one `ssh -t` prompt per host, `trusted-users` becomes `root` only with signed store paths and `trusted-substituters` | root via `doas`; root via the Nix daemon | one password per deploy, per `doas`. Later: a FIDO2 touch (`pam_u2f`) instead of typing |
| **2. Secrets** | per-host age keys from SSH host keys (as fern already does); a new primary key that lives only in a non-agent `sopsadmin` user on hazel, used through `SOPS_AGE_KEY_CMD`; the legacy key deleted everywhere and the secrets it protected rotated | the primary key on agent hosts (attn B1) | a `doas` prompt when editing secrets |
| **3. Agent user** | one `agent` Unix user per agent host (hazel included); T3 Code, OpenCode and herdr run as it; its own clones, logins and scoped tokens; the owner reaches it over `ssh agent@localhost` (VSCodium Remote-SSH, Zed, a terminal) | every owner-only asset: `~/.ssh`, gh and AWS SSO tokens, the vault, email tokens, Wayland, the clipboard, attn's keys | the owner's checkout and the agent's clone are different working trees; sync is git |
| **4. Egress** | per-UID `iptables` owner rules: agent UIDs reach only a local allowlisting proxy, a local allowlist DNS, and named tailnet services; the Nix daemon's fetches go through the same proxy; everything else is rejected | exfiltration to arbitrary hosts, DNS tunnelling, the Nix fixed-output hole | a blocked host now and then, answered with the tool below |
| **5. Unblock tool** | `egress`: blocked requests are attributed, logged, surfaced to the agent as a clear 403 and to the owner as a notification; `egress allow <host>` extends the runtime list until reboot or a TTL; `egress propose` writes the declarative diff | nothing new; it is what makes layer 4 liveable and auditable | approving a handful of hosts in the first weeks |

Where this deviates from the quick research you gave me (§6): T3 does not need an SSH
"remote environment" to run as another user (that path downloads a non-Nix runtime); running
`t3 serve` as the agent user keeps the desktop app, pairing and the tailnet URL exactly as they are.
ACLs on the owner's checkout are rejected (nuketown's reasoning holds, and T3 worktrees need a
writable `.git`). Claude's `setup-token` is the fallback, not the default; an interactive login as the
agent user is simpler and revocable. Bubblewrap wrappers and Claude's own sandbox are not the
boundary here: they are optional defence in depth once the user split exists, and several of them
currently break on NixOS with nix-direnv and worktrees. The three-UID pattern's "DNS to the local
resolver is allowed" is tightened to an allowlist resolver, because CVE-2025-55284 showed DNS is an
exfiltration channel.

What stays open for you (§7): one agent user per host, or one per trust domain (personal vs work);
whether to run a TLS-terminating mode for GitHub path rules; whether the owner keeps any Claude
running under the owner UID during the transition; which secret values to rotate beyond the
obvious ones.

---

## 1. Where the fleet stands

### 1.1 What an agent process can reach today (verified)

Every agent on hazel and butternut is a process of the owner's UID, so everything in the table is one
tool call away for a prompt-injected or merely confused agent. Claude's deny list
(`modules/nixos/features/agent-common.nix:196-202`: `sudo`, `doas`, `rm -r`, `rm -rf`, `nix copy`)
and `.claude/settings.json`'s denies (`sops`, `age`, `deploy`, `Read(~/.config/sops/**)`) match
command text, not programs; OpenCode's `policies` (`agent-opencode.nix:183-196`) do the same.

| Asset | Where | How an agent gets it | Consequence |
|---|---|---|---|
| root | `doas` with `noPass = true; keepEnv = true` for the owner (`doas.nix:11-12`); hazel, butternut, maple, peacelily, fern all import `doas` | `doas <anything>`; a deny rule on the word `doas` is bypassed by `env doas`, a script, or `nix shell nixpkgs#foo -c doas` | full machine, including other users' homes and the system profile |
| root (second route) | `trusted-users = root @wheel` (`nix.nix:27`, [live]) | `nix build` with `--option build-hook` / `post-build-hook`, or copying an unsigned path over a trusted one (Nix manual: trusted users "import unsigned realisations or unsigned input-addressed store objects", [conf-file](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html)) | root; also poisons the store other hosts substitute from |
| sops primary key | `~/.config/sops/age/keys.txt` on every host except fern (`sops.nix:17`; `scripts/install-host.sh:53-72` copies it to new hosts) | `cat`; or `sops -d secrets/**` in the checkout | every secret in git history: Tailscale auth key and OAuth client, Wi-Fi PSKs, harmonia signing key, syncthing identities, LibreChat secrets, fern's deploy key (`secrets/README.md`) |
| the whole fleet | `~/.ssh` plus the registry SSH config and known hosts (`hosts-registry.nix`), `PasswordAuthentication` still on by default (`openssh.nix:16-26`), passwordless `doas` on every target | `ssh butternut doas …` | root on every host from any host |
| GitHub, GitLab | `gh` token in the keyring or `~/.config/gh/hosts.yml` (`github.nix`; butternut uses the file) | `gh auth token`; the git credential helper | push to every repository the owner can, including the public `nixconf` |
| AWS | `~/.aws/sso/cache` after `aws-login` (`hosts/butternut/agents.nix:21-25` says so) | read the cache, exchange for Admin | the work AWS account |
| vault | `~/Vault/*.kdbx` plus the key file in `~/.local/share/keepassxc/` (`2026-11-17-secrets-design.md`) | copy both; the master password remains, but offline attack is now possible | human credentials |
| email, Chromium, VSCodium secrets | gnome-keyring Secret Service, PAM-unlocked for the session | `secret-tool lookup` | refresh tokens, cookies |
| T3 state | `~/.t3` (SQLite store, pairing sessions, `userdata/secrets/`) | read; `t3 pair` mints new pairings (T3 docs: `terminal:operate` "already grant[s] OS-user execution", t3code@9762a3c:docs/internals/04_environment-auth.md) | a second client of every environment |
| OpenCode credentials | `~/.local/share/opencode/opencode.db` (`agent-opencode.nix:14-17`) | read | provider logins |
| Claude logins | `~/.claude/.credentials.json`, `~/.claude-work/.credentials.json` ([authentication doc](https://code.claude.com/docs/en/authentication)) | read | the subscription, until revoked |
| session | Wayland socket, clipboard (`wl-paste`), D-Bus | same UID | screenshots, pasted passwords |
| attn (future) | ingest API on `127.0.0.1:5600` (review §a) | `curl` | pollution; keys are protected only once they leave `$HOME` (B1) |

What is already right and must be preserved: the thread-branch PR flow with `agent-push`
(`agent-env/agent_git.py`), the resource slices (`agent-host.nix`, `agent-t3code.nix`), T3's
`approval-required` default and locked `binaryPath` pins (`agent-t3code.nix:78,133-141`), the
`tokenInFile`/keyring split for `gh`, fern's host-key-only sops (`hosts/fern/configuration.nix:77-79`),
the Tailscale ACLs (`docs/tailscale-policy.hujson`), `ptrace_scope = 1` (hazel today [live]; it is the
Yama default, not pinned).

### 1.2 Why harness controls are not the boundary (evidence)

- Anthropic: "The boundary is a permission prompt, so a Bash command you approve can still write
  anywhere your user account can" ([security doc](https://code.claude.com/docs/en/security)); "A Bash
  rule matches the command text Claude writes … so a deny or ask rule covers the invocation Claude
  usually produces and isn't a security boundary around the program"
  ([permissions doc](https://code.claude.com/docs/en/permissions)); "Always run
  `--dangerously-skip-permissions` sessions inside a container, a VM, or the sandbox runtime"
  ([sandbox environments doc](https://code.claude.com/docs/en/sandbox-environments)).
- CVE-2025-55284: Claude Code's default allowlist let `ping`, `nslookup`, `dig` and `host` run
  without approval; prompt injection encoded secrets into DNS queries. Fixed by prompting for those
  four commands ([Embrace The Red](https://embracethered.com/blog/posts/2025/claude-code-exfiltration-via-dns-requests),
  [NVD](https://nvd.nist.gov/vuln/detail/cve-2025-55284)). The lesson for this design: any process
  that can resolve arbitrary names can exfiltrate.
- Approval mechanics themselves are attackable: "From Approval to Abuse" shows attacks that first
  mutate the harness's authorization state to acquire a reusable allow rule, then abuse it
  ([arXiv:2610.22987](https://arxiv.org/pdf/2610.22987)); "Approval Laundering" systematises
  approval-execution binding failures ([arXiv:2609.38983](https://arxiv.org/pdf/2609.38983));
  "When Context Gets Root" ([arXiv:2608.27299](https://arxiv.org/pdf/2608.27299)); tool-invocation
  red-teaming found RCE on major agents ([arXiv:2509.05755](https://arxiv.org/pdf/2509.05755));
  end-to-end exploit chains ([arXiv:2509.24240](https://arxiv.org/html/2509.24240v1)); repository
  poisoning ([arXiv:2608.30686](https://arxiv.org/pdf/2608.30686)); indirect-injection exfiltration
  that defeats surface defences ([arXiv:2608.27092](https://arxiv.org/pdf/2608.27092)).
- Allowlisted services are exfiltration channels when the attacker can read them: the GitHub MCP
  "toxic flow" leaked private repositories into a public PR
  ([Invariant Labs](https://invariantlabs.ai/blog/mcp-github-vulnerability)); CamoLeak used GitHub's
  own image proxy ([Legit Security](https://legitsecurity.com/blog/camoleak-critical-github-copilot-vulnerability-leaks-private-source-code));
  the "Rules File Backdoor" poisons agents through committed instruction files
  ([Pillar Security](https://pillar.security/blog/new-vulnerability-in-github-copilot-and-cursor-how-hackers-can-weaponize-code-agents)).
  gh-aw-firewall states the consequence plainly: "allowing github.com or api.github.com does not
  distinguish your account or repository from another"
  ([security architecture](https://github.github.io/gh-aw-firewall/reference/security-architecture)).
- The repository angle matters here because `nixconf` is public: anything an agent pushes to a
  branch is world-readable at once. The credential scoping in §3.3 and the `agent-push` secret scan in
  §3.3 are the mitigations.

---

## 2. Survey: approaches in the wild

Ratings: ●●● strong, ●● adequate, ● weak. "NixOS fit" means declarative, pure-Nix, no auto-updating
runtime. "Burden" is the owner's maintenance.

| Approach (examples) | Security | Ergonomics | NixOS fit | Burden | Verdict for this fleet |
|---|---|---|---|---|---|
| **A. Harness controls** (Claude permissions and sandbox, OpenCode `permissions`/`policies`, Codex bwrap sandbox, T3 modes) | ● as a boundary; ●● as friction reducer | ●●● | ●● | ● | keep, as ergonomics |
| **B. Same-user bubblewrap wrappers** (claudebox, ai-jail, jai, bubblewrap-claude, nix-agent-sandbox, sandbox-bwrap-nix, ai-sandbox/nono, SandboxedClaudeCode, Anthropic's `srt`) | ●● (self-described "not a security boundary" in several) | ●● (breaks nix-direnv symlinks, worktrees, nesting) | ●● | ●● | optional inner layer later |
| **C. Separate Unix user** (nuketown, agent-as-unix-user, hyperhive's per-agent users, blog posts, Claude issues #9102/#41505/#54321) | ●●● for files, processes, sockets; ● for network alone | ●● (git as the shared surface; editors over SSH) | ●●● (users, home-manager, sops-nix, impermanence) | ● | **recommended core** |
| **D. Containers** (hyperhive nixos-containers, claude-code-nix-sandbox nspawn, Anthropic devcontainer, sandcat, DLS claude-sandbox, gh-aw-firewall) | ●●● | ● (Nix store sharing, GPU, T3's worktree model, per-container upkeep) | ●● | ●●● | later, for untrusted repos |
| **E. VMs** (Stapelberg microvm.nix, Docker Sandboxes + sbx-config, claude-code-nix-sandbox QEMU, Claude cloud sessions) | ●●● (own kernel) | ● | ●● (microvm.nix is good; Docker Sandboxes is a binary product) | ●●● | later, for hostile code |
| **F. Egress control** (ipset firewall, Squid SNI, tinyproxy, mitmwall/exwall, sandcat's transparent mitmproxy, `srt` proxy, ai-jail CONNECT proxy, three-UID nftables, Docker HTTP rules, Claude cloud GitHub proxy) | ●● to ●●● | ●● | ●●● (iptables/nftables, systemd, small daemons) | ●● | **recommended, per UID** |

Notes per group, with what each contributes to the design:

**A. Harness controls.** Claude Code's sandbox covers "Bash, PowerShell, and Monitor tool commands
and their child processes"; "Read, Edit, Write, WebFetch, WebSearch … MCP servers, command hooks, LSP
servers … run outside it" ([sandboxing doc](https://code.claude.com/docs/en/sandboxing)). On Linux it
removes the network namespace and relays through host proxies over Unix sockets
(sandbox-runtime@0bbebed:README.md:108-135). Its allowlist prompts the user for new domains unless
`strictAllowlist` or `allowManagedDomainsOnly` is set ([sandboxing doc]). Current NixOS pain: bwrap
fails on read-deny paths through nix-direnv's `.direnv/flake-inputs` symlinks
([#86855](https://github.com/anthropics/claude-code/issues/86855), closed by the stale bot,
refiled as [#104685](https://github.com/anthropics/claude-code/issues/104685)); fails in git
worktrees ([#17374](https://github.com/anthropics/claude-code/issues/17374)); `excludedCommands`
silently ignored ([#89931](https://github.com/anthropics/claude-code/issues/89931)) or defeated by a
redirection ([#95532](https://github.com/anthropics/claude-code/issues/95532)); a relayed CONNECT
bypassed `allowManagedDomainsOnly` ([#87381](https://github.com/anthropics/claude-code/issues/87381),
closed); proxy 502s for allowlisted LAN hosts ([#112775](https://github.com/anthropics/claude-code/issues/112775)).
Codex sandboxes with bubblewrap on Linux and has read-only / workspace-write / danger-full-access
modes ([Codex sandboxing doc](https://learn.chatgpt.com/docs/sandboxing)); OpenCode 2 has
permissions and deny-only `policies` but no OS sandbox (`2026-11-17-opencode-integration.md` §2.3).
T3's own doc admits the limit: "Local admins … can modify policies or T3 Code binaries … Use OS/MDM
controls for binary integrity and network isolation" (t3code@9762a3c:docs/user/managed-policy.md).

**B. bwrap wrappers.** claudebox: "Not a security boundary - designed for transparency, not
isolation" (claudebox@2a937ed:README.md:115); sandbox-bwrap-nix: "a blast-radius reduction … not a
hard security boundary" (sandbox-bwrap-nix@b630892:README.md:90); ai-jail: "not a lockdown or
hard-security tool … defends against a trusted-but-fallible agent's mistakes" (ai-jail@83339b7:README.md:9-13).
What they contribute: ai-jail's `--allow-host` CONNECT-only egress with `--prompt-hosts`, which "shows
a desktop notification (`notify-send` …) with Allow and Deny buttons and holds the connection until
you answer" (README.md:323-340), is the closest existing implementation of your unblock idea, and its
"phantom credentials" (`--secret KEY=host`) match `srt`'s masking. nix-agent-sandbox documents the
NixOS-specific traps: `/etc/resolv.conf` symlink chains inside `--tmpfs /etc`, bwrap not nesting, Nix
in single-user mode inside the sandbox (nix-agent-sandbox@4b1f5b9:README.md:285-325). The NixOS
Discourse thread on the subject converged on "any of the existing bubblewrap wrappers" or a VM, and
noted the "not a security boundary" wording
([discourse thread 71543](https://discourse.nixos.org/t/claude-code-and-security-isolation/71543)).

**C. Separate Unix user.** nuketown: "AI agents as Unix users. Everything resets between rounds";
"Agents don't get ACLs on your checkout. They clone repos, work in their own copy, push branches …
The shared surface is the git remote, not the filesystem"; per-agent sops secrets with
`owner = "ada"`; `/agents` on a btrfs subvolume rolled back at boot with `.config/claude` and
`projects` persisted ([nuketownada/nuketown@57a7b62](https://github.com/nuketownada/nuketown)
README). agent-as-unix-user: a setuid entry point that scrubs the environment, group+setgid+ACL
home, `systemctl set-property user-$(id -u agent).slice CPUQuota=150% MemoryMax=16G`, an iptables
`-m owner --uid-owner agent` recipe redirecting 80/443 to a proxy, and `au sshd` + `au vscode-url` to
attach VS Code over SSH (agent-as-unix-user@1c49e32:README.md:60-175). hyperhive runs "one
nixos-container per agent … Every agent is a full NixOS container with its own unix user (passwordless
sudo inside the cage)", config changes "flow as git commits, the operator approves them in a
browser", secrets from one OpenBao store ([hyperhive README](https://git.berlin.ccc.de/vinzenz/hyperhive)).
Two practitioners' posts say the same thing from experience: "Having Claude Code and other harnesses
living under a separate user account eliminates a lot of potential disasters … I have watched the
… clanker try to figure out if it has passwordless sudo access on numerous occasions"
([joshtronic](https://joshtronic.com/2026/07/12/sandbox-coding-agents/)); "The politeness of LLMs
cannot be relied upon … Give Claude its own identity … Deny rules … keep honest people honest"
([patrickmccanna](https://patrickmccanna.net/keeping-secrets-from-claude-code/)). Anthropic closed
the feature requests to run Claude as another user ([#9102](https://github.com/anthropics/claude-code/issues/9102),
[#41505](https://github.com/anthropics/claude-code/issues/41505),
[#54321](https://github.com/anthropics/claude-code/issues/54321)), and on Windows its own `srt`
"runs the sandboxed process under a dedicated `srt-sandbox` local user account, with a Windows
Filtering Platform egress fence keyed on that account's SID" (sandbox-runtime@0bbebed:README.md:112),
which is exactly the Linux design below.

**D. Containers.** The Anthropic devcontainer firewall resolves an allowlist to IPs into an `ipset`
and rejects the rest (anthropics/claude-code@102fafb:.devcontainer/init-firewall.sh:41-113): simple,
but IP-based allowlists rot under CDNs. gh-aw-firewall chose "Squid Over mitmproxy" because SNI
filtering needs no CA and keeps pinning intact, and documents fail-secure layering (DOCKER-USER
chain, container NAT, Squid ACL) and DNS "restricted to configured DNS servers … prevents DNS-based
data exfiltration" ([security architecture](https://github.github.io/gh-aw-firewall/reference/security-architecture)).
sandcat routes all container traffic through a transparent mitmproxy over WireGuard with
first-match allow/deny rules and "secret substitution … so the container never sees real values", and
warns that its default "allow all GET traffic … is a vector for prompt injection"
(sandcat@405ed10:README.md, docs/configuration/settings.md:48-88). DiamondLightSource's
claude-sandbox adds a per-process egress jail that "blackholes RFC1918 internal networks" and an
integrity guard that "fails loud and closed if it is ever launched unwrapped"
(claude-sandbox@f2198c0:README.md, docs/index.md). hyperhive is the NixOS-native container design
(above). Containers are the right answer for a repository you do not trust at all; for daily work
across three checkouts with devShells, GPU and T3 worktrees they cost more than they add once the
user split exists.

**E. VMs.** Stapelberg's microvm.nix setup: ephemeral cloud-hypervisor VMs, read-only Nix store over
virtiofs, a shared workspace directory, Claude's config directory shared from
`~/claude-microvm` via `CLAUDE_CONFIG_DIR`, NAT without egress filtering, discard on stop
([post](https://michael.stapelberg.ch/posts/2026-02-01-coding-agent-microvm-nix/)). Docker Sandboxes
gives a microVM with network policies that can match HTTP methods, paths and query parameters, and
approvals that "can't override a deny rule" ([Docker docs](https://docs.docker.com/ai/sandboxes/governance/access-controls/network/));
sbx-config's hardened baseline is a good threat table for any sandbox: host files "that later run on
your host: `.git/hooks/*` …, `.claude/settings.json` hooks, `.envrc`, `Makefile`", broad GitHub tokens,
host browser, SSH agent, and "clone mode so agents never write to your checkout"
(sbx-config@cc7951f:policy/README.md). Its Nix allowlist (`cache.nixos.org`, `tarballs.nixos.org`,
`github.com`, `api.github.com`, `codeload.github.com`, `objects.githubusercontent.com`,
sbx-config@cc7951f:policy/allow/claude-nix.txt) seeds the starter list in §3.5.

**F. Egress.** The three-UID pattern is the kernel-side model: operator, proxy and agent UIDs, with
`meta skuid <agent>` dropping everything but loopback-to-proxy, and the explicit point that
"HTTPS_PROXY isn't a security control" ([three-UID post](https://dev.to/luckypipewrench/the-three-uid-containment-pattern-for-ai-agents-on-linux-13bd)).
mitmwall (now ported to Rust as exwall) is the TLS-terminating option: TOML `[[allow]]` rules with
`domain`, `include_subdomains`, `methods`, `pathname_pattern`, `inject_headers`, loaded from
`/etc/mitmwall/rules.d`, enforced by iptables REDIRECT of 80/443/53 (mitmwall@553b2ee:README.md,
example-rules.toml). Anthropic's `srt` proxy is the most complete reference for the unblock UX: a
denial "is surfaced to the sandboxed client in the response body so the agent can tell a policy block
from a network failure" (sandbox-runtime@0bbebed:src/sandbox/request-filter.ts:26-31), an external
"decider" process answers allow/deny over a framed JSON protocol (src/sandbox/decider-client.ts:1-50),
and `onFilterRequestDenied` carries attribution (src/sandbox/http-proxy.ts:180,266); it also warns
that the proxy "does not otherwise inspect the traffic" and that permitted names must not resolve to
loopback or LAN (README.md:1323). tinyproxy (1.11.3 in the pinned nixpkgs, NixOS module present)
has `Filter`, `FilterDefaultDeny`, `ConnectPort` and warns that URL filtering "works only in plain
HTTP scenarios" ([tinyproxy.conf](https://github.com/tinyproxy/tinyproxy/blob/master/docs/man5/tinyproxy.conf.txt.in));
Squid 7.6 and dnsmasq 2.93 are also packaged with modules. mitmproxy 12.2.3 is in nixpkgs for an
exwall-style mode later.

---

## 3. Recommended architecture, checked against the repository

```
 one agent host (butternut; hazel and peacelily and fern the same shape)
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │ owner UID (human)        sopsadmin UID (hazel only)   agent UID(s)           │
 │  sway, VSCodium, T3       new primary age key          t3 serve, opencode,   │
 │  desktop app, deploy,     read via doas -u sopsadmin   herdr, claude, codex, │
 │  KeePassXC, ~/.ssh        cat (password)               own clones, own       │
 │  no agents                                             logins, own tokens    │
 │        │ ssh agent@localhost / doas -u agent -s                │             │
 │        └───────────────────────────────────────────────────────┘             │
 │ egress UID: allowlisting CONNECT proxy + allowlist DNS   nix-daemon (root)   │
 │  reads allowlist.nix + /run runtime overlay               proxied too        │
 │ iptables -m owner: agent UIDs → lo:proxy, lo:dns, tailscale0:{named}; REJECT │
 │ journald: every decision; /run/agent-egress/requests: pending unblocks       │
 └──────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Layer 1: close root

**doas with a password.** Set `noPass = false; persist = true;` in `doas.nix` (the NixOS module
emits `persist`, nixpkgs `nixos/modules/security/doas.nix:19`; nixpkgs builds doas 6.8.2 with
`--with-timestamp` [live]). OpenDoas semantics, from source: the timestamp file name is
`ppid-sid-ttynr-starttime-uid` (OpenDoas@b96106b:timestamp.c:181-193), so a cached authentication is
reusable only by a process whose parent is the same shell, in the same session, on the same
terminal. The password is read with `RPP_REQUIRE_TTY`; without a controlling terminal doas fails with
"a tty is required" (OpenDoas@b96106b:shadow.c:84-88; the PAM path, which NixOS uses, has the same
flag at pam.c:64). Consequences: a T3- or systemd-started agent has no terminal and cannot even
prompt; an interactive `claude` in your terminal could trigger a prompt in that terminal, which you
would see; after layer 3 no agent is in `wheel` or the doas rule at all, so this layer protects you
against your own compromised processes and against any agent that stays on the owner UID during the
transition. `keepEnv` can stay. Later upgrade: `pam_u2f` (1.4.0 in nixpkgs) on the `doas` PAM stack,
so a FIDO2 touch replaces typing [verify].

The account password becomes load-bearing, and the current hash is committed to the public repository
(`modules/nixos/features/general.nix:30-36`, with its own SECURITY TODO). `preferences.user.passwordFromSops`
and the user-actions step 7c must land first.

**deploy over `ssh -t`.** `deploy.sh` runs `remote doas nix-env -p … --set` (line 271) and
`remote doas systemd-run … switch-to-configuration` (line 322) through `fleet-lib.sh`'s `remote()`,
which is `ssh "${ssh_opts[@]}" "$user@$target" "$@"` with no `-t`. With a password these fail
("a tty is required"). The change: merge the two root steps into one remote command run under
`ssh -tt`, so one prompt per host:

```
ssh -tt "${ssh_opts[@]}" "$user@$target" doas sh -c 'nix-env -p /nix/var/nix/profiles/system --set "$1" && systemd-run --unit=deploy-switch-to-configuration --collect --pipe --wait --quiet --service-type=exec -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER "$1"/bin/switch-to-configuration "$2"' _ "$system" "$action"
```

`persist` makes a second `doas` in the same remote shell free anyway. `--no-ask-password` on
`systemd-run` is unrelated (systemd's own password agent) and can stay. The 255-reconnect logic
(lines 326-345) still works because the unit is detached. `deploy all` becomes one prompt per host;
with `ControlMaster` it could be one per deploy, but the prompts are the feature. Local self-deploys
(`target = local`) simply prompt in your terminal. fern's bootstrap (`infra/aws/bootstrap.nix.tftpl`)
grants passwordless doas for the first boot only; the first `deploy fern` replaces it.

**trusted-users.** Set `nix.settings.trusted-users = ["root"]` in `nix.nix`. Effects, checked against
`deploy.sh`:

| Step | Today | After | Fix |
|---|---|---|---|
| `nix copy --no-check-sigs --to ssh-ng://user@target` of a locally built system (lines 228-231, 260-261) | works because the owner is trusted on the target | refused: `require-sigs` applies to untrusted users (Nix manual) | sign builds: `nix.settings.secret-key-files` on hazel and butternut (per-host signing keys in sops, root-only; butternut can reuse its harmonia key), and every host trusts both public keys. Drop `--no-check-sigs` |
| `remote nix build --extra-substituters <harmonia> --extra-trusted-public-keys <key>` (lines 251-253) | works because the owner is trusted | both flags are restricted settings for untrusted users; the second is ignored with a warning | put butternut's cache URL in `trusted-substituters` and its key in `trusted-public-keys` on every host (`lan-cache.nix` already adds the key on clients; make it fleet-wide and add `trusted-substituters`) |
| `nix build --eval-store auto --store ssh-ng://user@target` (build on target, lines 234-241) | works | still works: the derivations and flake sources the client uploads are content-addressed, and `buildPaths` is open to untrusted users [verify on the first deploy] | none expected |
| hazel's daemon offloading to butternut | root → `nix-ssh` (`nix-builder.nix`, `nix.sshServe.trusted = true` for that key-only account) | unchanged | none |
| the owner's ad-hoc `--option` and `--extra-substituters` | allowed | ignored unless the substituter is in `trusted-substituters` | add the ones you use (cachix caches) declaratively |

Remove `trusted-users` on every host, fern included (its bootstrap sets `trusted-users = @wheel`;
the first deploy fixes it).

**Other pins in this layer.** `boot.kernel.sysctl."kernel.yama.ptrace_scope" = 1` (the Yama default,
pinned so a kernel or module change cannot drop it; with separate UIDs, 2 is unnecessary). Flip
`preferences.ssh.passwordAuthentication = false` once key logins are verified (user-actions 7a-b).
Decide on Tailscale SSH (`check` mode, 12 h re-auth, `docs/tailscale-policy.hujson`): it is a second
root-free path into the owner account from any owner device; keep or drop, but know it exists.

Residual after layer 1: an agent on the owner UID still owns everything the owner owns except root;
root is reachable only through a kernel or setuid bug.

### 3.2 Layer 2: the sops primary key leaves agent-reachable homes

**Per-host keys.** Every host decrypts with its SSH host key, as fern does
(`hosts/fern/configuration.nix:77-79`: `sops.age.keyFile = lib.mkForce null; sops.age.sshKeyPaths =
["/etc/ssh/ssh_host_ed25519_key"]`). sops-nix converts the key with ssh-to-age at activation and
sets `SOPS_AGE_KEY_FILE` for `sops-install-secrets` (sops-nix@d5abe5e:pkgs/sops-install-secrets/main.go:1408-1440);
the host key is root-only, so no user-level process can decrypt host secrets. `scripts/install-host.sh`
stops copying `keys.txt` (lines 53-72) and instead enrols the new host's key the way
`scripts/fern/enroll.sh` does.

**The owner's editing key.** Create `users.users.sopsadmin` on hazel only (no shell login needed,
no groups, home `0700`), generate a new primary key there, and point every `sops` invocation at it
through `SOPS_AGE_KEY_CMD`, which sops 3.13.3 supports (getsops/sops@5032a71:age/keysource.go:29-42,
440-451): the command's stdout is the identity. The dev shell exports

```
SOPS_AGE_KEY_CMD="doas -u sopsadmin cat /home/sopsadmin/.config/sops/age/keys.txt"
```

with the doas rule `permit persist hfahmi as sopsadmin cmd cat args
/home/sopsadmin/.config/sops/age/keys.txt`. Editing a secret costs one password; the key never sits in
a file the owner UID can read; an agent on hazel (any UID) cannot run that `doas` without the
password and a terminal. Keep a paper or KeePassXC copy of the key, as `2026-11-17-secrets-design.md`
already says. Hardware later: `age-plugin-yubikey` 0.5.1 and `age-plugin-fido2-hmac` 0.5.0 are in
nixpkgs and sops-nix has `sops.age.plugins`.

For attn, honour the review literally: the brain's identity derives from peacelily's host key; attn's
S3 reader credentials and the DuckDB key are encrypted to peacelily's host key and the offline vault
key only. The new `sopsadmin` key is for nixconf's own secrets. Whether to add it as a third attn
recipient is your call (§7).

**Order of operations** (the owner runs; Claude edits `.sops.yaml` and the modules):

1. Deploy `sopsadmin` and the doas rule to hazel; generate the new key there; collect
   `ssh-to-age` of butternut's and hazel's host keys (maple's and peacelily's when reachable).
2. Rewrite `.sops.yaml` creation rules per file: `secrets/<host>/*` → admin + that host;
   `secrets/shared/tailscale*.yaml` → admin + every host; `secrets/shared/wifi*.yaml` → admin + the
   laptops + peacelily; `secrets/shared/user.yaml` → admin + all; `secrets/admin/*` and
   `shared/aws-sso.yaml` → admin only, as now.
3. `sops updatekeys -y` on every file while the *old* key is still available
   (`SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`), so each file gets the new recipient set.
4. Deploy hazel and butternut with `keyFile = null; sshKeyPaths = [...]`; check `/run/secrets`.
5. Delete `~/.config/sops/age/keys.txt` on hazel and butternut. maple and peacelily hold the legacy
   key on their disks until they are back online (both are down or not yet redeployed, per the
   registry TODOs); delete it as the first step of their bring-up.

**Rotation.** Age cannot revoke a key, and every ciphertext the old key protected is in the public
repository's history. Treat the old key's secrets as exposed to every process that ran on an agent
host, and rotate by value:

| Secret | Priority | Why |
|---|---|---|
| Tailscale reusable auth key, OAuth client | high | grants node identities |
| harmonia signing key (`butternut/nix-serve.yaml`) | high | a forged signature is trusted by hazel and `deploy` |
| fern's GitLab deploy key (`fern/workspace.yaml`) | high | repository access |
| LibreChat and Qdrant secrets (peacelily) | medium | rotate during bring-up anyway |
| Wi-Fi PSKs (`shared/wifi*.yaml`) | medium | owner decision; changing them touches the phone and the router |
| syncthing identities | low | device IDs change; re-pair the phone; the data is not secret |
| atuin key | low | rotation loses sync history; the history itself is the sensitive part |

Residual after layer 2: an agent on the owner UID can still read `/run/secrets/*` entries with
`owner = user` (today: the ntfy topic, the OpenCode password, fern's workspace key, secretspec files).
Review each `owner = user` and keep only what agents genuinely need; after layer 3, set `owner =
"agent"` for those.

### 3.3 Layer 3: the agent user model

**One user per host, named `agent`, fixed UID, no `wheel`, no doas rule, `linger = true`.**
Role-splitting is deferred: the natural second user is `agent-work` (routelab, d_abm, the work
Claude subscription), because its tokens must never be able to push work code into the public
`nixconf`; see §7. Per-thread users are not worth it: T3 already isolates threads into transient
scopes (`systemd-run --user --scope --slice=app-t3code-agents.slice`,
t3code@9762a3c:apps/server/src/process/agentScope.ts:23-33,169-180) and their worktrees, and a
thread's blast radius within one agent user is what the git flow already bounds.

Introduce `preferences.agents.user` (default: the owner's name) and make `agent-host`,
`agent-t3code`, `agent-opencode`, `agent-common`'s hooks and `workspace-bootstrap` consume it. Each
host then flips one option; the owner's user keeps `agent-client` (desktop app, Zed, `herdr --remote`).

**T3 Code as `agent`.** Keep the systemd user service exactly as in `agent-t3code.nix:584-639` but
under `home-manager.users.agent` (its own `~/.t3`). Two adjustments:

- `tailscale set --operator` accepts one user (`--operator=<user>`,
  [Tailscale CLI](https://tailscale.com/kb/1080/cli)); the owner needs it for `captive` (`dns.nix`).
  So drop `--tailscale-serve` from `ExecStart` and publish the loopback port with a root oneshot, the
  way `agent-opencode.nix:392-412` already does for OpenCode. The desktop app, pairing URL and
  `https://<host>.<tailnet>/` do not change.
- Pairing and linking become `doas -u agent -- t3 pair …` / `t3-link` run as the agent (the owner
  gets a rule `permit persist hfahmi as agent`, which also gives `doas -u agent -s` for a shell).

Do **not** use T3's "Desktop-managed SSH" environment for this: it "downloads its runtime to
`~/.t3/runtime` on the … host, starts or reuses a server" (t3code@9762a3c:docs/user/remote-access.md,
"Desktop-managed SSH"; "Cold archive launches download and extract ~70 MB",
packages/ssh/src/tunnel.ts:69). That is an auto-updating non-Nix runtime, which the integration spec
already rejected. T3 confirms the server's OS user is the boundary: "`terminal:operate` and
`orchestration:operate` already grant OS-user execution" (docs/internals/04_environment-auth.md), and
threads below Full access are fenced only by T3's own rules.

On hazel, T3 currently starts with the graphical session (`hosts/hazel/agents.nix`). As `agent`
with lingering it would run from boot; if battery matters, give the owner a polkit rule to
`systemctl start/stop t3code@agent` from the launcher instead of lingering [verify].

**OpenCode, herdr, hooks.** `opencode serve --service`, `herdr server` and `agent-run` move to the
agent's user manager unchanged. `oc` and `herdr --remote` on hazel connect as `agent@<target>`
(the owner's key goes into `users.users.agent.openssh.authorizedKeys.keys`; nothing goes the other
way). `cloud-idle-stop` must read the agent UID's `/run/user/<uid>/agent-status` and
`user-<uid>.slice` CPU, not the owner's.

**Credentials.**

| Credential | Recommended | Alternative | Notes |
|---|---|---|---|
| Claude (two subscriptions) | `doas -u agent -s`, then `claude` and `/login` once per config dir (`~agent/.claude`, `~agent/.claude-work`); T3 instance `homePath` points there (`agent-t3code.nix:545-561` already models `CLAUDE_CONFIG_DIR` per instance, as T3's doc recommends, docs/user/providers-claude.md:7-14) | `claude setup-token` into sops as `CLAUDE_CODE_OAUTH_TOKEN` in the service environment: "a one-year OAuth token … It can only make model requests" ([authentication doc](https://code.claude.com/docs/en/authentication)) | the interactive login refreshes itself and is revocable from claude.ai; `claude auth status --text` shows when it ends. Token reports: a stored env credential interfering with the saved login ([#104359](https://github.com/anthropics/claude-code/issues/104359)), model entitlement differences under `setup-token` auth ([#91852](https://github.com/anthropics/claude-code/issues/91852)), a 401 loop ([#58926](https://github.com/anthropics/claude-code/issues/58926)) |
| OpenCode | `opencode auth login` as agent; the `claude-agent` bridge reuses the Claude login | sops `ANTHROPIC_API_KEY` env file (`agent-opencode.nix:346-390`) | credentials live in `~agent/.local/share/opencode/opencode.db` |
| Codex (if enabled) | `codex login` device flow as agent | none needed | `~agent/.codex/auth.json` |
| GitHub | a fine-grained PAT per agent user, limited to the repositories it works on (Contents and Pull requests read/write, Metadata), loaded with `gh auth login --with-token` as agent; git over HTTPS through `gh auth git-credential` (`github.nix` already wires `/etc/gitconfig`) | SSH deploy keys per repository with `ProxyCommand` through the egress proxy | the gh device-flow token is a classic OAuth token over all your repositories: too broad for an agent. Fine-grained PATs expire; put the renewal in the calendar |
| GitLab | a project access token with `write_repository` + `api` for `glab` and HTTPS push | deploy key with write | as `scripts/fern/deploy-key.sh` does today, scoped per project |
| AWS | none on agent hosts until the Identity Center "agents" user exists (`2026-11-17-secrets-design.md` AWS plan); fern keeps its instance role | | the owner's `aws-login` stays on the owner UID, which agents can no longer read |
| tailnet | the host's node identity; no per-user credential | | ACLs are per node; §3.4 adds per-UID rules |

**Repositories: the shared surface is git.** The owner's checkouts stay where they are and stay
agent-free. The agent clones into `/home/agent/work/…` and `/home/agent/nixconf`;
`workspace-bootstrap.nix` already does exactly this for fern (clone from a remote named in sops,
pin `core.sshCommand`, register with T3) and is reused. Flow per project:

- GitHub-hosted repositories (`nixconf`, d_abm) and GitLab (routelab): the agent works on a branch in
  its clone, `agent-push`, `gh pr create`; you review and merge from your checkout. Nothing changes in
  the thread workflow except that `agent-push` should refuse a push whose diff contains a secret
  (`gitleaks protect --staged`-style pre-push scan; gitleaks 8.30.1 is in nixpkgs), because a branch
  pushed to the public `nixconf` is public immediately.
- Local-only repositories (attn until M5): a bare hub `/srv/git/attn.git` owned by a group with the
  owner and `agent` (`core.sharedRepository = group`); you push `main`, the agent clones and pushes
  branches, you fetch and review. This is nuketown's "shared surface is the git remote" without
  GitHub.
- `nixconf-sync` (owner ↔ owner between desktops) is unchanged.

ACLs on the owner's checkout are rejected: they expose every untracked file (`.env`, `.direnv`,
`.repos`), they would let the agent write `.git/hooks`, `.envrc`, `.claude/settings.json` and other
"files that later run on your host" (sbx-config@cc7951f:policy/README.md), and T3's worktree model
needs the agent to own `.git`.

**Dev shells.** direnv's `allow` is per user and content-bound: the allow file name is
`sha256(absolute path + "\n" + file content)` (direnv@main:internal/cmd/rc.go:371-392, `fileHash`).
Home-manager can therefore pre-create `~agent/.local/share/direnv/allow/<hash>` for each project's
committed `.envrc` from Nix (`builtins.hashString`), which is a declarative, content-pinned allow.
`direnv.toml`'s `[whitelist] exact` is the content-independent alternative and its own manual says to
use it "with great care" ([direnv.toml](https://direnv.net/man/direnv.toml.1.html)); avoid it.
`agent-devshell`'s worktree rule (identical `.envrc` to the main checkout) keeps working against the
agent's own main clone. nix-direnv caches live in the agent's checkouts; the store is shared through
the daemon, where `agent` is an ordinary untrusted user.

**GPU and devices.** peacelily's agents mostly talk to llama-swap over HTTP; if a thread needs CUDA
directly, add `agent` to `video`/`render` and check `ls -l /dev/nvidia* /dev/dri/*` on the box
[verify]. On butternut, T3's device support needs `kvm` (currently granted to the owner,
`agent-t3code.nix:701-705`) and the AVD home moves into the agent's routelab clone; T3's voice
transcription uses Vulkan (`LD_LIBRARY_PATH` in the unit), so `render` for the agent on the laptops
too.

**The owner's editor and terminal.** The agent user is reachable through sshd on `localhost:7654`
with the owner's key. Three surfaces, all precedented by agent-as-unix-user's `au sshd` / `au
vscode-url` (agent-as-unix-user@1c49e32:README.md:169-175):

- **VSCodium**: a Remote-SSH extension (nixpkgs packages Microsoft's
  `vscode-extensions.ms-vscode-remote.remote-ssh`, whose licence targets VS Code; the Open VSX
  "Open Remote - SSH" extension is the VSCodium-compatible one, installable with the
  `extensionFromVscodeMarketplace` helper `vscode.nix` already uses [verify]) opens
  `/home/agent/nixconf` over `agent@localhost`; the Claude extension then runs in the remote
  extension host as `agent`, and `claudeCode.claudeProcessWrapper` (`vscode.nix:98`) applies there.
- **Terminal**: `claude` on the owner's PATH becomes `ssh -t agent@localhost claude` (or `doas -u
  agent -s`), started in the agent's clone. The owner's own user gets no `claude` binary.
- **Zed**: its SSH remote projects do the same for ACP agents (`agent-client.nix` keeps Zed owner-side).

The real ergonomic change is that "my checkout" and "the agent's checkout" are two working trees.
Everything that depends on the owner's tree (deploy, `just status`, `nixconf-sync`) keeps working
unchanged; review happens on fetched branches, as the PR flow already requires.

**Wayland, D-Bus, clipboard.** Agents lose them, which is the point. `agent-notify` currently calls
`notify-send` from hooks; as `agent` it has no session bus, so add a bridge: hooks append a line to a
group-writable spool (`/run/agent-notify/<uid>/`), and an owner path unit turns new lines into
`notify-send` (plus ntfy as today). T3 shows its own notifications. The T3 server's headless Chromium
works without a display.

**Resource caps.** Replace the per-user `agents.slice` with properties on `user-<uid>.slice`
(`systemd.slices."user-1100".sliceConfig`), the same numbers as `agent-host.nix:51-63`; T3's own
`app-t3code-agents.slice` nests underneath.

**fern and peacelily.** fern adopts the agent user from its first deploy (`workspace-bootstrap` as
`agent`, the deploy key owned by `agent`). peacelily gets `agent-host` as `agent` during bring-up,
with llama-swap on loopback for it and the tailnet for the others.

Residual after layer 3: anything the agent user itself holds (its Claude login, its scoped tokens,
the code it works on) can still leave through any network path it has. That is layer 4. Kernel and
setuid bugs remain the escape class; `ptrace_scope` and no setuid helpers in the agent's PATH keep
that surface small.

### 3.4 Layer 4: egress

**Principle.** The kernel decides who may open which connection; a proxy decides which names are
allowed; `HTTPS_PROXY` is only how well-behaved tools find the proxy. The three-UID post's rules
(`meta skuid <agent> drop` after loopback and DNS accepts) are the model; this fleet's firewall is
iptables (`trusted-networks.nix` asserts the iptables backend), and iptables has the same primitives:
`-m owner --uid-owner` / `--gid-owner` in OUTPUT and `-m cgroup --path` for cgroup v2 paths.

Rules per agent host, OUTPUT chain, in the order given (sketch; `agent` and `egress` are user names
resolved at load):

```
# the proxy UID is the exit: it may dial the world (its allowlist decides)
-m owner --uid-owner egress -j ACCEPT
# agents: loopback to the proxy and the agent DNS only
-m owner --uid-owner agent -o lo -p tcp -d 127.0.0.1 --dport 3128 -j ACCEPT
-m owner --uid-owner agent -o lo -p udp -d 127.0.0.2 --dport 53   -j ACCEPT
-m owner --uid-owner agent -o lo -p tcp -d 127.0.0.2 --dport 53   -j ACCEPT
# agents: their own services and dev servers on loopback, minus the owner's services
-m owner --uid-owner agent -o lo -p tcp -m multiport --dports 5600,8384,2283,8178 -j REJECT
-m owner --uid-owner agent -o lo -j ACCEPT
# agents: named tailnet services (llama-swap on peacelily, butternut's cache), nothing else on the tailnet
-m owner --uid-owner agent -o tailscale0 -d <peacelily ts4> -p tcp --dport 9292 -j ACCEPT
-m owner --uid-owner agent -o tailscale0 -d <butternut ts4> -p tcp --dport 5000 -j ACCEPT
# the Nix daemon's builders and fetchers: proxy only
-m owner --gid-owner nixbld -o lo -p tcp -d 127.0.0.1 --dport 3128 -j ACCEPT
-m owner --gid-owner nixbld -j REJECT
-m cgroup --path system.slice/nix-daemon.service -o lo -p tcp -d 127.0.0.1 --dport 3128 -j ACCEPT
-m cgroup --path system.slice/nix-daemon.service ! -o lo -j REJECT
# everything else from agents
-m owner --uid-owner agent -j REJECT --reject-with icmp-admin-prohibited
```

`REJECT` rather than `DROP`, as the devcontainer script does ("for immediate feedback",
anthropics/claude-code@102fafb:.devcontainer/init-firewall.sh:118-119): a tool fails at once with
"Network is unreachable" instead of hanging. The loopback denylist of owner services exists because
`-m cgroup` cannot classify incoming SYNs to a listening socket (the iptables extension matches
"only … on INPUT … for packets with a socket early demuxed"), so "only sockets the agent owns" cannot
be expressed; the denylist is generated from the owner-side services the configuration declares
(attn 5600, Syncthing GUI 8384, Immich 2283, the dictation server 8178, the owner's own T3 if any).
The agent's own T3 server (`:3773`, needed for its MCP tools) and OpenCode (`:49374`) are agent-owned
and stay reachable. The addresses for tailnet rules come from the registry's `ts4` fields, which the
rules can reference by name through `/etc/hosts` [verify that iptables resolves names at load, or
emit the addresses from Nix].

**The proxy.** Two implementations, in order:

1. **Phase-1 stand-in: tinyproxy** (NixOS module `services.tinyproxy`), one instance, `Listen
   127.0.0.1`, `Allow 127.0.0.1`, `FilterDefaultDeny Yes`, `Filter` pointing at a generated domain
   list, `ConnectPort 443` and `22` (for SSH-over-CONNECT), `LogLevel Connect`. Zero code, kernel
   boundary in place in a day. Limits: it logs the client as `127.0.0.1` with no UID, reloads its
   filter only on `SIGHUP`, returns a generic 403 page.
2. **`agent-egress`, a small purpose-built CONNECT proxy** (Python stdlib asyncio or Go, a few
   hundred lines, unit-tested like `agent-env/tests/`). What it adds over tinyproxy, and why it is
   worth owning:
   - **attribution by UID without privileges**: on each accepted connection, look up the client
     `(ip:port)` in `/proc/net/tcp` and `/proc/net/tcp6`, whose `uid` column is world-readable;
     map UID → role (`agent`, `agent-work`, `nixbld`/`nix-daemon`). PID and cgroup need
     `/proc/<pid>/fd`, which another user cannot read, so thread-level attribution comes from the
     agent side (below), never trusted for authorization.
   - **roles**: one allowlist per role, each a merge of the declarative list (`allowlist.nix`,
     rendered to JSON) and a runtime overlay directory (`/run/agent-egress/allow.d/<role>/`,
     tmpfs, gone at reboot) with per-entry TTLs; `inotify` on the directory, no reload needed.
   - **a legible refusal**: `HTTP/1.1 403 Forbidden`, `X-Egress-Decision: denied`, body
     `egress: <host>:<port> is not allowed for role <role> on <host>. request id <id>. The owner
     can allow it with: egress allow <host> --role <role>`. This is `srt`'s design choice ("so the
     agent can tell a policy block from a network failure",
     sandbox-runtime@0bbebed:src/sandbox/request-filter.ts:26-31). For CONNECT, curl reports
     "Received HTTP code 403 from proxy after CONNECT", git and nix the same; Node and Bun surface
     the status.
   - **metered guard**: the proxy reads `agent-net --json` (it runs as its own user; nmcli reads
     work for any user) and, when metered, caps bytes per tunnel and per role per day (defaults in
     the module, e.g. 50 MB per tunnel, 500 MB per day), refusing new tunnels past the budget with a
     distinct reason (`metered-budget`) that the unblock tool can lift. `nx` keeps its own gate for
     Nix pulls; the proxy's byte counters are the enforcement that `agent-env`'s design explicitly
     left out ("Nothing blocks network access").
   - **logging**: one journald entry per decision with structured fields (`EGRESS_UID`,
     `EGRESS_ROLE`, `EGRESS_HOST`, `EGRESS_PORT`, `EGRESS_DECISION`, `EGRESS_REASON`,
     `EGRESS_BYTES`, `EGRESS_MS`), so `journalctl -t agent-egress EGRESS_DECISION=denied` is the
     audit log, and a denial also lands in `/run/agent-egress/requests/<id>.json` for the tool below.
   - **resolution**: the proxy resolves allowed names itself through systemd-resolved and refuses
     names that resolve to loopback, link-local or the LAN unless the entry says so (the `srt`
     "resolved-address check", README.md:1323; ai-jail's private-address classes).

   Alternatives considered: Squid (SNI peek/splice, `-k reconfigure`, ACL files; heavier, same UID
   blindness); `srt --proxy-only` (sandbox-runtime@0bbebed:src/sandbox/proxy-only.ts) with a
   decider process is close, but it is a beta whose "configuration format may change"
   ([sandbox environments doc](https://code.claude.com/docs/en/sandbox-environments)), is Node, and
   its ask-user path is built for the Claude TUI; mitmwall/exwall and sandcat terminate TLS and
   need a CA in every client (Node `NODE_EXTRA_CA_CERTS`, Python, curl, git, Bun, the Nix daemon),
   which gh-aw-firewall also rejected for the default ("Why Squid Over mitmproxy"). TLS termination
   stays an optional mode for GitHub path rules (§7).

**DNS.** Agents must not reach `127.0.0.53` or any resolver except their own: a second `dnsmasq`
instance on `127.0.0.2:53` whose configuration is generated from the same allowlist
(`server=/<domain>/127.0.0.53` per allowed domain, `address=/#/` for everything else, re-read on
`SIGHUP` via `servers-file`). Tools that resolve before they CONNECT (some pre-flight checks,
`ssh` with `ProxyCommand`, `ping`) get an answer for allowed names and a refusal for others; DNS
tunnelling to arbitrary names (the CVE-2025-55284 class) is closed at the kernel. The proxy itself
resolves through resolved as the `egress` user. gh-aw-firewall does the equivalent with "DNS to
trusted servers only".

**The Nix daemon hole, confirmed and closed.** The Nix manual: "Fixed-output derivations do not run in
private network namespace to ensure they can access the network"
([conf-file](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html)), and fetchers pass
`impureEnvVars = [ "http_proxy" "https_proxy" … ]` from the daemon's environment into the build
([advanced attributes](https://nix.dev/manual/nix/2.34/language/advanced-attributes.html)). Builders
run as `nixbld<N>` (group `nixbld`) inside `nix-daemon.service`'s cgroup, so per-UID agent rules do
not see them: an agent can write a fixed-output derivation whose fetch URL carries data to any host.
Closing it: (a) `systemd.services.nix-daemon.environment = { http_proxy = …; https_proxy = …;
no_proxy = "localhost,127.0.0.1,<tailnet suffix>,100.64.0.0/10"; }` so substitutions and
fixed-output fetches go through the proxy under the `nix` role; (b) the `nixbld` group and the
daemon cgroup rules above, so a builder that ignores the proxy is rejected. What remains is a
fixed-output fetch to a host on the `nix` role's allowlist (caches, GitHub, PyPI, npm): the same set
the agent already has, logged as role `nix`. Evaluation-time fetches (`flake` inputs,
`builtins.fetchurl`) run in the agent's own `nix` process and are covered by the agent rules. Hazel's
offloaded builds reach butternut as root over SSH and are unaffected.

**Tailnet.** Tailscale ACLs see nodes, not users, so the per-UID `tailscale0` rules above are the
only per-user control on the tailnet; the allowed pairs come from the registry (`roles`: `gpu` →
9292, `cache` → 5000). Linked T3 environments (`t3-link`) run server-to-server over HTTPS to the
other host's T3 port; add that pair when linking is used.

**SSH for git.** With `git_protocol = ssh` (`github.nix`), the agent's git would need
`ProxyCommand nc -X connect -x 127.0.0.1:3128 %h %p` and `github.com:22` on the allowlist. HTTPS
with the fine-grained PAT is simpler and is what the proxy sees best; recommended for the agent user
only (the owner keeps SSH).

**Clients that ignore the proxy.** Claude Code honours `HTTPS_PROXY` and documents its own hosts
([network configuration](https://code.claude.com/docs/en/network-config)); Node and Bun fetch, curl,
git, pip, cargo, gh, glab, nix all do. UDP and raw TCP tools fail closed, visibly. T3 pins the
environment per provider instance in the policy (`limits.providers.instances.<driver>.environment`,
t3code@9762a3c:docs/user/managed-policy.md:86-89), so `HTTPS_PROXY`, `NO_PROXY` and
`NODE_EXTRA_CA_CERTS` (if TLS termination is ever enabled) are declarative for every T3 thread, and
the agent's systemd units carry the same variables for OpenCode and hooks.

Residual after layer 4: exfiltration to an allowlisted sink the attacker can read (your own public
repositories, any site with user-generated content on the list); covert channels in allowed traffic
(timing, sizes); the model API itself carries everything the agent reads, by design; a root
compromise removes the rules. The proxy's logs make the first two auditable; scoped tokens and the
pre-push secret scan shrink the first.

### 3.5 Layer 5: the egress unblock tool (your idea, made concrete)

**What it is.** `egress`, one CLI with four verbs, a notification path, and a log. Agents cannot
approve anything: the control socket `/run/agent-egress/control.sock` is `root:egress-admin 0660`
with only the owner in `egress-admin`, and the proxy checks `SO_PEERCRED` on every control message.
Approvals are deliberate owner actions with a durable record.

**Flow of a blocked request.**

1. The agent's tool opens `https://docs.example.org/…`. The proxy finds no match for role `agent`,
   answers the 403 with the legible body, logs `EGRESS_DECISION=denied`, writes
   `/run/agent-egress/requests/<id>.json` (`{id, time, uid, role, host, port, reason}`), and pokes
   the owner-side watcher.
2. The agent learns it is a policy block, not a broken network: the tool output contains the
   403 text with the host and the request id. For Claude, a `PostToolUse` hook (fast, local, like
   `agent-net`'s hooks) reads new denials for its UID since the tool started and emits
   `additionalContext`: "egress blocked <host> (request <id>). This is policy, not an outage. Tell the
   user; do not retry or route around it." OpenCode gets the same through its instructions file. The
   agent's message to you in T3 then names the host and why it wants it. The hook also *claims* the
   request by appending `{session_id, cwd, tool, command}` to the request file: thread-level
   attribution, supplied by the agent (informative), next to the UID (authoritative).
3. You are told: the owner-side watcher (a path unit on the requests directory) sends a desktop
   notification ("agent (thread nixconf/feature-x) asked for docs.example.org:443, request 7f3a") and,
   through `agent-notify`, an ntfy push when you are away. ai-jail's `--prompt-hosts` is the
   precedent for notify-and-hold; here the request fails fast and you answer asynchronously, which
   suits T3's asynchronous threads better than holding a socket for 60 s.
4. You decide, from any owner shell (fish): `egress allow docs.example.org` (role defaults to the
   requesting role; `--role`, `--port`, `--ttl 4h`; default TTL "until reboot"), `egress deny
   docs.example.org --ttl 1d` (silence repeat notifications), or nothing. The proxy appends the entry
   to the runtime overlay, answers the socket with the new state, and the agent's next attempt
   succeeds. `egress pending` lists open requests; `egress log --denied --since 1d` reads journald.
5. Keeping it: `egress propose [<host>…]` writes a diff to
   `modules/nixos/features/agent-egress/allowlist.nix` with a comment per entry (`# <date> for
   <role>; requested by <thread/tool>; reason`), which you commit, or hand to a thread as a patch. The
   runtime entry lapses at reboot; the declarative one is the record you wanted: what agents talk to,
   through which tool, since when. Nothing agents can write feeds that file into the running proxy.

**Authorization path, explicitly.** Owner UID only, by file permissions and `SO_PEERCRED`; a
desktop-notification action runs the CLI in your terminal rather than approving from the
notification (notification actions are not an authenticated channel). From the phone: later, a T3
MCP tool exposed only to the owner's paired client with `access:write`, or an ntfy action against an
owner-authenticated endpoint; not in the first version.

**Starter allowlist** (per role; everything else is a request):

| Role | Hosts | Source |
|---|---|---|
| Claude (both subscriptions) | `api.anthropic.com`, `claude.ai`, `claude.com`, `platform.claude.com`, `downloads.claude.ai` (version checks are off, keep for `/release-notes`), `code.claude.com`, `raw.githubusercontent.com`, `registry.npmjs.org` (plugins, `npx` MCP servers), `github.com` (plugin marketplaces); **deny** `*.datadoghq.com` and set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | [network configuration](https://code.claude.com/docs/en/network-config) |
| OpenCode | `api.anthropic.com` (via the Claude bridge), `models.dev` (model catalogue) [verify], the OpenCode docs host for `/docs` lookups | `2026-11-17-opencode-integration.md` |
| Codex (if enabled) | `api.openai.com`, `chatgpt.com`, `auth.openai.com` | Codex docs |
| git forges | `github.com`, `api.github.com`, `codeload.github.com`, `objects.githubusercontent.com`, `raw.githubusercontent.com`, `gitlab.com` | sbx-config@cc7951f:policy/allow/claude-nix.txt; `github.nix` |
| packages | `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`, `crates.io`, `static.crates.io`, `huggingface.co`, `cdn-lfs.huggingface.co` (dictation models) | the fleet's dev shells |
| nix (daemon + agent evaluation) | `cache.nixos.org`, `tarballs.nixos.org`, `channels.nixos.org`, `cache.nixos-cuda.org`, `noctalia.cachix.org`, `cache.numtide.com`, `github.com` and the forge hosts above, `api.flakehub.com` if adopted | `nix.nix:28-39`, backlog |
| docs and search | `nixos.org`, `search.nixos.org`, `nixos-search.netlify.app`, `nix.dev`, `discourse.nixos.org`, `home-manager-options.extranix.com`, `developer.mozilla.org`, `docs.python.org`, `developer.android.com` …; `mcp-nixos` needs `search.nixos.org`, `nixhub.io`, `api.flakehub.com` | the MCP servers in `agent-common.nix`; grow by request |
| notifications | `ntfy.sh` (until self-hosted on peacelily) | `agent-common.nix` |
| tailnet | peacelily:9292 (llama-swap), butternut:5000 (cache), the other T3 hosts' 443 when linked | registry roles |

Claude's WebSearch is server-side (through `api.anthropic.com`); WebFetch is client-side and
unsandboxed, so it is exactly the tool that will hit the proxy most: pre-allow the documentation
hosts you use, and let the rest arrive as requests.

**Interaction with Claude's own sandbox, if you later enable it as an inner layer.**
`sandbox.network.httpProxyPort` can point at `agent-egress`, `allowManagedDomainsOnly` makes Claude
refuse instead of prompting, and the managed file `/etc/claude-code/managed-settings.json`
([managed settings](https://code.claude.com/docs/en/managed-settings)) is the right place for the
deny rules `agent-common.nix` currently merges into each user's `settings.json`; it applies to every
UID, and `allowManagedPermissionRulesOnly` stops a repository from widening it. Note the doc's own
caveat: "a developer who is an administrator on the machine can edit the managed source", which is
why the user split and the firewall come first.

---

## 4. Residual risk and daily cost, per layer

| After layer | What an agent can still do | What it costs you per day |
|---|---|---|
| 0 (today) | everything the owner can, including root and the primary key | nothing |
| 1 root | everything the owner can except root; the primary key still decrypts everything | a password per `doas` and per deploy target |
| 2 secrets | read `owner = user` secrets; read your `~/.ssh`, tokens, vault file, clipboard | a password when editing secrets |
| 3 agent user | act with its own scoped tokens and Claude login; read and push the code it works on; reach any network host | two working trees per project; `ssh agent@localhost` for the editor; one-time logins per host |
| 4 egress | send data only to allowlisted hosts (your own public repos included) and only the bytes the metered budget allows; be visible in the log | occasional 403 → request |
| 5 unblock | same, with every exception recorded | approving a few hosts a week at first, rarely later |
| later: nspawn or microVM for a repository you do not trust | nothing on the host beyond the share | a VM per project |

---

## 5. Phased rollout, ordered by risk reduction per unit of effort

Each phase ends with `just check` and a deploy by you. Owner steps are fish lines; multi-line logic is
a bash script. Claude edits files; you run what only you can.

**Phase 0 (hours): cheap hygiene, no behaviour change for you.**
Pin `kernel.yama.ptrace_scope = 1`; move the Claude deny rules to `/etc/claude-code/managed-settings.json`
and add `Read(~/.ssh/**)`, `Read(~/.aws/**)`, `Read(~/.config/gh/**)`, `Read(~/.local/share/keepassxc/**)`,
`Read(~/Vault/**)`, `Read(~/.t3/**)`, `Read(~/.local/share/opencode/**)`, `Read(//run/secrets/**)`,
`Read(//var/lib/attn/**)` and `Bash(curl*:5600*)`; mirror them in OpenCode `policies`. These are
courtesy fences until layer 3, and still useful afterwards against mistakes.

**Phase 1 (one evening): root.** Prerequisite: user-actions 7a-c (keys verified, password from sops,
SSH passwords off). Then `doas.nix` password + `persist`, `deploy.sh` single-prompt activation,
`trusted-users = ["root"]`, signing keys, `trusted-substituters`.

```fish
# 1. new password hash into sops (user-actions 7c), then deploy hazel first and test:
doas true                       # must prompt now
nix run .#deploy -- --plan butternut
just deploy butternut --dry-run # one password prompt from butternut
# 2. verify the untrusted paths:
nix config show | grep -E '^(trusted-users|trusted-substituters|trusted-public-keys) '
nix store verify --sigs-needed 1 /run/current-system   # signed by a key every host trusts
```

**Phase 2 (one evening plus waiting for maple/peacelily): secrets.**

```fish
# on hazel, after deploying the sopsadmin user and its doas rule
doas -u sopsadmin sh -c 'mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/keys.txt'   # prints the public key: paste into .sops.yaml as &admin
for h in butternut hazel
    ssh $h cat /etc/ssh/ssh_host_ed25519_key.pub | nix shell nixpkgs#ssh-to-age -c ssh-to-age   # &<host> recipients
end
```

```bash
#!/usr/bin/env bash
# re-encrypt every file to the new recipient set while the OLD key is still present
set -euo pipefail
cd ~/nixconf
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
find secrets -name '*.yaml' -print0 | xargs -0 -n1 sops updatekeys -y
git add -N . && git diff --stat
```

Then: deploy hazel and butternut with host-key sops, check `/run/secrets`, `shred -u
~/.config/sops/age/keys.txt` on both, rotate the high-priority values in §3.2, and re-run the same
on maple and peacelily when they come back (bring-up §3.2 already plans this).

**Phase 3 (a weekend, host by host): the agent user.** butternut first (the agent host), then
hazel, then peacelily during bring-up, fern from its first deploy.

```fish
# after deploying the agent user on butternut (the owner's key is authorized for it)
ssh -p 7654 agent@butternut true
doas -u agent -s                    # or: ssh -t agent@localhost on the host itself
#   inside: claude  → /login ;  CLAUDE_CONFIG_DIR=~/.claude-work claude → /login ;  opencode auth login
#   gh auth login --with-token < /dev/tty   (paste the fine-grained PAT)   ;  glab auth login --token
exit
doas -u agent -- t3 pair --base-dir /home/agent/.t3 --label hazel-desktop   # re-pair the desktop app once
```

Checks: `systemctl --user -M agent@ status t3code opencode herdr`; a thread in T3 lands in
`/home/agent/.t3/worktrees`; `agent-push` opens a PR; VSCodium Remote-SSH opens `/home/agent/nixconf`.

**Phase 4 (a week, mostly waiting for requests): egress.** Stand-in tinyproxy plus the iptables
owner rules and the agent DNS; flip the T3 policy environment and the agent units to the proxy; watch
`journalctl -t tinyproxy` for a few days and seed the allowlist; then replace tinyproxy with
`agent-egress` and ship `egress allow|deny|pending|log|propose`.

```fish
egress pending
egress allow docs.rs --ttl 8h
egress propose docs.rs    # prints the allowlist.nix diff; commit it from your checkout
egress log --denied --since 1d
```

**Phase 5 (optional, later):** `pam_u2f` for doas; a TLS-terminating mode (exwall-style rules) for
GitHub path and method rules; Claude's sandbox inside the agent user as an inner layer once the
NixOS bwrap issues are fixed upstream; `nixos-container` or microvm.nix for repositories you do not
trust (hyperhive and Stapelberg's setups are the templates).

Dependencies: Phase 1 needs the sops password (user-actions 7c). Phase 2 needs maple and peacelily
online to finish, but hazel and butternut can finish alone. Phase 3 needs Phase 1 (the agent must not
inherit a passwordless doas by accident) and should follow Phase 2 (so the agent host never saw the
new key). Phase 4 needs Phase 3 (per-UID rules need the UID). attn's P0 is satisfied by Phases 1-3.

---

## 6. Where this deviates from the quick research

- **T3 "remote environment over `ssh agent@localhost`"**: unnecessary and harmful. T3's SSH
  environments download a ~70 MB runtime into `~/.t3/runtime` (t3code@9762a3c:docs/user/remote-access.md,
  packages/ssh/src/tunnel.ts:69). Running the existing `t3 serve` unit as `agent` keeps Nix as the
  only source of binaries and changes nothing in the UI.
- **ACL-based folder grants** (agent-as-unix-user's `au mount`, the DEV posts): rejected for the
  owner's checkouts, for nuketown's reason and because of the "files that later run on your host"
  class (`.git/hooks`, `.envrc`, `.claude/settings.json`). Git remotes and a local bare hub instead.
- **`claude setup-token` via sops**: the fallback, not the default. The interactive login per agent
  user refreshes itself and is revocable; the token is a one-year static credential in git
  ciphertext that "can only make model requests".
- **A group-readable Claude credentials file** shared between owner and agent: no. Separate logins
  are what makes revocation per host and per role possible.
- **bubblewrap wrappers (claudebox and friends) as the boundary**: no; their authors say so, and on
  NixOS the Claude sandbox currently fails with nix-direnv symlinks and worktrees (#104685, #17374).
  They return as an optional inner layer.
- **The three-UID pattern's "DNS to the loopback resolver is allowed"**: tightened to an allowlist
  resolver, because of CVE-2025-55284.
- **mitmwall**: its author now points to a Rust port, exwall; TLS termination stays optional here.
- **The nix-daemon fixed-output hole**: confirmed from the Nix manual, closed by the daemon's proxy
  environment plus `nixbld` and cgroup rules, not by trying to deny fixed-output network access.
- **Separate user per role** (nuketown's `ada`, `vox`, `rio`): start with one per host; split by
  trust domain only if you decide work and personal credentials must never share a UID (§7).

---

## 7. Open questions for you

1. **One agent user per host, or `agent` + `agent-work`?** Two users double the logins, T3 servers
   and ports, but guarantee that a work token can never push into the public `nixconf` and that the
   two Claude subscriptions never share a filesystem. My recommendation: one `agent` now; split only
   if the work projects' policies require it.
2. **Any Claude on the owner UID during the transition?** The convenient "Claude in my own VSCodium
   window" is the thing being removed. Options: none (recommended end state); or a transitional
   owner-UID Claude restricted to `nixconf` with `blockReadsOutsideWorkingDirectories`, knowing it
   is a fence, not a wall.
3. **TLS termination for GitHub path rules** (allow pushes only to your repositories, deny gists and
   issue comments elsewhere): gains real control over the one allowlisted sink that is also a public
   read channel; costs a CA in every client and plaintext at the local proxy. Default no; revisit
   after a month of logs.
4. **Which secret values to rotate** beyond Tailscale, the signing key and the deploy key: Wi-Fi
   PSKs and syncthing identities are your call.
5. **Tailscale SSH**: keep (`check` mode, 12 h) or drop now that every other root path is closing.
6. **attn's third recipient**: host key + offline vault key only (the review's wording), or also the
   `sopsadmin` key for convenience.
7. **hazel's agent T3 on battery**: lingering from boot, or started with your session by a polkit
   rule.

---

## 8. Sources

Repository (`main`, 2026-11-28): `modules/nixos/features/{doas,nix,sops,openssh,tailscale,github,
agent-common,agent-env,agent-host,agent-client,agent-t3code,agent-opencode,nix-builder,nix-serve,
lan-cache,trusted-networks,dns,secretspec,workspace-bootstrap,server-mode,activitywatch}.nix`,
`modules/nixos/features/agent-env/{agent_net,agent_git,agent_devshell,nx}.py`,
`modules/packages/{deploy.sh,fleet-lib.sh,deploy.nix}`, `modules/hosts-registry.nix`,
`modules/nixos/hosts/*/`, `.sops.yaml`, `secrets/README.md`, `scripts/install-host.sh`,
`.claude/settings.json`, `docs/plans/2026-11-17-{agentic-workspace-design,aws-agent-host,
secrets-design,t3code-integration,opencode-integration,agent-environment-design,github-auth-design}.md`,
`docs/plans/2026-11-24-peacelily-bring-up.md`, `docs/plans/2026-11-25-attention-tracker-{design,review}.md`.
Live: `nix config show` (Nix 2.34.9), `/proc/sys/kernel/yama/ptrace_scope`, Claude Code 2.1.282,
nixpkgs `2074cc67` (nixos-26.05): doas 6.8.2 `--with-timestamp`, tinyproxy 1.11.3, squid 7.6,
dnsmasq 2.93, mitmproxy 12.2.3, gitleaks 8.30.1, bubblewrap 0.12.0, age-plugin-yubikey 0.5.1,
age-plugin-fido2-hmac 0.5.0, pam_u2f 1.4.0, sops 3.13.3.

Upstream code (shallow clones, 2026-11-28):
pingdotgg/t3code@9762a3c2195e04678661fc6a6c73d364e3911d46 (docs/user/remote-access.md,
docs/user/managed-policy.md, docs/user/providers-claude.md, docs/user/background-service.md,
docs/internals/04_environment-auth.md, docs/internals/05_remote.md,
apps/server/src/process/agentScope.ts, packages/ssh/src/tunnel.ts);
anthropic-experimental/sandbox-runtime@0bbebed0aa9a8e628dc4df8bc30293550a1988eb (README.md,
docs/srt-proxy.md, src/sandbox/{request-filter,decider-client,http-proxy,proxy-only,
linux-sandbox-utils}.ts); numtide/claudebox@2a937ed; akitaonrails/ai-jail@83339b7;
esamattis/mitmwall@553b2ee; VirtusLab/sandcat@405ed10; touilleMan/agent-as-unix-user@1c49e32;
stanford-scs/jai@ed1f58e; jhhuh/claude-code-nix-sandbox@a23ccb3; ncrmro/nix-agent-sandbox@4b1f5b9;
grigio/sandbox-bwrap-nix@b630892; GRBurst/ai-sandbox@5d017f5; CaptainMcCrank/SandboxedClaudeCode@9566adf;
matgawin/bubblewrap-claude@6ce5f40; DiamondLightSource (gilesknap)/claude-sandbox@f2198c0;
curantes/sbx-config@cc7951f; Mic92/sops-nix@d5abe5e; Duncaen/OpenDoas@b96106b7e34ac591ae78b1684e9be3a265122463;
nuketownada/nuketown@57a7b621771568d3a9a78ae2637467c6cb528171 (README, via the GitHub API);
anthropics/claude-code@102fafb0953d90cff472b438e443485e7d131d36 (.devcontainer/init-firewall.sh);
getsops/sops@5032a7184f1a1cac0f8cf3bc6b680b339a500395 (age/keysource.go); direnv/direnv main
(internal/cmd/rc.go `fileHash`); hyperhive (git.berlin.ccc.de/vinzenz/hyperhive, README on `main`).
Skipped as too large for the metered link: getsops/sops (145 MB) and anthropics/claude-code (36 MB)
were read file-by-file through the API; T3 Code (1.2 GB) was sparse-checked-out (docs, auth, cli,
peer, environment, contracts, desktop sources only).

Documentation and write-ups: Claude Code [sandboxing](https://code.claude.com/docs/en/sandboxing),
[sandbox environments](https://code.claude.com/docs/en/sandbox-environments),
[network configuration](https://code.claude.com/docs/en/network-config),
[settings](https://code.claude.com/docs/en/settings), [permissions](https://code.claude.com/docs/en/permissions),
[managed settings](https://code.claude.com/docs/en/managed-settings),
[authentication](https://code.claude.com/docs/en/authentication), [security](https://code.claude.com/docs/en/security),
[corporate launcher](https://code.claude.com/docs/en/corporate-launcher);
Anthropic, [Beyond permission prompts](https://www.anthropic.com/engineering/claude-code-sandboxing);
Codex [sandboxing](https://learn.chatgpt.com/docs/sandboxing); Docker Sandboxes
[network access policies](https://docs.docker.com/ai/sandboxes/governance/access-controls/network/);
Nix manual [configuration settings](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html) and
[advanced attributes](https://nix.dev/manual/nix/2.34/language/advanced-attributes.html);
[nftables manual](https://www.netfilter.org/projects/nftables/manpage.html);
[direnv.toml](https://direnv.net/man/direnv.toml.1.html); [Tailscale CLI](https://tailscale.com/kb/1080/cli);
[tinyproxy.conf](https://github.com/tinyproxy/tinyproxy/blob/master/docs/man5/tinyproxy.conf.txt.in);
Stapelberg, [Coding agent VMs on NixOS with microvm.nix](https://michael.stapelberg.ch/posts/2026-02-01-coding-agent-microvm-nix/);
[The three-UID containment pattern](https://dev.to/luckypipewrench/the-three-uid-containment-pattern-for-ai-agents-on-linux-13bd);
gh-aw-firewall [security architecture](https://github.github.io/gh-aw-firewall/reference/security-architecture);
NixOS Discourse [Claude Code and security isolation](https://discourse.nixos.org/t/claude-code-and-security-isolation/71543);
[joshtronic](https://joshtronic.com/2026/07/12/sandbox-coding-agents/);
[Keeping secrets from Claude Code](https://patrickmccanna.net/keeping-secrets-from-claude-code/);
Claude Code issues #9102, #41505, #54321, #17374, #86855, #104685, #89931, #95532, #87381, #112775,
#104359, #91852, #58926.

Security research: [CVE-2025-55284](https://nvd.nist.gov/vuln/detail/cve-2025-55284) and
[Embrace The Red](https://embracethered.com/blog/posts/2025/claude-code-exfiltration-via-dns-requests);
[Invariant Labs, GitHub MCP](https://invariantlabs.ai/blog/mcp-github-vulnerability);
[Legit Security, CamoLeak](https://legitsecurity.com/blog/camoleak-critical-github-copilot-vulnerability-leaks-private-source-code);
[Pillar Security, Rules File Backdoor](https://pillar.security/blog/new-vulnerability-in-github-copilot-and-cursor-how-hackers-can-weaponize-code-agents);
arXiv [2610.22987](https://arxiv.org/pdf/2610.22987), [2609.38983](https://arxiv.org/pdf/2609.38983),
[2608.27299](https://arxiv.org/pdf/2608.27299), [2509.05755](https://arxiv.org/pdf/2509.05755),
[2509.24240](https://arxiv.org/html/2509.24240v1), [2608.30686](https://arxiv.org/pdf/2608.30686),
[2608.27092](https://arxiv.org/pdf/2608.27092).
