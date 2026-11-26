import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tierForPrice, rowFromSubscription, isUuid, subscriptionFields, nextRow } from '../supabase/functions/stripe-webhook/plan.js';

const env = {
  STRIPE_PRICE_PRO_MONTHLY: 'price_pm',
  STRIPE_PRICE_PRO_YEARLY: 'price_py',
  STRIPE_PRICE_ULTIMATE_MONTHLY: 'price_um',
  STRIPE_PRICE_ULTIMATE_YEARLY: 'price_uy',
};

function sub(overrides = {}, itemOverrides = {}) {
  return {
    id: 'sub_123',
    customer: 'cus_456',
    status: 'active',
    cancel_at_period_end: false,
    livemode: false,
    items: { data: [{ price: { id: 'price_pm' }, ...itemOverrides }] },
    ...overrides,
  };
}

test('tierForPrice maps configured prices to tiers', () => {
  assert.equal(tierForPrice('price_pm', env), 'pro');
  assert.equal(tierForPrice('price_py', env), 'pro');
  assert.equal(tierForPrice('price_um', env), 'ultimate');
  assert.equal(tierForPrice('price_uy', env), 'ultimate');
  assert.equal(tierForPrice('price_x', env), null);
});

test('tierForPrice never matches an empty or missing price', () => {
  assert.equal(tierForPrice('', { STRIPE_PRICE_PRO_MONTHLY: '' }), null);
  assert.equal(tierForPrice(undefined, {}), null);
});

test('rowFromSubscription reads top-level current_period_end', () => {
  const row = rowFromSubscription(sub({ current_period_end: 1767225600 }), env);
  assert.deepEqual(row, {
    id: 'sub_123',
    stripe_customer_id: 'cus_456',
    tier: 'pro',
    status: 'active',
    current_period_end: '2026-01-01T00:00:00.000Z',
    cancel_at_period_end: false,
    livemode: false,
  });
});

test('rowFromSubscription falls back to items.data[0].current_period_end', () => {
  const row = rowFromSubscription(sub({}, { current_period_end: 1767225600 }), env);
  assert.equal(row.current_period_end, '2026-01-01T00:00:00.000Z');
});

test('rowFromSubscription returns null for an unknown price', () => {
  const row = rowFromSubscription(sub({ current_period_end: 1767225600 }, { price: { id: 'price_x' } }), env);
  assert.equal(row, null);
});

test('rowFromSubscription carries livemode and cancel_at_period_end through', () => {
  const test = rowFromSubscription(sub({ current_period_end: 1767225600, livemode: false }), env);
  assert.equal(test.livemode, false);
  const live = rowFromSubscription(sub({ current_period_end: 1767225600, livemode: true, cancel_at_period_end: true }, { price: { id: 'price_uy' } }), env);
  assert.equal(live.livemode, true);
  assert.equal(live.cancel_at_period_end, true);
  assert.equal(live.tier, 'ultimate');
});

test('rowFromSubscription accepts an expanded customer object', () => {
  const row = rowFromSubscription(sub({ current_period_end: 1767225600, customer: { id: 'cus_obj' } }), env);
  assert.equal(row.stripe_customer_id, 'cus_obj');
});

test('rowFromSubscription leaves current_period_end null when Stripe omits it', () => {
  const row = rowFromSubscription(sub(), env);
  assert.equal(row.current_period_end, null);
});

test('isUuid accepts UUIDs and rejects anything else', () => {
  assert.equal(isUuid('3f2b8c1e-9a4d-4e2f-8b7a-1c2d3e4f5a6b'), true);
  assert.equal(isUuid('3F2B8C1E-9A4D-4E2F-8B7A-1C2D3E4F5A6B'), true);
  assert.equal(isUuid('not-a-uuid'), false);
  assert.equal(isUuid(''), false);
  assert.equal(isUuid(null), false);
  assert.equal(isUuid("3f2b8c1e-9a4d-4e2f-8b7a-1c2d3e4f5a6b' or 1=1"), false);
});

test('subscriptionFields keeps the fields even when the price maps to no tier', () => {
  const fields = subscriptionFields(sub({ current_period_end: 1767225600, status: 'past_due' }, { price: { id: 'price_x' } }), env);
  assert.deepEqual(fields, {
    id: 'sub_123',
    stripe_customer_id: 'cus_456',
    tier: null,
    status: 'past_due',
    current_period_end: '2026-01-01T00:00:00.000Z',
    cancel_at_period_end: false,
    livemode: false,
  });
});

test('nextRow writes the fresh row when it has a tier', () => {
  const fresh = rowFromSubscription(sub({ current_period_end: 1767225600 }, { price: { id: 'price_uy' } }), env);
  assert.deepEqual(nextRow({ id: 'sub_123', tier: 'pro' }, fresh), fresh);
  assert.deepEqual(nextRow(null, fresh), fresh);
});

test('nextRow keeps the existing tier when the fresh price maps to no tier', () => {
  const fresh = subscriptionFields(sub({ current_period_end: 1767225600, status: 'active', cancel_at_period_end: true }, { price: { id: 'price_x' } }), env);
  const row = nextRow({ id: 'sub_123', tier: 'ultimate', status: 'trialing' }, fresh);
  assert.equal(row.tier, 'ultimate');
  assert.equal(row.status, 'active');
  assert.equal(row.cancel_at_period_end, true);
  assert.equal(row.current_period_end, '2026-01-01T00:00:00.000Z');
});

test('nextRow returns null when there is no tier to write', () => {
  const fresh = subscriptionFields(sub({ current_period_end: 1767225600 }, { price: { id: 'price_x' } }), env);
  assert.equal(nextRow(null, fresh), null);
  assert.equal(nextRow({ id: 'sub_123', tier: null }, fresh), null);
});
