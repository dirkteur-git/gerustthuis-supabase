import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.8'
import {
  isTokenExpired,
  refreshToken,
  fetchLights,
  fetchGroups,
  fetchSensors,
  buildRoomMap,
  buildSensorRoomMap,
  extractLightState,
  extractSensorState,
  mapSensorType,
  fetchContactSensorsV2,
  fetchDevicesV2,
  fetchRoomsV2,
  type HueConfig,
} from '../_shared/hue-client.ts'
import { corsHeaders, handleCors } from '../_shared/cors.ts'

Deno.serve(async (req) => {
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // Load active hue configs
    const { data: configs, error: configError } = await supabase.schema('integrations')
      .from('hue_config')
      .select('*')
      .eq('status', 'active')

    if (configError || !configs || configs.length === 0) {
      return new Response(
        JSON.stringify({ success: false, error: 'No active Hue configs found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const results: any[] = []

    for (const config of configs) {
      const hueConfig = config as HueConfig

      // Skip configs without bridge_username (incomplete linking)
      if (!hueConfig.bridge_username) {
        console.warn(`Skipping config ${hueConfig.id} (${hueConfig.user_email}): no bridge_username`)
        results.push({
          configId: hueConfig.id,
          userEmail: hueConfig.user_email,
          success: false,
          error: 'No bridge_username - bridge linking incomplete',
        })
        continue
      }

      const configResult = await syncConfig(supabase, hueConfig)
      results.push({
        configId: hueConfig.id,
        userEmail: hueConfig.user_email,
        ...configResult,
      })
    }

    return new Response(
      JSON.stringify({
        success: true,
        results,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('Sync error:', error)
    return new Response(
      JSON.stringify({ success: false, error: String(error) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})

async function syncConfig(supabase: any, hueConfig: HueConfig) {
  try {
    let accessToken = hueConfig.access_token

    // Refresh token if needed
    if (isTokenExpired(hueConfig)) {
      console.log('Token expired, refreshing...')
      const newTokens = await refreshToken(hueConfig.refresh_token)

      if (newTokens) {
        accessToken = newTokens.access_token

        await supabase.schema('integrations')
          .from('hue_config')
          .update({
            access_token: newTokens.access_token,
            refresh_token: newTokens.refresh_token,
            token_expires_at: new Date(Date.now() + newTokens.expires_in * 1000).toISOString(),
          })
          .eq('id', hueConfig.id)
      } else {
        return { success: false, error: 'Token refresh failed' }
      }
    }

    // Fetch lights, groups and sensors from Hue API (v1)
    const [lights, groups, sensors] = await Promise.all([
      fetchLights(accessToken, hueConfig.bridge_username),
      fetchGroups(accessToken, hueConfig.bridge_username),
      fetchSensors(accessToken, hueConfig.bridge_username),
    ])

    // Fetch contact sensors via v2 API
    const [contactSensors, devicesV2, roomsV2] = await Promise.all([
      fetchContactSensorsV2(accessToken, hueConfig.bridge_username),
      fetchDevicesV2(accessToken, hueConfig.bridge_username),
      fetchRoomsV2(accessToken, hueConfig.bridge_username),
    ])

    // Build room maps
    const lightRoomMap = buildRoomMap(groups)
    const sensorRoomMap = buildSensorRoomMap(sensors, groups)

    // Auto-discover new devices (lights, sensors, contacts, buttons)
    const discoveryResult = await discoverDevices(
      supabase, hueConfig.id, lights, sensors, contactSensors, groups,
      lightRoomMap, sensorRoomMap, devicesV2, roomsV2
    )

    // Load existing light devices from database (after discovery so new ones are included)
    const { data: devices } = await supabase.schema('integrations')
      .from('hue_devices')
      .select('*')
      .eq('config_id', hueConfig.id)
      .eq('device_type', 'light')

    const deviceMap = new Map(devices?.map((d: any) => [d.hue_unique_id, d]) || [])

    const now = new Date().toISOString()
    const activityEvents: any[] = []
    let lightsChecked = 0
    let changesDetected = 0

    // Process each light
    for (const [hueId, light] of Object.entries(lights)) {
      const uniqueId = (light as any).uniqueid
      if (!uniqueId) continue

      const device = deviceMap.get(uniqueId)
      if (!device) continue // Only process known devices

      const roomName = lightRoomMap.get(`light_${hueId}`) || device.room_name

      lightsChecked++

      // Extract current state from Hue API
      const currentState = extractLightState(light)
      const lastState = device.last_state || {}

      // Compare on/off state
      const wasOn = lastState.on === true
      const isOn = currentState.on === true

      // Check if on/off changed
      if (wasOn !== isOn) {
        changesDetected++
        console.log(`Light "${device.name}" in ${roomName}: ${wasOn ? 'ON' : 'OFF'} → ${isOn ? 'ON' : 'OFF'}`)

        // Create activity event
        activityEvents.push({
          config_id: hueConfig.id,
          device_id: device.id,
          device_type: 'light',
          room_name: roomName,
          is_on: isOn,
          recorded_at: now,
        })

        // Update last_state to current_state
        await supabase.schema('integrations')
          .from('hue_devices')
          .update({ last_state: currentState, last_state_at: now })
          .eq('id', device.id)
      }
    }

    // Sync contact sensors
    const contactResult = await syncContactSensors(
      supabase, hueConfig, contactSensors, devicesV2, roomsV2, now, activityEvents
    )

    // Sync motion sensors
    const motionResult = await syncMotionSensors(
      supabase, hueConfig, sensors, groups, now, activityEvents
    )

    // Sync buttons
    const buttonResult = await syncButtons(
      supabase, hueConfig, sensors, groups, now, activityEvents
    )

    // Insert activity events (lights + contacts + motion + buttons combined)
    let roomActivityUpdated = 0
    if (activityEvents.length > 0) {
      const { error: insertError } = await supabase.schema('activity')
        .from('activity_events')
        .insert(activityEvents)

      if (insertError) {
        console.error('Failed to insert activity_events:', insertError)
      } else {
        console.log(`Inserted ${activityEvents.length} activity events`)

        // Aggregate to room_activity
        roomActivityUpdated = await updateRoomActivity(supabase, hueConfig.id, activityEvents)
      }
    }

    // Update last_sync_at
    await supabase.schema('integrations')
      .from('hue_config')
      .update({ last_sync_at: new Date().toISOString() })
      .eq('id', hueConfig.id)

    return {
      success: true,
      devicesDiscovered: discoveryResult.totalAdded,
      lightsChecked,
      lightsChanged: changesDetected,
      contactsChecked: contactResult.contactsChecked,
      contactsChanged: contactResult.changesDetected,
      motionChecked: motionResult.motionChecked,
      motionChanged: motionResult.changesDetected,
      buttonsChecked: buttonResult.buttonsChecked,
      buttonsChanged: buttonResult.changesDetected,
      eventsInserted: activityEvents.length,
      roomActivityUpdated,
    }
  } catch (error) {
    console.error(`Sync error for config ${hueConfig.id}:`, error)
    return { success: false, error: String(error) }
  }
}

// Sync contact sensors
async function syncContactSensors(
  supabase: any,
  hueConfig: HueConfig,
  contactSensors: any[],
  devicesV2: any[],
  roomsV2: any[],
  now: string,
  activityEvents: any[]
) {
  // Build device ID → room name map from v2 rooms
  const deviceRoomMap = new Map<string, string>()
  for (const room of roomsV2) {
    const roomName = room.metadata?.name
    for (const child of room.children || []) {
      if (child.rtype === 'device') {
        deviceRoomMap.set(child.rid, roomName)
      }
    }
  }

  // Load existing contact sensor devices from database
  const { data: devices } = await supabase.schema('integrations')
    .from('hue_devices')
    .select('*')
    .eq('config_id', hueConfig.id)
    .eq('device_type', 'contact_sensor')

  const deviceMap = new Map(devices?.map((d: any) => [d.hue_unique_id, d]) || [])

  let contactsChecked = 0
  let changesDetected = 0

  for (const contact of contactSensors) {
    const uniqueId = contact.id
    const device = deviceMap.get(uniqueId)
    if (!device) continue // Only process known devices

    const ownerDeviceId = contact.owner?.rid
    const roomName = deviceRoomMap.get(ownerDeviceId) || device.room_name

    contactsChecked++

    // Current state from Hue API
    const isOpen = contact.contact_report?.state === 'no_contact'
    const currentChanged = contact.contact_report?.changed
    const currentState = {
      open: isOpen,
      changed: currentChanged,
    }

    // Compare changed timestamp
    const lastChanged = device.last_state?.changed

    if (lastChanged !== currentChanged && currentChanged) {
      // Door activity detected!
      changesDetected++
      console.log(`Contact "${device.name}" in ${roomName}: ${isOpen ? 'OPEN' : 'CLOSED'}`)

      activityEvents.push({
        config_id: hueConfig.id,
        device_id: device.id,
        device_type: 'contact_sensor',
        room_name: roomName,
        is_on: isOpen, // true = open, false = closed
        recorded_at: currentChanged, // Use Hue timestamp
      })

      // Update last_state to current_state
      await supabase.schema('integrations')
        .from('hue_devices')
        .update({ last_state: currentState, last_state_at: now })
        .eq('id', device.id)
    }
  }

  return { contactsChecked, changesDetected }
}

// Sync motion sensors
async function syncMotionSensors(
  supabase: any,
  hueConfig: HueConfig,
  sensors: Record<string, any>,
  groups: Record<string, any>,
  now: string,
  activityEvents: any[]
) {
  // Build sensor room map
  const sensorRoomMap = buildSensorRoomMap(sensors, groups)

  // Load existing motion sensor devices from database
  const { data: devices } = await supabase.schema('integrations')
    .from('hue_devices')
    .select('*')
    .eq('config_id', hueConfig.id)
    .eq('device_type', 'motion_sensor')

  const deviceMap = new Map(devices?.map((d: any) => [d.hue_unique_id, d]) || [])

  let motionChecked = 0
  let changesDetected = 0

  for (const [sensorId, sensor] of Object.entries(sensors)) {
    const sensorType = mapSensorType((sensor as any).type)
    if (sensorType !== 'motion_sensor') continue

    const uniqueId = (sensor as any).uniqueid
    if (!uniqueId) continue

    const device = deviceMap.get(uniqueId)
    if (!device) continue // Only process known devices

    const roomName = sensorRoomMap.get(uniqueId) || device.room_name

    motionChecked++

    // Current state from Hue API
    const currentState = extractSensorState(sensor)
    const lastState = device.last_state || {}

    // Compare lastupdated timestamp
    const lastUpdated = lastState.lastupdated
    const currentUpdated = currentState.lastupdated

    if (lastUpdated !== currentUpdated && currentUpdated && currentUpdated !== 'none') {
      // Motion detected!
      changesDetected++
      console.log(`Motion "${device.name}" in ${roomName}: detected at ${currentUpdated}`)

      // Format recorded_at timestamp
      const recordedAt = currentUpdated.includes('Z')
        ? currentUpdated
        : currentUpdated + 'Z'

      activityEvents.push({
        config_id: hueConfig.id,
        device_id: device.id,
        device_type: 'motion_sensor',
        room_name: roomName,
        is_on: true, // Motion = activity detected
        recorded_at: recordedAt,
      })

      // Update last_state to current_state
      await supabase.schema('integrations')
        .from('hue_devices')
        .update({ last_state: currentState, last_state_at: now })
        .eq('id', device.id)
    }
  }

  return { motionChecked, changesDetected }
}

// Sync buttons (schakelaars)
async function syncButtons(
  supabase: any,
  hueConfig: HueConfig,
  sensors: Record<string, any>,
  groups: Record<string, any>,
  now: string,
  activityEvents: any[]
) {
  // Build sensor room map
  const sensorRoomMap = buildSensorRoomMap(sensors, groups)

  // Load existing button devices from database
  const { data: devices } = await supabase.schema('integrations')
    .from('hue_devices')
    .select('*')
    .eq('config_id', hueConfig.id)
    .eq('device_type', 'button')

  const deviceMap = new Map(devices?.map((d: any) => [d.hue_unique_id, d]) || [])

  let buttonsChecked = 0
  let changesDetected = 0

  for (const [sensorId, sensor] of Object.entries(sensors)) {
    const sensorType = mapSensorType((sensor as any).type)
    if (sensorType !== 'button') continue

    const uniqueId = (sensor as any).uniqueid
    if (!uniqueId) continue

    const device = deviceMap.get(uniqueId)
    if (!device) continue // Only process known devices

    const roomName = sensorRoomMap.get(uniqueId) || device.room_name

    buttonsChecked++

    // Current state from Hue API
    const currentState = extractSensorState(sensor)
    const lastState = device.last_state || {}

    // Compare lastupdated timestamp
    const lastUpdated = lastState.lastupdated
    const currentUpdated = currentState.lastupdated

    if (lastUpdated !== currentUpdated && currentUpdated && currentUpdated !== 'none') {
      // Button pressed!
      changesDetected++
      console.log(`Button "${device.name}" in ${roomName}: pressed (event: ${currentState.buttonevent}) at ${currentUpdated}`)

      // Format recorded_at timestamp
      const recordedAt = currentUpdated.includes('Z')
        ? currentUpdated
        : currentUpdated + 'Z'

      activityEvents.push({
        config_id: hueConfig.id,
        device_id: device.id,
        device_type: 'button',
        room_name: roomName,
        is_on: true, // Button pressed = activity
        recorded_at: recordedAt,
      })

      // Update last_state to current_state (includes buttonevent)
      await supabase.schema('integrations')
        .from('hue_devices')
        .update({ last_state: currentState, last_state_at: now })
        .eq('id', device.id)
    }
  }

  return { buttonsChecked, changesDetected }
}

// Auto-discover devices from Hue API and insert into hue_devices
async function discoverDevices(
  supabase: any,
  configId: string,
  lights: Record<string, any>,
  sensors: Record<string, any>,
  contactSensors: any[],
  groups: Record<string, any>,
  lightRoomMap: Map<string, string>,
  sensorRoomMap: Map<string, string>,
  devicesV2: any[],
  roomsV2: any[],
) {
  // Load ALL existing devices for this config (all types)
  const { data: existingDevices } = await supabase.schema('integrations')
    .from('hue_devices')
    .select('hue_unique_id')
    .eq('config_id', configId)

  const existingIds = new Set(existingDevices?.map((d: any) => d.hue_unique_id) || [])
  const newDevices: any[] = []

  // 1. Discover lights
  for (const [hueId, light] of Object.entries(lights)) {
    const uniqueId = (light as any).uniqueid
    if (!uniqueId || existingIds.has(uniqueId)) continue

    newDevices.push({
      config_id: configId,
      hue_id: hueId,
      hue_unique_id: uniqueId,
      device_type: 'light',
      name: (light as any).name || `Light ${hueId}`,
      room_name: lightRoomMap.get(`light_${hueId}`) || null,
      last_state: extractLightState(light),
    })
    existingIds.add(uniqueId) // Prevent duplicates within same batch
  }

  // 2. Discover sensors (motion, buttons, temperature, light level)
  for (const [sensorId, sensor] of Object.entries(sensors)) {
    const uniqueId = (sensor as any).uniqueid
    if (!uniqueId || existingIds.has(uniqueId)) continue

    const deviceType = mapSensorType((sensor as any).type)
    if (deviceType === 'unknown') continue

    newDevices.push({
      config_id: configId,
      hue_id: sensorId,
      hue_unique_id: uniqueId,
      device_type: deviceType,
      name: (sensor as any).name || `Sensor ${sensorId}`,
      room_name: sensorRoomMap.get(uniqueId) || null,
      last_state: extractSensorState(sensor),
    })
    existingIds.add(uniqueId)
  }

  // 3. Discover contact sensors (v2 API)
  // Build device ID → room name map from v2 rooms
  const deviceRoomMap = new Map<string, string>()
  for (const room of roomsV2) {
    const roomName = room.metadata?.name
    for (const child of room.children || []) {
      if (child.rtype === 'device') {
        deviceRoomMap.set(child.rid, roomName)
      }
    }
  }

  for (const contact of contactSensors) {
    const uniqueId = contact.id
    if (!uniqueId || existingIds.has(uniqueId)) continue

    // Find device name from v2 devices
    const ownerDeviceId = contact.owner?.rid
    const ownerDevice = devicesV2.find((d: any) => d.id === ownerDeviceId)
    const deviceName = ownerDevice?.metadata?.name || `Contact sensor`
    const roomName = deviceRoomMap.get(ownerDeviceId) || null

    newDevices.push({
      config_id: configId,
      hue_id: uniqueId, // v2 API uses UUID as ID
      hue_unique_id: uniqueId,
      device_type: 'contact_sensor',
      name: deviceName,
      room_name: roomName,
      last_state: {
        open: contact.contact_report?.state === 'no_contact',
        changed: contact.contact_report?.changed,
      },
    })
    existingIds.add(uniqueId)
  }

  // Insert all new devices
  let totalAdded = 0
  if (newDevices.length > 0) {
    const { error } = await supabase.schema('integrations')
      .from('hue_devices')
      .upsert(newDevices, { onConflict: 'config_id,hue_unique_id' })

    if (error) {
      console.error('Failed to insert discovered devices:', error)
    } else {
      totalAdded = newDevices.length
      console.log(`Discovered ${totalAdded} new devices (${newDevices.filter(d => d.device_type === 'light').length} lights, ${newDevices.filter(d => d.device_type === 'motion_sensor').length} motion, ${newDevices.filter(d => d.device_type === 'contact_sensor').length} contact, ${newDevices.filter(d => d.device_type === 'button').length} buttons)`)
    }
  }

  return { totalAdded }
}

// Update room_activity with aggregated data from new activity events
async function updateRoomActivity(
  supabase: any,
  configId: string,
  activityEvents: any[]
): Promise<number> {
  // Group events by room and 5-minute window
  const windowMap = new Map<string, {
    config_id: string
    room_name: string
    activity_window: string
    trigger_types: Set<string>
    trigger_count: number
    first_trigger_at: string
    last_trigger_at: string
  }>()

  for (const event of activityEvents) {
    if (!event.room_name) continue

    // Calculate 5-minute window
    const recordedAt = new Date(event.recorded_at)
    const windowStart = new Date(recordedAt)
    windowStart.setMinutes(Math.floor(recordedAt.getMinutes() / 5) * 5, 0, 0)
    const windowKey = `${event.room_name}|${windowStart.toISOString()}`

    if (!windowMap.has(windowKey)) {
      windowMap.set(windowKey, {
        config_id: configId,
        room_name: event.room_name,
        activity_window: windowStart.toISOString(),
        trigger_types: new Set([event.device_type]),
        trigger_count: 1,
        first_trigger_at: event.recorded_at,
        last_trigger_at: event.recorded_at,
      })
    } else {
      const existing = windowMap.get(windowKey)!
      existing.trigger_types.add(event.device_type)
      existing.trigger_count++
      if (event.recorded_at < existing.first_trigger_at) {
        existing.first_trigger_at = event.recorded_at
      }
      if (event.recorded_at > existing.last_trigger_at) {
        existing.last_trigger_at = event.recorded_at
      }
    }
  }

  // Upsert each window into room_activity
  let updated = 0
  for (const [_key, window] of windowMap) {
    const { error } = await supabase
      .from('room_activity')
      .upsert({
        config_id: window.config_id,
        room_name: window.room_name,
        activity_window: window.activity_window,
        trigger_types: Array.from(window.trigger_types),
        trigger_count: window.trigger_count,
        first_trigger_at: window.first_trigger_at,
        last_trigger_at: window.last_trigger_at,
      }, {
        onConflict: 'config_id,room_name,activity_window',
      })

    if (error) {
      console.error('Failed to upsert room_activity:', error)
    } else {
      updated++
    }
  }

  console.log(`Updated ${updated} room_activity windows`)
  return updated
}
