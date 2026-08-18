# Mumbai Insider

A Mumbai-native experiences marketplace — hotels + activities + concerts + food + heritage + nightlife in one mobile-first app.

This repo contains:

| File / dir | What it is |
|---|---|
| `public/index.html` | **Interactive customer-journey prototype** — 15 screens, scroll-driven narrative, Basalt dark theme. Deploys straight to Vercel as a static site. |
| `SUPABASE_BACKEND_PLAN.md` | End-to-end backend plan: schema, RLS, edge functions, cron, Realtime, deployment sequence, security checklist, milestones. |
| `mumbai-app-blueprint.html` | Product research: 12 core screens, checkout flow, conversion levers, retention, India-specific features, competitor map. |
| `mumbai-supply-gtm-strategy.html` | Supply strategy, GTM channels, Gen Z data, SEO keywords, 90-day launch plan. |
| `ux-ui-ai-agent-playbook.html` | E-commerce UX/UI best practices, friction-elimination framework, AI concierge design + integration. |
| `vercel.json` | Vercel deployment config (static, security headers). |

## Deploy the prototype (static, ~1 minute)

### Option A — Vercel (recommended)
1. Push this repo to GitHub (see below).
2. Go to https://vercel.com/new → import the repo.
3. Framework preset: **Other**. Output directory: `public`. No build command.
4. Deploy. Your prototype is live at `https://<project>.vercel.app`.

### Option B — Vercel CLI
```bash
npm i -g vercel
vercel deploy public --prod
```

## Local preview

```bash
npm run dev
# opens http://localhost:3000
```

## What's in the prototype

Scroll top → bottom to walk the full customer journey. The phone advances with you.

1. **First open** — onboarding, permission priming
2. **Discover** — Home with live "Happening now" feed
3. **Evaluate** — listing detail with sticky book bar
4. **Book** — three-tap date/time selection
5. **Confirmed** — UPI checkout, QR ticket
6. **Anticipate** — pre-trip reminder push, weather, checklist, meeting-point map
7. **Experience** — in-trip live guide, stop-by-stop
8. **Reflect** — post-trip review with tag cloud + photo prompt
9. **Return** — weekend digest push, curated picks
10. **AI concierge** — chat sheet that books inline

The floating orange button opens the AI chat from any screen. Push-notification banners drop in at the anticipation and return stages.

## Backend

The full backend plan is in [`SUPABASE_BACKEND_PLAN.md`](./SUPABASE_BACKEND_PLAN.md) — Postgres schema (17 tables), row-level security, ten edge functions, cron jobs, Realtime channels, Next.js structure, env vars, and an 8-week execution roadmap.

## Later — when you upgrade to the real product

The prototype is static HTML. To become the real product, follow the plan:
- `mumbai-insider/` Next.js 14 app (App Router)
- Supabase project in `ap-south-1` (Mumbai)
- Razorpay for payments (UPI-first)
- Anthropic Claude for the AI concierge
- WhatsApp Business API for confirmations & reminders

Ship one vertical (food tours) end-to-end before adding surface area.
