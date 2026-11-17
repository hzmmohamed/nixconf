# The hosts' OAuth client: auth_keys only, tag:provisioner only (owns every
# host tag). maple, peacelily and fern log in with it
# (features/tailscale.nix, secrets/shared/tailscale-oauth.yaml).
#
# Adopted, not created: the client ID is derived at runtime from the stored
# secret (tskey-client-<id>-<secret>) and passed as TF_VAR_hosts_oauth_client_id,
# so no ID lands in git. The API never returns an existing secret: after the
# import, `key` is null in state and the sops file stays the only copy.
#
# Rotation (new secret): temporarily drop prevent_destroy, then
#   env TAILNET_REPLACE_HOSTS_CLIENT=1 bash scripts/tailscale/apply.sh
# (plans with -replace). apply.sh pipes the new `key` straight into `sops set` on
# secrets/shared/tailscale-oauth.yaml; it is never printed. Note that the
# secret then also lives in the (encrypted, private) S3 state.
import {
  for_each = var.hosts_oauth_client_id != "" ? toset([var.hosts_oauth_client_id]) : toset([])
  to       = tailscale_oauth_client.hosts[0]
  id       = each.value
}

resource "tailscale_oauth_client" "hosts" {
  count = var.hosts_oauth_client_id != "" ? 1 : 0

  description = "nixconf hosts"
  scopes      = ["auth_keys"]
  tags        = ["tag:provisioner"]

  lifecycle {
    # Deleting it breaks every OAuth host's next login.
    prevent_destroy = true
  }
}
