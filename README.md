# maxmycloud-deploy

Everything you need to install **MaxMyCloud** — a Snowflake FinOps platform — into your own AWS and Snowflake tenants. This repo contains no product source code; only what a customer engineer needs to install and operate the app inside your tenants.

## Start here

Read **[`INSTALL_GUIDE.md`](INSTALL_GUIDE.md)** at the root of this repo. It's the single end-to-end walkthrough covering the Snowflake side (Native App, OAuth), the AWS side (container + supporting services), and the first-connection setup that ties the two together. Both paths — using our Terraform module or bringing your own IaC — are documented there.

That's the only doc most customers need to read up front. Everything else in this repo is either optional or referenced from the guide.

## What else is in this repo

| Path | When you need it |
|---|---|
| [`INSTALL_GUIDE.md`](INSTALL_GUIDE.md) | **Read first.** End-to-end install walkthrough. |
| [`docs/customer/install/MaxMyCloud_SecretsHandoff_Template.pdf`](docs/customer/install/MaxMyCloud_SecretsHandoff_Template.pdf) | Environment-variable template you populate in your secret store. Direct-download recommended over in-browser preview. |
| [`docs/customer/install/`](docs/customer/install/) | Other install references — cost estimate, deployment spec, standard/enterprise edition guides. |
| [`deployment/aws/customer/`](deployment/aws/customer/) | Terraform module (VPC, ECS Fargate, DocumentDB, EFS, ALB, IAM). Optional — use it, use it as reference, or ignore if you're bringing your own IaC. |
| [`deployment/aws/customer/DEPLOY.md`](deployment/aws/customer/DEPLOY.md) | Terraform variable catalog, HTTPS options, cost baseline, troubleshooting. Reference when you're deep in the Terraform. |
| [`Dockerfile`](Dockerfile) | If you'd rather build the container image from source than pull the pre-built one. Most customers pull the pre-built. |

## Container images

Pre-built images are published to GitHub Container Registry — public, anonymous pull:

```
ghcr.io/maxmycloud/maxmycloud-ui:<version>
```

Pin to a specific tag; do NOT use `:latest`. Every version is tagged at [Releases](../../releases). Subscribe to the tags atom feed for release notifications: `https://github.com/maxmycloud/maxmycloud-deploy/tags.atom`.

## Support

- `support@maxmycloud.com` — onboarding, operations, general questions
- `richard.yan@maxmycloud.com` — enterprise escalations

## About this repo

The MaxMyCloud application source lives in a separate private repo. This deploy repo mirrors only the customer-facing subset so you never need access to source to install or operate the app. Sync happens automatically on every prod release.
