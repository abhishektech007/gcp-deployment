#!/bin/bash
# =============================================================================
# SCRIPT: deploy-backend.sh
# PURPOSE: Direct / Standalone Backend Service Deployment to Google Cloud Run
# TARGET ARCHITECTURE: Serverless Microservices on Google Cloud Platform
# =============================================================================
#
# OVERVIEW FOR THE READER:
#   This lightweight script provides an ad-hoc deployment path for the backend
#   container directly from a developer workstation or build machine.
#   It executes three fundamental cloud deployment stages:
#
#     1. Container Build: Compiles the source code into an optimized Docker image
#        using the local Docker daemon.
#     2. Registry Push: Authenticates with Google Container Registry (GCR) and
#        uploads the image so Cloud Run can access it.
#     3. Cloud Run Deploy: Spins up or updates the managed Cloud Run service
#        with the newly pushed container image.
#
# WHEN TO USE THIS SCRIPT:
#   - Fast developer iteration during local testing or staging experiments.
#   - Rapid manual rollouts when a full CI/CD pipeline (e.g. Cloud Build) is not needed.
#   - For full automated production deployments with tests and IAM provisioning,
#     refer to 'cloudbuild.yaml' or the master 'deploy.sh' in the root directory.
#
# PREREQUISITES:
#   - Google Cloud SDK (gcloud CLI) installed and authenticated (`gcloud auth login`).
#   - Docker Engine installed and running locally.
#   - Target GCP project must have Cloud Run and Container Registry APIs enabled.
#
# ENVIRONMENT VARIABLES:
#   GCP_PROJECT_ID  - Your target GCP project ID (defaults to placeholder below).
#   GCP_REGION      - The Google Cloud region for deployment (defaults to us-central1).
#
# USAGE:
#   chmod +x deploy-backend.sh
#   GCP_PROJECT_ID="your-project-id" ./deploy-backend.sh
# =============================================================================

# Stop script execution immediately if any command fails (-e)
set -e

# -----------------------------------------------------------------------------
# Configuration: Project ID, Target Region, Service & Container Names
# -----------------------------------------------------------------------------
# Resolve the target GCP Project ID:
# Reads from the $GCP_PROJECT_ID environment variable if provided, otherwise falls
# back to the specified placeholder string.
PROJECT_ID=${GCP_PROJECT_ID:-"your-gcp-project-id"}

# The geographic region where the Cloud Run container will physically execute.
# 'us-central1' (Iowa) is the default; you can change this to any valid GCP region
# such as 'us-east1', 'europe-west1', or 'asia-east1'.
REGION=${GCP_REGION:-"us-central1"}

# The unique service name that will identify this backend API in Google Cloud Run.
SERVICE_NAME="backend-service"

# The fully-qualified container image URI pointing to Google Container Registry (GCR).
# Note: In modern GCP setups, Google Artifact Registry is also supported using:
#   "${REGION}-docker.pkg.dev/${PROJECT_ID}/docker-repo/${SERVICE_NAME}"
IMAGE_NAME="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"

# -----------------------------------------------------------------------------
# Stage 1: Build the Container Image
# -----------------------------------------------------------------------------
# Builds a Docker image using the Dockerfile in the current directory ('.')
# and tags it with the target registry location ($IMAGE_NAME).
echo "==> Building Backend Container..."
docker build -t ${IMAGE_NAME} .

# -----------------------------------------------------------------------------
# Stage 2: Authenticate and Push Image to Google Container Registry
# -----------------------------------------------------------------------------
# Configures the local Docker client to use Google Cloud credentials for GCR.
# The '--quiet' flag prevents interactive confirmation prompts during automation.
echo "==> Pushing to Google Container Registry..."
gcloud auth configure-docker --quiet

# Uploads the compiled image layers to Google Container Registry storage.
docker push ${IMAGE_NAME}

# -----------------------------------------------------------------------------
# Stage 3: Deploy to Google Cloud Run
# -----------------------------------------------------------------------------
# Deploys the container to Cloud Run with the following production flags:
#   --image: Specifies the exact container image hosted in the registry.
#   --platform=managed: Directs deployment to Google's fully managed serverless
#     infrastructure (zero server maintenance, automatic scaling).
#   --region: Determines the physical datacenter region for low-latency delivery.
#   --allow-unauthenticated: Makes the HTTP API publicly reachable over the internet.
#     (Remove this flag if the API should only be accessible internally via IAM tokens).
echo "==> Deploying to Cloud Run..."
gcloud run deploy ${SERVICE_NAME} \
  --image=${IMAGE_NAME} \
  --platform=managed \
  --region=${REGION} \
  --allow-unauthenticated

# -----------------------------------------------------------------------------
# Deployment Complete
# -----------------------------------------------------------------------------
# Cloud Run prints the public HTTPS service URL upon completing the deploy above.
echo "==> Backend Deployment Complete!"