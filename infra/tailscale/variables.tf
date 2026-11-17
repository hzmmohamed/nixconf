# Every variable is set by scripts/tailscale/lib.sh (TF_VAR_* or the generated
# hosts.auto.tfvars.json). The defaults are the safe "manage less" choice.

variable "manage_tailnet_settings" {
  description = "Manage tailscale_tailnet_settings (needs the feature_settings scope; set from the admin client's granted scopes)."
  type        = bool
  default     = false
}

variable "hosts_oauth_client_id" {
  description = "ID of the hosts' tag:provisioner OAuth client (derived at runtime from secrets/shared/tailscale-oauth.yaml; empty = unmanaged). Needs the oauth_keys scope."
  type        = string
  default     = ""
}

variable "manage_device_tags" {
  description = "Enforce registry tags + disabled key expiry on tagged hosts (opt-in: TAILNET_DEVICE_TAGS=1, needs devices:core)."
  type        = bool
  default     = false
}

variable "tailnet_domain" {
  description = "MagicDNS domain (flake.tailnet.domain)."
  type        = string
  default     = "tail1a9f7c.ts.net"
}

variable "tagged_hosts" {
  description = "Hosts with Tailscale tags, from modules/hosts-registry.nix: { <host> = { name = <MagicDNS label>, tags = [...] } }."
  type = map(object({
    name = string
    tags = list(string)
  }))
  default = {}
}
