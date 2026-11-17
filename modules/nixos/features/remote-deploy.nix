{
  lib,
  self,
  ...
}: let
  # Hosts that build their own system (hosts registry `buildOnTarget`).
  targetBuildHosts = lib.attrNames (lib.filterAttrs (_: h: h.buildOnTarget or false) self.hosts);
in {
  # `deploy <host> [switch|boot|test|dry-activate]` — build a host's system
  # from the local flake checkout, copy it over SSH and activate it there.
  #
  # Target: `<host>` first — the hosts-registry ssh config resolves it to the
  # cable address when the cable is up, else the tailnet IP (/etc/hosts) —
  # then `<host>.local` (mDNS: hotspot, or the cable in a shared mode). Activation uses doas on the
  # target (no sudo, so `nixos-rebuild --target-host --sudo` is out). The
  # deploying user is in wheel → a trusted Nix user on the target, so
  # unsigned local builds are accepted by `nix copy`.
  #
  # Env: DEPLOY_FLAKE (default ~/nixconf), DEPLOY_SSH_PORT (default 7654),
  #      DEPLOY_USER (default: the primary user), DEPLOY_TARGET (skip lookup),
  #      DEPLOY_BUILD_ON (local|target; default target for registry hosts with
  #      `buildOnTarget`, e.g. the cloud box: evaluate here, build/substitute there).
  flake.nixosModules.remote-deploy = {
    config,
    pkgs,
    ...
  }: let
    deploy = pkgs.writeShellApplication {
      name = "deploy";
      runtimeInputs = with pkgs; [openssh coreutils nix];
      text = ''
        usage() {
          echo "usage: deploy <host> [switch|boot|test|dry-activate]" >&2
          exit 2
        }
        die() {
          echo "deploy: $*" >&2
          exit 1
        }

        [ $# -ge 1 ] && [ $# -le 2 ] || usage
        host=$1
        action=''${2:-switch}
        case "$action" in
          switch | boot | test | dry-activate) ;;
          *) usage ;;
        esac

        flake=''${DEPLOY_FLAKE:-$HOME/nixconf}
        port=''${DEPLOY_SSH_PORT:-7654}
        user=''${DEPLOY_USER:-${config.preferences.user.name}}
        [ -f "$flake/flake.nix" ] || die "no flake at $flake (set DEPLOY_FLAKE)"

        # Keepalives: a target that vanishes (spot stop, Wi-Fi drop) fails the
        # deploy within ~1 min instead of hanging on a dead connection.
        ssh_opts=(-p "$port" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
        export NIX_SSHOPTS="''${ssh_opts[*]}"

        # 1. Find a reachable address before spending time on the build.
        target=''${DEPLOY_TARGET:-}
        if [ -z "$target" ]; then
          for candidate in "$host" "$host.local"; do
            if ssh "''${ssh_opts[@]}" -o BatchMode=yes "$user@$candidate" true 2>/dev/null; then
              target=$candidate
              break
            fi
          done
        fi
        if [ -z "$target" ]; then
          echo "deploy: cannot log in to $host or $host.local on port $port as $user." >&2
          echo "  - cable: is the link up? (nmcli device; ping $host.local)" >&2
          echo "  - key: if 'ssh -p $port $user@$host.local' asks for a password, this" >&2
          echo "    machine's key is not in modules/ssh-keys.nix on $host yet — switch" >&2
          echo "    $host locally once (see docs/plans/2026-11-17-user-actions.md)." >&2
          exit 1
        fi
        echo ">> deploying $host via $user@$target ($action)"

        installable="$flake#nixosConfigurations.$host.config.system.build.toplevel"
        build_on=''${DEPLOY_BUILD_ON:-local}
        target_build_hosts=" ${lib.concatStringsSep " " targetBuildHosts} "
        case "$target_build_hosts" in
          *" $host "*) build_on=''${DEPLOY_BUILD_ON:-target} ;;
        esac

        if [ "$build_on" = target ]; then
          # 2+3. Evaluate here, build on the target: only derivations cross
          #      the link; the target substitutes from its own caches.
          system=$(nix build --no-link --print-out-paths \
            --eval-store auto --store "ssh-ng://$user@$target" "$installable") ||
            die "remote build failed"
          echo ">> built $system on $target"
        else
          # 2. Build locally.
          system=$(nix build --no-link --print-out-paths "$installable") ||
            die "build failed"
          echo ">> built $system"

          # 3. Copy the closure (substitutes on the target are not used: the
          #    cable is usually faster than the target's internet).
          #    Local builds are unsigned: --no-check-sigs (only honoured for a
          #    trusted user on the target, i.e. wheel; nix copy otherwise asks
          #    the target to check signatures even then).
          nix copy --no-check-sigs --to "ssh-ng://$user@$target" "$system" || die "nix copy failed"
        fi

        # Arguments are store paths/fixed words, so client-side expansion is intended.
        # shellcheck disable=SC2029
        remote() { ssh "''${ssh_opts[@]}" "$user@$target" "$@"; }

        # 4. Show what changes, on the target, against its running system.
        remote nix store diff-closures /run/current-system "$system" || true

        # 5. Activate.
        if [ "$action" = switch ] || [ "$action" = boot ]; then
          remote doas nix-env -p /nix/var/nix/profiles/system --set "$system" ||
            die "setting the system profile failed (passwordless doas on $host?)"
        fi
        # Run it as a transient unit on the target (like nixos-rebuild): it
        # leaves the SSH session's cgroup, so a network restart that drops
        # the connection mid-switch can't kill it half-way. If the
        # connection does drop (ssh exit 255), reconnect and wait for the
        # unit's result instead of failing.
        unit=deploy-switch-to-configuration
        rc=0
        remote doas systemd-run --unit="$unit" --collect --no-ask-password \
          --pipe --wait --quiet --service-type=exec \
          -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER \
          "$system/bin/switch-to-configuration" "$action" || rc=$?
        if [ "$rc" = 255 ]; then
          echo ">> connection to $host dropped during activation; waiting for $unit" >&2
          state=unknown
          for _ in $(seq 60); do
            sleep 5
            state=$(remote systemctl show "$unit" -p ActiveState --value 2>/dev/null) || continue
            case "$state" in activating | active | deactivating) continue ;; *) break ;; esac
          done
          result=$(remote systemctl show "$unit" -p Result --value 2>/dev/null || true)
          # --collect removes the unit once done: an inactive unit with no
          # result left means it finished; check the running system instead.
          current=$(remote readlink -f /run/current-system 2>/dev/null || true)
          if [ "$action" = boot ] || [ "$current" = "$system" ]; then
            [ -z "$result" ] || [ "$result" = success ] ||
              die "switch-to-configuration $action on $host: $result (journalctl -u $unit)"
            rc=0
          else
            die "switch-to-configuration $action on $host did not finish (state=$state result=$result)"
          fi
        fi
        [ "$rc" = 0 ] || die "switch-to-configuration $action failed on $host"
        echo ">> $host: $action done"
      '';
    };
  in {
    environment.systemPackages = [deploy];
  };
}
