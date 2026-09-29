import { test, expect } from '@playwright/test';
import {
  URLs,
  assertNoInfiniteLoading,
  attachClassification,
  maybeAuthenticateAtAuthentik,
} from './support';

test('ARGO_SSO_E2E readonly user can list apps but has no admin UI', async ({ browser }, testInfo) => {
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    await page.goto(URLs.argocd, { waitUntil: 'domcontentloaded' });

    const sso = page.getByRole('button', { name: /log in via authentik|authentik|sso/i }).first();
    if (await sso.isVisible().catch(() => false)) await sso.click();

    await page.waitForLoadState('domcontentloaded');
    await maybeAuthenticateAtAuthentik(page);
    await page.waitForURL((url) => url.hostname === new URL(URLs.argocd).hostname, { timeout: 30_000 });
    await assertNoInfiniteLoading(page);

    await expect(page.getByText(/applications/i).first(), 'ARGO_APP_LIST_VISIBLE').toBeVisible();
    const userInfo = await context.request.get(`${URLs.argocd}/api/v1/session/userinfo`);
    expect(userInfo.ok(), 'ARGO_CALLBACK').toBeTruthy();
    const identity = await userInfo.json();
    expect(identity.groups ?? []).toContain('dev');
    expect(identity.groups ?? []).not.toContain('admin');
    expect(identity.groups ?? []).not.toContain('authentik-admins');

    const createButton = page.getByRole('button', { name: /new app|create application/i }).first();
    if (await createButton.count()) {
      await expect(createButton, 'QA user must remain Argo readonly').toBeDisabled();
    }
  } catch (error) {
    await attachClassification(testInfo, 'ARGO_SSO_OR_RBAC_FAILED');
    throw error;
  } finally {
    await context.close();
  }
});
