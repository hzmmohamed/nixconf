# Official NixOS AMI (NixOS project account). Only read at creation: later
# AMIs never replace the instance (lifecycle.ignore_changes below).
data "aws_ami" "nixos" {
  count       = var.ami_id == null ? 1 : 0
  owners      = ["427812963091"]
  most_recent = true

  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.nixos[0].id

  user_data = templatefile("${path.module}/bootstrap.nix.tftpl", {
    name            = var.name
    username        = var.username
    ssh_public_keys = var.ssh_public_keys
    ts_key          = var.tailscale_bootstrap_key
  })
}

# Tailscale only: NO ingress at all. Direct WireGuard paths still form via
# NAT traversal (stateful SG), DERP otherwise.
resource "aws_security_group" "agent_host" {
  name        = "${var.name}-agent-host"
  description = "${var.name}: no inbound (Tailscale only), all outbound"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-agent-host" }
}

resource "aws_vpc_security_group_egress_rule" "all_v4" {
  security_group_id = aws_security_group.agent_host.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all_v6" {
  security_group_id = aws_security_group.agent_host.id
  ip_protocol       = "-1"
  cidr_ipv6         = "::/0"
}

resource "aws_instance" "agent_host" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.agent_host.id]
  iam_instance_profile   = aws_iam_instance_profile.agent_host.name

  # Needed for outbound (cache.nixos.org, GitHub, GitLab) without a NAT gateway.
  associate_public_ip_address = true

  # `systemctl poweroff` (cloud-idle-stop) = stopped, not terminated. Spot
  # rejects this attribute; a persistent spot request with interruption
  # behaviour "stop" already treats an OS shutdown as instance-stopped-by-user.
  instance_initiated_shutdown_behavior = var.market == "spot" ? null : "stop"

  user_data                   = local.user_data
  user_data_replace_on_change = false

  dynamic "instance_market_options" {
    for_each = var.market == "spot" ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
        max_price                      = var.spot_max_price
      }
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # no containers on the box
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gib
    encrypted             = true
    delete_on_termination = false # survive a replacement/destroy; delete by hand
    tags                  = { Name = "${var.name}-root" }
  }


  tags = { Name = var.name }

  lifecycle {
    # The box is managed by `just deploy` after the first boot.
    ignore_changes = [ami, user_data]
  }
}
