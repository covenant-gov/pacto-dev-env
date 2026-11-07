#!/usr/bin/env bash
# Fail if any workflow uses: entry is not pinned to a full 40-char commit SHA.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_dir="${1:-$ROOT/.github/workflows}"
fail=0

if [[ ! -d "$workflow_dir" ]]; then
  echo "No workflows directory at $workflow_dir" >&2
  exit 1
fi

while IFS= read -r -d '' file; do
  # Match third-party uses: owner/name@ref (skip local ./ paths)
  while IFS= read -r line; do
    [[ "$line" =~ uses:[[:space:]]*([^[:space:]#]+) ]] || continue
    ref="${BASH_REMATCH[1]}"
    [[ "$ref" == ./* ]] && continue
    sha="${ref##*@}"
    if [[ ! "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
      echo "Unpinned Action in ${file}: $ref" >&2
      fail=1
    fi
  done <"$file"
done < <(find "$workflow_dir" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 | sort -z)

if (( fail )); then
  echo "Action pin check failed." >&2
  exit 1
fi

echo "All workflow Actions are pinned to full commit SHAs."
