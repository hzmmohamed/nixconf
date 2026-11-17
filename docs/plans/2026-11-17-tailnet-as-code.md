# Tailnet as code (2026-11-17)

The tailnet's control-plane settings are declared in `infra/tailscale/` and
applied with **OpenTofu** through the official provider
(`tailscale/tailscale` **0.30.0**, pinned in the committed
`infra/tailscale/.terraform.lock.hcl`). This replaces pasting the policy in
the admin console and `scripts/fern/tailscale.sh acl`, which needed a
temporary OAuth client each time. That command still works, but it now prints
a deprecation notice.

Context: network review §4/§8/§12 (`2026-11-17-network-review.md`), fern runbook phase 2b.

## What is managed

| Resource | File | How it starts | Gate |
|---|---|---|---|
| `tailscale_acl.this` | `acl.tf` | **imported** (`import` block, id `acl`). The first plan shows the live → repo policy diff as an in-place update | always (scope `policy_file`) |
| `tailscale_dns_configuration.this` | `dns.tf` | **imported** (id `dns_configuration`). MagicDNS on, override local DNS on, 1.1.1.1 / 1.0.0.1 / 8.8.8.8 / 8.8.4.4, no split DNS, no search paths. `prevent_destroy` (a destroy empties the tailnet DNS) | always (scope `dns`) |
| `tailscale_tailnet_settings.this[0]` | `settings.tf` | **imported** (id `tailnet_settings`). Pins only `https_enabled = true`. Other attributes are null, so they stay as they are live (the provider sends only changed fields) | scope `feature_settings` |
| `tailscale_oauth_client.hosts[0]` | `oauth.tf` | **imported** by ID. The ID is derived at runtime from `secrets/shared/tailscale-oauth.yaml` (`tskey-client-<id>-…`). Declares `auth_keys` + `tag:provisioner` + "nixconf hosts". `prevent_destroy` | scope `oauth_keys` and the sops file present |
| `tailscale_device_tags.host[<h>]`, `tailscale_device_key.host[<h>]` | `devices.tf` | **created** (the API calls are idempotent "set" calls, so no import is needed). Applies registry tags and turns key expiry off for tagged hosts (maple, peacelily, fern) that exist in the tailnet, looked up by MagicDNS name | opt-in `TAILNET_DEVICE_TAGS=1` and scope `devices:core` |

The scripts set each gate from the admin client's **granted scopes** (and the
opt-in). A missing optional scope leaves that part unmanaged; it does not fail.
Required scopes: `policy_file` and `dns`.

**Not used, on purpose:**
- `tailscale_dns_nameservers`, `_preferences`, `_search_paths`, `_split_nameservers`:
  these are the older per-aspect resources. None of them carries "override local DNS",
  and they must not be mixed with `tailscale_dns_configuration`.
- `tailscale_tailnet_key`: the hosts log in with the OAuth client. fern's one-time
  bootstrap key is minted by `scripts/fern/apply.sh` and never stored. A key
  managed by tofu would sit in the state for no benefit.
- The **admin** OAuth client itself: it is the provider credential (chicken and egg). It is managed by hand.

## Still manual

- Creating and deleting the admin OAuth client (the web console only).
- Pinning node IPv4s (no API; Machines → Edit machine IPv4), approving routes
  outside `autoApprovers`, Taildrop and Funnel toggles in the console, user
  and role management, billing, tailnet lock.
- `acls_externally_managed_on` (which locks the console's policy editor) is
  left off for now. Turn it on in `settings.tf` once tofu is the only writer.

## Credentials

- **Admin client** (`nixconf admin (tofu)`), write scopes: Policy File, DNS,
  Feature Settings (tailnet settings), Networking Settings (only to *change*
  HTTPS), Devices Core, Auth Keys, OAuth Keys. Tailscale requires a tag for
  Devices Core and Auth Keys: pick **`tag:provisioner`**, which owns every host
  tag, so the client may apply them.
- It is stored in `secrets/admin/tailscale-admin.yaml`, key `tailscale_admin_oauth`. The
  `.sops.yaml` rule `secrets/admin/…` sits above the catch-all and lists the
  **primary age key only** (no host can decrypt it, not even fern).
  `store-admin.sh` reports the recipient count (expect 1).
- At run time, `scripts/tailscale/lib.sh` decrypts it into an unexported shell variable.
  It passes it to tofu as a per-command environment prefix only
  (`TAILSCALE_OAUTH_CLIENT_ID` = the third dash field of the secret,
  `TAILSCALE_OAUTH_CLIENT_SECRET`, `TAILSCALE_TAILNET=-` = the credential's own tailnet).
  It never appears in argv, on the terminal, in a file, or in the exported shell environment.
- The **hosts client** (`secrets/shared/tailscale-oauth.yaml`) stays auth-keys-only. When tofu
  creates or replaces it (rotation), `apply.sh` pipes the new secret from
  `tofu output -raw hosts_oauth_client_secret` straight into `sops set` and
  git-adds the file. The secret is never printed. After a replacement it also lives in
  the S3 state (private, SSE, versioned). After a plain import, `key` is null in
  state and the sops file stays the only copy.

## State

Same bucket as `infra/aws`, key **`tailscale/terraform.tfstate`**, S3-native
lock (`use_lockfile`). `infra/tailscale/backend.hcl` (gitignored) is
regenerated on every run from `infra/aws/backend.hcl`. AWS credentials for
the bucket are needed (same as `scripts/fern/apply.sh`).

`infra/tailscale/hosts.auto.tfvars.json` (gitignored, regenerated) is built
from `nix eval --json .#hosts`: the tagged hosts with their MagicDNS label and tags, and
`flake.tailnet.domain`. It holds no node IDs: devices are resolved at plan time
through the `tailscale_devices` data source.

## Bootstrap (once)

1. Create the admin client in the admin console (scopes above, tag `tag:provisioner`).
   Keep the page open: the secret is shown once.
2. Run the command block below, then paste both `REPORT BACK` blocks to the agent.

```fish
cd ~/nixconf
bash scripts/tailscale/store-admin.sh
bash scripts/tailscale/plan.sh
```

The agent then checks the plan:
- `tailscale_dns_configuration.this: import` with **no** update (otherwise
  the live DNS differs from the review: the agent copies the live value into `dns.tf`).
- `tailscale_tailnet_settings.this[0]: import` with no update. The agent pins
  `devices_approval_on`, `devices_key_duration_days` and
  `devices_auto_updates_on` from the `live tailnet_settings:` line.
- `tailscale_oauth_client.hosts[0]: import`, plus at most a description
  update. **Any scope or tag change here must be understood before applying.**
- `tailscale_acl.this: import + update`: the live policy → `docs/tailscale-policy.hujson`
  diff, the same diff `tailscale.sh acl` showed.

3. Once the plan is reviewed, run `bash scripts/tailscale/apply.sh` (re-plans, y/N, applies). The imports
   land in state, then the policy update.
4. Optional: `env TAILNET_DEVICE_TAGS=1 bash scripts/tailscale/plan.sh` shows
   which tagged hosts would get registry tags. A stale, user-owned maple or
   peacelily node would be **re-owned by the tags**. That is intended, but review it first.

## Runbook (day to day)

| Change | Do |
|---|---|
| Policy | edit `docs/tailscale-policy.hujson` → `just tailnet-plan` (the API validates syntax + `tests` at plan time) → `just tailnet-apply` |
| DNS / settings | edit `infra/tailscale/{dns,settings}.tf` → plan → apply |
| Host tags | edit `modules/hosts-registry.nix` `tags` → the OAuth login picks them up at the next login. To force them on a running node: `env TAILNET_DEVICE_TAGS=1 just tailnet-apply` |
| Rotate the hosts client | remove `prevent_destroy` in `oauth.tf` locally → `env TAILNET_REPLACE_HOSTS_CLIENT=1 bash scripts/tailscale/apply.sh` (plans with `-replace`; the apply writes the new secret to sops and git-adds it) → restore `prevent_destroy` → redeploy fern/maple/peacelily so the new secret reaches them. Running nodes stay logged in; only future logins use the new secret |
| Rotate the admin client | create a new one in the console → `store-admin.sh` → delete the old one |
| Console edit happened | `just tailnet-plan` shows it as drift; either copy it into the repo or apply to revert it |

Hazards:
- `tailscale_acl` updates are sent **without** an ETag (provider behaviour), so a console edit made
  between plan and apply is overwritten. The plan → y/N → apply-that-plan flow keeps the window short.
- `overwrite_existing_content` stays **false**. The import block is the adoption path. If the
  ACL is ever dropped from state (`tofu state rm`), the next plan re-imports it.
  Only set the flag true for a deliberate one-off overwrite, after backing up the live policy
  (`tailscale.sh acl` without `--apply-acl` still writes a backup).
- Turning a gate off (for example, removing a scope) makes tofu plan to drop that resource. For
  settings that only touches state. The hosts client and DNS are `prevent_destroy`,
  so the plan fails loudly instead.

## Files

- `infra/tailscale/{versions,variables,acl,dns,settings,oauth,devices,outputs}.tf`,
  `.terraform.lock.hcl`, `.gitignore`, `backend.hcl.example`
- `scripts/tailscale/{lib,store-admin,plan,apply}.sh`; `just tailnet-{store-admin,plan,apply}`
- `.sops.yaml` (rule `secrets/admin/`), `secrets/admin/tailscale-admin.yaml` (created by `store-admin.sh`)
- `docs/tailscale-policy.hujson` (unchanged location, header updated)

Verified locally: `tofu init -backend=false`, `tofu validate`, `tofu fmt -check`,
shellcheck on all scripts. No plan has run yet (it needs the admin credential).
