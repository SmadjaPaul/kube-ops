import { test, expect } from '@playwright/test';
import {
  URLs,
  assertNoInfiniteLoading,
  attachClassification,
  authenticateAtAuthentik,
} from './support';

test('AUTHENTIK_LOGIN_SUCCESS and non-admin authorization', async ({ browser }, testInfo) => {
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    await page.goto(URLs.authentik, { waitUntil: 'domcontentloaded' });
    await authenticateAtAuthentik(page);
    await assertNoInfiniteLoading(page);

    expect(new URL(page.url()).hostname).toBe(new URL(URLs.authentik).hostname);
    expect((await context.cookies()).some((cookie) => cookie.domain.includes('smadja.dev'))).toBeTruthy();

    const adminApi = await context.request.get(`${URLs.authentik}/api/v3/core/users/`);
    expect(
      [401, 403].includes(adminApi.status()),
      `QA user unexpectedly reached Authentik admin API with status ${adminApi.status()}`,
    ).toBeTruthy();
  } catch (error) {
    await attachClassification(testInfo, 'AUTHENTIK_LOGIN_OR_AUTHORIZATION_FAILED');
    throw error;
  } finally {
    await context.close();
  }
});
