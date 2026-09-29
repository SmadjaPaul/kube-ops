import { test, expect } from '@playwright/test';
import {
  URLs,
  assertNoInfiniteLoading,
  attachClassification,
  maybeAuthenticateAtAuthentik,
} from './support';

test('OPENWEBUI_E2E reaches authenticated main UI without model call', async ({ browser }, testInfo) => {
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    await page.goto(URLs.openwebui, { waitUntil: 'domcontentloaded' });

    const loginEntry = page
      .getByRole('button', { name: /sign in|log in|login|single sign-on|sso|openid|oidc/i })
      .or(page.getByRole('link', { name: /sign in|log in|login|single sign-on|sso|openid|oidc/i }))
      .first();
    if (await loginEntry.isVisible().catch(() => false)) await loginEntry.click();

    await page.waitForLoadState('domcontentloaded');
    await maybeAuthenticateAtAuthentik(page);

    if (new URL(page.url()).hostname === new URL(URLs.authentik).hostname) {
      await page.waitForURL((url) => url.hostname === new URL(URLs.openwebui).hostname, {
        timeout: 30_000,
      });
    }

    await assertNoInfiniteLoading(page);

    const mainUi = page.locator('textarea, [contenteditable="true"], nav').first();
    await expect(mainUi, 'OPENWEBUI_MAIN_UI_VISIBLE').toBeVisible({ timeout: 30_000 });
  } catch (error) {
    await attachClassification(testInfo, 'OPENWEBUI_LOGIN_OR_UI_FAILED');
    throw error;
  } finally {
    await context.close();
  }
});
