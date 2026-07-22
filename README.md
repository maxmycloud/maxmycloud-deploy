# maxmycloud-deploy

Everything you need to install **MaxMyCloud** — a Snowflake FinOps platform — into your own AWS account. This repo contains no product source code; only what a customer engineer needs to install and operate the app inside your tenants.

## Start here

**[`deployment/aws/customer/INSTALL_GUIDE.md`](deployment/aws/customer/INSTALL_GUIDE.md)** — end-to-end walkthrough covering both the Snowflake side (Native App, OAuth Security Integration) and the AWS side (Terraform, container image, first-account bootstrap). Read this first.

## Contents

| Path | What |
|---|---|
| [`deployment/aws/customer/INSTALL_GUIDE.md`](deployment/aws/customer/INSTALL_GUIDE.md) | Customer install walkthrough (Snowflake + AWS + bootstrap) |
| [`deployment/aws/customer/architecture.svg`](deployment/aws/customer/architecture.svg) | Architecture diagram embedded in the install guide |
| [`deployment/aws/customer/DEPLOY.md`](deployment/aws/customer/DEPLOY.md) | AWS Terraform reference — variable catalog, HTTPS options, cost baseline, troubleshooting |
| [`deployment/aws/customer/*.tf`](deployment/aws/customer/) | Terraform module (VPC, ECS Fargate, DocumentDB, EFS, ALB, IAM) |
| [`Dockerfile`](Dockerfile) | For customers who prefer building the container image from source rather than pulling the pre-built image |

## Container images

Pre-built images are published to GitHub Container Registry — anonymous pull, no authentication:

```
ghcr.io/maxmycloud/maxmycloud-ui:<version>
```

Release tags here move in lockstep with image tags. Latest release is listed at [Releases](../../releases).

## Support

Reach out any time — install questions, feature requests, or anything else:

- `support@maxmycloud.com` — onboarding, operations, general questions
- `richard.yan@maxmycloud.com` — enterprise escalations

## Relationship to the source repo

The MaxMyCloud application source lives in a separate private repo. This deploy repo mirrors only the customer-facing subset so you never need access to source to install or operate the app.
