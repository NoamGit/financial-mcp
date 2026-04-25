import { ScraperService } from '@bank-assistant/scraper';
import { logger } from '../utils/logger.js';
import { omitNullValues } from '../utils/response-optimizer.js';

export abstract class BaseHandler {
  constructor(protected scraperService: ScraperService) {}

  protected parseDate(dateString?: string): Date | undefined {
    return dateString ? new Date(dateString) : undefined;
  }

  protected async addScrapeStatusIfRunning<T extends { message?: string }>(
    response: T
  ): Promise<T> {
    const scrapeStatus = this.scraperService.getScrapeStatus();

    if (
      scrapeStatus.isAnyScrapeRunning &&
      scrapeStatus.activeScrapes?.length > 0
    ) {
      const runningServices = scrapeStatus.activeScrapes
        .map(s => s.provider)
        .join(', ');

      const warningMessage = `Note: Data scraping is currently in progress for: ${runningServices}. The data shown may be stale.`;

      if (response.message) {
        response.message = `${response.message}\n\n⚠️ ${warningMessage}`;
      } else {
        response.message = `⚠️ ${warningMessage}`;
      }
    }
    return response;
  }

  protected formatResponse<T>(data: T): {
    content: Array<{ type: string; text: string }>;
  } {
    // Remove null values to reduce response size
    const cleanedData = omitNullValues(data);

    // Check response size and warn if too large
    const responseStr = JSON.stringify(cleanedData, null, 2);
    const sizeInBytes = responseStr.length * 2; // Rough estimate

    if (sizeInBytes > 50 * 1024) {
      // 50KB threshold
      logger.warn('Large MCP response detected', {
        sizeInBytes,
        sizeInKB: Math.round(sizeInBytes / 1024),
        handler: this.constructor.name,
      });
    }

    return {
      content: [
        {
          type: 'text',
          text: responseStr,
        },
      ],
    };
  }

  protected formatError(error: unknown): {
    content: Array<{ type: string; text: string }>;
  } {
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            {
              success: false,
              error: error instanceof Error ? error.message : 'Unknown error',
            },
            null,
            2
          ),
        },
      ],
    };
  }

  /**
   * Build a lightweight data_freshness block for embedding in tool responses.
   * All data-returning tools include this so the LLM always sees staleness info.
   * Uses two-pass logic: separate query for last completed run timestamp so that
   * 'broken' is reachable even when the most recent run failed.
   */
  protected getFreshnessFooter(): {
    data_freshness: {
      as_of: string | null;
      hours_since_last_success: number | null;
      status: 'fresh' | 'stale' | 'broken' | 'never';
    };
  } {
    const lastSuccessAt = this.scraperService.getLastSuccessfulScrapeAt();
    const info = this.scraperService.getLastScrapeInfo();

    const hoursSince =
      lastSuccessAt != null
        ? (Date.now() - lastSuccessAt.getTime()) / 3600000
        : null;

    const lastRunFailed = info?.status === 'failed' && !info?.isRunning;

    let status: 'fresh' | 'stale' | 'broken' | 'never';
    if (!lastSuccessAt && !info?.isRunning) {
      status = 'never';
    } else if (lastRunFailed) {
      status = 'broken';
    } else if (hoursSince !== null && hoursSince > 36) {
      status = 'stale';
    } else {
      status = 'fresh';
    }

    return {
      data_freshness: {
        as_of: lastSuccessAt?.toISOString() ?? null,
        hours_since_last_success:
          hoursSince !== null ? Math.round(hoursSince * 10) / 10 : null,
        status,
      },
    };
  }

  /**
   * Safe wrapper around getFreshnessFooter().
   * If the DB throws (e.g. unreachable), returns a neutral fallback so the
   * tool response is not discarded entirely.
   */
  protected getFreshnessFooterSafe(): {
    data_freshness: {
      as_of: string | null;
      hours_since_last_success: number | null;
      status: 'fresh' | 'stale' | 'broken' | 'never';
    };
  } {
    try {
      return this.getFreshnessFooter();
    } catch {
      return {
        data_freshness: {
          as_of: null,
          hours_since_last_success: null,
          status: 'broken',
        },
      };
    }
  }

  /**
   * Calculate the number of days between two dates
   */
  protected getDaysBetween(startDate?: Date, endDate?: Date): number {
    if (!startDate || !endDate) return 0;
    const diffTime = Math.abs(endDate.getTime() - startDate.getTime());
    return Math.ceil(diffTime / (1000 * 60 * 60 * 24));
  }

  /**
   * Check if the requested timeframe is considered "large"
   */
  protected isLargeTimeframe(startDate?: Date, endDate?: Date): boolean {
    return this.getDaysBetween(startDate, endDate) > 90;
  }
}
