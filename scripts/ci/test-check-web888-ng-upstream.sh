#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# test-check-web888-ng-upstream.sh — self-test for check-web888-ng-upstream.sh.
#
# Feeds saved GitHub-releases JSON fixtures through the checker via its
# CHECK_WEB888_NG_RELEASES_JSON hook (no network) and proves:
#   1. prerelease-flagged releases ARE candidates (/releases/latest would
#      miss every one of them — that is the whole point of this watcher);
#   2. draft releases are excluded even when listed;
#   3. non-semver tags are excluded;
#   4. forward-only: older-than-pin and equal-to-pin tags are not selected;
#   5. semver prerelease suffix ordering (v0.6.0-rc1 < v0.6.0);
#   6. pinned-pair merge lines: only the advanced side's keys are emitted;
#   7. lane-A pin format (WEB888_NG_VERSION without 'v', WEB888_NGHW_* for
#      the hw side) is read and matched correctly.
#
# Exits non-zero on any violated expectation.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/check-web888-ng-upstream.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fixture release stream. API order here is deliberately NOT semver order
# (GitHub orders by creation time); the checker must sort by semver itself.
cat > "$TMP/fixtures.json" <<'JSON'
{
  "jeskko/web888-ng": [
    {"tag_name": "v0.5.0", "draft": false, "prerelease": true,  "published_at": "2026-10-20T00:00:00Z"},
    {"tag_name": "nightly-20261030", "draft": false, "prerelease": true, "published_at": "2026-10-30T00:00:00Z"},
    {"tag_name": "v0.6.0", "draft": false, "prerelease": true,  "published_at": "2026-10-30T19:00:00Z"},
    {"tag_name": "v0.4.0", "draft": false, "prerelease": false, "published_at": "2026-10-15T00:00:00Z"},
    {"tag_name": "v0.7.0-rc1", "draft": false, "prerelease": true, "published_at": "2026-11-01T00:00:00Z"},
    {"tag_name": "v0.8.0-secret", "draft": true, "prerelease": false, "published_at": "2026-11-02T00:00:00Z"}
  ],
  "jeskko/web888-ng-hw": [
    {"tag_name": "v0.2.0", "draft": false, "prerelease": true, "published_at": "2026-10-28T00:00:00Z"},
    {"tag_name": "v0.3.0", "draft": false, "prerelease": true, "published_at": "2026-10-30T00:00:00Z"},
    {"tag_name": "v0.4.0", "draft": true, "prerelease": true, "published_at": "2026-11-01T00:00:00Z"}
  ]
}
JSON

# Pin-file sandbox in the lane-A format: config/web888-ng/pins.env with
# VERSION (no leading 'v') and the WEB888_NGHW_* hw-side key prefix.
make_sandbox() { # make_sandbox <ng-version> <hw-version>
    local dir="$TMP/sandbox-$1-$2"
    mkdir -p "$dir/config/web888-ng"
    {
        echo "WEB888_NG_VERSION=$1"
        echo "WEB888_NG_COMMIT=0000000000000000000000000000000000000001"
        echo "WEB888_NGHW_VERSION=$2"
        echo "WEB888_NGHW_COMMIT=0000000000000000000000000000000000000002"
    } > "$dir/config/web888-ng/pins.env"
    echo "$dir"
}

fail() { echo "FAIL: $*" >&2; echo "--- stderr ---" >&2; cat "$TMP/stderr.log" >&2; exit 1; }

# Case 1: prerelease candidates win; draft v0.8.0-secret excluded; newest
# non-draft (v0.7.0-rc1) selected over pin 0.6.0.
S=$(make_sandbox 0.6.0 0.3.0)
cd "$S"
set +e
out=$(CHECK_WEB888_NG_RELEASES_JSON="$TMP/fixtures.json" bash "$SCRIPT" ng 2>"$TMP/stderr.log")
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "case 1: expected rc 0, got $RC"
[[ $out == "WEB888_NG_TAG=v0.7.0-rc1"$'\n'"WEB888_NG_COMMIT=unresolved-fixture" ]] \
    || fail "case 1: expected 'WEB888_NG_TAG=v0.7.0-rc1' + fixture commit line, got: $out"
grep -q "excluded 1 draft" "$TMP/stderr.log" \
    || fail "case 1: draft exclusion not logged"
grep -q "nightly-20261030" "$TMP/stderr.log" \
    || fail "case 1: non-semver tag not logged as skipped"
echo "ok   [prerelease candidate + draft excluded + non-semver skipped]"

# Case 2: forward-only — pin already at newest non-draft, nothing emitted.
S=$(make_sandbox 0.7.0-rc1 0.3.0)
cd "$S"
set +e
out=$(CHECK_WEB888_NG_RELEASES_JSON="$TMP/fixtures.json" bash "$SCRIPT" ng 2>"$TMP/stderr.log")
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "case 2: expected rc 0, got $RC"
[[ -z $out ]] || fail "case 2: expected no output for up-to-date pin, got: $out"
echo "ok   [forward-only: up-to-date pin selects nothing]"

# Case 3: equal numeric triple, prerelease suffix below release — pin
# v0.6.0-rc1 must not reselect v0.6.0-rc1, and v0.6.0 must not be skipped
# in favour of v0.7.0-rc1... i.e. the next strictly newer is selected.
S=$(make_sandbox 0.6.0-rc1 0.3.0)
cd "$S"
set +e
out=$(CHECK_WEB888_NG_RELEASES_JSON="$TMP/fixtures.json" bash "$SCRIPT" ng 2>"$TMP/stderr.log")
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "case 3: expected rc 0, got $RC"
[[ $(head -n1 <<<"$out") == "WEB888_NG_TAG=v0.7.0-rc1" ]] \
    || fail "case 3: expected v0.7.0-rc1 (v0.6.0 > v0.6.0-rc1, already pinned), got: $out"
echo "ok   [prerelease suffix ordering: v0.6.0 > v0.6.0-rc1]"

# Case 4: bootstrap (no pin file) selects the newest non-draft release.
S="$TMP/sandbox-none"
mkdir -p "$S/config/web888-ng"
cd "$S"
set +e
out=$(CHECK_WEB888_NG_RELEASES_JSON="$TMP/fixtures.json" bash "$SCRIPT" hw 2>"$TMP/stderr.log")
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "case 4: expected rc 0, got $RC"
[[ $(head -n1 <<<"$out") == "WEB888_NGHW_TAG=v0.3.0" ]] \
    || fail "case 4: expected WEB888_NGHW_TAG=v0.3.0 (draft v0.4.0 excluded), got: $out"
echo "ok   [bootstrap: newest non-draft selected, draft excluded]"

# Case 5: pinned pair — ng advanced, hw pinned at newest: only WEB888_NG_*
# (ng side) keys are emitted; the caller retains the hw pins verbatim.
S=$(make_sandbox 0.5.0 0.3.0)
cd "$S"
set +e
out=$(CHECK_WEB888_NG_RELEASES_JSON="$TMP/fixtures.json" bash "$SCRIPT" all 2>"$TMP/stderr.log")
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "case 5: expected rc 0, got $RC"
[[ $(head -n1 <<<"$out") == "WEB888_NG_TAG=v0.7.0-rc1" && $out != *NGHW* ]] \
    || fail "case 5: expected only the ng side (hw up to date), got: $out"
echo "ok   [pinned pair: only the advanced side's keys emitted]"

# Case 6: dry-run selects nothing and prints the candidate table including
# prerelease markers.
S=$(make_sandbox 0.6.0 0.3.0)
cd "$S"
set +e
out=$(CHECK_WEB888_NG_RELEASES_JSON="$TMP/fixtures.json" bash "$SCRIPT" --dry-run ng 2>"$TMP/stderr.log")
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "case 6: expected rc 0, got $RC"
[[ $out != *"WEB888_NG_TAG="* && $out != *"VERSION="* ]] \
    || fail "case 6: dry-run must not emit machine lines: $out"
grep -q "v0.7.0-rc1  prerelease=true  newer-than-pin" <<<"$out" \
    || fail "case 6: dry-run table missing prerelease candidate: $out"
grep -q "v0.4.0  prerelease=false  older-than-pin" <<<"$out" \
    || fail "case 6: dry-run table missing older pin marker: $out"
echo "ok   [dry-run: candidate table, no selection]"

# Case 7: --full-pin is rejected in fixture mode (no download/hashing).
S=$(make_sandbox 0.6.0 0.3.0)
cd "$S"
set +e
CHECK_WEB888_NG_RELEASES_JSON="$TMP/fixtures.json" bash "$SCRIPT" --full-pin ng \
    2>"$TMP/stderr.log"
RC=$?
set -e
[[ $RC -eq 2 ]] || fail "case 7: expected rc 2 for --full-pin with fixtures, got $RC"
echo "ok   [--full-pin rejected in fixture mode]"

echo "PASS: all check-web888-ng-upstream.sh fixtures behave as expected"
