# Optional co-deployed recommendation engine.
#
# For strict "runs entirely in customer's tenant" deploys, the recommendation
# engine (Python service originally hosted on Azure at api.maxmycloud.com)
# needs to live inside the customer's AWS. This file provisions a second ECS
# Fargate service + private DNS name (Cloud Map) so the main app calls it
# over VPC-internal traffic — nothing leaves the customer's account.
#
# Opt-in via var.recommend_enabled. If false, the whole block is a no-op and
# RECOMMEND_API_URL stays unset on the app task — the /api/snowflake/recommend
# endpoint returns { recommendations: [], unavailable: true } and the UI hides
# the section gracefully.
#
# The customer supplies the container image via var.recommend_container_image
# (their build of the recommendation-engine repo, pushed to the ECR repo this
# file creates). Until they do, tasks stay stopped (desired_count = 0).

# ─── ECR repo for the recommend image ────────────────────────────────
resource "aws_ecr_repository" "recommend" {
  count                = var.recommend_enabled ? 1 : 0
  name                 = "${local.name}-recommend-${local.short}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

# ─── Private DNS (Cloud Map) so the app can address the service by name ─
resource "aws_service_discovery_private_dns_namespace" "internal" {
  count       = var.recommend_enabled ? 1 : 0
  name        = "${local.name}.local"
  description = "Private DNS for in-VPC service-to-service traffic"
  vpc         = aws_vpc.this.id
}

resource "aws_service_discovery_service" "recommend" {
  count = var.recommend_enabled ? 1 : 0
  name  = "recommend"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal[0].id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config { failure_threshold = 1 }
}

# ─── Security group + task IAM ──────────────────────────────────────
resource "aws_security_group" "recommend" {
  count       = var.recommend_enabled ? 1 : 0
  name        = "${local.name}-recommend"
  description = "Recommend engine - accepts traffic from the app tasks only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "App-port from main app SG"
    from_port       = var.recommend_container_port
    to_port         = var.recommend_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.task.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "recommend_execution" {
  count = var.recommend_enabled ? 1 : 0
  name  = "${local.name}-recommend-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "recommend_execution_managed" {
  count      = var.recommend_enabled ? 1 : 0
  role       = aws_iam_role.recommend_execution[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "recommend_task" {
  count = var.recommend_enabled ? 1 : 0
  name  = "${local.name}-recommend-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ─── CloudWatch log group ───────────────────────────────────────────
resource "aws_cloudwatch_log_group" "recommend" {
  count             = var.recommend_enabled ? 1 : 0
  name              = "/ecs/${local.name}-recommend"
  retention_in_days = 30
}

# ─── Task definition + service ──────────────────────────────────────
resource "aws_ecs_task_definition" "recommend" {
  count                    = var.recommend_enabled ? 1 : 0
  family                   = "${local.name}-recommend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.recommend_task_cpu
  memory                   = var.recommend_task_memory
  execution_role_arn       = aws_iam_role.recommend_execution[0].arn
  task_role_arn            = aws_iam_role.recommend_task[0].arn

  container_definitions = jsonencode([{
    name      = "recommend"
    image     = var.recommend_container_image
    essential = true
    portMappings = [{
      containerPort = var.recommend_container_port
      protocol      = "tcp"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.recommend[0].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "recommend"
      }
    }
  }])
}

resource "aws_ecs_service" "recommend" {
  count           = var.recommend_enabled ? 1 : 0
  name            = "${local.name}-recommend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.recommend[0].arn
  desired_count   = var.recommend_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.recommend[0].id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.recommend[0].arn
  }
}
