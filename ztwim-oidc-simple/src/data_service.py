import http.server
import json
import os
import ssl
import threading
import time
import urllib.request

import jwt
from jwt import PyJWKClient

JWKS_URL = os.environ.get("JWKS_URL", "https://spire-oidc.apps.example.com/keys")
EXPECTED_AUDIENCE = os.environ.get("EXPECTED_AUDIENCE", "data-service")
ALLOWED_IDS = [s.strip() for s in os.environ.get("ALLOWED_SPIFFE_IDS", "").split(",") if s.strip()]
PORT = int(os.environ.get("PORT", "8080"))
JWKS_REFRESH_INTERVAL = int(os.environ.get("JWKS_REFRESH_INTERVAL", "300"))

SECRET_DATA = {
    "classification": "CONFIDENTIAL",
    "project": "Project Phoenix",
    "data": "The launch code is 7-4-1-1-9-2-6",
    "note": "This payload was delivered because your JWT-SVID identity is on the allow-list.",
}

jwks_client = None
jwks_lock = threading.Lock()


def log(msg):
    print(f"[data-service] {msg}", flush=True)


def init_jwks_client():
    global jwks_client
    tls_ctx = ssl.create_default_context()
    tls_ctx.check_hostname = False
    tls_ctx.verify_mode = ssl.CERT_NONE
    jwks_client = PyJWKClient(JWKS_URL, ssl_context=tls_ctx)
    log(f"JWKS client initialized (fetching keys from {JWKS_URL})")


def jwks_refresher():
    while True:
        time.sleep(JWKS_REFRESH_INTERVAL)
        try:
            with jwks_lock:
                jwks_client.fetch_data()
            log("JWKS keys refreshed from SPIRE OIDC Discovery Provider")
        except Exception as e:
            log(f"JWKS refresh error: {e}")


def validate_jwt(token):
    with jwks_lock:
        signing_key = jwks_client.get_signing_key_from_jwt(token)
    payload = jwt.decode(
        token,
        signing_key.key,
        algorithms=["ES256", "ES384", "RS256"],
        audience=EXPECTED_AUDIENCE,
        options={"verify_iss": False},
    )
    return payload


class DataServiceHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/secret":
            self.send_error(404)
            return

        log(f"--- Incoming request from {self.client_address[0]} ---")

        auth_header = self.headers.get("Authorization", "")
        if not auth_header.startswith("Bearer "):
            log("  Step 1: No Authorization header or not Bearer token")
            log("  RESULT -> REJECTED (HTTP 401 — no token)")
            self._send_json(401, {
                "authorized": False,
                "error": "Missing or invalid Authorization header. Expected: Bearer <JWT-SVID>",
            })
            return

        token = auth_header[7:]
        log("  Step 1: Extracted Bearer token from Authorization header")

        try:
            log("  Step 2: Validating JWT signature against SPIRE JWKS...")
            payload = validate_jwt(token)
            log(f"  Step 3: JWT signature valid. Claims:")
            log(f"           sub (SPIFFE ID): {payload.get('sub', '?')}")
            log(f"           aud (audience):  {payload.get('aud', '?')}")
            log(f"           iss (issuer):    {payload.get('iss', '?')}")
            log(f"           exp (expires):   {payload.get('exp', '?')}")
        except jwt.ExpiredSignatureError:
            log("  Step 2: RESULT -> REJECTED (JWT expired)")
            self._send_json(401, {"authorized": False, "error": "JWT-SVID has expired"})
            return
        except jwt.InvalidAudienceError:
            log(f"  Step 2: RESULT -> REJECTED (wrong audience, expected '{EXPECTED_AUDIENCE}')")
            self._send_json(401, {"authorized": False, "error": f"JWT audience does not match '{EXPECTED_AUDIENCE}'"})
            return
        except Exception as e:
            log(f"  Step 2: RESULT -> REJECTED (JWT validation failed: {e})")
            self._send_json(401, {"authorized": False, "error": f"JWT validation failed: {e}"})
            return

        caller_id = payload.get("sub", "")
        log(f"  Step 4: Checking SPIFFE ID against allow-list: {ALLOWED_IDS}")

        if caller_id in ALLOWED_IDS:
            log(f"  Step 5: RESULT -> ACCESS GRANTED (SPIFFE ID is on the allow-list)")
            self._send_json(200, {
                "authorized": True,
                "your_identity": caller_id,
                "secret": SECRET_DATA,
            })
        else:
            log(f"  Step 5: RESULT -> ACCESS DENIED (SPIFFE ID '{caller_id}' is NOT on the allow-list)")
            self._send_json(403, {
                "authorized": False,
                "your_identity": caller_id,
                "error": f"SPIFFE ID '{caller_id}' is not on the allow-list",
                "allowed_identities": ALLOWED_IDS,
            })

    def _send_json(self, status, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


def main():
    log("Starting data-service (OIDC JWT-SVID validation)")
    log(f"JWKS URL:         {JWKS_URL}")
    log(f"Expected audience: {EXPECTED_AUDIENCE}")
    log(f"Allow-list (SPIFFE IDs that can access /secret):")
    for aid in ALLOWED_IDS:
        log(f"  - {aid}")
    log(f"Listening on port {PORT} (plain HTTP — auth is via JWT Bearer, not mTLS)")

    log("Fetching initial JWKS from SPIRE OIDC Discovery Provider...")
    for attempt in range(1, 31):
        try:
            init_jwks_client()
            log("JWKS loaded successfully.")
            break
        except Exception as e:
            log(f"  Attempt {attempt}/30: JWKS fetch failed ({e}), retrying in 5s...")
            time.sleep(5)
    else:
        log("ERROR: Could not fetch JWKS after 30 attempts. Exiting.")
        return

    refresher = threading.Thread(target=jwks_refresher, daemon=True)
    refresher.start()

    log("Ready to serve requests.")
    server = http.server.HTTPServer(("0.0.0.0", PORT), DataServiceHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
