output "instance_id" {
  value = aws_instance.agent_host.id
}

output "ami" {
  description = "AMI the box was born from. Its boot mode must match ec2.efi in modules/nixos/hosts/<name>."
  value       = local.ami_id
}

output "ami_boot_mode" {
  value = var.ami_id == null ? data.aws_ami.nixos[0].boot_mode : "unknown (pinned ami_id)"
}

output "role_arn" {
  value = aws_iam_role.agent_host.arn
}

output "security_group_id" {
  value = aws_security_group.agent_host.id
}

# Narrow policy for the HUMAN identity that runs `cloud-box` (optional;
# admin already covers it). Attach it to an SSO permission set or IAM user.
output "operator_policy_json" {
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Describe"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid      = "StartStop"
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances", "ec2:GetConsoleOutput"]
        Resource = aws_instance.agent_host.arn
      },
    ]
  })
}
