import base64
import http.server
import json
import os
import threading
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

JWT_FILE = os.environ.get("JWT_FILE", "/certs/jwt_svid.token")
DATA_SERVICE_URL = os.environ.get("DATA_SERVICE_URL", "http://data-service:8080/secret")
WEB_PORT = int(os.environ.get("WEB_PORT", "8080"))
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "5"))

TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), "templates")

status_lock = threading.Lock()
current_status = {
    "jwt_header": {},
    "jwt_payload": {},
    "spiffe_id": "loading...",
    "audience": "",
    "issuer": "",
    "expires": "",
    "target_url": DATA_SERVICE_URL,
    "last_result": None,
    "access_log": [],
    "timestamp": "",
}

request_count = 0


def log(msg):
    print(f"[consumer] {msg}", flush=True)


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


def format_exp(exp_ts):
    try:
        return datetime.fromtimestamp(exp_ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    except Exception:
        return str(exp_ts)


def call_data_service(jwt_token):
    req = urllib.request.Request(DATA_SERVICE_URL)
    req.add_header("Authorization", f"Bearer {jwt_token}")
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        body = json.loads(resp.read().decode())
        return {"status_code": resp.status, "body": body}
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode())
        except Exception:
            body = {"error": str(e)}
        return {"status_code": e.code, "body": body}
    except Exception as e:
        return {"status_code": 0, "body": {"error": str(e)}}


def poller():
    global current_status, request_count
    last_jwt_iat = 0
    while True:
        try:
            jwt_token = read_jwt()
            if not jwt_token:
                time.sleep(2)
                continue

            request_count += 1
            header, payload = decode_jwt(jwt_token)
            spiffe_id = payload.get("sub", "unknown")
            aud = payload.get("aud", [])
            if isinstance(aud, list):
                aud = ", ".join(aud)
            now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

            jwt_iat = payload.get("iat", 0)
            if jwt_iat != last_jwt_iat:
                if last_jwt_iat:
                    log(f"JWT-SVID rotated by SPIRE (new iat={jwt_iat})")
                    log(f"  New expiry: {format_exp(payload.get('exp', 0))}")
                last_jwt_iat = jwt_iat

            log(f"--- Request #{request_count} to data-service ---")
            log(f"  Step 1: Reading JWT-SVID from {JWT_FILE}")
            log(f"           SPIFFE ID (sub): {spiffe_id}")
            log(f"           Audience (aud):  {aud}")
            log(f"           Issuer (iss):    {payload.get('iss', '?')}")
            log(f"  Step 2: Sending request to {DATA_SERVICE_URL}")
            log(f"           Authorization: Bearer <JWT-SVID>")

            result = call_data_service(jwt_token)

            if result["status_code"] == 200:
                log(f"  Step 3: RESULT -> ACCESS GRANTED (HTTP {result['status_code']})")
                log(f"           data-service validated JWT signature via SPIRE JWKS")
                log(f"           and confirmed SPIFFE ID is on the allow-list")
            elif result["status_code"] == 403:
                log(f"  Step 3: RESULT -> ACCESS DENIED (HTTP {result['status_code']})")
                log(f"           data-service validated JWT (signature OK) but")
                log(f"           SPIFFE ID '{spiffe_id}' is NOT on the allow-list")
                log(f"           Allowed: {result['body'].get('allowed_identities', [])}")
            elif result["status_code"] == 401:
                log(f"  Step 3: RESULT -> UNAUTHORIZED (HTTP {result['status_code']})")
                log(f"           JWT validation failed: {result['body'].get('error', '?')}")
            else:
                log(f"  Step 3: RESULT -> CONNECTION FAILED (code={result['status_code']})")
                log(f"           Error: {result['body'].get('error', '?')}")

            log_entry = {
                "timestamp": now,
                "status_code": result["status_code"],
                "authorized": result["body"].get("authorized", False),
                "identity_used": spiffe_id,
            }

            with status_lock:
                current_status["jwt_header"] = header
                current_status["jwt_payload"] = payload
                current_status["spiffe_id"] = spiffe_id
                current_status["audience"] = aud
                current_status["issuer"] = payload.get("iss", "unknown")
                current_status["expires"] = format_exp(payload.get("exp", 0))
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

    jwt_token = read_jwt()
    _, payload = decode_jwt(jwt_token)
    aud = payload.get("aud", [])
    if isinstance(aud, list):
        aud = ", ".join(aud)
    log(f"JWT-SVID received from SPIRE (via spiffe-helper sidecar)")
    log(f"  SPIFFE ID (sub): {payload.get('sub', '?')}")
    log(f"  Audience (aud):  {aud}")
    log(f"  Issuer (iss):    {payload.get('iss', '?')}")
    log(f"  Expires:         {format_exp(payload.get('exp', 0))}")
    log(f"Target: {DATA_SERVICE_URL}")
    log(f"Auth:   JWT-SVID sent as Authorization: Bearer header")
    log(f"        data-service validates JWT signature against SPIRE JWKS")
    log(f"Will attempt every {POLL_INTERVAL}s")

    poll_thread = threading.Thread(target=poller, daemon=True)
    poll_thread.start()

    log(f"Web dashboard starting on port {WEB_PORT}")
    server = http.server.HTTPServer(("0.0.0.0", WEB_PORT), ConsumerHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
