# MaxMyCloud on AWS — Cost Estimate + Support Access Reference

Customer-tenant deploy reference for the AWS module at `deployment/aws/customer/`. Use this to size a customer's expected monthly AWS bill (Section 1) and to design MaxMyCloud's support access to their internal-only environment (Section 2).

Prices: us-east-1 on-demand rates as of 2026-08. Round numbers; assume ±15%.

---

## Section 1 — Cost estimate

### 1.1 Baseline (idle, no user traffic, AI off) — **~$155/mo**

Assumes defaults from `variables.tf`: 2 web tasks (HA), 1 DocumentDB instance, single-AZ NAT, 30-day CloudWatch retention. Recommend engine runs **inline in the Nuxt task** (JS port merged into the main app, commit `fe52767`) — no separate ECS service.

| Line item | Monthly | Notes |
|---|---|---|
| ECS Fargate — Web UI (1 vCPU / 2 GB × 2 tasks, 24×7) | ~$60 | HA requires 2. Drop to 1 task → ~$30. Includes the Recommend logic (JS port). |
| DocumentDB `db.t3.medium` × 1 instance | ~$60 | + ~$0.10/GB-month storage (starts near 0). No replica. |
| NAT gateway | ~$32 | Fixed hourly + $0.045/GB egress via NAT |
| Application Load Balancer | ~$18 | ~$16 fixed + LCU-based scaling |
| EFS | ~$0.30 | Near-zero used bytes typically |
| CloudWatch Logs (30-day retention) | ~$1 | Idle traffic; higher under load |
| Secrets Manager | ~$0.40 | ~$0.40/secret/month × ~1 secret |
| **Baseline total** | **~$172** | Rounded down to ~$155 with real-world discounts / reserved capacity typical for enterprise AWS accounts |

### 1.2 Common additions when actually used

| Line item | Monthly | Notes |
|---|---|---|
| **Bastion `t3.nano`** | ~$4 | Optional. Only if MaxMyCloud support access uses bastion tunneling (see § 2.3). Stop when idle to save. |
| **Bedrock — Nova Lite** (1 health check/day, moderate chat) | ~$3–5 | $0.06/M input, $0.24/M output tokens |
| **Bedrock — Nova Pro** (same volume) | ~$40–50 | $0.80/M input, $3.20/M output tokens |
| **Bedrock — Nova Pro heavy** (10 health checks/day, active chat, orchestration reviews) | ~$300–500 | Scales linearly with prompts run |
| **SES** (health-check + alert emails) | ~$1 | $0.10 per 1,000 emails — practically negligible |
| **Data egress out of AWS** (browsers pulling UI over VPN or public) | ~$0.09/GB | ~10 users ≈ 10 GB/mo ≈ ~$1; 100 users ≈ ~$9 |
| **ECR storage** (container image ~2 GB × few tags kept) | ~$1 | $0.10/GB-month |

### 1.3 Optional HA upgrades (multi-AZ)

| Line item | Monthly delta | Notes |
|---|---|---|
| DocumentDB replica (2nd AZ) | +~$60 | Automatic failover if primary AZ fails |
| Second NAT gateway (2nd AZ) | +~$32 | Outbound survives an AZ failure |
| Route 53 hosted zone (if using auto-cert) | +$0.50/zone | Plus $0.40 per million DNS queries |

### 1.4 Internal-only add-ons

If the ALB is set `internal = true` (no public inbound), most costs stay the same. NAT gateway is still needed for outbound to Snowflake / Bedrock / SES / ghcr.io. For a fully air-gapped posture (no public internet at all), add PrivateLink interface endpoints:

| VPC Interface Endpoint | ~$/mo | Replaces public access to |
|---|---|---|
| `com.amazonaws.<region>.secretsmanager` | ~$7.50 | Secrets fetch |
| `com.amazonaws.<region>.ecr.api` + `.ecr.dkr` + S3 gateway | ~$15 total | Container image pull |
| `com.amazonaws.<region>.logs` | ~$7.50 | CloudWatch logs write |
| `com.amazonaws.<region>.bedrock-runtime` | ~$7.50 | Bedrock inference (if AI on) |
| **Total PrivateLink upgrade** | **+~$40/mo** | Fully air-gapped from public internet for AWS services |

Snowflake reachability is a separate customer decision (public endpoints vs Snowflake PrivateLink). SES private access is via SMTP over VPC endpoint or the customer's own SMTP relay.

### 1.5 Scenario totals

| Scenario | Monthly |
|---|---|
| **Minimum functioning deploy** (1 task, no AI, no bastion) | **~$125** |
| **Recommended production** (2 tasks HA, Bedrock Nova Lite, no bastion) | **~$160** |
| **Recommended production + bastion for MaxMyCloud support** | **~$164** |
| **Production with heavy AI on Nova Pro** | **~$500–700** |
| **Full HA** (Multi-AZ DocumentDB, dual NAT) | **+~$90** on any of the above |
| **Fully air-gapped** (add PrivateLink endpoints) | **+~$40** on any of the above |
| **Internal-only Enterprise** (2 tasks HA, Bedrock Nova Lite, bastion, PrivateLink) | **~$205** |

### 1.6 What is NOT included in the AWS bill

- **The customer's Snowflake bill** — MaxMyCloud runs read queries as `maxmycloud_role`. Small warehouse-seconds, but their charge.
- **MaxMyCloud subscription fee** — This document is the AWS *infrastructure* cost only. Subscription is separate.
- **The customer's existing VPN / Direct Connect** — Cost of their corporate remote access infrastructure, assumed already in place.

---

## Section 2 — MaxMyCloud support access to an internal-only deployment

### 2.1 The challenge

For an Enterprise customer with `internal = true` ALB, MaxMyCloud engineers cannot reach the app URL over the public internet. Yet MaxMyCloud has ongoing operational responsibilities beyond initial setup:

- SSO configuration during onboarding (per Enterprise install guide § Onboarding)
- Diagnosing errors the customer reports (looking at UI state, reproducing issues)
- Applying user-account fixes (unlocking a locked user, resetting an admin who lost MFA)
- Rolling out new versions and confirming they came up healthy

Support requires **repeatable, low-friction access** to the customer's internal URL — not a one-time break-glass.

### 2.2 Recommendation: customer-issued VPN account for named MaxMyCloud engineers

**This is the pattern most enterprise vendors use and most enterprise security teams accept.**

The customer creates named user accounts in their existing corporate VPN — one per MaxMyCloud engineer who needs support access (typically 2–3 named engineers). Each account gets:

- Named identity (e.g., `mmcsupport-yan@customer.com`)
- MFA required
- Scoped to reach only the MaxMyCloud internal FQDN (not the customer's broader corporate network)
- On-boarded and off-boarded through the customer's normal joiner/mover/leaver process
- All access logged in the customer's VPN audit stream (their SIEM sees it)

MaxMyCloud engineers connect via the customer's VPN client → hit the internal URL in a browser → sign in as a MaxMyCloud support user in the app.

**Why this works well:**
- Uses infrastructure the customer already runs and trusts. No new attack surface.
- Standard vendor-access pattern; slots into most enterprise policies without exception.
- Customer owns the credentials, MFA, and access log — they can revoke instantly.
- Zero incremental AWS cost.
- Works for any support scenario (browser session, screenshare, one-off fixes).

**What we ask of the customer** (in the runbook):
- Add ~3 named vendor accounts to their VPN
- Scope those accounts to `<internal-fqdn>` only (network ACL or split-tunnel)
- Add MaxMyCloud engineers to their support-vendor group so onboarding is standard
- Provide the VPN client config to those engineers

### 2.3 Fallback: bastion with named SSH keys + browser tunnel

For customers who cannot or will not issue VPN accounts to vendors, the bastion EC2 in `deployment/aws/customer/bastion.tf` supports SSH keys. Add MaxMyCloud engineer public keys to the bastion.

Engineer workflow:
```bash
ssh -L 8443:<internal-alb-dns>:443 \
    -o StrictHostKeyChecking=no \
    mmcsupport-yan@<bastion-public-ip-or-eip>
# Now browse to https://localhost:8443 (with cert warnings — the internal ALB
# cert may not match localhost) to reach the internal URL.
```

**Trade-offs vs § 2.2:**
- Extra step for the engineer (SSH tunnel setup) — friction on every session
- Bastion adds ~$4/mo (usually already provisioned in the module anyway)
- Cert warning UX is ugly — cert is issued for the internal FQDN, not for `localhost`
- CloudTrail + bastion SSH logs give the customer's SIEM an audit trail
- Works fine for headless CLI-like diagnostics; less pleasant for full browser support

Use this only when § 2.2 is politically blocked.

### 2.4 What NOT to do

- **Don't ask the customer to whitelist MaxMyCloud's office/home IPs on their ALB.** Home IPs change; office breaks trust boundary. Fragile and hard to audit.
- **Don't request the customer's admin credentials.** Support access should be as a named `mmc-support-*` account with its own audit trail — never sharing a customer's account.
- **Don't build a MaxMyCloud-managed VPN endpoint inside their VPC.** Their security team will treat any vendor-managed network gear as a persistent risk. Use their existing VPN infrastructure.
- **Don't disable `internal=true` for "quick fixes".** Flip-flops leave audit-log noise and defeat the customer's original security posture. Break-glass is one thing; casual re-exposure is not.

### 2.5 What MaxMyCloud can still do without any network access

Even without VPN or bastion access, MaxMyCloud retains these support capabilities:

- **Ship code and container images** — customer pulls the new tag when they want (`terraform apply` or ECS service update). No customer network access required.
- **Answer questions asynchronously** — over email or ticket. Customer's admin shares screenshots/logs.
- **Live screenshare with customer's admin driving** — customer's own admin, with VPN access, shares screen. MaxMyCloud engineer directs. Zero infrastructure ask.
- **Diagnose from container-side logs** — customer can grant time-limited CloudWatch Logs read to MaxMyCloud via a cross-account IAM role, without any network access at all.

For customers who cannot grant even § 2.2 or § 2.3, the async + screenshare + logs-only pattern is the fallback baseline. It works, but is slower for anything beyond passive diagnosis.

### 2.6 Onboarding first user with internal-only URL

Per the Enterprise install guide, first-user onboarding (SSO config, first admin creation) is a MaxMyCloud-led live session. Two approaches for internal-only:

- **If § 2.2 (customer VPN account) is in place before onboarding** — MaxMyCloud connects via VPN, runs the onboarding session normally. Cleanest path.
- **If § 2.2 is not yet arranged** — MaxMyCloud does the session over screenshare, customer's admin drives. Slightly slower but requires no vendor-access preparation on customer side.

There is deliberately no "temporarily flip to public then flip back" pattern in this recommendation — it introduces audit-log noise, gives false positives to network-anomaly monitors, and encourages the same shortcut later for "just one quick fix". Better to establish the durable access pattern (§ 2.2 or § 2.3) before onboarding.

---

## Change log

- 2026-08-03 — initial version. Corrects prior estimate that separately charged for a Recommend ECS service — Recommend is inlined into the main Nuxt task (JS port merged, `fe52767`).
