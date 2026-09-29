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

    const usersApi = await context.request.get(`${URLs.authentik}/api/v3/core/users/`);
    if (usersApi.status() === 200) {
      const body = await usersApi.json();
      const visibleUsers = Array.isArray(body?.results) ? body.results : [];
      expect(
        visibleUsers.every((user: { username?: string }) => user.username === 'e2e-user'),
        'QA user can enumerate identities outside its own account',
      ).toBeTruthy();
    } else {
      expect([401, 403]).toContain(usersApi.status());
    }
  } catch (error) {
    await attachClassification(testInfo, 'AUTHENTIK_LOGIN_OR_AUTHORIZATION_FAILED');
    throw error;
  } finally {
    await context.close();
  }
});
