# AWS SSO + secretspec runbook: paste-only (2026-11-17)

Goal: work on d_abm from **hazel** and drive **fern** (`cloud-box`) with short-lived
Identity Center credentials, with no long-lived AWS keys on hazel. Design:
`2026-11-17-secrets-design.md` ("AWS plan", "secretspec"). In each phase, **paste
the command block, then paste the `REPORT BACK` block to the agent**. Scripts:
`scripts/aws-sso/` (bash, idempotent, `--dry-run`), with `just aws-sso-*` wrappers.
They print no identifiers in the REPORT BACK block, and nothing identifying is
committed: account ID, start URL and region live only in sops
(`secrets/shared/aws-sso.yaml`).

## What exists already (read-only check, 2026-11-17)

- **IAM Identity Center is already enabled**: an **organization instance** in
  eu-central-1 (created 2023), owned by this account, which is the
  Organizations **management account** (feature set ALL, one member account:
  itself). Nothing to click to enable it. (An *account instance* would not do:
  it cannot assign permission sets for AWS accounts, so `aws sso login` would
  give no account role. The org instance can.)
- Identity store users: `h.fahmi` (work email, **no assignments yet**) and
  `admin`. Group `Admin`. One permission set, `AdministratorAccess` (1 h),
  assigned to `admin` and the `Admin` group. **These are left as they are.**
- `cairo-sim-dev-operator` (customer-managed, from d_abm Alchemy
  `infra/aws/src/Operator.ts`) exists and is attached to nothing.
- fern's instance role `fern-agent-host` has the inline policy `data-access`
  (`infra/aws/iam.tf`); the ECS RunTask part is disabled.
- Your shell today: IAM user `h.fahmi` with static admin keys in
  `~/.aws/credentials` `[default]` (butternut). Those keep working throughout.

## Design decisions

| Decision | Choice |
|---|---|
| Identity Center instance | Reuse the existing **organization instance** (eu-central-1) |
| Human identity | Reuse Identity Center user `h.fahmi` (created only if missing, from `git config user.email`) |
| `Admin` | AWS managed `AdministratorAccess`, **8 h** (`ADMIN_SESSION`). Deploys (Alchemy), console |
| `Operator` | `cairo-sim-dev-operator` (run/stop tasks of the runner, bundler, analysis families; run bucket read/write; logs; ECR push; run-config parameter) **+ inline** copied at setup time from `fern-agent-host` (data buckets read, `scratch/fern/` write; analysis RunTask once enabled in tofu) **+** CloudWatch Logs read on `/cairo-sim/*`. **12 h**. No IAM/EC2/deploy rights |
| `CloudBox` | `ec2:DescribeInstances/DescribeInstanceStatus` (no resource-level support) + `ec2:StartInstances/StopInstances/GetConsoleOutput` only where `aws:ResourceTag/Name = fern`. **12 h**. No SSM (cloud-box doesn't use it), no KMS (fern's root volume uses the AWS-managed `aws/ebs` key) |
| Client profiles | One `[sso-session tfc]`; `tfc-admin`, `tfc-operator`, `tfc-cloudbox` (`preferences.aws.sso`, `features/aws.nix`) on hazel + butternut. fern: instance role only |
| `~/.aws/config` | sops template → `/run/secrets/rendered/aws-sso-config` (user, 0400) → copied by `aws-sso-config-sync` (home-manager activation and every `aws-login`) between `# BEGIN/END nixconf aws-sso` markers. `[default]` and `~/.aws/credentials` untouched; the file stays writable |
| Default profile | None set globally. `cloud-box` uses `tfc-cloudbox` when it exists (else the old default chain); projects set `AWS_PROFILE` in their git-ignored `.envrc.local` |
| secretspec | 0.21.1 from llm-agents' nixpkgs. `team` alias = `keyring://` on hazel/butternut (gnome-keyring now, KeePassXC later; `preferences.secretspec.devVault.enable` switches to `kdbx://` once `dev.kdbx` exists), `file:///run/secrets/secretspec` on fern. `human` = `keyring://` on desktops. AWS credentials are never secretspec values |

**Caveat (butternut is an agent host):** one SSO login caches a token in
`~/.aws/sso/cache` that can be exchanged for **every** permission set assigned
to `h.fahmi`, Admin included, for as long as the portal session lasts. Agents
running as your user can use it. On butternut, run `aws sso logout` after admin
work. The clean fix (design doc) is a second Identity Center user that only has
Operator/CloudBox, with its own `sso-session` on agent hosts. That is a later step.

## Phase 0: check that you can sign in (console, 2 min)

1. Open the access portal URL that phase 1 prints (`https://d-….awsapps.com/start`)
   and sign in as **`h.fahmi`**. If you never set a password: console → IAM Identity
   Center → Users → `h.fahmi` → *Reset password* → *Send an email*.
2. IAM Identity Center → Settings → Authentication: MFA **"Every time they sign in"**
   (or context-aware) and register an authenticator for `h.fahmi`. Optionally set the
   *session duration* (portal session, how often `aws-login` is needed) to 12 h.

## Phase 1: permission sets + assignments (butternut, current admin keys)

```fish
cd ~/nixconf
bash scripts/aws-sso/setup.sh --dry-run
bash scripts/aws-sso/setup.sh
```

**Report back:** the second `REPORT BACK` block (the dry-run's too if anything
looks off). Expect `Admin/Operator/CloudBox: created … assignment=assigned-now`.
Re-running prints `unchanged … assigned`. Re-run it after `tofu apply` changes
fern's role (for example, enabling `ecs_run_task`): Operator picks up the new statements.

## Phase 2: client settings into sops, then deploy

```fish
cd ~/nixconf
bash scripts/aws-sso/store-config.sh --dry-run
bash scripts/aws-sso/store-config.sh       # git-adds the file (commit it with the rest)
doas nixos-rebuild switch --flake .#butternut
just deploy hazel
```

(If the portal has a custom subdomain, prefix the store command with
`env AWS_SSO_START_URL=https://<alias>.awsapps.com/start`.)

**Report back:** the `REPORT BACK` block (`recipients=1`, `portal-http=302` or `200`).

## Phase 3: log in and verify (on hazel)

```fish
cd ~/nixconf
aws-login                 # browser; over ssh: aws-login --use-device-code
bash scripts/aws-sso/verify.sh
cloud-box status
```

**Report back:** the verify block plus the `cloud-box status` first line. Expected:
`tfc-cloudbox describe fern=ok s3 ls=denied`, `tfc-operator run-config=ok iam=denied`
(`ls scratch` only where `infra/aws/fern.auto.tfvars` exists, i.e. butternut).
cloud-box prints `(AWS_PROFILE=tfc-cloudbox)`. When the session expires, it says
`run aws-login`.

## Phase 4: d_abm on hazel

```fish
cd ~/work/tfc/repos/d_abm
echo 'export AWS_PROFILE=tfc-operator' >> .envrc.local   # git-ignored; tfc-admin for deploys
direnv allow
secretspec check          # d_abm: nothing required
```

`infra/aws/.env` (git-ignored, butternut only) wins for `bin/sim` if it sets
`AWS_PROFILE` or static keys: point it at `tfc-operator` too. Deploys (Alchemy) need admin: `env AWS_PROFILE=tfc-admin <deploy command>`. For
Alchemy's own profile, switch `~/.alchemy/profiles/default/aws.json` from `method:
"stored"` to SSO with profile `tfc-admin` (`alchemy configure`/`alchemy login`;
check the CLI's prompts), then delete the stored keys there.

## Phase 5 (after a week of SSO working): retire the static keys

```fish
aws iam list-access-keys --user-name h.fahmi --profile tfc-admin
aws iam get-access-key-last-used --access-key-id <id> --profile tfc-admin
aws iam update-access-key --user-name h.fahmi --access-key-id <id> --status Inactive --profile tfc-admin
# a week later, if nothing broke:
aws iam delete-access-key --user-name h.fahmi --access-key-id <id> --profile tfc-admin
```

Then remove `[default]` from `~/.aws/credentials` on butternut, the keys in
d_abm's `infra/aws/.env`, and `~/.alchemy/profiles/default/aws.json` stored keys.

## secretspec

Machine config (generated, read-only): `~/.config/secretspec/config.toml` with
`[defaults] provider = "team"`, profile `default`. Per project, in the checkout:

| Command | What |
|---|---|
| `secretspec check` | lists every declared secret, prompts for missing **required** ones |
| `secretspec set NAME` (`-P <profile>`) | stores a value (prompt, or `--from-file -`) in the `team` provider |
| `secretspec run -- <cmd>` (`-P <profile>`) | runs `<cmd>` with the secrets in its environment only |

Agents must pass `--reason "…"` (or `SECRETSPEC_REASON`); it is logged in `secretspec audit`.

Values to `secretspec set` on hazel (all optional unless marked):

- **d_abm** (`profiles.default`): `CAIRO_SIM_ALERT_EMAIL` (budget alert address, only for
  the infra stack). Nothing else. AWS comes from `AWS_PROFILE`.
- **routelab** `profiles.default` (all optional; set what the dev task needs):
  `BETTER_AUTH_SECRET`, `DATABASE_URL`, `VITE_MAPBOX_ACCESS_TOKEN`, `MAPBOX_ACCESS_TOKEN`,
  `PLUNK_TOKEN`, `TILES_SIGNING_KEY`, `VITE_TILE_SERVER_CREDENTIALS`, `ORIGIN_SECRET_HEADER`,
  `OTEL_EXPORTER_OTLP_HEADERS`, `LEGACY_DB_URL`, `FLEXPRICE_API_KEY`, `SDI_DB_PASSWORD`.
- routelab `-P ops` (required there): `GRAFANA_TOKEN`, `TEAMS_WEBHOOK_URL`.
- routelab `-P lago` (all required, human-only): `LAGO_RSA_PRIVATE_KEY`,
  `LAGO_ENCRYPTION_PRIMARY_KEY`, `LAGO_ENCRYPTION_DETERMINISTIC_KEY`,
  `LAGO_ENCRYPTION_KEY_DERIVATION_SALT`, `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`,
  `REDIS_PASSWORD`, `LAGO_REDIS_CACHE_PASSWORD`, `LAGO_SMTP_PASSWORD`, `LAGO_ORG_USER_PASSWORD`,
  `LAGO_ORG_API_KEY`, `LAGO_AWS_S3_ACCESS_KEY_ID`, `LAGO_AWS_S3_SECRET_ACCESS_KEY`,
  `GOOGLE_AUTH_CLIENT_ID`, `GOOGLE_AUTH_CLIENT_SECRET`, `PORTAINER_PASSWORD`.
- routelab `-P android-release` (human-only): `OBSERVER_UPLOAD_STORE_PASSWORD`,
  `OBSERVER_UPLOAD_KEY_PASSWORD`, `OBSERVER_UPLOAD_KEY_ALIAS` (optional),
  `OBSERVER_UPLOAD_STORE_FILE` (binary: `secretspec set -P android-release OBSERVER_UPLOAD_STORE_FILE --from-file <keystore>`).

AWS-related: neither repo declares the operator's AWS credentials (correct: they come
from `AWS_PROFILE`). The one AWS-looking pair, `LAGO_AWS_S3_ACCESS_KEY_ID`/`_SECRET_ACCESS_KEY`,
is Lago's **service** credential for its S3 bucket, not your identity. It stays a secretspec
value (lago profile) until Lago can use a role.

fern: `team = file:///run/secrets/secretspec`. Nothing is placed there today (d_abm
needs nothing). To add a value: a sops file encrypted for fern, then
`preferences.secretspec.fileSecrets."<project>/<profile>/<KEY>" = { sopsFile = …; key = …; };`.

## Files

- `scripts/aws-sso/{lib,setup,store-config,verify}.sh`, `just aws-sso-{setup,store,verify}`
- `modules/nixos/features/aws.nix`: `preferences.aws.sso`, `aws-login`, `aws-sso-config-sync`
- `modules/nixos/features/secretspec.nix`: `preferences.secretspec`
- `modules/packages/cloud-box.nix`: `tfc-cloudbox` default + login hint
- hosts: `hazel/agents.nix`, `butternut/agents.nix` (secretspec + `aws.sso.enable`), `fern/configuration.nix` (secretspec)
- `.sops.yaml`: rule `secrets/shared/aws-sso.yaml` (primary only; never fern)
