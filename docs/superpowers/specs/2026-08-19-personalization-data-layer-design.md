# Personalization Data Layer — Design

Status: approved (design phase) · Date: 2026-08-19

## Context: the larger roadmap

Sub-project 2 of 6 (see
`2026-08-19-mood-first-ai-concierge-design.md` for the full list and the
9-stage user journey — First Open → Discover → Evaluate → Book → Confirmed
→ Anticipate → Experience → Reflect → Return — this design maps onto). This
layer is the shared foundation sub-project 1 (concierge), sub-project 3
(notifications), and the Home feed all read from.

## Purpose

Give the app a single, coherent memory of what each user actually wants —
combining what they explicitly tell the concierge, what they explicitly
rate/tag after a trip, and what they implicitly do (view/save/book) — and
make that memory power ranking wherever it matters, without becoming a
creepy black box.

## Success criteria

- A returning user's Home feed and search results are visibly better
  matched to them than a first-time visitor's, without any explicit setup.
- The Friday weekly digest (`generate_digest`, already scoped in
  `SUPABASE_BACKEND_PLAN.md`) sends genuinely different picks to different
  users, not one per-neighbourhood blast.
- A user with zero signal history (new signup) gets identical behavior to
  today's app — personalization only ever adds, never breaks, the baseline
  experience.
- Explicit signals (concierge vibe, post-trip review tags/rating) outweigh
  passive ones (views/saves) in a way that's inspectable in the data, not
  just asserted.

## Non-goals

- A user-facing "why am I seeing this" / full activity log UI (deferred;
  only the concierge's explicit vibe stays user-visible/editable, per
  sub-project 1's design).
- Cross-user/collaborative-filtering recommendations ("people like you
  also booked...") — this is single-user signal aggregation only.
- Real-time/streaming personalization — on-read aggregation at request
  time is fresh enough; no event-streaming infrastructure needed.

## Architecture

A new append-only `user_signals` table logs every meaningful action:
`view`, `save`, `book`, `review`, and the concierge's `vibe_update`. Rather
than a nightly batch/precompute job, affinity is computed **on-read** via a
Postgres function `get_user_affinity(user_id)` that aggregates recent
signals (last 90 days, row-capped) into per-category and per-neighbourhood
scores — always fresh, no staleness window, no new cron to maintain.

This function has two consumers:
1. **Home feed / search ranking** (client-triggered, live) — extends the
   existing `search_listings` RPC to optionally blend in affinity when a
   `user_id` is present.
2. **`generate_digest` cron** (already scoped, Friday 6 AM IST) — now calls
   `get_user_affinity` per subscriber before building that user's
   `digest_editions` row, so the weekly push is genuinely personal.

## Components

- `user_signals` table (new): `{id, user_id, listing_id, signal_type,
  category_slug, neighbourhood, weight, created_at}`.
- Lightweight fire-and-forget insert calls at existing action points:
  viewing a listing, saving, completing a booking, submitting a review
  (stage 8), and the concierge's `update_user_vibe` tool call (sub-project
  1) also writes here in addition to `profiles.vibe`.
- `get_user_affinity(user_id)` SQL function (new) — the single source of
  truth every consumer reads from. Two-tier weighting inside:
  - **Explicit tier** (high weight): `vibe_update`, `review` (weighted
    further by the review's star rating).
  - **Passive tier** (low weight): `view`, `save`, `book` without a
    review attached.
- `search_listings` RPC (existing, extended): accepts an optional
  `user_id` param; when present, blends `get_user_affinity` scores into
  ranking rather than pure recency/rating/featured.
- `generate_digest` Edge Function (existing, extended): loops subscribers,
  calls `get_user_affinity` per user, selects picks accordingly instead of
  one shared per-neighbourhood digest.

## Data flow

1. User views/saves/books/reviews a listing, or the concierge learns their
   vibe → a row is written to `user_signals` (or `profiles.vibe` for the
   concierge case, per sub-project 1).
2. Next Home load or search: `search_listings(user_id=...)` runs
   `get_user_affinity` inline (cheap aggregate query, no precomputation
   lag) and reorders results.
3. Friday 6 AM: `generate_digest` iterates subscribers, calls
   `get_user_affinity` for each, and writes personalized
   `digest_editions` rows before fan-out.

## Error handling

- **Signal-logging failures**: fire-and-forget, never block the underlying
  user action (a failed "log this view" call doesn't prevent the view from
  rendering).
- **`get_user_affinity` errors or empty history**: callers fall back to
  today's non-personalized ordering — personalization degrades gracefully,
  never breaks the baseline.
- **Digest generation**: if affinity lookup fails for one subscriber, that
  subscriber falls back to the original per-neighbourhood digest content
  rather than the whole cron run failing.

## Testing

- Seed a fake signal history for a test user; assert `get_user_affinity`
  returns the expected top categories, with explicit-tier signals
  (review/vibe) outweighing passive ones in the aggregate.
- Assert Home/search ordering changes accordingly for that user.
- Regression guard: a zero-signal (new) user must get output identical to
  today's baseline ordering.
- Assert digest generation produces different `digest_editions` content
  for two subscribers with different signal histories.

## Open items for later sub-projects

- Whether/when to expose a user-facing personalization control surface
  beyond the concierge's editable vibe — likely paired with sub-project 3
  (Calm notification & CTA policy), since both are about user trust and
  control.
