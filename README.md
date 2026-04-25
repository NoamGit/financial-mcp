<div align="center">
<h1>IL Bank MCP 🐷💸</h1>
<p><em>Personal fork of <a href="https://github.com/glekner/il-bank-mcp">glekner/il-bank-mcp</a> — hardened for home-server use with credential isolation and freshness signaling.</em></p>
</div>

## What is it?

IL Bank MCP is a finance assistant that brings your Israeli bank data to any AI assistant. It combines a headless scraper (powered by [`israeli-bank-scrapers`](https://github.com/eshaham/israeli-bank-scrapers)) with an MCP server, letting LLMs analyze your transactions, track spending patterns, and provide financial insights.

> **Upstream pinned at:** `glekner/il-bank-mcp` commit `1f175df`

---

## What's different from upstream

This fork adds a **process boundary** between the credential-holding scraper and the LLM-facing MCP server. The threat model: bank passwords must never be reachable by the MCP server, even under prompt injection.

### Credential isolation

| | Upstream | This fork |
|---|---|---|
| Credentials | Passed to `docker compose up` or Claude Desktop config | Stored in `pass` (GPG-encrypted); injected into a one-shot scraper container via temp file, shredded after run |
| MCP server env vars | Holds all bank credentials | Zero credential env vars — verified at boot |
| DB access | Read-write from MCP server | Read-only (`:ro` volume + `read_only: true` container) |
| `refresh_all_data` tool | Available | **Removed** — requires credentials in the MCP process |
| On-demand scrape | Via MCP tool call | Via `scripts/run-scrape.sh` (cron or manual) |

### Freshness signaling

The biggest real-world failure mode: the daily scrape silently breaks and the LLM confidently answers questions on month-old data. Every tool response now carries a `data_freshness` block:

```json
{
  "transactions": [...],
  "data_freshness": {
    "as_of": "2026-04-25T06:03:11Z",
    "hours_since_last_success": 2.1,
    "status": "fresh"
  }
}
```

A dedicated `get_data_freshness` tool returns `fresh` / `stale` (>36h) / `broken` (last run failed) / `never`. The MCP system prompt instructs the LLM to always check freshness before drawing time-sensitive conclusions.

An hourly heartbeat cron (`scripts/check-freshness.sh`) sends a push alert if no successful scrape has run in 30 hours.

### Dual Isracard support

Two separate Isracard accounts (different national IDs) are supported via an `isracard2` provider entry using `ISRACARD2_*` env vars. One Isracard login fetches all cards on that account automatically.

### Isracard bot-detection workaround

Isracard's WAF blocks automated requests to the per-transaction detail endpoint (`PirteyIska_204`) with 429 "Block Automation". `additionalTransactionInformation` defaults to `false` to skip those calls — trading installment metadata for a working scrape. Re-enable with `SCRAPER_ADDITIONAL_TX_INFO=true` once upstream ships a WAF bypass.

---

## Architecture

```
[ cron @ 06:00 ]
     │
     ▼  (creds from pass → scraper env, scoped to one run)
[ scraper container ] ──writes──▶ transactions.db ◀──reads──[ mcp-server container ]
     │ exits             │                                    (long-running, :ro mount)
                         └─writes─▶ scrape_runs                       │
                                    (status, errors)          [ nanoclaw / Claude ]
[ ntfy/Telegram alert                                         (every tool response
  on failure or >30h gap ]                                     carries freshness block)
```

---

## Setup

### Quick start (dev / single machine)

```bash
git clone https://github.com/NoamGit/financial-mcp.git
cd financial-mcp
docker compose build

# Run a one-shot scrape with credentials from .env.local
# (see .env.example.local for the format)
bash scripts/run-scrape.sh

# Start the MCP server
docker compose up -d mcp-server
```

### Home server setup (recommended)

See [`vibecoding/phase-1-remote-install/plan.md`](vibecoding/phase-1-remote-install/plan.md) for the full step-by-step guide covering:

1. Server pre-requisites (Docker, `pass`, GPG, `sqlite3`)
2. GPG key + `pass` store initialisation
3. Inserting credentials with `pass insert`
4. Updating `run-scrape.sh` to use `pass show`
5. MCP server boot persistence
6. Cron setup (daily scrape + hourly heartbeat)
7. nanoclaw / Claude MCP config
8. Phase 7 adversarial validation

### Credentials

Credentials are never stored in the repo or in Docker Compose. On the server they live in a GPG-encrypted `pass` store. During development, `.env.local` (gitignored) can be used as a stub — see `.env.example.local`.

**Supported providers** — anything supported by [`israeli-bank-scrapers`](https://github.com/eshaham/israeli-bank-scrapers#whats-here). Env var prefixes for common ones:

| Provider | Env vars |
|---|---|
| Bank Leumi | `LEUMI_USERNAME`, `LEUMI_PASSWORD` |
| Max (Leumi Card) | `MAX_USERNAME`, `MAX_PASSWORD` |
| Isracard (account 1) | `ISRACARD_ID`, `ISRACARD_CARD6DIGITS`, `ISRACARD_PASSWORD` |
| Isracard (account 2) | `ISRACARD2_ID`, `ISRACARD2_CARD6DIGITS`, `ISRACARD2_PASSWORD` |
| Bank Hapoalim | `HAPOALIM_USERCODE`, `HAPOALIM_PASSWORD` |

> **Note:** Isracard passwords must contain only letters and digits — the Isracard API rejects special characters.

### MCP client config (nanoclaw / Claude Desktop)

The MCP server communicates over stdio. Point your client at the running container:

```json
{
  "mcpServers": {
    "israeli-bank": {
      "command": "docker",
      "args": ["exec", "-i", "bank-mcp-server", "node", "dist/index.js"]
    }
  }
}
```

The container must be running (`docker compose up -d mcp-server`) before the client starts.

---

## MCP tools

| Tool | Description |
|---|---|
| `get_data_freshness` | **Check this first.** Returns `fresh` / `stale` / `broken` / `never` + hours since last successful scrape |
| `get_transactions` | Fetch transactions for any time period |
| `get_financial_summary` | Income, expenses, and trends at a glance |
| `get_accounts` | List connected accounts with balances |
| `get_account_balance_history` | Balance changes over time |
| `search_transactions` | Find specific transactions by amount, description, or category |
| `get_monthly_credit_summary` | Credit card usage breakdown by card and category |
| `get_recurring_charges` | Find subscriptions and repeated payments |
| `analyze_merchant_spending` | Spot unusual spending patterns at a specific merchant |
| `get_spending_by_merchant` | Rank all merchants by total spend |
| `get_category_comparison` | Compare spending between categories across periods |
| `analyze_day_of_week_spending` | Spending patterns by weekday vs weekend |
| `get_scrape_status` | When data was last updated and whether a scrape is running |
| `get_available_categories` | List all transaction categories present in the DB |
| `get_metadata` | DB statistics: date range, total transaction count |

All data-returning tools include a `data_freshness` block in their response.

**Removed from upstream:** `refresh_all_data`, `refresh_service_data` — both require bank credentials in the MCP process, which violates the credential isolation model.

---

## Example questions

- "How much did I spend on groceries last month?"
- "Show me all subscriptions and their total monthly cost"
- "Compare my spending this month vs last month"
- "Any unusual charges at merchants I don't normally visit?"
- "How is my cash flow looking this quarter?"
- "Is my financial data fresh enough to trust?"

---

## FAQ

**Which banks are supported?**
Any bank supported by [`israeli-bank-scrapers`](https://github.com/eshaham/israeli-bank-scrapers#whats-here).

**Is my data secure?**
Bank credentials never enter the MCP server process. The MCP server has read-only access to the transaction DB and zero credential env vars — verified at container startup.

**Can I use it with local LLMs?**
Yes. The MCP server communicates over stdio; any MCP-compatible client works.

**What if scraping fails?**
The `get_data_freshness` tool will return `broken` and every tool response will show the stale data warning. If you've configured alerting, you'll get a push notification within an hour. Check scraper logs for the root cause.

**What if Isracard is blocked with "Block Automation"?**
Isracard's WAF rate-limits headless scraping. Wait 30–60 minutes and retry. If it persists, the `additionalTransactionInformation=false` default (already set) skips the most aggressively blocked endpoint. See upstream issues [#1098](https://github.com/eshaham/israeli-bank-scrapers/issues/1098) and [#1053](https://github.com/eshaham/israeli-bank-scrapers/issues/1053).

**How do I update credentials?**
`pass insert -f nanoclaw/<provider>/<field>` then the next cron run picks it up automatically.

**How do I pull upstream changes?**
```bash
git remote add upstream https://github.com/glekner/il-bank-mcp.git
git fetch upstream
git merge upstream/master
```
Recommended cadence: quarterly. The `israeli-bank-scrapers` library updates frequently as banks change their frontends.

---

## License

MIT

## Acknowledgments

- [glekner/il-bank-mcp](https://github.com/glekner/il-bank-mcp) — original project this fork is based on
- [israeli-bank-scrapers](https://github.com/eshaham/israeli-bank-scrapers) — core scraping engine
- [Model Context Protocol](https://modelcontextprotocol.io/) — MCP framework
