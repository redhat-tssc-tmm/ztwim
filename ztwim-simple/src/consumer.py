import http.server
import json
import os
import ssl
import subprocess
import threading
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

SVID_DIR = os.environ.get("SVID_DIR", "/spiffe-workload")
CERT_FILE = os.path.join(SVID_DIR, "tls.crt")
KEY_FILE = os.path.join(SVID_DIR, "tls.key")
BUNDLE_FILE = os.path.join(SVID_DIR, "bundle.crt")
DATA_SERVICE_URL = os.environ.get("DATA_SERVICE_URL", "https://data-service:8443/secret")
WEB_PORT = int(os.environ.get("WEB_PORT", "8080"))
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "5"))

TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), "templates")

status_lock = threading.Lock()
current_status = {
    "own_spiffe_id": "loading...",
    "svid_serial": "",
    "svid_expires": "",
    "svid_issuer": "",
    "target_url": DATA_SERVICE_URL,
    "last_result": None,
    "access_log": [],
    "timestamp": "",
}

request_count = 0


def log(msg):
    print(f"[consumer] {msg}", flush=True)


def parse_cert_info(cert_path):
    try:
        text = subprocess.check_output(
            ["openssl", "x509", "-in", cert_path, "-text", "-noout"],
            stderr=subprocess.DEVNULL,
        ).decode()

        info = {"spiffe_id": "", "serial": "", "expires": "", "issuer": ""}

        lines = text.splitlines()
        for i, line in enumerate(lines):
            line = line.strip()
            if line.startswith("Serial Number:"):
                serial_val = line.split(":", 1)[1].strip()
                if not serial_val and i + 1 < len(lines):
                    serial_val = lines[i + 1].strip()
                info["serial"] = serial_val
            elif "Not After" in line:
                info["expires"] = line.split(" : ", 1)[1].strip() if " : " in line else line.split(":", 1)[1].strip()
            elif line.startswith("Issuer:"):
                info["issuer"] = line.split(":", 1)[1].strip()
            elif "URI:spiffe://" in line:
                info["spiffe_id"] = line.split("URI:", 1)[1].strip()

        return info
    except Exception as e:
        return {"spiffe_id": f"error: {e}", "serial": "", "expires": "", "issuer": ""}


def call_data_service():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)
    ctx.load_verify_locations(BUNDLE_FILE)
    ctx.check_hostname = False
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2

    req = urllib.request.Request(DATA_SERVICE_URL)
    try:
        resp = urllib.request.urlopen(req, context=ctx, timeout=10)
        body = json.loads(resp.read().decode())
        return {"status_code": resp.status, "body": body}
    except urllib.error.HTTPError as e:
        body = json.loads(e.read().decode()) if e.fp else {"error": str(e)}
        return {"status_code": e.code, "body": body}
    except Exception as e:
        return {"status_code": 0, "body": {"error": str(e)}}


def poller():
    global current_status, request_count
    last_serial = ""
    while True:
        try:
            if not (os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE)):
                time.sleep(2)
                continue

            request_count += 1
            cert_info = parse_cert_info(CERT_FILE)

            if cert_info["serial"] != last_serial:
                if last_serial:
                    log(f"SVID certificate rotated by SPIRE (new serial: {cert_info['serial'][:20]}...)")
                    log(f"  New expiry: {cert_info['expires']}")
                last_serial = cert_info["serial"]

            log(f"--- Request #{request_count} to data-service ---")
            log(f"  Step 1: Loading my X.509 SVID for mTLS client authentication")
            log(f"           Identity: {cert_info['spiffe_id']}")
            log(f"  Step 2: Connecting to {DATA_SERVICE_URL}")
            log(f"           Using mutual TLS (presenting my SVID as client certificate)")

            result = call_data_service()
            now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

            if result["status_code"] == 200:
                log(f"  Step 3: mTLS handshake succeeded (data-service verified my SVID)")
                log(f"  Step 4: RESULT -> ACCESS GRANTED (HTTP {result['status_code']})")
                log(f"           data-service confirmed my SPIFFE ID is on the allow-list")
            elif result["status_code"] == 403:
                log(f"  Step 3: mTLS handshake succeeded (my SVID is valid)")
                log(f"  Step 4: RESULT -> ACCESS DENIED (HTTP {result['status_code']})")
                log(f"           data-service rejected my SPIFFE ID — not on the allow-list")
                log(f"           Allowed: {result['body'].get('allowed_identities', [])}")
            elif result["status_code"] == 0:
                log(f"  Step 3: RESULT -> CONNECTION FAILED")
                log(f"           Error: {result['body'].get('error', 'unknown')}")

            log_entry = {
                "timestamp": now,
                "status_code": result["status_code"],
                "authorized": result["body"].get("authorized", False),
                "identity_used": cert_info["spiffe_id"],
            }

            with status_lock:
                current_status["own_spiffe_id"] = cert_info["spiffe_id"]
                current_status["svid_serial"] = cert_info["serial"]
                current_status["svid_expires"] = cert_info["expires"]
                current_status["svid_issuer"] = cert_info["issuer"]
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
            template_path = os.path.join(TEMPLATE_DIR, "index.html")
            with open(template_path, "rb") as f:
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
    log(f"Starting consumer workload")
    log(f"Waiting for SVID files from spiffe-helper sidecar...")
    log(f"  Looking for: {CERT_FILE}, {KEY_FILE}, {BUNDLE_FILE}")
    while not (os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE) and os.path.exists(BUNDLE_FILE)):
        time.sleep(1)

    cert_info = parse_cert_info(CERT_FILE)
    log(f"SVID files received from SPIRE (via spiffe-helper sidecar)")
    log(f"  My SPIFFE ID:    {cert_info['spiffe_id']}")
    log(f"  Certificate:     {CERT_FILE}")
    log(f"  Serial:          {cert_info['serial']}")
    log(f"  Expires:         {cert_info['expires']}")
    log(f"  Issuer (CA):     {cert_info['issuer']}")
    log(f"  Trust bundle:    {BUNDLE_FILE}")
    log(f"Target data-service: {DATA_SERVICE_URL}")
    log(f"Will attempt mTLS connection every {POLL_INTERVAL}s, presenting my SVID as client certificate")

    poll_thread = threading.Thread(target=poller, daemon=True)
    poll_thread.start()

    log(f"Web dashboard starting on port {WEB_PORT}")
    server = http.server.HTTPServer(("0.0.0.0", WEB_PORT), ConsumerHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
