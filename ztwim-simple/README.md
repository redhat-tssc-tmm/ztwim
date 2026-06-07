# ZTWIM Demo — Zero Trust Workload Identity Manager (SPIFFE/SPIRE)

This demo deploys three workloads on OpenShift that demonstrate SPIFFE/SPIRE workload identity using the Red Hat Zero Trust Workload Identity Manager operator.

- **data-service** — an mTLS server that holds a secret and validates the caller's SPIFFE ID against an allow-list
- **consumer** (authorized) — a web dashboard that calls data-service using its SVID and **succeeds** (HTTP 200)
- **consumer-unauthorized** — the same app image but with a different ServiceAccount, so it gets a different SPIFFE ID and is **denied** (HTTP 403)

Both consumer dashboards are exposed via OpenShift Routes so you can open them side-by-side in a browser — one green, one red.

## Architecture

```
                        ┌──────────────────────────────────┐
    Browser ◄───────────┤  consumer (web frontend :8080)   │
    (Route)             │  SA: consumer                    │
                        │  spiffe://idc.com/ns/ztwim-simple/ │
                        │    sa/consumer                    │
                        └──────────┬───────────────────────┘
                                   │ mTLS (SVID)
                                   │ ✅ ALLOWED
                                   ▼
                        ┌──────────────────────────────────┐
                        │  data-service (mTLS :8443)       │
                        │  SA: data-service                │
                        │  Validates caller SPIFFE ID      │
                        └──────────────────────────────────┘
                                   ▲
                                   │ mTLS (SVID)
                                   │ ❌ DENIED
                        ┌──────────┴───────────────────────┐
    Browser ◄───────────┤  consumer-unauthorized            │
    (Route)             │  SA: consumer-unauthorized        │
                        │  spiffe://idc.com/ns/ztwim-simple/ │
                        │    sa/consumer-unauthorized       │
                        └──────────────────────────────────┘
```

Each pod runs two containers:
1. The Python application
2. A `spiffe-helper` sidecar that reads the SPIRE Workload API socket (mounted via CSI driver) and writes PEM certificate files to a shared volume

## Prerequisites

- OpenShift 4.20+ cluster with cluster-admin access
- `oc` CLI logged in
- The **Zero Trust Workload Identity Manager** operator installed from OperatorHub (Operator → OperatorHub → search "Zero Trust Workload Identity Manager" → Install with defaults)

## Deployment Steps

### 1. Deploy SPIRE Infrastructure

Apply the manifests in order. The parent `ZeroTrustWorkloadIdentityManager` CR must be created first — the operator will not reconcile SpireServer/Agent/CSIDriver CRs without it.

```bash
oc apply -f infra/ztwim.yaml
oc apply -f infra/spire-server.yaml
oc apply -f infra/spire-agent.yaml
oc apply -f infra/spiffe-csi-driver.yaml
oc apply -f infra/spire-oidc-discovery.yaml
```

Wait for all SPIRE pods to be running:

```bash
oc get pods -n zero-trust-workload-identity-manager -w
```

You should see:
- `spire-server-0` (2/2 Running)
- `spire-agent-*` (1/1 Running, one per node)
- `spire-spiffe-csi-driver-*` (2/2 Running, one per node)
- `spire-spiffe-oidc-discovery-provider-*` (1/1 Running)
- `zero-trust-workload-identity-manager-controller-manager-*` (1/1 Running)

Verify all components are ready:

```bash
oc get zerotrustworkloadidentitymanager cluster -o jsonpath='{.status.conditions[0].message}'
# Should output: "All components are ready"
```

### 2. Create the Demo Namespace and Identity Assignments

```bash
oc apply -f app/namespace.yaml
oc apply -f app/service-accounts.yaml
oc apply -f app/cluster-spiffeid.yaml
oc apply -f app/spiffe-helper-config.yaml
```

This creates:
- Namespace `ztwim-simple` with label `spiffe.io/demo: "true"`
- Three ServiceAccounts: `data-service`, `consumer`, `consumer-unauthorized`
- A `ClusterSPIFFEID` that assigns SPIFFE IDs based on namespace and ServiceAccount: `spiffe://idc.com/ns/<namespace>/sa/<service-account>`

### 3. Build the Container Image

```bash
oc new-build --binary --name=ztwim-simple -n ztwim-simple --strategy=docker
oc start-build ztwim-simple --from-dir=src/ -n ztwim-simple --follow
```

### 4. Deploy the Workloads

```bash
oc apply -f app/data-service.yaml
oc apply -f app/consumer.yaml
oc apply -f app/consumer-unauthorized.yaml
```

Wait for all pods to be running (2/2 — app + spiffe-helper sidecar):

```bash
oc get pods -n ztwim-simple -w
```

### 5. Access the Dashboards

Get the Route URLs:

```bash
oc get routes -n ztwim-simple
```

Open both URLs in a browser side-by-side:
- **consumer** → green dashboard, ACCESS GRANTED, shows the secret payload
- **consumer-unauthorized** → red dashboard, ACCESS DENIED, shows the rejected SPIFFE ID

## Verification

```bash
# Check authorized consumer — should show AUTHORIZED
oc logs -n ztwim-simple deploy/consumer -c consumer --tail=5

# Check unauthorized consumer — should show DENIED with HTTP 403
oc logs -n ztwim-simple deploy/consumer-unauthorized -c consumer --tail=5

# Check data-service — should show ALLOWED and DENIED entries
oc logs -n ztwim-simple deploy/data-service -c data-service --tail=10

# Inspect an SVID certificate
oc exec -n ztwim-simple deploy/consumer -c consumer -- \
  openssl x509 -in /certs/tls.crt -text -noout | grep -E "URI:|Issuer:|Not After"
```

## What the Logs Show

All three workloads produce step-by-step debug logs that walk through the mTLS + SPIFFE ID validation flow. This makes the logs suitable for live demo narration.

### data-service startup

```
[data-service] SVID files found (delivered by spiffe-helper sidecar via SPIRE Workload API)
[data-service] My SPIFFE ID: spiffe://idc.com/ns/ztwim-simple/sa/data-service
[data-service] mTLS server configured:
[data-service]   - Server certificate: /certs/tls.crt (X.509 SVID)
[data-service]   - Client auth: REQUIRED (mutual TLS)
[data-service]   - Trust anchor: /certs/bundle.crt (SPIRE CA bundle)
[data-service]   - Listening on port 8443
[data-service] Allow-list (SPIFFE IDs that can access /secret):
[data-service]   - spiffe://idc.com/ns/ztwim-simple/sa/consumer
[data-service] Ready to serve requests.
```

### data-service handling a request (granted)

```
[data-service] --- Incoming request from 10.233.0.77 ---
[data-service]   Step 1: mTLS handshake completed (client presented a valid X.509 SVID)
[data-service]   Step 2: Extracting client certificate SAN (Subject Alternative Name)...
[data-service]   Step 3: Client SPIFFE ID from certificate: spiffe://idc.com/ns/ztwim-simple/sa/consumer
[data-service]   Step 4: Checking SPIFFE ID against allow-list: [...]
[data-service]   Step 5: RESULT -> ACCESS GRANTED (SPIFFE ID is on the allow-list)
```

### data-service handling a request (denied)

```
[data-service] --- Incoming request from 10.234.0.38 ---
[data-service]   Step 1: mTLS handshake completed (client presented a valid X.509 SVID)
[data-service]   Step 2: Extracting client certificate SAN (Subject Alternative Name)...
[data-service]   Step 3: Client SPIFFE ID from certificate: spiffe://idc.com/ns/ztwim-simple/sa/consumer-unauthorized
[data-service]   Step 4: Checking SPIFFE ID against allow-list: [...]
[data-service]   Step 5: RESULT -> ACCESS DENIED (SPIFFE ID '...' is NOT on the allow-list)
```

### consumer startup

```
[consumer] SVID files received from SPIRE (via spiffe-helper sidecar)
[consumer]   My SPIFFE ID:    spiffe://idc.com/ns/ztwim-simple/sa/consumer
[consumer]   Certificate:     /certs/tls.crt
[consumer]   Serial:          c0:fb:6b:f6:0f:6c:34:b4:...
[consumer]   Expires:         Jun  6 19:07:44 2026 GMT
[consumer]   Issuer (CA):     C=US, O=IDC, CN=ZTWIM Demo CA, ...
[consumer] Target data-service: https://data-service.ztwim-simple.svc:8443/secret
[consumer] Will attempt mTLS connection every 5s, presenting my SVID as client certificate
```

### consumer per-request flow (authorized)

```
[consumer] --- Request #1 to data-service ---
[consumer]   Step 1: Loading my X.509 SVID for mTLS client authentication
[consumer]            Identity: spiffe://idc.com/ns/ztwim-simple/sa/consumer
[consumer]   Step 2: Connecting to https://data-service.ztwim-simple.svc:8443/secret
[consumer]            Using mutual TLS (presenting my SVID as client certificate)
[consumer]   Step 3: mTLS handshake succeeded (data-service verified my SVID)
[consumer]   Step 4: RESULT -> ACCESS GRANTED (HTTP 200)
[consumer]            data-service confirmed my SPIFFE ID is on the allow-list
```

### consumer per-request flow (unauthorized)

```
[consumer] --- Request #1 to data-service ---
[consumer]   Step 1: Loading my X.509 SVID for mTLS client authentication
[consumer]            Identity: spiffe://idc.com/ns/ztwim-simple/sa/consumer-unauthorized
[consumer]   Step 2: Connecting to https://data-service.ztwim-simple.svc:8443/secret
[consumer]            Using mutual TLS (presenting my SVID as client certificate)
[consumer]   Step 3: mTLS handshake succeeded (my SVID is valid)
[consumer]   Step 4: RESULT -> ACCESS DENIED (HTTP 403)
[consumer]            data-service rejected my SPIFFE ID — not on the allow-list
[consumer]            Allowed: ['spiffe://idc.com/ns/ztwim-simple/sa/consumer']
```

### SVID rotation

When SPIRE rotates certificates (default: every hour), both consumers and the data-service log the event:

```
[data-service] SVID rotated — reloaded TLS context (my identity: spiffe://idc.com/ns/ztwim-simple/sa/data-service)
[consumer] SVID certificate rotated by SPIRE (new serial: a1:b2:c3:...)
[consumer]   New expiry: Jun  7 19:07:44 2026 GMT
```

## Cleanup

```bash
# Remove demo workloads
oc delete -f app/consumer-unauthorized.yaml
oc delete -f app/consumer.yaml
oc delete -f app/data-service.yaml
oc delete -f app/spiffe-helper-config.yaml
oc delete -f app/cluster-spiffeid.yaml
oc delete -f app/service-accounts.yaml
oc delete -f app/namespace.yaml

# Remove SPIRE infrastructure
oc delete -f infra/spire-oidc-discovery.yaml
oc delete -f infra/spiffe-csi-driver.yaml
oc delete -f infra/spire-agent.yaml
oc delete -f infra/spire-server.yaml
oc delete -f infra/ztwim.yaml
```

## File Structure

```
idc-demo/
├── README.md
├── infra/                          # SPIRE infrastructure (cluster-scoped)
│   ├── ztwim.yaml                  #   Parent CR — trust domain: idc.com
│   ├── spire-server.yaml           #   SPIRE Server (SQLite3, EC P-256 CA)
│   ├── spire-agent.yaml            #   SPIRE Agent (PSAT attestor)
│   ├── spiffe-csi-driver.yaml      #   SPIFFE CSI Driver
│   └── spire-oidc-discovery.yaml   #   OIDC Discovery Provider
├── app/                            # Demo application (namespace-scoped)
│   ├── namespace.yaml              #   Namespace ztwim-simple
│   ├── service-accounts.yaml       #   3 ServiceAccounts
│   ├── cluster-spiffeid.yaml       #   SPIFFE ID template assignment
│   ├── spiffe-helper-config.yaml   #   spiffe-helper sidecar config
│   ├── data-service.yaml           #   mTLS server + Service
│   ├── consumer.yaml               #   Authorized consumer + Route
│   └── consumer-unauthorized.yaml  #   Unauthorized consumer + Route
└── src/                            # Application source code
    ├── Containerfile               #   Container build file
    ├── data_service.py             #   mTLS server (validates SPIFFE IDs)
    ├── consumer.py                 #   Web dashboard + mTLS client
    └── templates/
        └── index.html              #   Dashboard HTML (auto-refreshes)
```

## Key Design Points

- **Same image, different ServiceAccount** — identity comes from the workload's SA, not the code. Both consumers run identical code but get different SPIFFE IDs.
- **Application-level authorization** — both consumers establish valid mTLS (SPIRE issues SVIDs to both), but only the authorized one passes the SPIFFE ID check. The demo message: "authentication succeeded, authorization failed."
- **spiffe-helper sidecar** — the SPIFFE CSI driver mounts a Workload API Unix socket, not PEM files. The `spiffe-helper` sidecar (Red Hat image: `registry.redhat.io/zero-trust-workload-identity-manager/spiffe-helper-rhel9:v0.10.0`) bridges the gap by reading from the socket and writing PEM files the Python app can consume.
- **Python stdlib only** — no pip dependencies. The `ssl` module handles mTLS, `http.server` serves the dashboard, `openssl` CLI parses certificate details.
- **Trust domain `idc.com`** — configured in the parent `ZeroTrustWorkloadIdentityManager` CR and referenced in the `ClusterSPIFFEID` template.
