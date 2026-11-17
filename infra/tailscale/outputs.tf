# Read by apply.sh only, never printed: piped into `sops set` when tofu has
# just created/replaced the hosts client. Empty after an import.
output "hosts_oauth_client_secret" {
  value     = try(coalesce(one(tailscale_oauth_client.hosts[*].key)), "")
  sensitive = true
}

output "managed_devices" {
  description = "Hosts whose tags/key expiry tofu enforces (names only)."
  value       = sort(keys(local.managed_devices))
}
