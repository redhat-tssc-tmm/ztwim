import base64
import http.server
import json
import os
import ssl
import threading
import time
import urllib.request
import urllib.error
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

JWT_FILE = os.environ.get("JWT_FILE", "/certs/jwt_svid.token")
TPA_URL = os.environ.get("TPA_URL", "https://server-trusted-profile-analyzer.apps.cluster-ngll2.dynamic2.redhatworkshops.io/api/v2/advisory?limit=5")
KEYCLOAK_TOKEN_URL = os.environ.get("KEYCLOAK_TOKEN_URL", "https://sso.apps.cluster-ngll2.dynamic2.redhatworkshops.io/realms/backstage/protocol/openid-connect/token")
KC_CLIENT_ID = os.environ.get("KC_CLIENT_ID", "spiffe-consumer")
KC_CLIENT_SECRET = os.environ.get("KC_CLIENT_SECRET", "")
KC_SUBJECT_ISSUER = os.environ.get("KC_SUBJECT_ISSUER", "spire-oidc")
WEB_PORT = int(os.environ.get("WEB_PORT", "8080"))
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "5"))

TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), "templates")

status_lock = threading.Lock()
current_status = {
    "jwt_raw": "",
    "jwt_header": {},
    "jwt_payload": {},
    "spiffe_id": "loading...",
    "audience": "",
    "issuer": "",
    "expires": "",
    "keycloak_token_payload": {},
    "keycloak_exchange_status": "",
    "target_url": TPA_URL,
    "last_result": None,
    "access_log": [],
    "timestamp": "",
}

request_count = 0

tls_ctx = ssl.create_default_context()
tls_ctx.check_hostname = False
tls_ctx.verify_mode = ssl.CERT_NONE


def log(msg):
    print(f"[oidc-consumer] {msg}", flush=True)


def decode_jwt(token):
    parts = token.strip().split(".")
    if len(parts) != 3:
        return {}, {}
    def pad_b64(s):
        return s + "=" * (-len(s) % 4)
    try:
        header = json.loads(base64.urlsafe_b64decode(pad_b64(parts[0])))
        payload = json.loads(base64.urlsafe_b64decode(pad_b64(parts[1])))
        return header, payload
    except Exception:
        return {}, {}


def read_jwt():
    try:
        return Path(JWT_FILE).read_text().strip()
    except Exception:
        return ""


def exchange_for_keycloak_token(jwt_svid):
    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token": jwt_svid,
        "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "subject_issuer": KC_SUBJECT_ISSUER,
        "client_id": KC_CLIENT_ID,
        "client_secret": KC_CLIENT_SECRET,
    }).encode()
    req = urllib.request.Request(KEYCLOAK_TOKEN_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        resp = urllib.request.urlopen(req, context=tls_ctx, timeout=10)
        result = json.loads(resp.read().decode())
        return result.get("access_token", ""), None
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode())
        except Exception:
            body = {"error": str(e)}
        return "", body
    except Exception as e:
        return "", {"error": str(e)}


def call_tpa(bearer_token):
    req = urllib.request.Request(TPA_URL)
    req.add_header("Authorization", f"Bearer {bearer_token}")
    try:
        resp = urllib.request.urlopen(req, context=tls_ctx, timeout=10)
        body = json.loads(resp.read().decode())
        return {"status_code": resp.status, "body": body, "authorized": True}
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode())
        except Exception:
            body = {"error": str(e)}
        return {"status_code": e.code, "body": body, "authorized": False}
    except Exception as e:
        return {"status_code": 0, "body": {"error": str(e)}, "authorized": False}


def format_exp(exp_ts):
    try:
        return datetime.fromtimestamp(exp_ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    except Exception:
        return str(exp_ts)


def poller():
    global current_status, request_count
    last_jwt_iat = 0
    while True:
        try:
            jwt_svid = read_jwt()
            if not jwt_svid:
                time.sleep(2)
                continue

            request_count += 1
            svid_header, svid_payload = decode_jwt(jwt_svid)
            aud = svid_payload.get("aud", [])
            if isinstance(aud, list):
                aud = ", ".join(aud)
            now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
            spiffe_id = svid_payload.get("sub", "unknown")

            jwt_iat = svid_payload.get("iat", 0)
            if jwt_iat != last_jwt_iat:
                if last_jwt_iat:
                    log(f"JWT-SVID rotated by SPIRE (new iat={jwt_iat})")
                    log(f"  New expiry: {format_exp(svid_payload.get('exp', 0))}")
                last_jwt_iat = jwt_iat

            log(f"--- Request #{request_count} ---")
            log(f"  Step 1: Reading JWT-SVID from {JWT_FILE}")
            log(f"           SPIFFE ID (sub): {spiffe_id}")
            log(f"           Audience (aud):  {aud}")
            log(f"           Issuer (iss):    {svid_payload.get('iss', '?')}")
            log(f"           Expires:         {format_exp(svid_payload.get('exp', 0))}")

            log(f"  Step 2: Exchanging JWT-SVID for Keycloak token (RFC 8693 token exchange)")
            log(f"           Token endpoint:  {KEYCLOAK_TOKEN_URL}")
            log(f"           Client ID:       {KC_CLIENT_ID}")
            log(f"           Subject issuer:  {KC_SUBJECT_ISSUER}")

            kc_token, kc_error = exchange_for_keycloak_token(jwt_svid)

            if kc_token:
                _, kc_payload = decode_jwt(kc_token)
                exchange_status = "SUCCESS"
                log(f"  Step 3: Token exchange SUCCEEDED")
                log(f"           Keycloak issued a token with:")
                log(f"             azp:                {kc_payload.get('azp', '?')}")
                log(f"             preferred_username:  {kc_payload.get('preferred_username', '?')}")
                log(f"             scope:               {kc_payload.get('scope', '?')}")

                log(f"  Step 4: Calling TPA API with Keycloak token")
                log(f"           Target: {TPA_URL}")
                log(f"           Auth:   Authorization: Bearer <keycloak-token>")

                result = call_tpa(kc_token)

                if result["authorized"]:
                    log(f"  Step 5: RESULT -> ACCESS GRANTED (HTTP {result['status_code']})")
                    log(f"           TPA accepted the Keycloak token and returned data")
                else:
                    log(f"  Step 5: RESULT -> ACCESS DENIED (HTTP {result['status_code']})")
                    log(f"           TPA rejected the request: {result['body'].get('error', result['body'].get('message', '?'))}")
            else:
                kc_payload = kc_error or {}
                exchange_status = f"FAILED: {kc_error.get('error', 'unknown')}"
                result = {"status_code": 0, "body": {"error": f"Keycloak token exchange failed: {kc_error}"}, "authorized": False}

                log(f"  Step 3: Token exchange FAILED")
                log(f"           Error:       {kc_error.get('error', 'unknown')}")
                log(f"           Description: {kc_error.get('error_description', 'none')}")
                log(f"           This SPIFFE identity is not authorized in Keycloak")
                log(f"  Step 4: RESULT -> ACCESS DENIED (no Keycloak token, cannot call TPA)")

            log_entry = {
                "timestamp": now,
                "status_code": result["status_code"],
                "authorized": result["authorized"],
                "spiffe_id": spiffe_id,
                "exchange": exchange_status,
            }

            with status_lock:
                current_status["jwt_raw"] = jwt_svid
                current_status["jwt_header"] = svid_header
                current_status["jwt_payload"] = svid_payload
                current_status["spiffe_id"] = spiffe_id
                current_status["audience"] = aud
                current_status["issuer"] = svid_payload.get("iss", "unknown")
                current_status["expires"] = format_exp(svid_payload.get("exp", 0))
                current_status["keycloak_token_payload"] = kc_payload
                current_status["keycloak_exchange_status"] = exchange_status
                current_status["last_result"] = result
                current_status["timestamp"] = now
                current_status["access_log"].insert(0, log_entry)
                current_status["access_log"] = current_status["access_log"][:50]

        except Exception as e:
            log(f"Poller error: {e}")

        time.sleep(POLL_INTERVAL)


class ConsumerHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/status":
            with status_lock:
                body = json.dumps(current_status, indent=2).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/":
            with open(os.path.join(TEMPLATE_DIR, "index.html"), "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def log_message(self, fmt, *args):
        pass


def main():
    log("Starting OIDC consumer workload")
    log(f"Waiting for JWT-SVID file from spiffe-helper sidecar...")
    log(f"  Looking for: {JWT_FILE}")
    while not os.path.exists(JWT_FILE):
        time.sleep(1)

    jwt_svid = read_jwt()
    _, payload = decode_jwt(jwt_svid)
    log(f"JWT-SVID received from SPIRE (via spiffe-helper sidecar)")
    log(f"  SPIFFE ID (sub): {payload.get('sub', '?')}")
    log(f"  Audience (aud):  {payload.get('aud', '?')}")
    log(f"  Issuer (iss):    {payload.get('iss', '?')}")
    log(f"  Expires:         {format_exp(payload.get('exp', 0))}")
    log(f"Token exchange configuration:")
    log(f"  Keycloak URL:    {KEYCLOAK_TOKEN_URL}")
    log(f"  Client ID:       {KC_CLIENT_ID}")
    log(f"  Subject issuer:  {KC_SUBJECT_ISSUER} (Keycloak IDP alias for SPIRE)")
    log(f"  Grant type:      urn:ietf:params:oauth:grant-type:token-exchange (RFC 8693)")
    log(f"Target application:")
    log(f"  TPA API:         {TPA_URL}")
    log(f"  Auth method:     Bearer token (Keycloak-issued, after exchange)")
    log(f"Flow: JWT-SVID -> Keycloak token exchange -> Keycloak access token -> TPA API")
    log(f"Will attempt every {POLL_INTERVAL}s")

    poll_thread = threading.Thread(target=poller, daemon=True)
    poll_thread.start()

    log(f"Web dashboard starting on port {WEB_PORT}")
    server = http.server.HTTPServer(("0.0.0.0", WEB_PORT), ConsumerHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
