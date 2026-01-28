import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

const HUE_TOKEN_URL = 'https://api.meethue.com/v2/oauth2/token'
const HUE_LINK_URL = 'https://api.meethue.com/route/api/0/config'

interface TokenRequest {
  code: string
  user_email: string
}

serve(async (req) => {
  // Handle CORS
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    const { code, user_email } = await req.json() as TokenRequest

    if (!code || !user_email) {
      return new Response(
        JSON.stringify({ error: 'Missing code or user_email' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const clientId = Deno.env.get('HUE_CLIENT_ID')
    const clientSecret = Deno.env.get('HUE_CLIENT_SECRET')

    if (!clientId || !clientSecret) {
      return new Response(
        JSON.stringify({ error: 'Missing HUE_CLIENT_ID or HUE_CLIENT_SECRET' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // 1. Exchange code for tokens
    const formParams = new URLSearchParams()
    formParams.append('grant_type', 'authorization_code')
    formParams.append('code', code)

    const credentials = `${clientId}:${clientSecret}`
    const basicAuth = btoa(credentials)

    const tokenResponse = await fetch(HUE_TOKEN_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': `Basic ${basicAuth}`,
      },
      body: formParams.toString(),
    })

    if (!tokenResponse.ok) {
      const error = await tokenResponse.text()
      console.error('Token exchange failed:', error)
      return new Response(
        JSON.stringify({ error: 'Token exchange failed', details: error }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const tokens = await tokenResponse.json()
    console.log('Tokens received')

    // 2. Link bridge to get username (whitelist)
    const linkResponse = await fetch(HUE_LINK_URL, {
      method: 'PUT',
      headers: {
        'Authorization': `Bearer ${tokens.access_token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ linkbutton: true }),
    })

    // Now create the whitelist entry
    const whitelistResponse = await fetch('https://api.meethue.com/route/api', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${tokens.access_token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ devicetype: 'gerustthuis#supabase' }),
    })

    let bridgeUsername = null
    if (whitelistResponse.ok) {
      const whitelistResult = await whitelistResponse.json()
      if (Array.isArray(whitelistResult) && whitelistResult[0]?.success?.username) {
        bridgeUsername = whitelistResult[0].success.username
        console.log('Bridge username obtained:', bridgeUsername)
      }
    }

    // 3. Save to database
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const { data: config, error: insertError } = await supabase
      .from('hue_config')
      .upsert({
        user_email,
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(),
        bridge_username: bridgeUsername,
        status: 'active',
        last_error: null,
      }, {
        onConflict: 'user_email',
      })
      .select()
      .single()

    if (insertError) {
      console.error('Failed to save config:', insertError)
      return new Response(
        JSON.stringify({ error: 'Failed to save config', details: insertError }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    return new Response(
      JSON.stringify({
        success: true,
        config_id: config?.id,
        bridge_username: bridgeUsername,
        message: bridgeUsername
          ? 'Hue connected successfully'
          : 'Tokens saved, but bridge linking may have failed. You may need to press the bridge button and retry.',
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('Token exchange error:', error)

    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
