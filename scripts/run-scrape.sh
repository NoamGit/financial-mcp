#!/usr/bin/env bash
# run-scrape.sh — Invoke the scraper container as a one-shot job.
# Designed to be called from cron:
#   0 6 * * * TG_BOT_TOKEN=<token> TG_CHAT_ID=<chat_id> /path/to/scripts/run-scrape.sh >> /var/log/scraper.log 2>&1
#
# Credentials are sourced from the `pass` GPG store (nanoclaw/* paths).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Telegram alerting. Set TG_BOT_TOKEN and TG_CHAT_ID env vars to enable.
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

notify() {
  local message="$1"
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    curl -s -o /dev/null -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}&text=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$message")" || true
  fi
}

# Create a temporary env file with tight permissions and shred it on exit.
ENVFILE=$(mktemp -t scraper-env.XXXXXX)
chmod 600 "$ENVFILE"
trap 'shred -u "$ENVFILE" 2>/dev/null || rm -f "$ENVFILE"' EXIT

# Load credentials from pass (GPG-encrypted store).
# Each provider is optional — missing entries are silently skipped so partially
# configured installations work without modification.
try_pass() {
  local key="$1" var="$2"
  local val
  val=$(pass show "$key" 2>/dev/null) || return 0
  [ -n "$val" ] && echo "${var}=${val}" >> "$ENVFILE"
}

try_pass nanoclaw/isracard/id          ISRACARD_ID
try_pass nanoclaw/isracard/card6digits ISRACARD_CARD6DIGITS
try_pass nanoclaw/isracard/password    ISRACARD_PASSWORD
try_pass nanoclaw/isracard2/id         ISRACARD2_ID
try_pass nanoclaw/isracard2/card6digits ISRACARD2_CARD6DIGITS
try_pass nanoclaw/isracard2/password   ISRACARD2_PASSWORD
try_pass nanoclaw/max/username         MAX_USERNAME
try_pass nanoclaw/max/password         MAX_PASSWORD
try_pass nanoclaw/leumi/username       LEUMI_USERNAME
try_pass nanoclaw/leumi/password       LEUMI_PASSWORD

if [ ! -s "$ENVFILE" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: No credentials loaded from pass store" >&2
  notify "bank-scraper FAILED: could not load credentials from pass — check nanoclaw/isracard/* entries"
  exit 1
fi

# Build -e flag list from the env file, then run scraper container.
env_args=()
while IFS='=' read -r key value; do
  [[ "$key" =~ ^[A-Z0-9_]+$ ]] && env_args+=(-e "${key}=${value}")
done < "$ENVFILE"

cd "$REPO_ROOT"
docker compose --profile tools run --rm "${env_args[@]}" scraper
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  MSG="🚨 bank-scraper FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ). Exit code: $EXIT_CODE. Check /var/log/scraper.log"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $MSG" >&2
  notify "$MSG"
  exit $EXIT_CODE
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] INFO: scraper completed successfully"
