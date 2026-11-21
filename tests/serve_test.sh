#!/usr/bin/env bash
# Tests for bonsai-serve, run with fake systemd-run, systemctl and curl, so
# nothing real starts. Run from anywhere: tests/serve_test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0

setup() {  # $1: "up" or "down" for the fake health check
  rm -rf "$T/bin" "$T/state" "$T/calls"; mkdir -p "$T/bin" "$T/state"
  : > "$T/calls"
  cat > "$T/bin/systemd-run" <<FAKE
#!/usr/bin/env bash
echo "systemd-run \$*" >> "$T/calls"
FAKE
  cat > "$T/bin/systemctl" <<FAKE
#!/usr/bin/env bash
echo "systemctl \$*" >> "$T/calls"
starts=\$(grep -c '^systemd-run' "$T/calls")
if [ "\$*" = "--user is-active --quiet bonsai-serve" ]; then
  [ "$1" = up ] && exit 0
  [ "$1" = gpu-dies ] && [ "\$starts" -ge 2 ] && exit 0
  exit 3
fi
exit 0
FAKE
  cat > "$T/bin/curl" <<FAKE
#!/usr/bin/env bash
starts=\$(grep -c '^systemd-run' "$T/calls")
[ "$1" = up ] && exit 0
[ "$1" = gpu-dies ] && [ "\$starts" -ge 2 ] && exit 0
exit 7
FAKE
  chmod +x "$T/bin/"*
  printf 'MemTotal: 32000000 kB\nMemAvailable: 20000000 kB\n' > "$T/meminfo"
}

serve() {  # runs bonsai-serve with the fakes; prints its output
  PATH="$T/bin:$PATH" BONSAI_STATE="$T/state" BONSAI_MODEL=/models/bonsai.gguf BONSAI_WRAP="" \
    BONSAI_MEMINFO="$T/meminfo" BONSAI_WAIT=2 "$HERE/bonsai-serve" "$@"
}

check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
started() { grep '^systemd-run' "$T/calls"; }

# Each level starts llama-server with its own context and cache type.
# (Fixed 2026-11-21: the checks used $1..$3, which inside check() are check's
# own arguments; the values are named now.)
for case in "low 16384 q8_0" "medium 32768 q8_0" "high 65536 q4_0"; do
  read -r lvl ctx kv <<< "$case"
  setup up; out=$(serve "$lvl" 2>&1); code=$?
  check "$lvl: exit 0 once the server is up" '[ $code -eq 0 ]'
  check "$lvl: context $ctx" 'started | grep -q -- "-c $ctx "'
  check "$lvl: cache $kv" 'started | grep -q -- "-ctk $kv -ctv $kv"'
  check "$lvl: level saved" '[ "$(cat "$T/state/effort")" = "$lvl" ]'
done

# max: 180K (owner, 2026-11-21). It fits on the 12 GB GPU when little else uses
# it (measured 11.7 GB), so it tries the GPU first.
setup up; out=$(serve max 2>&1); code=$?
check "max: 180K context with a q4_0 cache, on the GPU first" '[ $code -eq 0 ] && started | grep -q -- "-c 184320 -ctk q4_0 -ctv q4_0" && ! started | grep -q -- "-nkvo"'
check "max: level saved" '[ "$(cat "$T/state/effort")" = max ]'

# If the GPU start dies (out of memory), max retries with the cache in RAM.
setup gpu-dies; out=$(serve max 2>&1); code=$?
check "max: falls back to the cache in RAM when the GPU start dies" '[ $code -eq 0 ] && [ "$(started | wc -l)" -eq 2 ] && started | tail -1 | grep -q -- "-c 184320 -ctk q4_0 -ctv q4_0 -nkvo"'
check "max: says it fell back" 'echo "$out" | grep -q -i "ram"'

# The RAM fallback needs about 4 GB and must leave 7 GB free (the 25 GB rule).
setup gpu-dies; printf 'MemTotal: 32000000 kB\nMemAvailable: 9000000 kB\n' > "$T/meminfo"; out=$(serve max 2>&1); code=$?
check "max: refuses the RAM fallback when it would leave under 7 GB free" '[ $code -eq 3 ] && [ "$(started | wc -l)" -eq 1 ] && echo "$out" | grep -q -i "memory"'

setup up; serve medium >/dev/null 2>&1
check "runs as the systemd user unit bonsai-serve" 'started | grep -q -- "--user --unit=bonsai-serve"'
check "listens on localhost only" 'started | grep -q -- "--host 127.0.0.1 --port 8089"'
check "uses the model it is given" 'started | grep -q -- "-m /models/bonsai.gguf"'
check "keeps the model on the GPU" 'started | grep -q -- "-ngl 99"'
check "does not switch thinking off for every request" '! started | grep -q -- "-rea off"'
check "stops the running server before starting the new one" '[ "$(grep -n "systemctl --user stop bonsai-serve" "$T/calls" | head -1 | cut -d: -f1)" -lt "$(grep -n "^systemd-run" "$T/calls" | cut -d: -f1)" ]'

setup up; PATH="$T/bin:$PATH" BONSAI_STATE="$T/state" BONSAI_MODEL=/m.gguf BONSAI_WRAP=/opt/wrap BONSAI_WAIT=2 BONSAI_MEMINFO="$T/meminfo" "$HERE/bonsai-serve" low >/dev/null 2>&1
check "runs the server through BONSAI_WRAP when set" 'started | grep -q -- " /opt/wrap .*llama-server"'

setup up; out=$(serve turbo 2>&1); code=$?
check "an unknown level exits 2 with the usage" '[ $code -eq 2 ] && echo "$out" | grep -q -i "usage"'
check "an unknown level starts nothing" '! grep -q "^systemd-run" "$T/calls"'

setup down; out=$(serve low 2>&1); code=$?
check "says so and exits 1 when the server never comes up" '[ $code -eq 1 ] && echo "$out" | grep -q -i "not ready"'

setup up; echo high > "$T/state/effort"; out=$(serve status 2>&1)
check "status shows the level and that it is up" 'echo "$out" | grep -q "high" && echo "$out" | grep -q -i "up"'
setup down; echo low > "$T/state/effort"; out=$(serve status 2>&1)
check "status shows when it is down" 'echo "$out" | grep -q -i "down"'

setup up; serve stop >/dev/null 2>&1
check "stop stops the unit" 'grep -q "systemctl --user stop bonsai-serve" "$T/calls"'

# Fix A (2026-11-21): every start has the key file and the localhost-only CORS flags.
for lvl in low medium high max; do
  setup up; serve "$lvl" >/dev/null 2>&1
  check "$lvl: starts with the key file" 'started | grep -q -- "--api-key-file $T/state/api-key"'
  check "$lvl: answers browser pages from localhost only" 'started | grep -q -- "--cors-origins localhost"'
done
setup gpu-dies; serve max >/dev/null 2>&1
check "max RAM fallback: has the key file and the CORS flag too" '[ "$(started | wc -l)" -eq 2 ] && started | tail -1 | grep -q -- "--api-key-file $T/state/api-key" && started | tail -1 | grep -q -- "--cors-origins localhost"'

setup up; serve medium >/dev/null 2>&1
check "a missing key file is made: 48 letters and digits" '[ "$(wc -c < "$T/state/api-key" | tr -d " ")" -ge 48 ] && head -n 1 "$T/state/api-key" | grep -Eq "^[A-Za-z0-9]{48}$"'
check "the key file is mode 600" '[ "$(stat -c %a "$T/state/api-key")" = 600 ]'
setup up; echo "my-own-key" > "$T/state/api-key"; serve medium >/dev/null 2>&1
check "a key that is there is kept" '[ "$(cat "$T/state/api-key")" = "my-own-key" ]'
setup up; : > "$T/state/api-key"; serve medium >/dev/null 2>&1
check "an empty key file gets a new key" 'head -n 1 "$T/state/api-key" | grep -Eq "^[A-Za-z0-9]{48}$"'
# llama-server reads no key from blank or # lines, and then asks for none, so such a file counts as missing (lead's review, 2026-11-21).
setup up; printf '\n  \n# a note\n' > "$T/state/api-key"; serve medium >/dev/null 2>&1
check "a key file with only blank lines and comments gets a new key" 'head -n 1 "$T/state/api-key" | grep -Eq "^[A-Za-z0-9]{48}$"'
setup up; out=$(serve medium 2>&1); k=$(cat "$T/state/api-key" 2>/dev/null)
check "the key is never printed or on a command line" '[ -n "$k" ] && ! echo "$out" | grep -qF -- "$k" && ! grep -qF -- "$k" "$T/calls"'

exit $fail
