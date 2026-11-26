import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildRestoreSql, buildReadme } from '../backup-data.js';

const data = {
  teams: [{ id: 1, name: 'Club', price: 10 }],
  site_settings: [
    { key: 'hero', value: { title: 'x' }, updated_at: '2026-11-26T00:00:00Z' },
    { key: 'payments', value: { mode: 'live' }, updated_at: '2026-11-26T00:00:00Z' },
    { key: 'season', value: { start: '2026-12-20T00:00:00Z' }, updated_at: '2026-11-26T00:00:00Z' },
  ],
  price_history: [],
};

function siteSettingsStatement(sql) {
  const start = sql.indexOf('insert into public.site_settings');
  assert.ok(start >= 0, 'site_settings insert present');
  return sql.slice(start, sql.indexOf(';', sql.indexOf('on conflict', start)) + 1);
}

test('restore.sql never overwrites the payments or season settings', () => {
  const stmt = siteSettingsStatement(buildRestoreSql(data, '2026-11-26T00:00:00Z'));
  assert.match(stmt, /on conflict \(key\) do update set value = excluded\.value, updated_at = excluded\.updated_at\s+where public\.site_settings\.key not in \('payments', 'season'\);$/);
});

test('restore.sql still overwrites other tables as before', () => {
  const sql = buildRestoreSql(data, '2026-11-26T00:00:00Z');
  assert.match(sql, /on conflict \(id\) do update set name = excluded\.name, price = excluded\.price;/);
});

test('the backup README explains why payments and season are kept', () => {
  const readme = buildReadme(data, '2026-11-26T00:00:00Z');
  assert.match(readme, /payments/);
  assert.match(readme, /season/);
  assert.match(readme, /never changes/);
});
