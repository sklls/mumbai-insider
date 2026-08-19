-- Fires the send_booking_email Edge Function whenever a booking's status
-- flips to 'confirmed'. Async via pg_net (net.http_post), so a slow or
-- failing email send can never block or roll back the booking itself.
--
-- BEFORE RUNNING: replace <SERVICE_ROLE_KEY> below with the real service
-- role key (Project Settings -> API). Do not commit the real key to git --
-- this placeholder is intentional, matching the convention already used
-- for the pg_cron jobs in SUPABASE_BACKEND_PLAN.md.

create extension if not exists pg_net with schema extensions;

create or replace function notify_booking_confirmed()
returns trigger
language plpgsql
security definer
as $$
begin
  if new.status = 'confirmed' and (old.status is distinct from 'confirmed') then
    perform net.http_post(
      url := 'https://rwcgtxmpokzfplgnlwye.supabase.co/functions/v1/send_booking_email',
      headers := '{"Content-Type": "application/json", "Authorization": "Bearer <SERVICE_ROLE_KEY>"}'::jsonb,
      body := jsonb_build_object('booking_id', new.id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists on_booking_confirmed on bookings;
create trigger on_booking_confirmed
  after update of status on bookings
  for each row
  execute function notify_booking_confirmed();
