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

// Reads the subscriptions fields (without user_id / updated_at) from a Stripe
// subscription object. `tier` is null when the price maps to no tier.
export function subscriptionFields(sub, env) {
  const item = sub.items && sub.items.data && sub.items.data[0];
  const priceId = item && item.price ? item.price.id : null;

  // Newer Stripe API versions moved the current period onto subscription items.
  const periodStart = sub.current_period_start ?? (item ? item.current_period_start : undefined);
  const periodEnd = sub.current_period_end ?? (item ? item.current_period_end : undefined);
  const customer = sub.customer && typeof sub.customer === 'object' ? sub.customer.id : sub.customer;

  return {
    id: sub.id,
    stripe_customer_id: customer ?? null,
    tier: tierForPrice(priceId, env),
    status: sub.status,
    current_period_start: periodStart != null ? new Date(periodStart * 1000).toISOString() : null,
    current_period_end: periodEnd != null ? new Date(periodEnd * 1000).toISOString() : null,
    cancel_at_period_end: Boolean(sub.cancel_at_period_end),
    livemode: Boolean(sub.livemode),
  };
}

// Like subscriptionFields, but null when the price maps to no tier.
export function rowFromSubscription(sub, env) {
  const fields = subscriptionFields(sub, env);
  return fields.tier ? fields : null;
}

// Decides what to write given the stored row (or null) and fresh fields from
// subscriptionFields. A price that maps to no tier keeps the stored tier;
// returns null when there is no tier at all (tier may not be null in a row).
export function nextRow(existingRow, fresh) {
  if (fresh.tier) return fresh;
  if (existingRow && existingRow.tier) return { ...fresh, tier: existingRow.tier };
  return null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

// The six Edge Function secrets the webhook needs.
export const REQUIRED_SECRETS = [
  'STRIPE_SECRET_KEY',
  'STRIPE_WEBHOOK_SECRET',
  ...PRICE_ENV_TIERS.map(([name]) => name),
];

// Names (never values) of the secrets in `names` that are unset or empty.
export function missingSecrets(env, names = REQUIRED_SECRETS) {
  return names.filter((name) => !env[name]);
}

// True for a Stripe error saying the object doesn't exist.
export function isResourceMissing(err) {
  return Boolean(err) && err.code === 'resource_missing';
}

// True for a Postgres foreign key violation (23503): on a checkout, the
// client_reference_id is a UUID but not a player.
export function isUnknownPlayer(err) {
  return Boolean(err) && err.code === '23503';
}
