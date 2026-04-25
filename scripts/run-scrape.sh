#!/usr/bin/env bash
# run-scrape.sh — Invoke the scraper container as a one-shot job.
# Designed to be called from cron:
#   0 6 * * * NTFY_TOPIC=mytopic /path/to/scripts/run-scrape.sh >> /var/log/scraper.log 2>&1
#
# Credentials are sourced from .env.local (Phase 3).
# Phase 4 will replace the grep block below with `pass show` calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Optional ntfy topic for push alerts. Set NTFY_TOPIC env var to enable.
NTFY_TOPIC="${NTFY_TOPIC:-}"

notify() {
  local message="$1"
  if [ -n "$NTFY_TOPIC" ]; then
    curl -s -d "$message" "https://ntfy.sh/$NTFY_TOPIC" > /dev/null || true
  fi
}

# Create a temporary env file with tight permissions and shred it on exit.
ENVFILE=$(mktemp -t scraper-env.XXXXXX)
chmod 600 "$ENVFILE"
trap 'shred -u "$ENVFILE" 2>/dev/null || rm -f "$ENVFILE"' EXIT

# Phase 3: source credentials from .env.local.
# Only copy lines that look like KEY=value to avoid leaking unrelated shell env.
# Phase 4 will replace this block with `pass show` calls.
# Normalise the env file:
#   1. Strip surrounding quotes from values ("foo" → foo, 'foo' → foo)
#   2. Escape $ → $$ so Docker Compose interpolation doesn't eat values
#      like "secret$123" (would otherwise arrive as "secret").
grep -E '^[A-Z0-9_]+=.' "$REPO_ROOT/.env.local" 2>/dev/null \
  | sed "s/='\(.*\)'\$/=\1/; s/=\"\(.*\)\"\$/=\1/" \
  | sed 's/\$/\$\$/g' \
  > "$ENVFILE" || true

if [ ! -s "$ENVFILE" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: No credentials found in $REPO_ROOT/.env.local" >&2
  notify "bank-scraper FAILED: no credentials in .env.local — configure credentials before running"
  exit 1
fi

# Run scraper container — exits when done.
cd "$REPO_ROOT"
docker compose --profile tools run --rm --env-from-file "$ENVFILE" scraper
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  MSG="bank-scraper FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ). Exit code: $EXIT_CODE. Check /var/log/scraper.log"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $MSG" >&2
  notify "$MSG"
  exit $EXIT_CODE
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] INFO: scraper completed successfully"
