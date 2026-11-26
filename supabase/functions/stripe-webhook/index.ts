// Supabase Edge Function: stripe-webhook
// Receives Stripe events, verifies the signature and keeps the private
// `subscriptions` table in sync. Pure logic lives in ./plan.js.
import Stripe from 'https://esm.sh/stripe@17.7.0?target=deno';
import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.118.0';
import {
  isResourceMissing,
  isUuid,
  missingSecrets,
  nextRow,
  REQUIRED_SECRETS,
  subscriptionFields,
} from './plan.js';

// Read the secrets once. Only names are ever logged, never values.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
const SUPABASE_SECRETS = ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'];
const secrets: Record<string, string> = {};
for (const name of [...REQUIRED_SECRETS, ...SUPABASE_SECRETS]) secrets[name] = Deno.env.get(name) ?? '';

const missing = missingSecrets(secrets, [...REQUIRED_SECRETS, ...SUPABASE_SECRETS]);
if (missing.length > 0) {
  console.error(`stripe-webhook configuration error: missing secrets ${missing.join(', ')}`);
}
// Without these the webhook can't verify, retrieve or write anything.
const missingCore = missingSecrets(secrets, ['STRIPE_SECRET_KEY', 'STRIPE_WEBHOOK_SECRET', ...SUPABASE_SECRETS]);

const cryptoProvider = Stripe.createSubtleCryptoProvider();
const webhookSecret = secrets.STRIPE_WEBHOOK_SECRET;
const priceEnv = secrets;

// Clients are built on first use, after the missing-secret check: both
// constructors throw on an empty key/URL, which would crash the module at load.
let stripeClient: Stripe | null = null;
function getStripe(): Stripe {
  stripeClient ??= new Stripe(secrets.STRIPE_SECRET_KEY, {
    httpClient: Stripe.createFetchHttpClient(),
  });
  return stripeClient;
}

let supabaseClient: SupabaseClient | null = null;
function getSupabase(): SupabaseClient {
  supabaseClient ??= createClient(secrets.SUPABASE_URL, secrets.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  return supabaseClient;
}

function reply(status: number, text: string): Response {
  return new Response(text, { status, headers: { 'Content-Type': 'text/plain' } });
}

// Writes Stripe's current state of a subscription. `userId` is the player from
// a checkout; without it the row must already exist or the player is found
// from another row of the same Stripe customer.
async function syncSubscription(sub: Stripe.Subscription, userId: string | null, forceCanceled = false): Promise<Response> {
  const fresh = subscriptionFields(sub, priceEnv);
  // A deleted event means the subscription has ended, whatever the retrieved object says.
  if (forceCanceled) fresh.status = 'canceled';

  const existing = await getSupabase().from('subscriptions').select('id, tier, user_id').eq('id', fresh.id).maybeSingle();
  if (existing.error) throw existing.error;

  const row = nextRow(existing.data, fresh);
  if (!row) {
    console.log('subscription has a price that maps to no tier and no stored tier; not written', fresh.id);
    return reply(200, 'ignored: unknown price');
  }
  if (!fresh.tier) {
    console.log('subscription moved to a price that maps to no tier; keeping stored tier', fresh.id, row.tier);
  }
  const updatedAt = new Date().toISOString();

  if (existing.data) {
    // Never move an existing subscription to another player.
    if (userId && existing.data.user_id !== userId) {
      console.log('checkout client_reference_id differs from the stored player; keeping stored user_id', row.id);
    }
    const { error } = await getSupabase()
      .from('subscriptions')
      .update({ ...row, updated_at: updatedAt })
      .eq('id', row.id);
    if (error) throw error;
    return reply(200, 'ok');
  }

  if (!userId) {
    // No row yet: find the player from another subscription of the same customer.
    if (!row.stripe_customer_id) {
      console.log('subscription event for an unknown subscription with no customer', row.id);
      return reply(200, 'ignored: unknown subscription');
    }
    const owner = await getSupabase()
      .from('subscriptions')
      .select('user_id')
      .eq('stripe_customer_id', row.stripe_customer_id)
      .limit(1)
      .maybeSingle();
    if (owner.error) throw owner.error;
    if (!owner.data) {
      console.log('subscription event for a customer with no known player', row.id, row.stripe_customer_id);
      return reply(200, 'ignored: unknown customer');
    }
    userId = owner.data.user_id;
  }

  const { error } = await getSupabase()
    .from('subscriptions')
    .upsert({ ...row, user_id: userId, updated_at: updatedAt }, { onConflict: 'id' });
  if (error) throw error;
  return reply(200, 'ok');
}

async function handleCheckoutCompleted(session: Stripe.Checkout.Session): Promise<Response> {
  if (session.mode !== 'subscription') return reply(200, 'ignored: not a subscription checkout');

  const userId = session.client_reference_id;
  const subId = typeof session.subscription === 'string' ? session.subscription : session.subscription?.id;
  if (!userId || !subId) {
    console.log('checkout.session.completed without client_reference_id or subscription', session.id);
    return reply(200, 'ignored: missing client_reference_id or subscription');
  }
  if (!isUuid(userId)) {
    console.log('checkout.session.completed with a client_reference_id that is not a UUID', session.id);
    return reply(200, 'ignored: client_reference_id is not a UUID');
  }

  let sub: Stripe.Subscription;
  try {
    sub = await getStripe().subscriptions.retrieve(subId);
  } catch (err) {
    if (!isResourceMissing(err)) throw err;
    console.log('checkout subscription no longer exists in Stripe; not written', subId);
    return reply(200, 'ignored: subscription missing');
  }
  return await syncSubscription(sub, userId);
}

// Stripe doesn't guarantee event order, so never trust the event's embedded
// object: retrieve the subscription's current state and write that.
async function handleSubscriptionEvent(subId: string, deleted: boolean): Promise<Response> {
  let sub: Stripe.Subscription;
  try {
    sub = await getStripe().subscriptions.retrieve(subId);
  } catch (err) {
    if (!isResourceMissing(err)) throw err;
    console.log('subscription no longer exists in Stripe; marking canceled', subId);
    const { error } = await getSupabase()
      .from('subscriptions')
      .update({ status: 'canceled', updated_at: new Date().toISOString() })
      .eq('id', subId);
    if (error) throw error;
    return reply(200, 'ok: missing subscription marked canceled');
  }
  return await syncSubscription(sub, null, deleted);
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return reply(405, 'Method not allowed');
  if (missingCore.length > 0) return reply(500, `Webhook not configured: missing ${missingCore.join(', ')}`);

  const body = await req.text();
  const signature = req.headers.get('stripe-signature');
  if (!signature) return reply(400, 'Missing stripe-signature');

  let event: Stripe.Event;
  try {
    event = await getStripe().webhooks.constructEventAsync(body, signature, webhookSecret, undefined, cryptoProvider);
  } catch (err) {
    console.log('signature verification failed', err instanceof Error ? err.message : err);
    return reply(400, 'Bad signature');
  }

  try {
    switch (event.type) {
      case 'checkout.session.completed':
        return await handleCheckoutCompleted(event.data.object as Stripe.Checkout.Session);
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
        return await handleSubscriptionEvent((event.data.object as Stripe.Subscription).id, false);
      case 'customer.subscription.deleted':
        return await handleSubscriptionEvent((event.data.object as Stripe.Subscription).id, true);
      default:
        return reply(200, 'ignored');
    }
  } catch (err) {
    // A 500 makes Stripe retry the event later.
    console.error('failed to handle', event.type, event.id, err);
    return reply(500, 'Internal error');
  }
});
