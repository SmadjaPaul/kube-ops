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
      .getByRole('button', {
        name: /sign in|log in|login|single sign-on|sso|openid|oidc|authentik/i,
      })
      .or(
        page.getByRole('link', {
          name: /sign in|log in|login|single sign-on|sso|openid|oidc|authentik/i,
        }),
      )
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

    // Open WebUI v0.9.5 gives the primary composer a stable #chat-input id.
    // Keep navigation as a fallback for accounts that land on an authenticated
    // page before the composer is mounted.
    const mainUi = page.locator('#chat-input, nav').first();
    await expect(mainUi, 'OPENWEBUI_MAIN_UI_VISIBLE').toBeVisible({ timeout: 30_000 });

    const sessionResponse = await page.request.get('/api/v1/auths/');
    expect(sessionResponse.status(), 'OPENWEBUI_SESSION_HTTP').toBe(200);

    const session = await sessionResponse.json();
    expect(session?.role, 'OPENWEBUI_E2E_ROLE').toBe('user');
  } catch (error) {
    await attachClassification(testInfo, 'OPENWEBUI_LOGIN_OR_UI_FAILED');
    throw error;
  } finally {
    await context.close();
  }
});
