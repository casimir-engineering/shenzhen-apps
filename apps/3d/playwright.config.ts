import {defineConfig, devices} from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  testMatch: /e2e(-[a-z-]+)?\.spec\.ts$/,
  timeout: 180_000,
  expect: {timeout: 15_000},
  fullyParallel: false,
  workers: 1,
  reporter: [['list'], ['html', {open: 'never'}]],
  use: {
    baseURL: process.env.E2E_BASE_URL || 'http://127.0.0.1:1420',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    launchOptions: {args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader']},
  },
  projects: [
    {name: 'desktop-chromium', use: {...devices['Desktop Chrome'], viewport: {width: 1440, height: 1000}}},
    {name: 'mobile-chromium', use: {...devices['iPhone 13'], defaultBrowserType: 'chromium'}},
  ],
  webServer: process.env.E2E_BASE_URL ? undefined : {
    command: process.env.CI ? 'npm run preview -- --port 1420 --strictPort' : 'npm run dev',
    url: 'http://127.0.0.1:1420',
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
});
