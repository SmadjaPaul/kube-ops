import { test, expect } from '@playwright/test';
import {
  URLs,
  assertNoInfiniteLoading,
  attachClassification,
  maybeAuthenticateAtAuthentik,
} from './support';

test('HOME_ASSISTANT_UI_READY reaches login/onboarding/dashboard', async ({ browser }, testInfo) => {
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    await page.goto(URLs.homeAssistant, { waitUntil: 'domcontentloaded' });

    const oidc = page.getByText(/login with openid|oauth2|openid/i).first();
    if (await oidc.isVisible().catch(() => false)) await oidc.click();

    await page.waitForLoadState('domcontentloaded');
    await maybeAuthenticateAtAuthentik(page);

    if (new URL(page.url()).hostname === new URL(URLs.authentik).hostname) {
      await page.waitForURL((url) => url.hostname === new URL(URLs.homeAssistant).hostname, {
        timeout: 30_000,
      });
    }

    await assertNoInfiniteLoading(page);

    const readySurface = page.locator(
      'home-assistant, ha-panel-lovelace, onboarding-core-config, ha-sidebar',
    ).first();
    await expect(readySurface, 'HA_LOGIN_OR_ONBOARDING').toBeVisible({ timeout: 30_000 });
  } catch (error) {
    await attachClassification(testInfo, 'HOME_ASSISTANT_LOGIN_ONBOARDING_OR_DASHBOARD_FAILED');
    throw error;
  } finally {
    await context.close();
  }
});
