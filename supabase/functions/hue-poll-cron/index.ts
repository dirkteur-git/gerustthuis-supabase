import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

// This function is triggered by a cron job every minute
// It calls the hue-poll-state function to poll all Hue bridges

serve(async (req) => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    console.log('Cron: Triggering hue-poll-state...')

    const response = await fetch(`${supabaseUrl}/functions/v1/hue-poll-state`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${serviceRoleKey}`,
        'Content-Type': 'application/json',
      },
    })

    const result = await response.json()

    console.log('Cron: Poll result:', JSON.stringify(result))

    return new Response(
      JSON.stringify({
        success: true,
        triggered_at: new Date().toISOString(),
        poll_result: result,
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('Cron error:', error)
    return new Response(
      JSON.stringify({ success: false, error: String(error) }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
})
