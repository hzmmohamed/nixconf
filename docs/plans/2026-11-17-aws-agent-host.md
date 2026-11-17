# On-demand AWS agent host: `fern` (2026-11-17)

An EC2 box that runs this flake's `agent-host` profile next to the d_abm data in
S3 (eu-central-1). You start it when you need it, drive T3 Code from hazel or the
phone over Tailscale, and it powers itself off when it goes idle. Only the T3 UI
(websocket text) and SSH travel over your connection. The data, the agents' tool
calls and the Nix downloads stay inside AWS. That makes it usable from a café on
mobile data.

Related: `2026-11-17-agentic-workspace-design.md` (§ AWS target),
`2026-11-17-network-review.md` (tags, OAuth login), `2026-11-17-secrets-design.md`
(AWS identities, per-host sops keys), `2026-11-17-t3code-integration.md`,
`2026-11-17-repo-size-and-parallelism.md` (§3.1 shared reference dir),
`docs/tailscale-policy.hujson`.

**Name:** `fern` (a plant, no clash). You can rename it: the name lives in
`modules/nixos/hosts/fern/`, the registry entry in `modules/hosts-registry.nix`,
`var.name` in `infra/aws/` and `CLOUD_BOX_NAME` for `cloud-box`.

## TL;DR

| Decision | Choice | Why |
|---|---|---|
| Image / boot | **Official NixOS AMI + bootstrap user-data, then `just deploy fern`**. Builds run **on the box** (`nix build --store ssh-ng://fern`) | No multi-GB image upload over Egyptian ADSL, no `vmimport` role or import bucket. After the first boot it is updated like every other host |
| Base AMI | `nixos/25.11.*-x86_64-linux` (owner 427812963091, the NixOS project), legacy BIOS | No 26.05 AMI is published in eu-central-1 yet (checked 2026-11-17). The first deploy takes the box to 26.05 |
| Tailscale | Tags `tag:cloud` + `tag:agent-host`, **not ephemeral**, no key expiry (tagged). First login with a **one-time** pre-authorized key in user-data, then the OAuth client from sops | `tailscaled` state survives stop/start on EBS. An ephemeral node would be deleted while stopped and come back as a new node (new IP, `fern-1`, T3 pairing broken) |
| Market | **Persistent spot, interruption = stop** (`var.market = "on-demand"` switches) | ~60 % cheaper. An interruption only stops the box. EBS, checkouts and T3 threads survive, and `cloud-box up` resumes |
| Instance | `r7i.2xlarge` (8 vCPU, 64 GiB), `var.instance_type` | memory-heavy MATSim events/plans analysis (DuckDB/pandas). Go up to `r7i.4xlarge` (128 GiB) for full-population joins |
| Disk | One gp3 root volume, 100 GiB, encrypted, kept when the instance is terminated | Nix store, checkouts, `~/.t3` and `~/.claude` persist across stops |
| Idle | `cloud-idle-stop` timer: power off after **45 min** with no agent working, no agent CPU, no active SSH tty and no open T3 tab. Sends an ntfy note | the box must never stay up idle. `poweroff` + shutdown behaviour `stop` = stopped instance |
| Access | Instance role: S3 read on the data prefixes, write on one scratch prefix, optional ECS RunTask for the d_abm analysis task. IMDSv2 only, hop limit 1. SG with **no inbound** | no long-lived keys on the box. Tailscale is the only way in |
| IaC | **OpenTofu** in `infra/aws/` (identifiers in a gitignored `*.auto.tfvars`). Remote state on S3 with native locking | plain HCL that the AWS docs and provider examples match 1:1. terranix would add a Nix→JSON layer for a ~10-resource stack |
| Agent auth | Claude Code: **subscription OAuth login over SSH** (`claude` → `/login`), stored on the encrypted EBS. GitLab: one **read-only deploy key** for fern, from sops | nothing for Anthropic in git. The deploy key can't push and can be revoked per box |
| Cost | **≈ $20/month** (spot) or **≈ $36/month** (on-demand) for 40 h/month + 100 GiB | see § Cost |

## 1. Host: `modules/nixos/hosts/fern/configuration.nix`

`nixosConfigurations.fern` = `amazon-image.nix` (nixpkgs
`nixos/modules/virtualisation/amazon-image.nix`, still the right module on 26.05)
+ `base` + `general` + `sops` `openssh` `tailscale` `doas` + `agent-common`
`agent-host` `agent-t3code` `agent-opencode` + `cloud-idle-stop`
`workspace-bootstrap`. No desktop, no NetworkManager (EC2 DHCP via the default
`dhcpcd`), so `preferences.desktop.enable` stays false.

Host specifics:
- `ec2.efi = false`: the official x86_64 AMIs boot legacy BIOS (`BootMode:
  legacy-bios`), and the layout must match the AMI the volume came from
  (GRUB on `/dev/xvda`, root labelled `nixos`). If a future AMI is UEFI, set
  `ec2.efi = true` **before** the first deploy (check: `ssh fern test -d
  /sys/firmware/efi && echo efi`).
- `virtualisation.amazon-init.enable = false`. Otherwise every boot would
  re-apply the bootstrap user-data with `nixos-rebuild switch` and overwrite the
  deployed system.
- `services.amazon-ssm-agent.enable = false`: the role has no SSM permissions
  (least privilege). Break-glass is the EC2 serial console (enable it once per
  account; log in with the user password).
- `PermitRootLogin = "no"` (amazon-image wants `prohibit-password` for the EC2
  key pair; there is none).
- sops decrypts with the **SSH host key** only (`sops.age.sshKeyPaths`,
  `keyFile = null`). The master age key never lands on a cloud box
  (secrets-design phase 2b, applied to fern first).
- `nix.gc` weekly, older than 14 days. `nix.optimise`. journald capped.
- `system.stateVersion = "25.11"` (the AMI it was born from).

Registry entry (`modules/hosts-registry.nix`): `sshPort = 7654`, tags
`["tag:cloud" "tag:agent-host"]`, roles `["agent-host" "cloud"]`,
`buildOnTarget = true`, `ts4 = null` with a TODO.

## 2. Image / boot path

| | (a) Flake-built AMI | (b) Official AMI + user-data rebuild from the flake | (c) Official AMI + `deploy` after boot |
|---|---|---|---|
| How | `nix build .#nixosConfigurations.fern.config.system.build.images.amazon` (image.modules, 26.05), upload the VHD to S3, `aws ec2 import-snapshot`, `register-image` | user-data `nixos-rebuild switch --flake github:hzmmohamed/nixconf#fern` | user-data = a minimal NixOS config (user, sshd 7654, Tailscale with a one-time key), then `just deploy fern` |
| Upload from home | **2–5 GB image** per image change, over ADSL | none | only `.drv` files (MBs) when building on the box |
| AWS extras | `vmimport` service role + bucket | none | none |
| Secrets | the host key is baked into the image, or sops can't decrypt on first boot | sops can't decrypt on first boot (no recipient yet). The activation fails half-way | the host key is generated on the box, enrolled with `ssh-to-age`, then deploy |
| Updates | `just deploy fern` after the first boot | re-runs user-data, or `deploy` | **`just deploy fern`** |

**Choice: (c)** with one improvement: `deploy` builds **on the target** for
hosts with `buildOnTarget = true`. It evaluates on butternut/hazel, sends the
derivations (`nix build --eval-store auto --store ssh-ng://…`), and the box
substitutes from cache.nixos.org / cache.numtide.com inside AWS. A café
connection carries megabytes, not the multi-GB closure. (a) stays possible as a
fallback (`system.build.images.amazon` evaluates). It's worth it only if the
NixOS AMIs stop being published.

No GPU: the CUDA cache and `cache.nixos-cuda.org` don't matter here (inherited
from `nix.nix`, unused). A `g6`/`g5` box would only make sense for model
inference, which peacelily covers.

### Bootstrap (first boot only)

`infra/aws/bootstrap.nix.tftpl` is rendered into user-data. It is a NixOS
expression that the AMI's `amazon-init` applies with `nixos-rebuild switch`:
- your user, wheel, `openssh.authorizedKeys` = `var.ssh_public_keys`, passwordless
  doas for wheel (needed by `deploy`), sshd on 7654, `trusted-users = @wheel`
  plus the flake's substituters;
- Tailscale with `--hostname=fern`, logging in with a **one-time, pre-authorized,
  tagged** auth key. The key is a *comment line* in user-data. A oneshot copies
  it to `/run/ts-bootstrap-key` (0600), so it never enters the Nix store. A
  consumed or expired (1 day) key is worthless, so its copy in IMDS / the console
  doesn't matter.

Tofu ignores later changes to `ami` and `user_data`, so a new AMI or template
never replaces the instance.

## 3. Lifecycle and cost

### `cloud-box` (package, installed on hazel and butternut)

```
cloud-box up       start → wait running → wait for fern on the tailnet → wait for T3 → open https://fern.<tailnet>/
cloud-box down     show cloud-idle status (agents working?) → stop-instances (-f skips the check)
cloud-box status   EC2 state, type, market, launch time; tailnet reachability; idle report
cloud-box ssh …    ssh fern …
cloud-box hold N   keep it up N minutes despite idleness (long unattended job)
```
The instance is found by tag `Name=$CLOUD_BOX_NAME` (default `fern`). Region:
`CLOUD_BOX_REGION` (default `eu-central-1`). It uses your own AWS profile
(`AWS_PROFILE`, the human identity on hazel), never fern's role. The human needs
`ec2:DescribeInstances`, `ec2:StartInstances`, `ec2:StopInstances` on that
instance. Admin covers it; a narrow policy is in `infra/aws/outputs.tf`
(`operator_policy_json`) if you want a dedicated profile.

### Idle auto-stop (`features/cloud-idle-stop.nix`)

A root timer every 5 min marks the box **busy** if any of these holds:

| Signal | Source | Why |
|---|---|---|
| an agent is `working` | `/run/user/<uid>/agent-status/*` (agent-common hooks), files younger than 12 h | a Claude turn that waits on the API uses ~0 CPU, so CPU alone would stop the box mid-turn. The 12 h cap ignores sessions that crashed without `SessionEnd`. `input`/`done` count as idle: an agent waiting for you is not work |
| agent CPU > 20 % of one core (avg over the interval) | `cpu.stat` of `user-<uid>.slice` + `nix-daemon.service` | long tool runs (a DuckDB query, a Kedro node, a nix build started by an agent) don't touch the status file |
| an SSH/tty session with input in the last 30 min | `/dev/pts/*` mtime of logged-in sessions (like `w`'s IDLE) | you are working in a shell. A forgotten `ssh` with keepalives doesn't count |
| an open T3 tab | established TCP to `127.0.0.1:<t3 port>` (Tailscale Serve proxies the websocket) | you are watching a thread. A laptop that sleeps drops the socket |
| `cloud-box hold` | `/run/cloud-idle/hold-until` | explicit override |

Busy resets `/run/cloud-idle/last-busy`. After **45 min** without busy (counted from
boot on a fresh start), it sends `agent-notify "fern: stopping (idle 45 min)"`
(ntfy when `preferences.agents.ntfy` is on) and runs `systemctl poweroff`. With
`instance_initiated_shutdown_behavior = "stop"` that leaves a **stopped**
instance (spot: request `disabled`, restartable with `start-instances`).
`cloud-idle status` prints the signals. Tunables: `preferences.cloudIdleStop.*`.

### Spot vs on-demand

Persistent spot with `instance_interruption_behavior = "stop"`: interruptions
stop the box (EBS kept). `start-instances` can fail with
`InsufficientInstanceCapacity` for a while. Then wait, or `tofu apply -var
market=on-demand` (replaces the instance, **keeps the root volume only if you
snapshot it first**; see the risks). r7i spot interruption frequency in
eu-central-1 has been in the lowest band (<5 %). Recommendation: spot. Switch to
on-demand if a stop in the middle of a long analysis bites more than once.

### Cost (eu-central-1, prices read from the AWS Pricing API on 2026-11-17)

| Item | Rate | 40 h/month |
|---|---|---|
| r7i.2xlarge on-demand | $0.6384/h | $25.54 |
| r7i.2xlarge spot (last 24 h: $0.19–0.28 by AZ) | ~$0.25/h | ~$10.00 |
| gp3 root 100 GiB (3000 IOPS / 125 MB/s baseline included) | $0.0952/GB-month | $9.52 (billed while stopped too) |
| public IPv4 (only while running) | $0.005/h | $0.20 |
| S3 ↔ EC2 same region, Tailscale, budget alerts | free | $0 |
| egress to you (UI text, SSH) | $0.09/GB | < $0.10 |
| **Total** | | **≈ $20 spot / ≈ $36 on-demand** |

Bigger boxes: r7i.4xlarge $1.2768/h on-demand (~$0.45 spot) → ≈ $28 spot /
$61 on-demand per 40 h. r7a.2xlarge is $0.734/h, more expensive than r7i
here. A forgotten box costs ~$15/day on-demand. Idle stop and the optional
AWS Budget (`var.budget_email`, filtered on the `agent-box` cost tag) guard
against that.

## 4. AWS access (least privilege)

`infra/aws/iam.tf`, role `<name>-agent-host`, instance profile:
- `s3:ListBucket` on `var.data_bucket_names` (prefix-scoped via `s3:prefix`
  to `var.read_prefixes`), `s3:GetObject` on `bucket/<read prefix>*`.
- `s3:PutObject`, `s3:AbortMultipartUpload`, `s3:DeleteObject` on
  `var.scratch_bucket_name/var.scratch_prefix*` only.
- `kms:Decrypt` / `GenerateDataKey` on `var.kms_key_arns` (only if the buckets
  use SSE-KMS).
- Optional (`var.ecs_run_task`): `ecs:RunTask` on the d_abm analysis task
  definition family (the other agent's `agentic/ecs-analysis` branch defines
  it) with `ecs:cluster` pinned; `ecs:DescribeTasks`/`StopTask` in that
  cluster; `iam:PassRole` on exactly the task and execution roles (only to
  `ecs-tasks.amazonaws.com`); `logs:GetLogEvents`/`FilterLogEvents` on its log
  group. Useful for jobs larger than the box (a full-population rerun), and
  `bin/sim` already speaks ECS. Off by default.
- Nothing else: no EC2, no IAM, no SSM, no Secrets Manager.

IMDSv2 required (`http_tokens = "required"`), hop limit 1 (no containers on
the box). Security group: **no ingress**, egress all. Tailscale gets direct
connections through the stateful SG via NAT traversal (DERP as fallback). Use the
existing VPC/subnet (`var.vpc_id`, `var.subnet_id`). It must be a **public
subnet**: outbound to cache.nixos.org, GitHub and GitLab needs the public IPv4.
A NAT gateway would cost ~$35/month on its own. Add an S3 gateway endpoint to
the VPC if it lacks one (free; S3 in the same region is free either way).

## 5. Agent auth on the box

**Claude Code.** Three options:
1. **Subscription OAuth over SSH (recommended).** `ssh fern`, `claude`, then
   `/login`. It prints a URL; open it on hazel or the phone and paste the code
   back. The token lives in `~/.claude/.credentials.json` on the encrypted EBS
   volume and refreshes itself. You can revoke it from claude.ai (Settings →
   Claude Code sessions) without touching other hosts. T3's `claudeAgent` uses
   the same CLI, so it inherits the login.
2. `claude setup-token` (long-lived OAuth token, 1 year) → sops →
   `CLAUDE_CODE_OAUTH_TOKEN` for the t3code unit. The token would sit in git as
   ciphertext, and rotation means a sops edit + deploy. It only beats (1) for
   fully unattended rebuilds of the box.
3. An Anthropic API key from a dedicated Console workspace with a monthly
   spend limit, via sops. Pay per token. Use it if you want a hard cost cap
   for cloud agents, separate from the subscription.

The risk is the same in every case: anyone with root on fern can use the
credential until you revoke it. With no inbound SG and Tailscale SSH in `check`
mode, root on fern means one of the agents (same Unix user, passwordless doas, as
on butternut) or a supply-chain compromise. Hardening order: doas password on
fern (deploy then needs an interactive doas prompt; backlog), then the separate
`agent` Unix user (secrets-design phase 3).

**OpenCode** uses its own `opencode auth login` (same URL+code flow over SSH)
or the Claude Code bridge already configured in `agent-opencode`. It's cheap to
include, so it is included.

**Git forges.** d_abm is on GitHub and routelab on GitLab; `scripts/fern/deploy-key.sh` detects the forge from the remote URL (GitHub allows a key on one repo only). One SSH key per box (`ssh-keygen -t ed25519 -C fern-deploy`),
added as a **deploy key** (read-only) to each work project (GitLab lets one key
be a deploy key on several projects). The private key and the clone URLs (kept
out of this public repo) live in `secrets/fern/workspace.yaml`:
`git-ssh-key`, `remotes`. `workspace-bootstrap` sets `core.sshCommand` per
checkout, so only those repos use the key. For pushes (agents opening MRs),
tick "Grant write permissions" on the deploy key per project, or add a project
access token for `glab` (`GITLAB_TOKEN`) later. Keep it read-only by default.

**sops for fern.** Recipient = the box's SSH host key, converted with
`ssh-to-age`. `.sops.yaml` gets a `fern` key and two rules: `secrets/fern/.*`
for `[primary, fern]`, and the shared files fern needs (`tailscale.yaml`,
`tailscale-oauth.yaml`, `agents.yaml` if ntfy) re-encrypted for fern with
`sops updatekeys`. The full per-host migration (secrets-design 2b) can follow
later. fern only needs the files above.

## 6. Workspace bootstrap (`features/workspace-bootstrap.nix`)

`preferences.workspace.projects.<name> = { path; remote; referenceDir;
packages; }`. A user oneshot (`workspace-bootstrap.service`, after
network-online, on every boot, idempotent):
1. clones each missing project from its `remote`. The URL comes from the
   option if set, else from the sops `remotes` file (`<name> <url>` lines);
2. sets `core.sshCommand` to the deploy key for that checkout;
3. if the checkout has `.agents/reference-repos.txt` (`name url [ref]`), clones
   each reference repo shallow (`--depth 1 --filter=blob:none`) into
   `referenceDir` (default `~/.local/share/reference-repos`). It makes the
   directory read-only, and if the project has no `.repos` yet, links `.repos →
   referenceDir` (§3.1 of the repo-size doc). An existing `.repos` directory
   (submodules not migrated yet) is left alone;
4. re-runs `t3code-projects` when it cloned something, so the new checkout shows
   up in T3.

Packages per project are added to the user profile. They stay on PATH inside
`direnv`/`nix develop` shells, which only prepend. fern's d_abm entry adds
**s5cmd, duckdb, awscli2**. `AWS_REGION` is set host-wide. The SDKs find the
instance role through IMDS, and there is no `AWS_PROFILE` on fern. routelab
can be added later with its own entry (path, packages); nothing else changes.

## 7. IaC (`infra/aws/`)

OpenTofu ≥ 1.10, AWS provider ~> 6. Files: `versions.tf` (+ empty `backend
"s3" {}`), `variables.tf`, `main.tf` (AMI lookup, SG, instance with spot
options), `iam.tf`, `budget.tf` (optional), `outputs.tf`,
`bootstrap.nix.tftpl`, `fern.auto.tfvars.example`, `backend.hcl.example`,
`.gitignore` (`*.auto.tfvars`, `backend.hcl`, `.terraform/`, state).
`opentofu` is in the dev shell.

Remote state: an S3 bucket you create once (versioning on, public access
blocked, SSE), `backend.hcl` with `bucket`, `key = "nixconf/aws-agent-host.tfstate"`,
`region`, `use_lockfile = true` (S3-native locking, no DynamoDB table). Then
`tofu init -backend-config=backend.hcl`. Optional: OpenTofu state encryption
(`encryption {}` block with a PBKDF2 passphrase from KeePassXC). The state holds
no secrets, because `user_data` is stored as a hash, but it does hold ARNs and IDs.

## Risks / open points

- **Instance replacement loses the box's state unless you snapshot first.** The
  root volume has `delete_on_termination = false`, so a destroy leaves an
  orphaned volume (a cost, but recoverable). A market-type change or AMI
  `taint` replaces the instance. Before that: `aws ec2 create-snapshot`. After
  replacement the host key changes, so fern needs a new sops recipient.
- The first deploy jumps 25.11 → 26.05. That is normal NixOS upgrade territory,
  and the bootstrap system has nothing to migrate.
- MagicDNS name: `fern` must be free in the tailnet (delete stale nodes first),
  or the node becomes `fern-1`.
- `cloud-idle-stop` counts an open T3 tab as activity. If a phone browser keeps
  the websocket alive in the background, the box stays up. `cloud-box down` and
  the budget alert are the backstops.
- Passwordless doas for the user = agents can become root (same as butternut).
  The instance role is reachable by any process anyway (IMDS). Root adds
  "can rewrite the system", which a redeploy fixes.

## User steps

Replaced by the paste-only runbook **`2026-11-17-fern-runbook.md`**: five phases
(state bucket + preflight → Tailscale OAuth client + deploy key → `tofu apply`
→ enrol → deploy/logins/verify), each a command block to paste plus the output to
report back. The scripts live in `scripts/fern/`. The only web step is creating the
Tailscale OAuth client.

Changes from the list that used to be here: the deploy key is forge-aware
(d_abm is on GitHub, routelab on GitLab), and the clone URLs are read from the
local checkouts. The bootstrap auth key is minted through the API (1 day,
one-time) and never shown. The registry and `.sops.yaml` are edited at
`# fern-*` anchors by `scripts/fern/enroll.sh`.
