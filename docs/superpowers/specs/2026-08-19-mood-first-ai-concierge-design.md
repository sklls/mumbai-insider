# Mood-First AI Concierge — Design

Status: approved (design phase) · Date: 2026-08-19

## Context: the larger roadmap

This is sub-project 1 of a 6-part plan to make Mumbai Insider's experience feel
differentiated (personalization, seamless online-to-physical handoff,
non-pushy engagement) rather than just another booking grid. The full
decomposition, for reference when the later sub-projects are designed:

1. **Mood-first AI Concierge** *(this document)*
2. **Personalization data layer** — signals, storage, reuse across surfaces
3. **Calm notification & CTA policy** — frequency-capped, behavior-triggered
   notifications/nudges across the app (builds on the existing `notifications`
   table and WhatsApp/digest/reminder crons already scoped in
   `SUPABASE_BACKEND_PLAN.md`)
4. **Geofencing / location-aware layer** — net-new; nothing currently planned
5. **Online-to-offline (O2O) bridge** — QR check-in, day-of digital concierge,
   post-visit loop
6. **Cross-platform connectivity** — WhatsApp as first-class channel, web/app
   parity, sharing

Each sub-project gets its own design → spec → plan → build cycle. This
document covers only #1.

## Purpose

Turn the existing (currently generic, search-oriented) `ai_concierge` Edge
Function — already named in `SUPABASE_BACKEND_PLAN.md` §5.3 — into the app's
signature differentiator: a short, warm, mood-first conversation that ends in
2-3 genuinely well-matched, bookable picks. It exists alongside (not instead
of) the static mood/who chips already on Home; it's for the person who wants
a bit of guidance rather than to browse a filtered grid themselves.

## Success criteria

- A user can go from opening the concierge to a bookable recommendation in
  2-3 conversational turns.
- Every recommendation shown is confirmed-available inventory at the moment
  it's shown — never a hallucinated or stale listing.
- The conversation reads as calm and helpful, not as a sales funnel — judged
  by manual read of golden-conversation transcripts (see Testing), since tone
  isn't something automated assertions can fully verify.
- What the concierge learns (mood, who, budget hint) visibly and editably
  carries into the user's profile and influences later sessions.

## Non-goals (for this sub-project)

- Open-ended, unbounded chat (explicitly scoped out in favor of a capped
  2-3 turn exchange).
- Geofencing, push notifications, or any physical/in-venue behavior — those
  are sub-projects #4 and #5.
- Redesigning the existing mood/who chips on Home — they stay as-is; the
  concierge is a separate, opt-in entry point.
- A new booking mechanism — "Book" on a recommendation card hands off to the
  existing `create_booking` flow already used elsewhere in the app.

## Architecture

The concierge is a new chat surface (bottom-sheet or full-screen) layered
onto the existing static frontend (`public/index.html`'s app shell),
backed by the `ai_concierge` Supabase Edge Function. Each user turn —
chip tap or typed text — triggers one call to that function.

The function calls the Anthropic Messages API with three tool definitions:
`search_listings` and `get_availability` (already planned — every
recommendation stays grounded in real inventory, never hallucinated), plus a
new `update_user_vibe` tool the model invokes once it has learned something
worth remembering. It returns a small structured JSON payload — not raw
prose — so the frontend can reliably render: the bot's message text, up to 5
suggestion chips for the next answer, and (on the final turn) 2-3
recommendation cards with inline "Book" buttons.

Conversation state lives client-side for the session (the array of messages
so far, resent with each call) — no new message-history table, keeping the
function stateless. Only the *outcome* — the vibe the model learned — is
persisted server-side, via the `update_user_vibe` tool call, into a small
`profiles.vibe` jsonb column that a "your vibe" section in the user's
profile reads and lets them edit or clear.

## Components

**Frontend (new)**
- Entry point: a persistent but unobtrusive "Ask the concierge" affordance
  (FAB or Home card), distinct from the existing mood/who chips.
- Chat surface: message bubbles (bot + user), a chip row rendered from the
  function's suggested-chips output, and a text input always available
  alongside the chips.
- Recommendation card component, aligned with existing listing cards, with
  an inline "Book" CTA.
- "Your vibe" profile section: shows the current stored vibe in plain
  language (e.g. "Chill solo evenings, ~₹1500 budget"), with edit and clear
  actions.

**Backend (new/extended)**
- `ai_concierge` Edge Function (Deno) — takes `{messages: [...]}`, calls the
  Anthropic Messages API with a system prompt fixing persona (warm, calm,
  never pushy, max 2-3 turns before recommending, off-topic redirect) and
  the three tools below, returns
  `{reply_text, suggested_chips[], recommendations[]?}`.
- Tool `search_listings` *(already planned)* — semantic + filtered search
  over `listings` using pgvector.
- Tool `get_availability` *(already planned)* — confirms real slots before a
  listing is ever shown as a pick.
- Tool `update_user_vibe` *(new)* — writes `{mood, who, budget_hint}` to a
  new `profiles.vibe jsonb` column (single row per user; no new table for
  v1 — a history table can be added later without breaking this design).

## Data flow

1. User taps "Ask the concierge." Frontend sends `{messages: []}`. Model
   opens with e.g. *"What's the mood right now?"* plus chips (`Chill`,
   `Adventurous`, `Romantic`, `Something new`, `Not sure`); text field shown
   alongside.
2. User taps a chip or types free text — either way it's appended to
   `messages` as a normal user turn, so chip taps and free text are
   indistinguishable to the model. Frontend resends the full array.
3. Model asks one targeted follow-up (e.g. who's with you + how much time),
   capped by the system prompt at one more question before it must
   recommend.
4. User answers (chip or text) → sent as the next turn.
5. Model calls `search_listings`, then `get_availability` on top
   candidates, picks 2-3, and calls `update_user_vibe` to persist what it
   learned.
6. Function returns `{reply_text, recommendations: [...]}` — no more chips,
   since the conversation has reached its outcome. Frontend renders the
   cards with inline "Book" buttons.
7. Tapping "Book" hands off to the existing `create_booking` flow — no new
   booking mechanism.

## Error handling

- **LLM/API failure or timeout:** calm fallback message ("Having trouble
  right now — browse by mood instead") linking back to the existing
  chip-filtered Home view. Never a silent hang or raw error.
- **No matching inventory:** system prompt directs the model to relax one
  constraint at a time (budget before mood) and say so honestly, rather
  than dead-ending.
- **Availability changes mid-conversation:** if `get_availability` shows a
  candidate isn't actually bookable, the model silently substitutes the
  next-best result.
- **Off-topic input:** system prompt keeps the model scoped to
  mood/recommendation; unrelated requests get a gentle redirect.
- **Turn/cost cap:** hard cap (e.g. 4 model turns) enforced server-side
  regardless of what the model "wants" to ask.
- **Vibe write failure:** `update_user_vibe` is best-effort and decoupled
  from delivering recommendations — a failed profile write never blocks or
  delays showing the user's picks; it's logged, not surfaced as an error.

## Testing

No existing test suite in this project (static HTML/JS + Supabase, no build
step), so this stays pragmatic rather than adding heavy tooling:

- **Golden conversation script:** a fixed set of scripted exchanges
  (chip-only, free-text-only, mixed) with expected outcomes — e.g.
  `mood=romantic + who=couple` → recommendations must carry `date_night` in
  `mood_tags`. Run manually against the deployed function before each
  change ships; this is the primary acceptance check.
- **Grounding assertion (automatable):** every `id` in a returned
  `recommendations[]` must exist in `listings` and have passed
  `get_availability` — a small script replays the golden conversations and
  checks this against the live DB, catching hallucination regressions
  cheaply.
- **Turn-cap test:** force a conversation past the cap, confirm the
  function still terminates with a recommendation rather than looping.
- **Failure-path checks:** simulate an Anthropic API error and a
  zero-result search, confirm the Error Handling fallbacks actually fire.
- **Manual UX pass in-browser:** the "not pushy" goal is subjective and
  needs a human read of actual transcripts, not just automated assertions.

## Open items for later sub-projects (explicitly out of scope here)

- How `profiles.vibe` feeds the home feed ordering and the weekly digest —
  sub-project #2 (Personalization data layer).
- Whether/how the concierge should ever be *proactively* surfaced (e.g. a
  gentle prompt after browsing indecisively) — governed by sub-project #3
  (Calm notification & CTA policy), not this one.
