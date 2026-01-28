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

      if (hasStateChanged(device.last_state, currentState)) {
        changes.push({
          device_id: device.id,
          event_type: 'state_change',
          previous_state: device.last_state,
          new_state: currentState,
          recorded_at: now,
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

      // Log activity if lastupdated changed (motion detected) OR state changed
      if (lastUpdatedChanged || stateChanged) {
        // Bepaal recorded_at timestamp
        let recordedAt = now
        if (currentLastUpdated && currentLastUpdated !== 'none') {
          // Hue timestamps zijn UTC maar zonder 'Z'
          recordedAt = currentLastUpdated.includes('Z')
            ? currentLastUpdated
            : currentLastUpdated + 'Z'
        }

        // Log motion events when lastupdated changes (indicates movement detected)
        // This catches motion even when presence was already true
        if (sensorType === 'motion_sensor' && lastUpdatedChanged) {
          changes.push({
            device_id: device.id,
            event_type: 'state_change',
            previous_state: device.last_state,
            new_state: currentState,
            recorded_at: recordedAt,
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

      if (hasStateChanged(device.last_state, currentState)) {
        const recordedAt = contact.contact_report?.changed || now

        changes.push({
          device_id: device.id,
          event_type: 'state_change',
          previous_state: device.last_state,
          new_state: currentState,
          recorded_at: recordedAt,
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

    // 9. Batch insert changes
    if (changes.length > 0) {
      const { error: insertError } = await supabase
        .from('raw_events')
        .insert(changes)

      if (insertError) {
        console.error('Failed to insert changes:', insertError)
      }
    }

    // 10. Group multi-capability sensors into physical devices
    // Hue motion sensors have 3 capabilities: motion, temperature, light_level
    // They share the same MAC prefix (first 23 chars of hue_unique_id)
    const sensorGroups = new Map<string, {
      motionUniqueId: string | null;
      roomName: string | null;
      name: string;
      temperature: number | null;
      lightlevel: number | null;
      dark: boolean | null;
    }>()

    for (const [_hueId, sensor] of Object.entries(sensors)) {
      const uniqueId = (sensor as any).uniqueid
      if (!uniqueId) continue

      const sensorType = mapSensorType((sensor as any).type)
      if (!['motion_sensor', 'temperature_sensor', 'light_sensor'].includes(sensorType)) continue

      const macPrefix = uniqueId.substring(0, 23)
      if (!sensorGroups.has(macPrefix)) {
        sensorGroups.set(macPrefix, {
          motionUniqueId: null,
          roomName: null,
          name: 'Unknown Sensor',
          temperature: null,
          lightlevel: null,
          dark: null,
        })
      }

      const group = sensorGroups.get(macPrefix)!
      const roomName = sensorRoomMap.get(uniqueId) || null
      const state = (sensor as any).state || {}

      if (sensorType === 'motion_sensor') {
        group.motionUniqueId = uniqueId
        group.name = (sensor as any).name
        if (roomName) group.roomName = roomName
      } else if (sensorType === 'temperature_sensor') {
        // Temperature in 0.01°C from Hue
        group.temperature = state.temperature !== undefined ? state.temperature / 100 : null
        if (!group.roomName && roomName) group.roomName = roomName
      } else if (sensorType === 'light_sensor') {
        group.lightlevel = state.lightlevel ?? null
        group.dark = state.dark ?? null
        if (!group.roomName && roomName) group.roomName = roomName
      }
    }

    // Upsert physical devices for each group and update motion sensor's last_state with temp/light
    for (const [macPrefix, group] of sensorGroups) {
      // Only process groups that have a motion sensor
      if (!group.motionUniqueId) continue

      // Get the physical device
      const { data: physicalDevice } = await supabase
        .from('physical_devices')
        .select('id')
        .eq('config_id', hueConfig.id)
        .eq('mac_prefix', macPrefix)
        .single()

      if (!physicalDevice) {
        // Create if not exists
        const { data: newPhys, error: physError } = await supabase
          .from('physical_devices')
          .insert({
            config_id: hueConfig.id,
            mac_prefix: macPrefix,
            name: group.name,
            room_name: group.roomName,
          })
          .select()
          .single()

        if (physError) {
          console.error('Failed to create physical device:', physError)
          continue
        }

        // Link motion sensor
        if (newPhys) {
          await supabase
            .from('hue_devices')
            .update({ physical_device_id: newPhys.id })
            .eq('hue_unique_id', group.motionUniqueId)
        }
      } else {
        // Update room name if needed
        await supabase
          .from('physical_devices')
          .update({ room_name: group.roomName, name: group.name })
          .eq('id', physicalDevice.id)

        // Link motion sensor
        await supabase
          .from('hue_devices')
          .update({ physical_device_id: physicalDevice.id })
          .eq('hue_unique_id', group.motionUniqueId)
      }

      // Update motion sensor's last_state to include temperature and lightlevel
      const motionDevice = deviceMap.get(group.motionUniqueId)
      if (motionDevice) {
        const enrichedState = {
          ...motionDevice.last_state,
          temperature: group.temperature,
          lightlevel: group.lightlevel,
          dark: group.dark,
        }

        await supabase
          .from('hue_devices')
          .update({ last_state: enrichedState })
          .eq('id', motionDevice.id)
      }
    }

    console.log(`Grouped ${sensorGroups.size} physical devices`)

    // 11. Update last_sync_at
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
