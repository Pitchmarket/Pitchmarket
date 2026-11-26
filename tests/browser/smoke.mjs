import assert from 'node:assert/strict';
import { openPage } from './harness.mjs';

const mk = (id, name, price) => ({ id, name, league: 'epl', league_label: 'Premier League', tier: 'ENG · TIER 1', price, chg: 0, league_order: 1 });
const { page, errors, browser } = await openPage('http://127.0.0.1:8765/index.html', {
  routes: { teams: () => [mk(1, 'Arsenal', 100), mk(2, 'Chelsea', 90)] },
});
try {
  await page.waitForFunction(() => document.querySelectorAll('#tableBody tr:not(.sk-row)').length === 2, null, { timeout: 8000 });
  assert.equal(await page.locator('#tableBody tr').count(), 2);
  assert.deepEqual(errors, []);
  console.log('ok');
} finally { await browser.close(); }
