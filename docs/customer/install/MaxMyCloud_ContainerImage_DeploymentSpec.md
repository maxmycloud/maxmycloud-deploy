# MaxMyCloud Container Image — Deployment Specification

For customers running MaxMyCloud in their own AWS (or other cloud) using their existing IaC (Terraform, CloudFormation, Kubernetes manifests, etc.). MaxMyCloud provides the container image + this spec; the customer's platform team deploys it.

Use this alongside the Enterprise Installation Guide (Snowflake side) — this document covers the AWS side.

---

## 1. Container image

**Image:** `ghcr.io/maxmycloud/maxmycloud-ui`

**Version pinning:** pin to a specific tag (e.g. `v0.3.18`). See [github.com/maxmycloud/maxmycloud-deploy/tags](https://github.com/maxmycloud/maxmycloud-deploy/tags) for the current list.

**Pulling to your registry** (recommended — decouples from ghcr availability):
```bash
docker pull ghcr.io/maxmycloud/maxmycloud-ui:<latest-tag>
docker tag  ghcr.io/maxmycloud/maxmycloud-ui:<latest-tag> <your-registry>/maxmycloud-ui:<latest-tag>
docker push <your-registry>/maxmycloud-ui:<latest-tag>
```

**Base:** Node 22 (Nuxt server). No OS-level customization required.

---

## 2. Compute sizing

Recommended defaults:

| Resource | Per replica | Notes |
|---|---|---|
| vCPU | 1 | 0.5 vCPU works under light load; 1 vCPU comfortable up to ~50 concurrent users |
| Memory | 2 GB | Includes Nuxt server + in-memory session store + Recommend logic (JS port, inlined) |
| Replicas | 2 | For HA behind a load balancer. Single replica is functional but no rolling deploys without downtime |
| Ephemeral storage | 1 GB | Container writes very little to local disk |

Fargate / ECS translations: `task_cpu = 1024`, `task_memory = 2048`, `desired_count = 2`.

---

## 3. Ports and health checks

| Port | Purpose |
|---|---|
| 3010 (default) | HTTP — the Nuxt web server. Configurable via `PORT` env var if you need a different port. |

**Health check endpoints** (both return 200 when the app is healthy):

| Path | Purpose |
|---|---|
| `GET /api/version` | Returns build metadata (commit SHA, branch, build time, image tag). Good for load balancer health checks. |
| `GET /api/health` | Cheap liveness probe. |

Load balancer health-check settings: `HTTP GET /api/version`, healthy threshold 2, unhealthy threshold 3, interval 30s, timeout 5s. Grace period at deploy time: 60 seconds (Node warm-up + first Mongo connection).

---

## 4. Session stickiness — important

MaxMyCloud stores active session state in the ECS task's memory (`server/utils/session.ts activeSessions Map`). **Configure sticky sessions on your load balancer** so a user's requests reliably land on the same replica, otherwise session validation may fail intermittently across the fleet.

For AWS ALB: enable target-group stickiness with duration ≥ 24 hours.

---

## 5. Environment variables

### 5.1 Required — the app will not start correctly without these

| Variable | Purpose | Example / notes |
|---|---|---|
| `MONGODB_URI` | Mongo-compatible connection string | AWS DocumentDB (`retryWrites=false` required), or MongoDB Atlas, or CosmosDB Mongo API |
| `MONGODB_DB` | Database name | e.g. `maxmycloud` |
| `NUXT_JWT_SECRET` | Session-token signing secret (rotate periodically) | 64+ random bytes, base64 |
| `NUXT_MFA_SECRET_KEY` | AES key for encrypting stored TOTP secrets | Exactly 32 bytes, base64 |
| `NUXT_PASSWORD_ENCRYPTION_KEY` | AES key for encrypting stored Snowflake credentials | Exactly 32 bytes, base64 |
| `NUXT_PUBLIC_APP_URL` | Externally-reachable URL of the deployment (the URL browsers use) | e.g. `https://maxmycloud.internal.customer.com` — used to build OAuth redirect URIs and links inside the app |
| `NUXT_PUBLIC_TENANT_CLIENT_ID` | Fixed tenant ID for this single-tenant install | Any stable string; used to key the customer's tenant in DocumentDB and to enable the "MaxMyCloud staff sign in" affordance on `/login` |
| `NUXT_PUBLIC_TENANT_DISPLAY_NAME` | Human-readable name for this install (e.g. company / project name) | Shown on the login screen and included in the TOTP MFA issuer label so authenticator apps distinguish this install from other MaxMyCloud installs the user is enrolled in. Recommended for any deployment. |

### 5.2 Bootstrap superadmin (for first-login) — **defaults baked into image; override only if needed**

Purpose: seed a single MaxMyCloud-support superadmin at container boot so SSO onboarding is possible when no user exists yet in DocumentDB. These have working defaults hardcoded in the image — customer doesn't need to touch them.

| Variable | Default (baked in) | Notes |
|---|---|---|
| `BOOTSTRAP_SUPERADMIN_ENABLED` | `true` | Set to `false` to disable seeding (e.g. after initial onboarding once the customer has their own admins) |
| `BOOTSTRAP_SUPERADMIN_EMAIL` | `support@maxmycloud.com` | Override only if you have a customer-specific policy on vendor email addresses |
| `BOOTSTRAP_SUPERADMIN_BCRYPT_HASH` | (baked into image) | Overrideable — MaxMyCloud may provide a per-install hash for higher-sensitivity deployments |

**Behavior:** on the first container start against an empty DocumentDB, the plugin creates one user record (`support@maxmycloud.com` / role `Superadmin` / the baked-in bcrypt hash) and grants superadmin. Idempotent — subsequent boots see the existing user and no-op. Never overwrites an existing user record.

**First-login procedure for the MaxMyCloud engineer:**
1. Reach the app URL via the customer-provided proxy.
2. Navigate to `/login?bypass=1`.
3. Click **MaxMyCloud staff sign in**.
4. Enter `support@maxmycloud.com` and the shared MaxMyCloud-support password (provided out-of-band).
5. Click **Sign in with password**.
6. Immediately prompted to enroll TOTP MFA — scan QR code in an authenticator app, enter the 6-digit code. TOTP secret is stored encrypted in *this install's* DocumentDB, unique to this deployment.
7. From that login forward, sign-in requires password + TOTP.

**Security model — read carefully:**
The shared password's security rests entirely on MFA. The bcrypt hash is baked into a public container image and is therefore *knowable*. What keeps an attacker out of a *specific* customer's deployment is the per-install TOTP secret — enrolled once, stored only in that install's DocumentDB, and required on every subsequent login. Do not weaken MFA enforcement or the security model collapses across all deployments.

### 5.3 Snowflake integration — required at runtime, configurable post-deploy

| Variable | Purpose |
|---|---|
| `NUXT_SNOWFLAKE_ACCOUNT` | Optional default account identifier — customers configure per-Snowflake-account credentials via the UI after signing in |

Snowflake credentials (per-account URL, warehouse, user, private key) are entered by the customer's tenant admin via **Settings → Accounts** in the UI, not via env vars. Persisted encrypted in DocumentDB using `NUXT_PASSWORD_ENCRYPTION_KEY`.

### 5.4 Optional — AI features (Amazon Bedrock)

**Default posture: AI OFF.** POC customers typically start without AI to first validate the core cost / warehouse / orchestration insights (all deterministic, non-AI code paths). AI can be turned on later without redeploying — flip the env vars below and roll a task restart.

**To keep AI OFF (deployment-wide kill switch):**

| Variable | Value | Purpose |
|---|---|---|
| `NUXT_AI_FEATURES_DISABLED` | `true` | Master kill switch. `/api/ai/access` returns `AI_DISABLED`, the useAIAccess composable propagates to every AI UI surface. Result: AI Chat nav item hides, in-page AI insight cards hide, health-check narratives skip, orchestration analysis skips the AI synthesis step. No Bedrock IAM permissions required on the task role. |

Setting `NUXT_LLM_PROVIDER=''` alone is NOT sufficient — it only affects which provider a call routes to, not whether AI features are considered available. Always use `NUXT_AI_FEATURES_DISABLED=true` for a true off-state.

**To turn AI ON** (later, optional):

| Variable | Purpose |
|---|---|
| `NUXT_AI_FEATURES_DISABLED` | Set to `false` (or unset) to un-gate AI UI |
| `NUXT_LLM_PROVIDER` | Set to `bedrock` to route calls to Amazon Bedrock |
| `NUXT_BEDROCK_MODEL_MAIN` | Bedrock inference-profile ID for main model. Recommended: `us.amazon.nova-pro-v1:0` |
| `NUXT_BEDROCK_MODEL_FAST` | Bedrock inference-profile ID for fast model. Recommended: `us.amazon.nova-lite-v1:0` |
| `AWS_REGION` | AWS region for Bedrock calls |

Bedrock uses the container's IAM role (task role in ECS, IRSA in EKS, etc.) — no static credentials in env vars. Task role needs `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on the two configured model IDs.

### 5.5 Optional — persistent snapshot storage

| Variable | Purpose |
|---|---|
| `MAXMYCLOUD_REPLAY_DIR` | Directory the app can write snapshot files to (used for large-scale health-check exports). Default `/home/data/snapshots`. Mount a shared volume (EFS, or your equivalent) here if you want snapshots to survive restarts. |

### 5.6 What is deliberately NOT required

- **AWS SES / SMTP** — not required for this POC. Without email, the following features are unavailable but do not block core functionality: password-reset self-service (customer admin can reset via UI instead), scheduled health-check email digests, magic-link support signin (password path replaces it). If you enable SES later, all these features light up automatically.
- **AWS Secrets Manager** — not required. Customer's own secret store injects env vars into the container at deploy time. All secrets are read from `process.env`.
- **Route 53** — not required. Customer's internal DNS resolves the FQDN.

---

## 6. Database requirements

MaxMyCloud stores metadata (users, sessions, health-check history, orchestration findings, budget configs, etc.) in a **Mongo-compatible database**. No Snowflake data is copied here — Snowflake data is fetched on-demand and rendered.

Tested compatible:

| Database | Notes |
|---|---|
| **AWS DocumentDB 5.0** | Recommended for AWS-hosted deploys. Connection string MUST include `retryWrites=false` — DocumentDB rejects retryable writes. All 13 P0/P1 compat tests pass (see internal `docs/ai/INTERNAL_AIG_DocumentDB_Compatibility_Test_Plan.md`). |
| **MongoDB Atlas** | Full compat, no adaptation needed |
| **Azure Cosmos DB Mongo API** | Full compat (this is our production database). Some indexed-sort quirks handled in-code. |

**Sizing:** `db.t3.medium` (~2 vCPU, 4 GB RAM) is sufficient for a single-tenant install with modest load. Single instance; add a replica for multi-AZ HA. Storage grows slowly — starts near 0, tens of MB after a year of typical use.

**Access:** the app connects with a single Mongo user that has full read/write on the database. Store the connection string (including credentials) in your secret store, inject as `MONGODB_URI`.

---

## 7. Network requirements

### 7.1 Inbound

Only the app's HTTP port (default 3010). Terminate TLS at your load balancer / proxy. **Do not expose the app to the public internet** for this POC — the customer's proxy handles vendor access.

### 7.2 Outbound (from the container to external services)

| Destination | Purpose | Port | Optional |
|---|---|---|---|
| **Snowflake account URL** (`*.snowflakecomputing.com`) | Query the customer's Snowflake tenant | 443 | Required |
| **Bedrock endpoint** (`bedrock-runtime.<region>.amazonaws.com`) | LLM inference | 443 | Only if AI features enabled |
| **MongoDB endpoint** | Database access | 27017 | Required |
| **Container registry** (`ghcr.io` or customer's own) | Image pulls at deploy time only | 443 | Deploy-time only |

**No outbound to any MaxMyCloud-hosted API.** The recommendation engine is inlined into the container (JS port). The app does not phone home. If you require a fully air-gapped posture, use VPC endpoints for Bedrock and (optionally) your image registry.

---

## 8. IAM permissions (AWS-side, if applicable)

The container's task role needs, at minimum:

- `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on the two model IDs you configure (main + fast) — only if AI is enabled
- Read access to whatever secret store you use, scoped to the specific secrets you inject as env vars
- CloudWatch Logs write (for container stdout/stderr)

No S3, no other AWS service access is required for the core app.

---

## 9. Deployment sequence — the runbook

1. **Provision database.** Bring up your Mongo-compatible DB. Capture the connection string.
2. **Provision secret store entries.** All variables in §5.1 populated in your secret store. Confirm your platform team can inject them as env vars.
3. **Provision the customer's proxy path.** MaxMyCloud engineers should be able to reach the target FQDN through your proxy before the app comes up (the proxy config is customer-side — MaxMyCloud provides the engineer identities to allow).
4. **Deploy the container.** Pull the image tag you chose, deploy replicas, wait for health check to pass on `/api/version`.
5. **Verify bootstrap log line.** Container stdout on first start should include `[bootstrap-superadmin] seeded support@maxmycloud.com (id=…) as Superadmin`. If instead you see `already exists — no-op`, the DB isn't fresh (which is fine on redeploys). If you see `hash for … does not look like a bcrypt hash — skipping`, the env var override is malformed — check the value.
6. **MaxMyCloud engineer signs in.** Via customer's proxy → `/login?bypass=1` → **MaxMyCloud staff sign in** → enter `support@maxmycloud.com` + shared password → prompted for TOTP enrollment → enroll → land in the app as superadmin.
7. **Configure Snowflake SSO.** Engineer navigates to the enterprise-signup flow, enters OAuth Client ID + Client Secret (from the Snowflake `SECURITY INTEGRATION` you created), sets the OAuth redirect URI to `${NUXT_PUBLIC_APP_URL}/api/oauth/callback`.
8. **Create the customer's tenant admin.** Engineer creates the customer's first admin user (their email address) via Settings → Users, granting them Admin role.
9. **Customer's admin signs in via SSO.** From here on, the customer signs in normally via Snowflake SSO. MaxMyCloud engineer's account is retained for ongoing support access via the customer's proxy.

---

## 10. Post-onboarding verification

- **Snowflake SSO login works** — customer's admin can sign in from their normal Snowflake session and reach the dashboard
- **The MaxMyCloud service KeyPair connection works** — Settings → Accounts shows AI & autosize as "backed by service KeyPair", not "needs KeyPair"
- **A health check runs successfully** — customer's admin triggers a health check from the dashboard; it completes with recommendations
- **Autosize monitoring is active** — Warehouse monitor shows recent decisions

---

## 11. Known caveats / follow-ups

### 11.1 Server-side MFA enforcement is UX-gated, not strictly server-enforced
The MFA-enforce middleware is client-side. A determined attacker with the bootstrap password *and* the ability to call server APIs directly (bypassing the browser UI) could issue actions in the small window between initial login and TOTP enrollment. Mitigation for POC: MaxMyCloud engineer enrolls TOTP within seconds of first login on each install. Roadmap item: add server-side "must enroll" gate on `login-password` that issues an enrollment-only limited session for unenrolled admin/superadmin roles.

### 11.2 Bootstrap superadmin is not per-install
Same email + same bcrypt hash across every customer deployment. Attacker who cracks the shared password can attempt login on any install, but still cannot get past MFA without also compromising the target install's DocumentDB to extract that install's TOTP secret. If a customer requires per-install credentials, override `BOOTSTRAP_SUPERADMIN_BCRYPT_HASH` via env var — MaxMyCloud will provide a per-install hash.

### 11.3 SES-less deploys lose password-reset self-service
If a MaxMyCloud engineer forgets their password (of the shared account) or a customer user forgets theirs, self-service reset via email link is unavailable in a SES-less deploy. Password reset must be done by a superadmin via the UI. Roadmap item: SMTP relay support for customers that have their own outbound mail infrastructure but no SES.
