output "alb_dns_name" {
  description = "ALB DNS. If you didn't set var.fqdn + var.route53_zone_id, hit this directly."
  value       = aws_lb.this.dns_name
}

output "app_url" {
  description = "URL to hit the app. HTTPS when a cert is available, HTTP otherwise (dev only)."
  value = local.https_enabled ? (
    var.fqdn != "" ? "https://${var.fqdn}" : "https://${aws_lb.this.dns_name}"
  ) : "http://${aws_lb.this.dns_name}"
}

output "ecr_repository_url" {
  description = "Push container images here - `docker push <this>:v1.0.0` etc. Then set var.container_image = \"<this>:v1.0.0\" and re-apply."
  value       = aws_ecr_repository.app.repository_url
}

output "recommend_ecr_repository_url" {
  description = "ECR repo for the co-deployed recommendation engine image. Null when recommend_enabled=false. Push a recommend engine image here, then set var.recommend_container_image to that URI + tag."
  value       = var.recommend_enabled ? aws_ecr_repository.recommend[0].repository_url : null
}

output "recommend_internal_dns" {
  description = "Private DNS the main app calls for recommendations. Null when recommend_enabled=false."
  value       = var.recommend_enabled ? "recommend.${local.name}.local:${var.recommend_container_port}" : null
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "cloudwatch_log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "docdb_endpoint" {
  description = "DocumentDB cluster writer endpoint. Reachable ONLY from within the VPC (private subnets)."
  value       = aws_docdb_cluster.this.endpoint
}

output "mongodb_uri_secret_arn" {
  description = "Secrets Manager ARN holding the assembled Mongo connection string. Injected into the container as NUXT_MONGODB_URI."
  value       = aws_secretsmanager_secret.mongodb_uri.arn
}

output "app_secret_arns" {
  description = "Empty placeholders - populate with `aws secretsmanager update-secret --secret-id <arn> --secret-string <value>` before the ECS tasks can start."
  value       = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
}

output "efs_file_system_id" {
  value = aws_efs_file_system.snapshots.id
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "region" {
  description = "AWS region this deploy is in. Convenient for shell scripts that need to pass --region to aws-cli invocations."
  value       = var.region
}
