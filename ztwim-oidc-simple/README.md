# ZTWIM OIDC-Simple Demo — JWT-SVID Authentication via OIDC

A self-contained demo showing SPIFFE JWT-SVIDs used as standard OIDC Bearer tokens. The data-service validates JWTs against SPIRE's JWKS endpoint — no Keycloak, no TPA, no external dependencies.

## How It Works

```
Consumer Pod                              Data Service
    │                                         │
    │  1. spiffe-helper gets JWT-SVID         │
    │     from SPIRE (aud="data-service")     │
    │                                         │
    │  2. GET /secret                         │
    │     Authorization: Bearer <JWT-SVID>    │
    │  ──────────────────────────────────►    │
    │                                         │  3. Fetch JWKS from SPIRE
    │                                         │     OIDC Discovery Provider
    │                                         │  4. Verify JWT signature
    │                                         │  5. Check aud == "data-service"
    │                                         │  6. Check sub against allow-list
    │                                         │
    │  7. 200 + secret data (or 403)          │
    │  ◄──────────────────────────────────    │
```

- **Authorized consumer**: SPIFFE ID `spiffe://idc.com/ns/ztwim-oidc-simple/sa/oidc-consumer` is on the allow-list → 200
- **Unauthorized consumer**: SPIFFE ID `spiffe://idc.com/ns/ztwim-oidc-simple/sa/oidc-consumer-unauth` is NOT on the allow-list → 403

Both consumers get valid JWT-SVIDs with valid signatures. The data-service doesn't know about SPIFFE — it just validates JWTs using standard OIDC (JWKS signature verification + audience + subject checks).

## Prerequisites

- SPIRE infrastructure deployed (from `ztwim-simple/infra/`)
- `oc` CLI logged in as cluster-admin

## Deployment

```bash
# Option A: Using pre-built images
export IMAGE_REGISTRY=quay.io/tssc_demos
./deploy.sh

# Option B: Build in-cluster
./deploy.sh
```

The script auto-detects the cluster domain and updates all manifests.

## Verification

```bash
# Authorized — should show ACCESS GRANTED with JWT validation steps
oc logs -n ztwim-oidc-simple deploy/consumer -c consumer --tail=10

# Unauthorized — should show ACCESS DENIED (sub not on allow-list)
oc logs -n ztwim-oidc-simple deploy/consumer-unauthorized -c consumer --tail=10

# Data service — shows JWKS fetch, signature validation, allow/deny decisions
oc logs -n ztwim-oidc-simple deploy/data-service -c data-service --tail=15
```

## What the Logs Show

### data-service startup

```
[data-service] Starting data-service (OIDC JWT-SVID validation)
[data-service] JWKS URL:         https://spire-oidc.apps.<cluster>/keys
[data-service] Expected audience: data-service
[data-service] Allow-list (SPIFFE IDs that can access /secret):
[data-service]   - spiffe://idc.com/ns/ztwim-oidc-simple/sa/oidc-consumer
[data-service] Fetching initial JWKS from SPIRE OIDC Discovery Provider...
[data-service] JWKS loaded successfully.
[data-service] Ready to serve requests.
```

### data-service handling a request (granted)

```
[data-service] --- Incoming request from 10.233.0.77 ---
[data-service]   Step 1: Extracted Bearer token from Authorization header
[data-service]   Step 2: Validating JWT signature against SPIRE JWKS...
[data-service]   Step 3: JWT signature valid. Claims:
[data-service]            sub (SPIFFE ID): spiffe://idc.com/ns/ztwim-oidc-simple/sa/oidc-consumer
[data-service]            aud (audience):  data-service
[data-service]            iss (issuer):    https://spire-oidc.apps.<cluster>
[data-service]   Step 4: Checking SPIFFE ID against allow-list
[data-service]   Step 5: RESULT -> ACCESS GRANTED (SPIFFE ID is on the allow-list)
```

### data-service handling a request (denied)

```
[data-service] --- Incoming request from 10.234.0.38 ---
[data-service]   Step 1: Extracted Bearer token from Authorization header
[data-service]   Step 2: Validating JWT signature against SPIRE JWKS...
[data-service]   Step 3: JWT signature valid. Claims:
[data-service]            sub (SPIFFE ID): spiffe://idc.com/ns/ztwim-oidc-simple/sa/oidc-consumer-unauth
[data-service]   Step 4: Checking SPIFFE ID against allow-list
[data-service]   Step 5: RESULT -> ACCESS DENIED (SPIFFE ID '...' is NOT on the allow-list)
```

### consumer per-request flow

```
[consumer] --- Request #1 to data-service ---
[consumer]   Step 1: Reading JWT-SVID from /certs/jwt_svid.token
[consumer]            SPIFFE ID (sub): spiffe://idc.com/ns/ztwim-oidc-simple/sa/oidc-consumer
[consumer]            Audience (aud):  data-service
[consumer]   Step 2: Sending request to http://data-service:8080/secret
[consumer]            Authorization: Bearer <JWT-SVID>
[consumer]   Step 3: RESULT -> ACCESS GRANTED (HTTP 200)
[consumer]            data-service validated JWT signature via SPIRE JWKS
```

## File Structure

```
ztwim-oidc-simple/
├── README.md
├── deploy.sh
├── app/
│   ├── namespace.yaml
│   ├── service-accounts.yaml
│   ├── spiffe-helper-config.yaml     # JWT-SVID with aud="data-service"
│   ├── data-service.yaml             # Validates JWTs against SPIRE JWKS
│   ├── consumer.yaml                 # Authorized consumer + Route
│   └── consumer-unauthorized.yaml    # Unauthorized consumer + Route
└── src/
    ├── Containerfile                  # Includes pip install PyJWT[crypto]
    ├── data_service.py               # JWT validation via JWKS
    ├── consumer.py                   # Web dashboard + JWT Bearer client
    └── templates/
        └── index.html
```

## Key Design Points

- **Self-contained**: No Keycloak, no TPA, no external app modifications. Everything runs in one namespace.
- **Standard OIDC validation**: The data-service uses `PyJWT` to verify JWT signatures against SPIRE's JWKS endpoint. It has no SPIFFE-specific logic — it just validates standard JWTs.
- **Identity-based access control**: Both consumers get valid JWT-SVIDs with the same audience. The difference is the `sub` claim (SPIFFE ID) — only one is on the allow-list.
- **Direct JWKS fetch**: The data-service fetches signing keys directly from the SPIRE OIDC Discovery Provider's `/keys` endpoint. No OIDC proxy needed.
- **One pip dependency**: `PyJWT[crypto]` for real JWT signature verification. The other two demos use stdlib only, but JWT signature validation requires crypto primitives.

## Cleanup

```bash
oc delete namespace ztwim-oidc-simple
```

## Showcase Deployment Notes

To deploy on a different cluster:
1. SPIRE infrastructure must be deployed first (from `ztwim-simple/infra/`)
2. Run `./deploy.sh` — it auto-detects the cluster domain
3. Or set `IMAGE_REGISTRY=quay.io/tssc_demos` to use pre-built images
