#!/bin/bash
#
# Deploy SNAT Heartbeat Dashboard to OpenShift
# Builds container image, pushes to registry, and deploys to cluster
#

set -euo pipefail

# Configuration
REGISTRY="quay.signal9.gg"
IMAGE_NAME="aaustin/snat-test-dashboard"
IMAGE_TAG="latest"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

OPENSHIFT_API="api.lab-hub.lab.signal9.gg:6443"
NAMESPACE="snat-test"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_SERVICE_DIR="${SCRIPT_DIR}/web-service"
K8S_DIR="${SCRIPT_DIR}/k8s"

echo "=== SNAT Heartbeat Dashboard Deployment ==="
echo ""

# Step 1: Build container image
echo "----------------------------------------"
echo "Step 1: Building container image"
echo "----------------------------------------"
cd "$WEB_SERVICE_DIR"
podman build -t "$FULL_IMAGE" .
echo "Image built: $FULL_IMAGE"
echo ""

# Step 2: Push to registry
echo "----------------------------------------"
echo "Step 2: Pushing image to registry"
echo "----------------------------------------"
podman push "$FULL_IMAGE"
echo "Image pushed: $FULL_IMAGE"
echo ""

# Step 3: Login to OpenShift (if not already logged in)
echo "----------------------------------------"
echo "Step 3: Verifying OpenShift connection"
echo "----------------------------------------"
if ! oc whoami &>/dev/null; then
    echo "Not logged in to OpenShift. Please login:"
    oc login "$OPENSHIFT_API"
fi
echo "Logged in as: $(oc whoami)"
echo "Cluster: $(oc whoami --show-server)"
echo ""

# Step 4: Create namespace if it doesn't exist
echo "----------------------------------------"
echo "Step 4: Ensuring namespace exists"
echo "----------------------------------------"
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    echo "Creating namespace: $NAMESPACE"
    oc create namespace "$NAMESPACE"
else
    echo "Namespace already exists: $NAMESPACE"
fi
echo ""

# Step 5: Apply Kubernetes manifests
echo "----------------------------------------"
echo "Step 5: Deploying application"
echo "----------------------------------------"
oc apply -f "${K8S_DIR}/deployment.yaml"
oc apply -f "${K8S_DIR}/service.yaml"
oc apply -f "${K8S_DIR}/route.yaml"
echo ""

# Step 6: Wait for rollout
echo "----------------------------------------"
echo "Step 6: Waiting for deployment rollout"
echo "----------------------------------------"
oc rollout status deployment/snat-heartbeat-dashboard -n "$NAMESPACE" --timeout=120s
echo ""

# Step 7: Display status
echo "----------------------------------------"
echo "Deployment Complete!"
echo "----------------------------------------"
echo ""
echo "Dashboard URL: https://snat-heartbeat.apps.lab-hub.lab.signal9.gg"
echo ""
echo "Pod status:"
oc get pods -n "$NAMESPACE" -l app=snat-heartbeat-dashboard
echo ""
echo "Route:"
oc get route -n "$NAMESPACE" snat-heartbeat-dashboard
