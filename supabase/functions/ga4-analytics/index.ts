// GA4 Analytics Edge Function
// Haalt website analytics op via de Google Analytics Data API v1beta.
//
// Vereiste Supabase secrets:
//   GA4_SERVICE_ACCOUNT_KEY  — JSON string van Google service account
//   GA4_PROPERTY_ID          — GA4 property ID (bijv. "123456789")

import { getCorsHeaders, handleCors } from '../_shared/cors.ts'

// --- Google Auth helpers ---

function base64url(data: Uint8Array): string {
  let binary = ''
  for (const byte of data) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

async function createJwt(serviceAccount: { client_email: string; private_key: string }): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const header = { alg: 'RS256', typ: 'JWT' }
  const payload = {
    iss: serviceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/analytics.readonly',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }

  const enc = new TextEncoder()
  const headerB64 = base64url(enc.encode(JSON.stringify(header)))
  const payloadB64 = base64url(enc.encode(JSON.stringify(payload)))
  const signingInput = `${headerB64}.${payloadB64}`

  // Import private key
  const pemContents = serviceAccount.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\n/g, '')

  const binaryKey = Uint8Array.from(atob(pemContents), c => c.charCodeAt(0))
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8', binaryKey, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']
  )

  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', cryptoKey, enc.encode(signingInput))
  const sigB64 = base64url(new Uint8Array(signature))

  return `${signingInput}.${sigB64}`
}

async function getAccessToken(serviceAccount: { client_email: string; private_key: string }): Promise<string> {
  const jwt = await createJwt(serviceAccount)

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  })

  if (!res.ok) {
    const errText = await res.text()
    throw new Error(`Google token exchange failed: ${res.status} ${errText}`)
  }

  const data = await res.json()
  return data.access_token
}

// --- GA4 Data API ---

interface GA4Row {
  dimensionValues: { value: string }[]
  metricValues: { value: string }[]
}

interface GA4Response {
  rows?: GA4Row[]
  rowCount?: number
}

interface ReportRequest {
  dateRange: string  // "7", "30", "90"
  report: string     // "overview" | "pages" | "sources"
}

function buildDateRange(days: string): { startDate: string; endDate: string } {
  return { startDate: `${days}daysAgo`, endDate: 'today' }
}

async function runReport(
  accessToken: string,
  propertyId: string,
  dateRanges: { startDate: string; endDate: string }[],
  metrics: { name: string }[],
  dimensions?: { name: string }[],
  orderBys?: { metric?: { metricName: string }; desc?: boolean }[],
  limit?: number,
): Promise<GA4Response> {
  const body: Record<string, unknown> = { dateRanges, metrics }
  if (dimensions) body.dimensions = dimensions
  if (orderBys) body.orderBys = orderBys
  if (limit) body.limit = limit

  const res = await fetch(
    `https://analyticsdata.googleapis.com/v1beta/properties/${propertyId}:runReport`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    }
  )

  if (!res.ok) {
    const errText = await res.text()
    throw new Error(`GA4 API error: ${res.status} ${errText}`)
  }

  return res.json()
}

// --- Main handler ---

Deno.serve(async (req: Request) => {
  const corsResponse = handleCors(req)
  if (corsResponse) return corsResponse

  try {
    const saKeyRaw = Deno.env.get('GA4_SERVICE_ACCOUNT_KEY')
    const propertyId = Deno.env.get('GA4_PROPERTY_ID')

    if (!saKeyRaw || !propertyId) {
      return new Response(
        JSON.stringify({
          success: false,
          error: 'NOT_CONFIGURED',
          message: 'GA4 is nog niet geconfigureerd. Stel GA4_SERVICE_ACCOUNT_KEY en GA4_PROPERTY_ID in als Supabase secrets.',
        }),
        { status: 200, headers: { ...getCorsHeaders(req), 'Content-Type': 'application/json' } }
      )
    }

    const serviceAccount = JSON.parse(saKeyRaw)
    const { dateRange = '30' } = await req.json().catch(() => ({})) as { dateRange?: string }
    const dateRanges = [buildDateRange(dateRange)]

    // Haal access token op
    const accessToken = await getAccessToken(serviceAccount)

    // Drie rapporten parallel ophalen
    const [overviewRes, pagesRes, sourcesRes] = await Promise.all([
      // 1. Overview: bezoekers per dag
      runReport(
        accessToken, propertyId, dateRanges,
        [{ name: 'activeUsers' }, { name: 'sessions' }, { name: 'screenPageViews' }, { name: 'bounceRate' }, { name: 'averageSessionDuration' }],
        [{ name: 'date' }],
        [{ metric: { metricName: 'date' }, desc: false }],
      ),
      // 2. Top pagina's
      runReport(
        accessToken, propertyId, dateRanges,
        [{ name: 'screenPageViews' }, { name: 'activeUsers' }, { name: 'averageSessionDuration' }],
        [{ name: 'pageTitle' }, { name: 'pagePath' }],
        [{ metric: { metricName: 'screenPageViews' }, desc: true }],
        10,
      ),
      // 3. Traffic bronnen
      runReport(
        accessToken, propertyId, dateRanges,
        [{ name: 'sessions' }, { name: 'activeUsers' }, { name: 'bounceRate' }],
        [{ name: 'sessionDefaultChannelGroup' }],
        [{ metric: { metricName: 'sessions' }, desc: true }],
        10,
      ),
    ])

    // Transform overview data
    const daily = (overviewRes.rows || []).map(row => ({
      date: row.dimensionValues[0].value,
      users: parseInt(row.metricValues[0].value),
      sessions: parseInt(row.metricValues[1].value),
      pageviews: parseInt(row.metricValues[2].value),
      bounceRate: parseFloat(row.metricValues[3].value),
      avgDuration: parseFloat(row.metricValues[4].value),
    }))

    // Totalen
    const totals = daily.reduce((acc, d) => ({
      users: acc.users + d.users,
      sessions: acc.sessions + d.sessions,
      pageviews: acc.pageviews + d.pageviews,
    }), { users: 0, sessions: 0, pageviews: 0 })

    const avgBounce = daily.length > 0
      ? daily.reduce((s, d) => s + d.bounceRate, 0) / daily.length
      : 0
    const avgDuration = daily.length > 0
      ? daily.reduce((s, d) => s + d.avgDuration, 0) / daily.length
      : 0

    // Transform pages data
    const pages = (pagesRes.rows || []).map(row => ({
      title: row.dimensionValues[0].value,
      path: row.dimensionValues[1].value,
      views: parseInt(row.metricValues[0].value),
      users: parseInt(row.metricValues[1].value),
      avgDuration: parseFloat(row.metricValues[2].value),
    }))

    // Transform sources data
    const sources = (sourcesRes.rows || []).map(row => ({
      channel: row.dimensionValues[0].value,
      sessions: parseInt(row.metricValues[0].value),
      users: parseInt(row.metricValues[1].value),
      bounceRate: parseFloat(row.metricValues[2].value),
    }))

    return new Response(
      JSON.stringify({
        success: true,
        data: { daily, totals, avgBounce, avgDuration, pages, sources },
      }),
      { headers: { ...getCorsHeaders(req), 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('GA4 analytics error:', error)
    return new Response(
      JSON.stringify({ success: false, error: String(error) }),
      { status: 500, headers: { ...getCorsHeaders(req), 'Content-Type': 'application/json' } }
    )
  }
})
