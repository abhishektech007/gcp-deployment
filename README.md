# GCP Full-Stack Deployment Package

> Production-grade deployment configuration for a Node.js/Python backend on **Cloud Run** and Angular frontend on **Firebase Hosting** or **GCS + Cloud CDN**, with CI/CD via **Cloud Build** and container images on **Artifact Registry**.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Google Cloud Platform                         │
│                                                                     │
│  ┌──────────────┐    ┌──────────────────┐    ┌──────────────────┐  │
│  │  Cloud Build  │───▶│ Artifact Registry │───▶│    Cloud Run     │  │
│  │  (CI/CD)      │    │ (Docker Images)   │    │ (Backend API)    │  │
│  └──────┬───────┘    └──────────────────┘    └────────┬─────────┘  │
│         │                                              │            │
│         │ triggers on push                    REST API │            │
│         │                                              │            │
│  ┌──────┴───────┐                            ┌────────▼─────────┐  │
│  │    GitHub /   │                            │ Secret Manager   │  │
│  │  Cloud Source │                            │ (Env Variables)  │  │
│  └──────────────┘                            └──────────────────┘  │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │          Firebase Hosting  OR  GCS + Cloud CDN               │  │
│  │          (Angular SPA — Static Assets)                       │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Directory Structure

```
gcp-deployment/
├── deploy.sh                   # Master orchestration script
├── cloudbuild.yaml             # Cloud Build CI/CD pipeline
├── .env.example                # Environment variables template
├── .gitignore                  # Git ignore rules
├── README.md                   # This file
│
├── backend/
│   ├── Dockerfile              # Multi-stage production Dockerfile
│   ├── .dockerignore           # Docker build context exclusions
│   └── deploy-backend.sh       # Direct standalone backend deployment script
│
└── frontend/
    ├── angular.json            # Angular production build configuration
    ├── firebase.json           # Firebase Hosting configuration
    └── deploy-frontend.sh      # GCS + Cloud CDN deployment script
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| `gcloud` CLI | Latest | [cloud.google.com/sdk](https://cloud.google.com/sdk/docs/install) |
| `docker` | 20+ | [docker.com](https://docs.docker.com/get-docker/) |
| `node` / `npm` | 20+ LTS | [nodejs.org](https://nodejs.org/) |
| `firebase-tools` | Latest | `npm install -g firebase-tools` (only for Firebase strategy) |
| Angular CLI | 17+ | `npm install -g @angular/cli` |

---

## Quick Start

### 1. Authenticate with GCP

```bash
# Login to GCP
gcloud auth login

# Set your project
gcloud config set project YOUR_PROJECT_ID

# Authenticate Docker for Artifact Registry
gcloud auth configure-docker us-central1-docker.pkg.dev
```

### 2. Configure Environment

```bash
# Copy the template and fill in your values
cp .env.example .env
```

### 3. Run the Master Deploy Script

```bash
# Make executable
chmod +x deploy.sh

# Full deployment (Firebase Hosting for frontend)
./deploy.sh --project YOUR_PROJECT_ID --region us-central1

# Full deployment (GCS + Cloud CDN for frontend)
./deploy.sh --project YOUR_PROJECT_ID --region us-central1 --frontend-strategy gcs

# Dry run (preview commands without executing)
./deploy.sh --project YOUR_PROJECT_ID --region us-central1 --dry-run

# Deploy only backend
./deploy.sh --project YOUR_PROJECT_ID --region us-central1 --skip-frontend

# Deploy only frontend
./deploy.sh --project YOUR_PROJECT_ID --region us-central1 --skip-backend
```

The script performs these phases in order:
1. **Enable GCP APIs** — Cloud Run, Cloud Build, Artifact Registry, etc.
2. **Provision Artifact Registry** — Docker image repository
3. **Configure IAM** — Service account permissions for Cloud Build
4. **Build & Deploy Backend** — Docker build → push → Cloud Run deploy
5. **Build & Deploy Frontend** — Angular build → Firebase / GCS upload

---

## Detailed Component Guide

### Backend: Dockerfile

The [Dockerfile](backend/Dockerfile) uses a **3-stage build** for minimal image size:

| Stage | Purpose | Base Image |
|-------|---------|------------|
| `deps` | Install production dependencies only | `node:20-alpine` |
| `builder` | Compile TypeScript / bundle | `node:20-alpine` |
| `runtime` | Run the application | `node:20-alpine` |

**Key features:**
- Layer caching for dependencies (only rebuilds when `package.json` changes)
- Non-root user (`appuser`) for security
- Health check endpoint at `/health`
- Proper SIGTERM handling for Cloud Run graceful shutdown
- Python alternative included (commented out)

**To switch to Python backend:** Comment out the Node.js stages and uncomment the Python stages in the Dockerfile.

---

### Backend: Direct Deployment Script (`deploy-backend.sh`)

For fast local testing or ad-hoc revisions without triggering the full Cloud Build pipeline:

```bash
chmod +x backend/deploy-backend.sh
cd backend
GCP_PROJECT_ID="your-project-id" GCP_REGION="us-central1" ./deploy-backend.sh
```

This builds the Docker image locally, authenticates with Container Registry, and deploys directly to Cloud Run.

---

### CI/CD: Cloud Build Pipeline

The [cloudbuild.yaml](cloudbuild.yaml) defines a 5-step pipeline:

```
Tests → Build Image → Push to AR → Deploy to Cloud Run → Health Check
```

**Setting up a trigger:**

```bash
# Connect your repository first
gcloud builds triggers create github \
  --name="deploy-on-push" \
  --repo-owner="YOUR_ORG" \
  --repo-name="YOUR_REPO" \
  --branch-pattern="^main$" \
  --build-config="cloudbuild.yaml" \
  --substitutions="_REGION=us-central1,_SERVICE_NAME=backend-api,_AR_REPO=docker-repo"
```

**Manual trigger:**

```bash
gcloud builds submit --config=cloudbuild.yaml .
```

**Customizable substitution variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `_REGION` | `us-central1` | GCP region |
| `_SERVICE_NAME` | `backend-api` | Cloud Run service name |
| `_AR_REPO` | `docker-repo` | Artifact Registry repository |
| `_MIN_INSTANCES` | `0` | Min Cloud Run instances |
| `_MAX_INSTANCES` | `10` | Max Cloud Run instances |
| `_MEMORY` | `512Mi` | Memory per instance |
| `_CPU` | `1` | vCPUs per instance |
| `_CONCURRENCY` | `80` | Max concurrent requests |

---

### Frontend: Firebase Hosting

The [firebase.json](frontend/firebase.json) includes:

- **SPA routing** — All paths rewrite to `index.html`
- **API proxy** — `/api/**` routes proxy to the Cloud Run backend
- **Cache headers** — Immutable for hashed assets, no-cache for `index.html`
- **Security headers** — X-Frame-Options, CSP, MIME sniffing protection

**Deploy manually:**

```bash
cd frontend
firebase deploy --only hosting --project YOUR_PROJECT_ID
```

### Frontend: GCS + Cloud CDN (Alternative)

Use [deploy-frontend.sh](frontend/deploy-frontend.sh) for GCS-based hosting:

```bash
chmod +x frontend/deploy-frontend.sh
cd frontend && ./deploy-frontend.sh --env production
```

---

## Secrets Management

**Never hardcode secrets.** Use GCP Secret Manager:

```bash
# Create a secret
echo -n "my-secret-value" | gcloud secrets create my-secret --data-file=-

# Grant Cloud Run access
gcloud secrets add-iam-policy-binding my-secret \
  --member="serviceAccount:YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Reference in Cloud Run deployment (add to cloudbuild.yaml deploy step)
# --set-secrets=MY_SECRET=my-secret:latest
```

---

## Rollback Procedure

Every deployment is tagged with the Git commit SHA, enabling instant rollback:

```bash
# List recent revisions
gcloud run revisions list --service=backend-api --region=us-central1

# Rollback to a specific revision
gcloud run services update-traffic backend-api \
  --region=us-central1 \
  --to-revisions=backend-api-abc1234=100
```

---

## Cost Optimization Tips

| Setting | Recommendation | Impact |
|---------|---------------|--------|
| `min-instances=0` | Scale to zero when idle | Eliminates idle cost |
| `max-instances=10` | Cap scaling | Prevents runaway costs |
| `concurrency=80` | Handle 80 req/instance | Reduces instance count |
| Cloud CDN | Cache static assets | Reduces egress costs |
| Artifact Registry cleanup | Set retention policy | Saves storage costs |

```bash
# Set Artifact Registry cleanup policy (keep last 10 images)
gcloud artifacts repositories set-cleanup-policies docker-repo \
  --location=us-central1 \
  --policy=policy.json
```

---

## Monitoring & Observability

After deployment, set up monitoring:

```bash
# View Cloud Run logs
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=backend-api" \
  --limit=50 --format=json

# Create an uptime check
gcloud monitoring uptime create \
  --display-name="Backend API Health" \
  --uri="https://YOUR_SERVICE_URL/health"
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Permission denied` on deploy | Re-run IAM phase: `./deploy.sh --project X --region Y --skip-build` |
| Build fails at test step | Fix tests locally, or skip: remove the `run-tests` step from `cloudbuild.yaml` |
| Cloud Run returns 503 | Check logs: `gcloud run services logs read backend-api --region=us-central1` |
| Docker build slow | Ensure `.dockerignore` excludes `node_modules` and large files |
| Firebase deploy fails | Run `firebase login` and `firebase init hosting` |

---

## License

Internal use. Adjust as needed for your organization.
