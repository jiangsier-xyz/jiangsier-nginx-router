#!/usr/bin/env bash
# Pure parsing helpers. Sourced by entrypoint.sh and tests/test_parse.sh.
# Do not put top-level side effects here; this file is sourced, not executed.

# extract_domains_from_dir <dir>
# Print unique domains referenced by /etc/letsencrypt/live/<DOMAIN>/ paths
# across all *.conf files in <dir>. One domain per line.
extract_domains_from_dir() {
  local dir="$1"
  local f
  shopt -s nullglob
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    grep -hoE '/etc/letsencrypt/live/[^/]+/' "$f" 2>/dev/null || true
  done | sed -E 's#.*/live/([^/]+)/.*#\1#' | sort -u
  shopt -u nullglob
}
