import { expect, Page, TestInfo } from '@playwright/test';

export const URLs = {
  authentik: process.env.AUTHENTIK_URL ?? 'https://auth.smadja.dev',
  argocd: process.env.ARGOCD_URL ?? 'https://argocd.smadja.dev',
  openwebui: process.env.OPENWEBUI_URL ?? 'https://chat.smadja.dev',
  homeAssistant: process.env.HOME_ASSISTANT_URL ?? 'https://hassio.smadja.dev',
};

export function qaCredentials() {
  const username = process.env.E2E_USERNAME ?? 'e2e-user';
  const password = process.env.E2E_PASSWORD;
  if (!password) throw new Error('E2E_PASSWORD is required');
  return { username, password };
}

export async function attachClassification(testInfo: TestInfo, value: string) {
  await testInfo.attach('failure-classification', {
    body: Buffer.from(value),
    contentType: 'text/plain',
  });
}

export async function authenticateAtAuthentik(page: Page) {
  const { username, password } = qaCredentials();

  const identity = page.locator(
    'input[name="uid"], input[name="username"], input[type="email"], input[type="text"]',
  ).first();
  await expect(identity, 'LOGIN_FORM_MISSING').toBeVisible();
  await identity.fill(username);

  const continueButton = page.getByRole('button', { name: /continue|log in|sign in|submit|next/i }).first();
  await expect(continueButton, 'LOGIN_FORM_MISSING').toBeVisible();
  await continueButton.click();

  const passwordInput = page.locator('input[type="password"]').first();
  await expect(passwordInput, 'PASSWORD_FORM_MISSING').toBeVisible();
  await passwordInput.fill(password);

  const submitButton = page.getByRole('button', { name: /continue|log in|sign in|submit|next/i }).first();
  await expect(submitButton, 'PASSWORD_FORM_MISSING').toBeVisible();
  await submitButton.click();

  await page.waitForLoadState('domcontentloaded');
  await expect(page.locator('input[type="password"]'), 'PASSWORD_REJECTED').toHaveCount(0);
}

export async function maybeAuthenticateAtAuthentik(page: Page) {
  if (new URL(page.url()).hostname === new URL(URLs.authentik).hostname) {
    await authenticateAtAuthentik(page);
  }
}

export async function assertNoInfiniteLoading(page: Page) {
  const spinner = page.locator(
    '[role="progressbar"], .pf-c-spinner, ak-spinner, [aria-label*="loading" i]',
  );
  if (await spinner.count()) {
    await expect(spinner.first(), 'INFINITE_LOADING').toBeHidden({ timeout: 15_000 });
  }
}
