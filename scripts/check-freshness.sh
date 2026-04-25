#!/usr/bin/env bash
# check-freshness.sh — Hourly heartbeat cron job.
# Alerts via ntfy if no successful scrape has occurred in the last THRESHOLD_HOURS.
# Catches the "cron never ran" silent failure mode.
#
# Add to crontab:
#   0 * * * * NTFY_TOPIC=mytopic /path/to/scripts/check-freshness.sh >> /var/log/scraper-heartbeat.log 2>&1
#
# Set DB_PATH to the host-accessible path of the SQLite database.
# For Docker named volume: /var/lib/docker/volumes/financial-mcp_bank-data/_data/bank.db
# Or use a bind mount path if configured.
set -euo pipefail

NTFY_TOPIC="${NTFY_TOPIC:-}"
THRESHOLD_HOURS="${THRESHOLD_HOURS:-30}"
DB_PATH="${DB_PATH:-/var/lib/docker/volumes/financial-mcp_bank-data/_data/bank.db}"

if [ -z "$NTFY_TOPIC" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARN: NTFY_TOPIC not set — staleness alerting disabled"
  exit 0
fi

# Query the last successful scrape timestamp directly from the host-accessible DB.
# sqlite3 must be installed on the host (not inside a container).
LAST_SUCCESS=$(sqlite3 "${DB_PATH}" \
  "SELECT completed_at FROM scrape_runs WHERE status='completed' ORDER BY completed_at DESC LIMIT 1;" \
  2>/dev/null || echo "")

if [ -z "$LAST_SUCCESS" ]; then
  MSG="bank-scraper: No successful scrape found in DB! Data may be stale or DB unreachable. Check ${DB_PATH}"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ALERT: $MSG"
  curl -s -d "$MSG" "https://ntfy.sh/$NTFY_TOPIC" > /dev/null || true
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
  MSG="bank-scraper: Last success was $LAST_SUCCESS — over ${THRESHOLD_HOURS}h ago. Data is STALE. Run scripts/run-scrape.sh to refresh."
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ALERT: $MSG"
  curl -s -d "$MSG" "https://ntfy.sh/$NTFY_TOPIC" > /dev/null || true
elif [ "$IS_STALE" = "no" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] INFO: Last successful scrape at $LAST_SUCCESS — within ${THRESHOLD_HOURS}h threshold, OK"
else
  MSG="bank-scraper: staleness check could not be determined (result: $IS_STALE). Treating as stale — check ${DB_PATH} manually."
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ALERT: $MSG"
  [ -n "$NTFY_TOPIC" ] && curl -s -d "$MSG" "https://ntfy.sh/$NTFY_TOPIC" > /dev/null 2>&1 || true
fi
