// Shared CORS headers for Edge Functions

const ALLOWED_ORIGINS = [
  'https://gerustthuis.nl',
  'https://portaal.gerustthuis.nl',
  'https://gerustthuis-portaal.vercel.app',
  // Development
  'http://localhost:3000',
  'http://localhost:5173',
  'http://localhost:5174',
]

function getAllowedOrigin(req: Request): string {
  const origin = req.headers.get('Origin') || ''
  return ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0]
}

export function getCorsHeaders(req: Request) {
  return {
    'Access-Control-Allow-Origin': getAllowedOrigin(req),
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Vary': 'Origin',
  }
}

export function handleCors(req: Request): Response | null {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: getCorsHeaders(req) })
  }
  return null
}

// Backwards-compatible export for files that still use corsHeaders directly
// (verwijder zodra alle functies naar getCorsHeaders zijn gemigreerd)
export const corsHeaders = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGINS[0],
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
