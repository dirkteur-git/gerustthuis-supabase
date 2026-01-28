import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import {
  isTokenExpired,
  refreshToken,
  fetchLights,
  fetchSensors,
  extractLightState,
  extractSensorState,
  hasStateChanged,
  mapSensorType,
  type HueConfig,
} from '../_shared/hue-client.ts'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

interface PollResult {
  success: boolean
  devicesChecked: number
  changesDetected: number
  tokensRefreshed: boolean
  error?: string
}

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
    let tokensRefreshed = false

    // 3. Check token expiry and refresh if needed
    if (isTokenExpired(hueConfig)) {
      console.log('Token expired, refreshing...')
      const newTokens = await refreshToken(hueConfig.refresh_token)

      if (newTokens) {
        accessToken = newTokens.access_token
        tokensRefreshed = true

        // Update tokens in database
        await supabase
          .from('hue_config')
          .update({
            access_token: newTokens.access_token,
            refresh_token: newTokens.refresh_token,
            token_expires_at: new Date(Date.now() + newTokens.expires_in * 1000).toISOString(),
          })
          .eq('id', hueConfig.id)

        console.log('Tokens refreshed successfully')
      } else {
        // Mark config as error
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

    // 4. Fetch all data from Hue
    const [lights, sensors] = await Promise.all([
      fetchLights(accessToken, hueConfig.bridge_username),
      fetchSensors(accessToken, hueConfig.bridge_username),
    ])

    // 5. Load existing devices
    const { data: devices } = await supabase
      .from('hue_devices')
      .select('*')
      .eq('config_id', hueConfig.id)

    const deviceMap = new Map(devices?.map(d => [d.hue_unique_id, d]) || [])
    const changes: any[] = []
    const now = new Date().toISOString()

    // 6. Process lights
    for (const [hueId, light] of Object.entries(lights)) {
      const uniqueId = (light as any).uniqueid
      if (!uniqueId) continue

      let device = deviceMap.get(uniqueId)

      // Create device if not exists
      if (!device) {
        const { data: newDevice } = await supabase
          .from('hue_devices')
          .insert({
            config_id: hueConfig.id,
            hue_id: hueId,
            hue_unique_id: uniqueId,
            device_type: 'light',
            name: (light as any).name,
          })
          .select()
          .single()

        device = newDevice
        deviceMap.set(uniqueId, device)
      }

      if (!device) continue

      const currentState = extractLightState(light)

      if (hasStateChanged(device.last_state, currentState)) {
        changes.push({
          device_id: device.id,
          event_type: 'state_change',
          previous_state: device.last_state,
          new_state: currentState,
          recorded_at: now,
        })

        // Update device last_state
        await supabase
          .from('hue_devices')
          .update({
            last_state: currentState,
            last_state_at: now,
            name: (light as any).name, // Update name in case it changed
          })
          .eq('id', device.id)
      }
    }

    // 7. Process sensors
    for (const [hueId, sensor] of Object.entries(sensors)) {
      const uniqueId = (sensor as any).uniqueid
      if (!uniqueId) continue

      // Skip non-physical sensors (daylight, etc.)
      const sensorType = mapSensorType((sensor as any).type)
      if (sensorType === 'unknown') continue

      let device = deviceMap.get(uniqueId)

      // Create device if not exists
      if (!device) {
        const { data: newDevice } = await supabase
          .from('hue_devices')
          .insert({
            config_id: hueConfig.id,
            hue_id: hueId,
            hue_unique_id: uniqueId,
            device_type: sensorType,
            name: (sensor as any).name,
          })
          .select()
          .single()

        device = newDevice
        deviceMap.set(uniqueId, device)
      }

      if (!device) continue

      const currentState = extractSensorState(sensor)

      if (hasStateChanged(device.last_state, currentState)) {
        // Bepaal recorded_at timestamp
        let recordedAt = now
        if (currentState.lastupdated && currentState.lastupdated !== 'none') {
          // Hue timestamps zijn UTC maar zonder 'Z'
          recordedAt = currentState.lastupdated.includes('Z')
            ? currentState.lastupdated
            : currentState.lastupdated + 'Z'
        }

        changes.push({
          device_id: device.id,
          event_type: 'state_change',
          previous_state: device.last_state,
          new_state: currentState,
          recorded_at: recordedAt,
        })

        // Update device last_state
        await supabase
          .from('hue_devices')
          .update({
            last_state: currentState,
            last_state_at: now,
            name: (sensor as any).name, // Update name in case it changed
          })
          .eq('id', device.id)
      }
    }

    // 8. Batch insert changes
    if (changes.length > 0) {
      const { error: insertError } = await supabase
        .from('raw_events')
        .insert(changes)

      if (insertError) {
        console.error('Failed to insert changes:', insertError)
      }
    }

    // 9. Update last_sync_at
    await supabase
      .from('hue_config')
      .update({
        last_sync_at: now,
        last_error: null,
      })
      .eq('id', hueConfig.id)

    const result: PollResult = {
      success: true,
      devicesChecked: deviceMap.size,
      changesDetected: changes.length,
      tokensRefreshed,
    }

    console.log(`Poll complete: ${result.devicesChecked} devices, ${result.changesDetected} changes`)

    return new Response(
      JSON.stringify(result),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('Poll error:', error)

    return new Response(
      JSON.stringify({ success: false, error: String(error) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
