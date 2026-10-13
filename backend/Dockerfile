# =============================================================================
# DOCKERFILE: Production-Grade Multi-Stage Container Blueprint
# Target Runtime: Google Cloud Run (Fully Managed Serverless Container Engine)
# Supported Architectures: Node.js (Active Default) | Python (Alternative Blueprint)
# =============================================================================
#
# ARCHITECTURAL HIGHLIGHTS:
#   1. Multi-Stage Pipeline: Separates dependency resolution, source compilation,
#      and runtime execution into independent stages. DevDependencies, source maps,
#      and build caches are never leaked into the final production image.
#   2. Minimal Attack Surface: Built on Alpine Linux (`node:20-alpine`) to reduce
#      vulnerability footprint (CVEs) and image transfer sizes.
#   3. Optimized Layer Caching: Manifests (package.json / lockfiles) are copied
#      independently from source code, enabling Docker layer re-use across builds.
#   4. Least-Privilege Execution: Runs as an unprivileged, non-root user (UID 1001)
#      to comply with zero-trust container security policies.
#   5. Cloud Run Protocol Compliance: Respects the dynamic $PORT environment
#      variable assigned by Cloud Run's ingress proxy (defaulting to 8080).
#   6. Signal Propagation: Executes the binary directly without npm/yarn wrappers,
#      ensuring SIGTERM signals sent by Cloud Run autoscalers trigger graceful shutdown.
# =============================================================================

# -----------------------------------------------------------------------------
# RUNTIME OPTION A: Node.js Microservice (Active Default)
# -----------------------------------------------------------------------------

# =============================================================================
# STAGE 1: Dependency Resolution (deps)
# Purpose: Clean extraction and caching of production-only node_modules.
# =============================================================================
FROM node:20-alpine AS deps

# Set isolated working directory
WORKDIR /app

# Copy dependency manifests exclusively.
# This prevents cache invalidation whenever business logic files change.
COPY package.json package-lock.json* yarn.lock* pnpm-lock.yaml* ./

# Deterministic package installation:
# - npm ci / frozen-lockfile: Ensures exact dependency tree matching the lockfile.
# - --only=production / --prod: Omits devDependencies to maintain minimal footprint.
# - --ignore-scripts: Mitigates supply-chain risks by preventing arbitrary install hooks.
RUN if [ -f pnpm-lock.yaml ]; then \
        npm install -g pnpm && pnpm install --frozen-lockfile --prod; \
    elif [ -f yarn.lock ]; then \
        yarn install --frozen-lockfile --production; \
    else \
        npm ci --only=production --ignore-scripts; \
    fi

# =============================================================================
# STAGE 2: Build & Asset Compilation (builder)
# Purpose: Compiles TypeScript / Bundles assets using complete toolchain.
# =============================================================================
FROM node:20-alpine AS builder

WORKDIR /app

# Re-copy manifests to install full dependency suite (including devDependencies like TypeScript)
COPY package.json package-lock.json* yarn.lock* pnpm-lock.yaml* ./

RUN if [ -f pnpm-lock.yaml ]; then \
        npm install -g pnpm && pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then \
        yarn install --frozen-lockfile; \
    else \
        npm ci --ignore-scripts; \
    fi

# Ingest application source code for compilation
COPY . .

# Execute project build script (e.g., `tsc`, `esbuild`, `webpack`).
# If no custom build script exists (e.g. plain vanilla JS), fallback safely.
RUN npm run build || echo "Build step bypassed: No 'build' script defined in package.json."

# =============================================================================
# STAGE 3: Final Production Runtime (runtime)
# Purpose: Ultra-lightweight container holding only pre-built assets and prod deps.
# =============================================================================
FROM node:20-alpine AS runtime

# Security Hardening:
# Cloud Run containers should never run as root. Create a dedicated system
# user and group with an explicit UID/GID (1001) for audit compliance.
RUN addgroup -g 1001 -S appgroup && \
    adduser  -u 1001 -S appuser -G appgroup

WORKDIR /app

# Ingest production dependencies from Stage 1 (clean, production-only tree)
COPY --from=deps --chown=appuser:appgroup /app/node_modules ./node_modules

# Ingest compiled production artifacts from Stage 2
COPY --from=builder --chown=appuser:appgroup /app/dist ./dist
COPY --from=builder --chown=appuser:appgroup /app/package.json ./

# Environment configuration:
# - PORT: Cloud Run dynamically assigns an ingress port via $PORT. Defaults to 8080.
# - NODE_ENV: Enforces optimized runtime behavior across Node.js libraries (e.g., Express).
ENV PORT=8080
ENV NODE_ENV=production

# Informational port exposure for local Docker orchestrators (e.g., docker-compose)
EXPOSE ${PORT}

# Transition execution context to unprivileged user
USER appuser

# Container Health Probe:
# Used primarily in local environments or Kubernetes. Cloud Run performs
# its own health/startup probes via HTTP path configuration in cloudbuild.yaml.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:${PORT}/health || exit 1

# Process Execution:
# Directly invoke node on compiled entrypoint.
# Crucial: Avoid wrapping in 'npm start' or 'sh' because shells swallow SIGTERM signals,
# preventing Node's http.Server from gracefully finishing in-flight HTTP requests.
CMD ["node", "dist/index.js"]


# -----------------------------------------------------------------------------
# RUNTIME OPTION B: Python Microservice (FastAPI / Flask / Django)
# Note: To activate, comment out Option A above and uncomment this block.
# -----------------------------------------------------------------------------

# # ===========================================================================
# # STAGE 1: Python Compilation & Virtual Environment Builder
# # ===========================================================================
# FROM python:3.12-slim AS builder
#
# WORKDIR /app
#
# # Install system dependencies required for native C-extension compilation
# RUN apt-get update && \
#     apt-get install -y --no-install-recommends gcc libffi-dev musl-dev && \
#     rm -rf /var/lib/apt/lists/*
#
# # Copy package specification for dependency caching
# COPY requirements.txt ./
#
# # Build dependencies inside an isolated virtual environment
# RUN python -m venv /opt/venv
# ENV PATH="/opt/venv/bin:$PATH"
# RUN pip install --no-cache-dir --upgrade pip && \
#     pip install --no-cache-dir -r requirements.txt
#
# # ===========================================================================
# # STAGE 2: Python Minimal Runtime
# # ===========================================================================
# FROM python:3.12-slim AS runtime
#
# # Provision unprivileged execution user
# RUN groupadd -r appgroup && useradd -r -g appgroup -d /app -s /sbin/nologin appuser
#
# WORKDIR /app
#
# # Transfer virtual environment from builder stage
# COPY --from=builder /opt/venv /opt/venv
# ENV PATH="/opt/venv/bin:$PATH"
#
# # Copy application source tree with correct permission ownership
# COPY --chown=appuser:appgroup . .
#
# ENV PORT=8080
# ENV PYTHONUNBUFFERED=1
# EXPOSE ${PORT}
#
# USER appuser
#
# # Basic liveness check for local execution
# HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
#     CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:${PORT}/health')" || exit 1
#
# # Production WSGI/ASGI Server:
# # - Gunicorn + Uvicorn worker class for high-throughput asynchronous execution
# # - Workers tuned for serverless instances (typically 2-4 workers per 1-2 vCPUs)
# CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--timeout", "120", "app:app"]
