# fern runbook: paste-only setup (2026-11-17)

How to bring up `fern`, the on-demand EC2 agent host
(design: `2026-11-17-aws-agent-host.md`), in five phases. In each phase you
**paste one command block, then paste the `REPORT BACK` block(s) to the agent**.
The agent does every file edit. The scripts are in `scripts/fern/` (each has
`--dry-run`), with `just fern-*` wrappers in the `justfile`.

Rules the scripts follow:
- Idempotent: re-running a phase is safe. They print each command before running it.
- No secret is printed or passed in argv. Hidden prompts, stdin, or sops only.
- No identifiers in git. Bucket names, VPC/subnet IDs and ARNs stay in the
  gitignored `infra/aws/fern.auto.tfvars` and `infra/aws/backend.hcl`, which
  the agent wrote from read-only discovery. Org/repo names are read from your
  local checkouts at runtime.
- Command blocks are fish-safe. Run them from `~/nixconf` on **butternut**:
  its SSH key is the one fern trusts at bootstrap.

What the agent already did (no action needed): picked the CairoSim VPC public
subnet in eu-central-1b (the cheapest r7i.2xlarge spot price, ~$0.19/h); set
the data buckets (simulation runs and raw data; both SSE-S3, so no KMS) and the
scratch prefix; filled in the ECS analysis values (disabled); checked that a
real `tofu plan` creates 7 resources and that the AMI is legacy-BIOS.

---

## Phase 1: state bucket + preflight

```fish
cd ~/nixconf
bash scripts/fern/state-bucket.sh
bash scripts/fern/preflight.sh
```

**Report back:** both `REPORT BACK` blocks.

**Agent next:** fixes any `FAIL` line. For example, it adds a missing SSH key
to the tfvars, or gives you the login command for a forge. When everything
shows `OK` (the two `TODO`s about phase 2 are expected), it hands you phase 2.

---

## Phase 2: Tailscale OAuth client + deploy key

**The one web step** (Tailscale has no CLI or API for creating OAuth clients):
1. Open <https://login.tailscale.com/admin/settings/oauth> → **Generate OAuth client…**
2. Description: `nixconf hosts`.
3. Scopes: **Keys → Auth Keys → Write**, and nothing else.
4. Tag: **`tag:provisioner`** only (it owns every host tag, so the client can mint keys for any host). maple and
   peacelily use the same client.
5. Click **Generate client** and keep the page open. The secret
   (`tskey-client-…`) is shown only once. Paste it at the hidden prompt below.

> **If `tag:cloud` or `tag:agent-host` is missing from the tag picker**, the
> live tailnet policy doesn't define them yet. Do phase 2b first, then come back
> to step 1.

```fish
cd ~/nixconf
bash scripts/fern/tailscale.sh store
bash scripts/fern/deploy-key.sh
```

`deploy-key.sh` adds fern's key to d_abm (GitHub) as a **read-only** deploy key.
If `gh` is not logged in, it stops and prints the exact login command. Run
that, then re-run the script. To also add routelab (GitLab, needs `glab`), run
`env FERN_PROJECTS="d_abm=$HOME/work/tfc/repos/d_abm routelab=$HOME/work/tfc/repos/routelab-monorepo" bash scripts/fern/deploy-key.sh`.
Then tell the agent so it adds a routelab workspace entry on fern.

**Report back:** both `REPORT BACK` blocks.

**Agent next:** checks that `secrets/shared/tailscale-oauth.yaml` and
`secrets/fern/workspace.yaml` are staged, then evaluates fern, maple and
peacelily (the OAuth path is now active for all three). It updates
`secrets/README.md` and hands you phase 3.

### Phase 2b (only if the tags were missing): apply the tailnet policy

> **Superseded:** the policy is now applied with OpenTofu
> (`2026-11-17-tailnet-as-code.md`): `bash scripts/tailscale/store-admin.sh`
> once, then `bash scripts/tailscale/plan.sh` and `bash scripts/tailscale/apply.sh`.
> The flow below still works as a fallback (it prints a deprecation notice).

The agent's `docs/tailscale-policy.hujson` defines all the tags. To push it,
you need a **second, temporary** OAuth client with **General → Policy File →
Write** (no tags needed). That secret is prompted for and **never stored**: the
stored host client must not be able to rewrite your ACL.

```fish
cd ~/nixconf
bash scripts/fern/tailscale.sh acl
```

It validates the policy (syntax plus its `tests`), backs up the live policy to
`~/.local/state/nixconf/`, and prints the diff. Nothing is applied yet.
**Report back** the block and the diff. Once the agent says the diff is fine:

```fish
bash scripts/fern/tailscale.sh acl --apply-acl
```

(Prompts again, y/N.) Then delete the temporary client in the admin console
and go back to the web step above.

---

## Phase 3: create fern

```fish
cd ~/nixconf
bash scripts/fern/apply.sh
```

It runs `tofu init` against the S3 backend, mints a **one-time,
pre-authorized, tagged** Tailscale key (1 day, not ephemeral) and passes it
only through its own environment. Then it runs `tofu plan`, prints the summary
(expect **7 to add**: role, instance profile, policy, security group, 2 egress
rules, instance) and asks y/N before applying exactly that plan. The plan file
is shredded afterwards.

**Report back:** the plan summary and the `REPORT BACK` block (`ami_boot_mode`
should be `legacy-bios`, market `spot`, az `eu-central-1b`).

**Agent next:** checks that the boot mode matches `ec2.efi = false`. If spot
capacity failed, it switches `market` to `on-demand` in the tfvars and asks you
to re-run this phase. Otherwise it hands you phase 4. First boot takes about
5–10 min while amazon-init builds the bootstrap config.

---

## Phase 4: enrol fern

```fish
cd ~/nixconf
bash scripts/fern/enroll.sh
```

It waits up to 20 min for fern to come online in the tailnet. Then it reads
fern's tailnet IP and SSH host key over the tailnet, checks that your key logs
in, and checks the boot mode. It fills in `ts4` and `hostKey` in
`modules/hosts-registry.nix` and adds `&fern` (ssh-to-age) to `.sops.yaml`.
It runs `sops updatekeys -y` on every sops file fern's config references, then
`git add`, then evaluates fern. Tailscale has no API to pin a node's IP. The IP
stays the same unless the node re-registers. If you want to pin it anyway: admin
console → Machines → fern → Edit machine IPv4.

**Report back:** the `REPORT BACK` block.

**Agent next:** reviews the diff and runs `just check` (format, lint, eval of
every host). It tells you the changes are ready to commit, then hands you
phase 5 with the IP filled in.

---

## Phase 5: deploy, log in, verify

```fish
cd ~/nixconf
env DEPLOY_TARGET=<fern-ip-from-phase-4> just deploy fern
bash scripts/fern/ssh.sh claude
bash scripts/fern/ssh.sh t3-pair hazel
nix run .#cloud-box -- status
nix run .#cloud-box -- down
nix run .#cloud-box -- up
bash scripts/fern/verify.sh
```

- `deploy` builds on fern (only derivations are uploaded) and switches it
  from 25.11 bootstrap to the full 26.05 config. If `just` is missing, use
  `nix develop --impure -c just deploy fern`, with the same `env DEPLOY_TARGET=…` prefix.
- `claude`: type `/login`, open the URL on hazel or the phone, paste the code
  back, then `/exit`. `opencode auth login` works the same way if you want it.
- `t3-pair hazel`: open the link on hazel (T3 desktop → add environment).
  `t3-pair phone` gives the phone's link.
- `cloud-box down` then `up` should come back in ~1–2 min and print the T3 URL.
- `verify.sh` checks the instance role, a read of each data bucket, a write and
  delete in the scratch prefix, a **denied** write outside it, `t3code`,
  `workspace-bootstrap`, the d_abm checkout and the Claude login.

**Report back:** the deploy's last ~15 lines and the `verify.sh` block.

**Agent next:** looks into any `FAIL` (for example `workspace-bootstrap`:
`journalctl --user -u workspace-bootstrap` on fern). After that it's done. Once
butternut/hazel are next switched, `ssh fern` and `cloud-box ssh` work
directly from the registry.

---

## Notes

- `infra/aws/.terraform/` (~770 MB of provider binaries from an earlier init)
  is gitignored and can stay. `tofu init` reuses it.
- The EC2 serial console is off for the account. It's useful as break-glass
  only once fern has a user password (`preferences.user.passwordFromSops`), so
  it is not part of this runbook.
- Re-creating fern (instance replacement) changes its host key. Re-run phase 4,
  which rewrites the same anchors, and phase 5.
- GitHub accepts a given key as a deploy key on **one** repository only. A
  second GitHub project for fern needs its own key (backlog: per-project keys
  in `workspace-bootstrap`).
