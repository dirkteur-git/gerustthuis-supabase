import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import {
  isTokenExpired,
  refreshToken,
  fetchSensors,
  extractBatteryLevel,
  type HueConfig,
} from '../_shared/hue-client.ts'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

const LOW_BATTERY_THRESHOLD = 20

serve(async (req) => {
  // Handle CORS
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    // 1. Create Supabase client with service role
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // 2. Load active hue_config
    const { data: config, error: configError } = await supabase
      .from('hue_config')
      .select('*')
      .eq('status', 'active')
      .single()

    if (configError || !config) {
      return new Response(
        JSON.stringify({ success: false, error: 'No active Hue config found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const hueConfig = config as HueConfig
    let accessToken = hueConfig.access_token

    // 3. Check token expiry and refresh if needed
    if (isTokenExpired(hueConfig)) {
      console.log('Token expired, refreshing...')
      const newTokens = await refreshToken(hueConfig.refresh_token)

      if (newTokens) {
        accessToken = newTokens.access_token

        // Update tokens in database
        await supabase
          .from('hue_config')
          .update({
            access_token: newTokens.access_token,
            refresh_token: newTokens.refresh_token,
            token_expires_at: new Date(Date.now() + newTokens.expires_in * 1000).toISOString(),
          })
          .eq('id', hueConfig.id)
      } else {
        await supabase
          .from('hue_config')
          .update({
            status: 'error',
            last_error: 'Token refresh failed',
          })
          .eq('id', hueConfig.id)

        return new Response(
          JSON.stringify({ success: false, error: 'Token refresh failed' }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
    }

    // 4. Fetch sensors (lights don't have batteries)
    const sensors = await fetchSensors(accessToken, hueConfig.bridge_username)

    // 5. Get all battery-powered devices
    const { data: devices } = await supabase
      .from('hue_devices')
      .select('*')
      .eq('config_id', hueConfig.id)
      .in('device_type', ['motion_sensor', 'contact_sensor', 'button', 'temperature_sensor', 'light_sensor'])

    const deviceMap = new Map(devices?.map(d => [d.hue_unique_id, d]) || [])
    const batteryEvents: any[] = []
    const now = new Date().toISOString()
    let lowBatteryCount = 0

    // 6. Process sensors for battery levels
    for (const [_hueId, sensor] of Object.entries(sensors)) {
      const uniqueId = (sensor as any).uniqueid
      if (!uniqueId) continue

      const device = deviceMap.get(uniqueId)
      if (!device) continue

      const batteryLevel = extractBatteryLevel(sensor)
      if (batteryLevel === null) continue

      const isLow = batteryLevel < LOW_BATTERY_THRESHOLD
      if (isLow) lowBatteryCount++

      batteryEvents.push({
        device_id: device.id,
        event_type: 'battery_update',
        previous_state: null,
        new_state: {
          battery: batteryLevel,
          is_low: isLow,
        },
        recorded_at: now,
      })
    }

    // 7. Insert battery readings
    if (batteryEvents.length > 0) {
      const { error: insertError } = await supabase
        .from('raw_events')
        .insert(batteryEvents)

      if (insertError) {
        console.error('Failed to insert battery readings:', insertError)
      }
    }

    const result = {
      success: true,
      devicesPolled: deviceMap.size,
      readingsInserted: batteryEvents.length,
      lowBatteryCount,
    }

    console.log(`Battery poll complete: ${result.readingsInserted} readings, ${result.lowBatteryCount} low`)

    return new Response(
      JSON.stringify(result),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('Battery poll error:', error)

    return new Response(
      JSON.stringify({ success: false, error: String(error) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
