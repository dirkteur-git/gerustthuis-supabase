// Edge Function: waitlist-signup
// Handles waitlist signups with rate limiting, DB insert, and confirmation email

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.8'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

interface SignupRequest {
  email: string
  name?: string
  referral_source?: string
  postcode?: string
}

const MAX_REQUESTS_PER_HOUR = 3

Deno.serve(async (req) => {
  // CORS preflight
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  if (req.method !== 'POST') {
    return new Response(
      JSON.stringify({ error: 'Method not allowed' }),
      { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }

  try {
    const { email, name, referral_source, postcode } = await req.json() as SignupRequest

    // Validatie
    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return new Response(
        JSON.stringify({ error: 'Ongeldig e-mailadres' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Supabase client met service_role (volledige toegang)
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // ── Rate limiting ──────────────────────────────────────────
    const clientIp = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
      || req.headers.get('cf-connecting-ip')
      || 'unknown'

    const windowStart = new Date()
    windowStart.setMinutes(0, 0, 0) // Begin van het huidige uur

    // Upsert rate limit counter
    const { data: rateData, error: rateError } = await supabase
      .from('waitlist_rate_limits')
      .upsert(
        {
          ip_address: clientIp,
          window_start: windowStart.toISOString(),
          request_count: 1,
        },
        { onConflict: 'ip_address,window_start' }
      )
      .select('request_count')
      .single()

    if (!rateError && rateData) {
      // Als dit niet de eerste request is, verhoog de counter
      if (rateData.request_count > 0) {
        const { data: updated } = await supabase
          .from('waitlist_rate_limits')
          .update({ request_count: rateData.request_count + 1 })
          .eq('ip_address', clientIp)
          .eq('window_start', windowStart.toISOString())
          .select('request_count')
          .single()

        if (updated && updated.request_count > MAX_REQUESTS_PER_HOUR) {
          return new Response(
            JSON.stringify({ error: 'Te veel aanmeldingen. Probeer het later opnieuw.' }),
            { status: 429, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          )
        }
      }
    }

    // Opruimen oude rate limits
    await supabase.rpc('cleanup_waitlist_rate_limits')

    // ── INSERT in waitlist ─────────────────────────────────────
    const { data: signup, error: insertError } = await supabase
      .from('waitlist')
      .insert({
        email: email.toLowerCase().trim(),
        name: name?.trim() || null,
        referral_source: referral_source || null,
        postcode: postcode?.trim().toUpperCase() || null,
        gdpr_consent: true,
      })
      .select('id, confirm_token, email, name')
      .single()

    if (insertError) {
      // Duplicate email
      if (insertError.code === '23505') {
        return new Response(
          JSON.stringify({ error: 'DUPLICATE', message: 'Dit e-mailadres staat al op de wachtlijst' }),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
      console.error('Insert error:', insertError)
      return new Response(
        JSON.stringify({ error: 'Aanmelding mislukt' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // ── Bevestigingsmail sturen ─────────────────────────────────
    // Zoho SMTP via HTTP API (configureer ZOHO_MAIL_* secrets)
    const zohoToken = Deno.env.get('ZOHO_MAIL_ACCESS_TOKEN')
    const zohoAccountId = Deno.env.get('ZOHO_MAIL_ACCOUNT_ID')
    const siteUrl = Deno.env.get('SITE_URL') || 'https://gerustthuis.nl'

    if (zohoToken && zohoAccountId) {
      const confirmUrl = `${siteUrl}/wachtlijst/bevestig?token=${signup.confirm_token}`

      try {
        await fetch(`https://mail.zoho.eu/api/accounts/${zohoAccountId}/messages`, {
          method: 'POST',
          headers: {
            'Authorization': `Zoho-oauthtoken ${zohoToken}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            fromAddress: 'info@gerustthuis.care',
            toAddress: signup.email,
            subject: 'Bevestig je aanmelding voor de GerustThuis wachtlijst',
            content: `
              <div style="font-family: 'DM Sans', Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 40px 20px;">
                <div style="text-align: center; margin-bottom: 32px;">
                  <span style="font-size: 24px; font-weight: 600;">
                    <span style="color: #3E6652;">Gerust</span><span style="color: #2C2C2C;">Thuis</span>
                  </span>
                </div>

                <h1 style="font-size: 24px; color: #2C2C2C; margin-bottom: 16px;">
                  Welkom${signup.name ? `, ${signup.name}` : ''}!
                </h1>

                <p style="font-size: 16px; color: #5A5A5A; line-height: 1.6; margin-bottom: 24px;">
                  Bedankt voor je aanmelding op de GerustThuis wachtlijst.
                  Klik op onderstaande knop om je e-mailadres te bevestigen.
                </p>

                <div style="text-align: center; margin: 32px 0;">
                  <a href="${confirmUrl}"
                     style="background-color: #3E6652; color: white; padding: 14px 32px; border-radius: 8px; text-decoration: none; font-weight: 600; font-size: 16px; display: inline-block;">
                    Bevestig mijn aanmelding
                  </a>
                </div>

                <p style="font-size: 14px; color: #8A8A8A; line-height: 1.6;">
                  Of kopieer deze link in je browser:<br/>
                  <a href="${confirmUrl}" style="color: #3E6652;">${confirmUrl}</a>
                </p>

                <hr style="border: none; border-top: 1px solid #E4DED4; margin: 32px 0;" />

                <p style="font-size: 13px; color: #8A8A8A; text-align: center;">
                  GerustThuis — Slim meekijken, zonder camera's.<br/>
                  Je ontvangt deze mail omdat je je hebt aangemeld op gerustthuis.nl
                </p>
              </div>
            `,
          }),
        })
        console.log('Confirmation email sent to', signup.email)
      } catch (emailError) {
        // Email falen mag de signup niet blokkeren
        console.error('Failed to send confirmation email:', emailError)
      }
    } else {
      console.warn('Zoho Mail not configured — skipping confirmation email')
    }

    // ── Zoho Campaigns sync ────────────────────────────────────
    const zohoClientId = Deno.env.get('ZOHO_CAMPAIGNS_CLIENT_ID')
    const zohoClientSecret = Deno.env.get('ZOHO_CAMPAIGNS_CLIENT_SECRET')
    const zohoRefreshToken = Deno.env.get('ZOHO_CAMPAIGNS_REFRESH_TOKEN')
    const zohoListKey = Deno.env.get('ZOHO_CAMPAIGNS_LIST_KEY')

    if (zohoClientId && zohoClientSecret && zohoRefreshToken && zohoListKey) {
      try {
        // Refresh access token
        const tokenRes = await fetch('https://accounts.zoho.eu/oauth/v2/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            grant_type: 'refresh_token',
            client_id: zohoClientId,
            client_secret: zohoClientSecret,
            refresh_token: zohoRefreshToken,
          }),
        })
        const tokenData = await tokenRes.json()
        const accessToken = tokenData.access_token

        if (accessToken) {
          // Voeg contact toe aan Zoho Campaigns lijst
          const contactInfo = JSON.stringify({
            'Contact Email': signup.email,
            'First Name': signup.name || '',
          })

          await fetch(`https://campaigns.zoho.eu/api/v1.1/json/listsubscribe?resfmt=JSON&listkey=${zohoListKey}&contactinfo=${encodeURIComponent(contactInfo)}`, {
            method: 'POST',
            headers: {
              'Authorization': `Zoho-oauthtoken ${accessToken}`,
            },
          })

          // Markeer als gesynct
          await supabase
            .from('waitlist')
            .update({ synced_to_zoho: true })
            .eq('id', signup.id)

          console.log('Synced to Zoho Campaigns:', signup.email)
        }
      } catch (zohoError) {
        // Zoho sync falen mag de signup niet blokkeren
        console.error('Zoho Campaigns sync failed:', zohoError)
      }
    } else {
      console.warn('Zoho Campaigns not configured — skipping sync')
    }

    // ── Succes response ────────────────────────────────────────
    return new Response(
      JSON.stringify({
        success: true,
        id: signup.id,
        message: 'Aanmelding geslaagd! Check je email voor bevestiging.',
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Waitlist signup error:', error)
    return new Response(
      JSON.stringify({ error: 'Er ging iets mis. Probeer het opnieuw.' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
