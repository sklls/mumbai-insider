# Mumbai Insider — Supabase Backend Plan (Vercel-deployable)

Extremely detailed plan for the full backend on **Supabase** (Postgres + Auth + Storage + Edge Functions + Realtime), with a **Next.js 14 (App Router)** frontend hosted on **Vercel** that calls it. Written so an engineer (or future-you) can execute step by step.

---

## 0. Architecture at a glance

```
┌────────────────────────────────────────────────────────────────┐
│  Vercel (Next.js 14, App Router, edge + node runtimes)         │
│    – /app/(marketing)  → landing, static prototype             │
│    – /app/(app)        → the app UI (Home, Search, Listing…)   │
│    – /app/api/*        → BFF routes calling Supabase           │
│    – Client uses @supabase/ssr for auth cookies                │
└────────────┬───────────────────────────────────────────────────┘
             │  HTTPS (anon + service-role keys via env)
             ▼
┌────────────────────────────────────────────────────────────────┐
│  Supabase project (region: ap-south-1 · Mumbai)                │
│    – Postgres 15 (RLS on every table)                          │
│    – Auth (email OTP + Google + phone OTP)                     │
│    – Storage (bucket: images/, receipts/)                      │
│    – Realtime (channels: bookings, live_trip)                  │
│    – Edge Functions (checkout, webhook_razorpay,               │
│      abandoned_cart, notify_whatsapp, ai_concierge)            │
│    – Cron (pg_cron): reminders, digest, cleanup                │
│    – Vector: pgvector on listings.embedding for AI search      │
└────────────┬───────────────────────────────────────────────────┘
             │
             ├─▶ Razorpay (payments, webhooks)
             ├─▶ WhatsApp Business API (via Gupshup or Meta Cloud API)
             ├─▶ Anthropic Claude API (AI concierge, tool-use)
             ├─▶ Google Maps Platform (geocoding, distance)
             └─▶ Resend (transactional email)
```

**Why this stack**
- Supabase gives you Postgres + Auth + Storage + Realtime + Edge Functions in one project — no separate services to wire.
- ap-south-1 (Mumbai) region keeps latency <50 ms for Indian users.
- Vercel auto-connects to Supabase via its official integration → env vars injected automatically.
- Edge Functions run Deno, deploy independently of the Next.js app, so payment webhooks and AI calls don't tie up the app.

---

## 1. Prerequisites (one-time, ~30 min)

1. **Supabase**: create project at https://supabase.com/dashboard/new
   - Region: **South Asia (Mumbai)** · `ap-south-1`
   - Save: `PROJECT_URL`, `ANON_KEY`, `SERVICE_ROLE_KEY`, DB password
2. **Vercel**: create account, install Vercel CLI: `npm i -g vercel`
3. **Supabase CLI**: `npm i -g supabase` — for migrations
4. **Razorpay**: dashboard → API keys → save `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`
5. **WhatsApp**: Gupshup partner signup (fastest) → save `GUPSHUP_API_KEY`, `GUPSHUP_SOURCE_NUMBER`
6. **Claude API**: https://console.anthropic.com → save `ANTHROPIC_API_KEY`
7. **Resend**: https://resend.com → save `RESEND_API_KEY`
8. **Google Maps**: enable Places + Distance Matrix, save `GOOGLE_MAPS_API_KEY`

---

## 2. Database schema (17 tables)

### 2.1 Enums

```sql
create type user_role       as enum ('customer','operator','admin');
create type booking_status  as enum ('pending','confirmed','completed','cancelled','refunded','no_show');
create type payment_status  as enum ('created','authorized','captured','failed','refunded');
create type listing_type    as enum ('activity','event','hotel','bundle','food_tour','heritage_walk');
create type notif_channel   as enum ('push','whatsapp','email','in_app');
create type loyalty_tier    as enum ('explorer','insider','legend');
create type collection_visibility as enum ('private','shared','public');
```

### 2.2 Core tables

```sql
-- 1. profiles: extends auth.users
create table profiles (
  id uuid primary key references auth.users on delete cascade,
  full_name text,
  phone text unique,
  avatar_url text,
  role user_role not null default 'customer',
  language text default 'en',            -- 'en' | 'hi' | 'mr'
  home_neighbourhood text,               -- 'Bandra West'
  loyalty_points int not null default 0,
  loyalty_tier loyalty_tier not null default 'explorer',
  referral_code text unique,
  referred_by uuid references profiles(id),
  onboarding_complete boolean default false,
  created_at timestamptz default now()
);
create index on profiles(referral_code);

-- 2. operators: businesses running experiences
create table operators (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text unique not null,
  owner_id uuid references profiles(id),
  bio text,
  logo_url text,
  whatsapp_number text,
  response_minutes int default 30,
  rating numeric(3,2) default 0,
  rating_count int default 0,
  commission_pct numeric(5,2) default 18.00,
  verified boolean default false,
  created_at timestamptz default now()
);

-- 3. listings: bookable experiences
create table listings (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references operators(id) on delete cascade,
  slug text unique not null,
  type listing_type not null,
  title text not null,
  subtitle text,
  description text,
  neighbourhood text,                    -- 'Colaba', 'Bandra West'
  meeting_point text,
  meeting_lat numeric(9,6),
  meeting_lng numeric(9,6),
  duration_minutes int,
  max_group_size int,
  min_group_size int default 1,
  languages text[] default array['en'],
  base_price_paise int not null,         -- price in paise (₹1200 = 120000)
  taxes_pct numeric(5,2) default 5.00,
  cancellation_hours int default 24,
  what_included text[],
  what_to_bring text[],
  cover_image text,
  gallery text[],
  active boolean default true,
  featured boolean default false,
  editors_pick boolean default false,
  rating numeric(3,2) default 0,
  rating_count int default 0,
  booking_count int default 0,
  embedding vector(1536),                -- pgvector for AI concierge search
  search_tsv tsvector generated always as (
    to_tsvector('english', coalesce(title,'') || ' ' || coalesce(description,'') || ' ' || coalesce(neighbourhood,''))
  ) stored,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index on listings using gin(search_tsv);
create index on listings using ivfflat (embedding vector_cosine_ops) with (lists = 100);
create index on listings(type, active, featured);
create index on listings(neighbourhood);

-- 4. availability: slots
create table availability (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references listings(id) on delete cascade,
  starts_at timestamptz not null,        -- Sat 16 Aug 7:00 PM IST
  duration_minutes int,
  capacity int not null,
  booked int not null default 0,
  price_paise_override int,              -- allow surge/discount per slot
  active boolean default true,
  unique(listing_id, starts_at)
);
create index on availability(listing_id, starts_at);
create index on availability(starts_at) where active;

-- 5. bookings: transactions
create table bookings (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,             -- 'MI7241' — human-readable
  user_id uuid not null references profiles(id),
  listing_id uuid not null references listings(id),
  availability_id uuid references availability(id),
  operator_id uuid not null references operators(id),
  guests int not null default 1,
  base_total_paise int not null,
  taxes_paise int not null,
  discount_paise int not null default 0,
  points_earned int not null default 0,
  points_redeemed int not null default 0,
  total_paise int not null,
  currency text default 'INR',
  status booking_status not null default 'pending',
  payment_status payment_status default 'created',
  razorpay_order_id text,
  razorpay_payment_id text,
  qr_token text unique,                  -- signed token for scan
  meeting_point_snapshot text,
  starts_at timestamptz,
  cancellation_deadline timestamptz,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now(),
  confirmed_at timestamptz,
  cancelled_at timestamptz
);
create index on bookings(user_id, created_at desc);
create index on bookings(operator_id, starts_at);
create index on bookings(status);
create unique index on bookings(razorpay_payment_id) where razorpay_payment_id is not null;

-- 6. payments: full audit trail (bookings gets latest)
create table payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid references bookings(id) on delete cascade,
  provider text default 'razorpay',
  provider_order_id text,
  provider_payment_id text,
  amount_paise int not null,
  currency text default 'INR',
  status payment_status not null,
  method text,                           -- 'upi','card','wallet','bnpl'
  raw jsonb,                             -- full webhook payload
  created_at timestamptz default now()
);

-- 7. reviews
create table reviews (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid unique references bookings(id) on delete cascade,
  listing_id uuid not null references listings(id),
  operator_id uuid not null references operators(id),
  user_id uuid not null references profiles(id),
  rating int not null check (rating between 1 and 5),
  tags text[] default array[]::text[],
  body text,
  photos text[],
  helpful_count int default 0,
  created_at timestamptz default now()
);
create index on reviews(listing_id, created_at desc);

-- 8. wishlists (collections)
create table collections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  name text not null,
  visibility collection_visibility default 'private',
  share_slug text unique,
  created_at timestamptz default now()
);
create table collection_items (
  collection_id uuid references collections(id) on delete cascade,
  listing_id uuid references listings(id) on delete cascade,
  added_at timestamptz default now(),
  primary key (collection_id, listing_id)
);

-- 9. loyalty ledger (append-only, source of truth for points)
create table loyalty_events (
  id bigserial primary key,
  user_id uuid not null references profiles(id),
  delta int not null,                    -- +/- points
  reason text not null,                  -- 'booking','review_photo','referral','redeem','tier_bonus','manual'
  ref_booking_id uuid references bookings(id),
  ref_referral_id uuid references profiles(id),
  created_at timestamptz default now()
);
create index on loyalty_events(user_id, created_at desc);

-- 10. referrals
create table referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references profiles(id),
  referee_id uuid references profiles(id),
  code text not null,
  completed boolean default false,
  reward_paise int default 20000,        -- ₹200
  created_at timestamptz default now()
);

-- 11. carts (for abandoned-cart recovery)
create table carts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id),
  session_id text,                       -- for guests
  listing_id uuid references listings(id),
  availability_id uuid references availability(id),
  guests int default 1,
  updated_at timestamptz default now(),
  abandoned_notified_at timestamptz
);
create index on carts(user_id);
create index on carts(session_id);

-- 12. notifications (in-app inbox + delivery log)
create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  channel notif_channel not null,
  title text not null,
  body text,
  deep_link text,
  ref_booking_id uuid references bookings(id),
  scheduled_at timestamptz,
  sent_at timestamptz,
  read_at timestamptz,
  provider_response jsonb,
  created_at timestamptz default now()
);
create index on notifications(user_id, created_at desc);
create index on notifications(scheduled_at) where sent_at is null;

-- 13. digest_editions (weekly digest cache)
create table digest_editions (
  id uuid primary key default gen_random_uuid(),
  week_start date not null,
  neighbourhood text,
  items jsonb not null,                  -- [{listing_id, headline, blurb, price_paise}, …]
  published_at timestamptz default now(),
  unique(week_start, neighbourhood)
);

-- 14. live_trip: realtime per-booking state (for in-trip screen)
create table live_trip (
  booking_id uuid primary key references bookings(id) on delete cascade,
  started_at timestamptz,
  current_stop int default 0,
  stops jsonb not null,                  -- [{n, title, note, lat, lng, duration}]
  updated_at timestamptz default now()
);
-- publish on realtime
alter publication supabase_realtime add table live_trip;
alter publication supabase_realtime add table bookings;

-- 15. neighbourhoods (canonical list for filters + SEO pages)
create table neighbourhoods (
  slug text primary key,                 -- 'bandra-west'
  name text not null,
  center_lat numeric(9,6),
  center_lng numeric(9,6),
  cover_image text,
  active boolean default true
);

-- 16. audit_log (admin)
create table audit_log (
  id bigserial primary key,
  actor_id uuid,
  action text not null,
  target_table text,
  target_id uuid,
  before jsonb,
  after jsonb,
  created_at timestamptz default now()
);

-- 17. feature_flags (kill switches)
create table feature_flags (
  key text primary key,
  enabled boolean default false,
  metadata jsonb
);
```

### 2.3 Helpful RPCs (Postgres functions the app will call)

```sql
-- atomic seat hold + booking creation (prevents oversell under concurrency)
create or replace function public.create_booking(
  p_listing_id uuid,
  p_availability_id uuid,
  p_guests int,
  p_points_redeem int default 0
) returns bookings
language plpgsql security definer as $$
declare
  v_user uuid := auth.uid();
  v_listing listings%rowtype;
  v_avail availability%rowtype;
  v_booking bookings%rowtype;
  v_base_total int;
  v_taxes int;
  v_discount int;
  v_total int;
  v_points int;
begin
  if v_user is null then raise exception 'auth required'; end if;
  select * into v_listing from listings where id = p_listing_id and active;
  if not found then raise exception 'listing not available'; end if;
  select * into v_avail from availability where id = p_availability_id for update;
  if not found or not v_avail.active then raise exception 'slot not available'; end if;
  if v_avail.booked + p_guests > v_avail.capacity then raise exception 'not enough seats'; end if;

  v_base_total := coalesce(v_avail.price_paise_override, v_listing.base_price_paise) * p_guests;
  v_taxes := (v_base_total * v_listing.taxes_pct / 100)::int;
  v_discount := least(p_points_redeem, v_base_total / 10) * 100;  -- 1 pt = ₹1, capped 10% of base
  v_total := v_base_total + v_taxes - v_discount;
  v_points := (v_total / 100 * 0.05)::int;   -- 5% earn rate

  update availability set booked = booked + p_guests where id = p_availability_id;

  insert into bookings(
    code, user_id, listing_id, availability_id, operator_id, guests,
    base_total_paise, taxes_paise, discount_paise, points_earned, points_redeemed,
    total_paise, starts_at, cancellation_deadline, meeting_point_snapshot, qr_token
  ) values (
    'MI' || substr(encode(gen_random_bytes(3),'hex'),1,5),
    v_user, p_listing_id, p_availability_id, v_listing.operator_id, p_guests,
    v_base_total, v_taxes, v_discount, v_points, p_points_redeem,
    v_total, v_avail.starts_at,
    v_avail.starts_at - (v_listing.cancellation_hours || ' hours')::interval,
    v_listing.meeting_point,
    encode(gen_random_bytes(24),'base64')
  ) returning * into v_booking;

  if p_points_redeem > 0 then
    insert into loyalty_events(user_id, delta, reason, ref_booking_id)
      values (v_user, -p_points_redeem, 'redeem', v_booking.id);
    update profiles set loyalty_points = loyalty_points - p_points_redeem where id = v_user;
  end if;

  return v_booking;
end $$;
```

```sql
-- award loyalty points after payment success + tier promotion
create or replace function public.award_booking_points(p_booking_id uuid)
returns void language plpgsql security definer as $$
declare
  v_b bookings%rowtype;
  v_new_pts int;
  v_tier loyalty_tier;
begin
  select * into v_b from bookings where id = p_booking_id;
  if v_b.status <> 'confirmed' then return; end if;

  insert into loyalty_events(user_id, delta, reason, ref_booking_id)
    values (v_b.user_id, v_b.points_earned, 'booking', v_b.id);

  update profiles set loyalty_points = loyalty_points + v_b.points_earned
    where id = v_b.user_id returning loyalty_points into v_new_pts;

  v_tier := case
    when v_new_pts >= 2000 then 'legend'::loyalty_tier
    when v_new_pts >= 500  then 'insider'::loyalty_tier
    else 'explorer'::loyalty_tier end;
  update profiles set loyalty_tier = v_tier where id = v_b.user_id;
end $$;
```

```sql
-- semantic search for AI concierge — returns top-k listings by embedding
create or replace function public.search_listings(
  q_embedding vector(1536),
  q_neighbourhood text default null,
  q_max_price_paise int default null,
  q_limit int default 8
) returns table (
  id uuid, title text, subtitle text, price_paise int, rating numeric,
  distance real
) language sql stable as $$
  select l.id, l.title, l.subtitle, l.base_price_paise, l.rating,
         (l.embedding <=> q_embedding) as distance
  from listings l
  where l.active
    and (q_neighbourhood is null or l.neighbourhood = q_neighbourhood)
    and (q_max_price_paise is null or l.base_price_paise <= q_max_price_paise)
  order by l.embedding <=> q_embedding
  limit q_limit
$$;
```

---

## 3. Row-Level Security (RLS) — every table

**Rule of thumb**: enable RLS on every table, then grant the minimum. Nothing is public by default.

```sql
alter table profiles           enable row level security;
alter table operators          enable row level security;
alter table listings           enable row level security;
alter table availability       enable row level security;
alter table bookings           enable row level security;
alter table payments           enable row level security;
alter table reviews            enable row level security;
alter table collections        enable row level security;
alter table collection_items   enable row level security;
alter table loyalty_events     enable row level security;
alter table referrals          enable row level security;
alter table carts              enable row level security;
alter table notifications      enable row level security;
alter table digest_editions    enable row level security;
alter table live_trip          enable row level security;
alter table neighbourhoods     enable row level security;
alter table audit_log          enable row level security;
alter table feature_flags      enable row level security;

-- ===== profiles =====
create policy "own profile: read"  on profiles for select using (auth.uid() = id);
create policy "own profile: write" on profiles for update using (auth.uid() = id);

-- ===== listings, neighbourhoods, digest_editions, feature_flags — public read =====
create policy "listings: public read"       on listings       for select using (active);
create policy "neighbourhoods: public read" on neighbourhoods for select using (active);
create policy "digest: public read"         on digest_editions for select using (true);
create policy "flags: public read"          on feature_flags  for select using (true);

-- ===== availability: public read of active slots =====
create policy "availability: public read"   on availability   for select using (active);

-- ===== bookings: only owner (or operator) sees =====
create policy "bookings: owner read"    on bookings for select
  using (auth.uid() = user_id or exists(select 1 from operators o where o.id = bookings.operator_id and o.owner_id = auth.uid()));
-- writes only via RPC (create_booking is security definer). Block direct insert/update.

-- ===== reviews =====
create policy "reviews: public read"  on reviews for select using (true);
create policy "reviews: author write" on reviews for insert with check (auth.uid() = user_id);
create policy "reviews: author edit"  on reviews for update using (auth.uid() = user_id);

-- ===== collections =====
create policy "coll: owner read"  on collections for select using (auth.uid() = user_id or visibility in ('shared','public'));
create policy "coll: owner write" on collections for all    using (auth.uid() = user_id);
create policy "coll_items: owner" on collection_items for all
  using (exists(select 1 from collections c where c.id = collection_items.collection_id and c.user_id = auth.uid()));

-- ===== loyalty_events, payments, notifications, live_trip, carts =====
create policy "loyalty: own read"   on loyalty_events for select using (auth.uid() = user_id);
create policy "payments: own read"  on payments for select
  using (exists(select 1 from bookings b where b.id = payments.booking_id and b.user_id = auth.uid()));
create policy "notif: own read"     on notifications for select using (auth.uid() = user_id);
create policy "notif: own update"   on notifications for update using (auth.uid() = user_id); -- mark read
create policy "live_trip: own"      on live_trip for select
  using (exists(select 1 from bookings b where b.id = live_trip.booking_id and b.user_id = auth.uid()));
create policy "carts: own"          on carts for all using (auth.uid() = user_id or session_id is not null);

-- ===== operators =====
create policy "operators: public read" on operators for select using (verified);
create policy "operators: owner write" on operators for update using (auth.uid() = owner_id);

-- ===== audit_log — service role only (admin dashboard uses service key) =====
-- (no policies → service key bypass; nothing else can read)

-- ===== referrals =====
create policy "referrals: own read" on referrals for select using (auth.uid() = referrer_id or auth.uid() = referee_id);
```

**Testing RLS**: run `select * from bookings` while logged in as user A — should only see A's bookings. Postgres `set role authenticator; set request.jwt.claim.sub = '<uuid>'` in psql to simulate.

---

## 4. Storage buckets

```sql
-- via Supabase dashboard or SQL
insert into storage.buckets(id, name, public) values
  ('listing-images','listing-images', true),   -- CDN-cached, public
  ('review-photos','review-photos', true),
  ('avatars','avatars', true),
  ('receipts','receipts', false);              -- private, signed URLs

-- policies
create policy "avatars: own upload" on storage.objects for insert
  with check (bucket_id='avatars' and auth.uid()::text = (storage.foldername(name))[1]);
create policy "avatars: public read" on storage.objects for select using (bucket_id='avatars');

create policy "review-photos: booking-owner upload" on storage.objects for insert
  with check (bucket_id='review-photos' and auth.role() = 'authenticated');
create policy "review-photos: public read" on storage.objects for select using (bucket_id='review-photos');
```

---

## 5. Edge Functions (Deno, deployed via `supabase functions deploy <name>`)

Each function lives in `supabase/functions/<name>/index.ts`.

### 5.1 `checkout` — create Razorpay order

```ts
// supabase/functions/checkout/index.ts
import { createClient } from 'jsr:@supabase/supabase-js@2'
Deno.serve(async (req) => {
  const { listingId, availabilityId, guests, pointsRedeem } = await req.json();
  const authHeader = req.headers.get('Authorization')!;
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  );
  const { data: booking, error } = await supabase.rpc('create_booking', {
    p_listing_id: listingId, p_availability_id: availabilityId,
    p_guests: guests, p_points_redeem: pointsRedeem || 0
  }).single();
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 400 });

  // create Razorpay order
  const rzp = await fetch('https://api.razorpay.com/v1/orders', {
    method: 'POST',
    headers: {
      'Authorization': 'Basic ' + btoa(
        `${Deno.env.get('RAZORPAY_KEY_ID')}:${Deno.env.get('RAZORPAY_KEY_SECRET')}`),
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      amount: booking.total_paise, currency: 'INR', receipt: booking.code,
      notes: { booking_id: booking.id }
    })
  }).then(r => r.json());

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  await admin.from('bookings').update({ razorpay_order_id: rzp.id }).eq('id', booking.id);
  await admin.from('payments').insert({
    booking_id: booking.id, provider_order_id: rzp.id,
    amount_paise: booking.total_paise, status: 'created'
  });
  return Response.json({ booking, razorpay_order: rzp, key_id: Deno.env.get('RAZORPAY_KEY_ID') });
});
```

### 5.2 `webhook_razorpay` — payment status → booking confirmation

Verify HMAC signature, update `payments`, transition `bookings.status='confirmed'`, call `award_booking_points`, enqueue notifications (WhatsApp + email + push).

### 5.3 `ai_concierge` — Claude tool-use loop

Uses Anthropic Messages API with tool definitions: `search_listings`, `get_availability`, `create_booking`. Streams responses back. Grounds every recommendation in the DB — never hallucinates inventory.

### 5.4 `notify_whatsapp` — send template message via Gupshup

### 5.5 `abandoned_cart` — pg_cron nightly → find carts >1h old with no booking, send push + WhatsApp with a comeback code

### 5.6 `generate_digest` — Friday 6 AM IST → build per-neighbourhood digest, write to `digest_editions`, fan-out notifications

### 5.7 `pre_trip_reminder` — pg_cron hourly → find confirmed bookings starting in 22-26h, send push + WhatsApp with meeting point

### 5.8 `refresh_embeddings` — nightly → for listings updated in the last 24h, call Anthropic (or OpenAI text-embedding-3-small) and store into `listings.embedding`

### 5.9 `qr_verify` — operator scans a booking QR at the venue → returns booking status, marks `status='completed'` when scanned

### 5.10 `cancel_booking` — checks `cancellation_deadline`, refunds via Razorpay, releases the seat, reverses points

---

## 6. Scheduled jobs (pg_cron, enabled via `create extension pg_cron;`)

```sql
select cron.schedule('pre_trip_reminder', '0 * * * *',
  $$ select net.http_post( url:='https://<project>.functions.supabase.co/pre_trip_reminder',
       headers:='{"Authorization":"Bearer <SERVICE_ROLE_KEY>"}'::jsonb ) $$);

select cron.schedule('abandoned_cart', '30 20 * * *',            -- 8:30 PM IST daily
  $$ select net.http_post(url:='.../abandoned_cart', ...) $$);

select cron.schedule('generate_digest', '30 0 * * 5',            -- Fri 6:00 AM IST (=00:30 UTC)
  $$ select net.http_post(url:='.../generate_digest', ...) $$);

select cron.schedule('refresh_embeddings','0 2 * * *',
  $$ select net.http_post(url:='.../refresh_embeddings', ...) $$);
```

---

## 7. Realtime channels

- **`bookings:user_<uuid>`** → user sees their own booking status flip from `pending → confirmed` (drives the confirmation-page transition without a poll)
- **`live_trip:<booking_id>`** → in-trip screen listens; operator's tablet publishes stop-progress updates
- **`operator:<operator_id>:new_bookings`** → operator dashboard gets a chime when a new booking lands

Subscribe from Next.js:
```ts
const sb = createBrowserClient(...);
sb.channel(`live_trip:${bookingId}`)
  .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'live_trip', filter: `booking_id=eq.${bookingId}` },
      payload => setCurrentStop(payload.new.current_stop))
  .subscribe();
```

---

## 8. Next.js project structure (Vercel-ready)

```
/mumbai-insider/
├── app/
│   ├── (marketing)/
│   │   ├── page.tsx                       # landing (redirects to /explore)
│   │   └── prototype/page.tsx             # embed the static prototype HTML
│   ├── (app)/
│   │   ├── layout.tsx                     # auth-aware shell
│   │   ├── explore/page.tsx               # Home screen
│   │   ├── search/page.tsx
│   │   ├── l/[slug]/page.tsx              # listing detail
│   │   ├── book/[listingId]/page.tsx      # date/time + checkout wizard
│   │   ├── confirm/[bookingCode]/page.tsx
│   │   ├── trips/page.tsx
│   │   ├── trips/[bookingCode]/countdown/page.tsx
│   │   ├── trips/[bookingCode]/live/page.tsx
│   │   ├── wallet/page.tsx
│   │   ├── saved/page.tsx
│   │   ├── profile/page.tsx
│   │   └── digest/[week]/page.tsx
│   ├── api/
│   │   ├── checkout/route.ts              # calls edge fn `checkout`
│   │   ├── razorpay/webhook/route.ts      # forwards to edge fn (or handles locally)
│   │   ├── ai/route.ts                    # streams from `ai_concierge`
│   │   └── og/[bookingCode]/route.tsx     # dynamic OG image for share cards
│   └── auth/
│       ├── callback/route.ts              # OAuth code exchange
│       └── login/page.tsx
├── components/
│   ├── phone/                             # reuse the prototype's screen components
│   ├── ui/                                # buttons, cards, pills — same tokens
│   └── ai/ChatSheet.tsx
├── lib/
│   ├── supabase/server.ts                 # createServerClient (cookies)
│   ├── supabase/client.ts                 # createBrowserClient
│   ├── supabase/admin.ts                  # service-role client, server-only
│   ├── razorpay.ts
│   └── format.ts                          # ₹, dates, distances
├── styles/
│   └── globals.css                        # Basalt tokens
├── supabase/
│   ├── migrations/                        # generated by supabase db diff
│   ├── seed.sql                           # sample operators/listings/availability
│   ├── functions/
│   │   ├── checkout/index.ts
│   │   ├── webhook_razorpay/index.ts
│   │   ├── ai_concierge/index.ts
│   │   ├── notify_whatsapp/index.ts
│   │   ├── abandoned_cart/index.ts
│   │   ├── generate_digest/index.ts
│   │   ├── pre_trip_reminder/index.ts
│   │   ├── refresh_embeddings/index.ts
│   │   ├── qr_verify/index.ts
│   │   └── cancel_booking/index.ts
│   └── config.toml
├── public/
│   └── (static assets, favicon, prototype.html copy)
├── .env.local.example
├── .env.production                        # only NEXT_PUBLIC_* — real secrets live in Vercel
├── vercel.json
├── next.config.mjs
├── package.json
└── tsconfig.json
```

`next.config.mjs`:
```js
export default {
  images: { remotePatterns: [{ protocol:'https', hostname:'*.supabase.co' }] },
  experimental: { serverActions: { allowedOrigins: ['*.vercel.app', 'mumbai-insider.com'] } }
};
```

`vercel.json`:
```json
{
  "framework": "nextjs",
  "regions": ["bom1"],
  "buildCommand": "next build",
  "installCommand": "npm ci",
  "env": {
    "NEXT_PUBLIC_SUPABASE_URL":  "@supabase-url",
    "NEXT_PUBLIC_SUPABASE_ANON_KEY": "@supabase-anon-key"
  }
}
```

---

## 9. Env vars (Vercel dashboard → Project → Settings → Environment Variables)

```
# public — safe to expose in the browser
NEXT_PUBLIC_SUPABASE_URL          = https://xxx.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY     = eyJhbGci...
NEXT_PUBLIC_RAZORPAY_KEY_ID       = rzp_test_...
NEXT_PUBLIC_SITE_URL              = https://mumbai-insider.vercel.app

# server-only (never NEXT_PUBLIC_)
SUPABASE_SERVICE_ROLE_KEY         = eyJhbGci...
SUPABASE_JWT_SECRET               = super-secret
RAZORPAY_KEY_SECRET               = ...
RAZORPAY_WEBHOOK_SECRET           = ...
ANTHROPIC_API_KEY                 = sk-ant-...
GUPSHUP_API_KEY                   = ...
GUPSHUP_SOURCE_NUMBER             = 917xxxxxxxxx
RESEND_API_KEY                    = re_...
GOOGLE_MAPS_API_KEY               = AIza...
```

**Never** put service-role in a `NEXT_PUBLIC_*` var. `.env.local` is git-ignored — `.env.local.example` is committed as a template.

Same vars need to be set for each Edge Function via:
```bash
supabase secrets set ANTHROPIC_API_KEY=... RAZORPAY_KEY_SECRET=... etc.
```

---

## 10. Deployment sequence (first-time, ~2 hours end-to-end)

```bash
# 1. bootstrap the Next.js app
npx create-next-app@latest mumbai-insider --ts --app --tailwind
cd mumbai-insider
npm i @supabase/ssr @supabase/supabase-js razorpay resend zod

# 2. init Supabase locally (optional but recommended)
supabase init
supabase login
supabase link --project-ref <your-project-ref>

# 3. write & apply migrations
supabase migration new initial_schema
#   → paste sections 2.1, 2.2, 2.3 into the generated .sql file
supabase db push                        # applies to remote

# 4. seed sample data (see supabase/seed.sql)
supabase db execute --file supabase/seed.sql

# 5. deploy edge functions
supabase functions deploy checkout
supabase functions deploy webhook_razorpay
supabase functions deploy ai_concierge
# … one per function

# 6. schedule cron jobs — run the pg_cron SQL from section 6

# 7. commit + push to GitHub
git init && git add . && git commit -m "initial commit"
gh repo create mumbai-insider --public --push --source=.

# 8. import into Vercel — https://vercel.com/new → pick repo
#    - framework: Next.js (auto)
#    - region: Mumbai (bom1)
#    - env vars: paste from section 9
# 9. add Supabase integration — https://vercel.com/integrations/supabase
#    - auto-injects NEXT_PUBLIC_SUPABASE_URL + anon key

# 10. Razorpay webhook → point at https://<vercel-domain>/api/razorpay/webhook
#     enable events: payment.captured, payment.failed, refund.processed
```

Post-deploy smoke tests:
- Visit `/`; landing loads
- Sign up via email OTP; row appears in `profiles`
- Browse a listing; RLS-blocked query returns 0 (verified by trying to select another user's booking)
- Complete a Razorpay test payment (`4111 1111 1111 1111`); booking flips `confirmed`; QR appears
- Cancel a booking within the deadline; refund event lands; seat count restored on availability

---

## 11. Security checklist (before going live)

- [ ] Every table has `enable row level security` (query `pg_tables` to confirm)
- [ ] Service-role key exists nowhere in client bundles — grep the built `.next` for it
- [ ] Razorpay webhook verifies HMAC using `RAZORPAY_WEBHOOK_SECRET`
- [ ] Rate-limit `/api/ai` (Vercel Edge Middleware, 30 requests / user / min)
- [ ] CORS on Edge Functions restricted to your domains
- [ ] `auth.users.email` never returned to the frontend — always via `profiles`
- [ ] Supabase → Auth → Enable email confirmation, phone OTP quotas
- [ ] Supabase → Advisors: run "Security Advisor" — resolve all criticals
- [ ] Vercel → Deployment Protection → password-lock preview URLs
- [ ] Backups: Supabase daily backups ON (paid plan), test restore once

---

## 12. Observability & analytics

- **Supabase Logs** → `functions.<name>` for edge fn errors
- **Sentry** → wrap Next.js + Edge Fns (`@sentry/nextjs`)
- **Vercel Analytics** → page timings, Web Vitals
- **Mixpanel or PostHog** → funnel events: `viewed_listing`, `began_checkout`, `paid`, `reviewed`
- **A single dashboard SQL view**:
  ```sql
  create view v_daily_metrics as
  select date_trunc('day', created_at)::date as day,
         count(*) filter (where status='confirmed') as bookings,
         sum(total_paise) filter (where status='confirmed')/100.0 as gmv_rupees,
         count(distinct user_id) as unique_buyers
  from bookings group by 1 order by 1 desc;
  ```

---

## 13. Cost estimate (early months)

| Service | Free tier / est. cost |
|---|---|
| Supabase Pro | $25/mo (500 MB DB, 8 GB bandwidth, Realtime, edge fns) |
| Vercel Pro | $20/mo (needed for team + custom domain analytics) |
| Razorpay | 2% per txn (no monthly fee) |
| Gupshup (WhatsApp) | ~₹0.30/msg conversation |
| Anthropic Claude | $3/M input, $15/M output tokens |
| Resend | 3,000 emails/mo free |
| Google Maps | ~$200/mo credit covers small load |
| **Total fixed** | **~$50/mo** before variable API usage |

---

## 14. Milestones (execution plan)

| Week | Goal |
|---|---|
| 1 | Supabase project + schema + RLS + seed data + basic Next.js scaffold + auth |
| 2 | Listing detail, search, availability, checkout (Razorpay test mode), webhook |
| 3 | Ticket wallet, trips, reviews, loyalty ledger, edge fn: `award_booking_points` |
| 4 | AI concierge (embeddings + Claude tool-use), WhatsApp notify, digest generator |
| 5 | Countdown + live in-trip + realtime; pre-trip reminder cron; abandoned cart |
| 6 | Operator dashboard (Supabase Auth with `role=operator` RLS filter), QR verify |
| 7 | Polish (perf, SEO programmatic pages), pen-test the RLS, load test the RPC |
| 8 | Soft launch (private beta, 10 operators, 50 listings, 100 invited users) |

---

## 15. What NOT to build first

- Multi-language UI (English-only for MVP, add Hindi/Marathi in v1)
- Native mobile apps (Next.js PWA covers 90% of the value)
- Hotels vertical (activities + events are the wedge)
- Group booking / split pay (complex, delay to v2)
- Operator self-serve pricing (admin-managed at start)

Ship the loop end-to-end for one vertical (food tours) in one city before adding surface area.
