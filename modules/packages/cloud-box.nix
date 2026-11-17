# cloud-box — drive the on-demand EC2 agent host from hazel/butternut
# (docs/plans/2026-11-17-aws-agent-host.md §3):
#   cloud-box up         start, wait for the tailnet + T3, open the T3 URL
#   cloud-box down [-f]  stop (refuses while the box reports busy, unless -f)
#   cloud-box status     EC2 state + tailnet reachability + idle report
#   cloud-box ssh [cmd]  ssh to the box
#   cloud-box hold <min> keep it up despite idleness (long unattended job)
# Uses YOUR AWS identity (AWS_PROFILE), never the box's role; the instance is
# found by its Name tag.
#   CLOUD_BOX_NAME    instance Name tag and tailnet name (default fern)
#   CLOUD_BOX_REGION  default eu-central-1
{self, ...}: {
  perSystem = {pkgs, ...}: {
    packages.cloud-box = pkgs.writeShellApplication {
      name = "cloud-box";
      runtimeInputs = with pkgs; [awscli2 openssh tailscale curl coreutils xdg-utils];
      text = ''
        name=''${CLOUD_BOX_NAME:-fern}
        region=''${CLOUD_BOX_REGION:-eu-central-1}
        url="https://$name.${self.tailnet.domain}/"
        aws_() { aws --region "$region" "$@"; }
        die() { echo "cloud-box: $*" >&2; exit 1; }

        # JMESPath literal in backticks, not a shell expansion.
        # shellcheck disable=SC2016
        instance() {
          aws_ ec2 describe-instances \
            --filters "Name=tag:Name,Values=$name" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
            --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,InstanceLifecycle||`on-demand`,LaunchTime]' \
            --output text
        }

        info=$(instance) || die "describe-instances failed (AWS_PROFILE? aws sso login?)"
        [ -n "$info" ] || die "no instance tagged Name=$name in $region"
        read -r id state itype market launched <<<"$info"

        on_tailnet() { tailscale ping -c 1 --timeout 3s "$name" >/dev/null 2>&1; }

        case "''${1:-status}" in
          up)
            if [ "$state" = stopping ]; then
              echo ">> $name is stopping; waiting"
              aws_ ec2 wait instance-stopped --instance-ids "$id"
              state=stopped
            fi
            if [ "$state" = stopped ]; then
              echo ">> starting $name ($id, $itype, $market)"
              aws_ ec2 start-instances --instance-ids "$id" >/dev/null ||
                die "start failed (spot capacity? retry, or switch var.market)"
            fi
            aws_ ec2 wait instance-running --instance-ids "$id"
            echo ">> running; waiting for $name on the tailnet"
            for _ in $(seq 60); do on_tailnet && break; sleep 5; done
            on_tailnet || die "$name did not join the tailnet in 5 min (serial console: aws ec2 get-console-output --instance-id $id)"
            echo ">> waiting for T3 at $url"
            for _ in $(seq 36); do curl -fsS -o /dev/null --max-time 5 "$url" && break; sleep 5; done
            if [ -n "''${WAYLAND_DISPLAY:-}''${DISPLAY:-}" ]; then
              xdg-open "$url" >/dev/null 2>&1 || true
            fi
            echo ">> $url"
            ;;
          down)
            if [ "$state" != running ]; then echo "$name is $state"; exit 0; fi
            if [ "''${2:-}" != -f ] && on_tailnet; then
              report=$(ssh -o ConnectTimeout=5 "$name" cloud-idle status 2>/dev/null || true)
              if [ "$(printf '%s\n' "$report" | head -n1)" = busy ]; then
                echo "$report"
                die "$name is busy; 'cloud-box down -f' to stop anyway"
              fi
            fi
            aws_ ec2 stop-instances --instance-ids "$id" >/dev/null
            echo ">> stopping $name"
            ;;
          status)
            echo "$name  $id  $state  $itype  $market  launched $launched"
            if [ "$state" = running ]; then
              if on_tailnet; then
                echo "tailnet: up  ($url)"
                ssh -o ConnectTimeout=5 "$name" cloud-idle status 2>/dev/null || true
              else
                echo "tailnet: not reachable yet"
              fi
            fi
            ;;
          ssh)
            shift
            exec ssh "$name" "$@"
            ;;
          hold)
            [ "$state" = running ] || die "$name is $state"
            exec ssh "$name" cloud-idle hold "''${2:?usage: cloud-box hold <minutes>}"
            ;;
          *)
            echo "usage: cloud-box [up|down [-f]|status|ssh [cmd...]|hold <minutes>]" >&2
            exit 2
            ;;
        esac
      '';
    };
  };
}
