#!/usr/bin/env bash
# Tests the model choice in the Bonsai launchers, with fake llama binaries.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; SRC="$(cd "$(dirname "$0")/.." && pwd)"; fail=0
setup() {
  rm -rf "$T"; mkdir -p "$T/kit/llama-prism/llama-prism-b10809-b3ebc47" "$T/cache"
  cp "$SRC/bonsai" "$SRC/bonsai-web" "$T/kit/"
  for b in llama-cli llama-server; do
    printf '#!/usr/bin/env bash\necho "$@" > "%s/args-%s"\nexit 0\n' "$T" "$b" > "$T/kit/llama-prism/llama-prism-b10809-b3ebc47/$b"
    chmod +x "$T/kit/llama-prism/llama-prism-b10809-b3ebc47/$b"
  done
}
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
# 1. bonsai uses the one GGUF next to it
setup; touch "$T/kit/model-x.gguf"; "$T/kit/bonsai" >/dev/null 2>&1
check "bonsai picks the GGUF next to it" 'grep -q -- "-m $T/kit/model-x.gguf" "$T/args-llama-cli" 2>/dev/null'
# 2. BONSAI_MODEL wins
setup; touch "$T/kit/model-x.gguf"; BONSAI_MODEL=/elsewhere/other.gguf "$T/kit/bonsai" >/dev/null 2>&1
check "bonsai uses BONSAI_MODEL when set" 'grep -q -- "-m /elsewhere/other.gguf" "$T/args-llama-cli" 2>/dev/null'
# 3. no model: clear message, llama-cli never runs
setup; out=$("$T/kit/bonsai" 2>&1); code=$?
check "bonsai stops with a message when there is no model" '[ $code -ne 0 ] && [ ! -e "$T/args-llama-cli" ] && echo "$out" | grep -qi "BONSAI_MODEL"'
# 4. bonsai-web passes the same model to llama-server (the fake exits at once).
# A fake curl says no server is up, so a real Bonsai on 8089 can't change the
# result (fixed 2026-11-21: the test failed while a real one was running).
setup; touch "$T/kit/model-x.gguf"; mkdir -p "$T/downbin"; printf '#!/usr/bin/env bash\nexit 7\n' > "$T/downbin/curl"; chmod +x "$T/downbin/curl"
PATH="$T/downbin:$PATH" XDG_CACHE_HOME="$T/cache" timeout 20 "$T/kit/bonsai-web" >/dev/null 2>&1
check "bonsai-web picks the GGUF next to it" 'grep -q -- "-m $T/kit/model-x.gguf" "$T/args-llama-server" 2>/dev/null'
# 6. bonsai-web reuses a Bonsai that's already up (bonsai-serve), instead of refusing (added 2026-11-21)
setup; touch "$T/kit/model-x.gguf"; mkdir -p "$T/fakebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/curl"
printf '#!/usr/bin/env bash\necho "$@" > "%s/args-uv"\n' "$T" > "$T/fakebin/uv"
chmod +x "$T/fakebin/"*
out=$(PATH="$T/fakebin:$PATH" XDG_CACHE_HOME="$T/cache" timeout 20 "$T/kit/bonsai-web" 2>&1); code=$?
check "bonsai-web reuses a running server" '[ $code -eq 0 ] && [ ! -e "$T/args-llama-server" ] && grep -q "127.0.0.1:8089/v1/chat/completions" "$T/args-uv"'
# 5. the published scripts don't name the model file
check "no model file name in the scripts" '! grep -q "Abliterated" "$SRC/bonsai" "$SRC/bonsai-web"'
exit $fail
