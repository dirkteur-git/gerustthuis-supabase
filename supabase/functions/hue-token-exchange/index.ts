import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.8'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

const HUE_TOKEN_URL = 'https://api.meethue.com/v2/oauth2/token'
const HUE_LINK_URL = 'https://api.meethue.com/route/api/0/config'

interface TokenRequest {
  code: string
  user_email: string
  user_id: string
}

Deno.serve(async (req) => {
  // Handle CORS
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    const { code, user_email, user_id } = await req.json() as TokenRequest

    if (!code || !user_email || !user_id) {
      return new Response(
        JSON.stringify({ error: 'Missing code, user_email, or user_id' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const clientId = Deno.env.get('HUE_CLIENT_ID')
    const clientSecret = Deno.env.get('HUE_CLIENT_SECRET')

    // Debug logging - remove after debugging
    console.log('HUE_CLIENT_ID starts with:', clientId?.substring(0, 8))
    console.log('HUE_CLIENT_SECRET length:', clientSecret?.length)

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

    // 2. Link bridge — activate linkbutton via remote API
    const linkResponse = await fetch(HUE_LINK_URL, {
      method: 'PUT',
      headers: {
        'Authorization': `Bearer ${tokens.access_token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ linkbutton: true }),
    })

    const linkBody = await linkResponse.text()
    console.log('Link response:', linkResponse.status, linkBody)

    if (!linkResponse.ok) {
      console.error('Link button activation failed:', linkResponse.status, linkBody)
    }

    // 2b. Create whitelist entry (bridge username)
    const whitelistResponse = await fetch('https://api.meethue.com/route/api', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${tokens.access_token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ devicetype: 'gerustthuis#supabase' }),
    })

    let bridgeUsername = null
    let bridgeLinkError = null
    const whitelistBody = await whitelistResponse.text()
    console.log('Whitelist response:', whitelistResponse.status, whitelistBody)

    if (whitelistResponse.ok) {
      try {
        const whitelistResult = JSON.parse(whitelistBody)
        if (Array.isArray(whitelistResult) && whitelistResult[0]?.success?.username) {
          bridgeUsername = whitelistResult[0].success.username
          console.log('Bridge username obtained:', bridgeUsername)
        } else if (Array.isArray(whitelistResult) && whitelistResult[0]?.error) {
          bridgeLinkError = `Hue API error: ${whitelistResult[0].error.description || JSON.stringify(whitelistResult[0].error)}`
          console.error('Bridge link error:', bridgeLinkError)
        } else {
          bridgeLinkError = `Onverwacht whitelist antwoord: ${whitelistBody.substring(0, 200)}`
          console.error(bridgeLinkError)
        }
      } catch {
        bridgeLinkError = `Kon whitelist antwoord niet lezen: ${whitelistBody.substring(0, 200)}`
        console.error(bridgeLinkError)
      }
    } else {
      bridgeLinkError = `Whitelist request mislukt (HTTP ${whitelistResponse.status}): ${whitelistBody.substring(0, 200)}`
      console.error(bridgeLinkError)
    }

    // 3. Save to database
    // Only set status 'active' if bridge_username was obtained
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const configStatus = bridgeUsername ? 'active' : 'pending'

    const { data: config, error: insertError } = await supabase.schema('integrations')
      .from('hue_config')
      .upsert({
        user_email,
        user_id,
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(),
        bridge_username: bridgeUsername,
        status: configStatus,
        last_error: bridgeLinkError,
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

    // 4. Trigger initial sync to load devices (only if bridge linked)
    if (bridgeUsername) {
      console.log('Triggering initial sync...')
      try {
        const pollResponse = await fetch(
          `${Deno.env.get('SUPABASE_URL')}/functions/v1/hue-sync-state`,
          {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`,
              'Content-Type': 'application/json',
            },
          }
        )
        const pollResult = await pollResponse.json()
        console.log('Initial sync result:', pollResult)
      } catch (pollError) {
        console.error('Initial sync failed (non-blocking):', pollError)
      }
    }

    // Return different response based on bridge link success
    if (!bridgeUsername) {
      return new Response(
        JSON.stringify({
          success: false,
          config_id: config?.id,
          bridge_username: null,
          error: 'bridge_link_failed',
          message: bridgeLinkError || 'Bridge koppeling mislukt. Probeer opnieuw.',
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    return new Response(
      JSON.stringify({
        success: true,
        config_id: config?.id,
        bridge_username: bridgeUsername,
        message: 'Hue Bridge succesvol gekoppeld!',
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
