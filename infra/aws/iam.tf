# Instance role: read the d_abm data, write one scratch prefix, optionally
# run the d_abm analysis task on ECS. Nothing else (no EC2/IAM/SSM).

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent_host" {
  name                 = "${var.name}-agent-host"
  assume_role_policy   = data.aws_iam_policy_document.assume_ec2.json
  max_session_duration = 3600
}

resource "aws_iam_instance_profile" "agent_host" {
  name = "${var.name}-agent-host"
  role = aws_iam_role.agent_host.name
}

locals {
  read_object_arns = flatten([
    for b in var.data_bucket_names : [for p in var.read_prefixes : "arn:aws:s3:::${b}/${p}*"]
  ])
  list_prefixes = [for p in var.read_prefixes : "${p}*"]
}

data "aws_iam_policy_document" "data_access" {
  statement {
    sid       = "ListData"
    actions   = ["s3:ListBucket"]
    resources = [for b in var.data_bucket_names : "arn:aws:s3:::${b}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = local.list_prefixes
    }
  }

  statement {
    sid       = "ReadData"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = local.read_object_arns
  }

  statement {
    sid       = "ListScratch"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.scratch_bucket_name}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.scratch_prefix}*"]
    }
  }

  statement {
    sid = "WriteScratch"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["arn:aws:s3:::${var.scratch_bucket_name}/${var.scratch_prefix}*"]
  }

  dynamic "statement" {
    for_each = length(var.kms_key_arns) > 0 ? [1] : []
    content {
      sid       = "BucketKeys"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = var.kms_key_arns
    }
  }
}

resource "aws_iam_role_policy" "data_access" {
  name   = "data-access"
  role   = aws_iam_role.agent_host.id
  policy = data.aws_iam_policy_document.data_access.json
}

data "aws_iam_policy_document" "ecs_run_task" {
  count = var.ecs_run_task.enabled ? 1 : 0

  statement {
    sid       = "RunAnalysisTask"
    actions   = ["ecs:RunTask"]
    resources = var.ecs_run_task.task_definition_arns
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_run_task.cluster_arn]
    }
  }

  statement {
    sid       = "WatchTasks"
    actions   = ["ecs:DescribeTasks", "ecs:StopTask"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_run_task.cluster_arn]
    }
  }

  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = var.ecs_run_task.pass_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  dynamic "statement" {
    for_each = var.ecs_run_task.log_group_arn != "" ? [1] : []
    content {
      sid       = "ReadTaskLogs"
      actions   = ["logs:GetLogEvents", "logs:FilterLogEvents"]
      resources = ["${var.ecs_run_task.log_group_arn}:*"]
    }
  }
}

resource "aws_iam_role_policy" "ecs_run_task" {
  count  = var.ecs_run_task.enabled ? 1 : 0
  name   = "ecs-run-analysis-task"
  role   = aws_iam_role.agent_host.id
  policy = data.aws_iam_policy_document.ecs_run_task[0].json
}
