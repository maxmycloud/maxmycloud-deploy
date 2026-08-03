# MaxMyCloud — customer-tenant AWS deployment module.
#
# Provisions a full stack in a customer's own AWS account:
#   • VPC + 2 AZ subnets (public + private)
#   • DocumentDB 5.0 cluster in private subnets
#   • EFS for the snapshot dir (MAXMYCLOUD_REPLAY_DIR)
#   • ECR repo for our container image
#   • ECS Fargate service behind an ALB
#   • IAM: task role with Bedrock InvokeModel + Secrets Manager read
#   • Secrets Manager entries for every NUXT_* secret
#
# See README.md for the full apply flow, IAM prereqs, and how to publish
# container image versions to the ECR repo.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    tls    = { source = "hashicorp/tls",    version = "~> 4.0" }   # self-signed cert + bastion key
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
  default_tags {
    tags = merge({
      Project   = "maxmycloud"
      ManagedBy = "terraform"
      Module    = "customer"
    }, var.extra_tags)
  }
}

data "aws_availability_zones" "az" { state = "available" }
data "aws_caller_identity" "current" {}
data "aws_partition"      "current" {}

locals {
  name    = var.name_prefix
  # Short slug (5 chars) appended to globally-unique names (ECR repo, S3-like)
  # so multiple environments in the same account don't collide.
  short   = substr(random_id.suffix.hex, 0, 5)
  fqdn    = var.fqdn                              # e.g. "maxmycloud.internal.acme.com" or empty
}

resource "random_id" "suffix" {
  byte_length = 4
}
