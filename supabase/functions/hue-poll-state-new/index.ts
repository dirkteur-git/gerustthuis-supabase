import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import {
  isTokenExpired,
  refreshToken,
  fetchLights,
  fetchSensors,
  fetchGroups,
  fetchContactSensorsV2,
  fetchDevicesV2,
  fetchRoomsV2,
  buildRoomMap,
  buildSensorRoomMap,
  buildSensorRoomMapWithLights,
  extractLightState,
  extractSensorState,
  hasStateChanged,
  mapSensorType,
  type HueConfig,
} from '../_shared/hue-client.ts'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

serve(async (req) => {
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // Load active configs
    const { data: configs, error: configError } = await supabase
      .from('hue_config')
      .select('*')
      .eq('status', 'active')

    if (configError || !configs?.length) {
      return new Response(
        JSON.stringify({ success: false, error: configError?.message || 'No active configs' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const pollTime = new Date().toISOString()
    let totalEvents = 0

    for (const config of configs) {
      const hueConfig = config as HueConfig
      let accessToken = hueConfig.access_token

      // Refresh token if needed
      if (isTokenExpired(hueConfig)) {
        const newTokens = await refreshToken(hueConfig.refresh_token)
        if (newTokens) {
          accessToken = newTokens.access_token
          await supabase
            .from('hue_config')
            .update({
              access_token: newTokens.access_token,
              refresh_token: newTokens.refresh_token,
              token_expires_at: new Date(Date.now() + newTokens.expires_in * 1000).toISOString(),
            })
            .eq('id', hueConfig.id)
        } else {
          console.error(`Token refresh failed for ${hueConfig.user_email}`)
          continue
        }
      }

      // Fetch all data
      const [lights, sensors, groups] = await Promise.all([
        fetchLights(accessToken, hueConfig.bridge_username),
        fetchSensors(accessToken, hueConfig.bridge_username),
        fetchGroups(accessToken, hueConfig.bridge_username),
      ])

      // Build room maps
      const lightRoomMap = buildRoomMap(groups)
      const sensorRoomMapByMac = buildSensorRoomMapWithLights(sensors, lights, groups)
      const sensorRoomMapByName = buildSensorRoomMap(sensors, groups)
      const sensorRoomMap = new Map([...sensorRoomMapByName, ...sensorRoomMapByMac])

      // Load existing devices
      const { data: devices } = await supabase
        .from('hue_devices')
        .select('*')
        .eq('config_id', hueConfig.id)

      const deviceMap = new Map(devices?.map(d => [d.hue_unique_id, d]) || [])
      const newEvents: any[] = []

      // Process lights - check lastupdated
      for (const [hueId, light] of Object.entries(lights)) {
        const uniqueId = (light as any).uniqueid
        if (!uniqueId) continue

        const device = deviceMap.get(uniqueId)
        if (!device) continue

        const currentState = extractLightState(light)
        const stateChangedAt = currentState.lastupdated
          ? (currentState.lastupdated.includes('Z') ? currentState.lastupdated : currentState.lastupdated + 'Z')
          : null

        // Check if state actually changed since last poll
        if (hasStateChanged(device.last_state, currentState)) {
          const roomName = lightRoomMap.get(`light_${hueId}`) || device.room_name

          newEvents.push({
            config_id: hueConfig.id,
            device_id: device.id,
            device_name: device.name,
            device_type: 'light',
            room_name: roomName,
            state_changed_at: stateChangedAt,
            poll_time: pollTime,
            previous_state: device.last_state,
            new_state: currentState,
          })
        }
      }

      // Process sensors
      for (const [hueId, sensor] of Object.entries(sensors)) {
        const uniqueId = (sensor as any).uniqueid
        if (!uniqueId) continue

        const sensorType = mapSensorType((sensor as any).type)
        if (sensorType === 'unknown' || sensorType === 'temperature_sensor' || sensorType === 'light_sensor') continue

        const device = deviceMap.get(uniqueId)
        if (!device) continue

        const currentState = extractSensorState(sensor)
        const previousLastUpdated = device.last_state?.lastupdated
        const currentLastUpdated = currentState.lastupdated

        // For motion sensors: check if lastupdated changed (indicates new motion)
        const lastUpdatedChanged = previousLastUpdated !== currentLastUpdated &&
                                   currentLastUpdated &&
                                   currentLastUpdated !== 'none'

        if (lastUpdatedChanged || hasStateChanged(device.last_state, currentState)) {
          const stateChangedAt = currentLastUpdated && currentLastUpdated !== 'none'
            ? (currentLastUpdated.includes('Z') ? currentLastUpdated : currentLastUpdated + 'Z')
            : pollTime

          const roomName = sensorRoomMap.get(uniqueId) || device.room_name

          newEvents.push({
            config_id: hueConfig.id,
            device_id: device.id,
            device_name: device.name,
            device_type: sensorType,
            room_name: roomName,
            state_changed_at: stateChangedAt,
            poll_time: pollTime,
            previous_state: device.last_state,
            new_state: currentState,
          })
        }
      }

      // Process v2 Contact Sensors
      const contactSensorsV2 = await fetchContactSensorsV2(accessToken, hueConfig.bridge_username)
      const devicesV2 = await fetchDevicesV2(accessToken, hueConfig.bridge_username)
      const roomsV2 = await fetchRoomsV2(accessToken, hueConfig.bridge_username)

      const deviceToRoomV2 = new Map<string, string>()
      for (const room of roomsV2) {
        const roomName = room.metadata?.name
        if (!roomName) continue
        for (const child of room.children || []) {
          if (child.rtype === 'device') {
            deviceToRoomV2.set(child.rid, roomName)
          }
        }
      }

      const deviceInfoV2 = new Map<string, { name: string }>()
      for (const device of devicesV2) {
        deviceInfoV2.set(device.id, { name: device.metadata?.name || 'Contact Sensor' })
      }

      for (const contact of contactSensorsV2) {
        const ownerDeviceId = contact.owner?.rid
        if (!ownerDeviceId) continue

        const uniqueId = contact.id
        const device = deviceMap.get(uniqueId)
        if (!device) continue

        const isOpen = contact.contact_report?.state === 'no_contact'
        const currentState = {
          open: isOpen,
          lastupdated: contact.contact_report?.changed,
        }

        if (hasStateChanged(device.last_state, currentState)) {
          const deviceInfo = deviceInfoV2.get(ownerDeviceId)
          const roomName = deviceToRoomV2.get(ownerDeviceId) || device.room_name

          newEvents.push({
            config_id: hueConfig.id,
            device_id: device.id,
            device_name: deviceInfo?.name || device.name,
            device_type: 'contact_sensor',
            room_name: roomName,
            state_changed_at: contact.contact_report?.changed || pollTime,
            poll_time: pollTime,
            previous_state: device.last_state,
            new_state: currentState,
          })
        }
      }

      // Insert events
      if (newEvents.length > 0) {
        const { error: insertError } = await supabase
          .from('raw_events_new')
          .insert(newEvents)

        if (insertError) {
          console.error('Failed to insert events:', insertError)
        } else {
          totalEvents += newEvents.length
        }
      }

      console.log(`Config ${hueConfig.user_email}: ${newEvents.length} events`)
    }

    return new Response(
      JSON.stringify({ success: true, pollTime, totalEvents }),
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
