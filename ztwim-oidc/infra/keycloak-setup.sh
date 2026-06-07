#!/bin/bash
set -euo pipefail

# Keycloak OIDC Federation Setup for ZTWIM OIDC Demo
# This script configures Keycloak to accept SPIFFE JWT-SVIDs via token exchange.
#
# Prerequisites:
#   - Keycloak running with token-exchange feature enabled
#   - SPIRE OIDC Discovery Provider accessible
#   - OIDC Proxy deployed (fixes TPA compatibility)
#   - TPA (Trusted Profile Analyzer) running with Keycloak auth
#
# Usage:
#   export KEYCLOAK_URL="https://sso.apps.<cluster-domain>"
#   export KEYCLOAK_REALM="backstage"
#   export KEYCLOAK_ADMIN_PASSWORD="<admin-password>"
#   export OIDC_PROXY_URL="https://spire-oidc-proxy-ztwim-oidc.apps.<cluster-domain>"
#   export SPIRE_OIDC_ISSUER="https://spire-oidc.apps.<cluster-domain>"
#   ./keycloak-setup.sh

KEYCLOAK_URL="${KEYCLOAK_URL:?Set KEYCLOAK_URL}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-backstage}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?Set KEYCLOAK_ADMIN_PASSWORD}"
OIDC_PROXY_URL="${OIDC_PROXY_URL:?Set OIDC_PROXY_URL}"
SPIRE_OIDC_ISSUER="${SPIRE_OIDC_ISSUER:?Set SPIRE_OIDC_ISSUER}"

echo "=== Getting admin token ==="
ADMIN_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# --- Step 1: Create SPIRE OIDC Identity Provider ---
echo "=== Creating SPIRE OIDC Identity Provider ==="
curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/identity-provider/instances" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"alias\": \"spire-oidc\",
    \"displayName\": \"SPIRE Workload Identity\",
    \"providerId\": \"oidc\",
    \"enabled\": true,
    \"trustEmail\": true,
    \"storeToken\": true,
    \"config\": {
      \"issuer\": \"${SPIRE_OIDC_ISSUER}\",
      \"authorizationUrl\": \"${OIDC_PROXY_URL}/authorize\",
      \"tokenUrl\": \"${OIDC_PROXY_URL}/token\",
      \"userInfoUrl\": \"${OIDC_PROXY_URL}/userinfo\",
      \"jwksUrl\": \"${OIDC_PROXY_URL}/keys\",
      \"clientId\": \"spire-workload\",
      \"clientSecret\": \"not-used\",
      \"defaultScope\": \"openid\",
      \"validateSignature\": \"true\",
      \"useJwksUrl\": \"true\",
      \"disableUserInfo\": \"false\"
    }
  }"
echo " done"

# --- Step 2: Enable IDP token exchange permissions ---
echo "=== Enabling IDP token exchange permissions ==="
curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/identity-provider/instances/spire-oidc/management/permissions" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true}' > /tmp/kc-perm.json
PERM_ID=$(python3 -c "import json; print(json.load(open('/tmp/kc-perm.json'))['scopePermissions']['token-exchange'])")
echo "  Permission ID: $PERM_ID"

# --- Step 3: Create spiffe-consumer client ---
echo "=== Creating spiffe-consumer client ==="
curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "spiffe-consumer",
    "name": "SPIFFE Workload Consumer",
    "enabled": true,
    "clientAuthenticatorType": "client-secret",
    "serviceAccountsEnabled": true,
    "publicClient": false,
    "directAccessGrantsEnabled": false,
    "standardFlowEnabled": false,
    "protocol": "openid-connect"
  }'
echo " done"

# Get client UUID and secret
CLIENT_UUID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=spiffe-consumer" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
CLIENT_SECRET=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")
echo "  Client UUID: $CLIENT_UUID"
echo "  Client Secret: $CLIENT_SECRET"

# --- Step 4: Add read:document scope to the client ---
echo "=== Adding read:document scope ==="
SCOPE_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/client-scopes" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "
import sys,json
for s in json.load(sys.stdin):
    if s['name'] == 'read:document':
        print(s['id']); break")
curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/default-client-scopes/${SCOPE_ID}" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
echo " done"

# --- Step 5: Create token exchange policy ---
echo "=== Creating token exchange policy ==="
REALM_MGMT_UUID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=realm-management" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

POLICY_ID=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/policy/client" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"spiffe-consumer-policy\",
    \"description\": \"Allow spiffe-consumer to exchange tokens\",
    \"logic\": \"POSITIVE\",
    \"clients\": [\"${CLIENT_UUID}\"]
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  Policy ID: $POLICY_ID"

# Associate policy with the token-exchange permission
curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${REALM_MGMT_UUID}/authz/resource-server/permission/scope/${PERM_ID}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"id\": \"${PERM_ID}\",
    \"name\": \"token-exchange.permission.idp.spire-oidc\",
    \"type\": \"scope\",
    \"logic\": \"POSITIVE\",
    \"decisionStrategy\": \"UNANIMOUS\",
    \"policies\": [\"${POLICY_ID}\"]
  }"
echo " done"

# --- Step 6: Create Keycloak secret in OpenShift ---
echo "=== Creating K8s Secret for Keycloak client ==="
oc create secret generic spiffe-consumer-secret -n ztwim-oidc \
  --from-literal=client-id=spiffe-consumer \
  --from-literal=client-secret="${CLIENT_SECRET}" \
  --dry-run=client -o yaml | oc apply -f -
echo " done"

# --- Step 7: Do initial token exchange to auto-create users ---
echo "=== Triggering initial token exchange to create SPIFFE users ==="
echo "  Waiting for consumer pods to generate JWT-SVIDs..."
sleep 10

for SA in oidc-consumer oidc-consumer-unauth; do
  POD=$(oc get pods -n ztwim-oidc -l app=${SA/oidc-/oidc-} --no-headers 2>/dev/null | grep Running | head -1 | awk '{print $1}')
  if [ -n "$POD" ]; then
    JWT=$(oc exec -n ztwim-oidc "$POD" -c consumer -- cat /certs/jwt_svid.token 2>/dev/null || echo "")
    if [ -n "$JWT" ]; then
      RESULT=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
        -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
        -d "subject_token=$JWT" \
        -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
        -d "subject_issuer=spire-oidc" \
        -d "client_id=spiffe-consumer" \
        -d "client_secret=${CLIENT_SECRET}" 2>&1)
      echo "  $SA: $(echo $RESULT | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if 'access_token' in d else d.get('error','?'))" 2>/dev/null)"
    fi
  fi
done

# --- Step 8: Disable the unauthorized user ---
echo "=== Disabling unauthorized SPIFFE identity ==="
# Re-fetch admin token (may have expired)
ADMIN_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

UNAUTH_USER_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users?search=oidc-consumer-unauth&max=5" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "
import sys,json
for u in json.load(sys.stdin):
    if 'unauth' in u.get('username',''):
        print(u['id']); break")

if [ -n "$UNAUTH_USER_ID" ]; then
  curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${UNAUTH_USER_ID}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"enabled": false}'
  echo "  Disabled user: $UNAUTH_USER_ID"
else
  echo "  WARNING: unauthorized user not found — run this step manually after pods start"
fi

echo ""
echo "=== Setup complete ==="
echo "  Client ID:     spiffe-consumer"
echo "  Client Secret:  $CLIENT_SECRET"
echo "  Authorized:     spiffe://idc.com/ns/ztwim-oidc/sa/oidc-consumer (ENABLED)"
echo "  Unauthorized:   spiffe://idc.com/ns/ztwim-oidc/sa/oidc-consumer-unauth (DISABLED)"
