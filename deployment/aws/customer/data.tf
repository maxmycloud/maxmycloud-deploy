# Persistent state resources:
#   • DocumentDB 5.0 cluster (Mongo API-compatible) in private subnets
#   • EFS for the app's snapshot dir (MAXMYCLOUD_REPLAY_DIR)
#   • Secrets Manager entries for every NUXT_* secret (empty on apply — the
#     customer fills real values via `aws secretsmanager update-secret`, so
#     no secret material ever sits in Terraform state)

# ─── DocumentDB ──────────────────────────────────────────────────────
resource "aws_security_group" "docdb" {
  name        = "${local.name}-docdb"
  description = "DocumentDB - accepts traffic from ECS tasks only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "MongoDB port from ECS tasks"
    from_port       = 27017
    to_port         = 27017
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

resource "aws_docdb_subnet_group" "this" {
  name       = "${local.name}-docdb"
  subnet_ids = aws_subnet.private[*].id
}

resource "random_password" "docdb" {
  length  = 32
  special = false
}

resource "aws_docdb_cluster" "this" {
  cluster_identifier      = "${local.name}-docdb"
  engine                  = "docdb"
  engine_version          = "5.0.0"
  master_username         = "mmcadmin"
  master_password         = random_password.docdb.result
  db_subnet_group_name    = aws_docdb_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.docdb.id]
  storage_encrypted       = true
  backup_retention_period = 7
  deletion_protection     = var.docdb_deletion_protection
  # Skip final snapshot only if deletion_protection is also off — otherwise
  # a stray destroy on a protected cluster would be silently lossy on retry.
  skip_final_snapshot     = !var.docdb_deletion_protection
  apply_immediately       = true
}

resource "aws_docdb_cluster_instance" "this" {
  count              = var.docdb_instance_count
  identifier         = "${local.name}-docdb-${count.index}"
  cluster_identifier = aws_docdb_cluster.this.id
  instance_class     = var.docdb_instance_class
  apply_immediately  = true
}

# Store the assembled Mongo URI (including password) in Secrets Manager so
# the ECS task role can pull it — Terraform state has the password, but the
# container never sees it in plaintext env, only via a Secrets Manager
# reference in the task definition (see compute.tf task_definition `secrets`).
resource "aws_secretsmanager_secret" "mongodb_uri" {
  name                    = "${local.name}/mongodb-uri-${local.short}"
  description             = "DocumentDB connection URI. Populated by Terraform from cluster outputs."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "mongodb_uri" {
  secret_id     = aws_secretsmanager_secret.mongodb_uri.id
  secret_string = "mongodb://mmcadmin:${random_password.docdb.result}@${aws_docdb_cluster.this.endpoint}:${aws_docdb_cluster.this.port}/?tls=true&retryWrites=false&readPreference=secondaryPreferred"
}

# ─── EFS (snapshot dir) ─────────────────────────────────────────────
resource "aws_security_group" "efs" {
  name        = "${local.name}-efs"
  description = "EFS mount targets - accept NFS from ECS tasks only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "NFS from ECS tasks"
    from_port       = 2049
    to_port         = 2049
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

resource "aws_efs_file_system" "snapshots" {
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  tags             = { Name = "${local.name}-snapshots" }
}

resource "aws_efs_mount_target" "snapshots" {
  count           = 2
  file_system_id  = aws_efs_file_system.snapshots.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "snapshots" {
  file_system_id = aws_efs_file_system.snapshots.id
  posix_user {
    uid = 1000
    gid = 1000
  }
  root_directory {
    path = "/snapshots"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }
}

# ─── Secrets Manager placeholders for var.app_secrets ────────────────
resource "aws_secretsmanager_secret" "app" {
  for_each                = toset(var.app_secrets)
  name                    = "${local.name}/${lower(each.key)}-${local.short}"
  # Description ages well — accurate whether the value is currently
  # populated or not. Rotate via `aws secretsmanager put-secret-value`.
  description             = "Application secret ${each.key} — random 32-byte value expected. Injected into the ECS task container env at boot."
  recovery_window_in_days = 0
}

# Intentionally NOT writing an initial secret_string — customer populates.
# The task will fail to start if the secret is unset, which is the desired
# behavior: no accidental launches against stale placeholders.
