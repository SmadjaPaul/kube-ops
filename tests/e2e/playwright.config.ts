import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './specs',
  timeout: 60_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  retries: 0,
  reporter: [
    ['line'],
    ['junit', { outputFile: 'test-results/junit.xml' }],
    ['json', { outputFile: 'test-results/results.json' }],
  ],
  outputDir: 'test-results/artifacts',
  use: {
    ...devices['Desktop Chrome'],
    ignoreHTTPSErrors: false,
    screenshot: 'only-on-failure',
    trace: 'off',
    video: 'off',
  },
});
