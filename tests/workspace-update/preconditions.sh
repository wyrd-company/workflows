#!/usr/bin/env bash
# Checks that workspace-update-ansible and workspace-update-dotfiles run their
# step only for a push to main. Dry runs execute no command, so nothing is
# applied. Usage: tests/workspace-update/preconditions.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
home="$(mktemp -d)"
trap 'rm -rf "$home"' EXIT

failures=0
checks=0

# expect DAG STEP REF STATE: the dry run succeeds and STEP ends in STATE
expect() {
    local dag="$1" step="$2" ref="$3" state="$4" out
    checks=$((checks + 1))
    out="$(dagu dry --dagu-home "$home" "$root/sub-dags/$dag.yml" -- "REF=$ref" 2>&1)" || true
    if grep -Fq -- "─$step [$state]" <<<"$out" && grep -Fq 'Result: Succeeded' <<<"$out"; then
        echo "ok   $dag REF=$ref: $step $state"
    else
        echo "FAIL $dag REF=$ref: expected $step $state and Result: Succeeded" >&2
        echo "$out" >&2
        failures=$((failures + 1))
    fi
}

expect workspace-update-ansible ansible-sync refs/heads/main succeeded
expect workspace-update-ansible ansible-sync refs/heads/feat/x skipped
expect workspace-update-ansible ansible-sync refs/tags/1.0.0 skipped
expect workspace-update-dotfiles chezmoi-update refs/heads/main succeeded
expect workspace-update-dotfiles chezmoi-update refs/heads/feat/x skipped
expect workspace-update-dotfiles chezmoi-update refs/tags/1.0.0 skipped

if [ "$failures" -ne 0 ] || [ "$checks" -ne 6 ]; then
    echo "FAILED: $failures of $checks checks" >&2
    exit 1
fi
echo "PASSED: $checks checks"
