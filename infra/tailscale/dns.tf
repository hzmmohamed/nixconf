# Tailnet DNS, as live on 2026-11-17 (network review §1, §2.2): MagicDNS on,
# global resolvers Cloudflare + Google with "Override local DNS" on (the
# anti-ISP path; Tailscale upgrades these known resolvers to DoH), no split
# DNS, no extra search domains.
#
# tailscale_dns_configuration rather than the older per-aspect resources
# (tailscale_dns_nameservers / _preferences / _search_paths /
# _split_nameservers): only it carries override_local_dns, and it must not be
# mixed with them (each would overwrite the others' view).
#
# Imported first; the first plan must show no change here. If it does, the
# live state differs from the review: copy the live value in, don't apply.
import {
  to = tailscale_dns_configuration.this
  id = "dns_configuration" # ignored
}

resource "tailscale_dns_configuration" "this" {
  magic_dns          = true
  override_local_dns = true

  nameservers {
    address = "1.1.1.1"
  }
  nameservers {
    address = "1.0.0.1"
  }
  nameservers {
    address = "8.8.8.8"
  }
  nameservers {
    address = "8.8.4.4"
  }

  search_paths = []

  lifecycle {
    # Destroy RESETS the tailnet DNS (empty config): never by accident.
    prevent_destroy = true
  }
}
