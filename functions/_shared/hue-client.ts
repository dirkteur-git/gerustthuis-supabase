// Shared Hue API client utilities

const HUE_API_URL = 'https://api.meethue.com/route/api'
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
