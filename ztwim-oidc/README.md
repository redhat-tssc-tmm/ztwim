# ZTWIM OIDC Demo — SPIFFE Identity to Keycloak Token Exchange

This demo extends the `ztwim-simple` mTLS demo by adding **OIDC federation**: workloads use their SPIFFE JWT-SVIDs to authenticate via Keycloak and access a real application — **Trusted Profile Analyzer (TPA / Trustify)** — that knows nothing about SPIFFE.

## How It Works

```
Consumer Pod                          Keycloak                              TPA
    │                                 (backstage realm)                      │
    │  1. spiffe-helper gets          │                                      │
    │     JWT-SVID from SPIRE         │                                      │
    │                                 │                                      │
    │  2. Token exchange:             │                                      │
    │     JWT-SVID ──────────────►    │                                      │
    │                                 │ validates JWT signature              │
    │     Keycloak token ◄────────    │ via SPIRE OIDC Discovery             │
    │                                 │ (JWKS), checks user is enabled       │
    │                                 │                                      │
    │  3. Call TPA API with           │                                      │
    │     Keycloak token ────────────────────────────────────────────────►   │
    │                                 │                                      │
    │  4. Advisory data ◄────────────────────────────────────────────────    │
    │                                 │         validates Keycloak token      │
```

- **Authorized consumer**: SPIFFE ID is **enabled** in Keycloak → token exchange succeeds → TPA returns data
- **Unauthorized consumer**: SPIFFE ID is **disabled** in Keycloak → token exchange rejected → no TPA access

Both consumers have the same code, same audience, same client credentials. The only difference is whether their SPIFFE identity is approved in Keycloak.

## Architecture

```
Namespace: ztwim-oidc

┌─────────────────────────────────┐
│  oidc-consumer (frontend :8080) │     spiffe-helper sidecar
│  SA: oidc-consumer              │◄──── fetches JWT-SVID + X.509
│  spiffe://idc.com/ns/ztwim-oidc │      from SPIRE agent socket
│    /sa/oidc-consumer            │
│  Keycloak user: ENABLED         │
│  ✅ exchange=SUCCESS, tpa=200   │
└─────────────────────────────────┘

┌─────────────────────────────────┐
│  oidc-consumer-unauth           │     spiffe-helper sidecar
│  SA: oidc-consumer-unauth       │◄──── fetches JWT-SVID + X.509
│  spiffe://idc.com/ns/ztwim-oidc │      from SPIRE agent socket
│    /sa/oidc-consumer-unauth     │
│  Keycloak user: DISABLED        │
│  ❌ exchange=FAILED, tpa=denied │
└─────────────────────────────────┘

┌─────────────────────────────────┐
│  oidc-proxy                     │     Fixes SPIRE's OIDC discovery
│  Serves /.well-known/openid-    │     doc (adds missing fields
│  configuration and /keys,       │     required by TPA/Keycloak)
│  /userinfo                      │     and provides /userinfo
└─────────────────────────────────┘
```

## Prerequisites

- **SPIRE infrastructure** from `ztwim-simple` must be deployed (SpireServer, SpireAgent, SpiffeCSIDriver, SpireOIDCDiscoveryProvider, ClusterSPIFFEID)
- **Keycloak** (RHBK 24.x+) running on the cluster
- **TPA (Trusted Profile Analyzer)** running and authenticating via Keycloak
- `oc` CLI logged in as cluster-admin

## Deployment Steps

### 1. Enable Keycloak Token Exchange Feature

The token exchange feature is a preview in RHBK 24.x and must be enabled explicitly.

First, tell ArgoCD to ignore changes to the Keycloak CR (if ArgoCD manages it):

```bash
oc patch application keycloak -n openshift-gitops --type=json \
  -p '[{"op":"add","path":"/spec/ignoreDifferences","value":[
    {"group":"k8s.keycloak.org","kind":"Keycloak","name":"keycloak","namespace":"keycloak",
     "jsonPointers":["/spec/additionalOptions","/spec/features"]}
  ]}]'
```

Enable the features:

```bash
oc patch keycloak keycloak -n keycloak --type=merge \
  -p '{"spec":{"additionalOptions":[{"name":"features","value":"token-exchange,admin-fine-grained-authz"}]}}'
```

Wait for Keycloak to restart:

```bash
oc get pods -n keycloak -l app=keycloak -w
```

Verify token exchange is enabled:

```bash
curl -sk -X POST "https://<KEYCLOAK_URL>/realms/backstage/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange&subject_token=dummy&client_id=tpa-frontend"
# Should return "invalid_token" (not "unsupported_grant_type")
```

### 2. Update SPIRE jwtIssuer

The SpireServer `jwtIssuer` must be a routable URL matching the SPIRE OIDC Discovery Provider's Route:

```bash
# Check current OIDC route
oc get route spire-oidc-discovery-provider -n zero-trust-workload-identity-manager -o jsonpath='{.spec.host}'

# Update ztwim-simple/infra/spire-server.yaml jwtIssuer to:
#   https://spire-oidc.apps.<cluster-domain>
oc apply -f ztwim-simple/infra/spire-server.yaml
```

Verify the OIDC Discovery Provider responds:

```bash
curl -sk "https://spire-oidc.apps.<cluster-domain>/.well-known/openid-configuration"
```

### 3. Deploy the OIDC Demo Namespace and Workloads

```bash
# Namespace, ServiceAccounts, spiffe-helper configs
oc apply -f app/namespace.yaml
oc apply -f app/service-accounts.yaml
oc apply -f app/spiffe-helper-authorized.yaml
oc apply -f app/spiffe-helper-unauthorized.yaml

# Build the container image
oc new-build --binary --name=ztwim-oidc -n ztwim-oidc --strategy=docker
oc start-build ztwim-oidc --from-dir=src/ -n ztwim-oidc --follow

# Deploy OIDC proxy (must be running before Keycloak/TPA can use it)
oc apply -f app/oidc-proxy.yaml
```

Wait for the proxy to be ready, then verify:

```bash
curl -sk "https://spire-oidc-proxy-ztwim-oidc.apps.<cluster-domain>/.well-known/openid-configuration"
```

### 4. Patch TPA Authentication

Tell ArgoCD to ignore TPA ConfigMap changes (if ArgoCD manages TPA):

```bash
oc patch application trusted-profile-analyzer -n openshift-gitops --type=json \
  -p '[{"op":"add","path":"/spec/ignoreDifferences","value":[
    {"group":"","kind":"ConfigMap","name":"server-auth","namespace":"trusted-profile-analyzer",
     "jsonPointers":["/data/auth.yaml"]}
  ]}]'
```

**Important**: Edit `infra/tpa-auth-patch.yaml` and update the `issuerUrl` values to match your cluster's Keycloak URL before applying.

Apply the patch (uses `--from-file` to avoid YAML anchor issues):

```bash
oc create configmap server-auth -n trusted-profile-analyzer \
  --from-file=auth.yaml=<(cat infra/tpa-auth-patch.yaml | grep -A100 'authentication:') \
  --dry-run=client -o yaml | oc replace -f -
oc rollout restart deploy/server -n trusted-profile-analyzer
```

Verify TPA starts (1/1 Running, no CrashLoopBackOff):

```bash
oc get pods -n trusted-profile-analyzer -l app.kubernetes.io/name=server -w
```

### 5. Configure Keycloak (Identity Provider, Client, Permissions)

The `infra/keycloak-setup.sh` script automates all Keycloak configuration. Set the environment variables for your cluster:

```bash
export KEYCLOAK_URL="https://sso.apps.<cluster-domain>"
export KEYCLOAK_REALM="backstage"
export KEYCLOAK_ADMIN_PASSWORD="$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)"
export OIDC_PROXY_URL="https://spire-oidc-proxy-ztwim-oidc.apps.<cluster-domain>"
export SPIRE_OIDC_ISSUER="https://spire-oidc.apps.<cluster-domain>"

./infra/keycloak-setup.sh
```

The script:
1. Creates a `spire-oidc` Identity Provider in the backstage realm (points to the OIDC proxy for JWKS/userinfo, uses the real SPIRE issuer URL)
2. Enables token exchange permissions on the IDP
3. Creates a `spiffe-consumer` client (service account, confidential, with `read:document` scope)
4. Creates a token exchange policy allowing `spiffe-consumer` to exchange tokens
5. Stores the client secret in a K8s Secret `spiffe-consumer-secret`
6. Triggers initial token exchange to auto-create Keycloak users for both SPIFFE IDs
7. Disables the unauthorized SPIFFE identity's user

### 6. Deploy the Consumer Workloads

```bash
oc apply -f app/oidc-consumer.yaml
oc apply -f app/oidc-consumer-unauth.yaml
```

Wait for pods (2/2 Running — app + spiffe-helper sidecar):

```bash
oc get pods -n ztwim-oidc -w
```

### 7. Access the Dashboards

```bash
oc get routes -n ztwim-oidc
```

Open both consumer URLs in a browser side-by-side:

- **oidc-consumer** → green dashboard, token exchange SUCCESS, TPA advisory data shown
- **oidc-consumer-unauth** → red dashboard, token exchange FAILED (identity disabled in Keycloak)

Both dashboards show:
- The workload's SPIFFE ID (from the JWT-SVID)
- The JWT-SVID claims (aud, iss, exp)
- The Keycloak token exchange result and Keycloak token payload
- The TPA API response (or error)

## Verification

```bash
# Authorized consumer — should show AUTHORIZED, exchange=SUCCESS
oc logs -n ztwim-oidc deploy/oidc-consumer -c consumer --tail=5

# Unauthorized consumer — should show DENIED, exchange=FAILED
oc logs -n ztwim-oidc deploy/oidc-consumer-unauth -c consumer --tail=5

# TPA server — should show accepted requests from spiffe-consumer client
oc logs -n trusted-profile-analyzer deploy/server --tail=10
```

## OIDC Proxy

The OIDC proxy (`oidc_proxy.py`) exists because TPA's OIDC library requires `authorization_endpoint`, `token_endpoint`, and `userinfo_endpoint` fields in the discovery document, but SPIRE's OIDC Discovery Provider only provides `issuer`, `jwks_uri`, and signing algorithm metadata.

The proxy:
- Fetches the real SPIRE discovery document and adds the missing OIDC fields
- Proxies `/keys` requests to the real SPIRE JWKS endpoint
- Serves a `/userinfo` endpoint that decodes the JWT-SVID and returns the `sub` claim as user info (needed for Keycloak's token exchange validation)
- Preserves the real SPIRE issuer URL (does NOT rewrite `issuer`)

## File Structure

```
ztwim-oidc/
├── README.md
├── infra/
│   ├── tpa-auth-patch.yaml            # TPA server-auth ConfigMap with spiffe-consumer client
│   └── keycloak-setup.sh              # Automated Keycloak configuration script
├── app/
│   ├── namespace.yaml                 # Namespace ztwim-oidc
│   ├── service-accounts.yaml          # oidc-consumer, oidc-consumer-unauth
│   ├── spiffe-helper-authorized.yaml  # JWT-SVID config (aud=tpa-spiffe)
│   ├── spiffe-helper-unauthorized.yaml # JWT-SVID config (same aud=tpa-spiffe)
│   ├── oidc-proxy.yaml               # OIDC discovery proxy deployment + Route
│   ├── oidc-consumer.yaml             # Authorized consumer + Route
│   └── oidc-consumer-unauth.yaml      # Unauthorized consumer + Route
└── src/
    ├── Containerfile
    ├── consumer.py                    # Web dashboard + JWT-SVID→Keycloak→TPA flow
    ├── oidc_proxy.py                  # OIDC discovery proxy
    └── templates/
        └── index.html                 # Dashboard HTML
```

## Key Design Points

- **Identity-based access control in Keycloak**: Both consumers have the same code, audience, and client credentials. The gate is whether their SPIFFE ID is enabled or disabled as a Keycloak user. An admin controls which workload identities can access downstream services.
- **TPA is SPIFFE-unaware**: TPA only sees standard Keycloak tokens with `azp`, `scope`, `preferred_username` claims. The `preferred_username` carries the SPIFFE ID through as metadata, but TPA doesn't check it.
- **Token exchange (RFC 8693)**: The consumer exchanges its JWT-SVID for a Keycloak access token via the standard token exchange grant. Keycloak validates the JWT-SVID signature against SPIRE's JWKS, maps it to a local user, and issues its own token.
- **SPIFFE ID visible in Keycloak token**: The Keycloak token's `preferred_username` field contains the full SPIFFE ID (e.g., `spiffe://idc.com/ns/ztwim-oidc/sa/oidc-consumer`), making the identity chain traceable.

## Cleanup

```bash
# Remove demo workloads
oc delete -f app/oidc-consumer-unauth.yaml
oc delete -f app/oidc-consumer.yaml
oc delete -f app/oidc-proxy.yaml
oc delete -f app/spiffe-helper-unauthorized.yaml
oc delete -f app/spiffe-helper-authorized.yaml
oc delete secret spiffe-consumer-secret -n ztwim-oidc
oc delete -f app/service-accounts.yaml
oc delete -f app/namespace.yaml

# Restore TPA auth (remove the spiffe-consumer entry)
# Revert Keycloak: remove the spire-oidc IDP and spiffe-consumer client via admin console
```

## Showcase Deployment Notes

To deploy on a different cluster:

1. Deploy SPIRE infrastructure from `ztwim-simple/infra/` (update `jwtIssuer` to match the new cluster domain)
2. Enable Keycloak token exchange feature (step 1 above)
3. Deploy namespace, SAs, build image, deploy OIDC proxy (step 3 above)
4. Update and apply `infra/tpa-auth-patch.yaml` with the new cluster's Keycloak URL (step 4)
5. Run `infra/keycloak-setup.sh` with the new cluster's URLs (step 5)
6. Deploy consumer workloads (step 6)
7. Route hostnames auto-adjust to the new cluster's domain
