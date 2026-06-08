#!/bin/bash
set -euo pipefail

#
# ZTWIM Simple Demo — Full Deployment Script
#
# Deploys the mTLS-based SPIFFE/SPIRE workload identity demo on OpenShift.
# Includes SPIRE infrastructure (shared) and demo workloads.
#
# Prerequisites:
#   - oc CLI logged in as cluster-admin
#   - Zero Trust Workload Identity Manager operator installed from OperatorHub
#
# Usage:
#   ./deploy.sh
#
# All cluster-specific values are auto-detected. Override with environment
# variables if needed (see "Configurable variables" below).
#

# ─── Configurable variables ──────────────────────────────────────────────────

# Auto-detect cluster apps domain from OpenShift ingress config
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"
if [ -z "$CLUSTER_DOMAIN" ]; then
  echo "ERROR: Could not detect cluster domain. Set CLUSTER_DOMAIN manually."
  exit 1
fi

TRUST_DOMAIN="${TRUST_DOMAIN:-idc.com}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-ztwim-simple}"
SPIRE_NAMESPACE="${SPIRE_NAMESPACE:-zero-trust-workload-identity-manager}"
IMAGE_NAME="${IMAGE_NAME:-ztwim-simple}"
SPIRE_OIDC_HOST="spire-oidc.${CLUSTER_DOMAIN}"

# Set IMAGE_REGISTRY to use pre-built images from an external registry (e.g., quay.io/tssc_demos)
# When unset, images are built in-cluster using oc new-build.
IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
if [ -n "$IMAGE_REGISTRY" ]; then
  FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
else
  FULL_IMAGE="image-registry.openshift-image-registry.svc:5000/${DEMO_NAMESPACE}/${IMAGE_NAME}:latest"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Helper functions ────────────────────────────────────────────────────────

log()  { echo ">>> $*"; }
wait_for_pods() {
  local ns="$1" label="$2" expected="$3" timeout="${4:-300}"
  log "Waiting for $expected pod(s) in $ns ($label)..."
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local running
    running=$(oc get pods -n "$ns" -l "$label" --no-headers 2>/dev/null \
      | grep -v Terminating | grep -v Completed | grep Running | wc -l || echo 0)
    if [ "$running" -ge "$expected" ]; then
      log "  $running/$expected pods running."
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "ERROR: Timed out waiting for pods in $ns ($label)"
  oc get pods -n "$ns" -l "$label" --no-headers 2>&1
  exit 1
}

# ─── Step 1: Update cluster-specific values in YAML files ────────────────────

log "Cluster domain: $CLUSTER_DOMAIN"
log "Trust domain:   $TRUST_DOMAIN"
log "Demo namespace: $DEMO_NAMESPACE"
log "SPIRE OIDC:     https://$SPIRE_OIDC_HOST"

log "Updating cluster-specific values in manifests..."

# SpireServer jwtIssuer
sed -i "s|jwtIssuer:.*|jwtIssuer: \"https://${SPIRE_OIDC_HOST}\"|" \
  "$SCRIPT_DIR/infra/spire-server.yaml" \
  "$SCRIPT_DIR/infra/spire-oidc-discovery.yaml"

# ZeroTrustWorkloadIdentityManager trust domain
sed -i "s|trustDomain:.*|trustDomain: \"${TRUST_DOMAIN}\"|" \
  "$SCRIPT_DIR/infra/ztwim.yaml"

# ClusterSPIFFEID template
sed -i "s|spiffeIDTemplate:.*|spiffeIDTemplate: \"spiffe://${TRUST_DOMAIN}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}\"|" \
  "$SCRIPT_DIR/app/cluster-spiffeid.yaml"

# Namespace references in all app manifests
for f in "$SCRIPT_DIR"/app/*.yaml; do
  sed -i "s|namespace: ztwim-simple|namespace: ${DEMO_NAMESPACE}|g" "$f"
done
sed -i "s|name: ztwim-simple$|name: ${DEMO_NAMESPACE}|" "$SCRIPT_DIR/app/namespace.yaml"

# Image references
for f in "$SCRIPT_DIR"/app/data-service.yaml "$SCRIPT_DIR"/app/consumer.yaml "$SCRIPT_DIR"/app/consumer-unauthorized.yaml; do
  sed -i "s|image: .*ztwim-simple:.*|image: ${FULL_IMAGE}|g" "$f"
  sed -i "s|image: image-registry.openshift-image-registry.svc:5000/[^/]*/[^:]*:.*|image: ${FULL_IMAGE}|g" "$f"
  sed -i "s|image: quay.io/[^/]*/ztwim-simple:.*|image: ${FULL_IMAGE}|g" "$f"
done

# Data service URL in consumers
for f in "$SCRIPT_DIR"/app/consumer.yaml "$SCRIPT_DIR"/app/consumer-unauthorized.yaml; do
  sed -i "s|data-service\.[^.]*\.svc|data-service.${DEMO_NAMESPACE}.svc|g" "$f"
done

# Allowed SPIFFE IDs in data-service
sed -i "s|spiffe://[^/]*/ns/[^/]*/sa/consumer\"|spiffe://${TRUST_DOMAIN}/ns/${DEMO_NAMESPACE}/sa/consumer\"|" \
  "$SCRIPT_DIR/app/data-service.yaml"

log "Manifests updated."

# ─── Step 2: Deploy SPIRE infrastructure ─────────────────────────────────────

log "Deploying SPIRE infrastructure..."

oc apply -f "$SCRIPT_DIR/infra/ztwim.yaml"
oc apply -f "$SCRIPT_DIR/infra/spire-server.yaml"
oc apply -f "$SCRIPT_DIR/infra/spire-agent.yaml"
oc apply -f "$SCRIPT_DIR/infra/spiffe-csi-driver.yaml"
oc apply -f "$SCRIPT_DIR/infra/spire-oidc-discovery.yaml"

log "Waiting for SPIRE components..."
local_timeout=0
while [ $local_timeout -lt 300 ]; do
  STATUS=$(oc get zerotrustworkloadidentitymanager cluster -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || echo "")
  if [ "$STATUS" = "All components are ready" ]; then
    log "SPIRE infrastructure ready: $STATUS"
    break
  fi
  sleep 10
  local_timeout=$((local_timeout + 10))
done

if [ "$STATUS" != "All components are ready" ]; then
  log "WARNING: SPIRE not fully ready yet (status: $STATUS). Continuing anyway..."
  log "Check: oc get pods -n $SPIRE_NAMESPACE"
fi

# ─── Step 3: Create demo namespace and identity assignments ──────────────────

log "Creating demo namespace and identity assignments..."

oc apply -f "$SCRIPT_DIR/app/namespace.yaml"
oc apply -f "$SCRIPT_DIR/app/service-accounts.yaml"
oc apply -f "$SCRIPT_DIR/app/cluster-spiffeid.yaml"
oc apply -f "$SCRIPT_DIR/app/spiffe-helper-config.yaml"

# ─── Step 4: Build the container image ───────────────────────────────────────

if [ -n "$IMAGE_REGISTRY" ]; then
  log "Using pre-built image: $FULL_IMAGE"
  log "  (skipping in-cluster build)"
else
  log "Building container image in-cluster..."
  cp "$SCRIPT_DIR/src/Containerfile" "$SCRIPT_DIR/src/Dockerfile"

  if oc get buildconfig "$IMAGE_NAME" -n "$DEMO_NAMESPACE" &>/dev/null; then
    log "  BuildConfig already exists, starting new build..."
  else
    oc new-build --binary --name="$IMAGE_NAME" -n "$DEMO_NAMESPACE" --strategy=docker
  fi

  oc start-build "$IMAGE_NAME" --from-dir="$SCRIPT_DIR/src/" -n "$DEMO_NAMESPACE" --follow
fi

# ─── Step 5: Deploy workloads ────────────────────────────────────────────────

log "Deploying workloads..."

oc apply -f "$SCRIPT_DIR/app/data-service.yaml"
oc apply -f "$SCRIPT_DIR/app/consumer.yaml"
oc apply -f "$SCRIPT_DIR/app/consumer-unauthorized.yaml"

wait_for_pods "$DEMO_NAMESPACE" "app=data-service" 1
wait_for_pods "$DEMO_NAMESPACE" "app=consumer" 1
wait_for_pods "$DEMO_NAMESPACE" "app=consumer-unauthorized" 1

# ─── Step 6: Print results ───────────────────────────────────────────────────

echo ""
log "=========================================="
log "  ZTWIM Simple Demo — Deployment Complete"
log "=========================================="
echo ""

CONSUMER_URL=$(oc get route consumer -n "$DEMO_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
UNAUTH_URL=$(oc get route consumer-unauthorized -n "$DEMO_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)

log "Dashboards:"
log "  Authorized:   https://$CONSUMER_URL"
log "  Unauthorized: https://$UNAUTH_URL"
echo ""
log "Logs:"
log "  oc logs -n $DEMO_NAMESPACE deploy/data-service -c data-service -f"
log "  oc logs -n $DEMO_NAMESPACE deploy/consumer -c consumer -f"
log "  oc logs -n $DEMO_NAMESPACE deploy/consumer-unauthorized -c consumer -f"
echo ""

# Quick verification
sleep 5
AUTH_STATUS=$(curl -sk "https://$CONSUMER_URL/api/status" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_result',{}).get('body',{}).get('authorized','pending'))" 2>/dev/null || echo "pending")
UNAUTH_STATUS=$(curl -sk "https://$UNAUTH_URL/api/status" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_result',{}).get('body',{}).get('authorized','pending'))" 2>/dev/null || echo "pending")

log "Verification:"
log "  Authorized consumer:   $AUTH_STATUS (expected: True)"
log "  Unauthorized consumer: $UNAUTH_STATUS (expected: False)"
