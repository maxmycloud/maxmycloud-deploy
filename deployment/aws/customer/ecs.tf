# ECS Fargate — cluster, task definition, service. Also the ECR repo the
# customer publishes container images to.

# ─── ECR repo ────────────────────────────────────────────────────────
resource "aws_ecr_repository" "app" {
  name                 = "${local.name}-app-${local.short}"
  image_tag_mutability = "IMMUTABLE"
  # Allow `terraform destroy` to remove the repo even when it still has
  # image layers. Without this, tear-down leaves an orphaned ECR
  # repository the customer would have to delete by hand.
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images; delete older."
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ─── CloudWatch log group ────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}-app"
  retention_in_days = 30
}

# ─── ECS cluster ─────────────────────────────────────────────────────
resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ─── Task definition ─────────────────────────────────────────────────
locals {
  # RECOMMEND_API_URL: if the recommendation engine is co-deployed in this
  # module (recommend_enabled=true), point at its private Cloud Map DNS name
  # so traffic stays inside the VPC. Otherwise, fall through to whatever
  # var.app_env sets (customer may point at their own URL, or leave unset —
  # the /api/snowflake/recommend endpoint degrades gracefully when unset).
  recommend_internal_url = var.recommend_enabled ? "http://recommend.${local.name}.local:${var.recommend_container_port}" : ""

  # Static env from var.app_env plus derived ones (region -> BEDROCK_REGION).
  # Note: MONGODB_DB is passed as plain env (not a secret) - it's the db name,
  # not a credential. Nuxt runtime-config only auto-reads NUXT_-prefixed vars,
  # but MONGODB_URI / MONGODB_DB are read via process.env directly by the
  # mongo helpers, so they work fine as bare env vars.
  static_env = merge(var.app_env, {
    NUXT_BEDROCK_REGION    = var.app_env["NUXT_BEDROCK_REGION"] != "" ? var.app_env["NUXT_BEDROCK_REGION"] : var.region
    NUXT_BEDROCK_MODEL_MAIN = var.bedrock_model_main
    NUXT_BEDROCK_MODEL_FAST = var.bedrock_model_fast
    MONGODB_DB              = "maxapp"
    HOST                    = "0.0.0.0"
    PORT                    = "3000"
    NODE_ENV                = "production"
    # In-process heartbeat that polls Mongo for due health-check subscriptions.
    # Disabled by default in server/plugins/healthCheckScheduler.ts; must be
    # explicitly enabled for the scheduled-email feature to fire.
    HEALTHCHECK_SCHEDULER_ENABLED = "true"
    # Deployment-level AI kill-switch. When "true", isAIEnabled() returns
    # false everywhere → no Bedrock calls, AI UI hidden, health check falls
    # back to rule-based summaries. Default true so fresh installs are
    # LLM-free until the customer completes their security review.
    NUXT_AI_FEATURES_DISABLED = tostring(var.ai_features_disabled)
    # Single-tenant SSO binding — login.vue skips subdomain-hash routing when set.
    NUXT_PUBLIC_TENANT_CLIENT_ID    = var.tenant_client_id
    NUXT_PUBLIC_TENANT_DISPLAY_NAME = var.tenant_display_name
    # Sender identity for all outbound email — must be a verified identity in
    # this account's SES. sendEmail.ts falls back to the prod-Azure hardcode
    # if unset (which will fail SES if the identity isn't verified here).
    NUXT_EMAIL_FROM_ADDRESS = var.email_from_address
    # Support-admin magic link — comma-separated whitelist re-checked on
    # every request and every token consumption. Empty disables the feature.
    NUXT_SUPPORT_ADMINS = join(",", var.support_admins)
    # Base URL used to build the magic-link URL in support emails. Empty
    # falls back to the request Host header (works for the raw ALB DNS).
    NUXT_PUBLIC_APP_URL = var.public_app_url
  }, local.recommend_internal_url != "" ? { RECOMMEND_API_URL = local.recommend_internal_url } : {})

  # Secrets: MongoDB URI (Terraform-generated) + everything in var.app_secrets.
  # MONGODB_URI is bare (no NUXT_ prefix) because server/utils/mongo.ts and
  # server/utils/databases/snowflakeReal.js both read process.env.MONGODB_URI
  # directly, not via Nuxt runtime config.
  container_secrets = concat(
    [{
      name      = "MONGODB_URI"
      valueFrom = aws_secretsmanager_secret.mongodb_uri.arn
    }],
    [for k, s in aws_secretsmanager_secret.app : {
      name      = k
      valueFrom = s.arn
    }]
  )
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name}-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  volume {
    name = "snapshots"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.snapshots.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.snapshots.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = var.container_image
    essential = true
    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]
    environment = [for k, v in local.static_env : { name = k, value = v }]
    secrets     = local.container_secrets
    mountPoints = [{
      sourceVolume  = "snapshots"
      containerPath = "/mnt/data/snapshots"
      readOnly      = false
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }
    healthCheck = {
      command     = ["CMD-SHELL", "node -e \"require('http').get('http://127.0.0.1:3000/', r => process.exit(r.statusCode < 500 ? 0 : 1)).on('error', () => process.exit(1))\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])
}

# ─── ECS service ─────────────────────────────────────────────────────
resource "aws_ecs_service" "app" {
  name                   = "${local.name}-app"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.app.arn
  desired_count          = var.task_desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true              # allows `aws ecs execute-command` (Session-Manager style shell) for debugging
  wait_for_steady_state  = false

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false                 # tasks reach out via NAT gateway
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 3000
  }

  # Rolling deploys: 100% healthy, 200% max — one green task at a time.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy.task_execution_secrets,
  ]
}
