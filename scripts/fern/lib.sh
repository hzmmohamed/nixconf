# Shared helpers for scripts/fern/*.sh (sourced, not executed).
# Runbook: docs/plans/2026-11-17-fern-runbook.md
#
# Conventions: every script is idempotent, supports --dry-run (print what
# would change, touch nothing that creates resources or edits files), never
# prints secrets, and ends with a "REPORT BACK" block for the agent.
# shellcheck shell=bash
# Globals here are used by the scripts that source this file.
# shellcheck disable=SC2034

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
INFRA="$REPO/infra/aws"
TFVARS="$INFRA/fern.auto.tfvars"
BACKEND="$INFRA/backend.hcl"
NAME=fern
REGION=eu-central-1
SSH_PORT=7654
DRY_RUN=${DRY_RUN:-0}

log() { printf '>> %s\n' "$*" >&2; }
warn() { printf '!! %s\n' "$*" >&2; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# `run cmd args…`: print the command, execute it unless --dry-run.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '   [dry-run] %s\n' "$*" >&2
  else
    printf '   $ %s\n' "$*" >&2
    "$@"
  fi
}

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer </dev/tty || answer=
  case "$answer" in y | Y | yes) return 0 ;; *) return 1 ;; esac
}

# `need attr:binary …`: re-exec this script inside `nix shell` when a tool is
# missing (pinned to this flake's nixpkgs). Call as: need … -- "$@"
need() {
  local missing=() spec
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    spec=$1
    shift
    command -v "${spec#*:}" >/dev/null 2>&1 || missing+=("nixpkgs#${spec%%:*}")
  done
  [ "${1:-}" = -- ] && shift
  [ ${#missing[@]} -eq 0 ] && return 0
  [ -n "${FERN_REEXEC:-}" ] && die "still missing after nix shell: ${missing[*]}"
  log "fetching ${missing[*]} (nix shell --inputs-from $REPO)"
  FERN_REEXEC=1 exec nix shell --inputs-from "$REPO" "${missing[@]}" -c bash "$0" "$@"
}

# `tfvar name`: a scalar string from the local tfvars (gitignored).
tfvar() {
  [ -r "$TFVARS" ] || die "$TFVARS is missing (the agent writes it; see the runbook)"
  sed -n "s/^$1 *= *\"\(.*\)\".*/\1/p" "$TFVARS" | head -n1
}

# `tfvar_list name`: a one-line list of strings, one per line.
tfvar_list() {
  [ -r "$TFVARS" ] || die "$TFVARS is missing"
  sed -n "s/^$1 *= *\[\(.*\)\].*/\1/p" "$TFVARS" | head -n1 | tr ',' '\n' | tr -d ' "' | sed '/^$/d'
}

backend_var() {
  [ -r "$BACKEND" ] || die "$BACKEND is missing (the agent writes it; see the runbook)"
  sed -n "s/^$1 *= *\"\(.*\)\".*/\1/p" "$BACKEND" | head -n1
}

aws_() { aws --region "$REGION" "$@"; }

# Private temp dir for key material: tmpfs when possible, removed on exit.
secure_tmpdir() {
  local base=${XDG_RUNTIME_DIR:-/tmp}
  SECURE_TMP=$(umask 077 && mktemp -d "$base/fern.XXXXXX")
  trap 'shred_tmp' EXIT
}
shred_tmp() {
  [ -n "${SECURE_TMP:-}" ] && [ -d "$SECURE_TMP" ] || return 0
  find "$SECURE_TMP" -type f -exec shred -u {} + 2>/dev/null || true
  rmdir "$SECURE_TMP" 2>/dev/null || true
}

# Tailscale peer named fern from the local tailscaled: "<ipv4> <online> <dnsname>".
ts_peer() {
  tailscale status --json 2>/dev/null | jq -r --arg n "$NAME" '
    [.Peer // {} | .[] | select(.HostName == $n or ((.DNSName // "") | startswith($n + ".")) or ((.DNSName // "") | test("^" + $n + "-[0-9]+\\.")))]
    | .[] | "\((.TailscaleIPs // [])[] | select(test("^[0-9.]+$"))) \(.Online) \(.DNSName)"'
}

# Work projects fern clones, as `name=local-checkout` words. The clone URL is
# read from the local checkout at runtime, so no org/repo names live in git.
# The name must match preferences.workspace.projects.<name> on fern.
# Override: FERN_PROJECTS="d_abm=$HOME/… routelab=$HOME/…"
fern_projects() {
  local p
  for p in ${FERN_PROJECTS:-d_abm=$HOME/work/tfc/repos/d_abm}; do printf '%s\n' "$p"; done
}

# `parse_remote url` → "host path" (path without .git), for scp-style,
# ssh:// and https:// URLs.
parse_remote() {
  local url=$1 host path
  case "$url" in
    *://*)
      url=${url#*://}
      url=${url#*@}
      host=${url%%/*}
      host=${host%%:*}
      path=${url#*/}
      ;;
    *@*:*)
      url=${url#*@}
      host=${url%%:*}
      path=${url#*:}
      ;;
    *) return 1 ;;
  esac
  printf '%s %s\n' "$host" "${path%.git}"
}

forge_of() {
  case "$1" in
    github.com) echo github ;;
    gitlab.com | gitlab.*) echo gitlab ;;
    *) echo unknown ;;
  esac
}

# --- Tailscale API (OAuth client credentials) -------------------------------
# Secrets travel through printf (a builtin) into curl's stdin or a process
# substitution, never through argv (visible in ps) or the terminal.
TS_API=https://api.tailscale.com/api/v2
OAUTH_FILE="$REPO/secrets/shared/tailscale-oauth.yaml"

# `ts_token <client-secret>`: sets TS_TOKEN (access token) and TS_SCOPES.
# The client ID is the third dash-field of tskey-client-<id>-<secret>.
ts_token() {
  local secret=$1 id resp
  id=$(printf '%s' "$secret" | cut -d- -f3)
  if ! resp=$(printf 'grant_type=client_credentials&client_id=%s&client_secret=%s' "$id" "$secret" |
    curl -sS --fail-with-body -d @- "$TS_API/oauth/token"); then
    echo "token request failed: $(printf '%s' "$resp" | jq -r '.message? // .error? // "?"' 2>/dev/null)" >&2
    return 1
  fi
  TS_SCOPES=$(printf '%s' "$resp" | jq -r '.scope // ""')
  TS_TOKEN=$(printf '%s' "$resp" | jq -er '.access_token')
}

# `ts_api <token> curl-args…`: authenticated curl.
ts_api() {
  local token=$1
  shift
  curl -sS --fail-with-body -H @<(printf 'Authorization: Bearer %s\n' "$token") "$@"
}

# The stored OAuth client secret (sops), into $1 by name. Never echoed.
ts_stored_secret() {
  [ -e "$OAUTH_FILE" ] || die "$OAUTH_FILE is missing: run 'bash scripts/fern/tailscale.sh store' (phase 2)"
  printf -v "$1" '%s' "$(sops decrypt --extract '["tailscale_oauth"]' "$OAUTH_FILE")"
}

# fern's ACL tags from the hosts registry (modules/hosts-registry.nix).
fern_tags_json() {
  nix eval --json "$REPO#hosts.$NAME.tags" 2>/dev/null || echo '["tag:cloud","tag:agent-host"]'
}

# `ts_mint_key <token> <varname>`: a one-time, pre-authorized, tagged,
# non-ephemeral auth key (1 day), stored into <varname>. Never printed.
ts_mint_key() {
  local token=$1 body resp
  body=$(jq -cn --argjson tags "$(fern_tags_json)" --arg d "$NAME bootstrap scripts-fern" '{
    capabilities: {devices: {create: {reusable: false, ephemeral: false, preauthorized: true, tags: $tags}}},
    expirySeconds: 86400, description: $d}')
  if ! resp=$(ts_api "$token" -H 'Content-Type: application/json' -d "$body" "$TS_API/tailnet/-/keys"); then
    echo "minting the auth key failed: $(printf '%s' "$resp" | jq -r '.message? // "?"' 2>/dev/null)" >&2
    return 1
  fi
  printf -v "$2" '%s' "$(printf '%s' "$resp" | jq -er '.key')"
}

report_header() {
  printf '\n==================== REPORT BACK (paste this) ====================\n'
}
report_footer() {
  printf '==================================================================\n'
}
