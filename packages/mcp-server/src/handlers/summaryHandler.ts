import { BaseHandler } from './base.js';
import { SummaryArgs, SummaryResponse } from '../types.js';
import { optimizeFinancialSummary } from '../utils/response-optimizer.js';

export class SummaryHandler extends BaseHandler {
  async getFinancialSummary(args: SummaryArgs) {
    const startDate = this.parseDate(args.startDate);
    const endDate = this.parseDate(args.endDate);

    const summary = await this.scraperService.getFinancialSummary(
      startDate,
      endDate
    );

    // Data refreshes happen via the external cron scraper — this server has no credentials.
    // If the summary is empty, the LLM should be informed via the freshness footer.

    // Optimize the summary for large timeframes to prevent MCP response size errors
    const optimizedSummary = optimizeFinancialSummary(
      summary,
      startDate?.toISOString(),
      endDate?.toISOString()
    );

    let response: SummaryResponse = {
      success: true,
      summary: optimizedSummary,
    };

    // Add scrape status if running
    response = await this.addScrapeStatusIfRunning(response);

    return this.formatResponse({ ...response, ...this.getFreshnessFooterSafe() });
  }

}
