import {test, expect, type Page} from '@playwright/test';
import {geometryLocations, pickAt} from './support/e2e-helpers';
import {generateStepAssembly} from './support/step-generator';

type ErrorAwarePage = Page & {applicationErrors: string[]};

test.beforeEach(async ({page}) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => {if (message.type() === 'error') errors.push(message.text());});
  await page.goto('/');
  await expect(page.locator('header').getByRole('button', {name: /^Open file/})).toBeEnabled();
  (page as ErrorAwarePage).applicationErrors = errors;
});

test.afterEach(async ({page}) => {
  expect((page as ErrorAwarePage).applicationErrors, 'No application or console errors').toEqual([]);
});

// Above the size at which STEP files are read product by product.
const generated = generateStepAssembly({products: 40, usesPerProduct: 6, sides: 260});

test('a large STEP assembly opens part by part and keeps exact feature queries', async ({page, isMobile}) => {
  test.skip(isMobile, 'The large-file path is the same on touch devices; one run is enough.');
  expect(generated.text.length).toBeGreaterThan(16 * 1024 * 1024);
  await page.locator('input[type=file]').setInputFiles({name: 'generated-large.step', mimeType: 'application/step', buffer: Buffer.from(generated.text)});
  await expect(page.locator('.model-badge')).toContainText(`CAD model·${generated.solidOccurrences} parts`, {timeout: 120_000});
  await expect(page.locator('.loading-overlay')).toHaveCount(0, {timeout: 120_000});
  await expect(page.locator('.model-badge')).toContainText(`CAD model·${generated.solidOccurrences} parts`);
  await expect(page.getByRole('alert')).toHaveCount(0);
  const locations = await geometryLocations(page);
  await page.getByTitle('Pick CAD features · E', {exact: true}).click();
  await page.getByLabel('Feature selection filter').selectOption('face');
  await pickAt(page, locations[0], isMobile);
  await expect(page.locator('.feature-properties .subheading')).toContainText('Exact', {timeout: 60_000});
  await expect(page.locator('.feature-properties')).toContainText('Area');
  await pickAt(page, locations[1], isMobile);
  await expect(page.locator('.accuracy-tag')).toContainText('Exact CAD geometry', {timeout: 60_000});
  await expect(page.locator('.measurement-note')).toContainText('Exact minimum distance between CAD features');
  const distance = Number((await page.locator('.result-hero strong').innerText()).replaceAll(',', ''));
  expect(distance).toBeGreaterThan(0);
});
