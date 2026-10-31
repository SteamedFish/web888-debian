#!/usr/bin/env bash
# test-check-trigger-paths.sh — self-test for check-trigger-paths.sh.
#
# Copies the real deb-trigger-paths.txt and .github/workflows/ into a temp
# fixture, then proves both drift directions are caught:
#   fixture 1: txt missing one workflow path  -> must exit 1
#   fixture 2: txt carrying one extra pattern  -> must exit 1
#   fixture 0: pristine copies                 -> must exit 0
# Exits non-zero if any expectation is violated.
set -euo pipefail

SCRIPT="$(dirname "$0")/check-trigger-paths.sh"
REAL_TXT="$(dirname "$0")/deb-trigger-paths.txt"
REAL_WF="$(dirname "$0")/../../.github/workflows"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_case() {
    local name="$1" expect_rc="$2" txt="$3"
    set +e
    out="$(bash "$SCRIPT" "$txt" "$TMP/workflows" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -ne "$expect_rc" ]]; then
        echo "FAIL [$name]: expected exit $expect_rc, got $rc" >&2
        echo "$out" >&2
        exit 1
    fi
    echo "ok   [$name] exit $rc (as expected)"
    [[ -z "$out" ]] || printf '%s\n' "$out" | sed 's/^/       /'
}

# fixture 0: pristine
mkdir "$TMP/pristine"
cp "$REAL_TXT" "$TMP/pristine/deb-trigger-paths.txt"
cp -r "$REAL_WF" "$TMP/workflows"
run_case "pristine txt matches workflows" 0 "$TMP/pristine/deb-trigger-paths.txt"

# fixture 1: drop one pattern that a workflow lists (simulates workflow
# gaining a path nobody mirrored into the txt)
mkdir "$TMP/missing"
grep -v '^scripts/build-websdr-deb.sh$' "$REAL_TXT" > "$TMP/missing/deb-trigger-paths.txt"
set +e
out="$(bash "$SCRIPT" "$TMP/missing/deb-trigger-paths.txt" "$TMP/workflows" 2>&1)"
rc=$?
set -e
if [[ $rc -eq 0 ]] || ! grep -q 'scripts/build-websdr-deb.sh' <<<"$out"; then
    echo "FAIL [missing pattern]: expected exit 1 + the dropped path in the diff" >&2
    echo "$out" >&2
    exit 1
fi
echo "ok   [missing pattern] exit $rc, diff names the dropped path"

# fixture 2: add a pattern no workflow lists
mkdir "$TMP/extra"
{ cat "$REAL_TXT"; echo 'scripts/ci/no-such-workflow-input.sh'; } \
    > "$TMP/extra/deb-trigger-paths.txt"
set +e
out="$(bash "$SCRIPT" "$TMP/extra/deb-trigger-paths.txt" "$TMP/workflows" 2>&1)"
rc=$?
set -e
if [[ $rc -eq 0 ]] || ! grep -q 'scripts/ci/no-such-workflow-input.sh' <<<"$out"; then
    echo "FAIL [extra pattern]: expected exit 1 + the extra path in the diff" >&2
    echo "$out" >&2
    exit 1
fi
echo "ok   [extra pattern] exit $rc, diff names the extra path"

echo "PASS: all check-trigger-paths.sh fixtures behave as expected"
