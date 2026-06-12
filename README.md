# ZTWIM Demo — Zero Trust Workload Identity Manager (SPIFFE/SPIRE)

Three demos showcasing SPIFFE/SPIRE workload identity on OpenShift using the Red Hat Zero Trust Workload Identity Manager operator.

| Demo | What it shows | Identity type | External deps |
|------|---------------|---------------|---------------|
| [ztwim-simple](ztwim-simple/) | mTLS between workloads, application-level SPIFFE ID validation | X.509 SVID | None |
| [ztwim-oidc-simple](ztwim-oidc-simple/) | JWT-SVID as OIDC Bearer token, data-service validates against SPIRE JWKS | JWT-SVID (OIDC) | None |
| [ztwim-oidc](ztwim-oidc/) | JWT-SVID → Keycloak token exchange → access Trusted Profile Analyzer | JWT-SVID (OIDC) | Keycloak + TPA |

All demos run on the same cluster simultaneously and share the same SPIRE infrastructure.

## Prerequisites

- OpenShift 4.20+ with cluster-admin access
- **Zero Trust Workload Identity Manager** operator installed from OperatorHub
- For ztwim-oidc only: **Keycloak** (RHBK 24.x+) and **Trusted Profile Analyzer** running on the cluster

## Shared Infrastructure

Both demos share a single set of cluster-scoped SPIRE components. These are deployed once from `ztwim-simple/infra/` and serve both demo namespaces.

| Resource | Kind | Name | Purpose |
|----------|------|------|---------|
| `ZeroTrustWorkloadIdentityManager` | Singleton CR | `cluster` | Trust domain: `idc.com` |
| `SpireServer` | Singleton CR | `cluster` | Issues X.509 and JWT SVIDs, CA: "ZTWIM Demo CA / IDC" |
| `SpireAgent` | Singleton CR | `cluster` | DaemonSet, one per node, PSAT attestor |
| `SpiffeCSIDriver` | Singleton CR | `cluster` | DaemonSet, one per node, mounts Workload API socket |
| `SpireOIDCDiscoveryProvider` | Singleton CR | `cluster` | Publishes JWKS for JWT-SVID validation |
| `ClusterSPIFFEID` | Cluster-scoped | `ztwim-simple-workloads` | Assigns SPIFFE IDs to all pods in namespaces with label `spiffe.io/demo: "true"` |

The `ClusterSPIFFEID` uses a Go template that derives the SPIFFE ID from the pod's namespace and ServiceAccount:

```
spiffe://idc.com/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}
```

Both demo namespaces carry the label `spiffe.io/demo: "true"`, so all pods in both namespaces automatically receive SPIFFE identities from this single `ClusterSPIFFEID`.

## Deployment Order

The SPIRE infrastructure must be deployed before any demo. The demos can then be deployed in any order or in parallel.

```
Step 1: SPIRE Infrastructure (from ztwim-simple/infra/)
        ├── ztwim.yaml                    → ZeroTrustWorkloadIdentityManager (trust domain)
        ├── spire-server.yaml             → SpireServer
        ├── spire-agent.yaml              → SpireAgent
        ├── spiffe-csi-driver.yaml        → SpiffeCSIDriver
        └── spire-oidc-discovery.yaml     → SpireOIDCDiscoveryProvider
        
        Wait: all pods in zero-trust-workload-identity-manager namespace must be Running.
              Verify: oc get zerotrustworkloadidentitymanager cluster -o jsonpath='{.status.conditions[0].message}'
              Should output: "All components are ready"

Step 2: Deploy demos (any order, or all in parallel)

  ┌───────────────────────┐  ┌───────────────────────┐  ┌───────────────────────┐
  │  ztwim-simple         │  │  ztwim-oidc-simple    │  │  ztwim-oidc           │
  │                       │  │                       │  │                       │
  │  1. Create namespace  │  │  1. Create namespace  │  │  1. Enable Keycloak   │
  │  2. Apply SAs, SPIFFE │  │  2. Apply SAs, config │  │     token exchange    │
  │  3. Build image       │  │  3. Build image       │  │  2. Create namespace  │
  │  4. Deploy workloads  │  │  4. Deploy workloads  │  │  3. Build image       │
  │                       │  │                       │  │  4. Deploy OIDC proxy │
  │  NS: ztwim-simple     │  │  NS: ztwim-oidc-simple│  │  5. Patch TPA auth   │
  │  Auth: mTLS (X.509)   │  │  Auth: JWT Bearer     │  │  6. Configure KC     │
  │  Deps: none           │  │  Deps: none           │  │  7. Deploy workloads │
  │                       │  │                       │  │                       │
  └───────────────────────┘  └───────────────────────┘  │  NS: ztwim-oidc      │
                                                        │  Auth: JWT→KC→TPA    │
                                                        │  Deps: Keycloak, TPA │
                                                        └───────────────────────┘
```

### Quick start (full deployment)

```bash
# Step 1: SPIRE infrastructure
oc apply -f ztwim-simple/infra/ztwim.yaml
oc apply -f ztwim-simple/infra/spire-server.yaml
oc apply -f ztwim-simple/infra/spire-agent.yaml
oc apply -f ztwim-simple/infra/spiffe-csi-driver.yaml
oc apply -f ztwim-simple/infra/spire-oidc-discovery.yaml

# Wait for all SPIRE components
oc get pods -n zero-trust-workload-identity-manager -w

# Step 2a: ztwim-simple (mTLS demo — no external deps)
cd ztwim-simple && ./deploy.sh && cd ..

# Step 2b: ztwim-oidc-simple (JWT Bearer demo — no external deps)
cd ztwim-oidc-simple && ./deploy.sh && cd ..

# Step 2c: ztwim-oidc (Keycloak + TPA demo — requires Keycloak and TPA)
cd ztwim-oidc && ./deploy.sh && cd ..

# Or with pre-built images:
# export IMAGE_REGISTRY=quay.io/tssc_demos
# cd ztwim-simple && ./deploy.sh && cd ..
# cd ztwim-oidc-simple && ./deploy.sh && cd ..
# cd ztwim-oidc && ./deploy.sh && cd ..
```

## Cluster-Specific Configuration

When deploying on a new cluster, the following values must be updated to match the cluster's domain:

| File | Field | Example value |
|------|-------|---------------|
| `ztwim-simple/infra/spire-server.yaml` | `spec.jwtIssuer` | `https://spire-oidc.apps.<cluster-domain>` |
| `ztwim-simple/infra/spire-oidc-discovery.yaml` | `spec.jwtIssuer` | `https://spire-oidc.apps.<cluster-domain>` |
| `ztwim-oidc/app/oidc-proxy.yaml` | `SPIRE_OIDC_URL` env | `https://spire-oidc.apps.<cluster-domain>` |
| `ztwim-oidc/app/oidc-proxy.yaml` | `PROXY_EXTERNAL_URL` env | `https://spire-oidc-proxy-ztwim-oidc.apps.<cluster-domain>` |
| `ztwim-oidc/infra/tpa-auth-patch.yaml` | `issuerUrl` values | Keycloak URL for the target cluster |
| `ztwim-oidc/infra/keycloak-setup.sh` | env vars at runtime | `KEYCLOAK_URL`, `OIDC_PROXY_URL`, `SPIRE_OIDC_ISSUER` |

Route hostnames are generated automatically by OpenShift and do not need manual configuration.

## Cleanup

```bash
# Remove demos (any order)
oc delete namespace ztwim-oidc
oc delete namespace ztwim-oidc-simple
oc delete namespace ztwim-simple

# Remove shared ClusterSPIFFEID
oc delete clusterspiffeid ztwim-simple-workloads

# Remove SPIRE infrastructure (order matters — reverse of deployment)
oc delete spireoidcdiscoveryprovider cluster
oc delete spiffecsidriver cluster
oc delete spireagent cluster
oc delete spireserver cluster
oc delete zerotrustworkloadidentitymanager cluster
```
