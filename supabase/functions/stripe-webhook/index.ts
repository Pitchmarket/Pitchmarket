// Supabase Edge Function: stripe-webhook
// Receives Stripe events, verifies the signature and keeps the private
// `subscriptions` table in sync. Pure logic lives in ./plan.js.
import Stripe from 'https://esm.sh/stripe@17.7.0?target=deno';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.118.0';
import { isUuid, rowFromSubscription } from './plan.js';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY')!, {
  httpClient: Stripe.createFetchHttpClient(),
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET')!;

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { auth: { persistSession: false } },
);

const priceEnv: Record<string, string> = {};
for (const name of [
  'STRIPE_PRICE_PRO_MONTHLY',
  'STRIPE_PRICE_PRO_YEARLY',
  'STRIPE_PRICE_ULTIMATE_MONTHLY',
  'STRIPE_PRICE_ULTIMATE_YEARLY',
]) {
  priceEnv[name] = Deno.env.get(name) ?? '';
}

function reply(status: number, text: string): Response {
  return new Response(text, { status, headers: { 'Content-Type': 'text/plain' } });
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

  const sub = await stripe.subscriptions.retrieve(subId);
  const row = rowFromSubscription(sub, priceEnv);
  if (!row) {
    console.log('subscription has a price that maps to no tier', sub.id);
    return reply(200, 'ignored: unknown price');
  }

  const { error } = await supabase
    .from('subscriptions')
    .upsert({ ...row, user_id: userId, updated_at: new Date().toISOString() }, { onConflict: 'id' });
  if (error) throw error;
  return reply(200, 'ok');
}

async function handleSubscriptionEvent(sub: Stripe.Subscription, deleted: boolean): Promise<Response> {
  const row = rowFromSubscription(sub, priceEnv);
  if (!row) {
    console.log('subscription has a price that maps to no tier', sub.id);
    return reply(200, 'ignored: unknown price');
  }
  if (deleted) row.status = 'canceled';
  const updatedAt = new Date().toISOString();

  const existing = await supabase.from('subscriptions').select('id').eq('id', row.id).maybeSingle();
  if (existing.error) throw existing.error;

  if (existing.data) {
    const { error } = await supabase
      .from('subscriptions')
      .update({ ...row, updated_at: updatedAt })
      .eq('id', row.id);
    if (error) throw error;
    return reply(200, 'ok');
  }

  // No row yet: find the player from another subscription of the same customer.
  if (!row.stripe_customer_id) {
    console.log('subscription event for an unknown subscription with no customer', row.id);
    return reply(200, 'ignored: unknown subscription');
  }
  const owner = await supabase
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

  const { error } = await supabase
    .from('subscriptions')
    .upsert({ ...row, user_id: owner.data.user_id, updated_at: updatedAt }, { onConflict: 'id' });
  if (error) throw error;
  return reply(200, 'ok');
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return reply(405, 'Method not allowed');

  const body = await req.text();
  const signature = req.headers.get('stripe-signature');
  if (!signature) return reply(400, 'Missing stripe-signature');

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature, webhookSecret, undefined, cryptoProvider);
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
        return await handleSubscriptionEvent(event.data.object as Stripe.Subscription, false);
      case 'customer.subscription.deleted':
        return await handleSubscriptionEvent(event.data.object as Stripe.Subscription, true);
      default:
        return reply(200, 'ignored');
    }
  } catch (err) {
    // A 500 makes Stripe retry the event later.
    console.error('failed to handle', event.type, event.id, err);
    return reply(500, 'Internal error');
  }
});
