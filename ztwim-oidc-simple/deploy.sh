#!/bin/bash
set -euo pipefail

#
# ZTWIM OIDC-Simple Demo — Full Deployment Script
#
# Deploys a self-contained OIDC demo where workloads authenticate to a
# data-service using JWT-SVIDs validated against SPIRE's JWKS.
# No Keycloak, no TPA, no external dependencies.
#
# Prerequisites:
#   - oc CLI logged in as cluster-admin
#   - SPIRE infrastructure deployed (run ztwim-simple/deploy.sh first)
#
# Usage:
#   ./deploy.sh
#

# ─── Configurable variables ──────────────────────────────────────────────────

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"
if [ -z "$CLUSTER_DOMAIN" ]; then
  echo "ERROR: Could not detect cluster domain. Set CLUSTER_DOMAIN manually."
  exit 1
fi

TRUST_DOMAIN="${TRUST_DOMAIN:-idc.com}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-ztwim-oidc-simple}"
IMAGE_NAME="${IMAGE_NAME:-ztwim-oidc-simple}"
SPIRE_OIDC_HOST="spire-oidc.${CLUSTER_DOMAIN}"

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
warn() { echo "WARNING: $*"; }

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

# ─── Preflight checks ───────────────────────────────────────────────────────

log "Cluster domain:  $CLUSTER_DOMAIN"
log "Trust domain:    $TRUST_DOMAIN"
log "Demo namespace:  $DEMO_NAMESPACE"
log "SPIRE OIDC JWKS: https://$SPIRE_OIDC_HOST/keys"
log "Image:           $FULL_IMAGE"

SPIRE_STATUS=$(oc get zerotrustworkloadidentitymanager cluster -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || echo "not found")
if [ "$SPIRE_STATUS" != "All components are ready" ]; then
  echo "ERROR: SPIRE infrastructure is not ready (status: $SPIRE_STATUS)"
  echo "       Deploy SPIRE first: cd ../ztwim-simple && ./deploy.sh"
  exit 1
fi
log "SPIRE infrastructure: ready"

# ─── Step 1: Update cluster-specific values in manifests ─────────────────────

log "Step 1: Updating cluster-specific values in manifests..."

# JWKS URL in data-service
sed -i "s|value: \"https://spire-oidc\.[^\"]*\"|value: \"https://${SPIRE_OIDC_HOST}/keys\"|" \
  "$SCRIPT_DIR/app/data-service.yaml"

# Allowed SPIFFE IDs
sed -i "s|spiffe://[^/]*/ns/[^/]*/sa/oidc-consumer\"|spiffe://${TRUST_DOMAIN}/ns/${DEMO_NAMESPACE}/sa/oidc-consumer\"|" \
  "$SCRIPT_DIR/app/data-service.yaml"

# Data service URL in consumers
for f in "$SCRIPT_DIR"/app/consumer.yaml "$SCRIPT_DIR"/app/consumer-unauthorized.yaml; do
  sed -i "s|data-service\.[^.]*\.svc|data-service.${DEMO_NAMESPACE}.svc|g" "$f"
done

# Image references
for f in "$SCRIPT_DIR"/app/data-service.yaml "$SCRIPT_DIR"/app/consumer.yaml "$SCRIPT_DIR"/app/consumer-unauthorized.yaml; do
  sed -i "s|image: .*ztwim-oidc-simple:.*|image: ${FULL_IMAGE}|g" "$f"
  sed -i "s|image: image-registry.openshift-image-registry.svc:5000/[^/]*/[^:]*:.*|image: ${FULL_IMAGE}|g" "$f"
  sed -i "s|image: quay.io/[^/]*/ztwim-oidc-simple:.*|image: ${FULL_IMAGE}|g" "$f"
done

# Namespace references
for f in "$SCRIPT_DIR"/app/*.yaml; do
  sed -i "s|namespace: ztwim-oidc-simple|namespace: ${DEMO_NAMESPACE}|g" "$f"
done
sed -i "s|name: ztwim-oidc-simple$|name: ${DEMO_NAMESPACE}|" "$SCRIPT_DIR/app/namespace.yaml"

log "  Manifests updated."

# ─── Step 2: Create namespace and identity assignments ───────────────────────

log "Step 2: Creating namespace and identity assignments..."

oc apply -f "$SCRIPT_DIR/app/namespace.yaml"
oc apply -f "$SCRIPT_DIR/app/service-accounts.yaml"
oc apply -f "$SCRIPT_DIR/app/spiffe-helper-config.yaml"

# ─── Step 3: Build or pull container image ───────────────────────────────────

if [ -n "$IMAGE_REGISTRY" ]; then
  log "Step 3: Using pre-built image: $FULL_IMAGE"
  log "  (skipping in-cluster build)"
else
  log "Step 3: Building container image in-cluster..."
  cp "$SCRIPT_DIR/src/Containerfile" "$SCRIPT_DIR/src/Dockerfile"

  if oc get buildconfig "$IMAGE_NAME" -n "$DEMO_NAMESPACE" &>/dev/null; then
    log "  BuildConfig already exists, starting new build..."
  else
    oc new-build --binary --name="$IMAGE_NAME" -n "$DEMO_NAMESPACE" --strategy=docker
  fi

  oc start-build "$IMAGE_NAME" --from-dir="$SCRIPT_DIR/src/" -n "$DEMO_NAMESPACE" --follow
fi

# ─── Step 4: Deploy workloads ────────────────────────────────────────────────

log "Step 4: Deploying workloads..."

oc apply -f "$SCRIPT_DIR/app/data-service.yaml"
oc apply -f "$SCRIPT_DIR/app/consumer.yaml"
oc apply -f "$SCRIPT_DIR/app/consumer-unauthorized.yaml"

wait_for_pods "$DEMO_NAMESPACE" "app=data-service" 1
wait_for_pods "$DEMO_NAMESPACE" "app=consumer" 1
wait_for_pods "$DEMO_NAMESPACE" "app=consumer-unauthorized" 1

# ─── Step 5: Print results ───────────────────────────────────────────────────

echo ""
log "=========================================="
log "  ZTWIM OIDC-Simple Demo — Deployment Complete"
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

sleep 5
AUTH_STATUS=$(curl -sk "https://$CONSUMER_URL/api/status" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_result',{}).get('body',{}).get('authorized','pending'))" 2>/dev/null || echo "pending")
UNAUTH_STATUS=$(curl -sk "https://$UNAUTH_URL/api/status" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_result',{}).get('body',{}).get('authorized','pending'))" 2>/dev/null || echo "pending")

log "Verification:"
log "  Authorized consumer:   $AUTH_STATUS (expected: True)"
log "  Unauthorized consumer: $UNAUTH_STATUS (expected: False)"
