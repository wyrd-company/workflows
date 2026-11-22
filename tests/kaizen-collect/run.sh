#!/usr/bin/env bash
# Checks that kaizen-collect-run passes its day on, refuses a day that is not a
# date, fails when the collection is missing or fails, and that the DAG is valid. A stub stands in for collect.py, so nothing
# is read or written outside a temporary folder. Usage: tests/kaizen-collect/run.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: expected '$want', got '$got'" >&2
        failures=$((failures + 1))
    fi
}

mkdir "$tmp/collect" "$tmp/failing"
cat > "$tmp/collect/collect.py" <<'PY'
import sys
print(" ".join(sys.argv[1:]))
PY
cat > "$tmp/failing/collect.py" <<'PY'
import sys
sys.exit(7)
PY

run() { KAIZEN_COLLECT_DIR="$tmp/collect" "$root/bin/kaizen-collect-run"; }

check "no day collects every missing day" "run" "$(env -u DAY KAIZEN_COLLECT_DIR="$tmp/collect" "$root/bin/kaizen-collect-run")"
check "an empty day collects every missing day" "run" "$(DAY="" run)"
check "a day is passed on" "run --day 2026-01-02" "$(DAY=2026-01-02 run)"

status=0
out="$(DAY='2026-01-02"; echo injected; "' run 2>/dev/null)" || status=$?
check "a day that is not a date is refused" "2:" "$status:$out"

status=0
KAIZEN_COLLECT_DIR="$tmp/missing" "$root/bin/kaizen-collect-run" 2>/dev/null || status=$?
check "a missing collection fails" "1" "$status"

status=0
KAIZEN_COLLECT_DIR="$tmp/failing" "$root/bin/kaizen-collect-run" 2>/dev/null || status=$?
check "a failed collection fails the step" "7" "$status"

out="$(dagu dry --dagu-home "$tmp/dagu" "$root/dags/kaizen-collect.yml" 2>&1)" || true
check "the DAG dry run succeeds" "yes" "$(grep -Fq 'Result: Succeeded' <<<"$out" && echo yes || echo "$out")"

exit "$failures"
