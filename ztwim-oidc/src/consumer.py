import base64
import http.server
import json
import os
import ssl
import threading
import time
import urllib.request
import urllib.error
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

tls_ctx = ssl.create_default_context()
tls_ctx.check_hostname = False
tls_ctx.verify_mode = ssl.CERT_NONE


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


import urllib.parse


def poller():
    global current_status
    while True:
        try:
            jwt_svid = read_jwt()
            if not jwt_svid:
                time.sleep(2)
                continue

            svid_header, svid_payload = decode_jwt(jwt_svid)
            aud = svid_payload.get("aud", [])
            if isinstance(aud, list):
                aud = ", ".join(aud)
            now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

            kc_token, kc_error = exchange_for_keycloak_token(jwt_svid)

            if kc_token:
                _, kc_payload = decode_jwt(kc_token)
                result = call_tpa(kc_token)
                exchange_status = "SUCCESS"
            else:
                kc_payload = kc_error or {}
                result = {"status_code": 0, "body": {"error": f"Keycloak token exchange failed: {kc_error}"}, "authorized": False}
                exchange_status = f"FAILED: {kc_error.get('error', 'unknown')}"

            log_entry = {
                "timestamp": now,
                "status_code": result["status_code"],
                "authorized": result["authorized"],
                "spiffe_id": svid_payload.get("sub", ""),
                "exchange": exchange_status,
            }

            with status_lock:
                current_status["jwt_raw"] = jwt_svid
                current_status["jwt_header"] = svid_header
                current_status["jwt_payload"] = svid_payload
                current_status["spiffe_id"] = svid_payload.get("sub", "unknown")
                current_status["audience"] = aud
                current_status["issuer"] = svid_payload.get("iss", "unknown")
                current_status["expires"] = format_exp(svid_payload.get("exp", 0))
                current_status["keycloak_token_payload"] = kc_payload
                current_status["keycloak_exchange_status"] = exchange_status
                current_status["last_result"] = result
                current_status["timestamp"] = now
                current_status["access_log"].insert(0, log_entry)
                current_status["access_log"] = current_status["access_log"][:50]

            status_word = "AUTHORIZED" if result["authorized"] else "DENIED"
            print(f"{now} | {status_word} | tpa={result['status_code']} | exchange={exchange_status} | sub={svid_payload.get('sub','')}")
        except Exception as e:
            print(f"Poller error: {e}")

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
    print(f"Waiting for JWT-SVID file at {JWT_FILE}...")
    while not os.path.exists(JWT_FILE):
        time.sleep(1)
    print("JWT-SVID file found.")
    print(f"Keycloak token exchange: {KEYCLOAK_TOKEN_URL}")
    print(f"Keycloak client: {KC_CLIENT_ID}")
    print(f"Target: {TPA_URL}")

    poll_thread = threading.Thread(target=poller, daemon=True)
    poll_thread.start()

    print(f"OIDC Consumer web UI starting on port {WEB_PORT}")
    server = http.server.HTTPServer(("0.0.0.0", WEB_PORT), ConsumerHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
