#!/bin/bash
# PostHog sink against a local fixture server (no real PostHog): the bench posts one batch; the server checks
# the request the way PostHog's /batch/ reads it. Request shape from PostHog's iOS SDK (see app/Analytics.swift).
cd "$(dirname "$0")/.."
D=$(mktemp -d /tmp/td-posthog.XXXX); PORT=$((20000 + RANDOM % 20000))
python3 -I - "$PORT" "$D" <<'PY' &
import http.server, json, sys
port, d = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open(d + "/req.json", "w").write(json.dumps({"path": self.path, "ctype": self.headers.get("Content-Type"), "body": json.loads(body)}))
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":1}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).handle_request()
PY
S=$!; sleep 0.5
POSTHOG_FIXTURE_URL="http://127.0.0.1:$PORT" build/bench 2>&1 | grep "PostHog"
wait $S 2>/dev/null
python3 -I - "$D/req.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); b = r["body"]; e = b["batch"][0]; p = e["properties"]
ok = r["path"] == "/batch/" and r["ctype"].startswith("application/json") and b["api_key"] == "phc_test" and "sent_at" in b \
     and e["event"] == "undo" and len(e["distinct_id"]) == 64 and p["$process_person_profile"] is False and p["$geoip_disable"] is True
print("PASS" if ok else "FAIL", f"fixture received POST {r['path']} with {len(b['batch'])} event, anonymous: person profile {p['$process_person_profile']}, geoip off {p['$geoip_disable']}")
print("RESULT:", "PASS" if ok else "FAIL")
PY
