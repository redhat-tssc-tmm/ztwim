# ZTWIM Demo — Automated Setup Guide

Both demos include fully automated deployment scripts that handle all cluster-specific configuration, image builds, and Keycloak/TPA setup.

## Deployment Scripts

| Script | What it deploys |
|--------|----------------|
| `ztwim-simple/deploy.sh` | SPIRE infrastructure + mTLS demo (data-service, consumer, consumer-unauthorized) |
| `ztwim-oidc/deploy.sh` | OIDC demo (OIDC proxy, Keycloak config, TPA patch, oidc-consumer, oidc-consumer-unauth) |

Both scripts are **idempotent** — safe to re-run if something fails halfway.

## Container Images

The demo container images can either be built locally with Podman and pushed to an external registry, or built in-cluster using OpenShift's build system. Pre-building is recommended — it's faster and avoids build failures from cluster disk pressure.

### Build locally and push to quay.io

```bash
# Log in to quay.io (one-time)
podman login quay.io

# Build and push both images
./build-images.sh

# Or build only one
./build-images.sh simple
./build-images.sh oidc
```

This pushes to `quay.io/tssc_demos/ztwim-simple:latest` and `quay.io/tssc_demos/ztwim-oidc:latest`. Override the registry and org with environment variables:

```bash
REGISTRY=quay.io ORG=my-org TAG=v1.0 ./build-images.sh
```

### Deploy using pre-built images

Set `IMAGE_REGISTRY` before running the deploy scripts to skip the in-cluster build:

```bash
export IMAGE_REGISTRY=quay.io/tssc_demos

cd ztwim-simple && ./deploy.sh     # uses quay.io/tssc_demos/ztwim-simple:latest
cd ../ztwim-oidc && ./deploy.sh    # uses quay.io/tssc_demos/ztwim-oidc:latest
```

You can also override the tag:

```bash
export IMAGE_REGISTRY=quay.io/tssc_demos
export IMAGE_TAG=v1.0
```

### Build in-cluster (original behavior)

If `IMAGE_REGISTRY` is not set, the deploy scripts build the image on OpenShift using `oc new-build --binary`:

```bash
cd ztwim-simple && ./deploy.sh     # builds via oc start-build, pushes to internal registry
```

### Image repositories

| Image | Source | Default registry |
|-------|--------|------------------|
| `ztwim-simple` | `ztwim-simple/src/` | `quay.io/tssc_demos/ztwim-simple` |
| `ztwim-oidc` | `ztwim-oidc/src/` | `quay.io/tssc_demos/ztwim-oidc` |

Both images are built from `Containerfile` using `registry.access.redhat.com/ubi9/python-311:latest` as the base. No pip dependencies — Python stdlib only.

**Note**: When using an external registry, make sure the images are publicly accessible or that a pull secret is configured on the cluster.

## Quick Start

```bash
# Clone the repo to your machine
# Log in to the target cluster as cluster-admin
oc login --token=<token> --server=<api-url>

# Deploy the simple mTLS demo (also deploys shared SPIRE infrastructure)
cd ztwim-simple
./deploy.sh

# Deploy the OIDC demo (requires SPIRE infra from step above + Keycloak + TPA)
cd ../ztwim-oidc
./deploy.sh
```

Each script prints the dashboard URLs and a verification summary at the end.

## What the Scripts Do

### `ztwim-simple/deploy.sh`

1. **Auto-detects** the cluster apps domain from OpenShift ingress config
2. **Updates all manifests** with cluster-specific values (jwtIssuer, namespace, image refs, SPIFFE IDs, service DNS names)
3. **Deploys SPIRE infrastructure** (ZeroTrustWorkloadIdentityManager, SpireServer, SpireAgent, SpiffeCSIDriver, SpireOIDCDiscoveryProvider) and waits until all components report ready
4. **Creates the demo namespace** (`ztwim-simple`), ServiceAccounts, ClusterSPIFFEID, and spiffe-helper ConfigMap
5. **Builds the container image** in-cluster using `oc new-build --binary`
6. **Deploys workloads** (data-service, consumer, consumer-unauthorized) and waits for all pods to be Running (2/2)
7. **Prints Route URLs** and runs a quick API check to confirm authorized=True / unauthorized=False

### `ztwim-oidc/deploy.sh`

1. **Auto-detects** cluster domain, Keycloak URL (from route), and TPA URL (from route)
2. **Preflight checks**: verifies SPIRE infrastructure is ready, Keycloak realm is reachable, TPA is responding
3. **Enables Keycloak token-exchange** feature by patching the Keycloak CR with `additionalOptions` (skips if already enabled). Patches ArgoCD `ignoreDifferences` if Keycloak is ArgoCD-managed
4. **Updates manifests** with cluster-specific URLs (OIDC proxy, TPA, Keycloak token endpoint, image refs)
5. **Deploys the OIDC proxy** — a lightweight Python service that fixes SPIRE's OIDC discovery document for TPA compatibility and provides a `/userinfo` endpoint for Keycloak token exchange
6. **Patches TPA's auth ConfigMap** — appends a `spiffe-consumer` client entry alongside existing Keycloak clients. Patches ArgoCD `ignoreDifferences` to prevent revert. Restarts TPA server
7. **Configures Keycloak** via admin API:
   - Creates `spire-oidc` Identity Provider (OIDC type, pointing to the OIDC proxy for JWKS/userinfo, real SPIRE issuer URL)
   - Enables token exchange permissions on the IDP
   - Creates `spiffe-consumer` client (confidential, service account, `read:document` scope)
   - Creates a client policy and associates it with the token exchange permission
   - Stores the client secret in a K8s Secret (`spiffe-consumer-secret`)
8. **Deploys consumer workloads** (oidc-consumer, oidc-consumer-unauth) and waits for pods
9. **Triggers initial token exchange** for both consumers to auto-create Keycloak users from their SPIFFE identities
10. **Disables the unauthorized SPIFFE user** in Keycloak so its token exchange is rejected
11. **Prints dashboard URLs**, Keycloak user status, and verification results

## Configurable Variables

All variables have sensible defaults that are auto-detected or match the standard deployment. Override by exporting before running the script.

### Both scripts

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_DOMAIN` | auto-detected | OpenShift apps domain (e.g., `apps.cluster-xyz.example.com`) |
| `TRUST_DOMAIN` | `idc.com` | SPIFFE trust domain |
| `DEMO_NAMESPACE` | `ztwim-simple` / `ztwim-oidc` | Namespace for the demo workloads |
| `IMAGE_NAME` | `ztwim-simple` / `ztwim-oidc` | BuildConfig and ImageStream name |

### `ztwim-oidc/deploy.sh` only

| Variable | Default | Description |
|----------|---------|-------------|
| `KEYCLOAK_NAMESPACE` | `keycloak` | Namespace where Keycloak is deployed |
| `KEYCLOAK_CR_NAME` | `keycloak` | Name of the Keycloak CR (for patching features) |
| `KEYCLOAK_ADMIN_SECRET` | `keycloak-initial-admin` | K8s Secret containing admin credentials |
| `KEYCLOAK_ADMIN_USER_KEY` | `username` | Key in the secret for the admin username |
| `KEYCLOAK_ADMIN_PASS_KEY` | `password` | Key in the secret for the admin password |
| `KEYCLOAK_REALM` | `backstage` | Keycloak realm that TPA uses |
| `KEYCLOAK_HOST` | auto-detected from route | Keycloak hostname (without `https://`) |
| `TPA_NAMESPACE` | `trusted-profile-analyzer` | Namespace where TPA is deployed |
| `TPA_AUTH_CONFIGMAP` | `server-auth` | Name of TPA's auth configuration ConfigMap |
| `TPA_SERVER_DEPLOYMENT` | `server` | Name of TPA's server Deployment |
| `TPA_HOST` | auto-detected from route | TPA hostname (without `https://`) |
| `KC_CLIENT_ID` | `spiffe-consumer` | Keycloak client ID for SPIFFE workloads |
| `ARGOCD_NAMESPACE` | `openshift-gitops` | Namespace where ArgoCD runs (for `ignoreDifferences` patches) |

### Example: custom Keycloak setup

```bash
export KEYCLOAK_NAMESPACE="my-keycloak"
export KEYCLOAK_ADMIN_SECRET="my-admin-secret"
export KEYCLOAK_REALM="my-realm"
cd ztwim-oidc
./deploy.sh
```

## Troubleshooting

### SPIRE infrastructure not ready

```bash
oc get zerotrustworkloadidentitymanager cluster -o jsonpath='{.status.conditions[0].message}'
oc get pods -n zero-trust-workload-identity-manager
```

All pods should be Running. If the SpireOIDCDiscoveryProvider is not created, check that `ztwim-simple/deploy.sh` completed step 2 successfully.

### Token exchange returns `unsupported_grant_type`

The Keycloak token-exchange feature is not enabled. Check:

```bash
oc get keycloak keycloak -n keycloak -o jsonpath='{.spec.additionalOptions}'
oc logs -n keycloak keycloak-0 | grep "Preview features enabled"
```

### TPA crashes with `error decoding response body`

The SPIRE OIDC Discovery Provider serves an incomplete discovery document. The OIDC proxy must be deployed and running before TPA is configured:

```bash
oc get pods -n ztwim-oidc -l app=oidc-proxy
curl -sk "https://spire-oidc-proxy-ztwim-oidc.apps.<cluster-domain>/.well-known/openid-configuration"
```

### ArgoCD reverts ConfigMap changes

Both scripts patch ArgoCD applications with `ignoreDifferences`. Verify:

```bash
oc get application trusted-profile-analyzer -n openshift-gitops -o jsonpath='{.spec.ignoreDifferences}'
oc get application keycloak -n openshift-gitops -o jsonpath='{.spec.ignoreDifferences}'
```

### Token exchange returns `invalid_token`

Check that the unauthorized SPIFFE user is disabled in Keycloak:

```bash
# Get admin token
ADMIN_TOKEN=$(curl -sk -X POST "https://<keycloak-url>/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=<password>" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# List SPIFFE users
curl -sk "https://<keycloak-url>/admin/realms/backstage/users?search=spiffe&max=20" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "import sys,json; [print(f'{'ENABLED' if u['enabled'] else 'DISABLED'}: {u[\"username\"]}') for u in json.load(sys.stdin)]"
```

### Build fails with `DiskPressure`

A cluster node is running low on disk. Wait a minute and re-run the script — the build will retry automatically.
