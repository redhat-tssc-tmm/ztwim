#!/bin/bash
set -euo pipefail

#
# ZTWIM OIDC Demo — Full Deployment Script
#
# Deploys the OIDC-based SPIFFE/SPIRE workload identity demo on OpenShift.
# Workloads use JWT-SVIDs, exchanged via Keycloak, to access Trusted Profile Analyzer.
#
# Prerequisites:
#   - oc CLI logged in as cluster-admin
#   - SPIRE infrastructure already deployed (run ztwim-simple/deploy.sh first)
#   - Keycloak (RHBK 24.x+) running on the cluster
#   - Trusted Profile Analyzer (TPA) running and authenticating via Keycloak
#
# Usage:
#   ./deploy.sh
#
# All cluster-specific values are auto-detected. Override with environment
# variables if needed (see "Configurable variables" below).
#

# ─── Configurable variables ──────────────────────────────────────────────────

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"
if [ -z "$CLUSTER_DOMAIN" ]; then
  echo "ERROR: Could not detect cluster domain. Set CLUSTER_DOMAIN manually."
  exit 1
fi

TRUST_DOMAIN="${TRUST_DOMAIN:-idc.com}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-ztwim-oidc}"
IMAGE_NAME="${IMAGE_NAME:-ztwim-oidc}"

# Keycloak configuration
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_CR_NAME="${KEYCLOAK_CR_NAME:-keycloak}"
KEYCLOAK_ADMIN_SECRET="${KEYCLOAK_ADMIN_SECRET:-keycloak-initial-admin}"
KEYCLOAK_ADMIN_USER_KEY="${KEYCLOAK_ADMIN_USER_KEY:-username}"
KEYCLOAK_ADMIN_PASS_KEY="${KEYCLOAK_ADMIN_PASS_KEY:-password}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-backstage}"

# TPA configuration
TPA_NAMESPACE="${TPA_NAMESPACE:-trusted-profile-analyzer}"
TPA_AUTH_CONFIGMAP="${TPA_AUTH_CONFIGMAP:-server-auth}"
TPA_SERVER_DEPLOYMENT="${TPA_SERVER_DEPLOYMENT:-server}"

# Auto-detect URLs from routes
KEYCLOAK_HOST="${KEYCLOAK_HOST:-$(oc get route -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")}"
KEYCLOAK_URL="https://${KEYCLOAK_HOST}"
TPA_HOST="${TPA_HOST:-$(oc get route -n "$TPA_NAMESPACE" -l app.kubernetes.io/name=server -o jsonpath='{.items[0].spec.host}' 2>/dev/null || oc get route -n "$TPA_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")}"
TPA_URL="https://${TPA_HOST}"

# SPIRE OIDC
SPIRE_OIDC_HOST="spire-oidc.${CLUSTER_DOMAIN}"
SPIRE_OIDC_URL="https://${SPIRE_OIDC_HOST}"
OIDC_PROXY_HOST="spire-oidc-proxy-${DEMO_NAMESPACE}.${CLUSTER_DOMAIN}"
OIDC_PROXY_URL="https://${OIDC_PROXY_HOST}"

# Keycloak client for SPIFFE consumers
KC_CLIENT_ID="${KC_CLIENT_ID:-spiffe-consumer}"

# ArgoCD namespace (for ignoreDifferences patches)
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Helper functions ────────────────────────────────────────────────────────

log()  { echo ">>> $*"; }
warn() { echo "WARNING: $*"; }

get_admin_token() {
  local admin_user admin_pass
  admin_user=$(oc get secret "$KEYCLOAK_ADMIN_SECRET" -n "$KEYCLOAK_NAMESPACE" -o jsonpath="{.data.${KEYCLOAK_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d)
  admin_pass=$(oc get secret "$KEYCLOAK_ADMIN_SECRET" -n "$KEYCLOAK_NAMESPACE" -o jsonpath="{.data.${KEYCLOAK_ADMIN_PASS_KEY}}" 2>/dev/null | base64 -d)
  curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli&username=${admin_user}&password=${admin_pass}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

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
log "Keycloak:        $KEYCLOAK_URL (namespace: $KEYCLOAK_NAMESPACE)"
log "TPA:             $TPA_URL (namespace: $TPA_NAMESPACE)"
log "SPIRE OIDC:      $SPIRE_OIDC_URL"
log "OIDC Proxy:      $OIDC_PROXY_URL"
echo ""

# Verify SPIRE is running
SPIRE_STATUS=$(oc get zerotrustworkloadidentitymanager cluster -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || echo "not found")
if [ "$SPIRE_STATUS" != "All components are ready" ]; then
  echo "ERROR: SPIRE infrastructure is not ready (status: $SPIRE_STATUS)"
  echo "       Deploy SPIRE first: cd ../ztwim-simple && ./deploy.sh"
  exit 1
fi
log "SPIRE infrastructure: ready"

# Verify Keycloak is reachable
if ! curl -sk "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
  echo "ERROR: Keycloak realm '${KEYCLOAK_REALM}' not reachable at ${KEYCLOAK_URL}"
  exit 1
fi
log "Keycloak realm '$KEYCLOAK_REALM': reachable"

# Verify TPA is running
if ! curl -sk "${TPA_URL}/.well-known/trustify" | grep -q "version"; then
  echo "ERROR: TPA not reachable at ${TPA_URL}"
  exit 1
fi
log "TPA: reachable"

# ─── Step 1: Enable Keycloak token exchange feature ──────────────────────────

log "Step 1: Enabling Keycloak token-exchange feature..."

# Check if already enabled
EXCHANGE_TEST=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange&subject_token=dummy&client_id=tpa-frontend" 2>&1)
if echo "$EXCHANGE_TEST" | grep -q "unsupported_grant_type"; then
  log "  Token exchange not enabled. Patching Keycloak CR..."

  # Tell ArgoCD to ignore Keycloak CR changes (if ArgoCD manages it)
  oc patch application "$KEYCLOAK_CR_NAME" -n "$ARGOCD_NAMESPACE" --type=json \
    -p '[{"op":"add","path":"/spec/ignoreDifferences","value":[
      {"group":"k8s.keycloak.org","kind":"Keycloak","name":"'"$KEYCLOAK_CR_NAME"'","namespace":"'"$KEYCLOAK_NAMESPACE"'",
       "jsonPointers":["/spec/additionalOptions","/spec/features"]}
    ]}]' 2>/dev/null || warn "Could not patch ArgoCD app (may not be managed by ArgoCD)"

  oc patch keycloak "$KEYCLOAK_CR_NAME" -n "$KEYCLOAK_NAMESPACE" --type=merge \
    -p '{"spec":{"additionalOptions":[{"name":"features","value":"token-exchange,admin-fine-grained-authz"}]}}'

  log "  Waiting for Keycloak to restart..."
  sleep 10
  wait_for_pods "$KEYCLOAK_NAMESPACE" "app=keycloak" 1 180

  # Verify
  EXCHANGE_TEST=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange&subject_token=dummy&client_id=tpa-frontend" 2>&1)
  if echo "$EXCHANGE_TEST" | grep -q "unsupported_grant_type"; then
    echo "ERROR: Token exchange still not enabled after restart"
    exit 1
  fi
fi
log "  Token exchange: enabled"

# ─── Step 2: Update cluster-specific values in manifests ─────────────────────

log "Step 2: Updating cluster-specific values in manifests..."

# OIDC proxy deployment
sed -i "s|value: \"https://spire-oidc\.[^\"]*\"|value: \"${SPIRE_OIDC_URL}\"|" "$SCRIPT_DIR/app/oidc-proxy.yaml"
sed -i "s|value: \"https://spire-oidc-proxy[^\"]*\"|value: \"${OIDC_PROXY_URL}\"|" "$SCRIPT_DIR/app/oidc-proxy.yaml"

# Consumer deployments — TPA URL
for f in "$SCRIPT_DIR"/app/oidc-consumer.yaml "$SCRIPT_DIR"/app/oidc-consumer-unauth.yaml; do
  sed -i "s|value: \"https://server-trusted-profile-analyzer\.[^\"]*\"|value: \"${TPA_URL}/api/v2/advisory?limit=5\"|" "$f"
  sed -i "s|value: \"https://sso\.[^\"]*\"|value: \"${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token\"|" "$f"
  sed -i "s|image-registry.openshift-image-registry.svc:5000/[^/]*/[^:]*:latest|image-registry.openshift-image-registry.svc:5000/${DEMO_NAMESPACE}/${IMAGE_NAME}:latest|g" "$f"
done

# OIDC proxy image reference
sed -i "s|image-registry.openshift-image-registry.svc:5000/[^/]*/[^:]*:latest|image-registry.openshift-image-registry.svc:5000/${DEMO_NAMESPACE}/${IMAGE_NAME}:latest|g" \
  "$SCRIPT_DIR/app/oidc-proxy.yaml"

log "  Manifests updated."

# ─── Step 3: Deploy namespace, SAs, configs ──────────────────────────────────

log "Step 3: Creating namespace and service accounts..."

oc apply -f "$SCRIPT_DIR/app/namespace.yaml"
oc apply -f "$SCRIPT_DIR/app/service-accounts.yaml"
oc apply -f "$SCRIPT_DIR/app/spiffe-helper-authorized.yaml"
oc apply -f "$SCRIPT_DIR/app/spiffe-helper-unauthorized.yaml"

# ─── Step 4: Build container image ───────────────────────────────────────────

log "Step 4: Building container image..."

cp "$SCRIPT_DIR/src/Containerfile" "$SCRIPT_DIR/src/Dockerfile"

if oc get buildconfig "$IMAGE_NAME" -n "$DEMO_NAMESPACE" &>/dev/null; then
  log "  BuildConfig already exists, starting new build..."
else
  oc new-build --binary --name="$IMAGE_NAME" -n "$DEMO_NAMESPACE" --strategy=docker
fi

oc start-build "$IMAGE_NAME" --from-dir="$SCRIPT_DIR/src/" -n "$DEMO_NAMESPACE" --follow

# ─── Step 5: Deploy OIDC proxy ───────────────────────────────────────────────

log "Step 5: Deploying OIDC discovery proxy..."

oc apply -f "$SCRIPT_DIR/app/oidc-proxy.yaml"
wait_for_pods "$DEMO_NAMESPACE" "app=oidc-proxy" 1

# Verify proxy is serving
sleep 5
if curl -sk "${OIDC_PROXY_URL}/.well-known/openid-configuration" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
  log "  OIDC proxy serving discovery document."
else
  echo "ERROR: OIDC proxy not serving at ${OIDC_PROXY_URL}"
  exit 1
fi

# ─── Step 6: Patch TPA auth configuration ────────────────────────────────────

log "Step 6: Patching TPA authentication configuration..."

# Tell ArgoCD to ignore TPA ConfigMap changes
oc patch application trusted-profile-analyzer -n "$ARGOCD_NAMESPACE" --type=json \
  -p '[{"op":"add","path":"/spec/ignoreDifferences","value":[
    {"group":"","kind":"ConfigMap","name":"'"$TPA_AUTH_CONFIGMAP"'","namespace":"'"$TPA_NAMESPACE"'",
     "jsonPointers":["/data/auth.yaml"]}
  ]}]' 2>/dev/null || warn "Could not patch ArgoCD app for TPA (may not be managed by ArgoCD)"

# Get current auth.yaml and check if spiffe-consumer already exists
CURRENT_AUTH=$(oc get configmap "$TPA_AUTH_CONFIGMAP" -n "$TPA_NAMESPACE" -o jsonpath='{.data.auth\.yaml}' 2>/dev/null)

if echo "$CURRENT_AUTH" | grep -q "$KC_CLIENT_ID"; then
  log "  TPA already has '$KC_CLIENT_ID' client configured. Skipping patch."
else
  log "  Adding '$KC_CLIENT_ID' client to TPA auth.yaml..."

  cat > /tmp/tpa-auth-patched.yaml <<AUTHEOF
${CURRENT_AUTH}

    - clientId: ${KC_CLIENT_ID}
      issuerUrl: ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}
      scopeMappings:
        "read:document": [ "read.advisory", "read.importer", "read.metadata", "read.sbom", "read.weakness", "read.systemInformation" ]
AUTHEOF

  oc create configmap "$TPA_AUTH_CONFIGMAP" -n "$TPA_NAMESPACE" \
    --from-file=auth.yaml=/tmp/tpa-auth-patched.yaml \
    --dry-run=client -o yaml | oc replace -f -

  oc rollout restart deploy/"$TPA_SERVER_DEPLOYMENT" -n "$TPA_NAMESPACE"
  log "  Waiting for TPA to restart..."
  sleep 10
  wait_for_pods "$TPA_NAMESPACE" "app.kubernetes.io/name=server" 1 120
fi

# ─── Step 7: Configure Keycloak (IDP, client, permissions) ──────────────────

log "Step 7: Configuring Keycloak..."

ADMIN_TOKEN=$(get_admin_token)

# 7a. Create SPIRE OIDC Identity Provider (if not exists)
IDP_EXISTS=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/identity-provider/instances/spire-oidc" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -w "%{http_code}" -o /dev/null 2>/dev/null)

if [ "$IDP_EXISTS" = "200" ]; then
  log "  Identity Provider 'spire-oidc' already exists. Updating..."
  HTTP_METHOD="PUT"
  IDP_URL="${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/identity-provider/instances/spire-oidc"
else
  log "  Creating Identity Provider 'spire-oidc'..."
  HTTP_METHOD="POST"
  IDP_URL="${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/identity-provider/instances"
fi

curl -sk -X "$HTTP_METHOD" "$IDP_URL" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "alias": "spire-oidc",
    "displayName": "SPIRE Workload Identity",
    "providerId": "oidc",
    "enabled": true,
    "trustEmail": true,
    "storeToken": true,
    "config": {
      "issuer": "'"${SPIRE_OIDC_URL}"'",
      "authorizationUrl": "'"${OIDC_PROXY_URL}/authorize"'",
      "tokenUrl": "'"${OIDC_PROXY_URL}/token"'",
      "userInfoUrl": "'"${OIDC_PROXY_URL}/userinfo"'",
      "jwksUrl": "'"${OIDC_PROXY_URL}/keys"'",
      "clientId": "spire-workload",
      "clientSecret": "not-used",
      "defaultScope": "openid",
      "validateSignature": "true",
      "useJwksUrl": "true",
      "disableUserInfo": "false"
    }
  }' > /dev/null
log "  Identity Provider configured."

# 7b. Enable IDP token exchange permissions
curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/identity-provider/instances/spire-oidc/management/permissions" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true}' > /tmp/kc-perm.json
PERM_ID=$(python3 -c "import json; print(json.load(open('/tmp/kc-perm.json'))['scopePermissions']['token-exchange'])")
log "  Token exchange permission enabled (ID: $PERM_ID)"

# 7c. Create spiffe-consumer client (if not exists)
ADMIN_TOKEN=$(get_admin_token)
CLIENT_EXISTS=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KC_CLIENT_ID}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$CLIENT_EXISTS" = "0" ]; then
  log "  Creating client '${KC_CLIENT_ID}'..."
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "'"${KC_CLIENT_ID}"'",
      "name": "SPIFFE Workload Consumer",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "serviceAccountsEnabled": true,
      "publicClient": false,
      "directAccessGrantsEnabled": false,
      "standardFlowEnabled": false,
      "protocol": "openid-connect"
    }' > /dev/null
else
  log "  Client '${KC_CLIENT_ID}' already exists."
fi

CLIENT_UUID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KC_CLIENT_ID}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
CLIENT_SECRET=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")
log "  Client UUID: $CLIENT_UUID"

# 7d. Add read:document scope to client
SCOPE_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/client-scopes" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "
import sys,json
for s in json.load(sys.stdin):
    if s['name'] == 'read:document':
        print(s['id']); break" 2>/dev/null || echo "")

if [ -n "$SCOPE_ID" ]; then
  curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/default-client-scopes/${SCOPE_ID}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" 2>/dev/null
  log "  Added 'read:document' scope to client."
else
  warn "  'read:document' scope not found in realm. TPA access may fail with 403."
fi

# 7e. Create token exchange policy
ADMIN_TOKEN=$(get_admin_token)
REALM_MGMT_UUID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=realm-management" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

POLICY_EXISTS=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/policy?name=spiffe-consumer-policy" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$POLICY_EXISTS" = "0" ]; then
  POLICY_ID=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/policy/client" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"spiffe-consumer-policy\",
      \"description\": \"Allow spiffe-consumer to exchange tokens via SPIRE IDP\",
      \"logic\": \"POSITIVE\",
      \"clients\": [\"${CLIENT_UUID}\"]
    }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  log "  Created token exchange policy (ID: $POLICY_ID)"
else
  POLICY_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/policy?name=spiffe-consumer-policy" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
  log "  Token exchange policy already exists (ID: $POLICY_ID)"
fi

# Always ensure the policy is associated with the token-exchange permission
PERM_NAME=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/permission/scope/${PERM_ID}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")

curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/permission/scope/${PERM_ID}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"id\": \"${PERM_ID}\",
    \"name\": \"${PERM_NAME}\",
    \"type\": \"scope\",
    \"logic\": \"POSITIVE\",
    \"decisionStrategy\": \"UNANIMOUS\",
    \"policies\": [\"${POLICY_ID}\"]
  }" > /dev/null
log "  Policy associated with token exchange permission."

# 7f. Create K8s Secret for client credentials
oc create secret generic spiffe-consumer-secret -n "$DEMO_NAMESPACE" \
  --from-literal=client-id="$KC_CLIENT_ID" \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | oc apply -f -
log "  K8s Secret 'spiffe-consumer-secret' created/updated."

# ─── Step 8: Deploy consumer workloads ───────────────────────────────────────

log "Step 8: Deploying consumer workloads..."

oc apply -f "$SCRIPT_DIR/app/oidc-consumer.yaml"
oc apply -f "$SCRIPT_DIR/app/oidc-consumer-unauth.yaml"

wait_for_pods "$DEMO_NAMESPACE" "app=oidc-consumer" 1
wait_for_pods "$DEMO_NAMESPACE" "app=oidc-consumer-unauth" 1

# ─── Step 9: Create SPIFFE users in Keycloak via initial token exchange ──────

log "Step 9: Triggering initial token exchange to create SPIFFE users..."
sleep 15

do_token_exchange() {
  local sa_name="$1"
  local pod
  pod=$(oc get pods -n "$DEMO_NAMESPACE" -l "app=${sa_name}" --no-headers 2>/dev/null \
    | grep Running | grep -v Terminating | head -1 | awk '{print $1}')
  if [ -z "$pod" ]; then
    warn "  $sa_name: pod not found"
    return 1
  fi
  local jwt
  jwt=$(oc exec -n "$DEMO_NAMESPACE" "$pod" -c consumer -- cat /certs/jwt_svid.token 2>/dev/null || echo "")
  if [ -z "$jwt" ]; then
    warn "  $sa_name: JWT-SVID not ready yet"
    return 1
  fi
  local result
  result=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "subject_token=$jwt" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "subject_issuer=spire-oidc" \
    -d "client_id=${KC_CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" 2>&1)
  local status
  status=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if 'access_token' in d else d.get('error','?'))" 2>/dev/null)
  log "  $sa_name: $status"
  [ "$status" = "OK" ]
}

for SA in oidc-consumer oidc-consumer-unauth; do
  do_token_exchange "$SA" || true
done

# ─── Step 10: Disable the unauthorized SPIFFE identity ───────────────────────

log "Step 10: Disabling unauthorized SPIFFE identity in Keycloak..."

# Search broadly and match precisely by username
ADMIN_TOKEN=$(get_admin_token)
UNAUTH_USER_ID=""
for attempt in 1 2 3; do
  UNAUTH_USER_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users?search=spiffe&max=50" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "
import sys,json
for u in json.load(sys.stdin):
    if u.get('username','').endswith('/sa/oidc-consumer-unauth'):
        print(u['id']); break" 2>/dev/null || echo "")

  if [ -n "$UNAUTH_USER_ID" ]; then
    break
  fi

  if [ "$attempt" -lt 3 ]; then
    log "  User not found yet (attempt $attempt/3), waiting 15s for Keycloak to create it..."
    sleep 15
    ADMIN_TOKEN=$(get_admin_token)
  fi
done

if [ -n "$UNAUTH_USER_ID" ]; then
  DISABLE_CODE=$(curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${UNAUTH_USER_ID}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"enabled": false}' -w "%{http_code}" -o /dev/null 2>&1)

  if [ "$DISABLE_CODE" = "204" ]; then
    log "  Disabled user $UNAUTH_USER_ID (HTTP $DISABLE_CODE)"
  else
    warn "  Failed to disable user $UNAUTH_USER_ID (HTTP $DISABLE_CODE)"
  fi

  # Verify it's actually disabled
  ADMIN_TOKEN=$(get_admin_token)
  IS_ENABLED=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${UNAUTH_USER_ID}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('enabled','?'))" 2>/dev/null)

  if [ "$IS_ENABLED" = "False" ]; then
    log "  Verified: user is DISABLED"
  else
    warn "  User is still enabled=$IS_ENABLED — disabling again..."
    ADMIN_TOKEN=$(get_admin_token)
    curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${UNAUTH_USER_ID}" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"enabled": false}' > /dev/null
  fi

  # Restart unauthorized consumer so it picks up the rejection
  oc rollout restart deploy/oidc-consumer-unauth -n "$DEMO_NAMESPACE"
  sleep 15
else
  warn "  Unauthorized SPIFFE user not found after 3 attempts."
  warn "  Re-run this script to retry."
fi

# ─── Step 11: Print results ──────────────────────────────────────────────────

echo ""
log "=========================================="
log "  ZTWIM OIDC Demo — Deployment Complete"
log "=========================================="
echo ""

CONSUMER_URL=$(oc get route oidc-consumer -n "$DEMO_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
UNAUTH_URL=$(oc get route oidc-consumer-unauth -n "$DEMO_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)

log "Dashboards:"
log "  Authorized:   https://$CONSUMER_URL"
log "  Unauthorized: https://$UNAUTH_URL"
echo ""
log "Logs:"
log "  oc logs -n $DEMO_NAMESPACE deploy/oidc-consumer -c consumer -f"
log "  oc logs -n $DEMO_NAMESPACE deploy/oidc-consumer-unauth -c consumer -f"
echo ""
log "Keycloak SPIFFE users:"
ADMIN_TOKEN=$(get_admin_token)
curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users?search=spiffe&max=20" \
  -H "Authorization: Bearer $ADMIN_TOKEN" 2>/dev/null | python3 -c "
import sys,json
for u in json.load(sys.stdin):
    status = 'ENABLED' if u['enabled'] else 'DISABLED'
    print(f'  {status}: {u[\"username\"]}')
" 2>/dev/null

echo ""

# Quick verification
sleep 5
AUTH_EXCHANGE=$(curl -sk "https://$CONSUMER_URL/api/status" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('keycloak_exchange_status','pending'))" 2>/dev/null || echo "pending")
UNAUTH_EXCHANGE=$(curl -sk "https://$UNAUTH_URL/api/status" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('keycloak_exchange_status','pending'))" 2>/dev/null || echo "pending")

log "Verification:"
log "  Authorized:   exchange=$AUTH_EXCHANGE (expected: SUCCESS)"
log "  Unauthorized: exchange=$UNAUTH_EXCHANGE (expected: FAILED: invalid_token)"
