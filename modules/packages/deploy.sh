# deploy — body of the `deploy` package (modules/packages/deploy.nix, which
# prepends the registry data: registry_hosts, target_build_hosts, builders,
# caches, default_user, default_port). Not a standalone script.

usage() {
  cat >&2 <<EOF
usage: deploy [--plan] [--dry-run] [--force] <host> [switch|boot|test|dry-activate]
       deploy [--plan] [--dry-run] [--force] all [--skip h1,h2] [switch|boot|test|dry-activate]

  --dry-run   build and copy, then 'switch-to-configuration dry-activate'
              (shows what would change; nothing is activated)
  --force     deploy even if the target runs a commit this checkout lacks
              (it would roll the target back)
  --plan      print where it would build / copy / activate, run nothing
              (no ssh, no build; reachability is assumed)
  all         every registry host in turn (this machine last), then a table
              OK / unreachable / failed / skipped
  --skip      with 'all': hosts to leave out, comma-separated

hosts: $registry_hosts
env:   DEPLOY_FLAKE (default ~/nixconf)  DEPLOY_USER  DEPLOY_SSH_PORT
       DEPLOY_TARGET (skip address lookup)  DEPLOY_BUILD_ON (local|target|<host>)
       DEPLOY_ME (this machine's name; default: hostname)
EOF
  exit 2
}
die() {
  echo "deploy: $*" >&2
  exit 1
}
# Exit code 3 = target unreachable (`deploy all` reports it as such).
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

plan_only=0
dry_run=0
force=0
skip=""
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) plan_only=1 ;;
    --dry-run | -n) dry_run=1 ;;
    --force) force=1 ;;
    --skip) [ $# -ge 2 ] || usage; skip=$2; shift ;;
    --skip=*) skip=${1#--skip=} ;;
    -h | --help) usage ;;
    -*) echo "deploy: unknown option $1" >&2; usage ;;
    *) positional+=("$1") ;;
  esac
  shift
done
[ ${#positional[@]} -ge 1 ] && [ ${#positional[@]} -le 2 ] || usage
host=${positional[0]}
action=${positional[1]:-}
if [ "$dry_run" = 1 ]; then
  [ -z "$action" ] || [ "$action" = dry-activate ] || die "--dry-run conflicts with '$action'"
  action=dry-activate
fi
action=${action:-switch}
case "$action" in
  switch | boot | test | dry-activate) ;;
  *) echo "deploy: unknown action '$action'" >&2; usage ;;
esac

me=${DEPLOY_ME:-$(cat /proc/sys/kernel/hostname)}
flake=${DEPLOY_FLAKE:-$HOME/nixconf}
port=${DEPLOY_SSH_PORT:-$default_port}
user=${DEPLOY_USER:-$default_user}
[ -f "$flake/flake.nix" ] || die "no flake at $flake (set DEPLOY_FLAKE)"

# --- deploy all ---------------------------------------------------------------
if [ "$host" = all ]; then
  skip_list=" ${skip//,/ } "
  order=()
  for h in $registry_hosts; do [ "$h" = "$me" ] || order+=("$h"); done
  # This machine last: if its switch breaks the network, the rest are done.
  if in_list "$me" "$registry_hosts"; then order+=("$me"); fi

  flags=()
  [ "$plan_only" = 1 ] && flags+=(--plan)
  [ "$force" = 1 ] && flags+=(--force)
  logdir=$(mktemp -d "${TMPDIR:-/tmp}/deploy-all.XXXXXX")
  declare -A outcome
  failed=0
  for h in "${order[@]}"; do
    if in_list "$h" "$skip_list"; then
      outcome[$h]=skipped
      continue
    fi
    echo
    echo "=================== $h ==================="
    rc=0
    "$0" "${flags[@]}" "$h" "$action" 2>&1 | tee "$logdir/$h.log" || rc=${PIPESTATUS[0]}
    case "$rc" in
      0) outcome[$h]=OK ;;
      3) outcome[$h]=unreachable ;;
      *) outcome[$h]="failed (exit $rc, log $logdir/$h.log)"; failed=1 ;;
    esac
  done
  echo
  printf '%-12s %s\n' HOST "RESULT ($action)"
  for h in "${order[@]}"; do printf '%-12s %s\n' "$h" "${outcome[$h]}"; done
  exit "$failed"
fi

in_list "$host" "$registry_hosts" ||
  die "unknown host '$host' (registry hosts: $registry_hosts)"

# Keepalives: a target that vanishes (spot stop, Wi-Fi drop) fails the
# deploy within ~1 min instead of hanging on a dead connection.
ssh_opts=(-p "$port" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
  -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
export NIX_SSHOPTS="${ssh_opts[*]}"

# Can we log in? In --plan mode nothing is probed: everything is assumed
# reachable except the hosts in DEPLOY_PLAN_UNREACHABLE (tests).
reachable() {
  if [ "$plan_only" = 1 ]; then
    if in_list "${1%.local}" "${DEPLOY_PLAN_UNREACHABLE:-}"; then return 1; fi
    return 0
  fi
  ssh "${ssh_opts[@]}" -o BatchMode=yes "$user@$1" true 2>/dev/null
}
lookup() { # lookup <key> <"k=v k=v"> → v
  local kv
  for kv in $2; do
    if [ "${kv%%=*}" = "$1" ]; then
      echo "${kv#*=}"
      return 0
    fi
  done
  return 1
}

# 1. Where is the target? This machine: no ssh at all. Otherwise `<host>`
#    first (the registry ssh config takes the cable when it is up, else the
#    tailnet IP from /etc/hosts), then `<host>.local` (mDNS).
target=${DEPLOY_TARGET:-}
if [ "$host" = "$me" ] && [ -z "$target" ]; then
  target=local
elif [ -z "$target" ]; then
  for candidate in "$host" "$host.local"; do
    if reachable "$candidate"; then
      target=$candidate
      break
    fi
  done
  if [ -z "$target" ]; then
    echo "deploy: cannot log in to $host or $host.local on port $port as $user." >&2
    echo "  - cable: is the link up? (nmcli device; ping $host.local)" >&2
    echo "  - tailnet: tailscale status | grep $host" >&2
    echo "  - key: if 'ssh -p $port $user@$host' asks for a password, this" >&2
    echo "    machine's key is not in modules/ssh-keys.nix on $host yet — switch" >&2
    echo "    $host locally once (see docs/plans/2026-11-17-user-actions.md)." >&2
    exit 3
  fi
fi

# 2. Where to build? (DEPLOY_BUILD_ON overrides: local | target | <host>)
#    - the machine being deployed is this one: here (the daemon still
#      offloads to its nix.buildMachines, e.g. hazel → butternut)
#    - the registry says the target builds itself (buildOnTarget): there
#    - this machine has a registry builder (builderFor): on the builder,
#      the target then substitutes from the builder's cache
#    - else here, then nix copy to the target (the cable is fast)
build_on=${DEPLOY_BUILD_ON:-}
why="DEPLOY_BUILD_ON"
my_builder=$(lookup "$me" "$builders" || true)
if [ -z "$build_on" ]; then
  if [ "$target" = local ]; then
    build_on=local why="self-deploy"
  elif in_list "$host" "$target_build_hosts"; then
    build_on=target why="registry: $host has buildOnTarget"
  elif [ -n "$my_builder" ] && [ "$my_builder" != "$me" ]; then
    if reachable "$my_builder"; then
      build_on=$my_builder why="registry: $my_builder builds for $me"
    else
      build_on=local why="$my_builder (builder for $me) is unreachable"
    fi
  else
    build_on=local why="no builder for $me"
  fi
fi
[ "$build_on" = "$host" ] && build_on=target
[ "$build_on" = "$me" ] && build_on=local
[ "$target" = local ] && [ "$build_on" = target ] && build_on=local

installable="$flake#nixosConfigurations.$host.config.system.build.toplevel"
case "$build_on" in
  local)
    build_where="here ($me)"
    if [ -s /etc/nix/machines ]; then
      build_where+=", offloaded by the nix daemon to $(cut -d' ' -f1 /etc/nix/machines | tr '\n' ' ')when reachable"
    fi
    if [ "$target" = local ]; then copy_how="none (already here)"; else copy_how="nix copy $me → $host"; fi
    ;;
  target)
    build_where="on $host (eval here, only .drv files cross)"
    copy_how="none (built in place)"
    ;;
  *)
    in_list "$build_on" "$registry_hosts" || die "DEPLOY_BUILD_ON: unknown host '$build_on'"
    build_where="on $build_on (eval here, only .drv files cross)"
    cache=$(lookup "$build_on" "$caches" || true)
    if [ -n "$cache" ]; then
      copy_how="$host substitutes from ${cache%%|*} (fallback: nix copy $build_on → $host through $me)"
    else
      copy_how="nix copy $build_on → $host (streams through $me)"
    fi
    ;;
esac
if [ "$target" = local ]; then
  activate_how="here, doas systemd-run switch-to-configuration $action"
else
  activate_how="on $user@$target, doas systemd-run switch-to-configuration $action"
fi

echo ">> deploy $host ($action) from $me"
echo "   build:    $build_where  [$why]"
echo "   copy:     $copy_how"
echo "   activate: $activate_how"
[ "$plan_only" = 0 ] || exit 0

# Arguments are store paths/fixed words, so client-side expansion is intended.
# shellcheck disable=SC2029
remote() {
  if [ "$target" = local ]; then
    "$@"
  else
    ssh "${ssh_opts[@]}" "$user@$target" "$@"
  fi
}

# 3. Is this checkout at least as new as what the target runs? Deploying an
#    older checkout (a machine that wasn't synced) silently rolls the target
#    back. The target's commit comes from system.configurationRevision
#    (base/revision.nix); systems built before it have none: no check.
running=$(remote nixos-version --configuration-revision 2>/dev/null || true)
running_rev=${running%-dirty}
if [ -n "$running_rev" ] && [ "$force" = 0 ]; then
  head_rev=$(git -C "$flake" rev-parse HEAD 2>/dev/null || true)
  if ! git -C "$flake" cat-file -e "$running_rev^{commit}" 2>/dev/null; then
    die "$host runs commit ${running_rev:0:12}, which this checkout ($flake) does not have.
  Deploying would roll $host back. Bring this checkout up to date (fetch the
  machine that deployed $host last), or deploy from that machine; --force to
  deploy anyway."
  elif [ -n "$head_rev" ] && ! git -C "$flake" merge-base --is-ancestor "$running_rev" "$head_rev"; then
    die "$host runs ${running_rev:0:12} ($(git -C "$flake" log -1 --format=%s "$running_rev")),
  which is not in this checkout's history (HEAD ${head_rev:0:12}). Deploying would
  drop those commits from $host: merge or rebase first; --force to deploy anyway."
  fi
  [ "$running" = "$running_rev" ] ||
    echo ">> note: $host runs ${running_rev:0:12} with uncommitted changes; they are replaced" >&2
fi

# 4. Build (and copy).
case "$build_on" in
  local)
    system=$(nix build --no-link --print-out-paths "$installable") || die "build failed"
    echo ">> built $system"
    if [ "$target" != local ]; then
      # Local builds are unsigned: --no-check-sigs (honoured for a trusted
      # user on the target, i.e. wheel).
      nix copy --no-check-sigs --to "ssh-ng://$user@$target" "$system" || die "nix copy failed"
    fi
    ;;
  target)
    system=$(nix build --no-link --print-out-paths \
      --eval-store auto --store "ssh-ng://$user@$target" "$installable") ||
      die "build on $host failed"
    echo ">> built $system on $host"
    ;;
  *)
    system=$(nix build --no-link --print-out-paths \
      --eval-store auto --store "ssh-ng://$user@$build_on" "$installable") ||
      die "build on $build_on failed"
    echo ">> built $system on $build_on"
    copied=0
    if [ -n "$cache" ]; then
      # The target pulls the closure straight from the builder's harmonia
      # cache (signed with the builder's key, trusted for this one command;
      # the deploying user is trusted there) and everything public from
      # cache.nixos.org. Nothing travels through this machine.
      echo ">> $host: substituting from ${cache%%|*}"
      if remote nix build --no-link --connect-timeout 5 \
        --extra-substituters "${cache%%|*}?priority=10" \
        --extra-trusted-public-keys "${cache#*|}" "$system"; then
        copied=1
      else
        echo ">> substituting failed; copying $build_on → $host through $me" >&2
      fi
    fi
    if [ "$copied" = 0 ]; then
      nix copy --no-check-sigs --from "ssh-ng://$user@$build_on" \
        --to "ssh-ng://$user@$target" "$system" || die "nix copy $build_on → $host failed"
    fi
    ;;
esac

# 5. Show what changes, on the target, against its running system.
remote nix store diff-closures /run/current-system "$system" || true

# 6. Activate.
if [ "$action" = switch ] || [ "$action" = boot ]; then
  remote doas nix-env -p /nix/var/nix/profiles/system --set "$system" ||
    die "setting the system profile failed (passwordless doas on $host?)"
fi
# Run it as a transient unit (like nixos-rebuild): it leaves the SSH
# session's cgroup, so a network restart that drops the connection
# mid-switch can't kill it half-way. If the connection does drop (ssh exit
# 255), reconnect and wait for the unit's result instead of failing. On this
# machine it also survives the terminal going away.
unit=deploy-switch-to-configuration

# A switch waits on every unit it starts (home-manager's sd-switch on user
# oneshots too); one that never finishes hangs the deploy with no output.
# After 90 s, say every minute which systemd jobs are still pending on the
# target and what processes the running ones are stuck in.
show_pending() {
  local scope jobs line u
  for scope in system user; do
    local sc=()
    [ "$scope" = user ] && sc=(--user)
    jobs=$(remote systemctl "${sc[@]}" list-jobs --no-legend --no-pager 2>/dev/null) || continue
    [ -n "$jobs" ] || continue
    echo "   $scope jobs:"
    while read -r line; do
      [ -n "$line" ] || continue
      echo "     $line"
      # "<job> <unit> <type> <state>": show where a running job is stuck.
      local f=()
      read -ra f <<<"$line"
      [ "${f[3]:-}" = running ] || continue
      u=${f[1]}
      remote systemctl "${sc[@]}" status --no-pager --lines=0 "$u" 2>/dev/null |
        sed -n '/CGroup:/,$p' | sed 's/^/       /' | head -n 8
    done <<<"$jobs"
  done
}
watchdog() {
  sleep 90
  while :; do
    {
      echo ">> $host: still activating; pending systemd jobs:"
      show_pending
      echo "   (inspect: systemctl [--user] status <unit>; killing the stuck process lets the switch go on)"
    } >&2
    sleep 60
  done
}
watchdog &
watchdog_pid=$!
trap 'kill "$watchdog_pid" 2>/dev/null || true' EXIT

rc=0
remote doas systemd-run --unit="$unit" --collect --no-ask-password \
  --pipe --wait --quiet --service-type=exec \
  -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER \
  "$system/bin/switch-to-configuration" "$action" || rc=$?
if [ "$rc" = 255 ] && [ "$target" != local ]; then
  echo ">> connection to $host dropped during activation; waiting for $unit" >&2
  state=unknown
  for _ in $(seq 60); do
    sleep 5
    state=$(remote systemctl show "$unit" -p ActiveState --value 2>/dev/null) || continue
    case "$state" in activating | active | deactivating) continue ;; *) break ;; esac
  done
  result=$(remote systemctl show "$unit" -p Result --value 2>/dev/null || true)
  # --collect removes the unit once done: an inactive unit with no result
  # left means it finished; check the running system instead.
  current=$(remote readlink -f /run/current-system 2>/dev/null || true)
  if [ "$action" = boot ] || [ "$action" = dry-activate ] || [ "$current" = "$system" ]; then
    [ -z "$result" ] || [ "$result" = success ] ||
      die "switch-to-configuration $action on $host: $result (journalctl -u $unit)"
    rc=0
  else
    die "switch-to-configuration $action on $host did not finish (state=$state result=$result)"
  fi
fi
kill "$watchdog_pid" 2>/dev/null || true
[ "$rc" = 0 ] || die "switch-to-configuration $action failed on $host"
echo ">> $host: $action done"
