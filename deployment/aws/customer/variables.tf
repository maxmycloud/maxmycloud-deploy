# ─── Where + who ─────────────────────────────────────────────────────
variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "AWS CLI profile (leave empty when running via ECS task role / OIDC)."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Resource-name prefix. Kept short (<=16 chars) - ALBs and target groups have length limits."
  type        = string
  default     = "maxmycloud"
  validation {
    condition     = length(var.name_prefix) <= 16
    error_message = "name_prefix must be 16 characters or fewer."
  }
}

variable "extra_tags" {
  description = "Extra tags merged into every resource's default tags. Useful for cost-center / owner tagging."
  type        = map(string)
  default     = {}
}

# ─── Networking ──────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR for the VPC. Pick a range that doesn't overlap with the customer's on-prem or peered VPCs."
  type        = string
  default     = "10.60.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "One per AZ. Used for the ALB + NAT gateway."
  type        = list(string)
  default     = ["10.60.1.0/24", "10.60.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "One per AZ. Used for ECS tasks + DocumentDB + EFS mount targets."
  type        = list(string)
  default     = ["10.60.11.0/24", "10.60.12.0/24"]
}

# ─── Ingress / DNS ────────────────────────────────────────────────────
variable "fqdn" {
  description = "Hostname the ALB will serve (e.g. maxmycloud.internal.acme.com). Leave empty to skip cert + DNS and serve via the raw ALB DNS with HTTP only."
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "Existing ACM cert ARN in this region matching var.fqdn. If empty AND var.fqdn is set, Terraform issues a DNS-validated cert against var.route53_zone_id."
  type        = string
  default     = ""
}

variable "use_self_signed_cert" {
  description = "POC / evaluation only. When true (and no other cert source is set), Terraform generates a self-signed cert + imports to ACM so the ALB can serve HTTPS. Browsers show a 'Not Secure' warning but the app + all cookies work correctly. For real deploys, use fqdn+route53_zone_id or acm_certificate_arn instead."
  type        = bool
  default     = false
}

variable "route53_zone_id" {
  description = "Route53 hosted zone that owns var.fqdn. Used for both DNS-validated ACM issuance and the ALB A-record. Leave empty if the customer manages DNS externally."
  type        = string
  default     = ""
}

# ─── DocumentDB ──────────────────────────────────────────────────────
variable "docdb_instance_class" {
  description = "DocumentDB instance size. Defaults to the cheapest option (~$60/mo)."
  type        = string
  default     = "db.t3.medium"
}

variable "docdb_instance_count" {
  description = "Number of DocumentDB instances. 1 = single-node (cheapest, no HA). 2+ = HA across AZs."
  type        = number
  default     = 1
}

variable "docdb_deletion_protection" {
  description = "Prevent accidental terraform destroy. Set true for production; false for scratch."
  type        = bool
  default     = true
}

# ─── App / ECS ────────────────────────────────────────────────────────
variable "container_image" {
  description = "Full image URI including tag. Publish to the ECR repo this module creates (see outputs.ecr_repository_url) and put its :tag here."
  type        = string
}

variable "task_cpu" {
  description = "Fargate task CPU units. 512 = 0.5 vCPU."
  type        = number
  default     = 1024
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 2048
}

variable "task_desired_count" {
  description = "How many ECS tasks to run. 2+ for HA behind the ALB."
  type        = number
  default     = 2
}

# ─── LLM (Bedrock) ────────────────────────────────────────────────────
variable "bedrock_model_main" {
  description = "MODEL_MAIN inference-profile ID. Empty = don't grant Bedrock access at all."
  type        = string
  default     = "us.amazon.nova-pro-v1:0"
}

variable "bedrock_model_fast" {
  description = "MODEL_FAST inference-profile ID."
  type        = string
  default     = "us.amazon.nova-lite-v1:0"
}

# ─── Secrets ──────────────────────────────────────────────────────────
# Every entry becomes a Secrets Manager secret (with the value stored) AND
# a container env-var reference so ECS injects it at task start. Customer
# populates the actual secret values via CLI/Console after apply (Terraform
# only writes empty placeholders so the values never sit in state).
variable "app_secrets" {
  description = "Secret env vars to provision as empty Secrets Manager entries. Customer fills in real values post-apply via `aws secretsmanager update-secret`."
  type        = list(string)
  # NOTE: NUXT_MONGODB_URI is NOT listed here — the module auto-generates it
  # from the DocDB cluster output (see data.tf `aws_secretsmanager_secret.mongodb_uri`).
  # Listing it twice makes ECS reject the task def with "Duplicate secret names".
  # Only what the customer-tenant single-tenant SSO deploy actually needs.
  # Pruned from prior versions after auditing code for actual reads:
  #   * OpenAI keys (LLM traffic goes through Bedrock)
  #   * SES SMTP password (v0.3.2 switched to IAM task role)
  #   * Teams app password (Teams bot requires MaxMyCloud-hosted Azure Bot,
  #     doesn't fit customer-tenant)
  #   * bare JWT_SECRET (all code uses useRuntimeConfig().jwtSecret)
  #   * NUXT_SNOWFLAKE_ACCOUNT_KEY (zero code references anywhere;
  #     leftover from a prod-Azure feature that never landed)
  default = [
    "NUXT_JWT_SECRET",
    "NUXT_MFA_SECRET_KEY",
    # Bare env var the app reads directly via process.env — name case matters.
    "passwordEncryptionKey",        # AES-256-CBC for Snowflake keypair/password decrypt
  ]
}

# Non-secret env - merged into the ECS task definition environment block.
variable "app_env" {
  description = "Non-secret env vars passed to the container."
  type        = map(string)
  # RECOMMEND_API_URL deliberately NOT set: the recommendation engine
  # has been ported to JS (server/utils/recommend/*), and the endpoint
  # falls through to the local port when the env is unset — keeping ALL
  # data + inference inside the customer's AWS. Setting this env would
  # cause a phone-home to whatever URL you point it at (breaks the
  # customer-tenant promise).
  default = {
    NUXT_LLM_PROVIDER   = "bedrock"
    NUXT_BEDROCK_REGION = ""   # blank = use the deploy region
  }
}

variable "bastion_enabled" {
  description = "Provision a temporary EC2 bastion in the public subnet for one-shot ops (mongorestore, ad-hoc DocDB queries). Off by default — customers don't need this in normal operation. Flip true + apply only when MaxMyCloud support asks you to for debugging."
  type        = bool
  default     = false
}

variable "bastion_ingress_cidr" {
  description = "CIDR for the temp bastion SSH ingress. Populate with <your-ip>/32 only when bastion_enabled = true."
  type        = string
  default     = "0.0.0.0/32"
}

# --- Recommendation engine (opt-in co-deploy, see recommend.tf) ------------
variable "recommend_enabled" {
  description = "Co-deploy the recommendation engine as a second ECS service inside this VPC. When false, the app runs without recommendations (UI hides the section). Turn this on ONCE the customer's Docker image for the recommendation engine is pushed to the ECR repo this module creates."
  type        = bool
  default     = false
}

variable "recommend_container_image" {
  description = "Full image URI for the recommendation engine, e.g. <account>.dkr.ecr.<region>.amazonaws.com/mmc-*-recommend-*:v0.1.0. Ignored when recommend_enabled=false."
  type        = string
  default     = "public.ecr.aws/nginx/nginx:stable-alpine"
}

variable "recommend_container_port" {
  description = "Port the recommendation engine listens on inside the container."
  type        = number
  default     = 8080
}

variable "recommend_task_cpu" {
  description = "Fargate CPU units for the recommend task."
  type        = number
  default     = 512
}

variable "recommend_task_memory" {
  description = "Fargate memory (MiB) for the recommend task."
  type        = number
  default     = 1024
}

variable "recommend_desired_count" {
  description = "Number of recommend tasks. 2+ for HA."
  type        = number
  default     = 1
}

# ─── Customer-tenant identity + support access ─────────────────────────
variable "tenant_client_id" {
  description = "Single-tenant clientID baked into the deploy. Set this so login.vue skips the *.maxmycloud.com subdomain routing that only makes sense on multi-tenant SaaS. Must match the id of a doc in the clients Mongo collection."
  type        = string
  default     = ""
}

variable "tenant_display_name" {
  description = "Human-readable customer name for the login screen (e.g. \"Acme Corp\"). Shown to end users."
  type        = string
  default     = ""
}

variable "email_from_address" {
  description = "Sender identity for all outbound email. Must be a verified identity in the customer's SES account. Empty preserves the historical prod-Azure default (\"MaxMyCloud Support <contact@maxmycloud.com>\") which will only work if that identity is verified in this account."
  type        = string
  default     = ""
}

variable "support_admins" {
  description = "Vendor support access whitelist. Defaulted so day-0 works out of the box; override to rotate."
  type        = list(string)
  default     = ["support@maxmycloud.com"]
}

variable "public_app_url" {
  description = "Base URL customers reach the app at (e.g. https://finops.yourco.example). Used to construct the magic-link URL in outbound support emails. If empty, the request Host header is used."
  type        = string
  default     = ""
}

# ─── AI kill-switch ─────────────────────────────────────────────────────
variable "ai_features_disabled" {
  description = "Deployment-level AI kill-switch. When true, all LLM calls are blocked (isAIEnabled() returns false everywhere in the app) and AI UI is hidden. Recommended default for initial installs so the customer can validate + security-review before enabling Bedrock traffic."
  type        = bool
  default     = true
}
