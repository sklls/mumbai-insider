# Dev Log

A running record of notable problems hit while building Mumbai Insider and how they were fixed. Newest first.

---

## 4. AI chat gave a flat "I don't have that information" instead of a useful answer

**Commit:** [`154b5e2`](https://github.com/sklls/mumbai-insider/commit/154b5e2) — Replace generic chat fallback with scenario-specific replies

**Problem:** Once the assistant was grounded in real data (see #2 and #1 below), it still deflected with a generic "I don't have that information" whenever a question fell outside what it had — instead of giving the most useful answer available for that specific situation (e.g. suggesting alternatives, or explaining *why* it can't help).

**Fix:** Replaced the single catch-all instruction with explicit per-scenario guidance in the system prompt, plus a new `HOW MUMBAI INSIDER WORKS` context block (real facts: booking flow, per-listing cancellation windows, loyalty tier thresholds, guest-mode rules):

- Activity not in the catalog → say so, then suggest 2–3 real alternatives from the catalog.
- Personal question while signed out → explain sign-in is needed, offer to help find something to book meanwhile.
- Signed in but nothing there yet (no bookings/collections) → say so plainly and suggest a next step.
- "How does X work" (cancellation, payment, loyalty, booking) → answer from the new `HOW MUMBAI INSIDER WORKS` block instead of guessing.
- Fully unrelated questions (e.g. "write me Python code") → politely redirect to what the assistant can actually help with.

**Verified:** On a preview deploy — asking about a restaurant not on the app returned real alternative listings, asking about cancellation policy cited the actual per-listing window, and an off-topic coding request got a friendly redirect (no more bare "I don't know").

---

## 3. AI chat answered from general knowledge instead of the app's real listings

**Commit:** [`227b47a`](https://github.com/sklls/mumbai-insider/commit/227b47a) — Ground AI chat answers in the real listings catalog

**Problem:** The assistant's context only included the signed-in user's account data (profile, bookings, collections) — nothing about what's actually bookable on the app. So when asked "what food tours do you have?" it fell back to the LLM's own general knowledge of Mumbai instead of the app's real 45-listing catalog.

**Fix:** Added a `buildCatalogContext()` function to `api/chat.js` that fetches all active listings and categories directly from Supabase (public data, no auth needed) and instructs the model to only recommend/describe/price items from that list — never its own knowledge of Mumbai.

**Verified:** On a preview deploy — "recommend a food tour" returned a real listing ("Mohammad Ali Road Night Food Walk") with its actual price and rating; asking to book a table at a restaurant *not* on the app ("Trishna") was correctly declined with real alternatives offered instead of an invented booking.

---

## 2. Added an AI chat assistant, without leaking the API key or other users' data

**Commit:** [`3c11a41`](https://github.com/sklls/mumbai-insider/commit/3c11a41) — Add AI chat assistant with account-scoped context

**Ask:** A chat icon in the bottom nav (between Search and Trips, accessible from any screen) backed by an NVIDIA NIM (Llama 3.1 70B) API key, able to answer questions about the user's own account data.

**Problem 1 — the app is a single static `public/index.html` with no build step**, so a client-side API key would be visible to anyone viewing page source, and `NEXT_PUBLIC_*`-style env vars can't be injected into static HTML at deploy time.
**Fix:** Added a Vercel serverless function (`api/chat.js`) that calls NVIDIA's API using `NVIDIA_API_KEY` from `process.env` — the key never reaches the browser. Stored it in Vercel's env vars (Production + Preview as *sensitive*, so it's encrypted and non-readable after creation) via `vercel env add`, and documented it in `.env.local.example` (the real value only lives in the gitignored `.env.local`, pulled with `vercel env pull`).

**Problem 2 — how does the server function get personal data without trusting the client to only ask for its own?**
**Fix:** Rather than trusting client-supplied data, `api/chat.js` takes the caller's own Supabase access token (sent from the client) and re-queries Postgres *server-side* with that same token. Every table has Row Level Security, so the query can only ever return that one user's rows — even a tampered client can't make the endpoint fetch anyone else's bookings or profile, because the database itself enforces the boundary, not the prompt.

**Verified:** On a preview deploy — signed out, the bot correctly said it had no access to personal data; signed in as the demo admin account, it greeted the user by name and reported their real (zero) loyalty points and bookings, pulled live via RLS-scoped queries.

---

## 1. Listings and images weren't showing up on the live site

**Commit:** [`64d8c9b`](https://github.com/sklls/mumbai-insider/commit/64d8c9b) — Fix TypeError crash blocking listing images/activities from rendering

**Problem:** The homepage's "Curated for you" section was empty and no listing images rendered anywhere, despite Supabase having 10+ active listings with valid image URLs and correct public-read RLS policies. Browser console showed:
```
TypeError: Failed to execute 'addEventListener' on 'EventTarget': parameter 2 is not of type 'Object'.
  at el (index.html:598)
  at renderListingList (index.html:953)
```

**Root cause:** The app's `el()` DOM helper wires any `on*` prop through `addEventListener(name, handler)`, which requires a function. Two `<img>` elements passed `onerror` as an **inline JS string** (`"this.style.display='none';..."`) instead of a function — a pattern that works for raw HTML `onerror=""` attributes but not for `addEventListener`. The resulting `TypeError` was thrown and *uncaught* inside `renderListingList`, aborting the render before any listing card could be appended — so the whole section silently stayed empty, even though the Supabase query itself succeeded (confirmed via network tab: `200 OK`).

**Fix:** Replaced both string handlers with real arrow functions operating on `e.target`, in `public/index.html`:
```js
// before
onerror: 'this.style.display=\'none\';this.parentElement.innerHTML=\''+emojiForType(l.type)+'\';'
// after
onerror: e => { e.target.style.display = 'none'; e.target.parentElement.innerHTML = emojiForType(l.type); }
```

**Verified:** Reproduced the exact `TypeError` via a JS console snippet against the live `el()` implementation, confirmed the fix doesn't throw, then confirmed visually on the live site — listing cards, images, ratings, and prices all render correctly.
