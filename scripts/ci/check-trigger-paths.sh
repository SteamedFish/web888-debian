#!/usr/bin/env bash
# check-trigger-paths.sh — drift gate for scripts/ci/deb-trigger-paths.txt.
#
# The txt file is the union of the push.paths of the five deb-publishing
# workflows (build-boot-deb, build-kernel-deb, build-redpitaya-deb,
# build-websdr-deb, build-thirdparty-debs); build-image.yml's preflight
# consults it to skip push-triggered image builds that a deb build already
# covers. If the txt and the workflows drift, that skip logic silently does
# the wrong thing (see the header comment in deb-trigger-paths.txt).
#
# This script parses the workflows' push.paths with PyYAML and compares the
# set against the txt (comments/blank lines ignored, order ignored):
#   - pattern in workflows but MISSING from txt  -> fail (double build)
#   - pattern in txt but EXTRA (no workflow)     -> fail (skipped image)
# Either drift direction prints its diff set and exits non-zero.
#
# Usage: check-trigger-paths.sh [TXT [WORKFLOWS_DIR]]
#   Defaults: the real deb-trigger-paths.txt next to this script and
#   .github/workflows/. Override both to self-test against fixtures.
set -euo pipefail

TXT="${1:-$(dirname "$0")/deb-trigger-paths.txt}"
WORKFLOWS_DIR="${2:-$(dirname "$0")/../../.github/workflows}"

WORKFLOWS=(
    build-boot-deb.yml
    build-kernel-deb.yml
    build-redpitaya-deb.yml
    build-websdr-deb.yml
    build-thirdparty-debs.yml
)

python3 - "$TXT" "$WORKFLOWS_DIR" "${WORKFLOWS[@]}" <<'PY'
import re
import sys

import yaml

txt_path, workflows_dir = sys.argv[1], sys.argv[2]
workflow_names = sys.argv[3:]

# deb-trigger-paths.txt: one pattern per line; '#' starts a comment
# (full-line or trailing — mirrors matches-deb-triggers.sh which only skips
# full-line comments, so we accept the union here).
txt_patterns = set()
with open(txt_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        txt_patterns.add(line)

# PyYAML's SafeLoader resolves the unquoted YAML 1.1 key `on:` to the
# boolean True — accept both spellings.
def get_on(doc):
    if not isinstance(doc, dict):
        return {}
    return doc.get("on", doc.get(True, {})) or {}

wf_patterns = {}
for name in workflow_names:
    with open(f"{workflows_dir}/{name}", encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    paths = (get_on(doc).get("push") or {}).get("paths")
    if not paths:
        print(f"ERROR: {name} has no on.push.paths to compare", file=sys.stderr)
        sys.exit(2)
    wf_patterns[name] = set(paths)

wf_union = set().union(*wf_patterns.values())

missing = sorted(wf_union - txt_patterns)   # workflow path absent from txt
extra = sorted(txt_patterns - wf_union)     # txt path no workflow lists

if missing:
    print("Drift: push.paths in deb workflows but MISSING from "
          f"{txt_path} (push fires deb build AND image build):", file=sys.stderr)
    for p in missing:
        owners = [n for n, ps in wf_patterns.items() if p in ps]
        print(f"  - {p}   ({', '.join(owners)})", file=sys.stderr)
if extra:
    print(f"Drift: patterns in {txt_path} that NO deb workflow lists "
          "(image build would be skipped with no deb build to cover it):",
          file=sys.stderr)
    for p in extra:
        print(f"  - {p}", file=sys.stderr)

if missing or extra:
    sys.exit(1)
print(f"OK: {txt_path} matches the push.paths union of "
      f"{len(workflow_names)} deb workflows ({len(wf_union)} patterns).")
PY
