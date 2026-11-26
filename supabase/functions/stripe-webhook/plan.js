// Pure logic for the stripe-webhook Edge Function.
// Plain ES module: no imports, no Deno APIs, so Node can test it.

const PRICE_ENV_TIERS = [
  ['STRIPE_PRICE_PRO_MONTHLY', 'pro'],
  ['STRIPE_PRICE_PRO_YEARLY', 'pro'],
  ['STRIPE_PRICE_ULTIMATE_MONTHLY', 'ultimate'],
  ['STRIPE_PRICE_ULTIMATE_YEARLY', 'ultimate'],
];

// Maps a Stripe price id to 'pro' | 'ultimate', or null if it isn't one of ours.
export function tierForPrice(priceId, env) {
  if (!priceId) return null;
  for (const [name, tier] of PRICE_ENV_TIERS) {
    if (env[name] && env[name] === priceId) return tier;
  }
  return null;
}

// Builds a subscriptions row (without user_id / updated_at) from a Stripe
// subscription object. Returns null when the price maps to no tier.
export function rowFromSubscription(sub, env) {
  const item = sub.items && sub.items.data && sub.items.data[0];
  const priceId = item && item.price ? item.price.id : null;
  const tier = tierForPrice(priceId, env);
  if (!tier) return null;

  // Newer Stripe API versions moved current_period_end onto subscription items.
  const periodEnd = sub.current_period_end ?? (item ? item.current_period_end : undefined);
  const customer = sub.customer && typeof sub.customer === 'object' ? sub.customer.id : sub.customer;

  return {
    id: sub.id,
    stripe_customer_id: customer ?? null,
    tier,
    status: sub.status,
    current_period_end: periodEnd != null ? new Date(periodEnd * 1000).toISOString() : null,
    cancel_at_period_end: Boolean(sub.cancel_at_period_end),
    livemode: Boolean(sub.livemode),
  };
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}
