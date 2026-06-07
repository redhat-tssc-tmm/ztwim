import base64
import http.server
import json
import os
import ssl
import urllib.request

SPIRE_OIDC_URL = os.environ.get("SPIRE_OIDC_URL", "https://spire-oidc.apps.cluster-ngll2.dynamic2.redhatworkshops.io")
PROXY_EXTERNAL_URL = os.environ.get("PROXY_EXTERNAL_URL", SPIRE_OIDC_URL)
PORT = int(os.environ.get("PORT", "8080"))

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def fetch_upstream(path):
    url = f"{SPIRE_OIDC_URL}{path}"
    req = urllib.request.Request(url)
    resp = urllib.request.urlopen(req, context=ctx, timeout=10)
    return resp.read()


def decode_jwt_payload(token):
    parts = token.strip().split(".")
    if len(parts) != 3:
        return {}
    s = parts[1]
    s += "=" * (-len(s) % 4)
    return json.loads(base64.urlsafe_b64decode(s))


class OIDCProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/userinfo":
            auth = self.headers.get("Authorization", "")
            if auth.startswith("Bearer "):
                token = auth[7:]
                try:
                    payload = decode_jwt_payload(token)
                    userinfo = {
                        "sub": payload.get("sub", ""),
                        "preferred_username": payload.get("sub", ""),
                        "email": payload.get("sub", "").replace("spiffe://", "").replace("/", "-") + "@spiffe.local",
                        "email_verified": True,
                    }
                    body = json.dumps(userinfo).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                except Exception:
                    pass
            self.send_error(401)
            return
        self.send_error(404)

    def do_GET(self):
        if self.path == "/.well-known/openid-configuration":
            try:
                raw = fetch_upstream("/.well-known/openid-configuration")
                doc = json.loads(raw)
                doc["jwks_uri"] = f"{PROXY_EXTERNAL_URL}/keys"
                doc["userinfo_endpoint"] = f"{PROXY_EXTERNAL_URL}/userinfo"
                if not doc.get("authorization_endpoint"):
                    doc["authorization_endpoint"] = f"{PROXY_EXTERNAL_URL}/authorize"
                if not doc.get("token_endpoint"):
                    doc["token_endpoint"] = f"{PROXY_EXTERNAL_URL}/token"
                body = json.dumps(doc, indent=2).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                self.send_error(502, f"Upstream error: {e}")

        elif self.path == "/userinfo":
            auth = self.headers.get("Authorization", "")
            if auth.startswith("Bearer "):
                token = auth[7:]
                try:
                    payload = decode_jwt_payload(token)
                    userinfo = {
                        "sub": payload.get("sub", ""),
                        "preferred_username": payload.get("sub", ""),
                        "email": payload.get("sub", "").replace("spiffe://", "").replace("/", "-") + "@spiffe.local",
                        "email_verified": True,
                    }
                    body = json.dumps(userinfo).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except Exception:
                    self.send_error(401)
            else:
                self.send_error(401)

        elif self.path == "/keys":
            try:
                body = fetch_upstream("/keys")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                self.send_error(502, f"Upstream error: {e}")
        else:
            self.send_error(404)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print(f"OIDC Discovery Proxy starting on port {PORT}")
    print(f"Upstream: {SPIRE_OIDC_URL}")
    print(f"External URL: {PROXY_EXTERNAL_URL}")
    server = http.server.HTTPServer(("0.0.0.0", PORT), OIDCProxyHandler)
    server.serve_forever()
