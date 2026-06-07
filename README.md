# ZTWIM Demo — Zero Trust Workload Identity Manager (SPIFFE/SPIRE)

Two demos showcasing SPIFFE/SPIRE workload identity on OpenShift using the Red Hat Zero Trust Workload Identity Manager operator.

| Demo | What it shows | Identity type |
|------|---------------|---------------|
| [ztwim-simple](ztwim-simple/) | mTLS between workloads, application-level SPIFFE ID validation | X.509 SVID |
| [ztwim-oidc](ztwim-oidc/) | JWT-SVID → Keycloak token exchange → access Trusted Profile Analyzer | JWT-SVID (OIDC) |

Both demos run on the same cluster simultaneously and share the same SPIRE infrastructure.

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

The SPIRE infrastructure must be deployed before either demo. The two demos can then be deployed in any order, but `ztwim-oidc` depends on the infrastructure being fully ready.

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

Step 2: Deploy demos (either order, or both in parallel)

        ┌─────────────────────────────────┐     ┌─────────────────────────────────┐
        │  ztwim-simple                   │     │  ztwim-oidc                     │
        │                                 │     │                                 │
        │  1. oc apply -f app/namespace   │     │  1. Enable Keycloak token       │
        │  2. oc apply -f app/sa, spiffeid│     │     exchange feature            │
        │  3. Build image from src/       │     │  2. oc apply -f app/namespace   │
        │  4. oc apply -f app/workloads   │     │  3. Build image from src/       │
        │                                 │     │  4. Deploy OIDC proxy           │
        │  Namepsace: ztwim-simple        │     │  5. Patch TPA auth.yaml         │
        │  Uses: X.509 SVIDs (mTLS)       │     │  6. Run keycloak-setup.sh       │
        │                                 │     │  7. oc apply -f app/workloads   │
        │                                 │     │                                 │
        │                                 │     │  Namespace: ztwim-oidc          │
        │                                 │     │  Uses: JWT-SVIDs (OIDC)         │
        └─────────────────────────────────┘     └─────────────────────────────────┘
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

# Step 2a: ztwim-simple demo (see ztwim-simple/README.md for details)
oc apply -f ztwim-simple/app/namespace.yaml
oc apply -f ztwim-simple/app/service-accounts.yaml
oc apply -f ztwim-simple/app/cluster-spiffeid.yaml
oc apply -f ztwim-simple/app/spiffe-helper-config.yaml
oc new-build --binary --name=ztwim-simple -n ztwim-simple --strategy=docker
oc start-build ztwim-simple --from-dir=ztwim-simple/src/ -n ztwim-simple --follow
oc apply -f ztwim-simple/app/data-service.yaml
oc apply -f ztwim-simple/app/consumer.yaml
oc apply -f ztwim-simple/app/consumer-unauthorized.yaml

# Step 2b: ztwim-oidc demo (see ztwim-oidc/README.md for details)
# ... requires Keycloak and TPA setup — follow ztwim-oidc/README.md
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
# Remove ztwim-oidc demo
oc delete namespace ztwim-oidc

# Remove ztwim-simple demo
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
