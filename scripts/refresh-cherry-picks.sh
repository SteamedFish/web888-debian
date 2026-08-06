#!/usr/bin/env bash
# Re-check the KiwiSDR → Web-888 cherry-pick set against upstream, and optionally
# regenerate the non-adapted (GREEN) patches.
#
# Reads config/websdr/cherry-picks.manifest. For each candidate it:
#   1. confirms the KiwiSDR commit/range still resolves in the KiwiSDR tree;
#   2. regenerates the raw upstream diff and compares it to the stored patch
#      (drift report);
#   3. detects whether RaspSDR (Web-888) may have already merged the change
#      upstream (first-added-line signature grep in work/websdr-src).
#
# By default it only REPORTS. With --regen it overwrites the patch file for
# non-adapted candidates (status=applied AND a "data-only"/"GREEN" note); adapted
# patches (e.g. 0104) are never auto-overwritten — drift is reported only.
#
# The KiwiSDR tree is NOT tracked by git (lives in .tmp/repos/KiwiSDR, gitignored).
# Default location; override with --kiwi-tree <path>. Missing → instructions.
#
# Usage:
#   scripts/refresh-cherry-picks.sh                  # report only
#   scripts/refresh-cherry-picks.sh --regen          # regenerate GREEN patches
#   scripts/refresh-cherry-picks.sh --kiwi-tree /pth # use an existing clone
#
# Exit codes: 0 = all candidates resolved cleanly; 1 = one or more could not be
# resolved against upstream (commit gone / tree missing) — needs human review.

set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST=config/websdr/cherry-picks.manifest
PKDIR=config/websdr/cherry-picks
WEBSDR=work/websdr-src
KIWI=${KIWI_TREE:-.tmp/repos/KiwiSDR}
REGEN=0
PROBLEMS=0

usage() {
  sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --regen) REGEN=1; shift;;
    --kiwi-tree) KIWI="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done

[[ -f "$MANIFEST" ]] || { echo "error: $MANIFEST not found" >&2; exit 1; }
if [[ ! -d "$KIWI/.git" ]]; then
  cat >&2 <<EOF
error: KiwiSDR tree not found at $KIWI
Clone it first (gitignored scratch location):
  git clone https://github.com/jks-prv/KiwiSDR "$KIWI"
or point this script at an existing clone:  --kiwi-tree <path>
EOF
  exit 1
fi
[[ -d "$WEBSDR" ]] || { echo "error: Web-888 tree $WEBSDR not found (clone RaspSDR/server first)" >&2; exit 1; }

printf '%-12s %-44s %-10s %-10s %s\n' "STATUS" "PATCH" "KIWI?" "DRIFT" "UPSTREAM"
printf '%-12s %-44s %-10s %-10s %s\n' "------" "-----" "-----" "-----" "--------"

# manifest records look like (status + patch + rest-of-line; comments/blank skipped):
#   applied   0101-kiwi-remove-chu.patch   c3b4c06   data-only ...
#   pending   0108-...                     b1e0c84..f8f8fc7  ...
# We parse with awk into 4 fields; field3 may be a single hash or a range
# (space-separated list of hashes, or A..B). For drift we use the FIRST hash.
while IFS= read -r line; do
  # skip comments / blanks
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  # field layout: STATUS PATCH KIWI_REF... NOTES...
  status=$(awk '{print $1}' <<<"$line")
  patch=$(awk '{print $2}' <<<"$line")
  # kiwi ref(s) = the 3rd whitespace token up to the next run of spaces before notes;
  # in practice the manifest uses a single token (hash) or several hashes for a range.
  kref=$(awk '{print $3}' <<<"$line")
  notes=$(cut -f4- -d' ' <<<"$line" | sed 's/^[[:space:]]*//')

  kiwi_ok="-"; drift="-"; upstream="-"; action=""

  # resolve the first hash against the Kiwi tree
  first_hash=$(awk '{print $1}' <<<"$kref")
  if [[ -n "$first_hash" && "$first_hash" != "-" ]]; then
    if git -C "$KIWI" rev-parse --verify --quiet "${first_hash}^{commit}" >/dev/null; then
      kiwi_ok="ok"
    else
      kiwi_ok="GONE"; PROBLEMS=1
    fi
  fi

  # drift: regenerate the raw upstream diff for the first hash, compare to stored patch
  if [[ "$kiwi_ok" == "ok" && -f "$PKDIR/$patch" ]]; then
    raw=$(mktemp)
    # raw upstream patch (full commit, all files); we only need a rough drift signal
    if git -C "$KIWI" show "$first_hash" --format= -- >"$raw" 2>/dev/null; then
      # compare just the added-content lines (lines starting with '+') count + a
      # signature — a full diff of diffs is noisy; use added-line signature.
      sig_stored=$(grep -c '^+' "$PKDIR/$patch" 2>/dev/null || echo 0)
      sig_upstream=$(git -C "$KIWI" show "$first_hash" --format= | grep -c '^+' || echo 0)
      if [[ "$sig_stored" -eq "$sig_upstream" ]]; then
        drift="none"
      else
        drift="drift($sig_stored/$sig_upstream)"
        [[ "$status" == "applied" ]] && PROBLEMS=1
      fi
    fi
    rm -f "$raw"

    # upstream-merged detection: take the first added (non-+++) line from the stored
    # patch and grep for it in the Web-888 tree; if present, RaspSDR likely merged it.
    sigline=$(grep -m1 '^+[^+]' "$PKDIR/$patch" | sed 's/^+//' | tr -d '\r' || true)
    if [[ -n "$sigline" ]]; then
      # use a stable substring (first 40 chars) to avoid whitespace-only signatures
      sub=${sigline:0:40}
      if [[ -n "$sub" ]] && grep -rqF "$sub" "$WEBSDR" 2>/dev/null; then
        # confirm it's in the *current* (unpatched) tree, not our own patch dir
        if grep -rqF "$sub" "$WEBSDR" --include="*.cpp" --include="*.h" --include="*.cjson" --include="*.js" 2>/dev/null; then
          upstream="MERGED?"; PROBLEMS=1
        fi
      fi
    fi
  fi

  # --regen: overwrite only non-adapted applied patches
  if [[ "$REGEN" -eq 1 && "$status" == "applied" && "$kiwi_ok" == "ok" ]]; then
    if [[ "$notes" == *"data-only"* || "$notes" == *"GREEN"* ]]; then
      git -C "$KIWI" show "$first_hash" --format= >"$PKDIR/$patch.new" 2>/dev/null
      # only replace if the regen produced something non-empty
      if [[ -s "$PKDIR/$patch.new" ]]; then
        mv "$PKDIR/$patch.new" "$PKDIR/$patch"
        action="REGEN"
      else
        rm -f "$PKDIR/$patch.new"
        action="regen-fail"
        PROBLEMS=1
      fi
    else
      action="skip(adapted)"
    fi
  fi

  printf '%-12s %-44s %-10s %-10s %s%s\n' "$status" "$patch" "$kiwi_ok" "$drift" "$upstream" "${action:+ [$action]}"
done < "$MANIFEST"

echo
if (( PROBLEMS )); then
  echo "⚠  one or more candidates need human review (see GONE / drift / MERGED? above)"
  exit 1
fi
echo "✓ all candidates resolved; no drift detected"
exit 0
