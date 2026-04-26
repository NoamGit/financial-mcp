#!/usr/bin/env bash
# check-freshness.sh — Hourly heartbeat cron job.
# Alerts via Telegram if no successful scrape has occurred in the last THRESHOLD_HOURS.
# Catches the "cron never ran" silent failure mode.
#
# Add to crontab:
#   0 * * * * TG_BOT_TOKEN=<token> TG_CHAT_ID=<chat_id> /path/to/scripts/check-freshness.sh >> /var/log/scraper.log 2>&1
#
# Set DB_PATH to the host-accessible path of the SQLite database.
# For Docker named volume: /var/lib/docker/volumes/financial-mcp_bank-data/_data/bank.db
set -euo pipefail

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
THRESHOLD_HOURS="${THRESHOLD_HOURS:-30}"
DB_PATH="${DB_PATH:-/var/lib/docker/volumes/financial-mcp_bank-data/_data/bank.db}"

notify() {
  local message="$1"
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    curl -s -o /dev/null -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}&text=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$message")" || true
  fi
}

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARN: TG_BOT_TOKEN or TG_CHAT_ID not set — staleness alerting disabled"
  exit 0
fi

# Query the last successful scrape timestamp via sqlite3 in a Docker container
# (avoids requiring sqlite3 on the host).
LAST_SUCCESS=$(docker run --rm \
  -v financial-mcp_bank-data:/data:ro \
  alpine sh -c "apk add --quiet sqlite 2>/dev/null && sqlite3 /data/bank.db \"SELECT completed_at FROM scrape_runs WHERE status='completed' ORDER BY completed_at DESC LIMIT 1;\"" \
  2>/dev/null || echo "")

if [ -z "$LAST_SUCCESS" ]; then
  MSG="🚨 bank-scraper: No successful scrape found in DB! Data may be stale or DB unreachable."
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ALERT: $MSG"
  notify "$MSG"
  exit 0
fi

# Use Python for portable datetime comparison (avoids GNU date -d dependency).
# $LAST_SUCCESS is passed via the environment to prevent shell injection.
IS_STALE=$(LAST_SUCCESS="$LAST_SUCCESS" THRESHOLD_HOURS="$THRESHOLD_HOURS" python3 - <<'PYEOF'
import os, sys
from datetime import datetime, timezone, timedelta
ts = os.environ.get('LAST_SUCCESS', '').strip()
if not ts:
    print('yes')
    sys.exit(0)
try:
    # SQLite stores datetimes as "YYYY-MM-DD HH:MM:SS"
    last = datetime.fromisoformat(ts.replace(' ', 'T')).replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    threshold = int(os.environ.get('THRESHOLD_HOURS', '30'))
    print('yes' if (now - last) > timedelta(hours=threshold) else 'no')
except Exception as e:
    print('unknown', file=sys.stderr)
    sys.exit(1)
PYEOF
)

if [ "$IS_STALE" = "yes" ]; then
  MSG="⚠️ bank-scraper: Last success was $LAST_SUCCESS — over ${THRESHOLD_HOURS}h ago. Data is STALE. Run scripts/run-scrape.sh to refresh."
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ALERT: $MSG"
  notify "$MSG"
elif [ "$IS_STALE" = "no" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] INFO: Last successful scrape at $LAST_SUCCESS — within ${THRESHOLD_HOURS}h threshold, OK"
else
  MSG="🚨 bank-scraper: staleness check could not be determined (result: $IS_STALE). Treating as stale — check DB manually."
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ALERT: $MSG"
  notify "$MSG"
fi
