# Tailnet settings: import, then pin only what is known. Every attribute is
# optional + computed with "use state for unknown", and the provider sends
# only fields whose planned value differs from the live one, so an attribute
# left null here stays exactly as it is in the admin console.
#
# Known from the network review: HTTPS certificates are enabled.
# Pin the rest after the first plan's REPORT BACK shows the live values
# (plan.sh prints them): devices_approval_on, devices_key_duration_days
# (review §4: keep 180 d for user devices), devices_auto_updates_on.
#
# Scopes: feature_settings (read/write the settings); https_enabled is a
# networking_settings field, needed only to CHANGE it.
import {
  for_each = var.manage_tailnet_settings ? toset(["tailnet_settings"]) : toset([])
  to       = tailscale_tailnet_settings.this[0]
  id       = each.value # ignored
}

resource "tailscale_tailnet_settings" "this" {
  count = var.manage_tailnet_settings ? 1 : 0

  https_enabled             = true
  devices_approval_on       = null # pin to the imported value
  devices_key_duration_days = null # pin to the imported value
  devices_auto_updates_on   = null # pin to the imported value

  # Later, once tofu is the only writer of the policy (not a surprise change
  # now): acls_externally_managed_on = true, acls_external_link = <repo URL>.
}
