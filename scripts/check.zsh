#!/usr/bin/env zsh

set -euo pipefail

root="${0:A:h:h}"
ci="$root/.github/workflows/ci.yml"

if [[ ! -f "$ci" ]]; then
  print -u2 "CI workflow is missing"
  exit 1
fi

if ! grep -F -q 'scripts/check.zsh' "$ci"; then
  print -u2 "scripts/check.zsh is missing from CI"
  exit 1
fi

if [[ ! -x "$root/scripts/check.zsh" ]]; then
  print -u2 "script is not executable: scripts/check.zsh"
  exit 1
fi

scan_args=(
  --exclude-dir=.git
  --exclude=.git
  --exclude=check.zsh
)

if grep -RIE '/Users/|protocol-local|protocol\.secrets\.env|Infisical|Cortex|T-A[0-9]+|Co-Authored-By:' \
  "${scan_args[@]}" "$root" >/dev/null; then
  print -u2 "leak gate failed: forbidden token found"
  exit 1
fi

if grep -RIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
  "${scan_args[@]}" "$root" >/dev/null; then
  print -u2 "leak gate failed: email-shaped token found"
  exit 1
fi

print "warp checks passed"
