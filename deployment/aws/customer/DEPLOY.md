# AWS Terraform Reference

Technical reference for the AWS-side of the MaxMyCloud customer-tenant deploy. Covers the Terraform module's resources, variable catalog, cost baseline, HTTPS options, and troubleshooting.

**For the end-to-end customer install walkthrough** (Snowflake side, AWS side, first-account bootstrap), start with [`INSTALL_GUIDE.md`](./INSTALL_GUIDE.md). This document assumes you're already familiar with the overall flow and want the mechanical details.

---

## Module resources

What `terraform apply` provisions in your AWS account:

| Layer   | Resources                                                           |
|---------|---------------------------------------------------------------------|
| Network | VPC (2 AZs), public + private subnets, IGW, one NAT gateway         |
| Data    | DocumentDB 5.0 cluster + instance(s), EFS (encrypted), Secrets Manager entries |
| Compute | ECS Fargate cluster + service, CloudWatch log group, ECR repository |
| Ingress | ALB (HTTPS required — three cert paths, see below), Route 53 records (if you use Path A) |
| IAM     | Least-privilege task role: `bedrock:InvokeModel`, `ses:SendEmail`, EFS mount, Secrets read |

**Runtime egress from the app** is limited to: your Snowflake account (HTTPS queries), your recipients' mail servers (SES SMTP handoff), Bedrock inference endpoint (`bedrock-runtime.<region>.amazonaws.com`) when AI is on, and OS/language package updates on task boot (ECR image pulls). Nothing calls MaxMyCloud at runtime.

---

## Cost baseline (idle, no traffic)

| Resource                       | Rough $/mo    |
|--------------------------------|--------------:|
| DocumentDB `db.t3.medium` × 1  | ~$60          |
| ECS Fargate 1 vCPU × 2 tasks   | ~$60          |
| NAT gateway (single AZ)        | ~$32          |
| ALB                            | ~$18          |
| EFS (near-zero used bytes)     | ~$0.30        |
| CloudWatch logs (30d)          | ~$1           |
| **Total**                      | **~$170/mo**  |

Add ~$0.05/GB egress + Bedrock invoke usage on top when AI is enabled.

---

## Variable catalog

Full definitions with defaults live in [`variables.tf`](./variables.tf). The ones you'll typically set:

| Variable                | Notes                                                                                     |
|-------------------------|-------------------------------------------------------------------------------------------|
| `region`                | AWS region — pick one with SES + Bedrock support in your account                          |
| `name_prefix`           | ≤16-char prefix for all resource names (ALB name limit)                                   |
| `container_image`       | Full image URI in your ECR. On first apply, leave as the default placeholder; update after Step 2.5 in INSTALL_GUIDE |
| `ai_features_disabled`  | `true` for initial install (default). Flip to `false` after security review               |
| `bedrock_model_main`    | Only used when AI is on. Default `us.amazon.nova-pro-v1:0` (see model catalog below)      |
| `bedrock_model_fast`    | Only used when AI is on. Default `us.amazon.nova-lite-v1:0`                               |
| `email_from_address`    | `"Your Company FinOps <finops@yourcompany.com>"` — verified sender in your SES            |
| `tenant_client_id`      | Short DNS-safe slug (e.g. `"acme"`); becomes the primary key of your `clients` record. Don't change after install |
| `tenant_display_name`   | Free-form human-readable name shown on the login screen (e.g. `"Acme Corp"`)              |
| `fqdn` + `route53_zone_id` | Your hostname + Route 53 zone id (Path A below)                                        |
| `acm_certificate_arn`   | Alternative to `route53_zone_id` — bring-your-own ACM cert (Path B below)                 |
| `support_admins`        | Comma-separated allow-list of `@maxmycloud.com` emails for MaxMyCloud support access      |
| `task_desired_count`    | ECS task count; bump from `2` to scale UI capacity                                        |
| `docdb_instance_count`  | Bump from `1` to `2` for HA DocumentDB across AZs (~2× DocDB cost)                        |

Everything else in `variables.tf` has sensible defaults for a single-tenant enterprise install.

---

## IAM identity for Terraform

Terraform needs AWS credentials on your local machine before you can `apply`. Two supported patterns:

### Option A — IAM user with access keys (fastest to bootstrap)

1. IAM Console → Users → your user → Security credentials → Create access key → CLI use case.
2. On your workstation:
   ```bash
   aws configure
   # AWS Access Key ID [None]: AKIA...
   # AWS Secret Access Key [None]: ...
   # Default region name: us-east-1
   ```
3. Verify: `aws sts get-caller-identity` should print your account ID.

### Option B — AWS SSO / IAM Identity Center (preferred at enterprise)

```bash
aws configure sso
# SSO start URL: https://<yourcompany>.awsapps.com/start
# ...browser auth flow...
# CLI profile name: my-company-admin
export AWS_PROFILE=my-company-admin
aws sts get-caller-identity
```

For SSO, either `export AWS_PROFILE=...` in the shell before running Terraform, or add `profile = "my-company-admin"` to your tfvars.

### Minimum IAM policies (if scoping from day 1)

Skip if using `AdministratorAccess` for the initial install:

```
AmazonEC2FullAccess, AmazonECS_FullAccess, AmazonECRFullAccess,
AmazonRDSFullAccess (covers DocumentDB), AmazonSSMFullAccess,
AmazonElasticFileSystemFullAccess, ElasticLoadBalancingFullAccess,
IAMFullAccess, SecretsManagerReadWrite, CloudWatchLogsFullAccess,
AmazonRoute53FullAccess (only if using Path A below for HTTPS)
```

---

## HTTPS — three certificate paths

HTTPS is not optional; session cookies are Secure-only and an HTTP-only deploy will not let users log in. Pick one of:

### Path A — Route 53 hosted zone (recommended)

If your domain (or a subdomain you'll use) is in Route 53, Terraform issues a DNS-validated ACM cert, creates the CNAME to the ALB, and wires it all up.

```hcl
# terraform.tfvars
fqdn            = "maxmycloud.internal.acme.com"
route53_zone_id = "Z0123456ABCDEFGHIJ"
```

After apply, users hit `https://maxmycloud.internal.acme.com` with a green-lock browser experience.

### Path B — DNS outside AWS (Cloudflare, GoDaddy, on-prem, etc.)

Provision an ACM cert yourself in the deploy region:

1. ACM Console → Request certificate → your hostname.
2. Follow DNS validation (add the CNAME record shown to your DNS provider).
3. Wait for status: Issued.
4. Copy the ACM cert ARN, then:
   ```hcl
   # terraform.tfvars
   acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abcd..."
   ```
5. After `terraform apply`, get the ALB DNS from `terraform output -raw alb_dns_name` and CNAME your hostname at it in your DNS provider.

### Path C — self-signed (short POCs only, not recommended)

For internal evaluation with no domain lined up:

```hcl
use_self_signed_cert = true
```

Browsers show "Not Secure" — not appropriate for real users. Migrate to Path A or B before onboarding anyone beyond the evaluation team.

---

## Amazon SES setup

MaxMyCloud sends outbound email (health-check reports, notifications) via SES in your account.

- **Verified sender identity** in the deploy region — either a verified domain (recommended) or a single verified email address. SES Console → Verified identities → Create identity.
- **SES production access** (out of sandbox mode). SES Console → Account dashboard → Request production access if needed. AWS approves in hours to 24h.
- Pass the sender identity as `email_from_address` in tfvars.

---

## Bedrock model catalog

When `ai_features_disabled = false`, the app calls Bedrock in your account. Enable model access in **Bedrock Console → Model access** first.

| Priority              | `main` (reasoning)                                | `fast` (classifiers)         | ~$/M tokens (in/out)      | Access                     |
|-----------------------|---------------------------------------------------|------------------------------|---------------------------|----------------------------|
| **Balanced (default)** | `us.amazon.nova-pro-v1:0`                        | `us.amazon.nova-lite-v1:0`   | 0.80/3.20 · 0.06/0.24     | Instant, no approval       |
| Cost-optimized        | `us.amazon.nova-lite-v1:0`                        | `us.amazon.nova-lite-v1:0`   | 0.06/0.24 · same          | Instant                    |
| Quality-optimized     | `us.anthropic.claude-sonnet-4-5-20250929-v1:0`    | `us.amazon.nova-lite-v1:0`   | 3.00/15.00 · 0.06/0.24    | Anthropic use-case form    |

Any Bedrock inference-profile ID your account has access to works — pass whatever's approved.

Bedrock isn't in every region — `us-east-1`, `us-east-2`, and `us-west-2` have full model catalogs.

---

## Ongoing operations

### Rotating the support-admin allow-list

Edit `support_admins` in tfvars and `terraform apply`. Removed emails lose access on the next ECS task-def revision (typically within seconds).

### Rotating a Secrets Manager value

```bash
aws secretsmanager put-secret-value \
  --secret-id <secret-arn> \
  --secret-string "$(openssl rand -base64 32)"
```

The ECS task picks up the new value on next boot. For zero-downtime rotation, force a service redeploy after updating the secret:

```bash
aws ecs update-service --cluster <cluster> --service <service> --force-new-deployment
```

### Scaling

Defaults (`task_desired_count = 2`, `task_cpu = 1024`, `task_memory = 2048`, `docdb_instance_count = 1`) fit a single-customer deploy with dozens of users comfortably. If your user count grows into the hundreds or scheduled health-check workload gets heavy:

- Bump `task_desired_count` for more UI capacity.
- Set `docdb_instance_count = 2` for HA DocumentDB across AZs.
- Bump `task_cpu` / `task_memory` if individual tasks are CPU/RAM-bound (rare).

`terraform apply` — no downtime.

### Teardown

If you set `docdb_deletion_protection = true` (default), flip it first:

```bash
# edit terraform.tfvars → docdb_deletion_protection = false
terraform apply
terraform destroy
```

Removes everything cleanly. All state lives in your account, so nothing persists elsewhere.

---

## Troubleshooting

**ECS tasks crash-looping** — check the CloudWatch log group `/ecs/<name_prefix>-app`. Common causes:

- Secrets not populated (`NUXT_JWT_SECRET`, `passwordEncryptionKey`, `NUXT_MFA_SECRET_KEY`) — see INSTALL_GUIDE § 2.4.
- Bedrock model access not enabled in the deploy region (only matters when `ai_features_disabled = false`).
- `email_from_address` identity not verified in SES.

**Login page shows "No Snowflake SSO accounts found"** — the first Snowflake connection hasn't been registered yet. MaxMyCloud handles this bootstrap; see INSTALL_GUIDE Part 3.

**Health-check email doesn't arrive** — check:

- SES is out of sandbox mode.
- `email_from_address` identity is verified.
- Recipient isn't in the SES suppression list (SES Console → Suppression list).
- CloudWatch log shows `[hc-scheduler] tick: ... sent:1` — proves the scheduler ran and SES accepted the send.

**Task can't reach DocumentDB** — DocumentDB is in the private subnets; the task must have the DocumentDB security group attached. Terraform wires this correctly by default; only breaks if you customized `network.tf`.

**Terraform apply fails on cert issuance** — Route 53 validation records can take several minutes to propagate. Retry after 5 minutes. If it still fails, verify the `route53_zone_id` actually owns the `fqdn` you set.

For anything not covered above, email `support@maxmycloud.com` with your ALB URL and the CloudWatch log excerpt.
