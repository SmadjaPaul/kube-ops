import { test, expect } from '@playwright/test';
import {
  URLs,
  assertNoInfiniteLoading,
  attachClassification,
  maybeAuthenticateAtAuthentik,
} from './support';

test('JELLYFIN_SSO_E2E reaches the Jellyfin UI through Authentik', async ({ browser }, testInfo) => {
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    const ssoResponse = await page.goto(
      `${URLs.jellyfin}/sso/Oid/start/authentik`,
      { waitUntil: 'domcontentloaded' },
    );

    expect(ssoResponse?.status(), 'JELLYFIN_SSO_ROUTE').not.toBe(404);
    await page.waitForLoadState('domcontentloaded');
    await maybeAuthenticateAtAuthentik(page);
    await page.waitForURL(
      (url) => url.hostname === new URL(URLs.jellyfin).hostname,
      { timeout: 30_000 },
    );
    await assertNoInfiniteLoading(page);

    await expect(page.locator('body'), 'JELLYFIN_UI_VISIBLE').toContainText(
      /home|library|dashboard|welcome/i,
    );
  } catch (error) {
    await attachClassification(testInfo, 'JELLYFIN_SSO_OR_UI_FAILED');
    throw error;
  } finally {
    await context.close();
  }
});
