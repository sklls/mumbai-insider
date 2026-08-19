// supabase/functions/send_booking_email/index.ts
//
// Fired by the `on_booking_confirmed` trigger (see
// supabase/migrations/20260819_send_booking_email_trigger.sql) whenever a
// booking's status flips to 'confirmed'. Sends a personalized confirmation
// email via Resend: booking details, a meeting-point map link, the listing's
// "what to bring" checklist, and same-day weather for the meeting point.
//
// Never blocks or affects the booking itself — this runs after the booking
// is already confirmed, and any failure here is logged, not surfaced to the
// user.

import { createClient } from 'jsr:@supabase/supabase-js@2';

interface BookingEmailPayload {
  booking_id: string;
}

Deno.serve(async (req) => {
  try {
    const { booking_id }: BookingEmailPayload = await req.json();
    if (!booking_id) {
      return Response.json({ error: 'booking_id required' }, { status: 400 });
    }

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    const { data: booking, error: bookingErr } = await admin
      .from('bookings')
      .select('id, code, guests, total_paise, starts_at, user_id, listing_id')
      .eq('id', booking_id)
      .single();
    if (bookingErr || !booking) {
      console.error('send_booking_email: booking not found', booking_id, bookingErr);
      return Response.json({ error: 'booking not found' }, { status: 404 });
    }

    const { data: listing, error: listingErr } = await admin
      .from('listings')
      .select('title, meeting_point, meeting_lat, meeting_lng, what_to_bring, cover_image')
      .eq('id', booking.listing_id)
      .single();
    if (listingErr || !listing) {
      console.error('send_booking_email: listing not found', booking.listing_id, listingErr);
      return Response.json({ error: 'listing not found' }, { status: 404 });
    }

    const { data: profile } = await admin
      .from('profiles')
      .select('full_name')
      .eq('id', booking.user_id)
      .single();

    const { data: authUser, error: authErr } = await admin.auth.admin.getUserById(booking.user_id);
    const toEmail = authUser?.user?.email;
    if (authErr || !toEmail) {
      console.error('send_booking_email: no email for user', booking.user_id, authErr);
      return Response.json({ error: 'user has no email' }, { status: 404 });
    }

    const firstName = (profile?.full_name || 'there').split(' ')[0];
    const mapsLink = listing.meeting_lat && listing.meeting_lng
      ? `https://www.google.com/maps?q=${listing.meeting_lat},${listing.meeting_lng}`
      : null;

    const weather = await getWeather(listing.meeting_lat, listing.meeting_lng, booking.starts_at);

    const html = buildEmailHtml({
      firstName,
      listingTitle: listing.title,
      startsAt: booking.starts_at,
      guests: booking.guests,
      totalPaise: booking.total_paise,
      bookingCode: booking.code,
      meetingPoint: listing.meeting_point,
      mapsLink,
      whatToBring: listing.what_to_bring || [],
      weather,
    });

    const resendKey = Deno.env.get('RESEND_API_KEY');
    if (!resendKey) {
      console.warn('send_booking_email: RESEND_API_KEY not set, skipping send. Email would have been:', html);
      return Response.json({ skipped: true, reason: 'RESEND_API_KEY not configured' });
    }

    const resendRes = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${resendKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: 'Mumbai Insider <bookings@mumbaiinsider.app>',
        to: toEmail,
        subject: `You're set for ${listing.title}`,
        html,
      }),
    });

    if (!resendRes.ok) {
      const errText = await resendRes.text();
      console.error('send_booking_email: Resend send failed', resendRes.status, errText);
      return Response.json({ error: 'email send failed' }, { status: 502 });
    }

    return Response.json({ sent: true });
  } catch (e) {
    console.error('send_booking_email: unexpected error', e);
    return Response.json({ error: 'unexpected error' }, { status: 500 });
  }
});

// Free, keyless forecast lookup — Open-Meteo. Returns null (not thrown) on
// any failure so weather is best-effort, never blocking the email.
async function getWeather(lat: number | null, lng: number | null, startsAt: string) {
  if (!lat || !lng) return null;
  try {
    const date = new Date(startsAt).toISOString().slice(0, 10);
    const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lng}` +
      `&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max` +
      `&timezone=Asia%2FKolkata&start_date=${date}&end_date=${date}`;
    const res = await fetch(url);
    if (!res.ok) return null;
    const data = await res.json();
    const max = data?.daily?.temperature_2m_max?.[0];
    const min = data?.daily?.temperature_2m_min?.[0];
    const rainChance = data?.daily?.precipitation_probability_max?.[0];
    if (max == null || min == null) return null;
    return { max, min, rainChance };
  } catch (e) {
    console.warn('send_booking_email: weather lookup failed', e);
    return null;
  }
}

function fmtRupees(paise: number) {
  return `₹${(paise / 100).toLocaleString('en-IN')}`;
}

function fmtDateTime(iso: string) {
  return new Date(iso).toLocaleString('en-IN', {
    weekday: 'short', day: 'numeric', month: 'short',
    hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Kolkata',
  });
}

function buildEmailHtml(args: {
  firstName: string;
  listingTitle: string;
  startsAt: string;
  guests: number;
  totalPaise: number;
  bookingCode: string;
  meetingPoint: string | null;
  mapsLink: string | null;
  whatToBring: string[];
  weather: { max: number; min: number; rainChance: number } | null;
}) {
  const weatherLine = args.weather
    ? `Expect ${Math.round(args.weather.min)}–${Math.round(args.weather.max)}°C` +
      (args.weather.rainChance >= 40 ? `, ${args.weather.rainChance}% chance of rain — bring an umbrella.` : '.')
    : '';

  const bringList = args.whatToBring.length
    ? `<ul>${args.whatToBring.map((i) => `<li>${escapeHtml(i)}</li>`).join('')}</ul>`
    : '';

  return `
  <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;color:#160805">
    <h2 style="margin-bottom:4px">You're all set, ${escapeHtml(args.firstName)}.</h2>
    <p style="color:#555">Booking confirmed for <strong>${escapeHtml(args.listingTitle)}</strong>.</p>
    <table style="width:100%;border-collapse:collapse;margin:16px 0">
      <tr><td style="padding:4px 0;color:#888">When</td><td style="padding:4px 0">${fmtDateTime(args.startsAt)}</td></tr>
      <tr><td style="padding:4px 0;color:#888">Guests</td><td style="padding:4px 0">${args.guests}</td></tr>
      <tr><td style="padding:4px 0;color:#888">Paid</td><td style="padding:4px 0">${fmtRupees(args.totalPaise)}</td></tr>
      <tr><td style="padding:4px 0;color:#888">Booking code</td><td style="padding:4px 0">#${escapeHtml(args.bookingCode)}</td></tr>
    </table>
    ${args.meetingPoint ? `<p><strong>Meeting point:</strong> ${escapeHtml(args.meetingPoint)}${args.mapsLink ? ` — <a href="${args.mapsLink}">open in Google Maps</a>` : ''}</p>` : ''}
    ${weatherLine ? `<p style="color:#555">${weatherLine}</p>` : ''}
    ${bringList ? `<p><strong>What to bring</strong>${bringList}</p>` : ''}
    <p style="margin-top:24px;color:#888;font-size:12px">Mumbai Insider · See this booking any time in the Trips tab.</p>
  </div>`;
}

function escapeHtml(s: string) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}
