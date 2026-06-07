import http.server
import json
import os
import ssl
import subprocess
import threading
import time
from pathlib import Path

SVID_DIR = os.environ.get("SVID_DIR", "/spiffe-workload")
CERT_FILE = os.path.join(SVID_DIR, "tls.crt")
KEY_FILE = os.path.join(SVID_DIR, "tls.key")
BUNDLE_FILE = os.path.join(SVID_DIR, "bundle.crt")
PORT = int(os.environ.get("PORT", "8443"))
ALLOWED_IDS = [s.strip() for s in os.environ.get("ALLOWED_SPIFFE_IDS", "").split(",") if s.strip()]

SECRET_DATA = {
    "classification": "CONFIDENTIAL",
    "project": "Project Phoenix",
    "data": "The launch code is 7-4-1-1-9-2-6",
    "note": "This payload was only delivered because your workload identity is on the allow-list.",
}

ssl_ctx_lock = threading.Lock()
current_ssl_ctx = None


def log(msg):
    print(f"[data-service] {msg}", flush=True)


def parse_own_spiffe_id():
    try:
        text = subprocess.check_output(
            ["openssl", "x509", "-in", CERT_FILE, "-text", "-noout"],
            stderr=subprocess.DEVNULL,
        ).decode()
        for line in text.splitlines():
            if "URI:spiffe://" in line:
                return line.strip().split("URI:", 1)[1].strip()
    except Exception:
        pass
    return "unknown"


def build_ssl_context():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)
    ctx.load_verify_locations(BUNDLE_FILE)
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx


def get_spiffe_id_from_cert(cert):
    sans = cert.get("subjectAltName", ())
    for san_type, san_value in sans:
        if san_type == "URI" and san_value.startswith("spiffe://"):
            return san_value
    return None


class DataServiceHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/secret":
            self.send_error(404)
            return

        log(f"--- Incoming request from {self.client_address[0]} ---")
        log("  Step 1: mTLS handshake completed (client presented a valid X.509 SVID)")

        peer_cert = self.connection.getpeercert()
        if peer_cert:
            log("  Step 2: Extracting client certificate SAN (Subject Alternative Name)...")
            caller_id = get_spiffe_id_from_cert(peer_cert)
            log(f"  Step 3: Client SPIFFE ID from certificate: {caller_id}")
        else:
            caller_id = None
            log("  Step 2: WARNING — no client certificate found in TLS session")

        log(f"  Step 4: Checking SPIFFE ID against allow-list: {ALLOWED_IDS}")

        if caller_id and caller_id in ALLOWED_IDS:
            log(f"  Step 5: RESULT -> ACCESS GRANTED (SPIFFE ID is on the allow-list)")
            response = {
                "authorized": True,
                "your_identity": caller_id,
                "secret": SECRET_DATA,
            }
            self.send_response(200)
        else:
            log(f"  Step 5: RESULT -> ACCESS DENIED (SPIFFE ID '{caller_id}' is NOT on the allow-list)")
            response = {
                "authorized": False,
                "your_identity": caller_id or "unknown",
                "error": f"SPIFFE ID '{caller_id}' is not on the allow-list",
                "allowed_identities": ALLOWED_IDS,
            }
            self.send_response(403)

        body = json.dumps(response, indent=2).encode()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


def cert_watcher():
    global current_ssl_ctx
    last_mtime = 0
    while True:
        try:
            mtime = os.path.getmtime(CERT_FILE)
            if mtime != last_mtime:
                new_ctx = build_ssl_context()
                with ssl_ctx_lock:
                    current_ssl_ctx = new_ctx
                last_mtime = mtime
                own_id = parse_own_spiffe_id()
                log(f"SVID rotated — reloaded TLS context (my identity: {own_id})")
        except Exception as e:
            log(f"Cert watcher error: {e}")
        time.sleep(5)


class ReloadableSSLServer(http.server.HTTPServer):
    def get_request(self):
        newsocket, fromaddr = self.socket.accept()
        with ssl_ctx_lock:
            ctx = current_ssl_ctx
        connstream = ctx.wrap_socket(newsocket, server_side=True)
        return connstream, fromaddr


def main():
    global current_ssl_ctx

    log(f"Waiting for SVID files in {SVID_DIR}...")
    log(f"  Looking for: {CERT_FILE}, {KEY_FILE}, {BUNDLE_FILE}")
    while not (os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE) and os.path.exists(BUNDLE_FILE)):
        time.sleep(1)

    log("SVID files found (delivered by spiffe-helper sidecar via SPIRE Workload API)")
    own_id = parse_own_spiffe_id()
    log(f"My SPIFFE ID: {own_id}")

    current_ssl_ctx = build_ssl_context()
    log(f"mTLS server configured:")
    log(f"  - Server certificate: {CERT_FILE} (X.509 SVID)")
    log(f"  - Client auth: REQUIRED (mutual TLS)")
    log(f"  - Trust anchor: {BUNDLE_FILE} (SPIRE CA bundle)")
    log(f"  - Listening on port {PORT}")
    log(f"Allow-list (SPIFFE IDs that can access /secret):")
    for aid in ALLOWED_IDS:
        log(f"  - {aid}")
    log("Ready to serve requests.")

    watcher = threading.Thread(target=cert_watcher, daemon=True)
    watcher.start()

    server = ReloadableSSLServer(("0.0.0.0", PORT), DataServiceHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
