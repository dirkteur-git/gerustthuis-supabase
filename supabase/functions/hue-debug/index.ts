import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

const HUE_API_URL = 'https://api.meethue.com/route/api'
const HUE_API_V2_URL = 'https://api.meethue.com/route/clip/v2/resource'

serve(async (req) => {
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    // Create service role client for database queries
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // Get user email from request body
    const { user_email } = await req.json()

    if (!user_email) {
      return new Response(
        JSON.stringify({ error: 'Missing user_email' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Get user's hue config
    const { data: config, error: configError } = await supabase
      .from('hue_config')
      .select('*')
      .eq('user_email', user_email)
      .eq('status', 'active')
      .single()

    if (configError || !config) {
      return new Response(
        JSON.stringify({ error: 'No active Hue config found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    let accessToken = config.access_token
    const username = config.bridge_username

    // Check if token expired and refresh if needed
    const expiresAt = new Date(config.token_expires_at).getTime()
    const buffer = 5 * 60 * 1000
    if (Date.now() > expiresAt - buffer) {
      // Refresh token
      const clientId = Deno.env.get('HUE_CLIENT_ID')
      const clientSecret = Deno.env.get('HUE_CLIENT_SECRET')

      const formParams = new URLSearchParams()
      formParams.append('grant_type', 'refresh_token')
      formParams.append('refresh_token', config.refresh_token)

      const credentials = `${clientId}:${clientSecret}`
      const basicAuth = btoa(credentials)

      const tokenResponse = await fetch('https://api.meethue.com/v2/oauth2/token', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Authorization': `Basic ${basicAuth}`,
        },
        body: formParams.toString()
      })

      if (tokenResponse.ok) {
        const tokens = await tokenResponse.json()
        accessToken = tokens.access_token

        // Update config
        await supabase
          .from('hue_config')
          .update({
            access_token: tokens.access_token,
            refresh_token: tokens.refresh_token,
            token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(),
          })
          .eq('id', config.id)
      }
    }

    // Fetch all data from Hue API
    const fetchV1 = async (endpoint: string) => {
      const response = await fetch(`${HUE_API_URL}/${username}/${endpoint}`, {
        headers: { 'Authorization': `Bearer ${accessToken}` }
      })
      if (!response.ok) throw new Error(`V1 ${endpoint} failed: ${response.status}`)
      return await response.json()
    }

    const fetchV2 = async (endpoint: string) => {
      const response = await fetch(`${HUE_API_V2_URL}/${endpoint}`, {
        headers: {
          'Authorization': `Bearer ${accessToken}`,
          'hue-application-key': username
        }
      })
      if (!response.ok) {
        console.error(`V2 ${endpoint} failed:`, response.status)
        return []
      }
      const data = await response.json()
      return data.data || []
    }

    // Fetch everything in parallel
    const [lights, sensors, groups, devicesV2, roomsV2, contactV2] = await Promise.all([
      fetchV1('lights'),
      fetchV1('sensors'),
      fetchV1('groups'),
      fetchV2('device'),
      fetchV2('room'),
      fetchV2('contact'),
    ])

    return new Response(
      JSON.stringify({
        success: true,
        config: {
          user_email: config.user_email,
          bridge_username: config.bridge_username?.substring(0, 10) + '...',
          status: config.status,
        },
        data: {
          lights,
          sensors,
          groups,
          devicesV2,
          roomsV2,
          contactV2,
        }
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Debug error:', error)
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
