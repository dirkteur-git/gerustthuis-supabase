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

interface PollResult {
  success: boolean
  devicesChecked: number
  changesDetected: number
  tokensRefreshed: boolean
  error?: string
}

async function pollSingleConfig(supabase: any, hueConfig: HueConfig): Promise<PollResult> {
  const configId = hueConfig.id

  try {
    let accessToken = hueConfig.access_token
    let tokensRefreshed = false

    // Check token expiry and refresh if needed
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
    const [lights, sensors, groups] = await Promise.all([
      fetchLights(accessToken, hueConfig.bridge_username),
      fetchSensors(accessToken, hueConfig.bridge_username),
      fetchGroups(accessToken, hueConfig.bridge_username),
    ])

    // Build room maps
    const lightRoomMap = buildRoomMap(groups)
    // Try MAC-prefix matching first, fallback to name matching
    const sensorRoomMapByMac = buildSensorRoomMapWithLights(sensors, lights, groups)
    const sensorRoomMapByName = buildSensorRoomMap(sensors, groups)
    // Merge: MAC matching has priority
    const sensorRoomMap = new Map([...sensorRoomMapByName, ...sensorRoomMapByMac])

    // 5. Load existing devices
    const { data: devices } = await supabase
      .from('hue_devices')
      .select('*')
      .eq('config_id', hueConfig.id)

    const deviceMap = new Map(devices?.map(d => [d.hue_unique_id, d]) || [])
    const changes: any[] = []
    const activityEvents: any[] = []  // Nieuwe array voor activity_events
    const now = new Date().toISOString()

    // 6. Process lights
    for (const [hueId, light] of Object.entries(lights)) {
      const uniqueId = (light as any).uniqueid
      if (!uniqueId) continue

      let device = deviceMap.get(uniqueId)

      // Get room name for this light
      const roomName = lightRoomMap.get(`light_${hueId}`) || null

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
            room_name: roomName,
          })
          .select()
          .single()

        device = newDevice
        deviceMap.set(uniqueId, device)
      }

      if (!device) continue

      const currentState = extractLightState(light)
      const prevState = device.last_state || {}

      // Check of on/off is veranderd (alleen dit telt als activiteit)
      const wasOn = prevState.on === true
      const isOn = currentState.on === true
      const onOffChanged = (wasOn && !isOn) || (!wasOn && isOn)

      if (onOffChanged) {
        // Activity event: lamp aan of uit
        activityEvents.push({
          config_id: hueConfig.id,
          device_id: device.id,
          device_type: 'light',
          room_name: roomName,
          active: isOn,
          state_value: null,
          recorded_at: now,
        })
      }

      if (hasStateChanged(device.last_state, currentState)) {
        changes.push({
          device_id: device.id,
          event_type: 'state_change',
          previous_state: device.last_state,
          new_state: currentState,
          recorded_at: now,
          room_name: roomName,
        })

        // Update device last_state and room_name
        await supabase
          .from('hue_devices')
          .update({
            last_state: currentState,
            last_state_at: now,
            name: (light as any).name,
            room_name: roomName,
          })
          .eq('id', device.id)
      } else if (device.room_name !== roomName) {
        // Update room_name if changed
        await supabase
          .from('hue_devices')
          .update({ room_name: roomName })
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

      // Skip temperature_sensor and light_sensor - they are part of physical_devices
      // and don't need separate entries in hue_devices
      if (sensorType === 'temperature_sensor' || sensorType === 'light_sensor') continue

      let device = deviceMap.get(uniqueId)

      // Get room name for this sensor
      const roomName = sensorRoomMap.get(uniqueId) || null

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
            room_name: roomName,
          })
          .select()
          .single()

        device = newDevice
        deviceMap.set(uniqueId, device)
      }

      if (!device) continue

      const currentState = extractSensorState(sensor)

      // Check if lastupdated changed - this indicates activity even without state change
      // Motion sensors update lastupdated on EVERY motion, not just state transitions
      const previousLastUpdated = device.last_state?.lastupdated
      const currentLastUpdated = currentState.lastupdated

      const stateChanged = hasStateChanged(device.last_state, currentState)
      const lastUpdatedChanged = previousLastUpdated !== currentLastUpdated && currentLastUpdated && currentLastUpdated !== 'none'

      // Bepaal recorded_at timestamp
      let recordedAt = now
      if (currentLastUpdated && currentLastUpdated !== 'none') {
        recordedAt = currentLastUpdated.includes('Z')
          ? currentLastUpdated
          : currentLastUpdated + 'Z'
      }

      // Activity events voor motion sensor en button
      if (sensorType === 'motion_sensor' && lastUpdatedChanged) {
        activityEvents.push({
          config_id: hueConfig.id,
          device_id: device.id,
          device_type: 'motion_sensor',
          room_name: roomName,
          active: null,
          state_value: 'motion',
          recorded_at: recordedAt,
        })
      } else if (sensorType === 'button') {
        const prevButtonEvent = device.last_state?.buttonevent
        const newButtonEvent = currentState.buttonevent
        if (prevButtonEvent !== newButtonEvent && newButtonEvent != null) {
          activityEvents.push({
            config_id: hueConfig.id,
            device_id: device.id,
            device_type: 'button',
            room_name: roomName,
            active: null,
            state_value: String(newButtonEvent),
            recorded_at: recordedAt,
          })
        }
      }

      // Log activity if lastupdated changed (motion detected) OR state changed
      if (lastUpdatedChanged || stateChanged) {
        // Log motion events when lastupdated changes (indicates movement detected)
        // This catches motion even when presence was already true
        if (sensorType === 'motion_sensor' && lastUpdatedChanged) {
          changes.push({
            device_id: device.id,
            event_type: 'state_change',
            previous_state: device.last_state,
            new_state: currentState,
            recorded_at: recordedAt,
            room_name: roomName,
          })
        }

        // Update device last_state and room_name (always, for all sensor types)
        await supabase
          .from('hue_devices')
          .update({
            last_state: currentState,
            last_state_at: now,
            name: (sensor as any).name,
            room_name: roomName,
          })
          .eq('id', device.id)
      } else if (device.room_name !== roomName && roomName) {
        // Update room_name if changed
        await supabase
          .from('hue_devices')
          .update({ room_name: roomName })
          .eq('id', device.id)
      }
    }

    // 8. Process v2 Contact Sensors (door/window sensors)
    // These are only available via the v2 CLIP API
    const contactSensorsV2 = await fetchContactSensorsV2(accessToken, hueConfig.bridge_username)
    const devicesV2 = await fetchDevicesV2(accessToken, hueConfig.bridge_username)
    const roomsV2 = await fetchRoomsV2(accessToken, hueConfig.bridge_username)

    console.log(`Found ${contactSensorsV2.length} contact sensors via v2 API`)

    // Build device -> room map from v2 rooms
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

    // Build device info map from v2 devices
    const deviceInfoV2 = new Map<string, { name: string; model?: string }>()
    for (const device of devicesV2) {
      deviceInfoV2.set(device.id, {
        name: device.metadata?.name || 'Contact Sensor',
        model: device.product_data?.product_name,
      })
    }

    // Process each contact sensor from v2 API
    for (const contact of contactSensorsV2) {
      const ownerDeviceId = contact.owner?.rid
      if (!ownerDeviceId) continue

      const deviceInfo = deviceInfoV2.get(ownerDeviceId)
      const roomName = deviceToRoomV2.get(ownerDeviceId) || null

      // Use v2 contact id as unique identifier
      const uniqueId = contact.id

      let device = deviceMap.get(uniqueId)

      // Create device if not exists
      if (!device) {
        const { data: newDevice } = await supabase
          .from('hue_devices')
          .insert({
            config_id: hueConfig.id,
            hue_id: contact.id,
            hue_unique_id: uniqueId,
            device_type: 'contact_sensor',
            name: deviceInfo?.name || 'Contact Sensor',
            room_name: roomName,
          })
          .select()
          .single()

        device = newDevice
        if (device) {
          deviceMap.set(uniqueId, device)
        }
      }

      if (!device) continue

      // Map v2 state to our format
      // v2 API: "contact" = closed, "no_contact" = open
      const isOpen = contact.contact_report?.state === 'no_contact'
      const currentState = {
        open: isOpen,
        lastupdated: contact.contact_report?.changed,
      }

      // Check of de changed timestamp is gewijzigd (echte deur activiteit)
      const prevChanged = device.last_state?.lastupdated
      const newChanged = currentState.lastupdated
      const contactChanged = prevChanged !== newChanged && newChanged != null

      if (contactChanged) {
        activityEvents.push({
          config_id: hueConfig.id,
          device_id: device.id,
          device_type: 'contact_sensor',
          room_name: roomName,
          active: null,
          state_value: isOpen ? 'open' : 'closed',
          recorded_at: newChanged,
        })
      }

      if (hasStateChanged(device.last_state, currentState)) {
        const recordedAt = contact.contact_report?.changed || now

        changes.push({
          device_id: device.id,
          event_type: 'state_change',
          previous_state: device.last_state,
          new_state: currentState,
          recorded_at: recordedAt,
          room_name: roomName,
        })

        // Update device last_state and room_name
        await supabase
          .from('hue_devices')
          .update({
            last_state: currentState,
            last_state_at: now,
            name: deviceInfo?.name || device.name,
            room_name: roomName,
          })
          .eq('id', device.id)
      } else if (device.room_name !== roomName && roomName) {
        // Update room_name if changed
        await supabase
          .from('hue_devices')
          .update({ room_name: roomName })
          .eq('id', device.id)
      }
    }

    // 9. Batch insert changes to raw_events
    if (changes.length > 0) {
      const { error: insertError } = await supabase
        .from('raw_events')
        .insert(changes)

      if (insertError) {
        console.error('Failed to insert changes:', insertError)
      }
    }

    // 10. Batch insert activity_events
    if (activityEvents.length > 0) {
      const { error: activityError } = await supabase
        .from('activity_events')
        .insert(activityEvents)

      if (activityError) {
        console.error('Failed to insert activity_events:', activityError)
      } else {
        console.log(`Inserted ${activityEvents.length} activity events`)
      }
    }

    // 11. Update room_activity gebaseerd op activity_events
    // Groepeer activityEvents per room + 5-min window
    const activityMap = new Map<string, {
      configId: string
      roomName: string
      window: Date
      triggerTypes: Set<string>
      triggerCount: number
      firstTrigger: Date
      lastTrigger: Date
    }>()

    // TIJDELIJK: alleen deze kamers voor testen
    const testRooms = ['Berging', 'Entree']

    for (const event of activityEvents) {
      if (!event.room_name) continue

      // TIJDELIJK: alleen testRooms voor testen
      if (!testRooms.includes(event.room_name)) continue

      // Bereken 5-min window
      const timestamp = new Date(event.recorded_at)
      const windowStart = new Date(timestamp)
      windowStart.setMinutes(Math.floor(windowStart.getMinutes() / 5) * 5)
      windowStart.setSeconds(0)
      windowStart.setMilliseconds(0)

      const key = `${hueConfig.id}|${event.room_name}|${windowStart.toISOString()}`

      if (!activityMap.has(key)) {
        activityMap.set(key, {
          configId: hueConfig.id,
          roomName: event.room_name,
          window: windowStart,
          triggerTypes: new Set(),
          triggerCount: 0,
          firstTrigger: timestamp,
          lastTrigger: timestamp,
        })
      }

      const activity = activityMap.get(key)!
      activity.triggerTypes.add(event.device_type)
      activity.triggerCount++
      if (timestamp < activity.firstTrigger) activity.firstTrigger = timestamp
      if (timestamp > activity.lastTrigger) activity.lastTrigger = timestamp
    }

    // Upsert naar room_activity
    for (const [_key, activity] of activityMap) {
      const { error: upsertError } = await supabase
        .from('room_activity')
        .upsert({
          config_id: activity.configId,
          room_name: activity.roomName,
          activity_window: activity.window.toISOString(),
          trigger_types: [...activity.triggerTypes],
          trigger_count: activity.triggerCount,
          first_trigger_at: activity.firstTrigger.toISOString(),
          last_trigger_at: activity.lastTrigger.toISOString(),
        }, {
          onConflict: 'config_id,room_name,activity_window',
        })

      if (upsertError) {
        console.error('Failed to upsert room_activity:', upsertError)
      }
    }

    console.log(`Updated ${activityMap.size} room activity windows`)

    // 12. Update last_sync_at
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

    console.log(`Poll complete for config ${configId}: ${result.devicesChecked} devices, ${result.changesDetected} changes`)

    return result
  } catch (error) {
    console.error(`Poll error for config ${configId}:`, error)
    return {
      success: false,
      devicesChecked: 0,
      changesDetected: 0,
      tokensRefreshed: false,
      error: String(error),
    }
  }
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

    // 2. Load ALL active hue_configs (multi-tenant)
    const { data: configs, error: configError } = await supabase
      .from('hue_config')
      .select('*')
      .eq('status', 'active')

    if (configError) {
      return new Response(
        JSON.stringify({ success: false, error: 'Failed to load configs: ' + configError.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (!configs || configs.length === 0) {
      return new Response(
        JSON.stringify({ success: false, error: 'No active Hue configs found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    console.log(`Polling ${configs.length} active Hue config(s)...`)

    // 3. Poll each config
    const results: { configId: string; userEmail: string; result: PollResult }[] = []

    for (const config of configs) {
      const hueConfig = config as HueConfig
      console.log(`Polling config for ${hueConfig.user_email}...`)
      const result = await pollSingleConfig(supabase, hueConfig)
      results.push({
        configId: hueConfig.id,
        userEmail: hueConfig.user_email,
        result,
      })
    }

    // 4. Summary
    const totalDevices = results.reduce((sum, r) => sum + r.result.devicesChecked, 0)
    const totalChanges = results.reduce((sum, r) => sum + r.result.changesDetected, 0)
    const allSuccess = results.every(r => r.result.success)

    console.log(`Poll complete: ${configs.length} configs, ${totalDevices} total devices, ${totalChanges} total changes`)

    return new Response(
      JSON.stringify({
        success: allSuccess,
        configsPolled: configs.length,
        totalDevices,
        totalChanges,
        results,
      }),
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
