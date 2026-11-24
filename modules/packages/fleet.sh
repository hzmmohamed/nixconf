# fleet — body of the `fleet` package (modules/packages/deploy.nix, which
# prepends the registry data: registry_hosts, uncreated_hosts, default_user,
# default_port; then fleet-lib.sh). Not a standalone script. Read-only: it
# evaluates and asks hosts what they run, it never builds or deploys.
#
# Every system records the commit it was built from (base/revision.nix), so
# two commits never yield the same toplevel. Both commands therefore compare
# toplevels with system.configurationRevision pinned: to null for `affects`,
# to the revision the host runs for `status` (main with that pin is exactly
# what the host would run if nothing else changed).

usage() {
  cat >&2 <<EOF
usage: fleet affects [<base>]   hosts whose system changes between <base>
                                (default: merge-base with $main_ref) and the
                                working tree; eval only
       fleet status             per registry host: deployed commit vs
                                $main_ref, and whether its running system
                                differs from $main_ref's

env:   FLEET_REPO (default: the git checkout around \$PWD, else ~/nixconf)
       FLEET_MAIN (default: main)  FLEET_JOBS (parallel evals, default 6)
       FLEET_SKIP (hosts not to evaluate; default: \`skip\` in the justfile)
       DEPLOY_USER  DEPLOY_SSH_PORT  DEPLOY_ME (this machine; default: hostname)
EOF
  exit 2
}
die() {
  echo "fleet: $*" >&2
  exit 1
}

main_ref=${FLEET_MAIN:-main}
max_jobs=${FLEET_JOBS:-6}
me=${DEPLOY_ME:-$(cat /proc/sys/kernel/hostname)}
port=${DEPLOY_SSH_PORT:-$default_port}
user=${DEPLOY_USER:-$default_user}
repo=${FLEET_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/nixconf")}
[ -f "$repo/flake.nix" ] || die "no flake at $repo (set FLEET_REPO)"
git() { command git -C "$repo" "$@"; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fleet.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Start "$@" in the background, at most $max_jobs at a time.
spawn() {
  while [ "$(jobs -rp | wc -l)" -ge "$max_jobs" ]; do wait -n || true; done
  "$@" &
}
join() {
  local s
  s=$(printf '%s, ' "$@")
  echo "${s%, }"
}

# toplevel <flakeref> <host> <drvPath|outPath> <revision as a Nix value>
toplevel() {
  nix eval --no-warn-dirty --raw "$1#nixosConfigurations.$2" --apply "c: (c.extendModules {
    modules = [({lib, ...}: {system.configurationRevision = lib.mkForce $4;})];
  }).config.system.build.toplevel.$3"
}
# eval_to <file> <toplevel args…>: result in <file>, error in <file>.err.
eval_to() {
  local out=$1
  shift
  toplevel "$@" >"$out.tmp" 2>"$out.err" && mv "$out.tmp" "$out"
}
eval_error() { grep -E '^error|error:' "$1.err" | tail -n 1 | sed 's/^ *//'; }
host_names() { nix eval --no-warn-dirty --raw "$1#nixosConfigurations" --apply 'c: toString (builtins.attrNames c)'; }

skip=${FLEET_SKIP-$(sed -n 's/^skip := "\(.*\)"$/\1/p' "$repo/justfile" 2>/dev/null)}

# --- affects --------------------------------------------------------------------
affects() {
  local base_arg=${1:-} base base_desc head_desc h
  if [ -n "$base_arg" ]; then
    base=$(git rev-parse --verify --quiet "$base_arg^{commit}") || die "unknown revision '$base_arg'"
    base_desc="$base_arg (${base:0:7})"
  else
    base=$(git merge-base "$main_ref" HEAD) || die "no merge-base between $main_ref and HEAD"
    base_desc="${base:0:7} (merge-base with $main_ref)"
  fi
  head_desc="working tree (HEAD $(git rev-parse --short=7 HEAD)"
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then head_desc+=" + uncommitted changes"; fi
  head_desc+=")"
  echo "fleet affects: $base_desc → $head_desc" >&2
  if [ -n "$(git ls-files --others --exclude-standard -- '*.nix')" ]; then
    echo "  note: untracked .nix files are invisible to the flake (git add -N them)" >&2
  fi

  local base_ref="git+file://$repo?rev=$base" head_ref="git+file://$repo"
  local head_hosts base_hosts
  head_hosts=$(host_names "$head_ref") || die "cannot list nixosConfigurations in the working tree"
  base_hosts=$(host_names "$base_ref") || die "cannot list nixosConfigurations at ${base:0:7}"

  local hosts=() skipped=()
  for h in $head_hosts; do
    if in_list "$h" "$skip"; then skipped+=("$h"); else hosts+=("$h"); fi
  done
  for h in "${hosts[@]}"; do
    spawn eval_to "$tmp/head.$h" "$head_ref" "$h" drvPath null
    in_list "$h" "$base_hosts" && spawn eval_to "$tmp/base.$h" "$base_ref" "$h" drvPath null
  done
  wait

  local changed=() unchanged=() failed=()
  for h in "${hosts[@]}"; do
    if [ ! -f "$tmp/head.$h" ]; then
      failed+=("$h (working tree: $(eval_error "$tmp/head.$h"))")
    elif ! in_list "$h" "$base_hosts"; then
      changed+=("$h (new)")
    elif [ ! -f "$tmp/base.$h" ]; then
      failed+=("$h (at ${base:0:7}: $(eval_error "$tmp/base.$h"))")
    elif [ "$(cat "$tmp/head.$h")" = "$(cat "$tmp/base.$h")" ]; then
      unchanged+=("$h")
    else
      changed+=("$h")
    fi
  done
  local removed=()
  for h in $base_hosts; do in_list "$h" "$head_hosts" || removed+=("$h"); done

  local line="Affects: "
  if [ ${#changed[@]} -gt 0 ]; then line+=$(join "${changed[@]}"); else line+="none"; fi
  [ ${#unchanged[@]} -eq 0 ] || line+=" (unchanged: $(join "${unchanged[@]}"))"
  echo "$line"
  [ ${#removed[@]} -eq 0 ] || echo "Removed: $(join "${removed[@]}")"
  [ ${#skipped[@]} -eq 0 ] || echo "  skipped (known broken, justfile): $(join "${skipped[@]}")" >&2
  if [ ${#failed[@]} -gt 0 ]; then
    printf 'Eval failed: %s\n' "${failed[@]}"
    return 1
  fi
}

# --- status ---------------------------------------------------------------------
# status_host <host> <main rev>: one tab-separated line in $tmp/status.<host>:
# deployed commit, commits vs main, system state.
status_host() {
  local h=$1 main=$2
  local out="$tmp/status.$h" target running rev current pin counts behind ahead
  if ! target=$(find_target "$h"); then
    printf '%s\t%s\t%s\n' - - unreachable >"$out"
    return
  fi
  running=$(running_revision)
  current=$(remote readlink -f /run/current-system 2>/dev/null || true)
  rev=${running%-dirty}

  local deployed=- vs=- system
  if [[ "$running" =~ ^[0-9a-f]{40}(-dirty)?$ ]]; then
    pin="\"$running\""
    deployed=${rev:0:7}
    [ "$running" = "$rev" ] || deployed+=" (dirty)"
    if counts=$(git rev-list --left-right --count "$main...$rev" 2>/dev/null); then
      read -r behind ahead <<<"$counts"
      if [ "$behind" = 0 ] && [ "$ahead" = 0 ]; then
        vs="at $main_ref"
      else
        vs="$behind behind"
        [ "$ahead" = 0 ] || vs+=", $ahead ahead"
      fi
    else
      vs="unknown commit (not in $repo)"
    fi
  else
    pin=null # built before base/revision.nix
    deployed="(none recorded)"
  fi

  if [ -z "$current" ]; then
    system="cannot read /run/current-system"
  elif ! eval_to "$tmp/main.$h" "git+file://$repo?rev=$main" "$h" outPath "$pin"; then
    system="$main_ref eval failed: $(eval_error "$tmp/main.$h")"
  elif [ "$(cat "$tmp/main.$h")" = "$current" ]; then
    system=current
  else
    system="differs from $main_ref"
  fi
  printf '%s\t%s\t%s\n' "$deployed" "$vs" "$system" >"$out"
}

status() {
  local main h
  main=$(git rev-parse --verify --quiet "$main_ref^{commit}") || die "no branch '$main_ref' in $repo"
  echo "fleet status: hosts vs $main_ref ($(git log -1 --format='%h %s' "$main"))" >&2
  set_ssh_opts
  for h in $registry_hosts; do
    in_list "$h" "$uncreated_hosts" || spawn status_host "$h" "$main"
  done
  wait

  local deployed vs system behind=() current=() unreachable=() other=()
  printf '%-11s %-17s %-22s %s\n' HOST DEPLOYED "VS $main_ref" SYSTEM
  for h in $registry_hosts; do
    if in_list "$h" "$uncreated_hosts"; then
      deployed=- vs=- system="not created"
    else
      IFS=$'\t' read -r deployed vs system <"$tmp/status.$h"
    fi
    printf '%-11s %-17s %-22s %s\n' "$h" "$deployed" "$vs" "$system"
    case "$system" in
      current) current+=("$h") ;;
      "differs from"*) behind+=("$h") ;;
      unreachable) unreachable+=("$h") ;;
      "not created") ;;
      *) other+=("$h") ;;
    esac
  done
  local line="Behind $main_ref: "
  if [ ${#behind[@]} -gt 0 ]; then line+=$(join "${behind[@]}"); else line+="none"; fi
  local rest=()
  [ ${#current[@]} -eq 0 ] || rest+=("current: $(join "${current[@]}")")
  [ ${#unreachable[@]} -eq 0 ] || rest+=("unreachable: $(join "${unreachable[@]}")")
  [ ${#other[@]} -eq 0 ] || rest+=("unknown: $(join "${other[@]}")")
  if [ ${#rest[@]} -gt 0 ]; then
    local joined
    joined=$(printf '%s; ' "${rest[@]}")
    line+=" (${joined%; })"
  fi
  echo
  echo "$line"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  affects) [ $# -le 1 ] || usage; affects "$@" ;;
  status) [ $# -eq 0 ] || usage; status ;;
  -h | --help | help) usage ;;
  *) echo "fleet: unknown command '$cmd'" >&2; usage ;;
esac
