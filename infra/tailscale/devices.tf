# Registry-driven device state for tagged hosts (maple, peacelily, fern):
# tags = modules/hosts-registry.nix, key expiry disabled. Opt-in
# (TAILNET_DEVICE_TAGS=1 → manage_device_tags) because tagging a stale,
# user-owned node changes its ownership. Normally redundant: OAuth logins
# already advertise these tags, and tagged nodes never expire. It is the
# drift check / repair for nodes registered some other way.
#
# Devices are looked up by MagicDNS name at plan time, so no node IDs live in
# git or tfvars; hosts not in the tailnet (fern before phase 3) are skipped.
data "tailscale_devices" "all" {
  count = var.manage_device_tags ? 1 : 0
}

locals {
  devices_by_name = var.manage_device_tags ? {
    for d in data.tailscale_devices.all[0].devices : d.name => d
  } : {}

  managed_devices = {
    for host, h in var.tagged_hosts : host => {
      node_id = local.devices_by_name["${h.name}.${var.tailnet_domain}"].node_id
      tags    = h.tags
    } if contains(keys(local.devices_by_name), "${h.name}.${var.tailnet_domain}")
  }
}

resource "tailscale_device_tags" "host" {
  for_each = local.managed_devices

  device_id = each.value.node_id
  tags      = toset(each.value.tags)
}

resource "tailscale_device_key" "host" {
  for_each = local.managed_devices

  device_id           = each.value.node_id
  key_expiry_disabled = true
}
