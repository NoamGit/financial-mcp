import { BaseHandler } from './base.js';

const STALE_THRESHOLD_HOURS = 36;

export type FreshnessStatus = 'fresh' | 'stale' | 'broken' | 'never';

export interface FreshnessResult {
  status: FreshnessStatus;
  last_successful_scrape_at: string | null;
  hours_since_last_success: number | null;
  is_scrape_running: boolean;
  last_error: string | null;
}

export class FreshnessHandler extends BaseHandler {
  async getDataFreshness() {
    try {
      // Two-pass freshness logic:
      // Pass 1: was there EVER a successful scrape? (separate query for last completed)
      // Pass 2: did the most recent run fail?
      // This ensures 'broken' is reachable even when the last completed_at is null.
      const lastSuccessAt = this.scraperService.getLastSuccessfulScrapeAt();
      const info = this.scraperService.getLastScrapeInfo();

      const hoursSince =
        lastSuccessAt != null
          ? (Date.now() - lastSuccessAt.getTime()) / 3600000
          : null;

      const lastRunFailed = info?.status === 'failed' && !info?.isRunning;

      let status: FreshnessStatus;
      if (!lastSuccessAt && !info?.isRunning) {
        // No successful scrape ever, and not currently running
        status = 'never';
      } else if (lastRunFailed) {
        // Had a success before (or currently has no success), but latest attempt failed
        status = 'broken';
      } else if (hoursSince !== null && hoursSince > STALE_THRESHOLD_HOURS) {
        status = 'stale';
      } else {
        status = 'fresh';
      }

      const result: FreshnessResult = {
        status,
        last_successful_scrape_at: lastSuccessAt?.toISOString() ?? null,
        hours_since_last_success:
          hoursSince !== null ? Math.round(hoursSince * 10) / 10 : null,
        is_scrape_running: info?.isRunning ?? false,
        last_error: info?.status === 'failed' ? (info?.error ?? null) : null,
      };

      return this.formatResponse(result);
    } catch (error) {
      return this.formatResponse({
        status: 'broken' as FreshnessStatus,
        last_successful_scrape_at: null,
        hours_since_last_success: null,
        is_scrape_running: false,
        last_error:
          error instanceof Error ? error.message : 'DB unreachable',
      } satisfies FreshnessResult);
    }
  }
}
