-- Mumbai Insider — full schema, RLS, RPCs, seed
-- Applied to Supabase project rwcgtxmpokzfplgnlwye (ap-south-1, Mumbai region) on 2026-08-19.

-- ============================================================
-- 1. Extensions (kept out of public schema)
-- ============================================================
create schema if not exists extensions;
create extension if not exists "pgcrypto" with schema extensions;
create extension if not exists "vector"   with schema extensions;
create extension if not exists "pg_trgm"  with schema extensions;

-- ============================================================
-- 2. Enums
-- ============================================================
do $$ begin create type user_role as enum ('customer','operator','admin'); exception when duplicate_object then null; end $$;
do $$ begin create type booking_status as enum ('pending','confirmed','completed','cancelled','refunded','no_show'); exception when duplicate_object then null; end $$;
do $$ begin create type payment_status as enum ('created','authorized','captured','failed','refunded'); exception when duplicate_object then null; end $$;
do $$ begin create type listing_type as enum ('activity','event','hotel','bundle','food_tour','heritage_walk'); exception when duplicate_object then null; end $$;
do $$ begin create type notif_channel as enum ('push','whatsapp','email','in_app'); exception when duplicate_object then null; end $$;
do $$ begin create type loyalty_tier as enum ('explorer','insider','legend'); exception when duplicate_object then null; end $$;
do $$ begin create type collection_visibility as enum ('private','shared','public'); exception when duplicate_object then null; end $$;

-- ============================================================
-- 3. Tables (18)
-- ============================================================
create table if not exists profiles (
  id uuid primary key references auth.users on delete cascade,
  full_name text, phone text unique, avatar_url text,
  role user_role not null default 'customer',
  language text default 'en',
  home_neighbourhood text,
  loyalty_points int not null default 0,
  loyalty_tier loyalty_tier not null default 'explorer',
  referral_code text unique,
  referred_by uuid references profiles(id),
  onboarding_complete boolean default false,
  created_at timestamptz default now()
);

create table if not exists operators (
  id uuid primary key default gen_random_uuid(),
  name text not null, slug text unique not null,
  owner_id uuid references profiles(id),
  bio text, logo_url text, whatsapp_number text,
  response_minutes int default 30,
  rating numeric(3,2) default 0, rating_count int default 0,
  commission_pct numeric(5,2) default 18.00,
  verified boolean default false,
  created_at timestamptz default now()
);

create table if not exists neighbourhoods (
  slug text primary key, name text not null,
  center_lat numeric(9,6), center_lng numeric(9,6),
  cover_image text, active boolean default true
);

create table if not exists listings (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references operators(id) on delete cascade,
  slug text unique not null,
  type listing_type not null,
  title text not null, subtitle text, description text,
  neighbourhood text, meeting_point text,
  meeting_lat numeric(9,6), meeting_lng numeric(9,6),
  duration_minutes int, max_group_size int, min_group_size int default 1,
  languages text[] default array['en'],
  base_price_paise int not null,
  taxes_pct numeric(5,2) default 5.00,
  cancellation_hours int default 24,
  what_included text[], what_to_bring text[],
  cover_image text, gallery text[],
  active boolean default true, featured boolean default false, editors_pick boolean default false,
  rating numeric(3,2) default 0, rating_count int default 0, booking_count int default 0,
  embedding extensions.vector(1536),
  search_tsv tsvector generated always as (
    to_tsvector('english', coalesce(title,'') || ' ' || coalesce(description,'') || ' ' || coalesce(neighbourhood,''))
  ) stored,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists availability (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references listings(id) on delete cascade,
  starts_at timestamptz not null,
  duration_minutes int, capacity int not null, booked int not null default 0,
  price_paise_override int, active boolean default true,
  unique(listing_id, starts_at)
);

create table if not exists bookings (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  user_id uuid not null references profiles(id),
  listing_id uuid not null references listings(id),
  availability_id uuid references availability(id),
  operator_id uuid not null references operators(id),
  guests int not null default 1,
  base_total_paise int not null, taxes_paise int not null,
  discount_paise int not null default 0,
  points_earned int not null default 0, points_redeemed int not null default 0,
  total_paise int not null, currency text default 'INR',
  status booking_status not null default 'pending',
  payment_status payment_status default 'created',
  razorpay_order_id text, razorpay_payment_id text,
  qr_token text unique, meeting_point_snapshot text,
  starts_at timestamptz, cancellation_deadline timestamptz,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now(),
  confirmed_at timestamptz, cancelled_at timestamptz
);

create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid references bookings(id) on delete cascade,
  provider text default 'razorpay',
  provider_order_id text, provider_payment_id text,
  amount_paise int not null, currency text default 'INR',
  status payment_status not null, method text, raw jsonb,
  created_at timestamptz default now()
);

create table if not exists reviews (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid unique references bookings(id) on delete cascade,
  listing_id uuid not null references listings(id),
  operator_id uuid not null references operators(id),
  user_id uuid not null references profiles(id),
  rating int not null check (rating between 1 and 5),
  tags text[] default array[]::text[],
  body text, photos text[], helpful_count int default 0,
  created_at timestamptz default now()
);

create table if not exists collections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  name text not null,
  visibility collection_visibility default 'private',
  share_slug text unique,
  created_at timestamptz default now()
);
create table if not exists collection_items (
  collection_id uuid references collections(id) on delete cascade,
  listing_id uuid references listings(id) on delete cascade,
  added_at timestamptz default now(),
  primary key (collection_id, listing_id)
);

create table if not exists loyalty_events (
  id bigserial primary key,
  user_id uuid not null references profiles(id),
  delta int not null,
  reason text not null,
  ref_booking_id uuid references bookings(id),
  ref_referral_id uuid references profiles(id),
  created_at timestamptz default now()
);

create table if not exists referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references profiles(id),
  referee_id uuid references profiles(id),
  code text not null, completed boolean default false,
  reward_paise int default 20000,
  created_at timestamptz default now()
);

create table if not exists carts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id),
  session_id text,
  listing_id uuid references listings(id),
  availability_id uuid references availability(id),
  guests int default 1,
  updated_at timestamptz default now(),
  abandoned_notified_at timestamptz
);

create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  channel notif_channel not null,
  title text not null, body text, deep_link text,
  ref_booking_id uuid references bookings(id),
  scheduled_at timestamptz, sent_at timestamptz, read_at timestamptz,
  provider_response jsonb,
  created_at timestamptz default now()
);

create table if not exists digest_editions (
  id uuid primary key default gen_random_uuid(),
  week_start date not null, neighbourhood text,
  items jsonb not null,
  published_at timestamptz default now(),
  unique(week_start, neighbourhood)
);

create table if not exists live_trip (
  booking_id uuid primary key references bookings(id) on delete cascade,
  started_at timestamptz, current_stop int default 0,
  stops jsonb not null,
  updated_at timestamptz default now()
);

create table if not exists audit_log (
  id bigserial primary key,
  actor_id uuid, action text not null,
  target_table text, target_id uuid,
  before jsonb, after jsonb,
  created_at timestamptz default now()
);

create table if not exists feature_flags (
  key text primary key, enabled boolean default false, metadata jsonb
);

-- Indexes (see live DB for the full set; this list is the important ones)
create index if not exists profiles_ref_idx        on profiles(referral_code);
create index if not exists listings_search_idx     on listings using gin(search_tsv);
create index if not exists listings_type_active_idx on listings(type, active, featured);
create index if not exists listings_nbr_idx        on listings(neighbourhood);
create index if not exists availability_listing_idx on availability(listing_id, starts_at);
create index if not exists availability_starts_idx on availability(starts_at) where active;
create index if not exists bookings_user_idx       on bookings(user_id, created_at desc);
create index if not exists bookings_op_idx         on bookings(operator_id, starts_at);
create index if not exists bookings_status_idx     on bookings(status);
create unique index if not exists bookings_rzp_pay_idx on bookings(razorpay_payment_id) where razorpay_payment_id is not null;
create index if not exists payments_booking_idx    on payments(booking_id);
create index if not exists reviews_listing_idx     on reviews(listing_id, created_at desc);
create index if not exists loyalty_user_idx        on loyalty_events(user_id, created_at desc);
create index if not exists carts_user_idx          on carts(user_id);
create index if not exists carts_session_idx       on carts(session_id);
create index if not exists notifications_user_idx  on notifications(user_id, created_at desc);
create index if not exists notifications_pending_idx on notifications(scheduled_at) where sent_at is null;

-- ============================================================
-- 4. RLS — every table
-- ============================================================
-- See applied migrations mi_04_rls_policies_retry and mi_07_security_hardening for the exact policies.
-- Every table has RLS enabled. Public-read tables: listings, neighbourhoods, digest_editions,
-- feature_flags, availability, operators (verified only), reviews. Everything else is owner-only.

-- ============================================================
-- 5. Triggers + RPCs
-- ============================================================
-- handle_new_user() → creates profile row on auth.users insert (see migration mi_05)
-- create_booking(listing, availability, guests, points_redeem) → atomic seat hold + booking
-- award_booking_points(booking_id) → idempotent loyalty ledger + tier promotion
-- search_listings(embedding, neighbourhood, max_price, limit) → pgvector cosine search

-- Realtime publications:
--   supabase_realtime includes live_trip and bookings
