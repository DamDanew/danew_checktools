import { test, expect } from '@playwright/test';

const reportUrl = 'file:///H:/Danew_CheckTool/WinPe_local/reports/sav-diagnostic-report.html';

test('rapport SAV: affichage, interactions, absence erreurs console', async ({ page }) => {
  const consoleErrors: string[] = [];
  const pageErrors: string[] = [];

  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      consoleErrors.push(msg.text());
    }
  });

  page.on('pageerror', (err) => {
    pageErrors.push(String(err));
  });

  await page.goto(reportUrl);

  await expect(page).toHaveTitle('Rapport de diagnostic SAV Danew');
  await expect(page.getByRole('heading', { level: 1, name: 'Rapport de diagnostic SAV Danew' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Developper tout' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Reduire tout' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Imprimer' })).toBeVisible();

  const search = page.getByRole('searchbox', {
    name: 'Filtrer les causes, motifs de chronologie, fournisseurs ou recommandations',
  });
  await expect(search).toBeVisible();

  await page.getByRole('button', { name: 'Developper tout' }).click();
  await expect(page.getByText('25 premiers enregistrements classes pour un triage rapide.')).toBeVisible();

  await search.fill('bitlocker');
  await expect(page.getByRole('cell', { name: 'Volume verrouille par BitLocker' })).toBeVisible();

  await page.getByRole('button', { name: 'Reduire tout' }).click();
  await expect(page.getByRole('button', { name: 'Developper tout' })).toBeVisible();

  expect(consoleErrors, `Console errors: ${consoleErrors.join(' | ')}`).toEqual([]);
  expect(pageErrors, `Page errors: ${pageErrors.join(' | ')}`).toEqual([]);
});

test('rapport SAV: tri causes, filtre et reset filtre', async ({ page }) => {
  const reportUrl = 'file:///H:/Danew_CheckTool/WinPe_local/reports/sav-diagnostic-report.html';
  await page.goto(reportUrl);

  await expect(page.getByRole('button', { name: 'Developper tout' })).toBeVisible();
  await page.getByRole('button', { name: 'Developper tout' }).click();

  const scoreHeader = page.getByRole('button', { name: 'Score' });
  await expect(scoreHeader).toBeVisible();
  await scoreHeader.click();
  await scoreHeader.click();

  const firstScoreText = await page.locator('table tbody tr').first().locator('td').nth(2).innerText();
  const firstScore = Number.parseInt(firstScoreText.trim(), 10);
  expect(Number.isNaN(firstScore)).toBeFalsy();
  expect(firstScore).toBeGreaterThanOrEqual(60);

  const search = page.getByRole('searchbox', {
    name: 'Filtrer les causes, motifs de chronologie, fournisseurs ou recommandations',
  });
  const countBadge = page.locator('[data-report-count]');

  await expect(countBadge).toBeVisible();
  await expect(countBadge).toContainText('lignes visibles');

  await search.fill('bitlocker');
  await expect(page.getByRole('cell', { name: 'Volume verrouille par BitLocker' })).toBeVisible();
  await expect(countBadge).toContainText('resultat');

  await page.getByRole('button', { name: 'Effacer filtre' }).click();
  await expect(search).toHaveValue('');
  await expect(countBadge).toContainText('lignes visibles');

  await expect(page.getByRole('cell', { name: 'Instabilite thermique' })).toBeVisible();
});

test('rapports harmonises: evtx-by-file et export-summary', async ({ page }) => {
  await page.goto('file:///H:/Danew_CheckTool/WinPe_local/reports/evtx-by-file.html');
  await expect(page.getByRole('heading', { level: 1, name: 'EVTX rapide par fichier' })).toBeVisible();
  await expect(page.getByRole('searchbox')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Effacer filtre' })).toBeVisible();
  await expect(page.locator('[data-report-count]')).toBeVisible();

  const search = page.getByRole('searchbox');
  await search.fill('kernel-power');
  await expect(page.locator('[data-report-count]')).toContainText('resultat');
  await page.getByRole('button', { name: 'Effacer filtre' }).click();
  await expect(search).toHaveValue('');

  await page.goto('file:///H:/Danew_CheckTool/WinPe_local/reports/export-summary.html');
  await expect(page).toHaveTitle('Resume export USB Danew');
  await expect(page.getByRole('button', { name: 'Effacer filtre' })).toBeVisible();
  await expect(page.locator('[data-report-count]')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Developper tout' })).toBeVisible();
});
