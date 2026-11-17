variable "region" {
  description = "AWS region (next to the data)."
  type        = string
  default     = "eu-central-1"
}

variable "name" {
  description = "Host name: EC2 Name tag, tailnet name, NixOS hostName (modules/nixos/hosts/<name>)."
  type        = string
  default     = "fern"
}

variable "cost_tag" {
  description = "Value of the Project tag on every resource (cost allocation / budget filter)."
  type        = string
  default     = "agent-box"
}

# --- network --------------------------------------------------------------

variable "vpc_id" {
  description = "Existing VPC."
  type        = string
}

variable "subnet_id" {
  description = "Existing PUBLIC subnet (outbound needs the public IPv4; no inbound is allowed)."
  type        = string
}

# --- instance -------------------------------------------------------------

variable "instance_type" {
  description = "Memory-heavy for MATSim analysis: r7i.2xlarge (64 GiB), r7i.4xlarge (128 GiB)."
  type        = string
  default     = "r7i.2xlarge"
}

variable "market" {
  description = "\"spot\" (persistent request, interruption = stop) or \"on-demand\". Changing it replaces the instance: snapshot the root volume first."
  type        = string
  default     = "spot"

  validation {
    condition     = contains(["spot", "on-demand"], var.market)
    error_message = "market must be \"spot\" or \"on-demand\"."
  }
}

variable "spot_max_price" {
  description = "Spot price cap in USD/h; null = the on-demand price."
  type        = string
  default     = null
}

variable "root_volume_gib" {
  description = "gp3 root volume (Nix store, checkouts, ~/.t3). Billed while stopped."
  type        = number
  default     = 100
}

variable "ami_name_filter" {
  description = "Official NixOS AMI name pattern (owner 427812963091). Only used at creation; the box is then upgraded by `just deploy`."
  type        = string
  default     = "nixos/25.11*-x86_64-linux"
}

variable "ami_id" {
  description = "Pin an AMI instead of looking one up (optional)."
  type        = string
  default     = null
}

# --- bootstrap user-data ----------------------------------------------------

variable "username" {
  description = "Primary user (modules/user.nix)."
  type        = string
}

variable "ssh_public_keys" {
  description = "Public keys allowed to log in during bootstrap (modules/ssh-keys.nix)."
  type        = list(string)
}

variable "tailscale_bootstrap_key" {
  description = "ONE-TIME, pre-approved auth key tagged tag:cloud,tag:agent-host. Pass via TF_VAR_tailscale_bootstrap_key; only read at instance creation."
  type        = string
  sensitive   = true
  default     = ""
}

# --- data access (instance role) -------------------------------------------

variable "data_bucket_names" {
  description = "Buckets the agents may read (d_abm results)."
  type        = list(string)
}

variable "read_prefixes" {
  description = "Key prefixes readable in those buckets ([\"\"] = whole bucket)."
  type        = list(string)
  default     = [""]
}

variable "scratch_bucket_name" {
  description = "Bucket holding the writable scratch prefix."
  type        = string
}

variable "scratch_prefix" {
  description = "The only writable prefix, e.g. agents/fern/ (trailing slash)."
  type        = string
}

variable "kms_key_arns" {
  description = "KMS keys of SSE-KMS buckets (empty if SSE-S3)."
  type        = list(string)
  default     = []
}

variable "ecs_run_task" {
  description = "Allow RunTask of the d_abm analysis task (optional)."
  type = object({
    enabled              = bool
    cluster_arn          = optional(string, "")
    task_definition_arns = optional(list(string), []) # family ARNs, e.g. arn:...:task-definition/<family>:*
    pass_role_arns       = optional(list(string), []) # task role + execution role
    log_group_arn        = optional(string, "")
  })
  default = { enabled = false }
}

# --- budget ----------------------------------------------------------------

variable "budget_email" {
  description = "Address for the monthly budget alert; empty = no budget. Activate the Project cost-allocation tag first."
  type        = string
  default     = ""
}

variable "budget_usd" {
  description = "Monthly budget for resources tagged Project=<cost_tag>."
  type        = number
  default     = 40
}
