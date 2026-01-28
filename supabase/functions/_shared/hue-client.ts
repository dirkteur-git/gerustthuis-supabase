// Shared Hue API client utilities

const HUE_API_URL = 'https://api.meethue.com/route/api'
const HUE_API_V2_URL = 'https://api.meethue.com/route/clip/v2/resource'
const HUE_TOKEN_URL = 'https://api.meethue.com/v2/oauth2/token'

export interface HueConfig {
  id: string
  access_token: string
  refresh_token: string
  token_expires_at: string
  bridge_username: string
  status: string
}

export interface TokenResponse {
  access_token: string
  refresh_token: string
  expires_in: number
  token_type: string
}

/**
 * Check if token is expired (with 5 min buffer)
 */
export function isTokenExpired(config: HueConfig): boolean {
  const expiresAt = new Date(config.token_expires_at).getTime()
  const buffer = 5 * 60 * 1000 // 5 minutes
  return Date.now() > (expiresAt - buffer)
}

/**
 * Refresh Hue OAuth token
 */
export async function refreshToken(refreshToken: string): Promise<TokenResponse | null> {
  const clientId = Deno.env.get('HUE_CLIENT_ID')
  const clientSecret = Deno.env.get('HUE_CLIENT_SECRET')

  if (!clientId || !clientSecret) {
    console.error('Missing HUE_CLIENT_ID or HUE_CLIENT_SECRET')
    return null
  }

  const formParams = new URLSearchParams()
  formParams.append('grant_type', 'refresh_token')
  formParams.append('refresh_token', refreshToken)

  const credentials = `${clientId}:${clientSecret}`
  const basicAuth = btoa(credentials)

  try {
    const response = await fetch(HUE_TOKEN_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': `Basic ${basicAuth}`,
      },
      body: formParams.toString()
    })

    if (!response.ok) {
      const error = await response.text()
      console.error('Token refresh failed:', error)
      return null
    }

    return await response.json()
  } catch (error) {
    console.error('Token refresh error:', error)
    return null
  }
}

/**
 * Fetch all lights from Hue API
 */
export async function fetchLights(accessToken: string, username: string): Promise<Record<string, any>> {
  const response = await fetch(`${HUE_API_URL}/${username}/lights`, {
    headers: {
      'Authorization': `Bearer ${accessToken}`,
    }
  })

  if (!response.ok) {
    throw new Error(`Failed to fetch lights: ${response.status}`)
  }

  return await response.json()
}

/**
 * Fetch all sensors from Hue API
 */
export async function fetchSensors(accessToken: string, username: string): Promise<Record<string, any>> {
  const response = await fetch(`${HUE_API_URL}/${username}/sensors`, {
    headers: {
      'Authorization': `Bearer ${accessToken}`,
    }
  })

  if (!response.ok) {
    throw new Error(`Failed to fetch sensors: ${response.status}`)
  }

  return await response.json()
}

/**
 * Extract relevant state from a light
 */
export function extractLightState(light: any): Record<string, any> {
  if (!light?.state) return {}

  return {
    on: light.state.on,
    bri: light.state.bri,
    ct: light.state.ct,
    hue: light.state.hue,
    sat: light.state.sat,
    reachable: light.state.reachable,
  }
}

/**
 * Extract relevant state from a sensor
 */
export function extractSensorState(sensor: any): Record<string, any> {
  if (!sensor?.state) return {}

  const state: Record<string, any> = {}

  // Motion sensor
  if (sensor.state.presence !== undefined) {
    state.presence = sensor.state.presence
  }

  // Contact sensor
  if (sensor.state.open !== undefined) {
    state.open = sensor.state.open
  }

  // Temperature sensor
  if (sensor.state.temperature !== undefined) {
    state.temperature = sensor.state.temperature / 100 // Hue returns in 0.01°C
  }

  // Light level sensor
  if (sensor.state.lightlevel !== undefined) {
    state.lightlevel = sensor.state.lightlevel
    state.dark = sensor.state.dark
    state.daylight = sensor.state.daylight
  }

  // Button
  if (sensor.state.buttonevent !== undefined) {
    state.buttonevent = sensor.state.buttonevent
  }

  // Lastupdated timestamp
  if (sensor.state.lastupdated) {
    state.lastupdated = sensor.state.lastupdated
  }

  return state
}

/**
 * Compare two states and check if they differ
 */
export function hasStateChanged(previousState: Record<string, any> | null, currentState: Record<string, any>): boolean {
  if (!previousState || Object.keys(previousState).length === 0) {
    return true // First reading
  }

  // Vergelijk relevante velden (niet lastupdated)
  const compareFields = ['on', 'bri', 'ct', 'hue', 'sat', 'reachable', 'presence', 'open', 'temperature', 'lightlevel', 'dark', 'daylight', 'buttonevent']

  for (const field of compareFields) {
    if (currentState[field] !== undefined && previousState[field] !== currentState[field]) {
      return true
    }
  }

  return false
}

/**
 * Determine device type from Hue sensor type
 */
export function mapSensorType(hueType: string): string {
  const typeMap: Record<string, string> = {
    'ZLLPresence': 'motion_sensor',
    'ZLLLightLevel': 'light_sensor',
    'ZLLTemperature': 'temperature_sensor',
    'ZLLSwitch': 'button',
    'ZGPSwitch': 'button',
    'CLIPOpenClose': 'contact_sensor',
    'ZLLOpenClose': 'contact_sensor',
  }

  return typeMap[hueType] || 'unknown'
}

/**
 * Extract battery level from sensor config
 */
export function extractBatteryLevel(sensor: any): number | null {
  return sensor?.config?.battery ?? null
}

/**
 * Fetch all groups (rooms) from Hue API
 */
export async function fetchGroups(accessToken: string, username: string): Promise<Record<string, any>> {
  const response = await fetch(`${HUE_API_URL}/${username}/groups`, {
    headers: {
      'Authorization': `Bearer ${accessToken}`,
    }
  })

  if (!response.ok) {
    throw new Error(`Failed to fetch groups: ${response.status}`)
  }

  return await response.json()
}

/**
 * Build a map of light/sensor IDs to room names
 */
export function buildRoomMap(groups: Record<string, any>): Map<string, string> {
  const roomMap = new Map<string, string>()

  for (const [_groupId, group] of Object.entries(groups)) {
    // Only process rooms (type "Room") not other group types
    if ((group as any).type !== 'Room') continue

    const roomName = (group as any).name
    const lights = (group as any).lights || []

    // Map each light ID to the room name
    for (const lightId of lights) {
      roomMap.set(`light_${lightId}`, roomName)
    }
  }

  return roomMap
}

/**
 * Build a map of sensor unique IDs to room names
 * Uses multiple strategies:
 * 1. Check if sensor ID is in a LightGroup with type "Room"
 * 2. Match MAC prefix with lights in a room
 * 3. Name matching as fallback
 */
export function buildSensorRoomMap(
  sensors: Record<string, any>,
  groups: Record<string, any>
): Map<string, string> {
  const sensorRoomMap = new Map<string, string>()

  // Strategy 1: Build map of sensor IDs to room names from groups
  // Some Hue setups include sensors in the "sensors" array of rooms (v2 API behavior)
  const sensorIdToRoom = new Map<string, string>()
  for (const [_groupId, group] of Object.entries(groups)) {
    if ((group as any).type !== 'Room') continue
    const roomName = (group as any).name

    // Check if group has sensors array (v2 API)
    const groupSensors = (group as any).sensors || []
    for (const sensorId of groupSensors) {
      sensorIdToRoom.set(sensorId, roomName)
    }
  }

  // Strategy 2: Build map of MAC prefixes to room names based on lights
  // Hue devices from same accessory share MAC prefix (first 23 chars of uniqueid)
  const macPrefixToRoom = new Map<string, string>()
  for (const [_groupId, group] of Object.entries(groups)) {
    if ((group as any).type !== 'Room') continue
    const roomName = (group as any).name
    const lights = (group as any).lights || []

    // We need light uniqueids - but we don't have them here
    // This strategy requires passing lights data too
  }

  // Apply strategies to each sensor
  for (const [sensorId, sensor] of Object.entries(sensors)) {
    const uniqueId = (sensor as any).uniqueid
    if (!uniqueId) continue

    // Strategy 1: Direct sensor ID mapping from groups
    if (sensorIdToRoom.has(sensorId)) {
      sensorRoomMap.set(uniqueId, sensorIdToRoom.get(sensorId)!)
      continue
    }

    // Strategy 3: Name matching as fallback
    const sensorName = (sensor as any).name?.toLowerCase() || ''
    for (const [_groupId, group] of Object.entries(groups)) {
      if ((group as any).type !== 'Room') continue
      const roomName = (group as any).name
      const roomNameLower = roomName.toLowerCase()

      // Clean sensor name (remove common suffixes)
      const cleanSensorName = sensorName
        .replace(/\s*(motion|temperature|sensor|light level|presence)\s*/gi, '')
        .trim()

      // Check various matching patterns
      if (sensorName.includes(roomNameLower) ||
          roomNameLower.includes(cleanSensorName) ||
          cleanSensorName === roomNameLower) {
        sensorRoomMap.set(uniqueId, roomName)
        break
      }
    }
  }

  return sensorRoomMap
}

// ============================================================
// Hue v2 CLIP API Functions
// ============================================================

/**
 * Fetch contact sensors via v2 CLIP API
 * Contact sensors are only available in v2 API
 */
export async function fetchContactSensorsV2(accessToken: string, username: string): Promise<any[]> {
  try {
    const response = await fetch(`${HUE_API_V2_URL}/contact`, {
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'hue-application-key': username,
      }
    })

    if (!response.ok) {
      console.error('Failed to fetch contact sensors v2:', response.status)
      return []
    }

    const data = await response.json()
    return data.data || []
  } catch (error) {
    console.error('Error fetching contact sensors v2:', error)
    return []
  }
}

/**
 * Fetch devices via v2 CLIP API
 * Used to get device names and metadata for contact sensors
 */
export async function fetchDevicesV2(accessToken: string, username: string): Promise<any[]> {
  try {
    const response = await fetch(`${HUE_API_V2_URL}/device`, {
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'hue-application-key': username,
      }
    })

    if (!response.ok) {
      console.error('Failed to fetch devices v2:', response.status)
      return []
    }

    const data = await response.json()
    return data.data || []
  } catch (error) {
    console.error('Error fetching devices v2:', error)
    return []
  }
}

/**
 * Fetch rooms via v2 CLIP API
 * Used to map devices to rooms for contact sensors
 */
export async function fetchRoomsV2(accessToken: string, username: string): Promise<any[]> {
  try {
    const response = await fetch(`${HUE_API_V2_URL}/room`, {
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'hue-application-key': username,
      }
    })

    if (!response.ok) {
      console.error('Failed to fetch rooms v2:', response.status)
      return []
    }

    const data = await response.json()
    return data.data || []
  } catch (error) {
    console.error('Error fetching rooms v2:', error)
    return []
  }
}

/**
 * Build sensor room map using light MAC prefixes
 * Sensors and lights from same Hue accessory share MAC prefix
 */
export function buildSensorRoomMapWithLights(
  sensors: Record<string, any>,
  lights: Record<string, any>,
  groups: Record<string, any>
): Map<string, string> {
  const sensorRoomMap = new Map<string, string>()

  // Build map of light uniqueid MAC prefix to room
  const macPrefixToRoom = new Map<string, string>()
  for (const [_groupId, group] of Object.entries(groups)) {
    if ((group as any).type !== 'Room') continue
    const roomName = (group as any).name
    const lightIds = (group as any).lights || []

    for (const lightId of lightIds) {
      const light = lights[lightId]
      if (light?.uniqueid) {
        // MAC prefix is first 23 characters (e.g., "00:17:88:01:0b:d0:f5:1d")
        const macPrefix = light.uniqueid.substring(0, 23)
        macPrefixToRoom.set(macPrefix, roomName)
      }
    }
  }

  // Match sensors by MAC prefix
  for (const [sensorId, sensor] of Object.entries(sensors)) {
    const uniqueId = (sensor as any).uniqueid
    if (!uniqueId) continue

    const macPrefix = uniqueId.substring(0, 23)

    if (macPrefixToRoom.has(macPrefix)) {
      sensorRoomMap.set(uniqueId, macPrefixToRoom.get(macPrefix)!)
    }
  }

  return sensorRoomMap
}
