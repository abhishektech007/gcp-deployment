#!/usr/bin/env bash
# =============================================================================
# SCRIPT: deploy.sh — Master Infrastructure Provisioning & Deployment Orchestrator
# TARGET PLATFORM: Google Cloud Platform (GCP)
# TARGET ARCHITECTURE: Full-Stack Enterprise Application
#   - Backend: Google Cloud Run (Containerized Microservice)
#   - Container Storage: Google Artifact Registry (Docker OCI Format)
#   - CI/CD & Build: Google Cloud Build
#   - Frontend: Firebase Hosting OR Google Cloud Storage (GCS) + Cloud CDN
#   - Security: IAM Role Federation & Secret Manager Permissions
# =============================================================================
#
# ARCHITECTURAL HIGHLIGHTS:
#   1. Idempotent Provisioning: Safe to execute repeatedly without duplicating
#      resources or corrupting existing infrastructure state.
#   2. Least-Privilege IAM Orchestration: Grants only the precise IAM permissions
#      required by the Cloud Build service account to build, register, and roll out revisions.
#   3. Dual Frontend Strategy: Supports both zero-configuration Firebase Hosting
#      (recommended for SPAs) and enterprise GCS + Cloud CDN static hosting.
#   4. Safe Dry-Run Mode: Accepts '--dry-run' to audit provisioning commands without
#      mutating remote cloud state.
#
# EXECUTION MODES & CLI SYNTAX:
#   ./deploy.sh --project <PROJECT_ID> --region <REGION> [OPTIONS]
#
# REQUIRED FLAGS:
#   --project <ID>     Target Google Cloud Project ID
#   --region <REGION>  Target GCP Region (e.g., us-central1, europe-west1)
#
# OPTIONAL PARAMETERS:
#   --frontend-strategy <firebase|gcs>   Frontend hosting provider (Default: firebase)
#   --backend-dir <path>                 Relative path to backend directory (Default: ./backend)
#   --frontend-dir <path>                Relative path to frontend directory (Default: ./frontend)
#   --service-name <name>                Cloud Run service identifier (Default: backend-api)
#   --ar-repo <name>                     Artifact Registry repository name (Default: docker-repo)
#   --skip-build                         Skip artifact compilation; reuse existing image/dist
#   --skip-frontend                      Omit frontend deployment stage
#   --skip-backend                       Omit backend deployment stage
#   --dry-run                            Print planned commands without applying changes
#   -h, --help                           Display CLI usage and flag reference
# =============================================================================

# Strict Shell Execution Settings:
# -e: Halt immediately upon encounter of an unhandled non-zero exit status.
# -u: Disallow uninitialized environment variable lookups.
# -o pipefail: Capture non-zero status from piped command pipelines.
set -euo pipefail

# Global error trap to report precise line failure during unexpected crashes
trap 'log_error "Execution aborted unexpectedly at line ${LINENO} with exit code: $?"' ERR

# =============================================================================
# Section 1: Default Configuration Values
# =============================================================================
PROJECT_ID=""
REGION=""
FRONTEND_STRATEGY="firebase"
BACKEND_DIR="./backend"
FRONTEND_DIR="./frontend"
SERVICE_NAME="backend-api"
AR_REPO="docker-repo"
SKIP_BUILD=false
SKIP_FRONTEND=false
SKIP_BACKEND=false
DRY_RUN=false

# Dynamically derived endpoints (computed after argument parsing)
AR_HOSTNAME=""
IMAGE_URI=""
BUCKET_NAME=""

# =============================================================================
# Section 2: Terminal Styling & Logging Utilities
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Structured log helpers
log_info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[✔]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[✘]${NC}      $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }
log_header()  {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  $*${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Command execution dispatcher: executes or echoes based on --dry-run
run_cmd() {
    if [ "${DRY_RUN}" = true ]; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
    else
        eval "$@"
    fi
}

# =============================================================================
# Section 3: Command Line Argument Parsing
# =============================================================================
show_help() {
    head -35 "$0" | tail -30
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)           PROJECT_ID="$2"; shift 2 ;;
        --region)            REGION="$2"; shift 2 ;;
        --frontend-strategy) FRONTEND_STRATEGY="$2"; shift 2 ;;
        --backend-dir)       BACKEND_DIR="$2"; shift 2 ;;
        --frontend-dir)      FRONTEND_DIR="$2"; shift 2 ;;
        --service-name)      SERVICE_NAME="$2"; shift 2 ;;
        --ar-repo)           AR_REPO="$2"; shift 2 ;;
        --skip-build)        SKIP_BUILD=true; shift ;;
        --skip-frontend)     SKIP_FRONTEND=true; shift ;;
        --skip-backend)      SKIP_BACKEND=true; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        -h|--help)           show_help ;;
        *)                   log_error "Unrecognized CLI flag: $1"; show_help ;;
    esac
done

# Ensure mandatory cloud parameters are supplied
if [ -z "${PROJECT_ID}" ] || [ -z "${REGION}" ]; then
    log_error "Mandatory parameters missing: Please specify both --project and --region."
    echo "Example: ./deploy.sh --project my-company-prod --region us-central1"
    exit 1
fi

# Formulate derived infrastructure URIs
AR_HOSTNAME="${REGION}-docker.pkg.dev"
IMAGE_URI="${AR_HOSTNAME}/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}"
BUCKET_NAME="${PROJECT_ID}-frontend-production"

# =============================================================================
# Section 4: Pre-flight Verification & Environment Validation
# =============================================================================
log_header "Full-Stack Deployment Pipeline — Pre-Flight Validation"

# Verify availability of the Google Cloud SDK
if ! command -v gcloud &>/dev/null; then
    log_error "The 'gcloud' CLI binary is not installed on this system."
    log_error "Installation reference: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Verify active authentication session
if ! gcloud auth print-access-token &>/dev/null 2>&1; then
    log_error "Active GCP authentication session not detected."
    log_error "Please execute 'gcloud auth login' and retry."
    exit 1
fi

# Pin target project in local gcloud context
run_cmd "gcloud config set project '${PROJECT_ID}'"
log_success "Active GCP Project pinned: ${PROJECT_ID}"
log_info "Deployment Region:         ${REGION}"
log_info "Cloud Run Service:         ${SERVICE_NAME}"
log_info "Artifact Registry Target:  ${IMAGE_URI}"
log_info "Frontend Strategy:         ${FRONTEND_STRATEGY}"
if [ "${DRY_RUN}" = true ]; then
    log_warn "DRY-RUN MODE ACTIVE: Infrastructure mutations will be simulated only."
fi

# Retrieve GCP Project Number to derive canonical default service account emails
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || echo "UNKNOWN")
CLOUD_BUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# =============================================================================
# Phase 1 of 5: Enable Required Google Cloud Service APIs
# =============================================================================
log_header "Phase 1 / 5 — Enabling Required GCP Service APIs"

# Comprehensive list of foundation APIs required for serverless compute and CI/CD
REQUIRED_APIS=(
    "cloudbuild.googleapis.com"           # Automated container build worker engine
    "run.googleapis.com"                  # Serverless managed container orchestration
    "artifactregistry.googleapis.com"     # Next-generation secure OCI container repository
    "secretmanager.googleapis.com"        # Zero-trust credential and secret storage
    "compute.googleapis.com"              # Networking foundation for Cloud CDN / Load Balancer
    "cloudresourcemanager.googleapis.com" # Required for project metadata inspection
    "iam.googleapis.com"                  # Identity & Access Management API
)

# Append Firebase APIs if the user opted into the Firebase Hosting strategy
if [ "${FRONTEND_STRATEGY}" = "firebase" ]; then
    REQUIRED_APIS+=("firebase.googleapis.com" "firebasehosting.googleapis.com")
fi

# Idempotently check and activate each API
for api in "${REQUIRED_APIS[@]}"; do
    if gcloud services list --enabled --filter="config.name:${api}" --format="value(config.name)" 2>/dev/null | grep -q "${api}"; then
        log_success "Service API already active: ${api}"
    else
        log_info "Activating Service API: ${api}..."
        run_cmd "gcloud services enable '${api}' --quiet"
        log_success "Activated Service API: ${api}"
    fi
done

# =============================================================================
# Phase 2 of 5: Provision Google Artifact Registry Repository
# =============================================================================
log_header "Phase 2 / 5 — Provisioning Artifact Registry OCI Repository"

# Verify if the repository already exists to ensure idempotency
if gcloud artifacts repositories describe "${AR_REPO}" \
    --location="${REGION}" --format="value(name)" 2>/dev/null; then
    log_success "Artifact Registry repository '${AR_REPO}' already exists in region ${REGION}."
else
    log_info "Creating Artifact Registry repository '${AR_REPO}' (${REGION})..."
    run_cmd "gcloud artifacts repositories create '${AR_REPO}' \
        --repository-format=docker \
        --location='${REGION}' \
        --description='Production container images for ${SERVICE_NAME}' \
        --quiet"
    log_success "Artifact Registry repository successfully provisioned."
fi

# Configure Docker credentials helper to seamlessly push to Artifact Registry
log_info "Configuring Docker authentication helper for host: ${AR_HOSTNAME}..."
run_cmd "gcloud auth configure-docker '${AR_HOSTNAME}' --quiet"
log_success "Docker authentication configured."

# =============================================================================
# Phase 3 of 5: Configure Least-Privilege IAM Security Permissions
# =============================================================================
log_header "Phase 3 / 5 — Configuring IAM Service Account Permissions"

# To allow Google Cloud Build to deploy directly to Cloud Run and pull secrets,
# we federate the required roles to the Cloud Build and Compute service accounts.
IAM_BINDINGS=(
    "${CLOUD_BUILD_SA}:roles/run.admin:Cloud Build → Manage Cloud Run Services"
    "${CLOUD_BUILD_SA}:roles/iam.serviceAccountUser:Cloud Build → Act as Service Account"
    "${CLOUD_BUILD_SA}:roles/artifactregistry.writer:Cloud Build → Push Container Images"
    "${CLOUD_BUILD_SA}:roles/secretmanager.secretAccessor:Cloud Build → Access Secrets"
    "${COMPUTE_SA}:roles/secretmanager.secretAccessor:Compute Default SA → Runtime Secrets Access"
)

for binding in "${IAM_BINDINGS[@]}"; do
    IFS=':' read -r sa role desc <<< "${binding}"
    log_info "Granting policy binding: ${desc}..."
    run_cmd "gcloud projects add-iam-policy-binding '${PROJECT_ID}' \
        --member='serviceAccount:${sa}' \
        --role='${role}' \
        --condition=None \
        --quiet >/dev/null 2>&1"
    log_success "Verified IAM role: ${role}"
done

# =============================================================================
# Phase 4 of 5: Backend Build & Cloud Run Rollout
# =============================================================================
log_header "Phase 4 / 5 — Backend Build & Serverless Rollout"

if [ "${SKIP_BACKEND}" = true ]; then
    log_warn "Backend deployment stage bypassed via '--skip-backend' flag."
elif [ "${SKIP_BUILD}" = true ]; then
    log_warn "Compilation bypassed via '--skip-build'. Re-deploying existing latest image tag."

    run_cmd "gcloud run deploy '${SERVICE_NAME}' \
        --image='${IMAGE_URI}:latest' \
        --region='${REGION}' \
        --platform=managed \
        --allow-unauthenticated \
        --min-instances=0 \
        --max-instances=10 \
        --memory=512Mi \
        --cpu=1 \
        --port=8080 \
        --set-env-vars='NODE_ENV=production,LOG_LEVEL=info' \
        --quiet"
    log_success "Cloud Run service revision rolled out from latest image."
else
    # Submit source to Cloud Build for remote container compilation
    log_info "Submitting build context to Google Cloud Build..."

    # Formulate a unique immutable timestamp tag
    BUILD_TAG="release-$(date +%Y%m%d-%H%M%S)"

    run_cmd "gcloud builds submit '${BACKEND_DIR}' \
        --tag='${IMAGE_URI}:${BUILD_TAG}' \
        --timeout=600s \
        --quiet"
    log_success "Container image compiled and pushed: ${IMAGE_URI}:${BUILD_TAG}"

    # Re-tag as latest for operational reference
    run_cmd "gcloud artifacts docker tags add \
        '${IMAGE_URI}:${BUILD_TAG}' \
        '${IMAGE_URI}:latest' \
        --quiet 2>/dev/null" || log_warn "Notice: Secondary 'latest' tag assignment skipped."

    # Deploy the immutable tag to Cloud Run
    log_info "Rolling out revision on Cloud Run..."
    run_cmd "gcloud run deploy '${SERVICE_NAME}' \
        --image='${IMAGE_URI}:${BUILD_TAG}' \
        --region='${REGION}' \
        --platform=managed \
        --allow-unauthenticated \
        --min-instances=0 \
        --max-instances=10 \
        --memory=512Mi \
        --cpu=1 \
        --concurrency=80 \
        --port=8080 \
        --set-env-vars='NODE_ENV=production,LOG_LEVEL=info' \
        --quiet"
    log_success "Cloud Run revision active and serving ingress traffic."

    # Query public HTTPS endpoint
    SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
        --region="${REGION}" \
        --format='value(status.url)' 2>/dev/null || echo "Endpoint pending...")
    log_info "Backend Public Ingress Endpoint: ${SERVICE_URL}"
fi

# =============================================================================
# Phase 5 of 5: Frontend Build & Asset Deployment
# =============================================================================
log_header "Phase 5 / 5 — Frontend Build & Asset Deployment"

if [ "${SKIP_FRONTEND}" = true ]; then
    log_warn "Frontend deployment stage bypassed via '--skip-frontend' flag."
else
    # Compile the Angular frontend application
    if [ ! "${SKIP_BUILD}" = true ]; then
        log_info "Compiling Angular production distribution package..."
        if [ -f "${FRONTEND_DIR}/package.json" ]; then
            run_cmd "cd '${FRONTEND_DIR}' && npm ci && npm run build -- --configuration=production"
            log_success "Angular production compilation complete."
        else
            log_warn "Package manifest not found in ${FRONTEND_DIR}. Skipping npm build."
        fi
    fi

    # Strategy Branch A: Firebase Hosting (Recommended for Single-Page Apps)
    if [ "${FRONTEND_STRATEGY}" = "firebase" ]; then
        log_step "Deploying Assets to Firebase Hosting"

        # Check for Firebase CLI availability
        if ! command -v firebase &>/dev/null; then
            log_info "Installing Firebase CLI tools..."
            run_cmd "npm install -g firebase-tools"
        fi

        run_cmd "cd '${FRONTEND_DIR}' && firebase deploy --only hosting --project '${PROJECT_ID}'"
        log_success "Frontend assets deployed to Firebase Hosting CDN."

    # Strategy Branch B: Google Cloud Storage (GCS) + Cloud CDN
    elif [ "${FRONTEND_STRATEGY}" = "gcs" ]; then
        log_step "Deploying Assets to Google Cloud Storage (Static Website)"

        # Idempotently verify or provision static storage bucket
        if gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null 2>&1; then
            log_success "Target storage bucket gs://${BUCKET_NAME} already exists."
        else
            log_info "Provisioning static hosting bucket: gs://${BUCKET_NAME}..."
            run_cmd "gcloud storage buckets create 'gs://${BUCKET_NAME}' \
                --location='${REGION}' \
                --uniform-bucket-level-access \
                --public-access-prevention=inherited \
                --quiet"

            # Authorize anonymous read access for public website delivery
            run_cmd "gcloud storage buckets add-iam-policy-binding 'gs://${BUCKET_NAME}' \
                --member='allUsers' \
                --role='roles/storage.objectViewer' \
                --quiet"

            # Configure SPA fallback index routing
            run_cmd "gcloud storage buckets update 'gs://${BUCKET_NAME}' \
                --web-main-page-suffix='index.html' \
                --web-error-page='index.html' \
                --quiet"

            log_success "Storage bucket provisioned and configured for static website hosting."
        fi

        # Synchronize build artifacts with differential HTTP caching headers
        DIST_DIR="${FRONTEND_DIR}/dist/frontend/browser"
        if [ -d "${DIST_DIR}" ]; then
            log_info "Uploading compiled assets to gs://${BUCKET_NAME}..."
            run_cmd "gcloud storage rsync '${DIST_DIR}' 'gs://${BUCKET_NAME}' \
                --recursive \
                --delete-unmatched-destination-objects \
                --cache-control='public, max-age=3600' \
                --quiet"

            # Cache Strategy: Set 1-year immutable cache on fingerprint-hashed assets
            run_cmd "gcloud storage objects update 'gs://${BUCKET_NAME}/**/*.js' \
                --cache-control='public, max-age=31536000, immutable' \
                --quiet 2>/dev/null" || true
            run_cmd "gcloud storage objects update 'gs://${BUCKET_NAME}/**/*.css' \
                --cache-control='public, max-age=31536000, immutable' \
                --quiet 2>/dev/null" || true

            # Cache Strategy: Explicitly forbid caching on index.html to guarantee instantaneous rollouts
            run_cmd "gcloud storage objects update 'gs://${BUCKET_NAME}/index.html' \
                --cache-control='no-cache, no-store, must-revalidate' \
                --quiet"

            log_success "Frontend assets uploaded with optimized cache control headers."
        else
            log_warn "Compiled directory '${DIST_DIR}' not detected. Ensure frontend build completes successfully."
        fi
    else
        log_error "Unsupported frontend strategy: ${FRONTEND_STRATEGY}. Permitted values: 'firebase' or 'gcs'."
        exit 1
    fi
fi

# =============================================================================
# Deployment Summary & Observability Dashboard
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║${NC}  ${GREEN}✔  Full-Stack Deployment Pipeline Complete${NC}                  ${BOLD}║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}                                                              ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  ${CYAN}GCP Project:${NC}      ${PROJECT_ID}"
echo -e "${BOLD}║${NC}  ${CYAN}Compute Region:${NC}   ${REGION}"

if [ "${SKIP_BACKEND}" != true ]; then
    FINAL_URL=$(gcloud run services describe "${SERVICE_NAME}" \
        --region="${REGION}" \
        --format='value(status.url)' 2>/dev/null || echo "Endpoint pending")
    echo -e "${BOLD}║${NC}  ${CYAN}Backend URL:${NC}      ${FINAL_URL}"
fi

if [ "${SKIP_FRONTEND}" != true ]; then
    if [ "${FRONTEND_STRATEGY}" = "firebase" ]; then
        echo -e "${BOLD}║${NC}  ${CYAN}Frontend URL:${NC}     Firebase Hosting (run 'firebase open hosting:site')"
    else
        echo -e "${BOLD}║${NC}  ${CYAN}Frontend URL:${NC}     gs://${BUCKET_NAME}"
    fi
fi

echo -e "${BOLD}║${NC}  ${CYAN}Image Registry:${NC}   ${IMAGE_URI}"
echo -e "${BOLD}║${NC}                                                              ${BOLD}║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  ${YELLOW}Recommended Next Steps:${NC}                                     ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  1. Connect GitHub repository to Cloud Build triggers         ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  2. Populate Secret Manager credentials for production        ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  3. Map Custom Domain & provision Google-managed SSL cert     ${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  4. Configure Cloud Monitoring alerts for error budget SLA    ${BOLD}║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
