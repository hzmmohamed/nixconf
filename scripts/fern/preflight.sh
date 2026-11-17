#!/usr/bin/env bash
# Read-only checks before creating fern. Changes nothing except the local
# OpenTofu working directory (`tofu init`, provider download).
#   bash scripts/fern/preflight.sh
set -euo pipefail
# shellcheck source=scripts/fern/lib.sh
. "$(dirname "$0")/lib.sh"
need awscli2:aws opentofu:tofu jq:jq gh:gh glab:glab -- "$@"

results=()
ok() { results+=("OK    $*"); }
todo() { results+=("TODO  $*"); }
bad() { results+=("FAIL  $*"); }

# AWS identity (no account ID in the output).
if arn=$(aws_ sts get-caller-identity --query Arn --output text 2>/dev/null); then
  ok "aws identity: ${arn##*/}"
else
  bad "aws identity: no credentials (AWS_PROFILE? aws sso login?)"
fi

# Local, gitignored config written by the agent.
for f in "$TFVARS" "$BACKEND"; do
  if [ -r "$f" ] && git -C "$REPO" check-ignore -q "$f"; then
    ok "$(basename "$f") present and gitignored"
  else
    bad "$(basename "$f") missing or NOT gitignored"
  fi
done

# State bucket + tofu init/validate.
bucket=$(backend_var bucket)
cd "$INFRA"
if aws_ s3api head-bucket --bucket "$bucket" 2>/dev/null; then
  ok "state bucket exists"
  if tofu init -input=false -reconfigure -backend-config=backend.hcl >/dev/null 2>"$INFRA/.init.log"; then
    ok "tofu init (S3 backend)"
  else
    bad "tofu init: $(tail -n 3 "$INFRA/.init.log" | tr '\n' ' ')"
  fi
else
  todo "state bucket not created yet (bash scripts/fern/state-bucket.sh)"
  tofu init -input=false -backend=false >/dev/null 2>"$INFRA/.init.log" || bad "tofu init -backend=false: $(tail -n 3 "$INFRA/.init.log" | tr '\n' ' ')"
fi
rm -f "$INFRA/.init.log"
if out=$(tofu validate -no-color 2>&1); then ok "tofu validate"; else bad "tofu validate: $out"; fi
cd "$REPO"

# Does the instance already exist (re-run after phase 3)?
existing=$(aws_ ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].State.Name' --output text 2>/dev/null || true)
if [ -n "$existing" ]; then ok "EC2 instance $NAME exists ($existing)"; else ok "no EC2 instance named $NAME yet"; fi

# Tailscale: logged in, and no stale node squatting the name.
if tailscale status >/dev/null 2>&1; then
  ok "tailscale: this machine is logged in"
  peers=$(ts_peer || true)
  if [ -z "$peers" ]; then
    ok "tailscale: no node named $NAME (the name is free)"
  elif [ -n "$existing" ]; then
    ok "tailscale: $NAME present ($(echo "$peers" | awk '{print "online=" $2}' | head -n1))"
  else
    bad "tailscale: a stale '$NAME' node exists but no instance. Delete it: https://login.tailscale.com/admin/machines (search $NAME → … → Remove)"
  fi
else
  bad "tailscale: not logged in on this machine"
fi

# sops master key (for sops --set / updatekeys later). Content never read.
if [ -r "${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}" ]; then
  ok "sops age key present"
else
  bad "sops age key missing (~/.config/sops/age/keys.txt)"
fi
if [ -e "$REPO/secrets/shared/tailscale-oauth.yaml" ]; then
  ok "secrets/shared/tailscale-oauth.yaml exists"
else
  todo "secrets/shared/tailscale-oauth.yaml not created yet (phase 2)"
fi

# This machine's SSH key must be one of the bootstrap keys (enroll + deploy log in with it).
mine=$(awk '{print $2}' "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true)
if [ -n "$mine" ] && grep -q -- "$mine" "$TFVARS"; then
  ok "this machine's ~/.ssh/id_ed25519.pub is in ssh_public_keys"
else
  bad "this machine's SSH key is not in ssh_public_keys (run the phases from butternut, or tell the agent to add this key)"
fi

# Forges for the work projects (deploy keys, phase 2).
while IFS= read -r p; do
  name=${p%%=*}
  dir=${p#*=}
  if ! url=$(git -C "$dir" remote get-url origin 2>/dev/null); then
    bad "project $name: no checkout at $dir"
    continue
  fi
  read -r host _ < <(parse_remote "$url") || {
    bad "project $name: cannot parse its remote"
    continue
  }
  case $(forge_of "$host") in
    github)
      if gh auth status -h github.com >/dev/null 2>&1; then
        ok "project $name: GitHub, gh logged in"
      else
        todo "project $name: GitHub, gh NOT logged in → nix shell --inputs-from . nixpkgs#gh -c gh auth login -h github.com"
      fi
      ;;
    gitlab)
      if glab auth status -h "$host" >/dev/null 2>&1; then
        ok "project $name: GitLab, glab logged in"
      else
        todo "project $name: GitLab, glab NOT logged in → nix shell --inputs-from . nixpkgs#glab -c glab auth login -h $host"
      fi
      ;;
    *) bad "project $name: unsupported forge $host" ;;
  esac
done < <(fern_projects)

serial=$(aws_ ec2 get-serial-console-access-status --query SerialConsoleAccessEnabled --output text 2>/dev/null || echo unknown)
ok "EC2 serial console (break-glass, optional): enabled=$serial"

report_header
printf '%s\n' "${results[@]}"
report_footer
