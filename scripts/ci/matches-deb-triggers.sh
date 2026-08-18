#!/usr/bin/env bash
# matches-deb-triggers.sh — grep-like filter: read a changed-file list on
# stdin (one path per line, e.g. `git diff --name-only`), exit 0 if ANY path
# matches the deb-workflow trigger patterns in deb-trigger-paths.txt (next
# to this script), else exit 1. Matching paths are echoed to stderr.
#
# Pattern syntax mirrors GitHub Actions push.paths as used by the deb
# workflows: exact path, or 'dir/**' (everything under dir/, any depth).
# Used by build-image.yml's preflight to skip push-triggered image builds
# when the same push already fires deb builds (their publish step
# dispatches debs-published, which rebuilds the image with the fresh debs).
set -euo pipefail

PATTERNS="$(dirname "$0")/deb-trigger-paths.txt"

while IFS= read -r f || [[ -n $f ]]; do
    [[ -n $f ]] || continue
    while IFS= read -r p || [[ -n $p ]]; do
        [[ -n $p && $p != \#* ]] || continue
        # Quote the '/**' literals: unquoted, `*/**` is a glob matching any
        # path containing a slash, and ${p%/**} strips any '/<suffix>'.
        if [[ $p == *'/**' ]]; then
            if [[ $f == "${p%'/**'}/"* ]]; then
                echo "$f  <=  $p" >&2
                exit 0
            fi
        elif [[ $f == "$p" ]]; then
            echo "$f  <=  $p" >&2
            exit 0
        fi
    done < "$PATTERNS"
done
exit 1
