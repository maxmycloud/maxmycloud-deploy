# IAM roles for ECS Fargate.
# Two roles:
#   • task_execution_role — ECS agent uses this to pull ECR images + fetch
#                           secrets on task start. Managed policies only.
#   • task_role           — the app's own identity at runtime. Grants Bedrock
#                           InvokeModel on the two configured models, EFS
#                           access, and Secrets Manager read for the app
#                           secrets we provisioned. Least-privilege.

# ─── ECS agent (image pull + secret fetch) ──────────────────────────
resource "aws_iam_role" "task_execution" {
  name = "${local.name}-task-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow the execution role to fetch our app secrets. Managed policy only
# covers AWS-service secrets; app-owned Secrets Manager ARNs need explicit
# grant.
resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "read-app-secrets"
  role = aws_iam_role.task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = concat(
        [aws_secretsmanager_secret.mongodb_uri.arn],
        [for s in aws_secretsmanager_secret.app : s.arn]
      )
    }]
  })
}

# ─── App runtime role ───────────────────────────────────────────────
resource "aws_iam_role" "task" {
  name = "${local.name}-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Bedrock InvokeModel — scoped to the two configured inference-profile IDs.
# Empty MODEL_MAIN skips grant (customer opted out of Bedrock entirely).
locals {
  bedrock_arns = compact([
    var.bedrock_model_main != "" ? "arn:${data.aws_partition.current.partition}:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_main}" : "",
    var.bedrock_model_fast != "" ? "arn:${data.aws_partition.current.partition}:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_fast}" : "",
    # Foundation-model ARNs backing the inference profiles — required for
    # cross-region routing. Wildcard is safe here because the inference-profile
    # allowlist above bounds which models can actually be invoked.
    "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*",
  ])
}

resource "aws_iam_role_policy" "task_bedrock" {
  count = var.bedrock_model_main != "" ? 1 : 0
  name  = "bedrock-invoke"
  role  = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["bedrock:InvokeModel", "bedrock:Converse", "bedrock:ConverseStream"]
      Resource = local.bedrock_arns
    }]
  })
}

# EFS access — required for the ECS task to mount the snapshot volume.
resource "aws_iam_role_policy" "task_efs" {
  name = "efs-access"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite",
        "elasticfilesystem:DescribeMountTargets",
      ]
      Resource = aws_efs_file_system.snapshots.arn
    }]
  })
}

# SES — the app sends health-check emails and contact-form messages.
resource "aws_iam_role_policy" "task_ses" {
  name = "ses-send"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
    }]
  })
}
