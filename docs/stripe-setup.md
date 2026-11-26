# Setting up Pro and Ultimate payments

This guide takes you from nothing to a working test purchase of Pro on the site. It uses Stripe's **test mode** throughout, so no real money moves. Going live comes at the end, as a checklist for later.

Set aside about an hour. Do the parts in order: later parts need things you copy in earlier ones.

**Words used in this guide**

- **Stripe**: the company that takes the card payments and runs the subscriptions.
- **Test mode**: a practice copy of your Stripe account. Fake cards, no real money. Everything you make there stays separate from the real (live) account.
- **Supabase**: the database behind the site. You already use it for the SQL Editor.
- **Edge Function**: a small program that runs on Supabase. Ours is called `stripe-webhook`.
- **Webhook**: a message Stripe sends to that program each time something happens, such as "someone paid" or "someone cancelled". That's how the site finds out who has Pro.
- **Secret**: a password-like value that lets two systems trust each other. Secrets go into Supabase only (Part 8). Never paste one into a chat, an email, the site, admin or GitHub.

**Keep a notepad open.** You'll collect these as you go:

| What | Looks like | From |
|---|---|---|
| 4 price IDs | `price_1Q...` | Part 3 |
| 4 Payment Links | `https://buy.stripe.com/test_...` | Part 4 |
| Customer portal link | `https://billing.stripe.com/p/login/test_...` | Part 5 |
| Secret key | `sk_test_...` | Part 8 (copy it straight into Supabase, not the notepad) |
| Webhook signing secret | `whsec_...` | Part 7 (copy it straight into Supabase, not the notepad) |

The price IDs and links aren't secret. The two keys are: copy each one straight from Stripe into Supabase.

---

## Part 1: Update the database

1. Open [supabase.com/dashboard](https://supabase.com/dashboard) and pick the PitchMarket project.
2. In the left sidebar click **SQL Editor**, then **New query**.
3. In GitHub, open `supabase-pro-1.sql`, copy all of it, and paste it into the query box.
4. Click **Run**.
5. **You should see** one row at the bottom, with a `payments` column showing `"mode": "test"`, 0 subscriptions, and 0 grants (or one for each player who already had Pro or Ultimate given by hand: they keep it). Running it a second time does no harm.

## Part 2: Create a Stripe account

1. Go to [stripe.com](https://stripe.com) and click **Sign up** (or sign in if you already have an account).
2. Confirm your email when Stripe asks. You don't need to give business or bank details yet: those are only for taking real money.
3. At the top right of the Stripe dashboard, turn on **Test mode** (in newer accounts this is the **Sandbox** or **Test mode** switch next to your account name).
4. **You should see** an orange "Test mode" (or "Sandbox") banner. Keep it on for every step in this guide. If the banner disappears, switch it back on before carrying on.

## Part 3: Create the two products and four prices

A **product** is the thing being sold (Pro). A **price** is one way to pay for it (monthly or yearly). Each product gets two prices.

1. In the left sidebar click **Product catalog**, then **+ Add product** (or **Create product**).
2. Fill in:
   - **Name:** `Pro`
   - **Description** (optional): `PitchMarket Pro`
   - Choose **Recurring** (not One-off).
   - **Amount:** `1.99`, currency **USD**.
   - **Billing period:** **Monthly**.
3. Click **Add product** (or **Save product**).
4. You're now on the Pro product's page. In the **Pricing** section click **+ Add another price** (or **Add a price**).
   - **Recurring**, **Amount** `20.00` **USD**, **Billing period** **Yearly**.
   - Click **Add price** (or **Next**, then **Add price**).
5. Repeat steps 1 to 4 for a second product:
   - **Name:** `Ultimate`, monthly price `4.99` USD, yearly price `50.00` USD.
6. Copy the four **price IDs** into your notepad. On each product's page, click each price in the Pricing list; the price ID starts with `price_` and is shown at the top right of the price's page, with a copy button. Label each one, for example:
   - Pro monthly: `price_...`
   - Pro yearly: `price_...`
   - Ultimate monthly: `price_...`
   - Ultimate yearly: `price_...`

**You should see** two products in **Product catalog**, Pro and Ultimate, each with two prices.

## Part 4: Create four Payment Links

A **Payment Link** is a ready-made Stripe checkout page. The site's "Upgrade" buttons open these.

Make one link for each of the four prices:

1. In the left sidebar click **Payment Links** (if you can't see it, use the search bar at the top and type "Payment Links"). Click **+ New** (or **Create payment link**).
2. Under **Product**, choose **Pro**, then pick its **monthly** price ($1.99 / month). Leave the quantity at 1, and leave "Let customers adjust quantity" off.
3. Click the **After payment** tab (or section).
4. Choose **Don't show confirmation page** (sometimes worded "Redirect customers to your website") and enter:
   `https://pitchmarket.github.io/Pitchmarket/`
5. Click **Create link** (top right).
6. **You should see** the new link, starting `https://buy.stripe.com/test_`. Copy it into your notepad as "Pro monthly link".
7. Repeat steps 1 to 6 for Pro yearly ($20 / year), Ultimate monthly ($4.99 / month) and Ultimate yearly ($50 / year).

**Check:** you have four links, each labelled, each starting `https://buy.stripe.com/test_`.

## Part 5: Set up the customer portal and failed payments

The **customer portal** is a Stripe page where players manage their own subscription: cancel, change card, or switch between Pro and Ultimate. The site's "Manage subscription" link opens it.

1. Click the **gear icon** (Settings) at the top right, then under **Billing** click **Customer portal**. (Or search "Customer portal" in the top search bar.)
2. Under **Subscriptions**:
   - Turn on **Customers can cancel subscriptions**. Choose **Cancel at end of billing period** (the player keeps the plan until the time they've paid for runs out).
   - Turn on **Customers can switch plans**. In the product list that appears, add **Pro** and **Ultimate**, and make sure all four prices are ticked.
3. Under **Payment methods**, turn on **Customers can update payment methods**.
4. Click **Save** (or **Save changes**) at the top or bottom of the page.
5. Find the **Login link** section near the top of the same page. If there's an **Activate link** button, click it.
6. Copy the login link into your notepad. It starts `https://billing.stripe.com/p/login/test_`.

Now tell Stripe what to do when a renewal can't be paid (an expired card, say). Stripe keeps the subscription "past due" while it retries the card; the site gives a past-due player Pro or Ultimate for 3 days only, then treats them as Free until a payment goes through.

7. Click the **gear icon** (Settings), then under **Billing** click **Subscriptions and emails**. (Or search "Manage failed payments".)
8. Under **Manage failed payments**, set the retries to the shortest window offered (for example a custom schedule that retries within about 3 days, or the shortest Smart Retries period).
9. Under **If all retries for a payment fail**, choose **Cancel the subscription**.
10. Click **Save**.
11. **You should see** "Cancel the subscription" selected. A player whose card keeps failing then loses the plan for good once the retries run out, instead of staying "past due" forever. If they pay during the retries, the plan comes straight back.

## Part 6: Put the function on Supabase

This puts the `stripe-webhook` program on Supabase, ready to receive Stripe's messages.

1. In the Supabase dashboard, click **Edge Functions** in the left sidebar.
2. Click **Deploy a new function**, then **Via Editor**.
3. Set the function name to exactly `stripe-webhook` (lower case, with the dash). The name is part of the web address Stripe will use, so it must match.
4. The editor opens with one file, `index.ts`. Delete everything in it. In GitHub, open `supabase/functions/stripe-webhook/index.ts`, click the **Copy raw file** button (two overlapping squares, top right of the file), and paste it into the editor.
5. Add a second file: click **+** (or **Add file**) in the editor's file list, and name it exactly `plan.js`. In GitHub, open `supabase/functions/stripe-webhook/plan.js`, copy it the same way, and paste it in.
6. Click **Deploy function** (bottom right). Wait until it says it's deployed.
7. Open the function's **Details** (or **Settings**) tab. Find **Verify JWT** (also called **Enforce JWT verification**) and turn it **OFF**, then save.
   *Why:* with it on, Supabase only lets in visitors who are signed in to the site. Stripe isn't signed in, so its messages would be turned away. The function checks Stripe's own signature on every message instead, so turning this off is safe.
8. **Check it's there:** open this address in your browser:
   `https://ljpwxujlyqhlznasnhfk.supabase.co/functions/v1/stripe-webhook`
   **You should see** `Method not allowed`. That's correct: browsers ask for pages, and the function only accepts messages from Stripe. If you see a message about a missing authorization header or an invalid JWT instead, Verify JWT is still on (step 7).

## Part 7: Add the webhook in Stripe

This tells Stripe where to send its messages.

1. Back in Stripe (still in test mode), click **Developers** (bottom left, or top right in some accounts), then **Webhooks**.
2. Click **+ Add endpoint** (newer accounts: **+ Add destination**).
3. If asked, choose events from **Your account**, and **Webhook endpoint** as the destination type.
4. **Endpoint URL:**
   `https://ljpwxujlyqhlznasnhfk.supabase.co/functions/v1/stripe-webhook`
5. Under **Select events** (or **Events to send**), search for and tick exactly these four:
   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
6. Click **Add endpoint** (or **Create destination**).
7. On the endpoint's page, find **Signing secret** and click **Reveal**. It starts `whsec_`. Leave this tab open: you'll copy it in Part 8.

## Part 8: Give the function its six secrets

The function needs Stripe's secret key (to look up subscriptions), the signing secret (to know a message really came from Stripe), and the four price IDs (to know which price is Pro and which is Ultimate).

1. In the Supabase dashboard, go to **Edge Functions**, then **Secrets** (or **Project Settings → Edge Functions**).
2. Add each secret below: type the **Name** exactly as shown (capitals and underscores), paste the **Value**, and click **Add** (or **Save**). You can add several before saving.

| Name | Value | Where to find it |
|---|---|---|
| `STRIPE_SECRET_KEY` | `sk_test_...` | Stripe → **Developers → API keys** → **Secret key** → **Reveal test key**. Copy it straight into Supabase. |
| `STRIPE_WEBHOOK_SECRET` | `whsec_...` | The signing secret from Part 7, step 7. |
| `STRIPE_PRICE_PRO_MONTHLY` | `price_...` | Notepad: Pro monthly price ID |
| `STRIPE_PRICE_PRO_YEARLY` | `price_...` | Notepad: Pro yearly price ID |
| `STRIPE_PRICE_ULTIMATE_MONTHLY` | `price_...` | Notepad: Ultimate monthly price ID |
| `STRIPE_PRICE_ULTIMATE_YEARLY` | `price_...` | Notepad: Ultimate yearly price ID |

3. **You should see** all six names in the secrets list (Supabase hides the values). You may also see `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` and others already there: Supabase adds those itself. Leave them alone.

Use the price IDs (`price_...`) here, not the product IDs (`prod_...`) and not the Payment Links.

**Optional check:** in Stripe, on the webhook's page, click **Send test event** (or **Test**), pick `customer.subscription.updated` and send it. A reply of `200` means the function is reached and set up. A reply of `500` saying "Webhook not configured: missing ..." names a secret you haven't added yet (check the spelling of its name). A `400` saying "Bad signature" means `STRIPE_WEBHOOK_SECRET` doesn't match this endpoint's signing secret. This check can't tell whether the four price IDs are right; Part 10 does.

## Part 9: Paste the links into admin

1. Open the admin page, `https://pitchmarket.github.io/Pitchmarket/admin.html`, and sign in as admin.
2. Click the **Plans & Payments** tab.
3. Under **Payments**, choose **Test**.
4. Paste each Payment Link into its box: **Pro monthly link**, **Pro yearly link**, **Ultimate monthly link**, **Ultimate yearly link**.
5. Paste the customer portal login link into **Customer portal link**.
6. Click **Save**.
7. **You should see** "Saved ✓ — live now." next to the button. If a box turns red, the link in it isn't a full web address: copy it again from Stripe.

## Part 10: Make a test purchase

Use a test player account, not the admin account.

1. Open the site, `https://pitchmarket.github.io/Pitchmarket/`, and sign in as your test player.
2. Click **Go Pro** in the top menu.
3. **You should see** the plan cards with **Upgrade to ...** buttons, and a note giving the test card number.
4. Click **Upgrade to Pro** on the $1.99 / month card. Stripe's checkout opens in a new tab with your email already filled in.
5. Pay with:
   - Card number: `4242 4242 4242 4242`
   - Expiry: any future date, such as `12 / 34`
   - CVC: any three digits, such as `123`
   - Name and postcode: anything
6. Click **Subscribe**. Stripe takes you back to the site.
7. **You should see**, within a few seconds, the Pro card marked **Your plan**, and a **Manage subscription** link. If it still shows Upgrade, refresh the page once.
8. In admin, **Plans & Payments** tab, click **↻ Refresh**. **You should see** the test player in **Players with a plan or grant**, with plan Pro and the source shown as a subscription.
9. Back on the site, click **Manage subscription**. Stripe's portal opens and asks for the player's email, then emails a sign-in link. (If it never arrives, use your own email address for the test player next time: in test mode Stripe may only send emails to addresses on your own Stripe account. You can still cancel from Stripe: **Customers**, click the test player, click the subscription, **Cancel subscription**.)
10. Click **Cancel plan** (or **Cancel subscription**) and confirm.
11. **You should see** the site keep Pro until the end of the month that was "paid for", then switch back to Free. (If you choose to cancel straight away in the portal, Pro switches off within seconds.)

If step 7 never happens: in Stripe, open **Developers → Webhooks**, click the endpoint, and look at the latest events. A red failed event shows the function's reply, which says what's wrong. A missing secret or a typo in a secret's name is the usual cause.

## Giving a plan for free

For prize winners, testers and friends: admin → **Plans & Payments** → **Give a plan**. Enter the player's email, pick Pro or Ultimate, optionally an end date and a note, and click **Give plan**. **Revoke** next to a player takes a given plan away. A paid subscription is never touched by either.

## Going live (later)

Don't do this until the first two items are done. Test purchases stop counting automatically once admin is set to Live, so test players lose their test Pro at that moment.

1. **Legal pages on the site:** terms of service, privacy policy, and a refund policy.
2. **Activate your Stripe account:** turn test mode off and follow Stripe's **Activate payments** steps (business details, bank account for payouts).
3. **In live mode, recreate** everything from Parts 3 to 5 and 7: the two products and four prices, the four Payment Links, the customer portal settings and its login link, the failed-payments settings (Part 5, steps 7 to 10: **Settings → Billing → Subscriptions and emails → Manage failed payments**, a short retry window, and **If all retries for a payment fail**: **Cancel the subscription**), and the webhook endpoint (same URL, same four events). Live items start `price_...`, `https://buy.stripe.com/...` (no `test_`), `https://billing.stripe.com/p/login/...` and `whsec_...`.
4. **Replace all six secrets** in Supabase (Part 8) with the live values: the live secret key `sk_live_...`, the live webhook's signing secret, and the four live price IDs. To replace one, edit it or delete it and add it again with the same name.
5. **Delete or disable the test-mode webhook endpoint.** Switch Stripe back to test mode, open **Developers → Webhooks**, click the endpoint, and choose **Delete** (or **Disable**). It points at the same function, which now only has the live signing secret, so its messages would all fail.
6. **In admin**, paste the four live Payment Links and the live portal link over the test ones, choose **Live**, and click **Save**.
7. **Check:** buy Pro monthly with a real card, see it switch on, then cancel and refund yourself from Stripe (**Payments**, click the payment, **Refund**).

The function itself doesn't change: there's nothing to redeploy for live.
