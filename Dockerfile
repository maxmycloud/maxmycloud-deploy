# Multi-stage Nuxt 3 image for customer-tenant AWS deployments.
# See deployment/aws/customer/ for the Terraform that runs this on ECS Fargate.
#
# Build:   docker build -t maxmycloud .
# Run:     docker run --rm -p 3000:3000 --env-file .env.production maxmycloud

# ─── Stage 1: build ─────────────────────────────────────────────────────
FROM node:22-slim AS builder
WORKDIR /app

# Copy dependency manifests first for better layer caching
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# Copy source + build Nuxt (produces .output/)
COPY . .
RUN npm run build

# ─── Stage 2: runtime ───────────────────────────────────────────────────
FROM node:22-slim AS runtime
WORKDIR /app

# Non-root user for defense-in-depth
RUN groupadd -r app && useradd -r -g app -d /app app

# .output/ is fully self-contained (Nitro bundles server + client + deps)
COPY --from=builder --chown=app:app /app/.output /app/.output

# Build metadata baked at image-build time — surfaced by GET /version so
# ops can tell exactly what commit is running behind a given ALB. All args
# are optional; the /version endpoint defaults them to "unknown" if unset.
# CI passes them via `docker build --build-arg BUILD_COMMIT=$(git rev-parse HEAD) ...`
ARG BUILD_COMMIT=unknown
ARG BUILD_BRANCH=unknown
ARG BUILD_TIME=unknown
ARG BUILD_DIRTY=false
ARG IMAGE_TAG=unknown
ENV BUILD_COMMIT=$BUILD_COMMIT \
    BUILD_BRANCH=$BUILD_BRANCH \
    BUILD_TIME=$BUILD_TIME \
    BUILD_DIRTY=$BUILD_DIRTY \
    IMAGE_TAG=$IMAGE_TAG

# Snapshot dir mount point (EFS on ECS). Keep the app agnostic — the env var
# lets any container use whatever path is mounted, and the app falls back to
# ./data/snapshots when unset. Empty dir here is only a mount target.
RUN mkdir -p /mnt/data/snapshots && chown -R app:app /mnt/data/snapshots
ENV MAXMYCLOUD_REPLAY_DIR=/mnt/data/snapshots

USER app
EXPOSE 3000
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000 \
    NITRO_PRESET=node-server

# Healthcheck — Nuxt serves the SPA root; a 200 means the server is up.
# ECS also uses its own target-group healthcheck against the ALB.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD node -e "require('http').get('http://127.0.0.1:3000/', r => process.exit(r.statusCode < 500 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", ".output/server/index.mjs"]
