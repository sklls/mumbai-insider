# Mumbai Insider

A Mumbai-native experiences marketplace — hotels + activities + concerts + food + heritage + nightlife, mobile-first.

## What's in this repo

| Path | What it is |
|---|---|
| `public/index.html` | **Interactive customer-journey prototype** — 15 screens, scroll-driven narrative, dark "Basalt" theme. Every button, picker, tab, stepper, star, tag and toggle is live. Deploys straight to Vercel as a static site. |
| `supabase/migrations/` | The full applied schema (18 tables, RLS, atomic booking RPC, seed data). |
| `SUPABASE_BACKEND_PLAN.md` | End-to-end backend blueprint — schema, RLS, 10 edge functions, cron, Realtime, edge-fn code snippets, security checklist, 8-week execution roadmap. |
| `vercel.json` | Static deploy config (security headers, `outputDirectory: public`, no build). |
| `.env.local.example` | Env-var template — Supabase URL, anon key, Razorpay, WhatsApp, etc. |
| `mumbai-app-blueprint.html` | Research deck: 12 core screens, checkout flow, conversion levers, retention, India-specific features, competitor map. |
| `mumbai-supply-gtm-strategy.html` | Research deck: supply strategy, GTM channels, Gen Z data, SEO keywords, 90-day launch plan. |
| `ux-ui-ai-agent-playbook.html` | Research deck: e-commerce UX/UI best practices, friction-elimination framework. |

## Live Supabase project

The backend schema is already **applied and seeded** on:

```
Project    : trial  (rwcgtxmpokzfplgnlwye)
Region     : ap-south-1 (Mumbai)
URL        : https://rwcgtxmpokzfplgnlwye.supabase.co
Anon key   : sb_publishable_H_V75-uE8h8AXkb1Zm124w_v6klpmEz
```

Current state: 18 tables (all RLS-enabled), 10 sample listings, 6 real Mumbai operators, 10 neighbourhoods, 52 availability slots, 4 feature flags, 1 sample digest edition. Extensions installed: `pgcrypto`, `pgvector` (for AI recs), `pg_trgm` — all in the `extensions` schema (not `public`).

To connect from a frontend:
```ts
import { createClient } from '@supabase/supabase-js';
const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
);
```

## Deploy the prototype (static, ~1 minute)

### Option A — Vercel (recommended)
1. Push this repo to GitHub (already done: [github.com/sklls/mumbai-insider](https://github.com/sklls/mumbai-insider)).
2. Go to https://vercel.com/new → import the repo.
3. Framework preset: **Other**. Output directory: `public`. No build command.
4. Deploy. Live at `https://<project>.vercel.app`.

### Option B — Vercel CLI
```bash
npm i -g vercel
vercel deploy public --prod
```

## What's in the prototype

Scroll top → bottom to walk the full customer journey. The phone advances with you. Everything is clickable:

1. **First open** — onboarding, permission priming
2. **Discover** — Home with live "Happening now" feed
3. **Evaluate** — listing detail with sticky book bar, tabs, save-to-wishlist heart
4. **Book** — three-tap date/time selection with live-updating totals
5. **Confirmed** — UPI checkout, QR ticket
6. **Anticipate** — pre-trip reminder push, weather, checklist, meeting-point map
7. **Experience** — in-trip live guide, stop-by-stop
8. **Reflect** — post-trip review with star rating + tag cloud + photo prompt
9. **Return** — weekend digest push, curated picks

Push-notification banners drop in at the right story beats.

## Local preview

```bash
npm run dev              # opens http://localhost:3000
```

## Backend plan

The full backend blueprint is in [`SUPABASE_BACKEND_PLAN.md`](./SUPABASE_BACKEND_PLAN.md). The schema portion is now live — the next steps documented there are the ten Edge Functions (Razorpay webhook, WhatsApp notify, digest generator, pre-trip reminders, embeddings refresh, QR verify, cancel) and the Next.js frontend structure.
