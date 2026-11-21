#!/usr/bin/env bash
# Tests that web/agent.py sends the key from the key file (Fix A, 2026-11-21),
# against a fake server. Run from anywhere: tests/agent_test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; SRVPID=""
trap '[ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null; rm -rf "$T"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
cat > "$T/fake.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
T = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(T + "/auth", "a") as f:
            f.write((self.headers.get("Authorization") or "none") + "\n")
        body = b'{"choices":[{"message":{"role":"assistant","content":"pong"}}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
s = HTTPServer(("127.0.0.1", 0), H)
open(T + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -I "$T/fake.py" "$T" & SRVPID=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
URL="http://127.0.0.1:$(cat "$T/port")/v1/chat/completions"
run() { printf 'hello\n' | BONSAI_STATE="$1" timeout 120 uv run --quiet "$HERE/web/agent.py" "$URL" 2>&1; }

mkdir -p "$T/withkey"; printf 'test-key-123\n' > "$T/withkey/api-key"
: > "$T/auth"; out=$(run "$T/withkey")
check "agent.py sends the key from the key file" 'grep -qx "Bearer test-key-123" "$T/auth"'
check "agent.py prints the answer (with a key)" 'echo "$out" | grep -q pong'

mkdir -p "$T/nokey"
: > "$T/auth"; out=$(run "$T/nokey")
check "agent.py sends no Authorization header without a key file" '[ -s "$T/auth" ] && ! grep -qv "^none$" "$T/auth"'
check "agent.py prints the answer (no key)" 'echo "$out" | grep -q pong'
exit $fail
