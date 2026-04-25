import { BaseHandler } from './base.js';
import {
  AccountsResponse,
  BalanceHistoryArgs,
  BalanceHistoryResponse,
  DEFAULT_BALANCE_HISTORY_DAYS,
} from '../types.js';
export class AccountHandler extends BaseHandler {
  async getAccounts() {
    const accounts = await this.scraperService.getAccounts();

    // Data refreshes happen via the external cron scraper — this server has no credentials.

    let response: AccountsResponse = {
      success: true,
      accounts,
    };

    // Add scrape status if running
    response = await this.addScrapeStatusIfRunning(response);

    return this.formatResponse({ ...response, ...this.getFreshnessFooterSafe() });
  }

  async getAccountBalanceHistory(args: BalanceHistoryArgs) {
    if (!args.accountId) {
      throw new Error('accountId is required');
    }

    const history = await this.scraperService.getAccountBalanceHistory(
      args.accountId,
      args.days || DEFAULT_BALANCE_HISTORY_DAYS
    );

    let response: BalanceHistoryResponse = {
      success: true,
      accountId: args.accountId,
      history,
    };

    // Add scrape status if running
    response = await this.addScrapeStatusIfRunning(response);

    return this.formatResponse({ ...response, ...this.getFreshnessFooterSafe() });
  }
}
