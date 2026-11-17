#!/usr/bin/env bash
# fern's read-only git deploy key (runbook phase 2).
#   bash scripts/fern/deploy-key.sh [--dry-run]
#   FERN_PROJECTS="d_abm=$HOME/work/tfc/repos/d_abm routelab=$HOME/work/tfc/repos/routelab-monorepo" bash scripts/fern/deploy-key.sh
#
# For each work project (default: d_abm), reads the clone URL from your local
# checkout (no org/repo names in this public repo), detects the forge and adds
# the key as a READ-ONLY deploy key:
#   GitHub: gh repo deploy-key add (read-only unless --allow-write, never passed)
#   GitLab: glab api POST projects/:id/deploy_keys can_push=false
# Then writes secrets/fern/workspace.yaml with sops (keys `git-ssh-key` and
# `remotes`, exactly what features/workspace-bootstrap.nix reads) and git-adds it.
# Idempotent: an existing workspace.yaml's key is reused (decrypted into a
# private tmpfs dir, shredded on exit); keys already on a forge are skipped.
# GitHub allows a given key as deploy key on ONE repository only; a second
# GitHub project would need its own key (workspace-bootstrap has one).
# --dry-run: no forge or sops writes (a throwaway key is generated if needed).
set -euo pipefail
# shellcheck source=scripts/fern/lib.sh
. "$(dirname "$0")/lib.sh"
[ "${1:-}" = --dry-run ] && DRY_RUN=1
need jq:jq python3:python3 sops:sops gh:gh glab:glab -- "$@"

rel=secrets/fern/workspace.yaml
file="$REPO/$rel"
title="$NAME-deploy"
secure_tmpdir
key="$SECURE_TMP/key"

if [ -e "$file" ]; then
  log "reusing the key in $rel"
  (umask 077 && sops decrypt --extract '["git-ssh-key"]' "$file" >"$key")
  key_state=reused
else
  log "generating a new ed25519 key ($title) in a private temp dir"
  ssh-keygen -q -t ed25519 -C "$title" -N '' -f "$key"
  key_state=new
fi
pub=$(ssh-keygen -y -f "$key" | awk '{print $1 " " $2}')
fpr=$(printf '%s\n' "$pub" | ssh-keygen -lf - | awk '{print $2}')
printf '%s %s\n' "$pub" "$title" >"$key.pub"

# Pass 1: clone URLs from the local checkouts.
remotes=
projects=()
while IFS= read -r p; do
  name=${p%%=*}
  dir=${p#*=}
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || die "project $name: no git checkout at $dir"
  read -r host path < <(parse_remote "$url") || die "project $name: cannot parse remote $url"
  remotes+="$name git@$host:$path.git"$'\n' # SSH form: the deploy key is an SSH key
  projects+=("$name $host $path")
  case "$host" in
    github.com | gitlab.com) ;;
    *) warn "$host is not in fern's programs.ssh.knownHosts (workspace-bootstrap.nix): tell the agent" ;;
  esac
done < <(fern_projects)

# Pass 2: save the key in sops BEFORE registering it anywhere (a failure
# later never leaves a forge key whose private half is lost).
if [ -e "$file" ]; then
  current=$(sops decrypt --extract '["remotes"]' "$file" 2>/dev/null || true)
  if [ "$current" = "${remotes%$'\n'}" ] || [ "$current" = "$remotes" ]; then
    file_state=unchanged
  elif [ "$DRY_RUN" = 1 ]; then
    echo "   [dry-run] sops set --value-stdin $rel '[\"remotes\"]'" >&2
    file_state=would-update
  else
    printf '%s' "$remotes" | jq -Rs . | sops set --value-stdin "$file" '["remotes"]'
    file_state=updated-remotes
  fi
elif [ "$DRY_RUN" = 1 ]; then
  echo "   [dry-run] sops encrypt --filename-override $rel > $rel   (git-ssh-key, remotes)" >&2
  file_state=would-create
else
  mkdir -p "$(dirname "$file")"
  tmp=$(mktemp "$file.XXXXXX")
  if ! REMOTES=$remotes python3 -c '
import os, sys
key = open(sys.argv[1]).read().rstrip("\n")
remotes = os.environ["REMOTES"].rstrip("\n")
ind = lambda s: "\n".join("  " + l for l in s.split("\n"))
sys.stdout.write("git-ssh-key: |\n" + ind(key) + "\nremotes: |\n" + ind(remotes) + "\n")
' "$key" | sops encrypt --filename-override "$rel" --input-type yaml --output-type yaml >"$tmp"; then
    rm -f "$tmp"
    die "sops encrypt failed"
  fi
  mv "$tmp" "$file"
  file_state=created
fi
[ "$DRY_RUN" = 1 ] || git -C "$REPO" add "$rel"

# Pass 3: register the public key on each forge (read-only).
status=()
for entry in "${projects[@]}"; do
  read -r name host path <<<"$entry"
  forge=$(forge_of "$host")

  case "$forge" in
    github)
      gh auth status -h github.com >/dev/null 2>&1 ||
        die "gh auth status failed (not logged in, or offline). Log in with: nix shell --inputs-from . nixpkgs#gh -c gh auth login -h github.com"
      if gh repo deploy-key list --repo "$path" --json key -q '.[].key' | awk '{print $1 " " $2}' | grep -qxF "$pub"; then
        state=present
      elif [ "$DRY_RUN" = 1 ]; then
        echo "   [dry-run] gh repo deploy-key add <pub> --repo <owner/repo> --title $title" >&2
        state=would-add
      else
        gh repo deploy-key add "$key.pub" --repo "$path" --title "$title" >/dev/null ||
          die "gh deploy-key add failed for $name (admin rights on the repo? org policy allows deploy keys?)"
        state=added
      fi
      ;;
    gitlab)
      glab auth status --hostname "$host" >/dev/null 2>&1 ||
        die "glab auth status failed (not logged in, or offline). Log in with: nix shell --inputs-from . nixpkgs#glab -c glab auth login --hostname $host"
      enc=$(jq -rn --arg p "$path" '$p|@uri')
      if glab api --hostname "$host" "projects/$enc/deploy_keys" | jq -r '.[].key' | awk '{print $1 " " $2}' | grep -qxF "$pub"; then
        state=present
      elif [ "$DRY_RUN" = 1 ]; then
        echo "   [dry-run] glab api -X POST projects/<id>/deploy_keys title=$title can_push=false" >&2
        state=would-add
      else
        glab api --hostname "$host" -X POST "projects/$enc/deploy_keys" \
          -f "title=$title" -f "key=$pub $title" -F can_push=false >/dev/null ||
          die "glab deploy key add failed for $name (Maintainer rights on the project?)"
        state=added
      fi
      ;;
    *) die "project $name: unsupported forge $host" ;;
  esac
  status+=("$name: $forge read-only deploy key $state")
done

report_header
echo "deploy-key: $title $fpr ($key_state); $rel $file_state; dry-run=$DRY_RUN"
printf '%s\n' "${status[@]}"
report_footer
