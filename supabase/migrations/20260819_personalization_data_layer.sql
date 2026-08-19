-- Personalization data layer (sub-project 2/6): append-only signal log +
-- on-read affinity aggregation. See
-- docs/superpowers/specs/2026-08-19-personalization-data-layer-design.md

alter table public.profiles add column if not exists vibe jsonb not null default '{}'::jsonb;

create table if not exists public.user_signals (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  listing_id uuid references public.listings(id) on delete set null,
  signal_type text not null check (signal_type in ('view','save','book','review','vibe_update')),
  category_slug text,
  neighbourhood text,
  weight numeric not null default 1,
  created_at timestamptz not null default now()
);
create index if not exists user_signals_user_id_created_at_idx on public.user_signals(user_id, created_at desc);

alter table public.user_signals enable row level security;

drop policy if exists "signals: own insert" on public.user_signals;
create policy "signals: own insert" on public.user_signals
  for insert with check (auth.uid() = user_id);

drop policy if exists "signals: own read" on public.user_signals;
create policy "signals: own read" on public.user_signals
  for select using (auth.uid() = user_id);

-- SECURITY DEFINER so it can aggregate across RLS-scoped reads efficiently,
-- but it still hard-checks auth.uid() = p_user_id internally — one signed-in
-- user can never pull another user's affinity by passing a different id,
-- and only `authenticated` (never `anon`) may call it at all.
create or replace function public.get_user_affinity(p_user_id uuid)
returns table(kind text, value text, score numeric)
language sql stable security definer set search_path = public as $$
  select 'category'::text as kind, category_slug as value, sum(weight) as score
  from public.user_signals
  where user_id = p_user_id and auth.uid() = p_user_id
    and category_slug is not null and created_at > now() - interval '90 days'
  group by category_slug
  union all
  select 'neighbourhood'::text, neighbourhood, sum(weight)
  from public.user_signals
  where user_id = p_user_id and auth.uid() = p_user_id
    and neighbourhood is not null and created_at > now() - interval '90 days'
  group by neighbourhood
  order by score desc
  limit 20;
$$;

revoke execute on function public.get_user_affinity(uuid) from anon, authenticated;
grant execute on function public.get_user_affinity(uuid) to authenticated;
