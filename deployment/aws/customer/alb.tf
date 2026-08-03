# Application Load Balancer + target group + listeners.
# HTTP:80 → redirect to HTTPS:443
# HTTPS:443 → forward to the ECS task target group (port 3000)
#
# Cert handling:
#   • var.acm_certificate_arn set  → use existing cert (customer provided)
#   • var.acm_certificate_arn empty AND var.fqdn + var.route53_zone_id set
#     → Terraform issues a DNS-validated cert
#   • both empty                    → HTTP-only listener (dev only, no HTTPS)

resource "aws_lb" "this" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  idle_timeout       = 300  # longer than default 60s for slow LLM streaming responses
}

resource "aws_lb_target_group" "app" {
  name        = "${local.name}-app"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"          # required for Fargate
  vpc_id      = aws_vpc.this.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
    matcher             = "200-399"
  }

  # Cookie-based stickiness — the app's session state is per-ECS-task
  # in-memory (server/utils/session.ts activeSessions Map). Without
  # stickiness, a user's follow-up requests can land on a different task
  # than the one that issued the session, causing spurious 401s. This
  # pins each browser to the same task for 8 hours (matches the app's
  # refresh-token cycle). Task death still logs affected users out —
  # true HA needs JWT-stateless sessions (v0.4.0 target).
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 8 * 60 * 60   # 8 hours
    enabled         = true
  }

  deregistration_delay = 30
}

# ─── Cert issuance ──────────────────────────────────────────────────
# HTTPS is REQUIRED for this deploy — see the check block below. Three
# supported paths for providing the cert, in priority order:
#   1. Bring-your-own: acm_certificate_arn set → use it as-is.
#   2. Auto-issue via ACM DNS validation: fqdn + route53_zone_id set →
#      Terraform provisions the cert and validates via Route 53.
#   3. Self-signed for POC / evaluation: use_self_signed_cert = true →
#      Terraform generates a self-signed cert + imports to ACM. Browser
#      will show a "Not Secure" warning, but the app + all cookies work.
locals {
  issue_own_cert       = var.acm_certificate_arn == "" && var.fqdn != "" && var.route53_zone_id != ""
  use_self_signed_cert = var.acm_certificate_arn == "" && !local.issue_own_cert && var.use_self_signed_cert
  # Boolean derived from INPUT vars only — known at plan time so resource
  # `count`s that depend on it can be computed before apply.
  https_enabled = var.acm_certificate_arn != "" || local.issue_own_cert || local.use_self_signed_cert
  # Actual cert ARN — resource attribute, only known after apply. Used
  # inside the HTTPS listener which is itself only created when
  # https_enabled=true, so the try(...) fallbacks never fire in practice.
  effective_cert_arn = (
    var.acm_certificate_arn != ""      ? var.acm_certificate_arn :
    local.issue_own_cert               ? try(aws_acm_certificate_validation.this[0].certificate_arn, "") :
    local.use_self_signed_cert         ? try(aws_acm_certificate.self_signed[0].arn, "") :
    ""
  )
}

# HTTPS is mandatory. Fail fast at apply time if none of the three cert
# paths is configured, with an actionable message instead of a confusing
# runtime error later.
check "https_configured" {
  assert {
    condition = var.acm_certificate_arn != "" || (var.fqdn != "" && var.route53_zone_id != "") || var.use_self_signed_cert
    error_message = "HTTPS is required. Set one of: (a) acm_certificate_arn to an existing ACM cert ARN, (b) fqdn + route53_zone_id for Terraform to auto-issue a Route 53 DNS-validated ACM cert, or (c) use_self_signed_cert = true for a self-signed cert (POC/evaluation only — browsers show a warning). See DEPLOY.md § 1.4."
  }
}

# Self-signed cert for POC deploys — Terraform generates a 4096-bit key +
# self-signed cert good for 5 years, imports into ACM, and the ALB HTTPS
# listener uses it. Browsers will show "Not Secure" but the app functions.
resource "tls_private_key" "self_signed" {
  count     = local.use_self_signed_cert ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "self_signed" {
  count           = local.use_self_signed_cert ? 1 : 0
  private_key_pem = tls_private_key.self_signed[0].private_key_pem
  subject {
    common_name  = "${local.name}.internal"
    organization = "MaxMyCloud Self-Signed (POC)"
  }
  validity_period_hours = 5 * 365 * 24  # 5 years
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
  dns_names             = [aws_lb.this.dns_name, "*.${var.region}.elb.amazonaws.com"]
}

resource "aws_acm_certificate" "self_signed" {
  count            = local.use_self_signed_cert ? 1 : 0
  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem
  lifecycle { create_before_destroy = true }
}

resource "aws_acm_certificate" "this" {
  count             = local.issue_own_cert ? 1 : 0
  domain_name       = var.fqdn
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.issue_own_cert ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}
  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.issue_own_cert ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ─── Listeners ──────────────────────────────────────────────────────
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # If HTTPS is enabled, redirect. Otherwise, forward HTTP directly (dev only).
  dynamic "default_action" {
    for_each = local.https_enabled ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
  dynamic "default_action" {
    for_each = local.https_enabled ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.app.arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = local.https_enabled ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.effective_cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ─── DNS A-record for the FQDN → ALB ───────────────────────────────
resource "aws_route53_record" "app" {
  count   = var.fqdn != "" && var.route53_zone_id != "" ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.fqdn
  type    = "A"
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
